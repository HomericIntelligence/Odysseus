#!/usr/bin/env python3
"""Issue #180 live probe for the host-only key and scoped broker boundary."""
import importlib.util
import io
import pathlib
import subprocess
import sys
from contextlib import redirect_stderr, redirect_stdout

E2E = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(E2E))


def load(fn: str) -> object:
    """Load a module from the e2e directory by filename."""
    spec = importlib.util.spec_from_file_location("w", E2E / fn)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


if len(sys.argv) != 2 or sys.argv[1] not in {"single", "multi"}:
    sys.stderr.write("live auth probe worker must be 'single' or 'multi'\n")
    sys.exit(2)

worker = sys.argv[1]
prompt = "Reply with exactly: OK"

if worker == "single":
    m = load("claude-myrmidon.py")
    session_context = m._private_session_home()
else:
    m = load("claude-myrmidon-multi.py")
    session_context = m._private_session_home("live-auth-probe")

with session_context as session_home, m._scoped_claude_auth() as scoped_auth:
    claude_program = "claude-host" if worker == "single" else "claude"
    claude_args = [
        claude_program,
        "-p", prompt,
        "--permission-mode", "acceptEdits",
        "--allowedTools", "Read",
    ]
    # The probe emits only its own fixed status. Do not forward harness or
    # child output, because either stream can contain credentials or context.
    with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
        if worker == "single":
            cmd = m._build_container_cmd(
                claude_args,
                cwd="/tmp",
                scope="plan",
                session_home=session_home,
                scoped_auth=scoped_auth,
            )
        else:
            cmd = m._build_container_cmd_scoped(
                claude_args,
                cwd="/tmp",
                scope="plan",
                session_home=session_home,
                scoped_auth=scoped_auth,
            )

        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=120,
            env=m._container_runtime_environment(),
        )
out = (result.stdout or "").strip()
raw_err = result.stderr or ""
err = raw_err.lower()

# Auth failure surfaces as non-zero exit, empty output, or a specific
# credential-error token in stderr. Anchor on concrete failure phrases rather
# than the 4-char "auth" (which matches "author"/"authorized"/etc.), and rely
# on returncode + empty-output instead of a broad "ERROR in stdout" substring.
_AUTH_FAIL_TOKENS = (
    "authentication",
    "invalid api key",
    "invalid_api_key",
    "unauthorized",
    "credential",
)
if (
    m._credential_canary_present(out)
    or m._credential_canary_present(raw_err)
    or result.returncode != 0
    or out != "OK"
    or any(tok in err for tok in _AUTH_FAIL_TOKENS)
):
    sys.stderr.write("live auth probe failed\n")
    sys.exit(1)

print("OK")
sys.exit(0)
