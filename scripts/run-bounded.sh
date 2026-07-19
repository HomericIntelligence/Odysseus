#!/usr/bin/env bash
# run-bounded.sh — run a memory-hungry command under a virtual-memory cap.
#
# Wrap pixi / cmake / podman / pytest invocations so an over-budget process
# fails as a recoverable error of ITS OWN, instead of letting the kernel
# OOM-killer thrash swap and hang the whole WSL VM. This is the defense that
# would have contained the `hermes` host overload (see Odysseus AGENTS.md
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
    # Root cause of the old `ulimit -v ... || true`: `ulimit -v` fails ONLY when
    # asked to RAISE a soft rlimit (unprivileged processes can lower but never
    # raise). We only ever want to LOWER the ceiling, so guard on the current
    # limit and call ulimit only when it is a genuine lowering — then the call
    # cannot fail and no suppression is needed. (docs/runbooks/no-silent-failures.md)
    _cur_vmem="$(ulimit -v)"   # "unlimited" or a KiB integer
    if [[ "$_cur_vmem" == "unlimited" || "$_cur_vmem" -gt "$VMEM_KB" ]]; then
        ulimit -v "$VMEM_KB"
    fi
fi

exec "$@"
