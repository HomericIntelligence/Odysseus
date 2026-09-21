#!/usr/bin/env python3
"""Validate NATS configuration syntax and authentication structure.

The delimiter precheck in this module is not a NATS syntax parser. The command
line syntax gate fails closed unless a real ``nats-server -t`` parser is
available. With no explicit parser path, it downloads one fixed official
release and verifies its embedded SHA-256 before use. It renders controlled
environment and certificate fixtures so the parser can validate canonical
deployment files without live secrets.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import ctypes
import errno
import hashlib
import hmac
import io
import os
import platform
import re
import selectors
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from pathlib import PurePosixPath
from typing import Callable, ContextManager, Iterable, Iterator, Sequence
from urllib.request import urlopen
from urllib.parse import urlsplit


PARSER_TIMEOUT_SECONDS = 15
PARSER_DOWNLOAD_TIMEOUT_SECONDS = 30
MAX_PARSER_ARCHIVE_BYTES = 32 * 1024 * 1024
MAX_PARSER_BINARY_BYTES = 64 * 1024 * 1024
MAX_PARSER_OUTPUT_BYTES = 256 * 1024
MAX_CONFIG_BYTES = 1_048_576
MAX_CERTIFICATE_BYTES = 1_048_576
TERM_GRACE_SECONDS = 0.5
KILL_GRACE_SECONDS = 1.0
_OPEN_TO_CLOSE = {"{": "}", "[": "]", "(": ")"}
_CLOSE_TO_OPEN = {value: key for key, value in _OPEN_TO_CLOSE.items()}
_CERT_ASSIGNMENT = re.compile(
    r"(?P<prefix>\b(?P<field>cert_file|key_file|ca_file)\s*(?:=|:)\s*)"
    r"(?P<quote>['\"])(?P<value>.*?)(?P=quote)"
)
_ENV_REFERENCE = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)\Z")

_AUTH_ENVIRONMENTS = {
    "client": {
        "token": frozenset({"NATS_CLIENT_TOKEN"}),
        "user": frozenset({"NATS_CLIENT_USER"}),
        "password": frozenset({"NATS_CLIENT_PASSWORD"}),
        "nkey": frozenset({"NATS_CLIENT_NKEY"}),
    },
    "leaf": {
        "user": frozenset({"NATS_LEAF_USER"}),
        "password": frozenset({"NATS_LEAF_PASSWORD"}),
        "nkey": frozenset({"NATS_LEAF_NKEY"}),
    },
    "cluster": {
        "user": frozenset({"NATS_CLUSTER_USER"}),
        "password": frozenset({"NATS_CLUSTER_PASSWORD"}),
    },
    "account": {
        "user": frozenset(),
        "password": frozenset(),
        "nkey": frozenset(),
    },
}
_REMOTE_ENVIRONMENTS = {
    "url": frozenset({"NATS_LEAF_URL"}),
    "credentials": frozenset({"NATS_LEAF_CREDS"}),
    "nkey": frozenset({"NATS_LEAF_NKEY", "NATS_LEAF_SEED"}),
}


@dataclass(frozen=True)
class Token:
    """One lexical token used only for depth-aware auth inspection."""

    kind: str
    value: str
    line: int


@dataclass(frozen=True)
class Entry:
    """One direct named entry in a map-like scope."""

    name: str
    value_start: int
    value_end: int
    container: str | None


@dataclass(frozen=True)
class ParserRelease:
    """One immutable official NATS parser release artifact."""

    url: str
    member: str
    sha256: str


@dataclass(frozen=True)
class ParserExecutable(os.PathLike[str]):
    """A parser path plus the exact digest authorized by its producer."""

    path: Path
    sha256: str | None

    def __fspath__(self) -> str:
        return os.fspath(self.path)

    def __str__(self) -> str:
        return str(self.path)


@dataclass(frozen=True)
class CommandResult:
    """One bounded child-process result."""

    returncode: int
    stdout: str
    stderr: str


def _run_cleanup_actions(
    *actions: Callable[[], None],
    pending_primary: BaseException | None = None,
) -> None:
    """Attempt every cleanup and keep an active primary failure authoritative."""
    primary = sys.exc_info()[1] or pending_primary
    first_cleanup_error: BaseException | None = None
    for action in actions:
        try:
            action()
        except BaseException as error:
            if first_cleanup_error is None:
                first_cleanup_error = error
    if primary is None and first_cleanup_error is not None:
        raise first_cleanup_error


@dataclass
class BoundExecutable:
    """One selected executable copied to an owner-private snapshot."""

    name: str
    selected_path: str
    snapshot_directory: str
    directory_descriptor: int
    snapshot_name: str
    snapshot_state: os.stat_result
    directory_state: os.stat_result
    digest: bytes
    parent_descriptor: int = -1
    snapshot_directory_name: str = ""
    interpreter: BoundExecutable | None = None

    @property
    def path(self) -> str:
        return os.path.join(self.snapshot_directory, self.snapshot_name)

    def verify(self) -> None:
        current_directory = os.fstat(self.directory_descriptor)
        if (
            not stat.S_ISDIR(current_directory.st_mode)
            or current_directory.st_uid != os.geteuid()
            or stat.S_IMODE(current_directory.st_mode) != 0o500
            or not _same_object(self.directory_state, current_directory)
            or set(os.listdir(self.directory_descriptor)) != {self.snapshot_name}
        ):
            raise RuntimeError(
                f"private executable snapshot directory changed: {self.name}"
            )
        descriptor = os.open(
            self.snapshot_name,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0),
            dir_fd=self.directory_descriptor,
        )
        try:
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                raise RuntimeError(
                    f"private executable snapshot is not regular: {self.name}"
                )
            digest, _ = _read_executable_digest(descriptor, self.name)
            current = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        if (
            not stat.S_ISREG(current.st_mode)
            or current.st_uid != os.geteuid()
            or current.st_nlink != 1
            or stat.S_IMODE(current.st_mode) != 0o500
            or not _same_file_state(self.snapshot_state, current)
            or not hmac.compare_digest(digest, self.digest)
        ):
            raise RuntimeError(f"private executable snapshot changed: {self.name}")
        if self.interpreter is not None:
            self.interpreter.verify()

    def close(self) -> None:
        def cleanup_snapshot() -> None:
            _cleanup_private_snapshot(
                self.directory_descriptor,
                self.snapshot_directory,
                self.snapshot_name,
                self.snapshot_state,
            )

        def cleanup_snapshot_directory() -> None:
            if self.parent_descriptor >= 0 and self.snapshot_directory_name:
                _quarantine_owned_entry(
                    self.parent_descriptor,
                    self.snapshot_directory_name,
                    os.fstat(self.directory_descriptor),
                    is_directory=True,
                )

        actions: list[Callable[[], None]] = [
            cleanup_snapshot,
            cleanup_snapshot_directory,
            lambda: os.close(self.directory_descriptor),
        ]
        if self.parent_descriptor >= 0:
            actions.append(lambda: os.close(self.parent_descriptor))
        if self.interpreter is not None:
            actions.append(self.interpreter.close)
        _run_cleanup_actions(*actions)


@dataclass
class BoundConfigInput:
    """One unlinked, read-only config snapshot inherited by the parser."""

    descriptor: int
    state: os.stat_result
    digest: bytes
    size: int
    label: str
    maximum_size: int = MAX_CONFIG_BYTES

    @property
    def path(self) -> str:
        return f"/proc/self/fd/{self.descriptor}"

    def verify(self) -> None:
        current = os.fstat(self.descriptor)
        if (
            not stat.S_ISREG(current.st_mode)
            or current.st_uid != os.geteuid()
            or current.st_nlink != 0
            or stat.S_IMODE(current.st_mode) != 0o400
            or not _same_file_state(self.state, current)
        ):
            raise RuntimeError(f"bound config snapshot changed: {self.label}")
        content = bytearray()
        offset = 0
        while len(content) <= self.maximum_size:
            chunk = os.pread(
                self.descriptor,
                min(65_536, self.maximum_size + 1 - len(content)),
                offset,
            )
            if not chunk:
                break
            content.extend(chunk)
            offset += len(chunk)
        if (
            len(content) != self.size
            or len(content) > self.maximum_size
            or not hmac.compare_digest(
                hashlib.sha256(content).digest(), self.digest
            )
        ):
            raise RuntimeError(f"bound config snapshot bytes changed: {self.label}")

    def close(self) -> None:
        os.close(self.descriptor)


@dataclass
class BoundCertificateFiles:
    """Anonymous certificate fixtures retained through one parser run."""

    certificate: BoundConfigInput
    key: BoundConfigInput
    workspace: Path
    workspace_descriptor: int
    owns_workspace_descriptor: bool = False

    @property
    def inputs(self) -> tuple[BoundConfigInput, BoundConfigInput]:
        return (self.certificate, self.key)

    @property
    def descriptors(self) -> tuple[int, int]:
        return (self.certificate.descriptor, self.key.descriptor)

    def __getitem__(self, field: str) -> Path:
        if field in {"cert_file", "ca_file"}:
            return Path(self.certificate.path)
        if field == "key_file":
            return Path(self.key.path)
        raise KeyError(field)

    def verify(self) -> None:
        _verify_private_directory(
            self.workspace,
            self.workspace_descriptor,
            require_empty=True,
        )
        for bound in self.inputs:
            bound.verify()

    def close(self) -> None:
        actions: list[Callable[[], None]] = [
            self.certificate.close,
            self.key.close,
        ]
        if self.owns_workspace_descriptor:
            actions.append(lambda: os.close(self.workspace_descriptor))
        _run_cleanup_actions(*actions)


# Validation toolchain only: this does not select or mutate a deployed broker.
# Keep the default parser at the exact version used by the current canonical
# configuration-validation CI lane. A proposed broker upgrade must use a
# separate, explicit compatibility lane until its governing ADR is accepted and
# that validation pin changes.
_NATS_SERVER_VERSION = "2.10.22"
_PARSER_RELEASES = {
    ("linux", "x86_64"): ParserRelease(
        url=(
            "https://github.com/nats-io/nats-server/releases/download/"
            "v2.10.22/nats-server-v2.10.22-linux-amd64.tar.gz"
        ),
        member="nats-server-v2.10.22-linux-amd64/nats-server",
        sha256="db0b3ccbe4cbdd3872ae7486ec4f6b0f85824632a0789f4da2e0a8518390483e",
    ),
    ("linux", "aarch64"): ParserRelease(
        url=(
            "https://github.com/nats-io/nats-server/releases/download/"
            "v2.10.22/nats-server-v2.10.22-linux-arm64.tar.gz"
        ),
        member="nats-server-v2.10.22-linux-arm64/nats-server",
        sha256="b4da77b2b194dc5fcf13a1df0dad59ba7e87ae4423f254c50534015b7c8a2369",
    ),
    ("darwin", "x86_64"): ParserRelease(
        url=(
            "https://github.com/nats-io/nats-server/releases/download/"
            "v2.10.22/nats-server-v2.10.22-darwin-amd64.tar.gz"
        ),
        member="nats-server-v2.10.22-darwin-amd64/nats-server",
        sha256="e99eb01a886b5de05972445e362e48cf8ad10b45e4cd5a5592475b184f8f81c9",
    ),
    ("darwin", "arm64"): ParserRelease(
        url=(
            "https://github.com/nats-io/nats-server/releases/download/"
            "v2.10.22/nats-server-v2.10.22-darwin-arm64.tar.gz"
        ),
        member="nats-server-v2.10.22-darwin-arm64/nats-server",
        sha256="93ce74f61a49d8fa9dfbf420e5a844e25309e429c5c8e27b54b3283d0712fcff",
    ),
}
_PARSER_DOWNLOAD_HOSTS = frozenset(
    {
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    }
)


class ConfigStructureError(ValueError):
    """Report a lexical or delimiter error in a NATS config."""


class DeferredSignal(BaseException):
    def __init__(self, signal_number: int) -> None:
        self.signal_number = signal_number


class DownloadTimedOut(TimeoutError):
    """The single end-to-end parser download deadline expired."""


@contextmanager
def _deferred_termination() -> Iterator[None]:
    """Defer TERM/HUP until owned children and files have been cleaned up."""
    caught: int | None = None
    previous: dict[int, signal.Handlers] = {}

    def handle(signal_number: int, _frame: object) -> None:
        nonlocal caught
        if caught is None:
            caught = signal_number
            raise DeferredSignal(signal_number)

    for signal_number in (signal.SIGTERM, signal.SIGHUP):
        previous[signal_number] = signal.getsignal(signal_number)
        signal.signal(signal_number, handle)
    try:
        yield
    except DeferredSignal as cancellation:
        caught = cancellation.signal_number
    finally:
        for signal_number, handler in previous.items():
            signal.signal(signal_number, handler)
    if caught is not None:
        signal.raise_signal(caught)
        raise SystemExit(128 + caught)


@contextmanager
def _download_deadline(seconds: float) -> Iterator[float]:
    """Interrupt a blocking URL operation at one monotonic POSIX deadline."""
    deadline = time.monotonic() + seconds
    installed = False
    previous_handler: signal.Handlers | None = None
    if not hasattr(signal, "setitimer"):
        raise RuntimeError("a monotonic parser download deadline is unavailable")
    try:
        current_timer = signal.getitimer(signal.ITIMER_REAL)
        if current_timer[0] != 0:
            raise RuntimeError("an exclusive parser download deadline is unavailable")
        previous_handler = signal.getsignal(signal.SIGALRM)

        def expire(_signal_number: int, _frame: object) -> None:
            raise DownloadTimedOut("nats-server download timed out")

        signal.signal(signal.SIGALRM, expire)
        signal.setitimer(signal.ITIMER_REAL, seconds)
        installed = True
    except ValueError as exc:
        raise RuntimeError(
            "the parser download deadline requires the main POSIX thread"
        ) from exc
    try:
        yield deadline
    finally:
        if installed:
            signal.setitimer(signal.ITIMER_REAL, 0)
            assert previous_handler is not None
            signal.signal(signal.SIGALRM, previous_handler)


def _read_config(path: Path) -> str:
    source = BoundConfigSource.open(path)
    try:
        return source.text
    finally:
        source.close()


def _tokenize(text: str) -> list[Token]:
    tokens: list[Token] = []
    stack: list[tuple[str, int]] = []
    line = 1
    index = 0

    while index < len(text):
        char = text[index]
        if char == "\n":
            line += 1
            index += 1
            continue
        if char.isspace():
            index += 1
            continue
        if char == "#" or text.startswith("//", index):
            newline = text.find("\n", index)
            if newline < 0:
                break
            index = newline
            continue
        if char in "'\"":
            quote = char
            start_line = line
            value: list[str] = []
            index += 1
            while index < len(text):
                char = text[index]
                if char == "\n":
                    line += 1
                if char == "\\":
                    if index + 1 >= len(text):
                        raise ConfigStructureError(
                            f"unterminated escape in string on line {start_line}"
                        )
                    value.append(text[index + 1])
                    index += 2
                    continue
                if char == quote:
                    index += 1
                    tokens.append(Token("string", "".join(value), start_line))
                    break
                value.append(char)
                index += 1
            else:
                raise ConfigStructureError(f"unterminated string on line {start_line}")
            continue
        if char in "{}[]()=:,;":
            if char in _OPEN_TO_CLOSE:
                stack.append((char, line))
            elif char in _CLOSE_TO_OPEN:
                if not stack or stack[-1][0] != _CLOSE_TO_OPEN[char]:
                    raise ConfigStructureError(f"unmatched {char} on line {line}")
                stack.pop()
            tokens.append(Token("symbol", char, line))
            index += 1
            continue

        start = index
        while index < len(text):
            char = text[index]
            if char.isspace() or char in "{}[]()=:,;'\"#":
                break
            if text.startswith("//", index):
                break
            index += 1
        if index == start:
            raise ConfigStructureError(
                f"unsupported character {text[index]!r} on line {line}"
            )
        tokens.append(Token("atom", text[start:index], line))

    if stack:
        opener, opener_line = stack[-1]
        raise ConfigStructureError(f"unclosed {opener} from line {opener_line}")
    return tokens


def delimiter_precheck(text: str) -> tuple[bool, str]:
    """Check strings and delimiters without claiming full NATS syntax."""

    try:
        _tokenize(text)
    except ConfigStructureError as exc:
        return False, str(exc)
    return True, "delimiter precheck passed; full NATS syntax is unverified"


def check(text: str) -> tuple[bool, str]:
    """Compatibility alias for the delimiter precheck."""

    return delimiter_precheck(text)


def _delimiter_pairs(tokens: Sequence[Token]) -> dict[int, int]:
    pairs: dict[int, int] = {}
    stack: list[int] = []
    for index, token in enumerate(tokens):
        if token.kind != "symbol":
            continue
        if token.value in _OPEN_TO_CLOSE:
            stack.append(index)
        elif token.value in _CLOSE_TO_OPEN:
            opener = stack.pop()
            pairs[opener] = index
            pairs[index] = opener
    return pairs


def _direct_entries(
    tokens: Sequence[Token], pairs: dict[int, int], start: int, end: int
) -> list[Entry]:
    entries: list[Entry] = []
    index = start
    while index < end:
        token = tokens[index]
        if token.kind != "atom":
            if token.kind == "symbol" and token.value in _OPEN_TO_CLOSE:
                index = pairs[index] + 1
            else:
                index += 1
            continue

        value_index = index + 1
        if (value_index < end and tokens[value_index].kind == "symbol"
                and tokens[value_index].value in ("=", ":")):
            value_index += 1
        if value_index >= end:
            index += 1
            continue

        value_token = tokens[value_index]
        if value_token.kind == "symbol" and value_token.value in _OPEN_TO_CLOSE:
            value_end = pairs[value_index]
            entries.append(
                Entry(token.value, value_index + 1, value_end, value_token.value)
            )
            index = value_end + 1
            continue
        if value_token.kind in ("atom", "string"):
            entries.append(Entry(token.value, value_index, value_index + 1, None))
            index = value_index + 1
            continue
        index += 1
    return entries


def _named(entries: Iterable[Entry], name: str) -> list[Entry]:
    folded_name = name.casefold()
    return [entry for entry in entries if entry.name.casefold() == folded_name]


def _alias_entries(entries: Iterable[Entry], names: Iterable[str]) -> list[Entry]:
    folded_names = {name.casefold() for name in names}
    return [entry for entry in entries if entry.name.casefold() in folded_names]


def _scalar_value(tokens: Sequence[Token], entry: Entry) -> str | None:
    if entry.container is not None or entry.value_start >= entry.value_end:
        return None
    return tokens[entry.value_start].value.strip()


def _literal_or_external(
    tokens: Sequence[Token],
    entry: Entry,
    allowed_environment: frozenset[str],
    local_names: set[str],
) -> bool:
    value = _scalar_value(tokens, entry)
    if value is None or not value or value.casefold() in {"null", "none"}:
        return False
    reference = _ENV_REFERENCE.fullmatch(value)
    if reference is not None:
        name = reference.group(1)
        return name in allowed_environment and name not in local_names
    return "$" not in value


def _scope_entries(
    tokens: Sequence[Token], pairs: dict[int, int], entry: Entry
) -> list[Entry]:
    if entry.container != "{":
        return []
    return _direct_entries(tokens, pairs, entry.value_start, entry.value_end)


def _list_maps(
    tokens: Sequence[Token], pairs: dict[int, int], entry: Entry
) -> list[Entry]:
    if entry.container != "[":
        return []
    result: list[Entry] = []
    index = entry.value_start
    while index < entry.value_end:
        if tokens[index].value == "{":
            result.append(Entry("item", index + 1, pairs[index], "{"))
            index = pairs[index] + 1
        elif tokens[index].value in {",", ";"}:
            index += 1
        else:
            return []
    return result


def _list_scalars(tokens: Sequence[Token], entry: Entry) -> list[str] | None:
    if entry.container != "[":
        return None
    values: list[str] = []
    for index in range(entry.value_start, entry.value_end):
        token = tokens[index]
        if token.kind in {"atom", "string"}:
            values.append(token.value.strip())
        elif token.value not in {",", ";"}:
            return None
    return values


def _root_scalar_names(entries: Iterable[Entry]) -> set[str]:
    return {entry.name for entry in entries if entry.container is None}


def _contains_directive(tokens: Sequence[Token], name: str) -> bool:
    folded_name = name.casefold()
    return any(
        token.kind == "atom" and token.value.casefold() == folded_name
        for token in tokens
    )


def _user_record_valid(
    tokens: Sequence[Token],
    pairs: dict[int, int],
    entry: Entry,
    *,
    scope: str,
    local_names: set[str],
    allow_certificate_identity: bool,
) -> bool:
    fields = _scope_entries(tokens, pairs, entry)
    users = _alias_entries(fields, {"user", "username"})
    passwords = _alias_entries(fields, {"password", "pass"})
    nkeys = _named(fields, "nkey")
    if len(users) > 1 or len(passwords) > 1 or len(nkeys) > 1:
        return False

    environments = _AUTH_ENVIRONMENTS[scope]
    user_valid = len(users) == 1 and _literal_or_external(
        tokens, users[0], environments["user"], local_names
    )
    password_valid = len(passwords) == 1 and _literal_or_external(
        tokens, passwords[0], environments["password"], local_names
    )
    nkey_valid = (
        "nkey" in environments
        and len(nkeys) == 1
        and _literal_or_external(tokens, nkeys[0], environments["nkey"], local_names)
    )
    if nkeys:
        return nkey_valid and not users and not passwords
    if not users:
        return False
    if passwords:
        return user_valid and password_valid
    return user_valid and allow_certificate_identity


def _user_list_valid(
    tokens: Sequence[Token],
    pairs: dict[int, int],
    entry: Entry,
    *,
    scope: str,
    local_names: set[str],
    allow_certificate_identity: bool = False,
) -> bool:
    users = _list_maps(tokens, pairs, entry)
    if not users:
        return False
    return all(
        _user_record_valid(
            tokens,
            pairs,
            user,
            scope=scope,
            local_names=local_names,
            allow_certificate_identity=allow_certificate_identity,
        )
        for user in users
    )


def _credential_block_valid(
    tokens: Sequence[Token],
    pairs: dict[int, int],
    entry: Entry,
    *,
    scope: str,
    local_names: set[str],
) -> bool:
    fields = _scope_entries(tokens, pairs, entry)
    tokens_entries = _named(fields, "token")
    users_entries = _named(fields, "users")
    users = _alias_entries(fields, {"user", "username"})
    passwords = _alias_entries(fields, {"password", "pass"})
    unsupported = _alias_entries(fields, {"credentials", "creds", "nkey", "seed"})
    if (
        len(tokens_entries) > 1
        or len(users_entries) > 1
        or len(users) > 1
        or len(passwords) > 1
        or unsupported
    ):
        return False

    declared_mechanisms = sum(
        (bool(tokens_entries), bool(users_entries), bool(users or passwords))
    )
    if declared_mechanisms != 1:
        return False

    environments = _AUTH_ENVIRONMENTS[scope]
    if tokens_entries:
        return scope == "client" and _literal_or_external(
            tokens,
            tokens_entries[0],
            environments["token"],
            local_names,
        )
    if users_entries:
        return scope != "cluster" and _user_list_valid(
            tokens,
            pairs,
            users_entries[0],
            scope=scope,
            local_names=local_names,
        )
    return (
        len(users) == 1
        and len(passwords) == 1
        and _literal_or_external(tokens, users[0], environments["user"], local_names)
        and _literal_or_external(
            tokens, passwords[0], environments["password"], local_names
        )
    )


def _top_level_verify_and_map(
    tokens: Sequence[Token], pairs: dict[int, int], root: Sequence[Entry]
) -> bool:
    tls_entries = _named(root, "tls")
    if len(tls_entries) != 1:
        return False
    fields = _scope_entries(tokens, pairs, tls_entries[0])
    verify_entries = _named(fields, "verify_and_map")
    return (
        len(verify_entries) == 1
        and (_scalar_value(tokens, verify_entries[0]) or "").casefold() == "true"
    )


def _accounts_valid(
    tokens: Sequence[Token],
    pairs: dict[int, int],
    entry: Entry,
    *,
    root: Sequence[Entry],
    local_names: set[str],
) -> tuple[bool, bool]:
    accounts = _scope_entries(tokens, pairs, entry)
    if not accounts or any(account.container != "{" for account in accounts):
        return False, False
    account_names = [account.name.casefold() for account in accounts]
    if len(account_names) != len(set(account_names)):
        return False, False

    system_entries = _named(root, "system_account")
    if len(system_entries) > 1:
        return False, False
    system_name: str | None = None
    if system_entries:
        system_name = _scalar_value(tokens, system_entries[0])
        if not system_name or system_name.casefold() not in set(account_names):
            return False, False

    certificate_identity = _top_level_verify_and_map(tokens, pairs, root)
    client_auth = False
    for account in accounts:
        fields = _scope_entries(tokens, pairs, account)
        users_entries = _named(fields, "users")
        if len(users_entries) > 1:
            return False, False
        if not users_entries:
            continue
        if not _user_list_valid(
            tokens,
            pairs,
            users_entries[0],
            scope="account",
            local_names=local_names,
            allow_certificate_identity=certificate_identity,
        ):
            return False, False
        if system_name is None or account.name.casefold() != system_name.casefold():
            client_auth = True
    return True, client_auth


def _listener_auth_valid(
    tokens: Sequence[Token],
    pairs: dict[int, int],
    listener: Entry,
    *,
    scope: str,
    local_names: set[str],
) -> bool:
    fields = _scope_entries(tokens, pairs, listener)
    authorization = _named(fields, "authorization")
    return len(authorization) == 1 and _credential_block_valid(
        tokens,
        pairs,
        authorization[0],
        scope=scope,
        local_names=local_names,
    )


def _remote_maps(
    tokens: Sequence[Token], pairs: dict[int, int], remotes: Entry
) -> list[Entry]:
    return _list_maps(tokens, pairs, remotes)


def _remote_auth_valid(
    tokens: Sequence[Token],
    pairs: dict[int, int],
    remote: Entry,
    *,
    local_names: set[str],
) -> bool:
    fields = _scope_entries(tokens, pairs, remote)
    urls = _alias_entries(fields, {"url", "urls"})
    credentials = _alias_entries(fields, {"credentials", "creds"})
    nkeys = _alias_entries(fields, {"nkey", "seed"})
    routing_accounts = _alias_entries(fields, {"account", "local"})
    tokens_entries = _named(fields, "token")
    direct_user_fields = _alias_entries(
        fields, {"user", "username", "password", "pass"}
    )
    if (
        len(urls) != 1
        or len(credentials) > 1
        or len(nkeys) > 1
        or len(routing_accounts) > 1
        or tokens_entries
        or direct_user_fields
    ):
        return False

    url_values: list[str]
    scalar_url = _scalar_value(tokens, urls[0])
    if scalar_url is not None:
        url_values = [scalar_url]
    else:
        listed_urls = _list_scalars(tokens, urls[0])
        if listed_urls is None:
            return False
        url_values = listed_urls
    if not url_values:
        return False

    embedded_credentials = True
    for value in url_values:
        reference = _ENV_REFERENCE.fullmatch(value)
        if reference is not None:
            if (
                reference.group(1) not in _REMOTE_ENVIRONMENTS["url"]
                or reference.group(1) in local_names
            ):
                return False
            embedded_credentials = False
            continue
        if "$" in value:
            return False
        try:
            parsed = urlsplit(value)
            if not parsed.scheme or not parsed.hostname:
                return False
        except ValueError:
            return False
        username = parsed.username or ""
        password = parsed.password
        if not username or (password is not None and not password):
            embedded_credentials = False

    credential_file = bool(credentials) and _literal_or_external(
        tokens,
        credentials[0],
        _REMOTE_ENVIRONMENTS["credentials"],
        local_names,
    )
    nkey = bool(nkeys) and _literal_or_external(
        tokens,
        nkeys[0],
        _REMOTE_ENVIRONMENTS["nkey"],
        local_names,
    )
    declared_mechanisms = sum((embedded_credentials, bool(credentials), bool(nkeys)))
    return declared_mechanisms == 1 and (
        embedded_credentials or credential_file or nkey
    )


def _parse_auth_source(source: BoundConfigSource) -> tuple[list[Token], dict[int, int]]:
    text = source.text
    if not text.strip():
        raise ConfigStructureError(f"{source.path} is empty")
    tokens = _tokenize(text)
    return tokens, _delimiter_pairs(tokens)


def _validate_leaf_auth(
    leaf_path: Path,
    leaf_tokens: list[Token],
    leaf_pairs: dict[int, int],
) -> list[str]:
    errors: list[str] = []
    root = _direct_entries(leaf_tokens, leaf_pairs, 0, len(leaf_tokens))
    local_names = _root_scalar_names(root)
    if _contains_directive(leaf_tokens, "include"):
        errors.append(f"{leaf_path} contains an uninspected include directive")
    leafnodes = _named(root, "leafnodes")
    remotes: list[Entry] = []
    if len(leafnodes) != 1:
        errors.append(f"{leaf_path} must have exactly one leafnodes block")
    else:
        leaf_fields = _scope_entries(leaf_tokens, leaf_pairs, leafnodes[0])
        remotes_entries = _named(leaf_fields, "remotes")
        if len(remotes_entries) == 1:
            remotes = _remote_maps(leaf_tokens, leaf_pairs, remotes_entries[0])
    if len(leafnodes) == 1 and not remotes:
        errors.append(f"{leaf_path} has no leafnode remotes")
    elif remotes and not all(
        _remote_auth_valid(
            leaf_tokens,
            leaf_pairs,
            remote,
            local_names=local_names,
        )
        for remote in remotes
    ):
        errors.append(
            f"{leaf_path} has an ambiguous, unsupported, or unauthenticated remote"
        )
    return errors


def _validate_server_auth(
    server_path: Path,
    server_tokens: list[Token],
    server_pairs: dict[int, int],
) -> list[str]:
    errors: list[str] = []
    root = _direct_entries(server_tokens, server_pairs, 0, len(server_tokens))
    local_names = _root_scalar_names(root)
    if _contains_directive(server_tokens, "include"):
        errors.append(f"{server_path} contains an uninspected include directive")
    if _contains_directive(server_tokens, "no_auth_user"):
        errors.append(f"{server_path} declares no_auth_user")

    repeated_names = [
        name
        for name in ("authorization", "leafnodes", "cluster", "accounts", "operator")
        if len(_named(root, name)) > 1
    ]
    if repeated_names:
        errors.append(
            f"{server_path} repeats security-sensitive root fields: "
            + ", ".join(repeated_names)
        )

    authorization = _named(root, "authorization")
    top_auth = len(authorization) == 1 and _credential_block_valid(
        server_tokens,
        server_pairs,
        authorization[0],
        scope="client",
        local_names=local_names,
    )
    if authorization and not top_auth:
        errors.append(f"{server_path} has invalid or ambiguous client authorization")

    account_entries = _named(root, "accounts")
    accounts_valid = True
    account_auth = False
    if len(account_entries) == 1:
        accounts_valid, account_auth = _accounts_valid(
            server_tokens,
            server_pairs,
            account_entries[0],
            root=root,
            local_names=local_names,
        )
        if not accounts_valid:
            errors.append(f"{server_path} has invalid or ambiguous accounts")

    operator_entries = _named(root, "operator")
    operator_auth = len(operator_entries) == 1 and _literal_or_external(
        server_tokens,
        operator_entries[0],
        frozenset({"NATS_OPERATOR_JWT"}),
        local_names,
    )
    if operator_entries and not operator_auth:
        errors.append(f"{server_path} has invalid or ambiguous operator auth")

    if not (top_auth or account_auth or operator_auth):
        errors.append(f"{server_path} has no valid client authorization declaration")

    leaf_listeners = _named(root, "leafnodes")
    if len(leaf_listeners) != 1 or not _listener_auth_valid(
        server_tokens,
        server_pairs,
        leaf_listeners[0],
        scope="leaf",
        local_names=local_names,
    ):
        errors.append(
            f"{server_path} leafnodes listener has no valid direct authorization"
        )

    clusters = _named(root, "cluster")
    if len(clusters) == 1 and not _listener_auth_valid(
        server_tokens,
        server_pairs,
        clusters[0],
        scope="cluster",
        local_names=local_names,
    ):
        errors.append(
            f"{server_path} cluster listener has no valid direct authorization"
        )
    return errors


def validate_auth(leaf_path: Path, server_path: Path) -> list[str]:
    """Return authentication failures after exact-source revalidation."""

    errors: list[str] = []
    sources: list[BoundConfigSource] = []
    try:
        try:
            leaf_source = BoundConfigSource.open(leaf_path)
            sources.append(leaf_source)
            leaf_tokens, leaf_pairs = _parse_auth_source(leaf_source)
        except ConfigStructureError as exc:
            errors.append(str(exc))
        else:
            errors.extend(_validate_leaf_auth(leaf_path, leaf_tokens, leaf_pairs))

        try:
            server_source = BoundConfigSource.open(server_path)
            sources.append(server_source)
            server_tokens, server_pairs = _parse_auth_source(server_source)
        except ConfigStructureError as exc:
            errors.append(str(exc))
        else:
            errors.extend(
                _validate_server_auth(server_path, server_tokens, server_pairs)
            )

        for source in sources:
            try:
                source.verify()
            except ConfigStructureError as exc:
                errors.append(str(exc))
        return errors
    finally:
        _run_cleanup_actions(*(source.close for source in reversed(sources)))


def _same_object(left: os.stat_result, right: os.stat_result) -> bool:
    return left.st_dev == right.st_dev and left.st_ino == right.st_ino


def _rename_noreplace(directory: int, source: str, destination: str) -> None:
    """Atomically rename one direct entry without replacing another entry."""
    library = ctypes.CDLL(None, use_errno=True)
    source_bytes = os.fsencode(source)
    destination_bytes = os.fsencode(destination)
    if sys.platform.startswith("linux") and hasattr(library, "renameat2"):
        operation = library.renameat2
        operation.argtypes = (
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        )
        operation.restype = ctypes.c_int
        result = operation(
            directory,
            source_bytes,
            directory,
            destination_bytes,
            1,
        )
    elif hasattr(library, "renameatx_np"):
        operation = library.renameatx_np
        operation.argtypes = (
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        )
        operation.restype = ctypes.c_int
        result = operation(
            directory,
            source_bytes,
            directory,
            destination_bytes,
            0x00000004,
        )
    else:
        raise RuntimeError("atomic no-replace cleanup is unavailable")
    if result != 0:
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number), source)


def _restore_quarantined_entry(
    directory: int,
    quarantine: str,
    original: str,
) -> None:
    """Restore an entry moved before its identity could be established."""
    try:
        _rename_noreplace(directory, quarantine, original)
    except FileExistsError:
        return
    os.fsync(directory)


def _quarantine_owned_entry(
    directory: int,
    name: str,
    expected: os.stat_result,
    *,
    is_directory: bool = False,
) -> bool:
    """Retain a regular file so inode reuse cannot redirect cleanup."""
    if is_directory:
        return _quarantine_bound_entry(directory, name, expected, is_directory=True)
    try:
        descriptor = os.open(
            name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK,
            dir_fd=directory,
        )
    except FileNotFoundError:
        return False
    except OSError as error:
        if error.errno == errno.ELOOP:
            return False
        raise
    try:
        if not _same_file_state(expected, os.fstat(descriptor)):
            return False
        return _quarantine_bound_entry(directory, name, expected)
    finally:
        os.close(descriptor)


def _quarantine_bound_entry(
    directory: int,
    name: str,
    expected: os.stat_result,
    *,
    is_directory: bool = False,
) -> bool:
    """Atomically isolate and delete only the exact expected direct entry."""
    quarantine = ".odysseus-cleanup-" + secrets.token_hex(16)
    try:
        _rename_noreplace(directory, name, quarantine)
    except FileNotFoundError:
        return False
    moved = os.stat(quarantine, dir_fd=directory, follow_symlinks=False)
    if not _same_object(expected, moved):
        _restore_quarantined_entry(directory, quarantine, name)
        return False
    try:
        if is_directory:
            flags = (
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0)
            )
            descriptor = os.open(quarantine, flags, dir_fd=directory)
            try:
                opened = os.fstat(descriptor)
                if (
                    not stat.S_ISDIR(opened.st_mode)
                    or not _same_object(expected, opened)
                    or os.listdir(descriptor)
                ):
                    _restore_quarantined_entry(directory, quarantine, name)
                    return False
                os.rmdir(quarantine, dir_fd=directory)
            except BaseException:
                try:
                    _restore_quarantined_entry(directory, quarantine, name)
                finally:
                    try:
                        os.close(descriptor)
                    except BaseException:
                        pass
                raise
            else:
                os.close(descriptor)
        else:
            terminal = os.stat(quarantine, dir_fd=directory, follow_symlinks=False)
            if (
                not stat.S_ISREG(terminal.st_mode)
                or not _same_object(expected, terminal)
                or terminal.st_uid != os.geteuid()
                or terminal.st_nlink != 1
            ):
                _restore_quarantined_entry(directory, quarantine, name)
                return False
            os.unlink(quarantine, dir_fd=directory)
        os.fsync(directory)
        return True
    except BaseException:
        try:
            _restore_quarantined_entry(directory, quarantine, name)
        except (FileExistsError, FileNotFoundError):
            pass
        raise


def _same_file_state(left: os.stat_result, right: os.stat_result) -> bool:
    fields = (
        "st_dev",
        "st_ino",
        "st_nlink",
        "st_uid",
        "st_gid",
        "st_mode",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    return all(getattr(left, field) == getattr(right, field) for field in fields)


def _same_directory_state(left: os.stat_result, right: os.stat_result) -> bool:
    """Compare security-relevant directory identity without volatile contents."""
    fields = ("st_dev", "st_ino", "st_uid", "st_gid", "st_mode")
    return all(getattr(left, field) == getattr(right, field) for field in fields)


@dataclass(frozen=True)
class _ConfigDirectoryLink:
    parent_descriptor: int
    name: str
    child_descriptor: int
    state: os.stat_result


@dataclass(frozen=True)
class _ConfigLexicalLink:
    path: Path
    state: os.stat_result


@dataclass
class BoundConfigSource:
    """One exact config and its retained lexical directory route."""

    path: Path
    descriptor: int
    state: os.stat_result
    content: bytes
    directory_descriptors: list[int]
    links: list[_ConfigDirectoryLink]
    lexical_links: list[_ConfigLexicalLink]
    root_state: os.stat_result

    @classmethod
    def open(cls, path: Path) -> BoundConfigSource:
        required = ("O_CLOEXEC", "O_DIRECTORY", "O_NOFOLLOW", "O_NONBLOCK")
        missing = [name for name in required if not hasattr(os, name)]
        if missing:
            raise ConfigStructureError(
                "safe NATS config opening is unavailable: " + ", ".join(missing)
            )
        requested = Path(os.path.abspath(path))
        if not requested.name or requested.name in {".", ".."}:
            raise ConfigStructureError(f"{path} has an invalid file name")
        try:
            lexical_links: list[_ConfigLexicalLink] = []
            lexical_path = Path(os.path.sep)
            for component in requested.parent.parts[1:]:
                lexical_path /= component
                link_state = os.lstat(lexical_path)
                if not (
                    stat.S_ISDIR(link_state.st_mode)
                    or stat.S_ISLNK(link_state.st_mode)
                ):
                    raise ConfigStructureError(
                        f"{path} has a non-directory parent route component"
                    )
                lexical_links.append(
                    _ConfigLexicalLink(lexical_path, link_state)
                )
            absolute = requested.parent.resolve(strict=True) / requested.name
        except OSError as error:
            raise ConfigStructureError(
                f"{path} has an unavailable parent route: {error}"
            ) from error
        directory_flags = (
            os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW
        )
        file_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
        directories: list[int] = []
        links: list[_ConfigDirectoryLink] = []
        descriptor = -1
        try:
            current = os.open(os.path.sep, directory_flags)
            directories.append(current)
            root_state = os.fstat(current)
            if not stat.S_ISDIR(root_state.st_mode):
                raise ConfigStructureError("the filesystem root is not a directory")
            for component in absolute.parent.parts[1:]:
                child = os.open(component, directory_flags, dir_fd=current)
                child_state = os.fstat(child)
                if not stat.S_ISDIR(child_state.st_mode):
                    os.close(child)
                    raise ConfigStructureError(
                        f"{path} has a non-directory route component"
                    )
                links.append(
                    _ConfigDirectoryLink(
                        current,
                        component,
                        child,
                        child_state,
                    )
                )
                directories.append(child)
                current = child
            descriptor = os.open(absolute.name, file_flags, dir_fd=current)
            opened = os.fstat(descriptor)
            if (
                not stat.S_ISREG(opened.st_mode)
                or opened.st_uid != os.geteuid()
                or opened.st_nlink != 1
            ):
                raise ConfigStructureError(
                    f"{path} must be an owner-bound singly linked regular "
                    "non-symlink file"
                )
            if opened.st_size > MAX_CONFIG_BYTES:
                raise ConfigStructureError(
                    f"{path} exceeds the {MAX_CONFIG_BYTES}-byte limit"
                )
            content = bytearray()
            while len(content) <= MAX_CONFIG_BYTES:
                chunk = os.read(
                    descriptor,
                    min(65_536, MAX_CONFIG_BYTES + 1 - len(content)),
                )
                if not chunk:
                    break
                content.extend(chunk)
            if len(content) > MAX_CONFIG_BYTES:
                raise ConfigStructureError(
                    f"{path} exceeds the {MAX_CONFIG_BYTES}-byte limit"
                )
            after = os.fstat(descriptor)
            named = os.stat(
                absolute.name,
                dir_fd=current,
                follow_symlinks=False,
            )
            if (
                not stat.S_ISREG(named.st_mode)
                or named.st_uid != os.geteuid()
                or named.st_nlink != 1
                or not _same_file_state(opened, after)
                or not _same_file_state(after, named)
            ):
                raise ConfigStructureError(f"{path} changed while it was read")
            bound = cls(
                path=requested,
                descriptor=descriptor,
                state=after,
                content=bytes(content),
                directory_descriptors=directories,
                links=links,
                lexical_links=lexical_links,
                root_state=root_state,
            )
            bound.verify()
            descriptor = -1
            directories = []
            return bound
        except ConfigStructureError:
            raise
        except OSError as error:
            raise ConfigStructureError(
                f"{path} must be a readable regular non-symlink file: {error}"
            ) from error
        finally:
            actions: list[Callable[[], None]] = []
            if descriptor >= 0:
                actions.append(lambda: os.close(descriptor))
            actions.extend(
                lambda item=item: os.close(item) for item in reversed(directories)
            )
            _run_cleanup_actions(*actions)

    @property
    def text(self) -> str:
        try:
            return self.content.decode("utf-8")
        except UnicodeDecodeError as error:
            raise ConfigStructureError(
                f"{self.path} is not valid UTF-8: {error}"
            ) from error

    def verify(self) -> None:
        """Revalidate the descriptor, bytes, dentry, and lexical parent route."""
        try:
            parent = self.directory_descriptors[-1]

            def read_content() -> bytes:
                observed = bytearray()
                offset = 0
                while len(observed) <= MAX_CONFIG_BYTES:
                    chunk = os.pread(
                        self.descriptor,
                        min(65_536, MAX_CONFIG_BYTES + 1 - len(observed)),
                        offset,
                    )
                    if not chunk:
                        break
                    observed.extend(chunk)
                    offset += len(chunk)
                if len(observed) > MAX_CONFIG_BYTES:
                    raise ConfigStructureError(
                        f"{self.path} changed during validation"
                    )
                return bytes(observed)

            def verify_route() -> None:
                if not _same_directory_state(
                    self.root_state,
                    os.fstat(self.directory_descriptors[0]),
                ):
                    raise ConfigStructureError(
                        f"{self.path} parent route changed during validation"
                    )
                for link in self.lexical_links:
                    direct = os.lstat(link.path)
                    if not _same_directory_state(link.state, direct):
                        raise ConfigStructureError(
                            f"{self.path} parent route changed during validation"
                        )
                for link in self.links:
                    direct = os.stat(
                        link.name,
                        dir_fd=link.parent_descriptor,
                        follow_symlinks=False,
                    )
                    opened = os.fstat(link.child_descriptor)
                    if (
                        not stat.S_ISDIR(direct.st_mode)
                        or not _same_directory_state(link.state, direct)
                        or not _same_directory_state(link.state, opened)
                    ):
                        raise ConfigStructureError(
                            f"{self.path} parent route changed during validation"
                        )

            current = os.fstat(self.descriptor)
            named = os.stat(
                self.path.name,
                dir_fd=parent,
                follow_symlinks=False,
            )
            first_observation = read_content()
            after_first_read = os.fstat(self.descriptor)
            second_observation = read_content()
            after_second_read = os.fstat(self.descriptor)
            final_named = os.stat(
                self.path.name,
                dir_fd=parent,
                follow_symlinks=False,
            )
            if (
                not stat.S_ISREG(current.st_mode)
                or current.st_uid != os.geteuid()
                or current.st_nlink != 1
                or not _same_file_state(self.state, current)
                or not _same_file_state(current, named)
                or not _same_file_state(current, after_first_read)
                or not _same_file_state(after_first_read, after_second_read)
                or not _same_file_state(after_second_read, final_named)
                or not hmac.compare_digest(first_observation, self.content)
                or not hmac.compare_digest(second_observation, self.content)
            ):
                raise ConfigStructureError(
                    f"{self.path} changed during validation"
                )
            verify_route()
            terminal = os.fstat(self.descriptor)
            terminal_named = os.stat(
                self.path.name,
                dir_fd=parent,
                follow_symlinks=False,
            )
            if (
                not _same_file_state(after_second_read, terminal)
                or not _same_file_state(terminal, terminal_named)
            ):
                raise ConfigStructureError(
                    f"{self.path} changed during validation"
                )
            verify_route()
        except ConfigStructureError:
            raise
        except OSError as error:
            raise ConfigStructureError(
                f"{self.path} changed during validation: {error}"
            ) from error

    def close(self) -> None:
        actions: list[Callable[[], None]] = []
        if self.descriptor >= 0:
            descriptor = self.descriptor
            self.descriptor = -1
            actions.append(lambda: os.close(descriptor))
        directories = list(reversed(self.directory_descriptors))
        self.directory_descriptors.clear()
        self.links.clear()
        self.lexical_links.clear()
        actions.extend(lambda item=item: os.close(item) for item in directories)
        _run_cleanup_actions(*actions)


def _read_executable_digest(descriptor: int, label: str) -> tuple[bytes, int]:
    """Hash one executable stream without reading beyond its byte ceiling."""
    digest = hashlib.sha256()
    total = 0
    os.lseek(descriptor, 0, os.SEEK_SET)
    while total <= MAX_PARSER_BINARY_BYTES:
        chunk = os.read(
            descriptor,
            min(1024 * 1024, MAX_PARSER_BINARY_BYTES + 1 - total),
        )
        if not chunk:
            break
        total += len(chunk)
        if total > MAX_PARSER_BINARY_BYTES:
            raise RuntimeError(f"{label} exceeds the executable size limit")
        digest.update(chunk)
    os.lseek(descriptor, 0, os.SEEK_SET)
    return digest.digest(), total


def _directory_path_matches(descriptor: int, path: str | Path) -> bool:
    try:
        current = os.stat(path, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return stat.S_ISDIR(current.st_mode) and _same_object(
        current, os.fstat(descriptor)
    )


def _cleanup_private_snapshot(
    directory: int,
    path: str | Path,
    name: str,
    created: os.stat_result | None,
    *,
    parent_descriptor: int = -1,
    directory_name: str = "",
    directory_state: os.stat_result | None = None,
) -> None:
    """Remove owned snapshot entries without deleting replacement objects."""
    del path

    def restore_directory_mode() -> None:
        os.fchmod(directory, 0o700)

    def remove_owned_leaf() -> None:
        if created is not None:
            _quarantine_owned_entry(directory, name, created)

    _run_cleanup_actions(
        restore_directory_mode,
        remove_owned_leaf,
    )


def _executable_for_current_user(metadata: os.stat_result) -> bool:
    mode = stat.S_IMODE(metadata.st_mode)
    if os.geteuid() == 0:
        return bool(mode & 0o111)
    if metadata.st_uid == os.geteuid():
        return bool(mode & stat.S_IXUSR)
    if metadata.st_gid == os.getegid() or metadata.st_gid in os.getgroups():
        return bool(mode & stat.S_IXGRP)
    return bool(mode & stat.S_IXOTH)


def _adhoc_sign_darwin_system_snapshot(
    selected: str, snapshot_path: str
) -> bool:
    """Make a copied Darwin platform binary executable outside the system volume."""
    selected_real = os.path.realpath(selected)
    if sys.platform != "darwin" or not selected_real.startswith(
        ("/usr/bin/", "/bin/")
    ):
        return False
    signer = "/usr/bin/codesign"
    before = os.stat(signer, follow_symlinks=True)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_uid != 0
        or stat.S_IMODE(before.st_mode) & 0o022
    ):
        raise RuntimeError("fixed Darwin code-signing boundary is unsafe")
    process = subprocess.Popen(
        [signer, "--force", "--sign", "-", snapshot_path],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    failure: RuntimeError | None = None
    try:
        returncode = process.wait(timeout=PARSER_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as exc:
        _terminate_process_group(process)
        failure = RuntimeError("Darwin snapshot code signing timed out")
        failure.__cause__ = exc
        returncode = process.returncode
    except BaseException:
        _terminate_process_group(process)
        raise
    finally:
        after = os.stat(signer, follow_symlinks=True)
        if not _same_file_state(before, after):
            raise RuntimeError("fixed Darwin code-signing boundary changed")
    if failure is not None:
        raise failure
    if returncode != 0:
        raise RuntimeError("could not ad-hoc sign Darwin executable snapshot")
    return True


def _bind_executable(
    path: Path,
    name: str,
    expected_sha256: str | None = None,
) -> BoundExecutable:
    """Copy one stable executable selection to a private snapshot."""
    selected = os.fspath(path)
    before = os.stat(selected, follow_symlinks=False)
    source = os.open(
        selected,
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0),
    )
    snapshot_directory = ""
    snapshot_directory_name = ""
    parent_descriptor = -1
    directory_descriptor = -1
    snapshot_name = "executable"
    snapshot_state: os.stat_result | None = None
    interpreter: BoundExecutable | None = None
    try:
        opened = os.fstat(source)
        if (
            not stat.S_ISREG(opened.st_mode)
            or not _same_file_state(before, opened)
            or not _executable_for_current_user(opened)
        ):
            raise RuntimeError(
                f"selected {name} is not a stable executable file"
            )
        first_line = os.read(source, 4096).split(b"\n", 1)[0]
        os.lseek(source, 0, os.SEEK_SET)
        if first_line.startswith(b"#!"):
            try:
                shebang = first_line[2:].decode("utf-8").strip().split()
            except UnicodeDecodeError as exc:
                raise RuntimeError(f"selected {name} has an invalid shebang") from exc
            if not shebang:
                raise RuntimeError(f"selected {name} has an empty shebang")
            if shebang[0] == "/usr/bin/env":
                if len(shebang) != 2 or shebang[1] not in {"sh", "bash", "python3"}:
                    raise RuntimeError(
                        f"selected {name} has an unbound env shebang"
                    )
                interpreter_path = shutil.which(shebang[1], path=os.defpath)
                if interpreter_path is None:
                    raise RuntimeError(
                        f"selected {name} shebang interpreter is unavailable"
                    )
            elif len(shebang) == 1 and os.path.isabs(shebang[0]):
                interpreter_path = shebang[0]
            else:
                raise RuntimeError(f"selected {name} has an unsupported shebang")
            candidate_interpreter = _bind_executable(
                Path(interpreter_path), f"{name}-interpreter"
            )
            if candidate_interpreter.interpreter is not None:
                candidate_interpreter.close()
                raise RuntimeError(
                    f"selected {name} has a nested script interpreter chain"
                )
            interpreter = candidate_interpreter

        snapshot_directory = os.path.abspath(
            tempfile.mkdtemp(prefix=f"odysseus-{name}-")
        )
        snapshot_directory_name = os.path.basename(snapshot_directory)
        os.chmod(snapshot_directory, 0o700)
        parent_descriptor = os.open(
            os.path.dirname(snapshot_directory),
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        directory_descriptor = os.open(
            snapshot_directory_name,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_descriptor,
        )
        direct_directory = os.stat(
            snapshot_directory_name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        if not _same_object(direct_directory, os.fstat(directory_descriptor)):
            raise RuntimeError(f"private executable directory changed: {name}")
        snapshot = os.open(
            snapshot_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o400,
            dir_fd=directory_descriptor,
        )
        snapshot_state = os.fstat(snapshot)
        source_digest = hashlib.sha256()
        size = 0
        try:
            while True:
                chunk = os.read(source, 1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > MAX_PARSER_BINARY_BYTES:
                    raise RuntimeError(
                        f"selected {name} exceeds the executable size limit"
                    )
                source_digest.update(chunk)
                offset = 0
                while offset < len(chunk):
                    written = os.write(snapshot, chunk[offset:])
                    if written <= 0:
                        raise OSError("short executable snapshot write")
                    offset += written
            source_after = os.fstat(source)
            try:
                path_after = os.stat(selected, follow_symlinks=True)
            except FileNotFoundError as exc:
                raise RuntimeError(
                    f"selected {name} changed while it was bound"
                ) from exc
            if (
                not _same_file_state(opened, source_after)
                or not _same_file_state(source_after, path_after)
            ):
                raise RuntimeError(
                    f"selected {name} changed while it was bound"
                )
            if (
                expected_sha256 is not None
                and not hmac.compare_digest(
                    source_digest.hexdigest(), expected_sha256
                )
            ):
                raise RuntimeError(
                    f"selected {name} SHA-256 does not match its handoff receipt"
                )
            os.fchmod(snapshot, 0o700 if sys.platform == "darwin" else 0o500)
            os.fsync(snapshot)
        finally:
            os.close(snapshot)
        snapshot_path = os.path.join(snapshot_directory, snapshot_name)
        snapshot_signed = _adhoc_sign_darwin_system_snapshot(
            selected, snapshot_path
        )
        os.chmod(snapshot_path, 0o500)
        snapshot_reader = os.open(
            snapshot_name,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0),
            dir_fd=directory_descriptor,
        )
        try:
            if not stat.S_ISREG(os.fstat(snapshot_reader).st_mode):
                raise RuntimeError(
                    f"private executable snapshot is not regular: {name}"
                )
            snapshot_digest, _ = _read_executable_digest(
                snapshot_reader,
                f"private {name} snapshot",
            )
            snapshot_state = os.fstat(snapshot_reader)
        finally:
            os.close(snapshot_reader)
        if (
            not snapshot_signed
            and not hmac.compare_digest(
                source_digest.digest(), snapshot_digest
            )
        ):
            raise RuntimeError(f"private executable snapshot differs: {name}")
        os.fchmod(directory_descriptor, 0o500)
        bound = BoundExecutable(
            name=name,
            selected_path=selected,
            snapshot_directory=snapshot_directory,
            directory_descriptor=directory_descriptor,
            snapshot_name=snapshot_name,
            snapshot_state=snapshot_state,
            directory_state=os.fstat(directory_descriptor),
            digest=snapshot_digest,
            parent_descriptor=parent_descriptor,
            snapshot_directory_name=snapshot_directory_name,
            interpreter=interpreter,
        )
        bound.verify()
        parent_descriptor = -1
        directory_descriptor = -1
        snapshot_directory = ""
        interpreter = None
        return bound
    finally:
        actions: list[Callable[[], None]] = [lambda: os.close(source)]
        if directory_descriptor >= 0:
            def cleanup_snapshot_directory() -> None:
                if parent_descriptor >= 0 and snapshot_directory_name:
                    _quarantine_owned_entry(
                        parent_descriptor,
                        snapshot_directory_name,
                        os.fstat(directory_descriptor),
                        is_directory=True,
                    )

            actions.extend(
                (
                    lambda: _cleanup_private_snapshot(
                        directory_descriptor,
                        snapshot_directory,
                        snapshot_name,
                        snapshot_state,
                    ),
                    cleanup_snapshot_directory,
                    lambda: os.close(directory_descriptor),
                )
            )
        if parent_descriptor >= 0:
            actions.append(lambda: os.close(parent_descriptor))
        if interpreter is not None:
            actions.append(interpreter.close)
        _run_cleanup_actions(*actions)


def _popen_bound(
    executable: BoundExecutable,
    arguments: Sequence[str],
    *,
    deadline: float | None = None,
    **kwargs: object,
) -> subprocess.Popen[bytes]:
    """Execute through already-open objects, never the snapshot pathname."""
    if not sys.platform.startswith("linux"):
        raise RuntimeError(
            "Linux descriptor execution is required; this platform is unsupported"
        )
    script_descriptor = -1
    launch = executable.interpreter or executable
    launch_descriptor = os.open(
        launch.snapshot_name,
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0),
        dir_fd=launch.directory_descriptor,
    )
    try:
        if not stat.S_ISREG(os.fstat(launch_descriptor).st_mode):
            raise RuntimeError(
                f"newly opened executable is not regular: {launch.name}"
            )
        _verify_open_executable(launch, launch_descriptor)
        command = [executable.name]
        inherited = [launch_descriptor, launch.directory_descriptor]
        if executable.interpreter is not None:
            script_descriptor = os.open(
                executable.snapshot_name,
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_NONBLOCK", 0),
                dir_fd=executable.directory_descriptor,
            )
            if not stat.S_ISREG(os.fstat(script_descriptor).st_mode):
                raise RuntimeError(
                    f"newly opened script is not regular: {executable.name}"
                )
            _verify_open_executable(executable, script_descriptor)
            inherited.append(script_descriptor)
            command.append(f"/dev/fd/{script_descriptor}")
        command.extend(arguments)
        environment = dict(kwargs.pop("env"))
        config_descriptors = tuple(kwargs.pop("pass_fds", ()))
        environment["PATH"] = os.defpath
        launch_path = f"/proc/self/fd/{launch_descriptor}"
        if deadline is not None and time.monotonic() >= deadline:
            raise RuntimeError(
                f"{executable.name} validation deadline expired before launch"
            )
        return subprocess.Popen(
            command,
            executable=launch_path,
            env=environment,
            pass_fds=tuple(dict.fromkeys((*inherited, *config_descriptors))),
            preexec_fn=None,
            **kwargs,
        )
    finally:
        os.close(launch_descriptor)
        if script_descriptor >= 0:
            os.close(script_descriptor)


def _verify_open_executable(
    executable: BoundExecutable,
    descriptor: int,
) -> None:
    """Verify the exact newly opened inode that will reach exec or an interpreter."""
    digest, _ = _read_executable_digest(descriptor, executable.name)
    current = os.fstat(descriptor)
    if (
        not stat.S_ISREG(current.st_mode)
        or current.st_uid != os.geteuid()
        or current.st_nlink != 1
        or stat.S_IMODE(current.st_mode) != 0o500
        or not _same_file_state(executable.snapshot_state, current)
        or not hmac.compare_digest(digest, executable.digest)
    ):
        raise RuntimeError(
            f"newly opened executable snapshot changed: {executable.name}"
        )


def _process_group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _signal_process_group(process_group: int, signal_number: int) -> None:
    try:
        os.killpg(process_group, signal_number)
    except ProcessLookupError:
        pass


def _wait_for_process_group_exit(
    process: subprocess.Popen[bytes], seconds: float
) -> bool:
    deadline = time.monotonic() + seconds
    while _process_group_exists(process.pid):
        process.poll()
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.01)
    return True


def _terminate_process_group(process: subprocess.Popen[bytes]) -> bool:
    _signal_process_group(process.pid, signal.SIGTERM)
    extinct = _wait_for_process_group_exit(process, TERM_GRACE_SECONDS)
    if not extinct:
        _signal_process_group(process.pid, signal.SIGKILL)
        extinct = _wait_for_process_group_exit(process, KILL_GRACE_SECONDS)
    try:
        process.wait(timeout=KILL_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        process.kill()
        try:
            process.wait(timeout=KILL_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            return False
    return extinct and not _process_group_exists(process.pid)


def _verify_private_directory(
    path: Path,
    descriptor: int,
    *,
    require_empty: bool = False,
) -> None:
    current = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(current.st_mode)
        or current.st_uid != os.geteuid()
        or stat.S_IMODE(current.st_mode) != 0o700
        or not _directory_path_matches(descriptor, path)
        or (require_empty and bool(os.listdir(descriptor)))
    ):
        raise RuntimeError(f"private child-process workspace changed: {path}")


def _new_anonymous_file(label: str, workspace_descriptor: int) -> int:
    """Create one Linux anonymous file for parser-owned fixture bytes."""
    if not sys.platform.startswith("linux"):
        raise RuntimeError(
            "Linux anonymous file descriptors are required for NATS fixtures"
        )
    descriptor = -1
    tmpfile_error: OSError | None = None
    if hasattr(os, "O_TMPFILE"):
        try:
            descriptor = os.open(
                ".",
                os.O_TMPFILE
                | os.O_RDWR
                | getattr(os, "O_CLOEXEC", 0),
                0o600,
                dir_fd=workspace_descriptor,
            )
        except OSError as exc:
            tmpfile_error = exc
    if descriptor < 0:
        if not hasattr(os, "memfd_create"):
            raise RuntimeError(
                "Linux anonymous file descriptors are required for NATS fixtures"
            ) from tmpfile_error
        try:
            descriptor = os.memfd_create(
                f"odysseus-nats-{label}",
                getattr(os, "MFD_CLOEXEC", 0),
            )
        except OSError as exc:
            raise RuntimeError(
                f"could not create anonymous parser fixture: {label}"
            ) from exc
    os.fchmod(descriptor, 0o600)
    created = os.fstat(descriptor)
    if (
        not stat.S_ISREG(created.st_mode)
        or created.st_uid != os.geteuid()
        or created.st_nlink != 0
    ):
        os.close(descriptor)
        raise RuntimeError(f"anonymous parser fixture is unsafe: {label}")
    return descriptor


def _read_only_descriptor_path(descriptor: int) -> str:
    if sys.platform.startswith("linux"):
        return f"/proc/self/fd/{descriptor}"
    return f"/dev/fd/{descriptor}"


def _bind_anonymous_input(
    writer: int,
    label: str,
    *,
    maximum_size: int,
    require_nonempty: bool,
) -> BoundConfigInput:
    """Freeze one anonymous writer and retain the exact object read-only."""
    os.fchmod(writer, 0o400)
    os.fsync(writer)
    reader = os.open(_read_only_descriptor_path(writer), os.O_RDONLY)
    try:
        writer_state = os.fstat(writer)
        reader_state = os.fstat(reader)
        if (
            not stat.S_ISREG(reader_state.st_mode)
            or reader_state.st_uid != os.geteuid()
            or reader_state.st_nlink != 0
            or stat.S_IMODE(reader_state.st_mode) != 0o400
            or not _same_file_state(writer_state, reader_state)
            or reader_state.st_size > maximum_size
            or (require_nonempty and reader_state.st_size == 0)
        ):
            raise RuntimeError(f"anonymous parser fixture is unsafe: {label}")
        content = bytearray()
        offset = 0
        while len(content) <= maximum_size:
            chunk = os.pread(
                reader,
                min(65_536, maximum_size + 1 - len(content)),
                offset,
            )
            if not chunk:
                break
            content.extend(chunk)
            offset += len(chunk)
        after = os.fstat(reader)
        if (
            len(content) > maximum_size
            or not _same_file_state(reader_state, after)
        ):
            raise RuntimeError(f"anonymous parser fixture changed: {label}")
        bound = BoundConfigInput(
            descriptor=reader,
            state=after,
            digest=hashlib.sha256(content).digest(),
            size=len(content),
            label=label,
            maximum_size=maximum_size,
        )
        reader = -1
        bound.verify()
        return bound
    finally:
        if reader >= 0:
            os.close(reader)


@contextmanager
def _bound_config_input(
    workspace: Path,
    content: bytes,
    label: str,
    workspace_descriptor: int | None = None,
) -> Iterator[BoundConfigInput]:
    """Create an unlinked read-only snapshot for one parser invocation."""
    if len(content) > MAX_CONFIG_BYTES:
        raise RuntimeError(
            f"parser input exceeds the {MAX_CONFIG_BYTES}-byte limit: {label}"
        )
    directory = (
        os.dup(workspace_descriptor)
        if workspace_descriptor is not None
        else os.open(
            workspace,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
    )
    writer = -1
    reader = -1
    name = ""
    created: os.stat_result | None = None
    linked = False
    bound: BoundConfigInput | None = None
    try:
        _verify_private_directory(workspace, directory, require_empty=True)
        for _ in range(16):
            name = ".odysseus-nats-input-" + secrets.token_hex(16)
            try:
                writer = os.open(
                    name,
                    os.O_WRONLY
                    | os.O_CREAT
                    | os.O_EXCL
                    | getattr(os, "O_NOFOLLOW", 0),
                    0o600,
                    dir_fd=directory,
                )
                linked = True
                break
            except FileExistsError:
                continue
        if writer < 0:
            raise RuntimeError("could not allocate a private config snapshot")
        created = os.fstat(writer)
        if (
            not stat.S_ISREG(created.st_mode)
            or created.st_uid != os.geteuid()
            or created.st_nlink != 1
        ):
            raise RuntimeError(f"config snapshot identity is unsafe: {label}")
        offset = 0
        while offset < len(content):
            written = os.write(writer, content[offset:])
            if written <= 0:
                raise OSError("short write while snapshotting parser input")
            offset += written
        os.fchmod(writer, 0o400)
        os.fsync(writer)
        written_state = os.fstat(writer)
        reader = os.open(
            name,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0),
            dir_fd=directory,
        )
        opened_state = os.fstat(reader)
        if not stat.S_ISREG(opened_state.st_mode):
            raise RuntimeError(f"config snapshot is not regular: {label}")
        named_state = os.stat(name, dir_fd=directory, follow_symlinks=False)
        if (
            not _same_file_state(written_state, opened_state)
            or not _same_file_state(opened_state, named_state)
        ):
            raise RuntimeError(f"config snapshot changed while opening: {label}")
        if not _quarantine_owned_entry(directory, name, opened_state):
            raise RuntimeError(f"config snapshot changed while opening: {label}")
        linked = False
        os.fsync(directory)
        os.close(writer)
        writer = -1
        state = os.fstat(reader)
        bound = BoundConfigInput(
            descriptor=reader,
            state=state,
            digest=hashlib.sha256(content).digest(),
            size=len(content),
            label=label,
        )
        reader = -1
        bound.verify()
        _verify_private_directory(workspace, directory, require_empty=True)
        yield bound
        bound.verify()
        _verify_private_directory(workspace, directory, require_empty=True)
    finally:
        actions: list[Callable[[], None]] = []
        if bound is not None:
            actions.append(bound.close)
        if reader >= 0:
            actions.append(lambda: os.close(reader))
        if writer >= 0:
            actions.append(lambda: os.close(writer))
        if linked and created is not None:

            def remove_linked_snapshot() -> None:
                if _quarantine_owned_entry(directory, name, created):
                    os.fsync(directory)

            def remove_if_present() -> None:
                try:
                    remove_linked_snapshot()
                except FileNotFoundError:
                    return

            actions.append(remove_if_present)
        actions.append(lambda: os.close(directory))
        _run_cleanup_actions(*actions)


def _run_supervised(
    executable: BoundExecutable,
    arguments: Sequence[str],
    *,
    environment: dict[str, str],
    workspace: Path,
    boundary: Callable[[], None],
    workspace_descriptor: int | None = None,
    pass_fds: Sequence[int] = (),
    deadline: float | None = None,
) -> CommandResult:
    """Run one snapshot with bounded output, time, and descendants."""
    if deadline is None:
        deadline = time.monotonic() + PARSER_TIMEOUT_SECONDS
    if time.monotonic() >= deadline:
        raise RuntimeError(
            f"{executable.name} validation deadline expired before launch"
        )
    executable.verify()
    process: subprocess.Popen[bytes] | None = None
    stream_selector = selectors.DefaultSelector()
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    failure: str | None = None
    try:
        if time.monotonic() >= deadline:
            raise RuntimeError(
                f"{executable.name} validation deadline expired before launch"
            )
        boundary()
        child_environment = dict(environment)
        child_workspace: Path | str = workspace
        inherited = tuple(pass_fds)
        if workspace_descriptor is not None:
            child_workspace = f"/proc/self/fd/{workspace_descriptor}"
            child_environment["HOME"] = child_workspace
            inherited = (*inherited, workspace_descriptor)
        process = _popen_bound(
            executable,
            arguments,
            deadline=deadline,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=child_environment,
            cwd=child_workspace,
            start_new_session=True,
            pass_fds=tuple(dict.fromkeys(inherited)),
        )
        if process.stdout is None or process.stderr is None:
            raise RuntimeError(f"could not capture {executable.name} output")
        stream_selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        stream_selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        while process.poll() is None or stream_selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                failure = (
                    f"{executable.name} timed out at the shared validation deadline"
                )
                break
            events = stream_selector.select(min(0.05, remaining))
            for key, _ in events:
                chunk = os.read(key.fd, 64 * 1024)
                if not chunk:
                    stream_selector.unregister(key.fileobj)
                    continue
                buffer = buffers[key.data]
                available = MAX_PARSER_OUTPUT_BYTES - len(buffer)
                if available > 0:
                    buffer.extend(chunk[:available])
                if len(chunk) > available:
                    failure = (
                        f"{executable.name} exceeded the "
                        f"{MAX_PARSER_OUTPUT_BYTES}-byte output limit"
                    )
                    break
            if failure is not None:
                break
        if failure is not None:
            def terminate_after_failure() -> None:
                nonlocal failure
                if not _terminate_process_group(process):
                    failure += "; process group did not become extinct"

            _run_cleanup_actions(
                terminate_after_failure,
                pending_primary=RuntimeError(failure),
            )
        else:
            process.wait(timeout=KILL_GRACE_SECONDS)
            if _process_group_exists(process.pid):
                failure = f"{executable.name} left running descendants"
                def terminate_after_failure() -> None:
                    nonlocal failure
                    if not _terminate_process_group(process):
                        failure += "; process group did not become extinct"

                _run_cleanup_actions(
                    terminate_after_failure,
                    pending_primary=RuntimeError(failure),
                )
    except BaseException:
        if process is not None:
            _run_cleanup_actions(lambda: _terminate_process_group(process))
        raise
    finally:
        actions: list[Callable[[], None]] = [stream_selector.close]
        if process is not None:
            if process.stdout is not None:
                actions.append(process.stdout.close)
            if process.stderr is not None:
                actions.append(process.stderr.close)
            actions.extend((executable.verify, boundary))
        pending = RuntimeError(failure) if failure is not None else None
        _run_cleanup_actions(*actions, pending_primary=pending)
    if failure is not None:
        raise RuntimeError(failure)
    if process is None:
        raise RuntimeError(f"could not start {executable.name}")
    return CommandResult(
        process.returncode,
        bytes(buffers["stdout"]).decode("utf-8", errors="replace"),
        bytes(buffers["stderr"]).decode("utf-8", errors="replace"),
    )


def _run_parser_with_config(
    executable: BoundExecutable,
    arguments: Sequence[str],
    content: str,
    *,
    label: str,
    environment: dict[str, str],
    workspace: Path,
    boundary: Callable[[], None],
    workspace_descriptor: int | None = None,
    retained_inputs: Sequence[BoundConfigInput] = (),
    deadline: float,
) -> tuple[CommandResult, str]:
    """Run a parser against bytes inherited through one retained descriptor."""
    try:
        encoded = content.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise RuntimeError(f"parser input is not valid UTF-8: {label}") from exc
    with _bound_config_input(
        workspace,
        encoded,
        label,
        workspace_descriptor,
    ) as bound:
        for retained in retained_inputs:
            retained.verify()
        result = _run_supervised(
            executable,
            (*arguments, bound.path),
            environment=environment,
            workspace=workspace,
            boundary=boundary,
            workspace_descriptor=workspace_descriptor,
            pass_fds=(
                bound.descriptor,
                *(item.descriptor for item in retained_inputs),
            ),
            deadline=deadline,
        )
        bound.verify()
        for retained in retained_inputs:
            retained.verify()
        return result, bound.path


def _controlled_environment(home: Path) -> dict[str, str]:
    return {
        "HOME": str(home),
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": os.defpath,
        "NATS_CLIENT_TOKEN": "validation-client-token",
        "NATS_CLUSTER_PASSWORD": "validation-cluster-password",
        "NATS_CLUSTER_USER": "validation-cluster-user",
        "NATS_LEAF_PASSWORD": "validation-leaf-password",
        "NATS_LEAF_TOKEN": "validation-leaf-token",
        "NATS_LEAF_URL": "nats+tls://127.0.0.1:7422",
        "NATS_LEAF_USER": "validation-leaf-user",
    }


@contextmanager
def _private_workspace(prefix: str) -> Iterator[tuple[Path, int]]:
    """Hold one private workspace and never remove a replacement path."""
    workspace = Path(os.path.abspath(tempfile.mkdtemp(prefix=prefix)))
    parent_descriptor = -1
    descriptor = -1
    workspace_state: os.stat_result | None = None
    try:
        os.chmod(workspace, 0o700)
        parent_descriptor = os.open(
            workspace.parent,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        descriptor = os.open(
            workspace.name,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_descriptor,
        )
        workspace_state = os.fstat(descriptor)
        direct = os.stat(
            workspace.name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        if not _same_object(workspace_state, direct):
            raise RuntimeError("private workspace changed while it was bound")
        _verify_private_directory(workspace, descriptor, require_empty=True)
        yield workspace, descriptor
    finally:
        actions: list[Callable[[], None]] = []
        if (
            descriptor >= 0
            and parent_descriptor >= 0
            and workspace_state is not None
        ):

            def remove_owned_workspace() -> None:
                os.fchmod(descriptor, 0o700)
                _quarantine_owned_entry(
                    parent_descriptor,
                    workspace.name,
                    workspace_state,
                    is_directory=True,
                )

            actions.append(remove_owned_workspace)
        if descriptor >= 0:
            actions.append(lambda: os.close(descriptor))
        if parent_descriptor >= 0:
            actions.append(lambda: os.close(parent_descriptor))
        _run_cleanup_actions(*actions)


def _generate_certificates(
    workspace: Path,
    environment: dict[str, str],
    *,
    workspace_descriptor: int | None = None,
    deadline: float | None = None,
) -> BoundCertificateFiles:
    if deadline is None:
        deadline = time.monotonic() + PARSER_TIMEOUT_SECONDS
    openssl = shutil.which("openssl", path=environment["PATH"])
    if openssl is None:
        raise RuntimeError("openssl is required to create NATS parser fixtures")
    executable = _bind_executable(Path(openssl), "openssl")
    owned_workspace_descriptor = workspace_descriptor is None
    key_writer = -1
    cert_writer = -1
    key: BoundConfigInput | None = None
    certificate: BoundConfigInput | None = None
    arguments = [
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
    ]
    try:
        if workspace_descriptor is None:
            workspace_descriptor = os.open(
                workspace,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
            )
        assert workspace_descriptor is not None
        _verify_private_directory(
            workspace,
            workspace_descriptor,
            require_empty=True,
        )
        key_writer = _new_anonymous_file("server-key", workspace_descriptor)
        cert_writer = _new_anonymous_file("server-cert", workspace_descriptor)
        arguments.extend(
            [
                "-keyout",
                f"/proc/self/fd/{key_writer}",
                "-out",
                f"/proc/self/fd/{cert_writer}",
                "-days",
                "1",
                "-nodes",
                "-subj",
                "/CN=nats-config-validation",
            ]
        )
        completed = _run_supervised(
            executable,
            arguments,
            environment=environment,
            workspace=workspace,
            boundary=lambda: _verify_private_directory(
                workspace,
                workspace_descriptor,
                require_empty=True,
            ),
            workspace_descriptor=workspace_descriptor,
            pass_fds=(key_writer, cert_writer),
            deadline=deadline,
        )
        if completed.returncode != 0:
            detail = completed.stderr.strip().splitlines()
            message = detail[-1] if detail else f"exit {completed.returncode}"
            raise RuntimeError(message)
        key = _bind_anonymous_input(
            key_writer,
            "generated NATS server key",
            maximum_size=MAX_CERTIFICATE_BYTES,
            require_nonempty=True,
        )
        os.close(key_writer)
        key_writer = -1
        certificate = _bind_anonymous_input(
            cert_writer,
            "generated NATS server certificate",
            maximum_size=MAX_CERTIFICATE_BYTES,
            require_nonempty=True,
        )
        os.close(cert_writer)
        cert_writer = -1
        result = BoundCertificateFiles(
            certificate=certificate,
            key=key,
            workspace=workspace,
            workspace_descriptor=workspace_descriptor,
            owns_workspace_descriptor=owned_workspace_descriptor,
        )
        result.verify()
        key = None
        certificate = None
        workspace_descriptor = -1
        return result
    except (OSError, RuntimeError) as exc:
        raise RuntimeError(f"could not create NATS parser certificates: {exc}") from exc
    finally:
        actions: list[Callable[[], None]] = []
        if key_writer >= 0:
            actions.append(lambda: os.close(key_writer))
        if cert_writer >= 0:
            actions.append(lambda: os.close(cert_writer))
        if key is not None:
            actions.append(key.close)
        if certificate is not None:
            actions.append(certificate.close)
        if owned_workspace_descriptor and workspace_descriptor >= 0:
            actions.append(lambda: os.close(workspace_descriptor))
        actions.append(executable.close)
        _run_cleanup_actions(*actions)


@contextmanager
def _render_for_parser(
    text: str,
    workspace: Path,
    environment: dict[str, str],
    *,
    workspace_descriptor: int,
    deadline: float | None = None,
) -> Iterator[tuple[str, tuple[BoundConfigInput, ...]]]:
    if not _CERT_ASSIGNMENT.search(text):
        yield text, ()
        return
    certificates = _generate_certificates(
        workspace,
        environment,
        workspace_descriptor=workspace_descriptor,
        deadline=deadline,
    )

    def replace(match: re.Match[str]) -> str:
        quote = match.group("quote")
        field = match.group("field")
        return f"{match.group('prefix')}{quote}{certificates[field]}{quote}"

    try:
        rendered = _CERT_ASSIGNMENT.sub(replace, text)
        certificates.verify()
        yield rendered, certificates.inputs
        certificates.verify()
    finally:
        certificates.close()


def _release_for_host() -> ParserRelease:
    machine = platform.machine().lower()
    if machine == "amd64":
        machine = "x86_64"
    elif machine == "arm64" and sys.platform.startswith("linux"):
        machine = "aarch64"
    key = (sys.platform, machine)
    try:
        return _PARSER_RELEASES[key]
    except KeyError as exc:
        raise RuntimeError(
            "no content-pinned nats-server parser is available for "
            f"{sys.platform}/{machine}"
        ) from exc


def _read_download(response: object, deadline: float) -> bytes:
    content = bytearray()
    read = getattr(response, "read", None)
    if not callable(read):
        raise RuntimeError("nats-server download returned no readable body")
    while len(content) <= MAX_PARSER_ARCHIVE_BYTES:
        if time.monotonic() >= deadline:
            raise RuntimeError("nats-server download timed out")
        chunk = read(min(65_536, MAX_PARSER_ARCHIVE_BYTES + 1 - len(content)))
        if time.monotonic() >= deadline:
            raise RuntimeError("nats-server download timed out")
        if not chunk:
            break
        if not isinstance(chunk, bytes):
            raise RuntimeError("nats-server download returned a non-byte body")
        content.extend(chunk)
    if len(content) > MAX_PARSER_ARCHIVE_BYTES:
        raise RuntimeError(
            "nats-server release archive exceeds the "
            f"{MAX_PARSER_ARCHIVE_BYTES}-byte limit"
        )
    return bytes(content)


def _archive_member_safe(member: tarfile.TarInfo) -> bool:
    name = PurePosixPath(member.name)
    return (
        not name.is_absolute()
        and ".." not in name.parts
        and (member.isdir() or member.isfile())
    )


def provision_nats_server(
    destination: Path,
    *,
    release: ParserRelease | None = None,
    opener: Callable[..., ContextManager[object]] | None = None,
) -> ParserExecutable:
    """Materialize one verified official parser in a caller-owned directory."""

    selected = release or _release_for_host()
    parsed_url = urlsplit(selected.url)
    if (
        parsed_url.scheme != "https"
        or parsed_url.hostname not in _PARSER_DOWNLOAD_HOSTS
    ):
        raise RuntimeError("nats-server release URL must be approved HTTPS")
    destination_descriptor = -1
    try:
        destination_descriptor = os.open(
            destination,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        destination_stat = os.fstat(destination_descriptor)
    except OSError as exc:
        raise RuntimeError(
            f"nats-server destination is unavailable: {destination}"
        ) from exc
    if (
        not destination.is_absolute()
        or not stat.S_ISDIR(destination_stat.st_mode)
        or destination_stat.st_uid != os.geteuid()
        or destination_stat.st_mode & 0o077
        or not _directory_path_matches(destination_descriptor, destination)
    ):
        os.close(destination_descriptor)
        raise RuntimeError(
            f"nats-server destination must be a private real directory: {destination}"
        )

    def verify_destination(boundary: str) -> None:
        current = os.fstat(destination_descriptor)
        if (
            not stat.S_ISDIR(current.st_mode)
            or current.st_uid != os.geteuid()
            or stat.S_IMODE(current.st_mode) != 0o700
            or not _same_object(destination_stat, current)
            or not _directory_path_matches(destination_descriptor, destination)
        ):
            raise RuntimeError(
                f"nats-server destination changed {boundary}"
            )

    open_url = opener or urlopen
    try:
        with _download_deadline(PARSER_DOWNLOAD_TIMEOUT_SECONDS) as download_deadline:
            with open_url(
                selected.url,
                timeout=max(0.001, download_deadline - time.monotonic()),
            ) as response:
                if time.monotonic() >= download_deadline:
                    raise RuntimeError("nats-server download timed out")
                final_url = urlsplit(str(getattr(response, "geturl")()))
                if (
                    final_url.scheme != "https"
                    or final_url.hostname not in _PARSER_DOWNLOAD_HOSTS
                ):
                    raise RuntimeError(
                        "nats-server release redirect must remain on approved HTTPS"
                    )
                archive_bytes = _read_download(response, download_deadline)
    except RuntimeError:
        os.close(destination_descriptor)
        raise
    except (OSError, TimeoutError) as exc:
        os.close(destination_descriptor)
        raise RuntimeError(
            f"could not download nats-server v{_NATS_SERVER_VERSION}: {exc}"
        ) from exc

    actual_sha256 = hashlib.sha256(archive_bytes).hexdigest()
    if not hmac.compare_digest(actual_sha256, selected.sha256):
        os.close(destination_descriptor)
        raise RuntimeError(
            "nats-server release archive SHA-256 does not match the pinned value"
        )

    try:
        with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:gz") as archive:
            members = archive.getmembers()
            try:
                parser_member = archive.getmember(selected.member)
            except KeyError as exc:
                raise RuntimeError(
                    "nats-server release archive omits the pinned parser member"
                ) from exc
            if not parser_member.isfile():
                raise RuntimeError(
                    "nats-server release parser member must be a regular file"
                )
            if not members or any(not _archive_member_safe(item) for item in members):
                raise RuntimeError(
                    "nats-server release archive contains an unsafe member"
                )
            parser_stream = archive.extractfile(parser_member)
            if parser_stream is None:
                raise RuntimeError(
                    "nats-server release parser member could not be read"
                )
            parser_bytes = parser_stream.read(MAX_PARSER_BINARY_BYTES + 1)
    except RuntimeError:
        os.close(destination_descriptor)
        raise
    except (tarfile.TarError, OSError) as exc:
        os.close(destination_descriptor)
        raise RuntimeError(f"invalid nats-server release archive: {exc}") from exc
    if len(parser_bytes) > MAX_PARSER_BINARY_BYTES:
        os.close(destination_descriptor)
        raise RuntimeError(
            "nats-server parser exceeds the "
            f"{MAX_PARSER_BINARY_BYTES}-byte limit"
        )

    parser_path = destination / "nats-server"
    parser_name = parser_path.name
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = -1
    created_state: os.stat_result | None = None
    try:
        verify_destination("before materialization")
        descriptor = os.open(
            parser_name,
            flags,
            0o700,
            dir_fd=destination_descriptor,
        )
        try:
            created_state = os.fstat(descriptor)
            offset = 0
            while offset < len(parser_bytes):
                written = os.write(descriptor, parser_bytes[offset:])
                if written <= 0:
                    raise OSError("short write while materializing parser")
                offset += written
            os.fchmod(descriptor, 0o700)
            os.fsync(descriptor)
            final_state = os.fstat(descriptor)
            if (
                not stat.S_ISREG(final_state.st_mode)
                or final_state.st_nlink != 1
                or final_state.st_uid != os.geteuid()
                or stat.S_IMODE(final_state.st_mode) != 0o700
                or not _same_object(created_state, final_state)
            ):
                raise RuntimeError("materialized parser identity is unsafe")
        finally:
            os.close(descriptor)
            descriptor = -1
        direct = os.stat(
            parser_name,
            dir_fd=destination_descriptor,
            follow_symlinks=False,
        )
        if (
            not _same_object(created_state, direct)
            or not _same_file_state(final_state, direct)
        ):
            raise RuntimeError("materialized nats-server dentry changed")
        reader = os.open(
            parser_name,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0),
            dir_fd=destination_descriptor,
        )
        try:
            if not stat.S_ISREG(os.fstat(reader).st_mode):
                raise RuntimeError("materialized nats-server is not a regular file")
            observed_digest, observed_size = _read_executable_digest(
                reader,
                "materialized nats-server",
            )
            observed_state = os.fstat(reader)
        finally:
            os.close(reader)
        if (
            not _same_file_state(final_state, observed_state)
            or observed_size != len(parser_bytes)
            or not hmac.compare_digest(
                observed_digest,
                hashlib.sha256(parser_bytes).digest(),
            )
        ):
            raise RuntimeError("materialized nats-server bytes changed")
        verify_destination("after materialization")
        os.fsync(destination_descriptor)
        verify_destination("after directory fsync")
    except BaseException as exc:
        if descriptor >= 0:
            os.close(descriptor)
        if created_state is not None:
            _quarantine_owned_entry(
                destination_descriptor,
                parser_name,
                created_state,
            )
        if isinstance(exc, DeferredSignal):
            raise
        if isinstance(exc, RuntimeError):
            raise
        raise RuntimeError(
            f"could not materialize the verified nats-server parser: {exc}"
        ) from exc
    finally:
        os.close(destination_descriptor)
    return ParserExecutable(
        parser_path,
        hashlib.sha256(parser_bytes).hexdigest(),
    )


def _parser_path(requested: str | None) -> Path:
    if not requested:
        raise RuntimeError("required nats-server parser is unavailable")
    candidate = requested
    path = Path(candidate).expanduser()
    if not path.is_absolute():
        resolved = shutil.which(str(path))
        if resolved:
            path = Path(resolved)
    try:
        path = path.resolve(strict=True)
    except OSError as exc:
        raise RuntimeError(
            f"required nats-server parser is unavailable: {candidate}"
        ) from exc
    if not path.is_file() or not os.access(path, os.X_OK):
        raise RuntimeError(f"required nats-server parser is not executable: {path}")
    return path


@contextmanager
def _parser_context(
    requested: str | None,
    expected_sha256: str | None = None,
) -> Iterator[ParserExecutable]:
    if requested is not None:
        yield ParserExecutable(_parser_path(requested), expected_sha256)
        return
    try:
        with _private_workspace(
            "odysseus-nats-parser-"
        ) as (workspace, workspace_descriptor):
            parser = provision_nats_server(workspace)
            parser_name = parser.path.name
            parser_state = os.stat(
                parser_name,
                dir_fd=workspace_descriptor,
                follow_symlinks=False,
            )
            if (
                not stat.S_ISREG(parser_state.st_mode)
                or parser_state.st_uid != os.geteuid()
                or parser_state.st_nlink != 1
            ):
                raise RuntimeError("provisioned nats-server parser identity is unsafe")
            try:
                yield parser
            finally:

                def remove_owned_parser() -> None:
                    _quarantine_owned_entry(
                        workspace_descriptor,
                        parser_name,
                        parser_state,
                    )

                _run_cleanup_actions(remove_owned_parser)
    except RuntimeError:
        raise
    except OSError as exc:
        raise RuntimeError(
            f"could not prepare nats-server parser workspace: {exc}"
        ) from exc


def _verify_parser(
    parser: Path | BoundExecutable,
    workspace: Path,
    environment: dict[str, str],
    boundary: Callable[[], None] | None = None,
    workspace_descriptor: int | None = None,
    deadline: float | None = None,
) -> str | None:
    if deadline is None:
        deadline = time.monotonic() + PARSER_TIMEOUT_SECONDS
    owned = not isinstance(parser, BoundExecutable)
    try:
        executable = (
            _bind_executable(parser, "nats-server")
            if isinstance(parser, Path)
            else parser
        )
    except (OSError, RuntimeError) as exc:
        return f"could not verify nats-server parser: {exc}"
    owns_workspace_descriptor = workspace_descriptor is None
    if workspace_descriptor is None:
        try:
            workspace_descriptor = os.open(
                workspace,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
            )
        except OSError as exc:
            if owned:
                executable.close()
            return f"could not verify nats-server parser: {exc}"
    assert workspace_descriptor is not None
    outer_boundary = boundary

    def verify_workspace() -> None:
        _verify_private_directory(
            workspace,
            workspace_descriptor,
            require_empty=True,
        )
        if outer_boundary is not None:
            outer_boundary()

    boundary = verify_workspace
    try:
        try:
            completed = _run_supervised(
                executable,
                ("--version",),
                environment=environment,
                workspace=workspace,
                boundary=boundary,
                workspace_descriptor=workspace_descriptor,
                deadline=deadline,
            )
        except (OSError, RuntimeError) as exc:
            return f"could not verify nats-server parser: {exc}"
        version_output = "\n".join((completed.stdout, completed.stderr)).strip()
        if (
            completed.returncode != 0
            or re.search(
                r"(?:^|\n)nats-server: v\d+\.\d+\.\d+(?:[-+][^\s]+)?(?:\n|$)",
                version_output,
            )
            is None
        ):
            return f"{executable.selected_path} is not a nats-server executable"
        try:
            invalid_result, _ = _run_parser_with_config(
                executable,
                ("-t", "-c"),
                "authorization = []\n",
                label="malformed semantic canary",
                environment=environment,
                workspace=workspace,
                boundary=boundary,
                workspace_descriptor=workspace_descriptor,
                deadline=deadline,
            )
            valid_result, _ = _run_parser_with_config(
                executable,
                ("-t", "-c"),
                "port = 4222\n",
                label="valid semantic canary",
                environment=environment,
                workspace=workspace,
                boundary=boundary,
                workspace_descriptor=workspace_descriptor,
                deadline=deadline,
            )
        except (OSError, RuntimeError) as exc:
            return f"could not run nats-server semantic canaries: {exc}"
        if invalid_result.returncode == 0:
            return "nats-server parser accepted the malformed semantic canary"
        if valid_result.returncode != 0:
            return "nats-server parser rejected the valid semantic canary"
        return None
    finally:
        actions: list[Callable[[], None]] = []
        if owns_workspace_descriptor:
            actions.append(lambda: os.close(workspace_descriptor))
        if owned:
            actions.append(executable.close)
        _run_cleanup_actions(*actions)


def _validate_syntax(
    configs: Sequence[Path],
    parser: ParserExecutable,
) -> int:
    failed = 0
    executable = _bind_executable(
        parser.path,
        "nats-server",
        expected_sha256=parser.sha256,
    )
    try:
        with _private_workspace(
            "odysseus-nats-validate-"
        ) as (workspace, workspace_descriptor):

            def verify_workspace() -> None:
                _verify_private_directory(
                    workspace,
                    workspace_descriptor,
                    require_empty=True,
                )

            boundary = verify_workspace
            environment = _controlled_environment(workspace)
            validation_deadline = time.monotonic() + PARSER_TIMEOUT_SECONDS
            parser_error = _verify_parser(
                executable,
                workspace,
                environment,
                boundary,
                workspace_descriptor=workspace_descriptor,
                deadline=validation_deadline,
            )
            if parser_error is not None:
                print(f"ERROR: {parser_error}", file=sys.stderr)
                return 1
            for number, config in enumerate(configs):
                source: BoundConfigSource | None = None
                try:
                    try:
                        source = BoundConfigSource.open(config)
                        text = source.text
                    except ConfigStructureError as exc:
                        print(f"FAILED: {config} -- {exc}", file=sys.stderr)
                        failed += 1
                        continue
                    if not text.strip():
                        print(
                            f"FAILED: {config} -- config is empty", file=sys.stderr
                        )
                        failed += 1
                        continue
                    ok, detail = delimiter_precheck(text)
                    if not ok:
                        print(
                            f"FAILED: {config} -- delimiter precheck rejected config: {detail}",
                            file=sys.stderr,
                        )
                        failed += 1
                        continue
                    rendered_ready = False
                    try:
                        with _render_for_parser(
                            text,
                            workspace,
                            environment,
                            workspace_descriptor=workspace_descriptor,
                            deadline=validation_deadline,
                        ) as (rendered, retained_inputs):
                            rendered_ready = True
                            completed, parser_input_path = _run_parser_with_config(
                                executable,
                                ("-t", "-c"),
                                rendered,
                                label=f"configuration {number}: {config}",
                                environment=environment,
                                workspace=workspace,
                                boundary=boundary,
                                workspace_descriptor=workspace_descriptor,
                                retained_inputs=retained_inputs,
                                deadline=validation_deadline,
                            )
                    except (OSError, RuntimeError) as exc:
                        if rendered_ready:
                            print(
                                f"FAILED: {config} -- nats-server parser failed: {exc}",
                                file=sys.stderr,
                            )
                        else:
                            print(
                                f"FAILED: {config} -- {exc}",
                                file=sys.stderr,
                            )
                        failed += 1
                        continue
                    if completed.returncode != 0:
                        parser_output = (
                            completed.stderr or completed.stdout
                        ).strip()
                        parser_output = parser_output.replace(
                            parser_input_path, str(config)
                        )
                        detail = (
                            parser_output.splitlines()[0]
                            if parser_output
                            else (f"exit {completed.returncode}")
                        )
                        print(
                            f"FAILED: {config} -- nats-server rejected config: {detail}",
                            file=sys.stderr,
                        )
                        failed += 1
                        continue
                    try:
                        source.verify()
                    except ConfigStructureError as exc:
                        print(f"FAILED: {config} -- {exc}", file=sys.stderr)
                        failed += 1
                        continue
                    print(f"OK: {config}")
                finally:
                    if source is not None:
                        source.close()
    finally:
        executable.close()
    return 1 if failed else 0


def _arguments(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--nats-server",
        metavar="PATH",
        help="exact nats-server executable for the syntax gate",
    )
    parser.add_argument(
        "--expected-nats-server-sha256",
        help="exact parser digest received from the pinned provisioner",
    )
    parser.add_argument(
        "--auth",
        nargs=2,
        metavar=("LEAF_CONFIG", "SERVER_CONFIG"),
        help="validate the authentication structure without the syntax gate",
    )
    parser.add_argument("configs", nargs="*", type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Run the requested authentication or real-parser validation gate."""
    with _deferred_termination():
        args = _arguments(argv)
        if args.auth is not None:
            if (
                args.configs
                or args.nats_server is not None
                or args.expected_nats_server_sha256 is not None
            ):
                print(
                    "ERROR: --auth cannot be combined with syntax-gate arguments",
                    file=sys.stderr,
                )
                return 2
            errors = validate_auth(Path(args.auth[0]), Path(args.auth[1]))
            if errors:
                for error in errors:
                    print(f"FAIL: {error}", file=sys.stderr)
                return 1
            print("OK: NATS configs declare structurally valid authentication")
            return 0

        root = Path(__file__).resolve().parent.parent
        configs = (
            list(args.configs)
            if args.configs
            else sorted((root / "configs" / "nats").rglob("*.conf"))
        )
        if not configs:
            print("ERROR: no NATS .conf files were selected", file=sys.stderr)
            return 1
        expected_sha256 = args.expected_nats_server_sha256
        if expected_sha256 is not None:
            if args.nats_server is None:
                print(
                    "ERROR: --expected-nats-server-sha256 requires --nats-server",
                    file=sys.stderr,
                )
                return 2
            if re.fullmatch(r"[0-9a-f]{64}", expected_sha256) is None:
                print(
                    "ERROR: expected nats-server SHA-256 must be 64 lowercase hex characters",
                    file=sys.stderr,
                )
                return 2
        try:
            with _parser_context(args.nats_server, expected_sha256) as parser:
                return _validate_syntax(configs, parser)
        except RuntimeError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 1


if __name__ == "__main__":
    sys.exit(main())
