#!/usr/bin/env python3
"""Capture one new exact NATS event without a durable or historical consumer."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import ipaddress
import json
import os
import re
import signal
import socket
import stat
import sys
import threading
import time


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--subject", required=True)
    parser.add_argument("--event", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--task-id", required=True)
    parser.add_argument("--evidence-dir-fd", type=int)
    parser.add_argument("--ready-name")
    parser.add_argument("--output-name")
    parser.add_argument("--ready-fd", type=int)
    parser.add_argument("--output-fd", type=int)
    parser.add_argument("--timeout", required=True, type=float)
    args = parser.parse_args()
    if not 1 <= args.port <= 65535 or not 0 < args.timeout <= 30:
        parser.error("port or timeout is out of range")
    token = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,255}")
    event = re.compile(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+")
    subject = re.compile(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+")
    if subject.fullmatch(args.subject) is None:
        parser.error("subject is malformed")
    if event.fullmatch(args.event) is None:
        parser.error("event is malformed")
    for value in (args.team_id, args.task_id):
        if token.fullmatch(value) is None:
            parser.error("event identity is malformed")
    evidence_name = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
    descriptor_mode = args.ready_fd is not None or args.output_fd is not None
    if descriptor_mode:
        if (
            args.ready_fd is None
            or args.output_fd is None
            or args.ready_fd < 0
            or args.output_fd < 0
            or args.ready_fd == args.output_fd
            or args.ready_name is not None
            or args.output_name is not None
        ):
            parser.error("evidence capability descriptors are malformed")
    else:
        if (
            args.evidence_dir_fd is None
            or args.evidence_dir_fd < 0
            or args.ready_name is None
            or args.output_name is None
            or any(
                evidence_name.fullmatch(value) is None or value in {".", ".."}
                for value in (args.ready_name, args.output_name)
            )
            or args.ready_name == args.output_name
        ):
            parser.error("evidence descriptor or name is malformed")
    return args


def _same_file(left: os.stat_result, right: os.stat_result) -> bool:
    return left.st_dev == right.st_dev and left.st_ino == right.st_ino


def _validate_evidence_directory(descriptor: int) -> None:
    metadata = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or stat.S_IMODE(metadata.st_mode) & 0o077
        or metadata.st_nlink < 1
    ):
        raise RuntimeError("evidence directory descriptor is not private and owned")


def _name_exists(directory_fd: int, name: str) -> bool:
    try:
        os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return True


def _publish_file(directory_fd: int, name: str, value: bytes) -> None:
    descriptor = os.open(
        name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
        dir_fd=directory_fd,
    )
    try:
        opened = os.fstat(descriptor)
        named = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != os.getuid()
            or opened.st_nlink != 1
            or stat.S_IMODE(opened.st_mode) != 0o600
            or not _same_file(opened, named)
        ):
            raise RuntimeError("evidence publication identity changed before write")
        view = memoryview(value)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise RuntimeError("evidence publication made no progress")
            view = view[written:]
        os.fsync(descriptor)
        after = os.fstat(descriptor)
        named_after = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if (
            after.st_nlink != 1
            or after.st_size != len(value)
            or not _same_file(opened, after)
            or not _same_file(opened, named_after)
        ):
            raise RuntimeError("evidence publication identity changed during write")
    finally:
        os.close(descriptor)


def _publish_descriptor(descriptor: int, value: bytes) -> None:
    opened = os.fstat(descriptor)
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_uid != os.getuid()
        or opened.st_nlink != 1
        or stat.S_IMODE(opened.st_mode) != 0o600
        or opened.st_size != 0
    ):
        raise RuntimeError("evidence capability is not an empty private file")
    offset = 0
    view = memoryview(value)
    while view:
        written = os.pwrite(descriptor, view, offset)
        if written <= 0:
            raise RuntimeError("evidence capability write made no progress")
        offset += written
        view = view[written:]
    os.fsync(descriptor)
    after = os.fstat(descriptor)
    if (
        not _same_file(opened, after)
        or after.st_nlink != 1
        or after.st_size != len(value)
    ):
        raise RuntimeError("evidence capability identity changed during write")


def _remaining(deadline: float) -> float:
    value = deadline - time.monotonic()
    if value <= 0:
        raise TimeoutError("NATS evidence capture timed out")
    return value


@contextmanager
def _absolute_deadline(seconds: float):
    """Interrupt connect, protocol, and evidence publication at one deadline."""
    if (
        threading.current_thread() is not threading.main_thread()
        or not hasattr(signal, "setitimer")
        or not hasattr(signal, "ITIMER_REAL")
    ):
        raise RuntimeError("NATS evidence deadline enforcement is unavailable")
    if signal.getitimer(signal.ITIMER_REAL) != (0.0, 0.0):
        raise RuntimeError("another process deadline is already active")

    previous_handler = signal.getsignal(signal.SIGALRM)

    def deadline_expired(_signum, _frame):  # noqa: ANN001
        raise TimeoutError("NATS evidence capture timed out")

    signal.signal(signal.SIGALRM, deadline_expired)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    deadline = time.monotonic() + seconds
    try:
        yield deadline
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)


def _connect_numeric(host: str, port: int, deadline: float) -> socket.socket:
    """Connect to one literal address without DNS or multi-address fallback."""
    try:
        address = ipaddress.ip_address(host)
    except ValueError as error:
        raise RuntimeError("NATS evidence host must be a numeric IP address") from error
    family = socket.AF_INET6 if address.version == 6 else socket.AF_INET
    client = socket.socket(family, socket.SOCK_STREAM)
    try:
        client.settimeout(_remaining(deadline))
        client.connect((address.compressed, port))
        return client
    except BaseException:
        client.close()
        raise


class _DeadlineReader:
    def __init__(self, client: socket.socket, deadline: float) -> None:
        self.client = client
        self.deadline = deadline
        self.buffer = bytearray()

    def _receive(self, maximum: int) -> None:
        self.client.settimeout(_remaining(self.deadline))
        chunk = self.client.recv(maximum)
        if not chunk:
            raise RuntimeError("NATS evidence stream is truncated")
        self.buffer.extend(chunk)

    def read_line(self) -> bytes:
        while True:
            marker = self.buffer.find(b"\r\n")
            if marker >= 0:
                line = bytes(self.buffer[:marker])
                del self.buffer[: marker + 2]
                return line
            if len(self.buffer) > 65536:
                raise RuntimeError("NATS control line is missing or oversized")
            self._receive(65537 - len(self.buffer))

    def read_exact(self, size: int) -> bytes:
        if size < 0:
            raise RuntimeError("NATS evidence payload size is invalid")
        while len(self.buffer) < size:
            self._receive(size - len(self.buffer))
        value = bytes(self.buffer[:size])
        del self.buffer[:size]
        return value


def _capture(args: argparse.Namespace, deadline: float) -> int:
    descriptor_mode = args.ready_fd is not None
    if descriptor_mode:
        assert args.ready_fd is not None
        assert args.output_fd is not None
    else:
        assert args.evidence_dir_fd is not None
        assert args.ready_name is not None
        assert args.output_name is not None
        _validate_evidence_directory(args.evidence_dir_fd)
        if _name_exists(args.evidence_dir_fd, args.ready_name) or _name_exists(
            args.evidence_dir_fd, args.output_name
        ):
            raise RuntimeError("evidence destination already exists")
    with _connect_numeric(args.host, args.port, deadline) as client:
        reader = _DeadlineReader(client, deadline)
        first = reader.read_line()
        if not first.startswith(b"INFO "):
            raise RuntimeError("NATS server did not send INFO")
        info = json.loads(first[5:])
        if not isinstance(info, dict) or info.get("auth_required") is True:
            raise RuntimeError("unsupported authenticated NATS evidence endpoint")
        connect = json.dumps(
            {"verbose": False, "pedantic": True, "name": "odysseus-e2e-evidence"},
            separators=(",", ":"),
        ).encode()
        client.settimeout(_remaining(deadline))
        client.sendall(
            b"CONNECT "
            + connect
            + b"\r\n"
            + f"SUB {args.subject} ODYSSEUS_E2E\r\nPING\r\n".encode()
        )
        while True:
            line = reader.read_line()
            if line == b"PING":
                client.settimeout(_remaining(deadline))
                client.sendall(b"PONG\r\n")
                continue
            if line == b"PONG":
                break
            if line.startswith(b"-ERR"):
                raise RuntimeError("NATS rejected the evidence subscription")
        if descriptor_mode:
            _publish_descriptor(args.ready_fd, b"ready\n")
        else:
            _publish_file(args.evidence_dir_fd, args.ready_name, b"ready\n")

        while True:
            line = reader.read_line()
            if line == b"PING":
                client.settimeout(_remaining(deadline))
                client.sendall(b"PONG\r\n")
                continue
            if line.startswith(b"-ERR"):
                raise RuntimeError("NATS rejected the evidence consumer")
            fields = line.split()
            if not fields or fields[0] != b"MSG" or len(fields) not in {4, 5}:
                continue
            subject = fields[1].decode("ascii")
            size = int(fields[-1])
            if size < 0 or size > 1024 * 1024:
                raise RuntimeError("NATS evidence payload is oversized")
            payload_bytes = reader.read_exact(size)
            terminator = reader.read_exact(2)
            if terminator != b"\r\n":
                raise RuntimeError("NATS evidence payload is truncated")
            payload = json.loads(payload_bytes)
            if not isinstance(payload, dict):
                continue
            data = payload.get("data")
            if (
                subject != args.subject
                or payload.get("event") != args.event
                or not isinstance(data, dict)
                or data.get("team_id") != args.team_id
                or data.get("task_id") != args.task_id
            ):
                continue
            result = json.dumps(
                {"subject": subject, "payload": payload},
                sort_keys=True,
                separators=(",", ":"),
            ).encode()
            encoded_result = result + b"\n"
            if len(encoded_result) > 1024 * 1024:
                raise RuntimeError("NATS evidence result is oversized")
            if descriptor_mode:
                _publish_descriptor(args.output_fd, encoded_result)
            else:
                _publish_file(
                    args.evidence_dir_fd,
                    args.output_name,
                    encoded_result,
                )
            return 0


def main() -> int:
    args = _parse_args()
    with _absolute_deadline(args.timeout) as deadline:
        return _capture(args, deadline)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"NATS evidence capture failed: {error}", file=sys.stderr)
        raise SystemExit(1)
