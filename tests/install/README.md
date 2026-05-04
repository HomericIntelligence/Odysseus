# Install Test Harness

Container-based tests that validate `install.sh` and `install_dev.sh` against
clean Debian 12, Ubuntu 22.04, and Ubuntu 24.04 images.

## Prerequisites

- `podman` or `docker` on PATH
- Odysseus repo checked out with submodules initialized

## Quick start

```bash
# Test all OS variants with worker role (parallel)
bash tests/install/run_install_tests.sh

# Test a specific OS
bash tests/install/run_install_tests.sh debian12 worker

# Test with dev install too
bash tests/install/run_install_tests.sh ubuntu2404 worker --dev

# Via just
just test-install
just test-install ubuntu2404 worker
```

## How it works

For each OS/role combination `run_install_tests.sh`:

1. Builds a clean container image from `Dockerfile.<os>`
2. Run 1 — `install.sh --install --role <role>`
3. Run 2 — same command again (idempotency check)
4. Optional dev run — `install.sh --install` then `install_dev.sh --install`

Logs are written to `/tmp/install-<os>-<role>-run{1,2}.log`.

## Dockerfiles

| File | Base image |
|------|-----------|
| `Dockerfile.debian12` | `debian:12-slim` |
| `Dockerfile.ubuntu2404` | `ubuntu:24.04` |
| `Dockerfile.ubuntu2204` | `ubuntu:22.04` |

All Dockerfiles create a non-root user (`tester`) with passwordless sudo and
copy the Odysseus tree into `/home/tester/Projects/Odysseus`.
