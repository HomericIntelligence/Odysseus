#!/usr/bin/env python3
"""HTTP research-intake client for HomericIntelligence.

The only available CLI operation registers a new high-level task with Nestor
(``POST /v1/research``) and exits. It requires ``submit --no-watch``. A returned
intake ID proves only that Nestor accepted the request; it is not evidence of a
research-pool dispatch.

NATS watch and interview handling are unavailable at the current pins because
the canonical policy has no dedicated least-privilege console identity.
Proposed ADR-013 section 5 records target design context; the future M5 task
owns implementing that consumer after its identity and behavior are approved.

Usage:
    python3 tools/odysseus-console.py submit "IDEA TEXT" \
        [--context TEXT] [--repo OWNER/NAME] --no-watch

Environment:
    NESTOR_URL          Nestor base URL (default: http://127.0.0.1:8081)
                        Plaintext HTTP requires a numeric loopback literal;
                        redirects fail.
    NESTOR_API_KEY      Bearer token for Nestor, if configured
    NESTOR_CA_FILE      Optional CA bundle for an HTTPS Nestor endpoint
"""

import argparse
from contextlib import contextmanager
import ipaddress
import json
import math
import os
from pathlib import Path
import signal
import ssl
import stat
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

NESTOR_URL = os.environ.get("NESTOR_URL", "http://127.0.0.1:8081")
WATCH_UNAVAILABLE = (
    "watch mode is unavailable: the canonical NATS policy has no dedicated "
    "least-privilege NATS identity for the Odysseus console"
)

RESET = "\033[0m"
BOLD = "\033[1m"
GREEN = "\033[0;32m"
RED = "\033[0;31m"
MAX_RESEARCH_ID_LENGTH = 256
MAX_NESTOR_RESPONSE_BYTES = 64 * 1024
MAX_NESTOR_CA_BYTES = 2 * 1024 * 1024
NESTOR_REQUEST_TIMEOUT_SECONDS = 10.0
MAX_CONSOLE_ERROR_DETAIL_CHARS = 512


class NestorResponseError(ValueError):
    """Report a response that cannot satisfy the Nestor intake contract."""


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Turn every HTTP redirect into a response error instead of following it."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        """Refuse redirects so credentials never cross an unverified origin."""
        return None


def _safe_error_detail(value: object) -> str:
    """Render an untrusted exception field as one bounded printable record."""
    try:
        detail = str(value)
    except Exception:  # pragma: no cover - defensive against hostile __str__
        detail = type(value).__name__
    escaped = ascii(detail)
    if len(escaped) > MAX_CONSOLE_ERROR_DETAIL_CHARS:
        escaped = escaped[: MAX_CONSOLE_ERROR_DETAIL_CHARS - 3] + "..."
    return escaped


def _remaining(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise NestorResponseError("Nestor request exceeded its absolute deadline")
    return remaining


@contextmanager
def _absolute_deadline(seconds: float):
    """Interrupt every blocking phase at one wall-clock deadline."""
    if not math.isfinite(seconds) or seconds <= 0:
        raise NestorResponseError("Nestor request deadline is invalid")
    if (
        threading.current_thread() is not threading.main_thread()
        or not hasattr(signal, "setitimer")
        or not hasattr(signal, "ITIMER_REAL")
    ):
        raise NestorResponseError(
            "Nestor request deadline enforcement is unavailable"
        )
    if signal.getitimer(signal.ITIMER_REAL) != (0.0, 0.0):
        raise NestorResponseError("another process deadline is already active")

    previous_handler = signal.getsignal(signal.SIGALRM)

    def deadline_expired(_signum, _frame):  # noqa: ANN001
        raise NestorResponseError("Nestor request exceeded its absolute deadline")

    signal.signal(signal.SIGALRM, deadline_expired)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    deadline = time.monotonic() + seconds
    try:
        yield deadline
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)


def _identity(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _trusted_ca_directory(metadata: os.stat_result) -> bool:
    return (
        stat.S_ISDIR(metadata.st_mode)
        and metadata.st_uid == 0
        and metadata.st_mode & 0o022 == 0
    )


def _trusted_ca_file(metadata: os.stat_result) -> bool:
    return (
        stat.S_ISREG(metadata.st_mode)
        and metadata.st_uid == 0
        and metadata.st_nlink == 1
        and metadata.st_mode & 0o022 == 0
    )


def _read_bound_ca_bundle(path: Path) -> bytes:
    """Read one stable, direct regular CA file through retained descriptors."""
    required = ("O_CLOEXEC", "O_DIRECTORY", "O_NOFOLLOW", "O_NONBLOCK")
    if any(not hasattr(os, name) for name in required):
        raise ValueError("NESTOR_CA_FILE cannot be bound safely on this host")
    if not path.is_absolute():
        raise ValueError("NESTOR_CA_FILE must be an absolute path")

    directory_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW
    file_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
    parent = Path(os.path.abspath(path.parent))
    descriptors: list[int] = []
    links: list[tuple[int, str, int, tuple[int, ...]]] = []
    file_descriptor = -1
    try:
        root_descriptor = os.open("/", directory_flags)
        descriptors.append(root_descriptor)
        if not _trusted_ca_directory(os.fstat(root_descriptor)):
            raise ValueError("NESTOR_CA_FILE root is not a trusted directory")
        current = root_descriptor
        for component in parent.parts[1:]:
            child = os.open(component, directory_flags, dir_fd=current)
            metadata = os.fstat(child)
            if not _trusted_ca_directory(metadata):
                os.close(child)
                raise ValueError(
                    "NESTOR_CA_FILE parent is not a trusted, non-writable directory"
                )
            links.append((current, component, child, _identity(metadata)))
            descriptors.append(child)
            current = child

        file_descriptor = os.open(path.name, file_flags, dir_fd=current)
        before = os.fstat(file_descriptor)
        if not _trusted_ca_file(before):
            raise ValueError(
                "NESTOR_CA_FILE must be a root-owned, direct, non-writable file"
            )
        if before.st_size > MAX_NESTOR_CA_BYTES:
            raise ValueError(
                f"NESTOR_CA_FILE exceeds the {MAX_NESTOR_CA_BYTES}-byte limit"
            )
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(
                file_descriptor,
                min(65536, MAX_NESTOR_CA_BYTES + 1 - total),
            )
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > MAX_NESTOR_CA_BYTES:
                raise ValueError(
                    f"NESTOR_CA_FILE exceeds the {MAX_NESTOR_CA_BYTES}-byte limit"
                )

        after = os.fstat(file_descriptor)
        current_file = os.stat(path.name, dir_fd=current, follow_symlinks=False)
        if (
            _identity(before) != _identity(after)
            or _identity(after) != _identity(current_file)
            or not _trusted_ca_file(after)
            or not _trusted_ca_file(current_file)
        ):
            raise ValueError("NESTOR_CA_FILE changed while it was read")
        for parent_fd, name, child_fd, expected in links:
            current_link = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            if (
                not _trusted_ca_directory(current_link)
                or not _trusted_ca_directory(os.fstat(child_fd))
                or _identity(current_link) != expected
                or _identity(os.fstat(child_fd)) != expected
            ):
                raise ValueError("NESTOR_CA_FILE parent changed while it was read")
        return b"".join(chunks)
    except OSError as error:
        raise ValueError("NESTOR_CA_FILE cannot be opened safely") from error
    finally:
        if file_descriptor >= 0:
            os.close(file_descriptor)
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def _tls_context() -> ssl.SSLContext:
    explicit = os.environ.get("NESTOR_CA_FILE")
    if explicit:
        candidates = [Path(explicit)]
    else:
        compiled = ssl.get_default_verify_paths().openssl_cafile
        candidates = [
            Path("/private/etc/ssl/cert.pem"),
            Path("/etc/ssl/certs/ca-certificates.crt"),
            Path("/etc/pki/tls/certs/ca-bundle.crt"),
        ]
        if compiled:
            candidates.append(Path(os.path.realpath(compiled)))

    last_error: Exception | None = None
    for ca_path in dict.fromkeys(candidates):
        try:
            ca_data = _read_bound_ca_bundle(ca_path)
            pem_data = ca_data.decode("ascii")
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.load_verify_locations(cadata=pem_data)
            return context
        except (OSError, UnicodeError, ssl.SSLError, ValueError) as error:
            last_error = error
            if explicit:
                break
    label = "NESTOR_CA_FILE" if explicit else "system CA bundle"
    raise ValueError(f"invalid {label}: cannot load trusted CA bundle") from last_error


def validated_nestor_url(value: str) -> str:
    """Return a safe Nestor base URL or reject it before network use."""
    try:
        parsed = urllib.parse.urlsplit(value)
        _ = parsed.port
    except ValueError as error:
        raise ValueError(f"invalid NESTOR_URL: {error}") from error

    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError("NESTOR_URL must use http:// or https:// with a host")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("NESTOR_URL must not contain embedded credentials")
    if parsed.query or parsed.fragment:
        raise ValueError("NESTOR_URL must not contain a query or fragment")

    if parsed.scheme == "http":
        host = parsed.hostname
        try:
            address = ipaddress.ip_address(host)
        except ValueError as error:
            raise ValueError(
                "plaintext HTTP requires a numeric loopback NESTOR_URL host"
            ) from error
        if not address.is_loopback or "%" in host:
            raise ValueError(
                "plaintext HTTP requires a numeric loopback NESTOR_URL host"
            )

    return value.rstrip("/")


def submit_research(idea: str, context: str = "", repo: str = "") -> dict:
    """POST the idea to Nestor's intake endpoint and return its response."""
    base_url = validated_nestor_url(NESTOR_URL)
    body = {"idea": idea}
    if context:
        body["context"] = context
    if repo:
        body["repo"] = repo

    request = urllib.request.Request(
        f"{base_url}/v1/research",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    api_key = os.environ.get("NESTOR_API_KEY")
    if api_key:
        request.add_header("Authorization", f"Bearer {api_key}")

    with _absolute_deadline(NESTOR_REQUEST_TIMEOUT_SECONDS) as deadline:
        handlers = [urllib.request.ProxyHandler({}), NoRedirectHandler()]
        if urllib.parse.urlsplit(base_url).scheme == "https":
            handlers.append(urllib.request.HTTPSHandler(context=_tls_context()))
        opener = urllib.request.build_opener(*handlers)
        with opener.open(request, timeout=_remaining(deadline)) as response:
            response_body = response.read(MAX_NESTOR_RESPONSE_BYTES + 1)
            _remaining(deadline)
            if len(response_body) > MAX_NESTOR_RESPONSE_BYTES:
                raise NestorResponseError(
                    f"Nestor response exceeds {MAX_NESTOR_RESPONSE_BYTES}-byte limit"
                )
            try:
                return json.loads(response_body.decode())
            except (ValueError, RecursionError) as error:
                raise NestorResponseError(
                    "Nestor response is not valid UTF-8 JSON"
                ) from error


def parse_args(argv):
    """Parse the HTTP-only console interface."""
    parser = argparse.ArgumentParser(
        prog="odysseus-console",
        description=(
            "HTTP research-intake client; NATS watch is unavailable at current pins."
        ),
    )
    commands = parser.add_subparsers(dest="command")
    submit = commands.add_parser(
        "submit", help="Submit a high-level task to Nestor (POST /v1/research)"
    )
    submit.add_argument("idea", help="High-level task / idea text")
    submit.add_argument(
        "--context", default="", help="Extra context for the researcher"
    )
    submit.add_argument("--repo", default="", help="Target repo (OWNER/NAME), if known")
    submit.add_argument(
        "--no-watch",
        action="store_true",
        help="Required at current pins: exit after the HTTP submission",
    )
    return parser.parse_args(argv)


def main() -> None:
    """Submit one HTTP intake request or fail before any unavailable watch path."""
    args = parse_args(sys.argv[1:])
    if args.command != "submit" or not args.no_watch:
        print(f"ERROR: {WATCH_UNAVAILABLE}", file=sys.stderr)
        raise SystemExit(2)

    try:
        result = submit_research(args.idea, args.context, args.repo)
    except NestorResponseError as error:
        print(
            f"{RED}✗ Nestor response failure: {_safe_error_detail(error)}{RESET}",
            file=sys.stderr,
        )
        raise SystemExit(1) from error
    except ValueError as error:
        print(
            f"{RED}✗ Invalid console configuration: {_safe_error_detail(error)}{RESET}",
            file=sys.stderr,
        )
        raise SystemExit(2) from error
    except urllib.error.HTTPError as error:
        print(
            f"{RED}✗ Nestor rejected the submission: "
            f"HTTP {_safe_error_detail(error.code)}{RESET}",
            file=sys.stderr,
        )
        raise SystemExit(1) from error
    except urllib.error.URLError as error:
        print(
            f"{RED}✗ Nestor endpoint is unreachable: "
            f"{_safe_error_detail(error.reason)}{RESET}",
            file=sys.stderr,
        )
        raise SystemExit(1) from error

    research_id = result.get("id") if isinstance(result, dict) else None
    if not isinstance(research_id, str) or not research_id.strip():
        print("ERROR: Nestor response contained no intake ID", file=sys.stderr)
        raise SystemExit(1)
    if (
        research_id != research_id.strip()
        or len(research_id) > MAX_RESEARCH_ID_LENGTH
        or not research_id.isprintable()
    ):
        print("ERROR: Nestor response contained an invalid intake ID", file=sys.stderr)
        raise SystemExit(1)
    rendered_id = json.dumps(research_id, ensure_ascii=True)
    print(f"{GREEN}✓ submitted{RESET} research_id={BOLD}{rendered_id}{RESET}")


if __name__ == "__main__":
    main()
