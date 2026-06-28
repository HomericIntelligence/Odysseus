#!/usr/bin/env python3
"""Validate NATS server config structure (issue #198).

Binary-free: nats-server -t cannot be used as a syntax gate because it exits
non-zero on a *valid* config when TLS cert files are absent (the CI/dev case).
This checks HOCON structure (balanced braces, terminated strings) with stdlib
only, so it runs on any runner with python3.
"""
import sys
from pathlib import Path


def check(text: str) -> tuple[bool, str]:
    """Check HOCON structure: balanced braces and terminated strings.

    Returns (True, "ok") on success or (False, error_message) on failure.
    """
    depth = 0
    for ln, raw in enumerate(text.splitlines(), start=1):
        out = []
        instr = False
        q = ""
        i = 0
        while i < len(raw):
            ch = raw[i]
            if instr:
                if ch == "\\" and i + 1 < len(raw):
                    out.append(ch)
                    out.append(raw[i + 1])
                    i += 2
                    continue
                if ch == q:
                    instr = False
                out.append(ch)
                i += 1
                continue
            if ch == "#":
                break  # comment to end of line
            if ch in "\"'":
                instr = True
                q = ch
            out.append(ch)
            i += 1
        if instr:
            return False, f"unterminated string on line {ln}"
        code = "".join(out)
        depth += code.count("{") - code.count("}")
        if depth < 0:
            return False, f"unmatched }} on line {ln}"
    if depth != 0:
        return False, f"unbalanced braces: {depth} unclosed brace(s)"
    return True, "ok"


def main() -> int:
    """Validate all NATS .conf files under configs/nats/."""
    nats_dir = Path(__file__).resolve().parent.parent / "configs" / "nats"
    confs = sorted(nats_dir.glob("*.conf"))
    if not confs:
        print(f"ERROR: no NATS .conf files under {nats_dir}", file=sys.stderr)
        return 1
    failed = 0
    for f in confs:
        text = f.read_text(encoding="utf-8")
        if not text.strip():
            print(f"FAILED: {f} is empty", file=sys.stderr)
            failed += 1
            continue
        ok, msg = check(text)
        if ok:
            print(f"OK: {f}")
        else:
            print(f"FAILED: {f} -- {msg}", file=sys.stderr)
            failed += 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
