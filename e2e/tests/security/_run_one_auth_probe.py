#!/usr/bin/env python3
"""Issue #180 live auth probe: build a worker's real container command and run a
trivial prompt, asserting auth succeeds with the secret kept off the cmdline."""
import importlib.util
import pathlib
import subprocess
import sys

E2E = pathlib.Path(__file__).resolve().parents[2]


def load(fn: str) -> object:
    """Load a module from the e2e directory by filename."""
    spec = importlib.util.spec_from_file_location("w", E2E / fn)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


worker = sys.argv[1]
prompt = "Reply with exactly: OK"

if worker == "single":
    m = load("claude-myrmidon.py")
    cmd = m._build_container_cmd(
        [
            "claude-host",
            "-p", prompt,
            "--dangerously-skip-permissions",
            "--allowedTools", "Read",
        ],
        cwd="/tmp",
    )
else:
    m = load("claude-myrmidon-multi.py")
    cmd = m._build_container_cmd_scoped(
        [
            "claude",
            "-p", prompt,
            "--permission-mode", "acceptEdits",
            "--allowedTools", "Read",
        ],
        cwd="/tmp",
        scope="plan",
    )

result = subprocess.run(
    cmd,
    capture_output=True,
    text=True,
    stdin=subprocess.DEVNULL,
    timeout=120,
)
out = (result.stdout or "").strip()

# Auth failure surfaces as non-zero exit and/or auth/credential error text.
if (
    result.returncode != 0
    or not out
    or "ERROR" in out
    or "auth" in (result.stderr or "").lower()
):
    sys.stderr.write(f"rc={result.returncode} stderr={result.stderr[:300]}\n")
    sys.exit(1)

print(out[:200])
sys.exit(0)
