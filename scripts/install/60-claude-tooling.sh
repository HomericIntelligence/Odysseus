#!/usr/bin/env bash
# Phase 60 — Claude Code Tooling
#
# Steps:
#   1. Install Claude Code CLI (via curl installer)
#   2. Merge settings.json: register the Athena marketplace and plugin
#   3. Clone or update Mnemosyne agent brain seed
#
# Idempotent: each step checks state before acting.
#
# shellcheck disable=SC2015
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "Claude Code Tooling"

# ─── Step 1: Claude Code CLI ─────────────────────────────────────────────────
# Claude Code is developer/interactive tooling: its installer is network-gated
# (fetches from claude.ai) and it is not required for a headless worker to run
# jobs. So a missing/undownloadable CLI is a WARN, not a hard fail — the same
# non-fatal treatment Mnemosyne gets below, and consistent
# with the network-gated precedent in 40-pixi-envs.sh. This keeps a clean-image
# `--role worker` install at exit 0 when the CLI can't be fetched (#393).
_probe_claude_version() {
    local executable="$1"
    local output
    local status
    output="$("$executable" --version 2>&1)"
    status=$?
    _claude_version_line="${output%%$'\n'*}"
    if [[ "$status" -ne 0 ]] || \
       [[ ! "$_claude_version_line" =~ (^|[^0-9])[0-9]+\.[0-9]+(\.[0-9]+)?([^0-9]|$) ]]; then
        return 1
    fi
    return 0
}

if has_cmd claude; then
    if _probe_claude_version "$(command -v claude)"; then
        check_pass "claude $_claude_version_line"
    else
        check_fail "claude — version check failed (expected a successful semantic version)"
    fi
else
    if [[ "${INSTALL:-false}" == "true" ]]; then
        echo -e "    ${BLUE}→${NC} Installing Claude Code CLI..."
        if curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1; then
            _claude_executable=""
            if has_cmd claude; then
                _claude_executable="$(command -v claude)"
            elif [[ -x "$HOME/.local/bin/claude" ]]; then
                _claude_executable="$HOME/.local/bin/claude"
            fi
            if [[ -n "$_claude_executable" ]] && \
               _probe_claude_version "$_claude_executable"; then
                check_pass "claude $_claude_version_line installed"
            else
                check_warn "claude — installer completed but no executable returned a valid version"
            fi
        else
            check_warn "claude — install failed (network-gated; not required for a headless worker)"
        fi
        # Add ~/.local/bin to PATH idempotently in rc files
        for RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
            if [[ -f "$RC" ]] && ! grep -q '\.local/bin' "$RC"; then
                echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$RC"
                echo -e "    ${BLUE}→${NC} Added ~/.local/bin to PATH in $RC"
            fi
        done
    else
        # Detect / check-only mode: warn (not fail) so this phase is flagged
        # for install without counting toward the exit gate.
        check_warn "claude — not installed (will attempt network install)"
    fi
fi

# ─── Step 2: settings.json merge ─────────────────────────────────────────────
SETTINGS="$HOME/.claude/settings.json"
SETTINGS_MAX_BYTES=1048576

# The Athena marketplace + plugin is the sole Claude Code surface registered
# by this install script. The Hephaestus marketplace registration that this
# script previously wrote has been removed per the user's directive; the
# `hephaestus` orchestrator library remains installable directly from the
# Hephaestus repo (pip install hephaestus[automation]) without any Claude
# Code marketplace registration required.
# URL matches .gitmodules [submodule "agentic/Athena"].
ATHENA_MARKETPLACE_NAME="Athena"
ATHENA_MARKETPLACE_URL="https://github.com/HomericIntelligence/Athena.git"
ATHENA_PLUGIN_KEY="athena@Athena"

# Plugin keys from PRE-ADR-016 installs (dead marketplace names), the
# non-canonical `hephaestus@Athena` mapping (Claude Code auto-resolved
# `hephaestus` to the Athena marketplace at some point), and the canonical
# `hephaestus@Hephaestus` key that this install script used to register but
# no longer does (per the user's directive). All three are now cleaned
# on --install — leaving any of them in enabledPlugins causes noise-level
# 404s on every plugin enumeration. Space-separated so it can be .split()
# into a Python tuple. Single source of truth — both the precondition
# diagnostic AND the merge purge derive from this; add new legacy keys
# here only.
LEGACY_PLUGIN_KEYS_CSV="hephaestus@ProjectHephaestus hephaestus@Hephaestus hephaestus@Athena"
LEGACY_MARKETPLACE_KEYS_CSV="ProjectHephaestus Hephaestus"
_do_settings_merge=false
_settings_hard_failure=false
_settings_binding="settings-binding-v1:absent"

if [[ -L "$SETTINGS" ]]; then
    _settings_hard_failure=true
    check_fail "settings.json — symbolic links are not permitted"
elif [[ -e "$SETTINGS" && ! -f "$SETTINGS" ]]; then
    _settings_hard_failure=true
    check_fail "settings.json — path must be a regular file"
elif [[ -f "$SETTINGS" ]]; then
    # Per-item diagnostic (Athena marketplace + plugin conformance). Python's
    # stdout is captured into DIAGNOSTICS via command substitution. Safe
    # because the data flows through the COMMAND (stdout -> bash variable via
    # $()), not through Python-to-bash variable scope (which doesn't work;
    # see bug note in the merge block below). Detects canonical-marketplace
    # presence, missing plugin keys, and any non-canonical legacy plugin
    # keys. URL comparison tolerates trailing-slash and with/without-.git
    # variants.
    if DIAGNOSTICS=$(python3 -I -S - \
        "$SETTINGS" \
        "$ATHENA_MARKETPLACE_NAME" \
        "$ATHENA_MARKETPLACE_URL" \
        "$ATHENA_PLUGIN_KEY" \
        "$LEGACY_PLUGIN_KEYS_CSV" \
        "$LEGACY_MARKETPLACE_KEYS_CSV" \
        "$SETTINGS_MAX_BYTES" \
        2>/dev/null <<'PYEOF'
import hashlib
import json
import os
import stat
import sys
(
    settings_path,
    athena_marketplace_name,
    athena_marketplace_url,
    athena_plugin_key,
    legacy_plugin_keys_csv,
    legacy_marketplace_keys_csv,
    settings_max_bytes_text,
) = sys.argv[1:]
settings_max_bytes = int(settings_max_bytes_text)

class SettingsSecurityError(RuntimeError):
    pass

def inspection_failure(message):
    print(f"inspection failed: {message}")
    sys.exit(2)

def descriptor_flags():
    no_follow = getattr(os, "O_NOFOLLOW", 0)
    directory = getattr(os, "O_DIRECTORY", 0)
    if (
        not no_follow
        or not directory
        or os.open not in getattr(os, "supports_dir_fd", set())
    ):
        raise SettingsSecurityError(
            "settings.json requires descriptor-relative O_NOFOLLOW support"
        )
    return no_follow, directory

def read_settings_safely(path):
    no_follow, directory = descriptor_flags()
    settings_directory = os.path.dirname(path)
    home_directory = os.path.dirname(settings_directory)
    parent_name = os.path.basename(settings_directory)
    settings_name = os.path.basename(path)
    if (
        not os.path.isabs(path)
        or not home_directory
        or parent_name != ".claude"
        or settings_name != "settings.json"
    ):
        raise SettingsSecurityError("settings.json path is not canonical")

    home_descriptor = None
    parent_descriptor = None
    settings_descriptor = None
    try:
        home_descriptor = os.open(
            home_directory, os.O_RDONLY | directory | no_follow
        )
        parent_descriptor = os.open(
            parent_name,
            os.O_RDONLY | directory | no_follow,
            dir_fd=home_descriptor,
        )
        parent_state = os.fstat(parent_descriptor)
        if (
            not stat.S_ISDIR(parent_state.st_mode)
            or parent_state.st_uid != os.geteuid()
            or stat.S_IMODE(parent_state.st_mode) not in (0o700, 0o755)
        ):
            raise SettingsSecurityError(
                "settings.json parent must be an owner-private direct directory "
                "or the owner-owned legacy mode 0755"
            )
        settings_descriptor = os.open(
            settings_name,
            os.O_RDONLY | no_follow,
            dir_fd=parent_descriptor,
        )
        settings_state = os.fstat(settings_descriptor)
        if not stat.S_ISREG(settings_state.st_mode):
            raise SettingsSecurityError("settings.json must be a regular file")
        if settings_state.st_uid != os.geteuid():
            raise SettingsSecurityError("settings.json must be owned by this user")
        if settings_state.st_nlink != 1:
            raise SettingsSecurityError("settings.json must have exactly one link")
        chunks = []
        payload_size = 0
        while True:
            chunk = os.read(
                settings_descriptor,
                min(65536, settings_max_bytes + 1 - payload_size),
            )
            if not chunk:
                break
            chunks.append(chunk)
            payload_size += len(chunk)
            if payload_size > settings_max_bytes:
                raise SettingsSecurityError(
                    "settings.json exceeds the "
                    f"{settings_max_bytes}-byte limit"
                )
        payload = b"".join(chunks)
        settings = json.loads(payload.decode("utf-8"))
        return (
            settings,
            parent_state,
            settings_state,
            hashlib.sha256(payload).hexdigest(),
        )
    except SettingsSecurityError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SettingsSecurityError(
            f"settings.json parent or source could not be read safely: "
            f"{type(error).__name__}: {error}"
        ) from error
    finally:
        if settings_descriptor is not None:
            os.close(settings_descriptor)
        if parent_descriptor is not None:
            os.close(parent_descriptor)
        if home_descriptor is not None:
            os.close(home_descriptor)

try:
    s, parent_state, settings_state, settings_digest = read_settings_safely(
        settings_path
    )
except SettingsSecurityError as error:
    inspection_failure(str(error))
if not isinstance(s, dict):
    print("inspection failed: settings root must be a JSON object")
    sys.exit(2)
mp = s.get("extraKnownMarketplaces", {})
pl = s.get("enabledPlugins", {})
if not isinstance(mp, dict) or not isinstance(pl, dict):
    print("inspection failed: marketplace and plugin settings must be JSON objects")
    sys.exit(2)

def malformed_field(field, expected):
    print(f"inspection failed: {field} must be {expected}")
    sys.exit(2)

def get_source(name):
    if name not in mp:
        return {}
    e = mp[name]
    if not isinstance(e, dict):
        malformed_field(f"extraKnownMarketplaces.{name}", "a JSON object")
    if "source" not in e:
        return {}
    src = e["source"]
    if not isinstance(src, dict):
        malformed_field(
            f"extraKnownMarketplaces.{name}.source", "a JSON object"
        )
    return src

def get_url(name):
    src = get_source(name)
    if "url" not in src:
        return ""
    url = src["url"]
    if not isinstance(url, str):
        malformed_field(
            f"extraKnownMarketplaces.{name}.source.url", "a string"
        )
    return url

def get_source_kind(name):
    src = get_source(name)
    if "source" not in src:
        return ""
    source_kind = src["source"]
    if not isinstance(source_kind, str):
        malformed_field(
            f"extraKnownMarketplaces.{name}.source.source", "a string"
        )
    return source_kind

def norm(u):
    return u.rstrip("/").removesuffix(".git") if u else ""

actual_url = get_url(athena_marketplace_name)
actual_source_kind = get_source_kind(athena_marketplace_name)
url_ok = norm(actual_url) == norm(athena_marketplace_url)
source_kind_ok = actual_source_kind == "git"
a_ok = url_ok and source_kind_ok
p_a = pl.get(athena_plugin_key) is True
legacy = [k for k in legacy_plugin_keys_csv.split() if k in pl]
legacy_marketplaces = [k for k in legacy_marketplace_keys_csv.split() if k in mp]
legacy_parent_mode = stat.S_IMODE(parent_state.st_mode) == 0o755

if a_ok and p_a and not legacy and not legacy_marketplaces and not legacy_parent_mode:
    sys.exit(0)

print(
    "settings-binding-v1:"
    f"{parent_state.st_dev}:{parent_state.st_ino}:"
    f"{settings_state.st_dev}:{settings_state.st_ino}:{settings_digest}"
)

def fmt_marketplace(name, url_matches, actual, source_kind_matches, source_kind):
    if url_matches and source_kind_matches:
        return "marketplace " + name + ": present"
    problems = []
    if not source_kind_matches:
        problems.append(
            "wrong source kind (found: "
            + (source_kind or "not configured")
            + "; expected: git)"
        )
    if not url_matches:
        problems.append(
            "missing or wrong URL (found: " + (actual or "not configured") + ")"
        )
    return "marketplace " + name + ": " + "; ".join(problems)

out = []
out.append(
    fmt_marketplace(
        athena_marketplace_name,
        url_ok,
        actual_url,
        source_kind_ok,
        actual_source_kind,
    )
)
out.append("plugin " + athena_plugin_key + ": " + ("enabled" if p_a else "missing or disabled"))
if legacy:
    out.append("non-canonical plugin keys present (will be cleaned on --install): " + ", ".join(legacy))
if legacy_marketplaces:
    out.append("retired marketplaces present (will be cleaned on --install): " + ", ".join(legacy_marketplaces))
if legacy_parent_mode:
    out.append(
        "settings parent mode 0755 requires --install migration to 0700"
    )
print("\n".join(out))
sys.exit(1)
PYEOF
); then
        check_pass "settings.json — Athena marketplace and plugin configured"
    else
        _settings_diagnostic_status=$?
        if [[ "$_settings_diagnostic_status" -ne 1 ]]; then
            _settings_hard_failure=true
            check_fail "settings.json — inspection failed:
$DIAGNOSTICS"
        else
            _settings_binding="${DIAGNOSTICS%%$'\n'*}"
            if [[ "$DIAGNOSTICS" != *$'\n'* ]] || \
               [[ ! "$_settings_binding" =~ ^settings-binding-v1:[0-9]+:[0-9]+:[0-9]+:[0-9]+:[0-9a-f]{64}$ ]]; then
                _settings_hard_failure=true
                check_fail "settings.json — inspection returned an invalid source binding"
            else
                DIAGNOSTICS="${DIAGNOSTICS#*$'\n'}"
                if [[ "${INSTALL:-false}" == "true" ]]; then
                    _do_settings_merge=true
                    echo -e "    ${BLUE}→${NC} Reconciling the Athena marketplace and plugin"
                else
                    check_warn "settings.json — Athena marketplace+plugin gap detected:
$DIAGNOSTICS
tip: re-run with --install to apply the canonical fix; or manually edit ~/.claude/settings.json"
                fi
            fi
        fi
    fi
else
    if [[ "${INSTALL:-false}" == "true" ]]; then
        _do_settings_merge=true
        echo -e "    ${BLUE}→${NC} Creating the Athena marketplace and plugin settings"
    else
        check_warn "settings.json — not found (will create with --install)"
    fi
fi

if [[ "${_do_settings_merge:-false}" == "true" ]]; then
    if python3 -I -S - \
        "$SETTINGS" \
        "$ATHENA_MARKETPLACE_NAME" \
        "$ATHENA_MARKETPLACE_URL" \
        "$ATHENA_PLUGIN_KEY" \
        "$LEGACY_PLUGIN_KEYS_CSV" \
        "$LEGACY_MARKETPLACE_KEYS_CSV" \
        "$_settings_binding" \
        "$SETTINGS_MAX_BYTES" \
        <<'PYEOF'
import hashlib
import json
import os
import secrets
import stat
import sys

(
    settings_path,
    athena_marketplace_name,
    athena_marketplace_url,
    athena_plugin_key,
    legacy_plugin_keys_csv,
    legacy_marketplace_keys_csv,
    expected_binding_text,
    settings_max_bytes_text,
) = sys.argv[1:]
settings_max_bytes = int(settings_max_bytes_text)

class SettingsReconciliationError(RuntimeError):
    pass

def norm(u):
    return u.rstrip("/").removesuffix(".git") if u else ""

def reconciliation_failure(field, expected):
    raise SettingsReconciliationError(f"{field} must be {expected}")

def parse_expected_binding(value):
    if value == "settings-binding-v1:absent":
        return None
    parts = value.split(":")
    if (
        len(parts) != 6
        or parts[0] != "settings-binding-v1"
        or any(not item.isascii() or not item.isdigit() for item in parts[1:5])
        or len(parts[5]) != 64
        or any(character not in "0123456789abcdef" for character in parts[5])
    ):
        raise SettingsReconciliationError(
            "settings.json source binding is malformed"
        )
    return tuple(int(item) for item in parts[1:5]) + (parts[5],)

def descriptor_flags():
    no_follow = getattr(os, "O_NOFOLLOW", 0)
    directory = getattr(os, "O_DIRECTORY", 0)
    if (
        not no_follow
        or not directory
        or os.open not in getattr(os, "supports_dir_fd", set())
        or os.mkdir not in getattr(os, "supports_dir_fd", set())
    ):
        raise SettingsReconciliationError(
            "descriptor-relative O_NOFOLLOW settings storage is required"
        )
    return no_follow, directory

def settings_components(path):
    settings_directory = os.path.dirname(path)
    home_directory = os.path.dirname(settings_directory)
    parent_name = os.path.basename(settings_directory)
    settings_name = os.path.basename(path)
    if (
        not os.path.isabs(path)
        or not home_directory
        or parent_name != ".claude"
        or settings_name != "settings.json"
    ):
        raise SettingsReconciliationError("settings.json path is not canonical")
    return home_directory, parent_name, settings_name

def validate_parent(state, allow_legacy=False):
    mode = stat.S_IMODE(state.st_mode)
    if (
        not stat.S_ISDIR(state.st_mode)
        or state.st_uid != os.geteuid()
        or (mode != 0o700 and not (allow_legacy and mode == 0o755))
    ):
        raise SettingsReconciliationError(
            "settings.json parent must be an owner-private direct directory"
        )

def migrate_legacy_parent(
    home_descriptor, parent_descriptor, parent_name, parent_state
):
    mode = stat.S_IMODE(parent_state.st_mode)
    if mode == 0o700:
        return parent_state, False
    validate_parent(parent_state, allow_legacy=True)
    if mode != 0o755:
        raise SettingsReconciliationError(
            "settings.json parent is not the supported legacy mode 0755"
        )
    os.fchmod(parent_descriptor, 0o700)
    os.fsync(parent_descriptor)
    migrated_state = os.fstat(parent_descriptor)
    validate_parent(migrated_state)
    if (migrated_state.st_dev, migrated_state.st_ino) != (
        parent_state.st_dev,
        parent_state.st_ino,
    ):
        raise SettingsReconciliationError(
            "settings.json parent changed during mode migration"
        )

    no_follow, directory = descriptor_flags()
    rebound_descriptor = None
    try:
        rebound_descriptor = os.open(
            parent_name,
            os.O_RDONLY | directory | no_follow,
            dir_fd=home_descriptor,
        )
        rebound_state = os.fstat(rebound_descriptor)
        validate_parent(rebound_state)
        if (rebound_state.st_dev, rebound_state.st_ino) != (
            migrated_state.st_dev,
            migrated_state.st_ino,
        ):
            raise SettingsReconciliationError(
                "settings.json parent changed during mode migration"
            )
    except SettingsReconciliationError:
        raise
    except OSError as error:
        raise SettingsReconciliationError(
            "settings.json parent changed during mode migration"
        ) from error
    finally:
        if rebound_descriptor is not None:
            os.close(rebound_descriptor)
    return migrated_state, True

def open_parent(path):
    no_follow, directory = descriptor_flags()
    home_directory, parent_name, settings_name = settings_components(path)
    home_descriptor = None
    parent_descriptor = None
    try:
        home_descriptor = os.open(
            home_directory, os.O_RDONLY | directory | no_follow
        )
    except OSError as error:
        raise SettingsReconciliationError(
            "settings.json home could not be opened safely"
        ) from error
    try:
        try:
            os.mkdir(parent_name, mode=0o700, dir_fd=home_descriptor)
            os.fsync(home_descriptor)
        except FileExistsError:
            pass
        try:
            parent_descriptor = os.open(
                parent_name,
                os.O_RDONLY | directory | no_follow,
                dir_fd=home_descriptor,
            )
        except OSError as error:
            raise SettingsReconciliationError(
                "settings.json parent could not be opened safely"
            ) from error
        parent_state, parent_migrated = migrate_legacy_parent(
            home_descriptor,
            parent_descriptor,
            parent_name,
            os.fstat(parent_descriptor),
        )
        return (
            home_descriptor,
            parent_descriptor,
            parent_name,
            settings_name,
            parent_state,
            parent_migrated,
        )
    except BaseException:
        if parent_descriptor is not None:
            os.close(parent_descriptor)
        os.close(home_descriptor)
        raise

def read_all(descriptor):
    os.lseek(descriptor, 0, os.SEEK_SET)
    chunks = []
    payload_size = 0
    while True:
        chunk = os.read(
            descriptor,
            min(65536, settings_max_bytes + 1 - payload_size),
        )
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)
        payload_size += len(chunk)
        if payload_size > settings_max_bytes:
            raise SettingsReconciliationError(
                "settings.json exceeds the "
                f"{settings_max_bytes}-byte limit"
            )

def write_all(descriptor, payload):
    offset = 0
    while offset < len(payload):
        written = os.write(descriptor, payload[offset:])
        if written <= 0:
            raise SettingsReconciliationError("settings write made no progress")
        offset += written

def serialize_settings(value):
    chunks = []
    payload_size = 1  # Account for the final newline.
    encoder = json.JSONEncoder(indent=2, ensure_ascii=True)
    for fragment in encoder.iterencode(value):
        chunk = fragment.encode("utf-8")
        payload_size += len(chunk)
        if payload_size > settings_max_bytes:
            raise SettingsReconciliationError(
                "reconciled settings exceed the "
                f"{settings_max_bytes}-byte limit"
            )
        chunks.append(chunk)
    chunks.append(b"\n")
    return b"".join(chunks)

def validate_source(state):
    if not stat.S_ISREG(state.st_mode):
        raise SettingsReconciliationError("settings.json must be a regular file")
    if state.st_uid != os.geteuid():
        raise SettingsReconciliationError("settings.json must be owned by this user")
    if state.st_nlink != 1:
        raise SettingsReconciliationError(
            "settings.json must have exactly one link"
        )

def open_source(parent_descriptor, settings_name, required):
    no_follow, _ = descriptor_flags()
    try:
        descriptor = os.open(
            settings_name,
            os.O_RDONLY | no_follow,
            dir_fd=parent_descriptor,
        )
    except FileNotFoundError:
        if required:
            raise SettingsReconciliationError(
                "settings.json disappeared during reconciliation"
            )
        return None, None, None
    except OSError as error:
        raise SettingsReconciliationError(
            "settings.json could not be opened without following links"
        ) from error
    try:
        state = os.fstat(descriptor)
        validate_source(state)
        return descriptor, state, read_all(descriptor)
    except BaseException:
        os.close(descriptor)
        raise

def verify_parent_binding(
    home_descriptor, parent_descriptor, parent_name, expected_state
):
    no_follow, directory = descriptor_flags()
    current_descriptor = None
    try:
        current_descriptor = os.open(
            parent_name,
            os.O_RDONLY | directory | no_follow,
            dir_fd=home_descriptor,
        )
        current_state = os.fstat(current_descriptor)
        validate_parent(current_state)
        if (current_state.st_dev, current_state.st_ino) != (
            expected_state.st_dev,
            expected_state.st_ino,
        ):
            raise SettingsReconciliationError(
                "settings.json parent changed during reconciliation"
            )
    except SettingsReconciliationError:
        raise
    except OSError as error:
        raise SettingsReconciliationError(
            "settings.json parent changed during reconciliation"
        ) from error
    finally:
        if current_descriptor is not None:
            os.close(current_descriptor)

def verify_source_binding(
    parent_descriptor, settings_name, source_state, source_payload
):
    descriptor, current_state, current_payload = open_source(
        parent_descriptor, settings_name, source_state is not None
    )
    try:
        if source_state is None:
            if descriptor is not None:
                raise SettingsReconciliationError(
                    "settings.json appeared during reconciliation"
                )
            return
        if descriptor is None or current_state is None:
            raise SettingsReconciliationError(
                "settings.json disappeared during reconciliation"
            )
        validate_source(current_state)
        if (
            (current_state.st_dev, current_state.st_ino)
            != (source_state.st_dev, source_state.st_ino)
            or current_payload != source_payload
        ):
            raise SettingsReconciliationError(
                "settings.json changed during reconciliation"
            )
    finally:
        if descriptor is not None:
            os.close(descriptor)

def create_exclusive_file(parent_descriptor, prefix, mode):
    no_follow, _ = descriptor_flags()
    for _ in range(128):
        name = prefix + secrets.token_hex(16)
        try:
            descriptor = os.open(
                name,
                os.O_RDWR | os.O_CREAT | os.O_EXCL | no_follow,
                mode,
                dir_fd=parent_descriptor,
            )
            return name, descriptor
        except FileExistsError:
            continue
    raise SettingsReconciliationError(
        "could not allocate an exclusive settings artifact"
    )

def verify_named_payload(
    parent_descriptor, name, expected_state, expected_payload, expected_mode
):
    no_follow, _ = descriptor_flags()
    descriptor = None
    try:
        descriptor = os.open(
            name, os.O_RDONLY | no_follow, dir_fd=parent_descriptor
        )
        state = os.fstat(descriptor)
        if (
            not stat.S_ISREG(state.st_mode)
            or state.st_uid != os.geteuid()
            or state.st_nlink != 1
            or stat.S_IMODE(state.st_mode) != expected_mode
            or (state.st_dev, state.st_ino)
            != (expected_state.st_dev, expected_state.st_ino)
            or read_all(descriptor) != expected_payload
        ):
            raise SettingsReconciliationError(
                "published settings artifact did not match its bound content"
            )
    except SettingsReconciliationError:
        raise
    except OSError as error:
        raise SettingsReconciliationError(
            "published settings artifact could not be read safely"
        ) from error
    finally:
        if descriptor is not None:
            os.close(descriptor)

def reconcile():
    expected_binding = parse_expected_binding(expected_binding_text)
    (
        home_descriptor,
        parent_descriptor,
        parent_name,
        settings_name,
        parent_state,
        parent_migrated,
    ) = open_parent(settings_path)
    source_descriptor = None
    backup_descriptor = None
    output_descriptor = None
    try:
        source_descriptor, source_state, source_payload = open_source(
            parent_descriptor, settings_name, required=False
        )
        if expected_binding is None:
            if source_state is not None:
                raise SettingsReconciliationError(
                    "settings.json appeared after the inspected state"
                )
        elif source_state is None or source_payload is None:
            raise SettingsReconciliationError(
                "settings.json disappeared after inspection"
            )
        else:
            actual_binding = (
                parent_state.st_dev,
                parent_state.st_ino,
                source_state.st_dev,
                source_state.st_ino,
                hashlib.sha256(source_payload).hexdigest(),
            )
            if actual_binding != expected_binding:
                raise SettingsReconciliationError(
                    "settings.json parent or source changed after inspection"
                )
        output_mode = (
            stat.S_IMODE(source_state.st_mode)
            if source_state is not None
            else 0o600
        )
        if source_payload is None:
            s = {}
        else:
            try:
                s = json.loads(source_payload.decode("utf-8"))
            except (UnicodeError, json.JSONDecodeError) as error:
                raise SettingsReconciliationError(
                    f"{type(error).__name__}: {error}"
                ) from error

        if not isinstance(s, dict):
            reconciliation_failure("settings root", "a JSON object")
        mp = s.get("extraKnownMarketplaces", {})
        plugins = s.get("enabledPlugins", {})
        if not isinstance(mp, dict):
            reconciliation_failure("extraKnownMarketplaces", "a JSON object")
        if not isinstance(plugins, dict):
            reconciliation_failure("enabledPlugins", "a JSON object")
        s["extraKnownMarketplaces"] = mp
        s["enabledPlugins"] = plugins

        if athena_marketplace_name in mp:
            existing_a = mp[athena_marketplace_name]
            if not isinstance(existing_a, dict):
                reconciliation_failure(
                    f"extraKnownMarketplaces.{athena_marketplace_name}",
                    "a JSON object",
                )
            if "source" in existing_a:
                source = existing_a["source"]
                if not isinstance(source, dict):
                    reconciliation_failure(
                        f"extraKnownMarketplaces.{athena_marketplace_name}.source",
                        "a JSON object",
                    )
                if "url" in source and not isinstance(source["url"], str):
                    reconciliation_failure(
                        f"extraKnownMarketplaces.{athena_marketplace_name}.source.url",
                        "a string",
                    )
                if "source" in source and not isinstance(
                    source["source"], str
                ):
                    reconciliation_failure(
                        f"extraKnownMarketplaces.{athena_marketplace_name}.source.source",
                        "a string",
                    )

        existing_a = mp.get(athena_marketplace_name)
        a_shape_match = (
            isinstance(existing_a, dict)
            and isinstance(existing_a.get("source"), dict)
            and existing_a["source"].get("source") == "git"
            and norm(existing_a["source"].get("url"))
            == norm(athena_marketplace_url)
        )
        if not a_shape_match:
            mp[athena_marketplace_name] = {
                "source": {
                    "source": "git",
                    "url": athena_marketplace_url,
                }
            }
        plugins[athena_plugin_key] = True

        purged_entries = 0
        for legacy_key in legacy_plugin_keys_csv.split():
            if plugins.pop(legacy_key, None) is not None:
                purged_entries += 1
        for legacy_key in legacy_marketplace_keys_csv.split():
            if mp.pop(legacy_key, None) is not None:
                purged_entries += 1

        output_payload = serialize_settings(s)
        verify_parent_binding(
            home_descriptor, parent_descriptor, parent_name, parent_state
        )
        verify_source_binding(
            parent_descriptor, settings_name, source_state, source_payload
        )

        if source_payload == output_payload:
            return purged_entries, False, parent_migrated

        if source_state is not None:
            backup_name, backup_descriptor = create_exclusive_file(
                parent_descriptor, "settings.json.bak.", output_mode
            )
            write_all(backup_descriptor, source_payload)
            os.fchmod(backup_descriptor, output_mode)
            os.fsync(backup_descriptor)
            backup_state = os.fstat(backup_descriptor)
            verify_named_payload(
                parent_descriptor,
                backup_name,
                backup_state,
                source_payload,
                output_mode,
            )
            os.fsync(parent_descriptor)

        output_name, output_descriptor = create_exclusive_file(
            parent_descriptor, ".settings.json.", 0o600
        )
        write_all(output_descriptor, output_payload)
        os.fchmod(output_descriptor, output_mode)
        os.fsync(output_descriptor)
        output_state = os.fstat(output_descriptor)

        verify_parent_binding(
            home_descriptor, parent_descriptor, parent_name, parent_state
        )
        verify_source_binding(
            parent_descriptor, settings_name, source_state, source_payload
        )
        os.replace(
            output_name,
            settings_name,
            src_dir_fd=parent_descriptor,
            dst_dir_fd=parent_descriptor,
        )
        os.fsync(parent_descriptor)
        verify_named_payload(
            parent_descriptor,
            settings_name,
            output_state,
            output_payload,
            output_mode,
        )
        verify_parent_binding(
            home_descriptor, parent_descriptor, parent_name, parent_state
        )
        return purged_entries, True, parent_migrated
    finally:
        # If publication fails after the output file is created, retain its
        # directory entry. The name can change after the last identity check.
        # Unlinking that mutable name here could delete an unrelated entry.
        # The file stays owner-private and provides failure evidence.
        if output_descriptor is not None:
            os.close(output_descriptor)
        if backup_descriptor is not None:
            os.close(backup_descriptor)
        if source_descriptor is not None:
            os.close(source_descriptor)
        os.close(parent_descriptor)
        os.close(home_descriptor)

try:
    purged_entries, settings_changed, parent_migrated = reconcile()
except (OSError, SettingsReconciliationError) as error:
    print(f"settings.json reconciliation failed: {error}", file=sys.stderr)
    sys.exit(2)

if parent_migrated:
    print("    settings parent migrated from mode 0755 to 0700")
if purged_entries:
    print(
        "    settings.json updated — Athena marketplace and plugin reconciled "
        f"({purged_entries} retired entries removed)"
    )
elif settings_changed:
    print("    settings.json updated — Athena marketplace and plugin reconciled")
PYEOF
    then
        # Python's print above carries the per-action detail, including the
        # retired-entry count when applicable.
        check_pass "settings.json — Athena marketplace and plugin reconciled"
    else
        _settings_hard_failure=true
        check_fail "settings.json — Athena marketplace and plugin reconciliation failed"
    fi
fi

# ─── Step 3: Mnemosyne agent brain seed ──────────────────────────────────────
MNEMOSYNE_PARENT="$HOME/.agent_brain"
MNEMOSYNE_DIR="$HOME/.agent_brain/knowledge"
MNEMOSYNE_URL="https://github.com/HomericIntelligence/Mnemosyne.git"

_mnemosyne_directories_are_safe() {
    if [[ -L "$MNEMOSYNE_PARENT" ]] || \
       [[ -e "$MNEMOSYNE_PARENT" && ! -d "$MNEMOSYNE_PARENT" ]]; then
        _mnemosyne_error="Mnemosyne parent must be a direct directory: $MNEMOSYNE_PARENT"
        return 1
    fi
    if [[ -L "$MNEMOSYNE_DIR" ]] || \
       [[ -e "$MNEMOSYNE_DIR" && ! -d "$MNEMOSYNE_DIR" ]]; then
        _mnemosyne_error="Mnemosyne checkout must be a direct directory: $MNEMOSYNE_DIR"
        return 1
    fi
    return 0
}

_mnemosyne_git() (
    # Repository routing and config injection are ambient process state, not
    # authority to select a different checkout or rewrite the approved URL.
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
        GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG \
        GIT_CONFIG_PARAMETERS GIT_EXEC_PATH GIT_NAMESPACE GIT_TEMPLATE_DIR \
        GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM \
        GIT_ASKPASS SSH_ASKPASS GIT_SSH GIT_SSH_COMMAND GIT_PROXY_COMMAND \
        GIT_PROTOCOL_FROM_USER GIT_ALLOW_PROTOCOL GIT_SSL_NO_VERIFY \
        GIT_SSL_CAINFO GIT_SSL_CAPATH GIT_ATTR_SOURCE GIT_REPLACE_REF_BASE \
        || return 80
    # GIT_CONFIG selects the input for `git config`; other Git commands still
    # read repository config. Direct validation below therefore names the
    # bound config explicitly, while pull effects also receive command-scope
    # overrides for selected execution-capable settings.
    export GIT_CONFIG=/dev/null
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_SYSTEM=/dev/null
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_COUNT=0
    export GIT_ATTR_NOSYSTEM=1
    export GIT_TERMINAL_PROMPT=0
    command git -c core.attributesFile=/dev/null \
        -c core.fsmonitor=false \
        -c core.hooksPath=/dev/null \
        -c credential.helper= \
        -c credential.interactive=false \
        -c protocol.allow=never \
        -c protocol.https.allow=always \
        -c protocol.file.allow=never \
        -c http.sslVerify=true \
        -c http.sslCAPath= \
        -c http.curloptResolve= "$@"
)

_mnemosyne_bound_git() {
    # The caller has entered the bound .git directory. Relative operands stay
    # on that directory and its worktree even if an attacker replaces a named
    # checkout or .git path after validation.
    _mnemosyne_git --git-dir=. --work-tree=.. "$@"
}

_mnemosyne_pull_git() {
    local nonce source_url
    if ! nonce=$(python3 -I -S - <<'PYEOF'
import secrets

print(secrets.token_hex(16))
PYEOF
    ) || [[ ! "$nonce" =~ ^[0-9a-f]{32}$ ]]; then
        return 80
    fi
    # The random source alias is longer than the approved URL. Its command-
    # scope rewrite maps to the approved URL. Thus, a config that is replaced
    # after validation cannot redirect this invocation with a shorter rule.
    source_url="$MNEMOSYNE_URL/.homeric-bound-$nonce"
    _mnemosyne_bound_git \
        -c "url.$MNEMOSYNE_URL.insteadOf=$source_url" \
        pull --ff-only --no-recurse-submodules "$source_url" main
}

_mnemosyne_path_guard() {
    python3 -I -S - "$@" <<'PYEOF'
import hashlib
import os
import secrets
import stat
import sys


class UnsafePath(RuntimeError):
    pass


def direct_directory(path, label):
    value = os.lstat(path)
    if (
        not stat.S_ISDIR(value.st_mode)
        or value.st_uid != os.geteuid()
        or stat.S_IMODE(value.st_mode) & 0o022
    ):
        raise UnsafePath(f"{label} is not an owner-bound direct directory")
    return value


def config_record(path):
    try:
        value = os.lstat(path)
    except FileNotFoundError:
        return (-1, -1, "absent")
    if (
        not stat.S_ISREG(value.st_mode)
        or value.st_uid != os.geteuid()
        or value.st_nlink != 1
        or stat.S_IMODE(value.st_mode) & 0o022
    ):
        raise UnsafePath("Mnemosyne config is not one direct regular file")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (value.st_dev, value.st_ino):
            raise UnsafePath("Mnemosyne config changed while opening")
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            digest.update(chunk)
        current = os.fstat(descriptor)
        named = os.lstat(path)
        if (
            (current.st_dev, current.st_ino) != (value.st_dev, value.st_ino)
            or (named.st_dev, named.st_ino) != (value.st_dev, value.st_ino)
        ):
            raise UnsafePath("Mnemosyne config changed while reading")
        return value.st_dev, value.st_ino, digest.hexdigest()
    finally:
        os.close(descriptor)


def record(parent, checkout, require_git, allow_contents=False):
    parent_state = direct_directory(parent, "Mnemosyne parent")
    checkout_state = direct_directory(checkout, "Mnemosyne checkout")
    if os.path.dirname(checkout) != parent or os.path.basename(checkout) != "knowledge":
        raise UnsafePath("Mnemosyne checkout path is not canonical")
    git_path = os.path.join(checkout, ".git")
    git_state = None
    config_state = (-1, -1, "absent")
    if require_git:
        git_state = direct_directory(git_path, "Mnemosyne .git")
        config_state = config_record(os.path.join(git_path, "config"))
    elif not allow_contents:
        try:
            next(os.scandir(checkout))
        except StopIteration:
            pass
        else:
            raise UnsafePath("new Mnemosyne checkout directory is not empty")
    return (
        parent_state.st_dev,
        parent_state.st_ino,
        checkout_state.st_dev,
        checkout_state.st_ino,
        -1 if git_state is None else git_state.st_dev,
        -1 if git_state is None else git_state.st_ino,
        *config_state,
    )


def encode(values):
    return "mnemosyne-binding-v1:" + ":".join(str(value) for value in values)


def decode(value):
    parts = value.split(":")
    if len(parts) != 10 or parts[0] != "mnemosyne-binding-v1":
        raise UnsafePath("invalid Mnemosyne path binding")
    numeric = []
    for item in parts[1:9]:
        if item == "-1":
            numeric.append(-1)
        elif item.isascii() and item.isdigit():
            numeric.append(int(item))
        else:
            raise UnsafePath("invalid Mnemosyne path binding")
    digest = parts[9]
    if digest != "absent" and (
        len(digest) != 64
        or any(character not in "0123456789abcdef" for character in digest)
    ):
        raise UnsafePath("invalid Mnemosyne config binding")
    return (*numeric, digest)


mode, parent, checkout = sys.argv[1:4]
if mode == "bind":
    print(encode(record(parent, checkout, True)))
elif mode == "bind-empty":
    print(encode(record(parent, checkout, False)))
elif mode == "retire-failed":
    expected = decode(sys.argv[4])
    current = record(parent, checkout, False, allow_contents=True)
    if current[:4] != expected[:4]:
        raise UnsafePath("failed Mnemosyne checkout binding changed")
    cwd = os.lstat(".")
    if (
        not stat.S_ISDIR(cwd.st_mode)
        or (cwd.st_dev, cwd.st_ino) != expected[2:4]
    ):
        raise UnsafePath("failed Mnemosyne clone left its bound directory")

    parent_descriptor = os.open(
        parent,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
    )
    try:
        opened_parent = os.fstat(parent_descriptor)
        if (opened_parent.st_dev, opened_parent.st_ino) != expected[:2]:
            raise UnsafePath("Mnemosyne parent binding changed")
        checkout_descriptor = os.open(
            "knowledge",
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=parent_descriptor,
        )
        try:
            opened_checkout = os.fstat(checkout_descriptor)
            if (opened_checkout.st_dev, opened_checkout.st_ino) != expected[2:4]:
                raise UnsafePath("failed Mnemosyne checkout binding changed")

            while True:
                retired_name = ".knowledge.clone-failed." + secrets.token_hex(16)
                try:
                    os.stat(
                        retired_name,
                        dir_fd=parent_descriptor,
                        follow_symlinks=False,
                    )
                except FileNotFoundError:
                    break
            os.rename(
                "knowledge",
                retired_name,
                src_dir_fd=parent_descriptor,
                dst_dir_fd=parent_descriptor,
            )
            retired = os.stat(
                retired_name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            if (retired.st_dev, retired.st_ino) != expected[2:4]:
                raise UnsafePath("failed Mnemosyne checkout retirement changed target")
        finally:
            os.close(checkout_descriptor)
    finally:
        os.close(parent_descriptor)
elif mode in {"verify", "verify-container", "verify-git"}:
    expected = decode(sys.argv[4])
    current = record(
        parent,
        checkout,
        mode != "verify-container",
        allow_contents=mode == "verify-container",
    )
    compared = 4 if mode == "verify-container" else len(expected)
    if current[:compared] != expected[:compared]:
        raise UnsafePath("Mnemosyne path binding changed")
    cwd = os.lstat(".")
    expected_cwd = expected[4:6] if mode == "verify-git" else expected[2:4]
    if (
        not stat.S_ISDIR(cwd.st_mode)
        or (cwd.st_dev, cwd.st_ino) != expected_cwd
    ):
        raise UnsafePath("Mnemosyne operation left its bound directory")
    if len(sys.argv) == 6:
        root = os.lstat(sys.argv[5])
        if (
            not stat.S_ISDIR(root.st_mode)
            or (root.st_dev, root.st_ino) != expected[2:4]
        ):
            raise UnsafePath("Git reported a different Mnemosyne root")
else:
    raise UnsafePath("invalid Mnemosyne path guard operation")
PYEOF
}

_mnemosyne_validate_checkout() {
    local binding="$1" checkout_root origin_url branch
    local forbidden_config_pattern rewrite_status
    forbidden_config_pattern='^('
    forbidden_config_pattern+='url\..*\.insteadof|include\.path|includeif\..*\.path|'
    forbidden_config_pattern+='core\.(worktree|fsmonitor|hookspath|sshcommand|attributesfile)|'
    forbidden_config_pattern+='extensions\.worktreeconfig|filter\..*\.(clean|smudge|process)|'
    forbidden_config_pattern+='credential\..*|http(\..*)?\..*|'
    forbidden_config_pattern+='remote\..*\.(uploadpack|proxy|receivepack)|'
    forbidden_config_pattern+='diff\..*\.(command|textconv)|merge\..*\.driver|'
    forbidden_config_pattern+='protocol\..*\.allow|submodule\..*\.update)$'
    if ! _mnemosyne_path_guard verify-git \
        "$MNEMOSYNE_PARENT" "$MNEMOSYNE_DIR" "$binding"; then
        return 80
    fi
    if ! checkout_root=$(_mnemosyne_bound_git rev-parse --show-toplevel 2>/dev/null) \
        || [[ "$checkout_root" == *$'\n'* ]]; then
        return 80
    fi
    if ! origin_url=$(_mnemosyne_bound_git config --file ./config --no-includes \
        --get-all remote.origin.url 2>/dev/null) \
        || [[ "$origin_url" == *$'\n'* ]] \
        || [[ "$origin_url" != "$MNEMOSYNE_URL" ]]; then
        return 80
    fi
    if ! branch=$(_mnemosyne_bound_git symbolic-ref --quiet --short HEAD 2>/dev/null) \
        || [[ "$branch" != main ]]; then
        return 80
    fi
    _mnemosyne_bound_git config --file ./config --no-includes \
        --get-regexp "$forbidden_config_pattern" \
        >/dev/null 2>&1
    rewrite_status=$?
    if [[ "$rewrite_status" -eq 0 ]] || [[ "$rewrite_status" -ne 1 ]]; then
        return 80
    fi
    if ! _mnemosyne_path_guard verify-git \
        "$MNEMOSYNE_PARENT" "$MNEMOSYNE_DIR" "$binding" \
        "$checkout_root"; then
        return 80
    fi
    return 0
}

_mnemosyne_checkout_operation() {
    local operation="$1" binding pull_status
    if ! binding=$(_mnemosyne_path_guard bind \
        "$MNEMOSYNE_PARENT" "$MNEMOSYNE_DIR" 2>/dev/null); then
        return 80
    fi
    (
        cd "$MNEMOSYNE_DIR" || exit 80
        cd .git || exit 80
        _mnemosyne_validate_checkout "$binding" || exit 80
        if [[ "$operation" == pull ]]; then
            _mnemosyne_pull_git >/dev/null 2>&1
            pull_status=$?
            _mnemosyne_validate_checkout "$binding" || exit 80
            [[ "$pull_status" -eq 0 ]] || exit 81
        fi
    )
}

_mnemosyne_retire_failed_clone() (
    local binding="$1"
    cd "$MNEMOSYNE_DIR" || exit 80
    _mnemosyne_path_guard retire-failed \
        "$MNEMOSYNE_PARENT" "$MNEMOSYNE_DIR" "$binding" \
        >/dev/null 2>&1 || exit 80
)

if [[ "${_settings_hard_failure:-false}" == "true" ]]; then
    check_skip "Mnemosyne — skipped because settings inspection failed"
elif ! _mnemosyne_directories_are_safe; then
    _settings_hard_failure=true
    check_fail "$_mnemosyne_error"
elif [[ -e "$MNEMOSYNE_DIR" || -L "$MNEMOSYNE_DIR" ]]; then
    if ! _mnemosyne_checkout_operation inspect; then
        _settings_hard_failure=true
        check_fail "canonical Mnemosyne checkout, branch, remote, or path binding is unavailable"
    elif [[ "${INSTALL:-false}" == "true" ]]; then
        _mnemosyne_checkout_operation pull
        _mnemosyne_status=$?
        if [[ "$_mnemosyne_status" -eq 0 ]]; then
            check_pass "Mnemosyne — up to date"
        elif [[ "$_mnemosyne_status" -eq 81 ]]; then
            check_warn "Mnemosyne pull failed (offline? non-fast-forward?)"
        else
            _settings_hard_failure=true
            check_fail "canonical Mnemosyne checkout changed during pull"
        fi
    else
        check_pass "Mnemosyne — canonical checkout present (not updated in check-only mode)"
    fi
else
    check_warn "Mnemosyne — not seeded at $MNEMOSYNE_DIR"
    if [[ "${INSTALL:-false}" == "true" ]]; then
        echo -e "    ${BLUE}→${NC} Seeding Mnemosyne..."
        if ! mkdir -p "$MNEMOSYNE_PARENT" || \
           ! _mnemosyne_directories_are_safe; then
            _settings_hard_failure=true
            check_fail "${_mnemosyne_error:-cannot create the direct Mnemosyne parent directory}"
        elif ! mkdir "$MNEMOSYNE_DIR"; then
            _settings_hard_failure=true
            check_fail "cannot reserve the direct Mnemosyne checkout directory"
        else
            if ! _mnemosyne_empty_binding=$(_mnemosyne_path_guard bind-empty \
                "$MNEMOSYNE_PARENT" "$MNEMOSYNE_DIR" 2>/dev/null); then
                _settings_hard_failure=true
                check_fail "cannot bind the reserved Mnemosyne checkout directory"
            else
                (
                cd "$MNEMOSYNE_DIR" || exit 80
                _mnemosyne_path_guard verify-container \
                    "$MNEMOSYNE_PARENT" "$MNEMOSYNE_DIR" \
                    "$_mnemosyne_empty_binding" || exit 80
                _mnemosyne_git clone --depth 1 --branch main --single-branch \
                    -- "$MNEMOSYNE_URL" . >/dev/null 2>&1 || exit 81
                _mnemosyne_path_guard verify-container \
                    "$MNEMOSYNE_PARENT" "$MNEMOSYNE_DIR" \
                    "$_mnemosyne_empty_binding" || exit 80
                )
                _mnemosyne_clone_status=$?
                if [[ "$_mnemosyne_clone_status" -eq 0 ]] && \
                    _mnemosyne_checkout_operation inspect; then
                    check_pass "Mnemosyne — seeded to $MNEMOSYNE_DIR"
                elif [[ "$_mnemosyne_clone_status" -eq 81 ]] && \
                    _mnemosyne_retire_failed_clone \
                        "$_mnemosyne_empty_binding"; then
                    check_warn "Mnemosyne clone failed (offline? check network)"
                elif [[ "$_mnemosyne_clone_status" -eq 81 ]]; then
                    _settings_hard_failure=true
                    check_fail "failed Mnemosyne clone could not be retired safely"
                else
                    _settings_hard_failure=true
                    check_fail "seeded Mnemosyne checkout or path binding failed canonical validation"
                fi
            fi
        fi
    fi
fi

# This file is also exposed directly through `just claude-setup`. Preserve the
# aggregate installer's sourced phase contract, but propagate hard failures
# when this phase is the process entry point.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    [[ "${_FAIL:-0}" -eq 0 ]]
fi
