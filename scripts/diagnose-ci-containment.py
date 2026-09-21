#!/usr/bin/env python3
"""Report non-secret CI containment capabilities without changing host policy.

This is diagnostic output, not a substitute for the behavioral test gates.
"""

import json
import ctypes
import fcntl
import importlib.util
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys


def hook_runtime_probe() -> dict:
    """Inspect the real sealed-interpreter route without executing hooks."""
    helper = Path(__file__).resolve().parent / "install/dev/precommit_hooks.py"
    specification = importlib.util.spec_from_file_location("ci_hook_probe", helper)
    if specification is None or specification.loader is None:
        return {"error": "helper loader unavailable"}
    subject = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = subject
    bound_tools = []
    report = {}
    try:
        specification.loader.exec_module(subject)
        boundary = subject.ReadOnlyExecutionBoundary(
            bound_tools, subject.OperationDeadline(30)
        )
        boundary.require()
        source = subject._trusted_python_tool(bound_tools)
        snapshot, _ = subject.execution_tool(
            source, boundary.tree, "diagnostic-interpreter", bound_tools, boundary
        )
        report["source"] = source.path
        for name, target in (
            ("snapshot_stat", ["/usr/bin/stat", "--format=%F %a %s", snapshot.path]),
            ("snapshot_elf", ["/usr/bin/readelf", "--program-headers", snapshot.path]),
            ("system_version", [source.path, "--version"]),
            ("loader_stat", ["/usr/bin/stat", "--dereference", "--format=%F %a %s",
                             "/lib64/ld-linux-x86-64.so.2"]),
            ("snapshot_version", [snapshot.path, "--version"]),
        ):
            command, executable = boundary.wrap(target, sealed_files=(snapshot,))
            result = subprocess.run(
                command, executable=executable,
                pass_fds=(boundary.guard.descriptor, snapshot.descriptor),
                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                timeout=5, check=False,
                env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"},
            )
            report[name] = {
                "returncode": result.returncode,
                "stdout": (
                    "\n".join(line.strip() for line in result.stdout.splitlines()
                              if "program interpreter:" in line)[:1024]
                    if name == "snapshot_elf" else result.stdout[:1024]
                ),
                "stderr": result.stderr[:1024],
            }
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        report["error"] = type(error).__name__
    finally:
        for tool in reversed(bound_tools):
            tool.close()
        sys.modules.pop(specification.name, None)
    return report


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
    # execve reports ENOENT for a missing ELF loader as well as a missing
    # executable. Record only fixed runtime routes, not environment contents.
    report["runtime_routes"] = {}
    for name in (
        "/usr/bin/python3", "/lib", "/lib64", "/usr/lib64",
        "/lib64/ld-linux-x86-64.so.2",
        "/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2",
        "/lib/ld-linux-aarch64.so.1",
    ):
        try:
            info = os.stat(name)
            report["runtime_routes"][name] = {
                "resolved": os.path.realpath(name, strict=True),
                "uid": info.st_uid,
                "mode": oct(stat.S_IMODE(info.st_mode)),
                "symlink": os.path.islink(name),
            }
        except OSError as error:
            report["runtime_routes"][name] = {"errno": error.errno}
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
    for name in (
        "/proc/self/attr/current",
        "/etc/apparmor.d/bwrap",
        "/etc/apparmor.d/bwrap-userns-restrict",
    ):
        try:
            report[name] = Path(name).read_text()[:8192].strip()
        except OSError as error:
            report[name] = {"errno": error.errno}
    report["hook_runtime_probe"] = hook_runtime_probe()
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
