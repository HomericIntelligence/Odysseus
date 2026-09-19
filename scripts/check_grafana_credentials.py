#!/usr/bin/env python3
"""Fail-closed gate (#179): documented Grafana default creds must carry an
adjacent rotation WARNING, and anonymous dashboard read must be explicitly
marked e2e-only. Scope is `git ls-files` — THIS repo's tracked files only,
never submodule content this repo cannot edit. `--self-test` runs unit checks.
"""
import ast
import re
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath

_TRACKED_SCAN_IMPORT_ERROR: Exception | None = None
try:
    from tracked_scan import UnsafeTrackedPathError, read_regular_no_follow
except (ImportError, OSError) as exc:  # Report unavailable from main/_run.
    _TRACKED_SCAN_IMPORT_ERROR = exc

    class UnsafeTrackedPathError(RuntimeError):
        """Placeholder used only while the shared reader is unavailable."""

    read_regular_no_follow = None  # type: ignore[assignment]

CRED_RE = re.compile(r"admin\s*/\s*admin", re.IGNORECASE)
# Accept one narrow affirmative admonition grammar. The action must immediately
# follow the marker and directly name the credential object; advisory prose that
# merely contains the same words is not authority for the exception.
AFFIRMATIVE_WARNING_RE = re.compile(
    r"^\s*(?:>\s*)?(?:\*\*)?(?:warning|caution|important)\b"
    r"\s*:?\s*(?:\*\*)?\s*"
    r"(?:rotate|change|replace)\s+"
    r"(?:(?:this|the|that|default|documented|example|grafana|admin)\s+){0,3}"
    r"(?:password|credentials?|secrets?|admin\s*/\s*admin)\b"
    r"(?:\s+(?:before\s+(?:any\s+production\s+or\s+shared-network\s+use|"
    r"(?:any\s+)?production(?:\s+use)?)|immediately|now))?"
    r"[.!]?\s*$",
    re.IGNORECASE,
)
ANON_NAME = "GF_AUTH_ANONYMOUS_ENABLED"
ANON_NAME_RE = re.compile(rf"\b{ANON_NAME}\b", re.IGNORECASE)
YAML_HEX_ESCAPE_RE = re.compile(
    r"\\x(?P<x>[0-9a-fA-F]{2})|\\u(?P<u>[0-9a-fA-F]{4})|"
    r"\\U(?P<U>[0-9a-fA-F]{8})"
)
# Only an affirmative YAML comment is authority for this exception. Incidental
# or negated prose containing the same words must not satisfy the gate.
E2E_MARKER = re.compile(r"^\s*#\s*e2e-only\s*:", re.IGNORECASE)
ANON_E2E_PATHS = frozenset({"docker-compose.e2e.yml"})
WARN_WINDOW = 3      # docs: forward look-ahead from the credential line
ANON_LOOKBACK = 2   # compose: lines above the flag the e2e-only marker may sit on


def _is_rotation_warning(line: str) -> bool:
    return bool(AFFIRMATIVE_WARNING_RE.fullmatch(line))


def _marker_is_yaml_comment(
    lines: list[str], marker_index: int, setting_index: int
) -> bool:
    """Accept only a sibling-indented physical YAML comment marker."""
    marker = lines[marker_index]
    marker_indent = len(marker) - len(marker.lstrip(" "))
    setting = lines[setting_index]
    setting_indent = len(setting) - len(setting.lstrip(" "))
    # The exemption is intentionally narrower than general YAML comment
    # placement: the marker must be a physical comment at the setting's exact
    # indentation. Block/quoted scalar content is necessarily deeper than the
    # real sibling setting and cannot grant the exception.
    return marker_indent == setting_indent


def _canonicalize_yaml_escapes(text: str) -> str:
    """Expose YAML hexadecimal escapes before the fail-closed name check."""

    def replace(match: re.Match[str]) -> str:
        digits = next(group for group in match.groups() if group is not None)
        try:
            return chr(int(digits, 16))
        except (ValueError, OverflowError):
            return match.group(0)

    return YAML_HEX_ESCAPE_RE.sub(replace, text)


def _strip_yaml_comment(text: str) -> str:
    """Strip only an unquoted YAML comment introduced after whitespace."""
    single = False
    double = False
    escaped = False
    index = 0
    while index < len(text):
        char = text[index]
        if double:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                double = False
        elif single:
            if char == "'" and index + 1 < len(text) and text[index + 1] == "'":
                index += 1
            elif char == "'":
                single = False
        elif char == '"':
            double = True
        elif char == "'":
            single = True
        elif char == "#" and (index == 0 or text[index - 1].isspace()):
            return text[:index].rstrip()
        index += 1
    return text.rstrip()


def _split_mapping(text: str) -> tuple[str, str] | None:
    """Split one simple YAML mapping at its first unquoted colon."""
    single = False
    double = False
    escaped = False
    index = 0
    while index < len(text):
        char = text[index]
        if double:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                double = False
        elif single:
            if char == "'" and index + 1 < len(text) and text[index + 1] == "'":
                index += 1
            elif char == "'":
                single = False
        elif char == '"':
            double = True
        elif char == "'":
            single = True
        elif char == ":":
            return text[:index].strip(), text[index + 1 :].strip()
        index += 1
    return None


def _decode_yaml_scalar(text: str) -> str | None:
    """Decode the bounded scalar forms accepted by Compose environment syntax."""
    text = text.strip()
    if not text:
        return ""
    if text.startswith('"'):
        try:
            value = ast.literal_eval(text)
        except (SyntaxError, ValueError):
            return None
        return value if isinstance(value, str) else None
    if text.startswith("'"):
        if not re.fullmatch(r"'(?:[^']|'')*'", text):
            return None
        return text[1:-1].replace("''", "'")
    if any(character.isspace() for character in text):
        return None
    return text


def _literal_bool(text: str) -> bool | None:
    scalar = _decode_yaml_scalar(text)
    if scalar is None:
        return None
    if scalar.casefold() == "true":
        return True
    if scalar.casefold() == "false":
        return False
    return None


def _anonymous_assignment(line: str) -> tuple[bool, bool | None]:
    """Return whether a line assigns the setting and its literal value."""
    canonical = _canonicalize_yaml_escapes(line)
    text = _strip_yaml_comment(line).strip()
    if not text or text.startswith("#"):
        return False, None

    if text.startswith("-"):
        item = _decode_yaml_scalar(text[1:].strip())
        if item is not None and "=" in item:
            key, value = item.split("=", 1)
            if key.casefold() == ANON_NAME.casefold():
                return True, _literal_bool(value)
        # A list mapping is not canonical Compose syntax, but identify it so it
        # fails as an unknown form instead of being skipped.
        text = text[1:].strip()

    mapping = _split_mapping(text)
    if mapping:
        key_text, value_text = mapping
        key = _decode_yaml_scalar(key_text)
        if key is not None and key.casefold() == ANON_NAME.casefold():
            return True, _literal_bool(value_text)

    # Any visible or hex-escaped spelling that did not match the closed grammar
    # is an unsafe/dynamic use, not an unrelated line.
    return bool(ANON_NAME_RE.search(canonical)), None


def _inside_double_quote(text: str) -> bool:
    """Return whether the end of a physical YAML line is double-quoted."""
    double = False
    escaped = False
    for char in text:
        if not double:
            if char == '"':
                double = True
            continue
        if escaped:
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == '"':
            double = False
    return double


def _logical_yaml_lines(lines: list[str]) -> list[tuple[int, str]]:
    """Join YAML double-quoted escaped line continuations for inspection."""
    logical: list[tuple[int, str]] = []
    buffer = ""
    start = 0
    for index, physical in enumerate(lines):
        if not buffer:
            start = index
            buffer = physical
        else:
            buffer += physical.lstrip()

        stripped = buffer.rstrip()
        trailing = len(stripped) - len(stripped.rstrip("\\"))
        if _inside_double_quote(stripped) and trailing % 2 == 1:
            buffer = stripped[:-1]
            continue
        logical.append((start, buffer))
        buffer = ""
    if buffer:
        logical.append((start, buffer))
    return logical


def _environment_lines(lines: list[str]) -> set[int]:
    """Return physical line indexes belonging to Compose environment nodes."""
    indexes: set[int] = set()
    environment_indent: int | None = None
    for index, physical in enumerate(lines):
        text = _strip_yaml_comment(physical)
        if not text.strip():
            continue
        indent = len(text) - len(text.lstrip(" "))
        if environment_indent is not None:
            if indent > environment_indent:
                indexes.add(index)
                continue
            environment_indent = None

        mapping = _split_mapping(text.strip())
        if mapping is None:
            continue
        key = _decode_yaml_scalar(mapping[0])
        if key is None or key.casefold() != "environment":
            continue
        indexes.add(index)
        if not mapping[1].strip():
            environment_indent = indent
    return indexes


def _dynamic_environment_key(line: str) -> bool:
    """Reject Compose interpolation in an environment variable name."""
    text = _strip_yaml_comment(line).strip()
    if not text:
        return False

    mapping = _split_mapping(text)
    if mapping is not None:
        outer_key = _decode_yaml_scalar(mapping[0])
        if outer_key is not None and outer_key.casefold() == "environment":
            value = mapping[1]
            # Inline list and mapping forms. Values may be dynamic; only a
            # variable-name position is rejected here.
            if re.search(
                r"(?:^|[\[{,])\s*['\"]?\s*\$\{[^}\r\n]+\}"
                r"(?:[^='\"\r\n]*=|\s*['\"]?\s*:)",
                value,
            ):
                return True
            return False

    if text.startswith("-"):
        item = _decode_yaml_scalar(text[1:].strip())
        if item is None:
            item = text[1:].strip().strip("'\"")
        key = item.split("=", 1)[0]
        return "$" in key

    if mapping is not None:
        key = _decode_yaml_scalar(mapping[0])
        if key is None:
            key = mapping[0]
        return "$" in key
    return False


def _environment_uses_yaml_indirection(line: str) -> bool:
    """Reject aliases, anchors, and merge keys on an environment node/member."""
    text = _strip_yaml_comment(line)
    return bool(
        re.search(r"(?:^|[\s\[{,:-])[&*](?=[^\s\[\]{},])", text)
        or re.search(r"(?:^|[\s\[{,])<<\s*:", text)
    )


def _grafana_env_file_targets(lines: list[str]) -> list[tuple[int, str | None]]:
    """Return literal short-syntax env_file entries for the Grafana service.

    ``None`` marks an entry whose syntax is not a single literal scalar.  This
    intentionally rejects interpolation, aliases, inline collections, and the
    long mapping syntax rather than attempting a partial Compose parser.
    """
    targets: list[tuple[int, str | None]] = []
    services_indent: int | None = None
    service_indent: int | None = None
    grafana_service = False
    env_file_indent: int | None = None
    env_file_line: int | None = None
    env_file_had_entry = False

    for index, physical in enumerate(lines):
        text = _strip_yaml_comment(physical)
        if not text.strip():
            continue
        indent = len(text) - len(text.lstrip(" "))
        stripped = text.strip()

        if env_file_indent is not None:
            if indent > env_file_indent:
                env_file_had_entry = True
                if not stripped.startswith("-") or _environment_uses_yaml_indirection(
                    physical
                ):
                    targets.append((index, None))
                else:
                    targets.append((index, _decode_yaml_scalar(stripped[1:].strip())))
                continue
            if not env_file_had_entry and env_file_line is not None:
                targets.append((env_file_line, None))
            env_file_indent = None
            env_file_line = None
            env_file_had_entry = False

        mapping = _split_mapping(stripped)
        key = _decode_yaml_scalar(mapping[0]) if mapping is not None else None

        if services_indent is not None and indent <= services_indent:
            services_indent = None
            service_indent = None
            grafana_service = False

        if services_indent is None:
            if (
                mapping is not None
                and key is not None
                and key.casefold() == "services"
            ):
                if mapping[1]:
                    targets.append((index, None))
                else:
                    services_indent = indent
            continue

        if service_indent is None:
            service_indent = indent

        if indent == service_indent:
            if _environment_uses_yaml_indirection(physical):
                targets.append((index, None))
                grafana_service = False
                continue
            is_grafana = bool(
                mapping is not None
                and key is not None
                and key.casefold() == "grafana"
            )
            if is_grafana and mapping is not None and mapping[1]:
                targets.append((index, None))
            grafana_service = is_grafana and mapping is not None and not mapping[1]
            continue

        if not grafana_service or mapping is None or key is None:
            continue
        if _environment_uses_yaml_indirection(physical):
            targets.append((index, None))
            continue
        if key.casefold() != "env_file":
            continue
        if not mapping[1]:
            env_file_indent = indent
            env_file_line = index
            continue
        targets.append((index, _decode_yaml_scalar(mapping[1])))

    if (
        env_file_indent is not None
        and not env_file_had_entry
        and env_file_line is not None
    ):
        targets.append((env_file_line, None))
    return targets


def _bind_env_file_target(compose_relative: str, target: str) -> str | None:
    """Bind one literal Compose env_file path inside the repository."""
    if (
        not target
        or target[0] in "[{!&*|>"
        or "$" in target
        or "\x00" in target
        or "\n" in target
        or "\r" in target
    ):
        return None
    path = PurePosixPath(target)
    if path.is_absolute() or ".." in path.parts:
        return None
    bound = PurePosixPath(compose_relative).parent / path
    if not bound.parts or any(part in {"", ".", ".."} for part in bound.parts):
        return None
    return bound.as_posix()


def _has_e2e_marker(
    lines: list[str],
    setting_index: int,
    *,
    allowed_indexes: set[int] | None = None,
) -> bool:
    """Return whether a same-indent e2e-only comment authorizes a setting."""
    context_start = max(0, setting_index - ANON_LOOKBACK)
    return any(
        (allowed_indexes is None or marker_index in allowed_indexes)
        and E2E_MARKER.search(lines[marker_index])
        and _marker_is_yaml_comment(lines, marker_index, setting_index)
        for marker_index in range(context_start, setting_index + 1)
    )


def _env_comment_lines(lines: list[str]) -> set[int]:
    """Return e2e marker lines that are outside multiline dotenv quotes."""
    indexes: set[int] = set()
    quote: str | None = None
    for index, line in enumerate(lines):
        if quote is None and E2E_MARKER.search(line):
            indexes.add(index)

        escaped = False
        for offset, character in enumerate(line):
            if quote is not None:
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == quote:
                    quote = None
                continue
            if character == "#" and (offset == 0 or line[offset - 1].isspace()):
                break
            if character in {"'", '"'}:
                quote = character
    return indexes


def _git_tracked(root: Path, patterns: list[str]) -> list[str]:
    """Return tracked files matching patterns.

    Bounds the scan to THIS repo's index, excluding all submodules and
    untracked/gitignored trees.
    """
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", *patterns],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return [relative for relative in out.split("\0") if relative]


def check_docs(root: Path) -> list[str]:
    """Check tracked markdown files for admin/admin credentials lacking a rotation warning."""
    errs: list[str] = []
    for relative in _git_tracked(root, ["*.md"]):
        content = read_regular_no_follow(root, relative)
        if content is None:
            continue
        lines = content.decode("utf-8", errors="replace").splitlines()
        for i, line in enumerate(lines):
            if CRED_RE.search(line):
                window = lines[i : i + 1 + WARN_WINDOW]
                if not any(_is_rotation_warning(w) for w in window):
                    errs.append(
                        f"{relative}:{i + 1}: 'admin/admin' "
                        f"with no rotation warning within {WARN_WINDOW} lines"
                    )
    return errs


def check_compose(root: Path) -> list[str]:
    """Check tracked YAML files for anonymous Grafana read lacking an e2e-only marker."""
    errs: list[str] = []
    tracked = frozenset(_git_tracked(root, []))
    for relative in _git_tracked(root, ["*.yml", "*.yaml"]):
        content = read_regular_no_follow(root, relative)
        if content is None:
            continue
        lines = content.decode("utf-8", errors="replace").splitlines()
        environment_lines = _environment_lines(lines)
        for i, line in _logical_yaml_lines(lines):
            if i in environment_lines and _environment_uses_yaml_indirection(line):
                errs.append(
                    f"{relative}:{i + 1}: Compose environment nodes must not "
                    "use YAML anchors, aliases, or merge keys"
                )
                continue
            if i in environment_lines and _dynamic_environment_key(line):
                errs.append(
                    f"{relative}:{i + 1}: Compose environment keys must be "
                    "literal; interpolation can conceal GF_AUTH_ANONYMOUS_ENABLED"
                )
                continue
            matched, value = _anonymous_assignment(line)
            if not matched:
                continue
            if value is False:
                continue
            if value is None:
                errs.append(
                    f"{relative}:{i + 1}: GF_AUTH_ANONYMOUS_ENABLED must use "
                    "a literal true or false value"
                )
                continue
            if relative not in ANON_E2E_PATHS:
                errs.append(
                    f"{relative}:{i + 1}: anonymous Grafana read is not "
                    "allowed in this tracked path"
                )
                continue
            # Look back ANON_LOOKBACK lines AND include the flag line itself,
            # so the e2e-only marker may sit on any of i-2, i-1, or i.
            if not _has_e2e_marker(lines, i):
                errs.append(
                    f"{relative}:{i + 1}: anonymous Grafana read enabled "
                    f"without an 'e2e-only' marker within {ANON_LOOKBACK} "
                    "lines above"
                )

        for i, target_text in _grafana_env_file_targets(lines):
            if target_text is None:
                errs.append(
                    f"{relative}:{i + 1}: Grafana service env_file configuration "
                    "must use literal short-syntax paths without YAML indirection"
                )
                continue
            target = _bind_env_file_target(relative, target_text)
            if target is None:
                errs.append(
                    f"{relative}:{i + 1}: Grafana env_file target must be a "
                    "literal repository-relative path"
                )
                continue
            if target not in tracked:
                errs.append(
                    f"{relative}:{i + 1}: Grafana env_file target {target!r} "
                    "is not tracked"
                )
                continue
            env_content = read_regular_no_follow(root, target)
            if env_content is None:
                errs.append(
                    f"{relative}:{i + 1}: tracked Grafana env_file target "
                    f"{target!r} is missing from the worktree"
                )
                continue
            env_lines = env_content.decode("utf-8").splitlines()
            env_markers = _env_comment_lines(env_lines)
            for env_index, env_line in enumerate(env_lines):
                matched, value = _anonymous_assignment(f"- {env_line}")
                if not matched or value is False:
                    continue
                if value is None:
                    errs.append(
                        f"{target}:{env_index + 1}: GF_AUTH_ANONYMOUS_ENABLED "
                        "must use a literal true or false value"
                    )
                    continue
                if relative not in ANON_E2E_PATHS:
                    errs.append(
                        f"{target}:{env_index + 1}: anonymous Grafana read is "
                        f"not allowed from {relative}"
                    )
                    continue
                if not _has_e2e_marker(
                    env_lines, env_index, allowed_indexes=env_markers
                ):
                    errs.append(
                        f"{target}:{env_index + 1}: anonymous Grafana read "
                        f"enabled without an 'e2e-only' marker within "
                        f"{ANON_LOOKBACK} lines above"
                    )
    return errs


def _run(root: Path) -> int:
    if _TRACKED_SCAN_IMPORT_ERROR is not None or read_regular_no_follow is None:
        sys.stderr.write(
            "Grafana credential-hygiene check unavailable: "
            f"cannot load tracked_scan: {_TRACKED_SCAN_IMPORT_ERROR}\n"
        )
        return 2
    try:
        errs = check_docs(root) + check_compose(root)
    except (UnsafeTrackedPathError, OSError, subprocess.SubprocessError, UnicodeError) as exc:
        sys.stderr.write(f"Grafana credential-hygiene check unavailable: {exc}\n")
        return 2
    if errs:
        sys.stderr.write("Grafana credential-hygiene check FAILED (#179):\n")
        for e in errs:
            sys.stderr.write(f"  - {e}\n")
        sys.stderr.write(
            f"\nFix: add `> **WARNING:** Rotate this password before production.` adjacent to the\n"
            f"credential, or mark a deliberate e2e anonymous stack with `# e2e-only:`\n"
            f"within {ANON_LOOKBACK} lines above the GF_AUTH_ANONYMOUS_ENABLED line.\n"
        )
        return 1
    print("Grafana credential hygiene OK.")
    return 0


def _self_test() -> int:
    """Embedded unit tests — stdlib only, no pytest (repo has no py test harness)."""
    cases: list[tuple[str, bool, int, int]] = []

    def case(
        name: str,
        files: dict[str, str],
        want: int,
        *,
        missing: frozenset[str] = frozenset(),
        untracked: frozenset[str] = frozenset(),
    ) -> None:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            subprocess.run(["git", "-C", d, "init", "-q"], check=True)
            for rel, body in files.items():
                p = root / rel
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(body)
            tracked = [relative for relative in files if relative not in untracked]
            subprocess.run(["git", "-C", d, "add", "--", *tracked], check=True)
            for relative in missing:
                (root / relative).unlink()
            got = _run(root)
            cases.append((name, got == want, got, want))

    # --- doc rule ---
    case(
        "creds_no_warning_fails",
        {"doc.md": "Default credentials: `admin / admin`\nNext line.\n"},
        1,
    )
    case(
        "creds_with_blank_then_warning_passes",  # mirrors the shipped doc layout
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n\n"
                "> **WARNING:** Rotate this password before any production use\n"
            )
        },
        0,
    )
    case(
        "shipped_shared_network_warning_passes",
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n\n"
                "> **WARNING:** Rotate this password before any production or "
                "shared-network use.\n"
            )
        },
        0,
    )
    case(
        "loose_word_does_not_satisfy",
        {"doc.md": "Default credentials: `admin / admin`\nWe rotate logs nightly.\n"},
        1,  # bare verb must NOT pass
    )
    case(
        "change_phrase_without_admonition_fails",
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n"
                "Replace default dashboard panels in examples.\n"
            )
        },
        1,
    )
    case(
        "unrelated_admonition_and_change_fails",
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n"
                "> **WARNING:** Change the dashboard theme before production.\n"
            )
        },
        1,
    )
    case(
        "admin_theme_warning_fails",
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n"
                "> **WARNING:** Change the admin dashboard theme before production.\n"
            )
        },
        1,
    )
    case(
        "theme_change_then_password_text_fails",
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n"
                "> **WARNING:** Change the dashboard theme; the password remains admin/admin.\n"
            )
        },
        1,
    )
    case(
        "negated_rotation_warning_fails",
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n"
                "> **WARNING:** Do not rotate or change the default password.\n"
            )
        },
        1,
    )
    case(
        "not_necessary_rotation_fails",
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n"
                "> **WARNING:** It is not necessary to change the default password.\n"
            )
        },
        1,
    )
    case(
        "refuse_rotation_fails",
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n"
                "> **WARNING:** Refuse to change this password.\n"
            )
        },
        1,
    )
    case(
        "suffix_negation_warning_fails",
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n"
                "> **WARNING:** Change the default password? No; retain admin/admin.\n"
            )
        },
        1,
    )

    # --- compose rule ---
    case(
        "anon_no_marker_fails",
        {
            "docker-compose.e2e.yml": (
                'environment:\n  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        1,
    )
    case(
        "anon_marker_one_line_above_passes",
        {
            "docker-compose.e2e.yml": (
                "  # e2e-only: anonymous viewer (no prod data)\n"
                '  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        0,
    )
    case(
        "anon_marker_two_lines_above_passes",  # EXACT shipped layout: marker @ i-2
        {
            "docker-compose.e2e.yml": (
                "  # e2e-only: anonymous Viewer for the local demo stack.\n"
                "  # Never enable this in a prod-facing stack; see #179.\n"
                '  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        0,
    )
    case(
        "anon_marker_three_lines_above_fails",  # boundary: i-3 is out of window
        {
            "docker-compose.e2e.yml": (
                "  # e2e-only: marker too far up\n"
                "  # filler comment a\n"
                "  # filler comment b\n"
                '  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        1,
    )
    case(
        "negated_marker_comment_fails",
        {
            "docker-compose.e2e.yml": (
                "  # not e2e-only: this is the production stack\n"
                '  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        1,
    )
    case(
        "marker_text_in_yaml_value_fails",
        {
            "docker-compose.e2e.yml": (
                '  deployment_note: "e2e-only is forbidden here"\n'
                '  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        1,
    )
    case(
        "marker_inside_block_scalar_fails",
        {
            "docker-compose.e2e.yml": (
                "environment:\n"
                "  NOTE: |\n"
                "    # e2e-only: this is scalar data, not a comment\n"
                "  GF_AUTH_ANONYMOUS_ENABLED: true\n"
            )
        },
        1,
    )
    case(
        "marker_after_block_scalar_content_fails",
        {
            "docker-compose.e2e.yml": (
                "environment:\n"
                "  NOTE: |\n"
                "    ordinary scalar line\n"
                "    # e2e-only: still scalar data\n"
                "  GF_AUTH_ANONYMOUS_ENABLED: true\n"
            )
        },
        1,
    )
    case(
        "marker_in_explicit_indent_scalar_fails",
        {
            "docker-compose.e2e.yml": (
                "environment:\n"
                "  NOTE: |2-\n"
                "    # e2e-only: explicit-indent scalar data\n"
                "  GF_AUTH_ANONYMOUS_ENABLED: true\n"
            )
        },
        1,
    )
    case(
        "marker_in_multiline_quote_fails",
        {
            "docker-compose.e2e.yml": (
                "environment:\n"
                "  NOTE: \"ordinary text\\\n"
                "    # e2e-only: continued quoted scalar data\"\n"
                "  GF_AUTH_ANONYMOUS_ENABLED: true\n"
            )
        },
        1,
    )
    case(
        "marker_in_unclassified_yaml_fails",
        {
            "production.yml": (
                "  # e2e-only: misleading marker in an unclassified path\n"
                '  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        1,
    )
    case(
        "dynamic_anonymous_value_fails",
        {
            "docker-compose.e2e.yml": (
                "  # e2e-only: value must still be literal\n"
                '  GF_AUTH_ANONYMOUS_ENABLED: "${GRAFANA_ANON:-true}"\n'
            )
        },
        1,
    )
    case(
        "dynamic_environment_list_key_fails",
        {
            "docker-compose.e2e.yml": (
                "environment:\n"
                '  - "${ANON_KEY}=true"\n'
            )
        },
        1,
    )
    case(
        "dynamic_environment_mapping_key_fails",
        {
            "docker-compose.e2e.yml": (
                "environment:\n"
                '  "${ANON_KEY}": true\n'
            )
        },
        1,
    )
    case(
        "aliased_environment_fragment_fails",
        {
            "docker-compose.e2e.yml": (
                "x-env: &anon_env\n"
                '  - "${ANON_KEY}=true"\n'
                "services:\n"
                "  grafana:\n"
                "    environment: *anon_env\n"
            )
        },
        1,
    )
    case(
        "environment_list_alias_fails",
        {
            "docker-compose.e2e.yml": (
                "environment:\n"
                "  - *hidden_setting\n"
            )
        },
        1,
    )
    case(
        "dotted_environment_alias_fails",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    environment: *.hidden\n"
            )
        },
        1,
    )
    case(
        "unicode_environment_alias_fails",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    environment: *\u914d\u7f6e\n"
            )
        },
        1,
    )
    case(
        "inline_environment_merge_key_fails",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    environment: {<<: {SAFE: false}}\n"
            )
        },
        1,
    )
    case(
        "dynamic_unrelated_environment_value_is_not_a_key",
        {
            "docker-compose.e2e.yml": (
                "environment:\n"
                '  OTHER_SETTING: "${OTHER_VALUE:-safe}"\n'
            )
        },
        0,
    )
    case(
        "quoted_mapping_key_in_unclassified_yaml_fails",
        {
            "production.yml": (
                '  "GF_AUTH_ANONYMOUS_ENABLED": "true"\n'
            )
        },
        1,
    )
    case(
        "quoted_list_item_in_unclassified_yaml_fails",
        {
            "production.yml": (
                '  - "GF_AUTH_ANONYMOUS_ENABLED=true"\n'
            )
        },
        1,
    )
    case(
        "quoted_list_dynamic_value_fails",
        {
            "docker-compose.e2e.yml": (
                "  # e2e-only: value must still be literal\n"
                '  - "GF_AUTH_ANONYMOUS_ENABLED=${GRAFANA_ANON:-true}"\n'
            )
        },
        1,
    )
    case(
        "escaped_mapping_key_in_unclassified_yaml_fails",
        {
            "production.yml": (
                '  "GF_AUTH_ANONYMOUS_\\u0045NABLED": "true"\n'
            )
        },
        1,
    )
    case(
        "escaped_list_key_in_unclassified_yaml_fails",
        {
            "production.yml": (
                '  - "GF_AUTH_ANONYMOUS_\\u0045NABLED=true"\n'
            )
        },
        1,
    )
    case(
        "mapping_hash_without_comment_space_is_dynamic",
        {
            "docker-compose.e2e.yml": (
                "  # e2e-only: value must still be literal\n"
                "  GF_AUTH_ANONYMOUS_ENABLED: true#suffix\n"
            )
        },
        1,
    )
    case(
        "list_hash_without_comment_space_is_dynamic",
        {
            "docker-compose.e2e.yml": (
                "  # e2e-only: value must still be literal\n"
                "  - GF_AUTH_ANONYMOUS_ENABLED=true#suffix\n"
            )
        },
        1,
    )
    case(
        "escaped_multiline_mapping_key_fails",
        {
            "production.yml": (
                '  "GF_AUTH_ANONYMOUS_ENA\\\n'
                '    BLED": "true"\n'
            )
        },
        1,
    )
    case(
        "escaped_multiline_list_key_fails",
        {
            "production.yml": (
                '  - "GF_AUTH_ANONYMOUS_ENA\\\n'
                '    BLED=true"\n'
            )
        },
        1,
    )
    case(
        "tracked_production_env_file_enablement_fails",
        {
            "production.yml": (
                "services:\n"
                "  grafana:\n"
                "    env_file:\n"
                "      - grafana.env\n"
            ),
            "grafana.env": "GF_AUTH_ANONYMOUS_ENABLED=true\n",
        },
        1,
    )
    case(
        "dotted_grafana_service_alias_with_env_file_fails",
        {
            "docker-compose.e2e.yml": (
                "x-grafana: &.shared\n"
                "  env_file: grafana.env\n"
                "services:\n"
                "  grafana: *.shared\n"
            ),
            "grafana.env": (
                "# e2e-only: anonymous viewer for the local demo stack\n"
                "GF_AUTH_ANONYMOUS_ENABLED=true\n"
            ),
        },
        1,
    )
    case(
        "dotted_services_alias_with_env_file_fails",
        {
            "docker-compose.e2e.yml": (
                "x-services: &.shared\n"
                "  grafana:\n"
                "    env_file: grafana.env\n"
                "services: *.shared\n"
            ),
            "grafana.env": (
                "# e2e-only: anonymous viewer for the local demo stack\n"
                "GF_AUTH_ANONYMOUS_ENABLED=true\n"
            ),
        },
        1,
    )
    case(
        "tracked_e2e_env_file_with_marker_passes",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    env_file: grafana.env\n"
            ),
            "grafana.env": (
                "# e2e-only: anonymous viewer for the local demo stack\n"
                "GF_AUTH_ANONYMOUS_ENABLED=true\n"
            ),
        },
        0,
    )
    case(
        "tracked_e2e_env_file_without_marker_fails",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    env_file: grafana.env\n"
            ),
            "grafana.env": "GF_AUTH_ANONYMOUS_ENABLED=true\n",
        },
        1,
    )
    case(
        "env_file_marker_inside_multiline_value_fails",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    env_file: grafana.env\n"
            ),
            "grafana.env": (
                "NOTE='ordinary text\n"
                "# e2e-only: quoted value data, not a comment\n"
                "'\n"
                "GF_AUTH_ANONYMOUS_ENABLED=true\n"
            ),
        },
        1,
    )
    case(
        "inline_env_file_collection_fails_closed",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    env_file: [grafana.env]\n"
            ),
            "grafana.env": "GF_AUTH_ANONYMOUS_ENABLED=true\n",
            "[grafana.env]": "SAFE=true\n",
        },
        1,
    )
    case(
        "tracked_env_file_literal_false_passes",
        {
            "production.yml": (
                "services:\n"
                "  grafana:\n"
                "    env_file: grafana.env\n"
            ),
            "grafana.env": "GF_AUTH_ANONYMOUS_ENABLED=false\n",
        },
        0,
    )
    case(
        "nested_compose_binds_env_file_from_its_parent",
        {
            "deploy/production.yml": (
                "services:\n"
                "  grafana:\n"
                "    env_file: ./grafana.env\n"
            ),
            "deploy/grafana.env": "GF_AUTH_ANONYMOUS_ENABLED=false\n",
        },
        0,
    )
    case(
        "dynamic_grafana_env_file_target_fails",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                '    env_file: "${GRAFANA_ENV_FILE}"\n'
            )
        },
        1,
    )
    case(
        "empty_grafana_env_file_target_fails",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    env_file:\n"
                "    image: grafana/grafana\n"
            )
        },
        1,
    )
    case(
        "missing_grafana_env_file_target_fails",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    env_file: missing.env\n"
            ),
            "missing.env": "GF_AUTH_ANONYMOUS_ENABLED=true\n",
        },
        1,
        missing=frozenset({"missing.env"}),
    )
    case(
        "untracked_grafana_env_file_target_fails",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    env_file: grafana.env\n"
            ),
            "grafana.env": "GF_AUTH_ANONYMOUS_ENABLED=true\n",
        },
        1,
        untracked=frozenset({"grafana.env"}),
    )
    case(
        "unrelated_service_dynamic_env_file_is_out_of_scope",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  helper:\n"
                '    env_file: "${HELPER_ENV_FILE}"\n'
            )
        },
        0,
    )

    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        subprocess.run(["git", "-C", d, "init", "-q"], check=True)
        compose = root / "docker-compose.e2e.yml"
        compose.write_text(
            "services:\n"
            "  grafana:\n"
            "    env_file: grafana.env\n"
        )
        env_file = root / "grafana.env"
        env_file.write_text("GF_AUTH_ANONYMOUS_ENABLED=false\n")
        subprocess.run(
            ["git", "-C", d, "add", "--", compose.name, env_file.name], check=True
        )
        env_file.unlink()
        env_file.symlink_to("missing.env")
        got = _run(root)
        cases.append(("tracked_env_file_symlink_is_unavailable", got == 2, got, 2))

    with tempfile.TemporaryDirectory() as d:
        got = _run(Path(d))
        cases.append(("inventory_failure_is_unavailable", got == 2, got, 2))

    with tempfile.TemporaryDirectory() as d:
        copied = Path(d) / "check_grafana_credentials.py"
        copied.write_bytes(Path(__file__).read_bytes())
        result = subprocess.run(
            [sys.executable, str(copied)], cwd=d, capture_output=True, text=True
        )
        cases.append(
            (
                "missing_shared_reader_is_unavailable",
                result.returncode == 2,
                result.returncode,
                2,
            )
        )

    with tempfile.TemporaryDirectory() as d:
        result = subprocess.run(
            [sys.executable, str(Path(__file__).resolve())],
            cwd=d,
            capture_output=True,
            text=True,
        )
        cases.append(
            (
                "outside_repo_is_unavailable",
                result.returncode == 2,
                result.returncode,
                2,
            )
        )

    # A tracked deletion remains visible to plain `git ls-files` until it is
    # staged. The worktree gate must scan the current filesystem instead of
    # crashing while a legitimate rename or deletion is under review.
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        subprocess.run(["git", "-C", d, "init", "-q"], check=True)
        deleted = root / "deleted.md"
        deleted.write_text("Default credentials: `admin / admin`\n")
        subprocess.run(["git", "-C", d, "add", "deleted.md"], check=True)
        deleted.unlink()
        try:
            got = _run(root)
        except FileNotFoundError:
            got = 99
        cases.append(("tracked_worktree_deletion_is_ignored", got == 0, got, 0))

    # A tracked file replaced by a symlink is not a deletion. The gate must
    # reject the worktree type change instead of following or silently skipping
    # it, including when the symlink target is missing.
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        subprocess.run(["git", "-C", d, "init", "-q"], check=True)
        replaced = root / "replaced.md"
        replaced.write_text("safe\n")
        subprocess.run(["git", "-C", d, "add", "replaced.md"], check=True)
        replaced.unlink()
        replaced.symlink_to("missing.md")
        got = _run(root)
        cases.append(("tracked_symlink_type_change_fails", got == 2, got, 2))

    failed = [c for c in cases if not c[1]]
    for name, ok, got, want in cases:
        print(f"  [{'PASS' if ok else 'FAIL'}] {name} (got={got} want={want})")
    if failed:
        sys.stderr.write(f"SELF-TEST FAILED: {len(failed)}/{len(cases)} cases\n")
        return 1
    print(f"SELF-TEST OK: {len(cases)}/{len(cases)} cases passed.")
    return 0


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return _self_test()
    if _TRACKED_SCAN_IMPORT_ERROR is not None:
        return _run(Path.cwd())
    try:
        root_text = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        if not root_text:
            raise RuntimeError("git returned an empty repository root")
        root = Path(root_text)
    except (OSError, RuntimeError, subprocess.SubprocessError, UnicodeError) as exc:
        sys.stderr.write(f"Grafana credential-hygiene check unavailable: {exc}\n")
        return 2
    return _run(root)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
