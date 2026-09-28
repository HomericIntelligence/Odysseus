#!/usr/bin/env python3
"""Bind CI's locked providers before running the shared staged-source policy."""

import hashlib
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import runpy
import shutil
import sys


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main() -> None:
    if not sys.flags.isolated:
        raise SystemExit("run this CI entry point with isolated Python (-I)")
    root = Path(__file__).resolve().parent.parent
    if Path.cwd().resolve() != root:
        raise SystemExit("run this CI entry point from the repository root")
    interpreter = Path(sys.executable).resolve(strict=True)
    provider = (Path(sys.prefix) / "bin" / "pre-commit").resolve(strict=True)
    git_route = shutil.which("git")
    if git_route is None:
        raise SystemExit("Git is unavailable")
    git = Path(git_route).resolve(strict=True)
    specification = importlib.util.find_spec("yaml")
    if specification is None or specification.origin is None:
        raise SystemExit("the locked interpreter cannot locate PyYAML")
    package = Path(specification.origin).resolve(strict=True).parent
    suffixes = (".py", *importlib.machinery.EXTENSION_SUFFIXES)
    manifest = []
    for current, directories, files in os.walk(package, followlinks=False):
        directories[:] = sorted(directories)
        for name in sorted(files):
            path = Path(current) / name
            if name.endswith(suffixes):
                if path.is_symlink():
                    raise SystemExit("PyYAML code must not be a symbolic link")
                manifest.append(f"{path}={digest(path)}")
    policy = root / "scripts" / "check_silent_failures.py"
    payload = policy.read_bytes()
    environment = {
        "PATH": "/usr/bin:/bin",
        "LC_ALL": "C",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_NO_LAZY_FETCH": "1",
        "ODYSSEUS_MANAGED_PRE_COMMIT": "1",
        "ODYSSEUS_PRE_COMMIT_POLICY_PATH": str(policy),
        "ODYSSEUS_PRE_COMMIT_POLICY_SHA256": hashlib.sha256(payload).hexdigest(),
        "ODYSSEUS_PYYAML_MANIFEST": "\n".join(manifest),
    }
    for label, path in (("INTERPRETER", interpreter), ("PROVIDER", provider), ("GIT", git)):
        environment[f"ODYSSEUS_PRE_COMMIT_{label}"] = str(path)
        environment[f"ODYSSEUS_PRE_COMMIT_{label}_SHA256"] = digest(path)
    os.environ.clear()
    os.environ.update(environment)
    sys.argv = [str(policy)]
    runpy.run_path(str(policy), run_name="__main__")


if __name__ == "__main__":
    main()
