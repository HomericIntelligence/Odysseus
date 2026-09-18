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
import hashlib
import hmac
import io
import os
import platform
import re
import selectors
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
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=self.directory_descriptor,
        )
        try:
            content = bytearray()
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                content.extend(chunk)
            current = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        if (
            not stat.S_ISREG(current.st_mode)
            or current.st_uid != os.geteuid()
            or current.st_nlink != 1
            or stat.S_IMODE(current.st_mode) != 0o500
            or not _same_file_state(self.snapshot_state, current)
            or hashlib.sha256(content).digest() != self.digest
        ):
            raise RuntimeError(f"private executable snapshot changed: {self.name}")
        if self.interpreter is not None:
            self.interpreter.verify()

    def close(self) -> None:
        try:
            os.fchmod(self.directory_descriptor, 0o700)
            os.unlink(self.snapshot_name, dir_fd=self.directory_descriptor)
            if _directory_path_matches(
                self.directory_descriptor, self.snapshot_directory
            ):
                os.rmdir(self.snapshot_directory)
        finally:
            os.close(self.directory_descriptor)
            if self.interpreter is not None:
                self.interpreter.close()


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
    flags = os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise ConfigStructureError(
            f"{path} must be a readable regular non-symlink file: {exc.strerror}"
        ) from exc
    try:
        file_stat = os.fstat(descriptor)
        if not stat.S_ISREG(file_stat.st_mode):
            raise ConfigStructureError(
                f"{path} must be a readable regular non-symlink file"
            )
        if file_stat.st_size > MAX_CONFIG_BYTES:
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
    except OSError as exc:
        raise ConfigStructureError(f"cannot read {path}: {exc}") from exc
    finally:
        os.close(descriptor)
    try:
        return content.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ConfigStructureError(f"{path} is not valid UTF-8: {exc}") from exc


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
            if token.value in _OPEN_TO_CLOSE:
                index = pairs[index] + 1
            else:
                index += 1
            continue

        value_index = index + 1
        if value_index < end and tokens[value_index].value in ("=", ":"):
            value_index += 1
        if value_index >= end:
            index += 1
            continue

        value_token = tokens[value_index]
        if value_token.value in _OPEN_TO_CLOSE:
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


def _parse_auth_file(path: Path) -> tuple[list[Token], dict[int, int]]:
    text = _read_config(path)
    if not text.strip():
        raise ConfigStructureError(f"{path} is empty")
    tokens = _tokenize(text)
    return tokens, _delimiter_pairs(tokens)


def validate_auth(leaf_path: Path, server_path: Path) -> list[str]:
    """Return authentication contract failures for a leaf and server config."""

    errors: list[str] = []
    try:
        leaf_tokens, leaf_pairs = _parse_auth_file(leaf_path)
    except ConfigStructureError as exc:
        errors.append(str(exc))
    else:
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

    try:
        server_tokens, server_pairs = _parse_auth_file(server_path)
    except ConfigStructureError as exc:
        errors.append(str(exc))
        return errors

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


def _same_object(left: os.stat_result, right: os.stat_result) -> bool:
    return left.st_dev == right.st_dev and left.st_ino == right.st_ino


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


def _directory_path_matches(descriptor: int, path: str | Path) -> bool:
    try:
        current = os.stat(path, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return stat.S_ISDIR(current.st_mode) and _same_object(
        current, os.fstat(descriptor)
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
    selected = str(path)
    before = os.stat(selected, follow_symlinks=True)
    source = os.open(selected, os.O_RDONLY)
    snapshot_directory = ""
    directory_descriptor = -1
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

        snapshot_directory = tempfile.mkdtemp(prefix=f"odysseus-{name}-")
        os.chmod(snapshot_directory, 0o700)
        directory_descriptor = os.open(
            snapshot_directory,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
        )
        snapshot_name = "executable"
        snapshot = os.open(
            snapshot_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o400,
            dir_fd=directory_descriptor,
        )
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
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory_descriptor,
        )
        snapshot_digest = hashlib.sha256()
        try:
            while True:
                chunk = os.read(snapshot_reader, 1024 * 1024)
                if not chunk:
                    break
                snapshot_digest.update(chunk)
            snapshot_state = os.fstat(snapshot_reader)
        finally:
            os.close(snapshot_reader)
        if (
            not snapshot_signed
            and not hmac.compare_digest(
                source_digest.digest(), snapshot_digest.digest()
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
            digest=snapshot_digest.digest(),
            interpreter=interpreter,
        )
        bound.verify()
        directory_descriptor = -1
        snapshot_directory = ""
        interpreter = None
        return bound
    finally:
        os.close(source)
        if directory_descriptor >= 0:
            os.fchmod(directory_descriptor, 0o700)
            try:
                os.unlink("executable", dir_fd=directory_descriptor)
            except FileNotFoundError:
                pass
            os.close(directory_descriptor)
        if snapshot_directory:
            try:
                os.rmdir(snapshot_directory)
            except FileNotFoundError:
                pass
        if interpreter is not None:
            interpreter.close()


def _popen_bound(
    executable: BoundExecutable,
    arguments: Sequence[str],
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
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=launch.directory_descriptor,
    )
    try:
        _verify_open_executable(launch, launch_descriptor)
        command = [executable.name]
        inherited = [launch_descriptor, launch.directory_descriptor]
        if executable.interpreter is not None:
            script_descriptor = os.open(
                executable.snapshot_name,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=executable.directory_descriptor,
            )
            _verify_open_executable(executable, script_descriptor)
            inherited.append(script_descriptor)
            command.append(f"/dev/fd/{script_descriptor}")
        command.extend(arguments)
        environment = dict(kwargs.pop("env"))
        environment["PATH"] = os.defpath
        launch_path = f"/proc/self/fd/{launch_descriptor}"
        return subprocess.Popen(
            command,
            executable=launch_path,
            env=environment,
            pass_fds=tuple(inherited),
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
    content = bytearray()
    os.lseek(descriptor, 0, os.SEEK_SET)
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        content.extend(chunk)
    current = os.fstat(descriptor)
    os.lseek(descriptor, 0, os.SEEK_SET)
    if (
        not stat.S_ISREG(current.st_mode)
        or current.st_uid != os.geteuid()
        or current.st_nlink != 1
        or stat.S_IMODE(current.st_mode) != 0o500
        or not _same_file_state(executable.snapshot_state, current)
        or hashlib.sha256(content).digest() != executable.digest
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


def _verify_private_directory(path: Path, descriptor: int) -> None:
    current = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(current.st_mode)
        or current.st_uid != os.geteuid()
        or stat.S_IMODE(current.st_mode) != 0o700
        or not _directory_path_matches(descriptor, path)
    ):
        raise RuntimeError(f"private child-process workspace changed: {path}")


def _run_supervised(
    executable: BoundExecutable,
    arguments: Sequence[str],
    *,
    environment: dict[str, str],
    workspace: Path,
    boundary: Callable[[], None],
) -> CommandResult:
    """Run one snapshot with bounded output, time, and descendants."""
    executable.verify()
    process: subprocess.Popen[bytes] | None = None
    stream_selector = selectors.DefaultSelector()
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    failure: str | None = None
    try:
        process = _popen_bound(
            executable,
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            cwd=workspace,
            start_new_session=True,
        )
        if process.stdout is None or process.stderr is None:
            raise RuntimeError(f"could not capture {executable.name} output")
        stream_selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        stream_selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        deadline = time.monotonic() + PARSER_TIMEOUT_SECONDS
        while process.poll() is None or stream_selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                failure = (
                    f"{executable.name} timed out after "
                    f"{PARSER_TIMEOUT_SECONDS:g} seconds"
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
            if not _terminate_process_group(process):
                failure += "; process group did not become extinct"
        else:
            process.wait(timeout=KILL_GRACE_SECONDS)
            if _process_group_exists(process.pid):
                failure = f"{executable.name} left running descendants"
                if not _terminate_process_group(process):
                    failure += "; process group did not become extinct"
    except BaseException:
        if process is not None:
            _terminate_process_group(process)
        raise
    finally:
        stream_selector.close()
        if process is not None:
            if process.stdout is not None:
                process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()
            executable.verify()
            boundary()
    if failure is not None:
        raise RuntimeError(failure)
    if process is None:
        raise RuntimeError(f"could not start {executable.name}")
    return CommandResult(
        process.returncode,
        bytes(buffers["stdout"]).decode("utf-8", errors="replace"),
        bytes(buffers["stderr"]).decode("utf-8", errors="replace"),
    )


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


def _generate_certificates(
    workspace: Path, environment: dict[str, str]
) -> dict[str, Path]:
    openssl = shutil.which("openssl", path=environment["PATH"])
    if openssl is None:
        raise RuntimeError("openssl is required to create NATS parser fixtures")
    executable = _bind_executable(Path(openssl), "openssl")
    workspace_descriptor = -1
    key_path = workspace / "server-key.pem"
    cert_path = workspace / "server-cert.pem"
    arguments = [
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-keyout",
        str(key_path),
        "-out",
        str(cert_path),
        "-days",
        "1",
        "-nodes",
        "-subj",
        "/CN=nats-config-validation",
    ]
    try:
        workspace_descriptor = os.open(
            workspace,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
        )
        completed = _run_supervised(
            executable,
            arguments,
            environment=environment,
            workspace=workspace,
            boundary=lambda: _verify_private_directory(
                workspace, workspace_descriptor
            ),
        )
    except (OSError, RuntimeError) as exc:
        raise RuntimeError(f"could not create NATS parser certificates: {exc}") from exc
    finally:
        if workspace_descriptor >= 0:
            os.close(workspace_descriptor)
        executable.close()
    if completed.returncode != 0:
        detail = completed.stderr.strip().splitlines()
        message = detail[-1] if detail else f"exit {completed.returncode}"
        raise RuntimeError(f"could not create NATS parser certificates: {message}")
    os.chmod(key_path, 0o600)
    os.chmod(cert_path, 0o600)
    return {
        "cert_file": cert_path,
        "key_file": key_path,
        "ca_file": cert_path,
    }


def _render_for_parser(text: str, workspace: Path, environment: dict[str, str]) -> str:
    if not _CERT_ASSIGNMENT.search(text):
        return text
    certificates = _generate_certificates(workspace, environment)

    def replace(match: re.Match[str]) -> str:
        quote = match.group("quote")
        field = match.group("field")
        return f"{match.group('prefix')}{quote}{certificates[field]}{quote}"

    return _CERT_ASSIGNMENT.sub(replace, text)


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
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=destination_descriptor,
        )
        try:
            observed = bytearray()
            while len(observed) <= MAX_PARSER_BINARY_BYTES:
                chunk = os.read(reader, 1024 * 1024)
                if not chunk:
                    break
                observed.extend(chunk)
            observed_state = os.fstat(reader)
        finally:
            os.close(reader)
        if (
            not _same_file_state(final_state, observed_state)
            or bytes(observed) != parser_bytes
        ):
            raise RuntimeError("materialized nats-server bytes changed")
        verify_destination("after materialization")
        os.fsync(destination_descriptor)
        verify_destination("after directory fsync")
    except BaseException as exc:
        if descriptor >= 0:
            os.close(descriptor)
        if created_state is not None:
            try:
                direct = os.stat(
                    parser_name,
                    dir_fd=destination_descriptor,
                    follow_symlinks=False,
                )
                if _same_object(created_state, direct):
                    os.unlink(parser_name, dir_fd=destination_descriptor)
                    os.fsync(destination_descriptor)
            except FileNotFoundError:
                pass
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
    with tempfile.TemporaryDirectory(prefix="odysseus-nats-parser-") as temp_name:
        workspace = Path(temp_name)
        try:
            os.chmod(workspace, 0o700)
            yield provision_nats_server(workspace)
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
) -> str | None:
    owned = not isinstance(parser, BoundExecutable)
    try:
        executable = (
            _bind_executable(parser, "nats-server")
            if isinstance(parser, Path)
            else parser
        )
    except (OSError, RuntimeError) as exc:
        return f"could not verify nats-server parser: {exc}"
    workspace_descriptor = -1
    if boundary is None:
        try:
            workspace_descriptor = os.open(
                workspace,
                os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
            )
        except OSError as exc:
            if owned:
                executable.close()
            return f"could not verify nats-server parser: {exc}"

        def verify_workspace() -> None:
            _verify_private_directory(workspace, workspace_descriptor)

        boundary = verify_workspace
    try:
        try:
            completed = _run_supervised(
                executable,
                ("--version",),
                environment=environment,
                workspace=workspace,
                boundary=boundary,
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
        invalid_canary = workspace / "malformed-semantic-canary.conf"
        valid_canary = workspace / "valid-semantic-canary.conf"
        invalid_canary.write_text("authorization = []\n", encoding="utf-8")
        valid_canary.write_text("port = 4222\n", encoding="utf-8")
        os.chmod(invalid_canary, 0o600)
        os.chmod(valid_canary, 0o600)
        try:
            invalid_result = _run_supervised(
                executable,
                ("-t", "-c", str(invalid_canary)),
                environment=environment,
                workspace=workspace,
                boundary=boundary,
            )
            valid_result = _run_supervised(
                executable,
                ("-t", "-c", str(valid_canary)),
                environment=environment,
                workspace=workspace,
                boundary=boundary,
            )
        except (OSError, RuntimeError) as exc:
            return f"could not run nats-server semantic canaries: {exc}"
        if invalid_result.returncode == 0:
            return "nats-server parser accepted the malformed semantic canary"
        if valid_result.returncode != 0:
            return "nats-server parser rejected the valid semantic canary"
        return None
    finally:
        if workspace_descriptor >= 0:
            os.close(workspace_descriptor)
        if owned:
            executable.close()


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
        with tempfile.TemporaryDirectory(
            prefix="odysseus-nats-validate-"
        ) as temp_name:
            workspace = Path(temp_name)
            os.chmod(workspace, 0o700)
            workspace_descriptor = os.open(
                workspace,
                os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
            )

            def verify_workspace() -> None:
                _verify_private_directory(workspace, workspace_descriptor)

            boundary = verify_workspace
            try:
                environment = _controlled_environment(workspace)
                parser_error = _verify_parser(
                    executable, workspace, environment, boundary
                )
                if parser_error is not None:
                    print(f"ERROR: {parser_error}", file=sys.stderr)
                    return 1
                for number, config in enumerate(configs):
                    try:
                        text = _read_config(config)
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
                    try:
                        rendered = _render_for_parser(text, workspace, environment)
                    except RuntimeError as exc:
                        print(f"FAILED: {config} -- {exc}", file=sys.stderr)
                        failed += 1
                        continue
                    rendered_path = workspace / f"config-{number}.conf"
                    rendered_path.write_text(rendered, encoding="utf-8")
                    os.chmod(rendered_path, 0o600)
                    try:
                        completed = _run_supervised(
                            executable,
                            ("-t", "-c", str(rendered_path)),
                            environment=environment,
                            workspace=workspace,
                            boundary=boundary,
                        )
                    except (OSError, RuntimeError) as exc:
                        print(
                            f"FAILED: {config} -- nats-server parser failed: {exc}",
                            file=sys.stderr,
                        )
                        failed += 1
                        continue
                    if completed.returncode != 0:
                        parser_output = (
                            completed.stderr or completed.stdout
                        ).strip()
                        parser_output = parser_output.replace(
                            str(rendered_path), str(config)
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
                    print(f"OK: {config}")
            finally:
                os.close(workspace_descriptor)
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
