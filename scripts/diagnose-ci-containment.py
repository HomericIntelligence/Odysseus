#!/usr/bin/env python3
"""Report non-secret CI containment capabilities without changing host policy.

This is diagnostic output, not a substitute for the behavioral test gates.
"""

import json
import ctypes
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys


def main() -> None:
    report = {
        "python": sys.version,
        "executable": sys.executable,
        "uid": os.geteuid(),
        "pidfd_open": callable(getattr(os, "pidfd_open", None)),
        "pidfd_send_signal": callable(getattr(signal, "pidfd_send_signal", None)),
        "memfd_create": callable(getattr(os, "memfd_create", None)),
        "MFD_ALLOW_SEALING": getattr(os, "MFD_ALLOW_SEALING", None),
        "seal_constants": {
            name: getattr(fcntl, name, None)
            for name in (
                "F_ADD_SEALS", "F_GET_SEALS", "F_SEAL_SEAL",
                "F_SEAL_SHRINK", "F_SEAL_GROW", "F_SEAL_WRITE",
            )
        },
    }
    library = ctypes.CDLL(None)
    report["libc_memfd_create"] = hasattr(library, "memfd_create")
    for name in (
        "/proc/self/cgroup",
        "/proc/sys/kernel/unprivileged_userns_clone",
        "/proc/sys/kernel/apparmor_restrict_unprivileged_userns",
        "/sys/fs/cgroup/cgroup.controllers",
        "/sys/fs/cgroup/cgroup.subtree_control",
    ):
        try:
            report[name] = Path(name).read_text().strip()
        except OSError as error:
            report[name] = {"errno": error.errno}
    report["cgroup_root_writable"] = os.access("/sys/fs/cgroup", os.W_OK)
    try:
        result = subprocess.run(
            ["/usr/bin/unshare", "--user", "--map-root-user", "--mount",
             "--pid", "--fork", "/usr/bin/true"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"},
        )
        report["namespace_probe"] = {
            "returncode": result.returncode,
            "stderr": result.stderr[:1024],
        }
    except (OSError, subprocess.TimeoutExpired) as error:
        report["namespace_probe"] = {"error": type(error).__name__}
    # Compare the distribution's supported sandbox launcher with raw unshare.
    # This executes only true, with a read-only filesystem and no host network.
    try:
        result = subprocess.run(
            ["/usr/bin/bwrap", "--unshare-all", "--die-with-parent",
             "--ro-bind", "/", "/", "--", "/usr/bin/true"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"},
        )
        report["bubblewrap_probe"] = {
            "returncode": result.returncode,
            "stderr": result.stderr[:1024],
        }
    except (OSError, subprocess.TimeoutExpired) as error:
        report["bubblewrap_probe"] = {"error": type(error).__name__}
    for name in ("/proc/self/attr/current", "/etc/apparmor.d/bwrap"):
        try:
            report[name] = Path(name).read_text()[:8192].strip()
        except OSError as error:
            report[name] = {"errno": error.errno}
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
