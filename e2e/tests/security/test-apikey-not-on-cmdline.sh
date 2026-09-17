#!/usr/bin/env bash
# Security: Reusable API Key Stays Host-Only (#180)
# Validates that containers receive only an expiring broker token, while the
# reusable key stays out of argv, runtime environment, and container environment.
set -euo pipefail
cd "$(dirname "$0")/../../.."   # repo root
export PYTHONPATH="$PWD/e2e${PYTHONPATH:+:$PYTHONPATH}"
FAIL=0
SECRET="sk-ant-SENTINEL-must-not-leak-180"
LIVE_REQUIRED=0

if [ "${1:-}" = "--require-live" ]; then
    LIVE_REQUIRED=1
    shift
fi
if [ "$#" -ne 0 ]; then
    echo "FAIL: usage: $0 [--require-live]"
    exit 2
fi

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# ── Layer 1: scoped transport contract (both workers) ──

for W in single multi; do
    if ANTHROPIC_API_KEY="$SECRET" \
        ANTHROPIC_AUTH_TOKEN="host-shadow-must-not-cross" \
        python3 - "$W" <<'PY'
import asyncio
import importlib.util
import os
import stat
import sys
from pathlib import Path

worker = sys.argv[1]
filename = (
    "e2e/claude-myrmidon.py"
    if worker == "single"
    else "e2e/claude-myrmidon-multi.py"
)
spec = importlib.util.spec_from_file_location("m", filename)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
session_context = (
    module._private_session_home()
    if worker == "single"
    else module._private_session_home("scoped-auth-contract")
)

with session_context as session_home, module._scoped_claude_auth() as auth:
    builder_options = {
        "cwd": "/tmp",
        "scope": "plan",
        "session_home": session_home,
        "scoped_auth": auth,
    }
    command = (
        module._build_container_cmd(
            ["claude-host", "-p", "x"], **builder_options
        )
        if worker == "single"
        else module._build_container_cmd_scoped(
            ["claude", "-p", "x"], **builder_options
        )
    )
    command_text = "\0".join(command)
    if (
        os.environ["ANTHROPIC_API_KEY"] in command_text
        or "host-shadow-must-not-cross" in command_text
        or "ANTHROPIC_API_KEY" in command_text
        or command.count("--env-file") != 1
    ):
        raise AssertionError("reusable host credential crossed the command boundary")
    env_index = command.index("--env-file")
    if command[env_index + 1] != auth.env_file:
        raise AssertionError("container is not bound to the scoped environment file")

    metadata = os.stat(auth.env_file, follow_symlinks=False)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_uid != os.geteuid()
        or metadata.st_nlink != 1
    ):
        raise AssertionError("scoped environment file is not owner-private")
    values = dict(
        line.split("=", 1)
        for line in Path(auth.env_file).read_text().splitlines()
        if line
    )
    if (
        set(values) != {
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_BASE_URL",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
        }
        or values["ANTHROPIC_AUTH_TOKEN"] != auth.token
        or values["ANTHROPIC_BASE_URL"] != auth.container_url
        or os.environ["ANTHROPIC_API_KEY"] in values.values()
    ):
        raise AssertionError("scoped environment payload is malformed")

    runtime_environment = module._container_runtime_environment()
    if any(name in runtime_environment for name in (
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"
    )):
        raise AssertionError("container runtime inherited a reusable credential")

    for sink in (
        lambda: module.log("plan", f"unsafe {auth.token}"),
        lambda: module.post_issue_comment(8, "plan", 0, f"unsafe {auth.token}"),
        lambda: asyncio.run(
            module.publish_log(None, "plan", f"unsafe {auth.token}")
        ),
    ):
        try:
            sink()
        except module.HarnessValidationError:
            pass
        else:
            raise AssertionError("credential canary reached an outbound sink")

env_file = auth.env_file
if os.path.exists(env_file):
    raise AssertionError("scoped environment file survived its invocation")
PY
    then
        pass "$W: scoped broker transport and outbound canary enforced"
    else
        fail "$W: scoped broker transport contract failed"
    fi
done

# ── Layer 2: live container auth smoke check (skips if podman/image absent) ──
IMAGE="${CLAUDE_IMAGE:-achaean-claude:latest}"
if command -v podman >/dev/null 2>&1 && podman image exists "$IMAGE" 2>/dev/null; then
    for W in single multi; do
        if OUT=$(ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
            python3 e2e/tests/security/_run_one_auth_probe.py "$W" 2>&1)
        then
            pass "$W: live container auth OK"
        else
            echo "$OUT" | tail -5
            fail "$W: live container auth FAILED"
        fi
    done
else
    if [ "$LIVE_REQUIRED" -eq 1 ]; then
        fail "live container auth unavailable: podman or image '$IMAGE' is missing"
    else
        echo "SKIP: podman or image '$IMAGE' unavailable — live auth check skipped (Layer 1 still enforced)"
    fi
fi

if [ "$FAIL" -eq 0 ]; then
    echo "ALL CHECKS PASS"
    exit 0
fi
echo "CHECKS FAILED"
exit 1
