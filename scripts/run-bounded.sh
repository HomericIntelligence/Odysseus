#!/usr/bin/env bash
# run-bounded.sh — run a memory-hungry command under a virtual-memory cap.
#
# Wrap pixi / cmake / podman / pytest invocations so an over-budget process
# fails as a recoverable error of ITS OWN, instead of letting the kernel
# OOM-killer thrash swap and hang the whole WSL VM. This is the defense that
# would have contained the `hermes` host overload (see Odysseus CLAUDE.md
# "Resource limits & concurrency"): `ulimit -v` turns the uncatchable SIGKILL
# into a normal non-zero exit / MemoryError that unwinds cleanly.
#
# Usage:
#   scripts/run-bounded.sh pixi install
#   scripts/run-bounded.sh cmake --build --preset release -j2
#   RUN_BOUNDED_VMEM_KB=4194304 scripts/run-bounded.sh pytest tests/
#
# Env:
#   RUN_BOUNDED_VMEM_KB   Virtual-memory cap in KiB (default 5242880 = 5 GiB).
#                         Set to 0 to disable the cap (run unbounded).
#
# Sizing: on the 16 GB / 8-core host, ~5 GiB/process lets one heavy solve/build
# run comfortably while keeping 3 concurrent bounded processes < 16 GB.
set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "usage: $(basename "$0") <command> [args...]" >&2
    exit 2
fi

VMEM_KB="${RUN_BOUNDED_VMEM_KB:-5242880}"

if [[ "$VMEM_KB" != "0" ]]; then
    # Best-effort: if the soft limit is already lower, ulimit -v will refuse to
    # raise it — that is fine, we only ever want to LOWER the ceiling here.
    ulimit -v "$VMEM_KB" 2>/dev/null || true
fi

exec "$@"
