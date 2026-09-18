"""Exact-pin, read-only Athena evidence adapter for legacy myrmidon shipping."""

from __future__ import annotations

import contextlib
import hashlib
import json
import os
import re
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
from collections.abc import Iterator
from typing import Callable


MAX_INPUT_BYTES = 1024 * 1024
MAX_OUTPUT_BYTES = 16 * 1024 * 1024
MAX_STDERR_BYTES = 64 * 1024
MAX_RULE_PAGES = 100
MAX_RULES_PER_PAGE = 100
MAX_CHECK_RUNS = 10_000
COMMAND_TIMEOUT_SECONDS = 180.0
PROCESS_TERMINATE_SECONDS = 0.5
PROCESS_REAP_SECONDS = 2.0
PROCESS_POLL_SECONDS = 0.01
READ_CHUNK_BYTES = 64 * 1024
PROCESS_STATUS_BYTES = 4
HEX_40 = re.compile(r"[0-9a-f]{40}")
HEX_64 = re.compile(r"[0-9a-f]{64}")
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
ATHENA_RELEASE_VERSION = "0.5.3"
ATHENA_RELEASE_COMMIT = "8c72148529a38efb4dd97e8e78c1b2193d852403"
ATHENA_RELEASE_SOURCE = "https://github.com/HomericIntelligence/Athena.git"
PLUGIN_MANIFEST = ".codex-plugin/plugin.json"
INSTALL_MANIFEST = ".codex-marketplace-install.json"
PLUGIN_MANIFEST_SHA256 = (
    "dd4c5f7eccbc919d34936f8514ba0de5acf37f46ab3432a7058b2750dab319f5"
)
INSTALL_MANIFEST_SHA256 = (
    "1d1d0d693dc4b93b688ebb6463a636fa5008d52703f4616661373d86b4d1eead"
)
HELPER_SHA256 = {
    "skills/pr-review/scripts/resolve_pr.py": (
        "978b71a2c79b1fe4a66489c899876403d7ef3d79b589f9128499772e97cb5222"
    ),
    "skills/pr-review/scripts/collect_evidence.py": (
        "961f1af29296763fb1f0297d9dcf873001f0008a93dfcd4a2bf2044c049777a0"
    ),
    "skills/pr-review/scripts/deliver_go.py": (
        "6c12b7c953980ec703e154d8f98989fb2fb1d155f61584768f0ad70c174cfa06"
    ),
    "skills/pr-review/scripts/anchor_proofs.py": (
        "388b1d167bc3eb44ffcd07cc50ec0f6f19f0e6ab4f309d3bd8d0c0c8491975d1"
    ),
    "skills/pr-review/scripts/pr_identity.py": (
        "274f6fff920f5a8d970a8018e3c8cee7d93af26e9aea3fa869e78cbeb32a5a3a"
    ),
    "skills/pr-review/scripts/materialize_snapshot.py": (
        "f560d2ef785bb1a8fd604373e65268cdfaeb1d3360778dfe73bc83dce45e37f2"
    ),
    "skills/review-exchange/scripts/review_exchange.py": (
        "7f6db45e9d4e9364441c0ac8f3c9ab303b165fd9ac8cd54fbdca6585dad0d693"
    ),
    "skills/_cli.py": (
        "80e6189d94f7e7f0d7cc32d57d3e0d1cb11093fb2aed30209624c5939cf2d7d9"
    ),
}
PLUGIN_COMMANDS = frozenset({
    "skills/pr-review/scripts/collect_evidence.py",
    "skills/review-exchange/scripts/review_exchange.py",
})
CHAIN_COMMAND = "e2e/athena_readonly_chain.py"
CHAIN_ADAPTER_SHA256 = (
    "dcc0a414a1b794ba53538f1ba712b31b427af26a97847f6fbb42d66ae86f3951"
)
RULES_COMMAND = "github/effective-branch-rules"
BRANCH_PROTECTION_COMMAND = "github/branch-protection"
CHECK_RUNS_COMMAND = "github/head-check-runs"
MERGE_READINESS_COMMAND = "github/pr-merge-readiness"

_PROCESS_SUPERVISOR = """
import os
import signal
import struct
import subprocess
import sys
import traceback

status_descriptor = int(sys.argv[1])
signal.signal(signal.SIGTERM, lambda _signum, _frame: None)
try:
    target = subprocess.Popen(sys.argv[2:])
    target_returncode = target.wait()
except BaseException:
    traceback.print_exc()
    target_returncode = 125
os.write(status_descriptor, struct.pack("!i", target_returncode))
os.close(status_descriptor)
os.close(1)
os.close(2)
while True:
    signal.pause()
"""


class AthenaEvidenceError(RuntimeError):
    """Athena evidence is missing, stale, ambiguous, or unsafe."""


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise AthenaEvidenceError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _load_json(payload: str, context: str) -> object:
    try:
        value = json.loads(
            payload,
            object_pairs_hook=_unique_object,
            parse_constant=lambda item: (_ for _ in ()).throw(
                AthenaEvidenceError(f"nonfinite JSON value: {item}")
            ),
        )
    except (json.JSONDecodeError, UnicodeError) as exc:
        raise AthenaEvidenceError(f"{context} is not valid JSON") from exc
    return value


def _load_object(payload: str, context: str) -> dict:
    value = _load_json(payload, context)
    if not isinstance(value, dict):
        raise AthenaEvidenceError(f"{context} is not a JSON object")
    return value


def _canonical_json(value: object) -> str:
    try:
        return json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    except (TypeError, UnicodeError, ValueError) as exc:
        raise AthenaEvidenceError("Athena data is not canonical JSON") from exc


def _read_no_follow(path: str, maximum_bytes: int = 8 * 1024 * 1024) -> bytes:
    no_follow = getattr(os, "O_NOFOLLOW", None)
    if not isinstance(no_follow, int) or no_follow == 0:
        raise AthenaEvidenceError("O_NOFOLLOW is required for Athena helpers")
    try:
        descriptor = os.open(path, os.O_RDONLY | no_follow)
    except OSError as exc:
        raise AthenaEvidenceError("an Athena helper cannot be opened safely") from exc
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise AthenaEvidenceError("an Athena helper is not a regular file")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            payload = stream.read(maximum_bytes + 1)
    finally:
        os.close(descriptor)
    if len(payload) > maximum_bytes:
        raise AthenaEvidenceError("an Athena helper exceeds its size bound")
    return payload


def _release_path(root: str, relative: str) -> str:
    candidate = os.path.normpath(os.path.join(root, relative))
    if (
        os.path.commonpath((root, candidate)) != root
        or os.path.realpath(candidate) != candidate
    ):
        raise AthenaEvidenceError("Athena release metadata escapes the plugin root")
    return candidate


def _release_object(path: str, context: str, expected_sha256: str) -> dict:
    try:
        release_bytes = _read_no_follow(path, 64 * 1024)
        if hashlib.sha256(release_bytes).hexdigest() != expected_sha256:
            raise AthenaEvidenceError(
                f"{context} bytes do not match release 0.5.3"
            )
        payload = release_bytes.decode("utf-8")
    except UnicodeError as exc:
        raise AthenaEvidenceError(f"{context} is not valid UTF-8") from exc
    return _load_object(payload, context)


def _verify_release_metadata(root: str) -> None:
    plugin = _release_object(
        _release_path(root, PLUGIN_MANIFEST),
        "the Athena plugin manifest",
        PLUGIN_MANIFEST_SHA256,
    )
    if (
        plugin.get("name") != "athena"
        or plugin.get("version") != ATHENA_RELEASE_VERSION
        or plugin.get("repository")
        != "https://github.com/HomericIntelligence/Athena"
    ):
        raise AthenaEvidenceError("the Athena plugin manifest is not release 0.5.3")
    installation = _release_object(
        _release_path(root, INSTALL_MANIFEST),
        "the Athena install manifest",
        INSTALL_MANIFEST_SHA256,
    )
    if installation != {
        "source_type": "git",
        "source": ATHENA_RELEASE_SOURCE,
        "ref_name": "main",
        "sparse_paths": [],
        "revision": ATHENA_RELEASE_COMMIT,
    }:
        raise AthenaEvidenceError("the Athena install manifest is not the pinned release")


def _verified_plugin_root(plugin_root: str) -> str:
    if (
        not plugin_root
        or not os.path.isabs(plugin_root)
        or os.path.normpath(plugin_root) != plugin_root
        or os.path.realpath(plugin_root) != plugin_root
    ):
        raise AthenaEvidenceError("ATHENA_PLUGIN_ROOT is not an exact safe path")
    try:
        metadata = os.lstat(plugin_root)
    except OSError as exc:
        raise AthenaEvidenceError("ATHENA_PLUGIN_ROOT is unavailable") from exc
    if not stat.S_ISDIR(metadata.st_mode):
        raise AthenaEvidenceError("ATHENA_PLUGIN_ROOT is not a directory")
    _verify_release_metadata(plugin_root)
    for relative, expected in HELPER_SHA256.items():
        candidate = _release_path(plugin_root, relative)
        if hashlib.sha256(_read_no_follow(candidate)).hexdigest() != expected:
            raise AthenaEvidenceError("the dependency-locked Athena digest changed")
    return plugin_root


@contextlib.contextmanager
def _private_script_copy(path: str, expected_sha256: str) -> Iterator[str]:
    """Yield a private executable copy made from one no-follow source read."""
    payload = _read_no_follow(path)
    if hashlib.sha256(payload).hexdigest() != expected_sha256:
        raise AthenaEvidenceError("the read-only chain adapter digest changed")
    no_follow = getattr(os, "O_NOFOLLOW", None)
    if not isinstance(no_follow, int) or no_follow == 0:
        raise AthenaEvidenceError("O_NOFOLLOW is required for Athena adapters")
    with tempfile.TemporaryDirectory(prefix="odysseus-athena-adapter-") as temporary:
        script = os.path.join(temporary, "athena_readonly_chain.py")
        descriptor = os.open(
            script,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | no_follow,
            0o500,
        )
        try:
            with os.fdopen(descriptor, "wb", closefd=False) as stream:
                stream.write(payload)
                stream.flush()
                os.fsync(descriptor)
        finally:
            os.close(descriptor)
        yield script


def _sanitized_environment() -> dict[str, str]:
    """Pass only runtime/auth/network inputs; exclude all Python startup hooks."""
    allowed = {
        "PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
        "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GH_HOST",
        "GH_CONFIG_DIR", "XDG_CONFIG_HOME", "SSL_CERT_FILE", "SSL_CERT_DIR",
        "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy",
        "no_proxy",
    }
    return {
        key: value
        for key, value in os.environ.items()
        if key in allowed and isinstance(value, str)
    }


def _child_has_exited(process_id: int) -> bool:
    required = ("waitid", "P_PID", "WEXITED", "WNOHANG", "WNOWAIT")
    if any(not hasattr(os, name) for name in required):
        raise AthenaEvidenceError(
            "safe no-reap process observation is unavailable"
        )
    try:
        result = os.waitid(
            os.P_PID,
            process_id,
            os.WEXITED | os.WNOHANG | os.WNOWAIT,
        )
    except InterruptedError:
        return False
    except ChildProcessError as exc:
        raise AthenaEvidenceError("the Athena helper process lost ownership") from exc
    return result is not None


def _process_group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _stop_process_group(process: subprocess.Popen) -> int:
    """Terminate, kill, and reap one private helper process group."""
    process_group = process.pid
    cleanup_error = None
    try:
        os.killpg(process_group, signal.SIGTERM)
    except ProcessLookupError:
        pass
    except OSError as exc:
        cleanup_error = AthenaEvidenceError(
            "the Athena helper process group cannot be terminated"
        )
        cleanup_error.__cause__ = exc

    deadline = time.monotonic() + PROCESS_TERMINATE_SECONDS
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(PROCESS_POLL_SECONDS, remaining))

    try:
        os.killpg(process_group, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except OSError as exc:
        if cleanup_error is None:
            cleanup_error = AthenaEvidenceError(
                "the Athena helper process group cannot be killed"
            )
            cleanup_error.__cause__ = exc

    try:
        process.wait(timeout=PROCESS_REAP_SECONDS)
    except subprocess.TimeoutExpired:
        try:
            os.kill(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError as exc:
            if cleanup_error is None:
                cleanup_error = AthenaEvidenceError(
                    "the Athena helper leader cannot be killed"
                )
                cleanup_error.__cause__ = exc
        try:
            process.wait(timeout=PROCESS_REAP_SECONDS)
        except (ChildProcessError, subprocess.TimeoutExpired) as exc:
            if cleanup_error is None:
                cleanup_error = AthenaEvidenceError(
                    "the Athena helper leader cannot be reaped"
                )
                cleanup_error.__cause__ = exc
    except ChildProcessError as exc:
        if cleanup_error is None:
            cleanup_error = AthenaEvidenceError(
                "the Athena helper leader lost ownership"
            )
            cleanup_error.__cause__ = exc

    extinction_deadline = time.monotonic() + PROCESS_REAP_SECONDS
    while _process_group_exists(process_group):
        if time.monotonic() >= extinction_deadline:
            if cleanup_error is None:
                cleanup_error = AthenaEvidenceError(
                    "the Athena helper process group did not become extinct"
                )
            break
        time.sleep(PROCESS_POLL_SECONDS)
    if cleanup_error is not None:
        raise cleanup_error
    if process.returncode is None:
        raise AthenaEvidenceError("the Athena helper leader was not reaped")
    return process.returncode


def _finalize_process_resources(state: dict[str, object]) -> None:
    """Finish process cleanup even when one cleanup operation is interrupted."""
    cleanup_errors: list[BaseException] = []
    process = state.get("process")
    if process is not None:
        try:
            state["leader_returncode"] = _stop_process_group(process)
        except BaseException as exc:
            cleanup_errors.append(exc)
            if process.returncode is None or _process_group_exists(process.pid):
                try:
                    state["leader_returncode"] = _stop_process_group(process)
                except BaseException as retry_exc:
                    cleanup_errors.append(retry_exc)
            elif process.returncode is not None:
                state["leader_returncode"] = process.returncode

    readers = state["readers"]
    reader_deadline = time.monotonic() + PROCESS_REAP_SECONDS
    for reader in readers:
        if reader.ident is None:
            continue
        while True:
            remaining = max(0.0, reader_deadline - time.monotonic())
            try:
                reader.join(remaining)
            except BaseException as exc:
                cleanup_errors.append(exc)
                if time.monotonic() >= reader_deadline:
                    break
                continue
            if not reader.is_alive() or remaining <= 0:
                break
    if any(
        reader.ident is not None and reader.is_alive()
        for reader in readers
    ):
        cleanup_errors.append(AthenaEvidenceError(
            "the Athena helper output readers did not stop"
        ))

    for stream in state["streams"]:
        try:
            stream.close()
        except BaseException as exc:
            cleanup_errors.append(exc)
    input_stream = state.get("input_stream")
    if input_stream is not None:
        try:
            input_stream.close()
        except BaseException as exc:
            cleanup_errors.append(exc)
    for name in ("status_read_descriptor", "status_write_descriptor"):
        descriptor = state[name]
        if descriptor < 0:
            continue
        try:
            os.close(descriptor)
        except OSError:
            pass
        except BaseException as exc:
            cleanup_errors.append(exc)
        finally:
            state[name] = -1

    if cleanup_errors:
        raise cleanup_errors[0]


def _spawn_owned_process(
    command: list[str],
    *,
    stdin,
    status_descriptor: int,
    cwd: str | None,
    environment: dict[str, str],
    owner: dict[str, object],
) -> subprocess.Popen:
    """Acquire subprocess ownership before an interruption can escape."""
    outcome: dict[str, object] = {}
    ready = threading.Event()

    def spawn() -> None:
        try:
            process = subprocess.Popen(
                [
                    sys.executable,
                    "-I",
                    "-S",
                    "-B",
                    "-c",
                    _PROCESS_SUPERVISOR,
                    str(status_descriptor),
                    *command,
                ],
                stdin=stdin,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=cwd,
                env=environment,
                start_new_session=True,
                pass_fds=(status_descriptor,),
            )
            owner["process"] = process
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    owner["streams"].append(stream)
            outcome["process"] = process
        except BaseException as exc:  # transfer the exact spawn failure
            outcome["error"] = exc
        finally:
            ready.set()

    worker = threading.Thread(
        target=spawn,
        daemon=False,
        name="athena-process-spawn",
    )
    interrupted = None
    interrupted_traceback = None
    try:
        worker.start()
        while not ready.wait(PROCESS_POLL_SECONDS):
            pass
    except BaseException as exc:
        interrupted = exc
        interrupted_traceback = exc.__traceback__
        if worker.ident is None:
            raise
        while not ready.is_set():
            try:
                ready.wait(PROCESS_POLL_SECONDS)
            except BaseException:
                continue
    finally:
        if worker.ident is not None:
            while worker.is_alive():
                try:
                    worker.join(PROCESS_POLL_SECONDS)
                except BaseException as exc:
                    if interrupted is None:
                        interrupted = exc
                        interrupted_traceback = exc.__traceback__

    process = outcome.get("process")
    if interrupted is not None:
        raise interrupted.with_traceback(interrupted_traceback)
    error = outcome.get("error")
    if isinstance(error, BaseException):
        raise error
    if process is None:
        raise AthenaEvidenceError("the Athena helper process was not acquired")
    return process


def _run_bounded_process(
    command: list[str],
    *,
    input_text: str | None,
    cwd: str | None,
    environment: dict[str, str],
) -> subprocess.CompletedProcess:
    """Run one command with bounded pipes and process-group cleanup."""
    for name in ("waitid", "P_PID", "WEXITED", "WNOHANG", "WNOWAIT"):
        if not hasattr(os, name):
            raise AthenaEvidenceError(
                "safe no-reap process observation is unavailable"
            )

    process = None
    readers: list[threading.Thread] = []
    streams = []
    state: dict[str, object] = {
        "process": None,
        "readers": readers,
        "streams": streams,
        "input_stream": None,
        "status_read_descriptor": -1,
        "status_write_descriptor": -1,
        "leader_returncode": None,
    }
    chunks: dict[str, list[bytes]] = {
        "stdout": [], "stderr": [], "status": [],
    }
    overflow = threading.Event()
    activity = threading.Event()
    done = {
        "stdout": threading.Event(),
        "stderr": threading.Event(),
        "status": threading.Event(),
    }
    reader_errors: list[BaseException] = []
    finalize_requested = threading.Event()
    finalize_outcome: dict[str, object] = {}

    def finalize() -> None:
        while not finalize_requested.is_set():
            try:
                finalize_requested.wait(PROCESS_POLL_SECONDS)
            except BaseException as exc:
                finalize_outcome.setdefault(
                    "error", (exc, exc.__traceback__)
                )
        try:
            _finalize_process_resources(state)
        except BaseException as exc:
            finalize_outcome.setdefault("error", (exc, exc.__traceback__))

    finalizer = threading.Thread(
        target=finalize,
        daemon=False,
        name="athena-process-finalizer",
    )

    def read_stream(name: str, stream, maximum_bytes: int) -> None:
        observed = 0
        try:
            while True:
                block = os.read(stream.fileno(), READ_CHUNK_BYTES)
                if not block:
                    break
                remaining = maximum_bytes + 1 - observed
                if remaining > 0:
                    chunks[name].append(block[:remaining])
                observed += len(block)
                if observed > maximum_bytes:
                    overflow.set()
                    activity.set()
                    break
        except BaseException as exc:  # pragma: no cover - operating-system fault
            reader_errors.append(exc)
            activity.set()
        finally:
            try:
                stream.close()
            finally:
                done[name].set()
                activity.set()

    try:
        finalizer.start()
        if input_text is not None:
            input_stream = tempfile.TemporaryFile()
            state["input_stream"] = input_stream
            input_stream.write(input_text.encode("utf-8"))
            input_stream.seek(0)
        else:
            input_stream = None
        stdin = subprocess.DEVNULL if input_stream is None else input_stream
        (
            state["status_read_descriptor"],
            state["status_write_descriptor"],
        ) = os.pipe()
        process = _spawn_owned_process(
            command,
            stdin=stdin,
            status_descriptor=state["status_write_descriptor"],
            cwd=cwd,
            environment=environment,
            owner=state,
        )
        os.close(state["status_write_descriptor"])
        state["status_write_descriptor"] = -1
        if process.stdout is None or process.stderr is None:
            raise AthenaEvidenceError("the Athena helper pipes are unavailable")
        status_stream = os.fdopen(state["status_read_descriptor"], "rb")
        streams.append(status_stream)
        state["status_read_descriptor"] = -1
        readers.extend([
            threading.Thread(
                target=read_stream,
                args=("stdout", process.stdout, MAX_OUTPUT_BYTES),
                daemon=True,
                name="athena-stdout-reader",
            ),
            threading.Thread(
                target=read_stream,
                args=("stderr", process.stderr, MAX_STDERR_BYTES),
                daemon=True,
                name="athena-stderr-reader",
            ),
            threading.Thread(
                target=read_stream,
                args=("status", status_stream, PROCESS_STATUS_BYTES),
                daemon=True,
                name="athena-status-reader",
            ),
        ])
        for reader in readers:
            reader.start()

        deadline = time.monotonic() + COMMAND_TIMEOUT_SECONDS
        failure = ""
        while True:
            if overflow.is_set():
                failure = "the Athena read exceeded its output bound"
                break
            if reader_errors:
                failure = "the Athena read output cannot be collected"
                break
            if all(marker.is_set() for marker in done.values()):
                if overflow.is_set():
                    failure = "the Athena read exceeded its output bound"
                break
            if _child_has_exited(process.pid):
                failure = "the Athena helper supervisor stopped unexpectedly"
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                failure = "the Athena read did not complete"
                break
            activity.wait(min(PROCESS_POLL_SECONDS, remaining))
            activity.clear()

        if failure:
            raise AthenaEvidenceError(failure)
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired) as exc:
        raise AthenaEvidenceError("the Athena read did not complete") from exc
    finally:
        active_error = sys.exc_info()[1]
        interrupted = None
        interrupted_traceback = None
        while True:
            try:
                finalize_requested.set()
                break
            except BaseException as exc:
                if interrupted is None:
                    interrupted = exc
                    interrupted_traceback = exc.__traceback__
        if finalizer.ident is not None:
            while finalizer.is_alive():
                try:
                    finalizer.join(PROCESS_POLL_SECONDS)
                except BaseException as exc:
                    if interrupted is None:
                        interrupted = exc
                        interrupted_traceback = exc.__traceback__
        cleanup = finalize_outcome.get("error")
        if cleanup is not None:
            cleanup_error, cleanup_traceback = cleanup
            if active_error is not None:
                raise cleanup_error.with_traceback(cleanup_traceback) from active_error
            raise cleanup_error.with_traceback(cleanup_traceback)
        if interrupted is not None and active_error is None:
            raise interrupted.with_traceback(interrupted_traceback)

    leader_returncode = state["leader_returncode"]
    if leader_returncode is None:
        raise AthenaEvidenceError("the Athena helper leader was not reaped")
    status_payload = b"".join(chunks["status"])
    if len(status_payload) != PROCESS_STATUS_BYTES:
        raise AthenaEvidenceError("the Athena helper status is malformed")
    returncode = struct.unpack("!i", status_payload)[0]
    try:
        stdout = b"".join(chunks["stdout"]).decode("utf-8")
        stderr = b"".join(chunks["stderr"]).decode("utf-8")
    except UnicodeDecodeError as exc:
        raise AthenaEvidenceError("the Athena read output is not valid UTF-8") from exc
    return subprocess.CompletedProcess(command, returncode, stdout, stderr)


def run_command(
    plugin_root: str,
    harness_file: str,
    relative: str,
    argv: list[str],
    *,
    input_text: str | None = None,
    cwd: str | None = None,
) -> str:
    """Run one audited read-only helper with fixed arguments and bounded output."""
    if not isinstance(argv, list) or not argv or not all(
        isinstance(item, str) and item for item in argv
    ):
        raise AthenaEvidenceError("Athena helper arguments are malformed")
    root = _verified_plugin_root(plugin_root)
    if input_text is not None and len(input_text.encode("utf-8")) > MAX_INPUT_BYTES:
        raise AthenaEvidenceError("Athena helper input exceeds 1 MiB")
    if input_text is not None and relative in {
        RULES_COMMAND,
        BRANCH_PROTECTION_COMMAND,
        CHECK_RUNS_COMMAND,
        MERGE_READINESS_COMMAND,
    }:
        raise AthenaEvidenceError("read-only forge operations do not accept input")
    e2e_root = os.path.dirname(os.path.abspath(harness_file))
    adapter = os.path.join(e2e_root, "athena_readonly_chain.py")
    if os.path.realpath(adapter) != adapter:
        raise AthenaEvidenceError("the read-only chain adapter is symlinked")
    if relative in {RULES_COMMAND, BRANCH_PROTECTION_COMMAND}:
        if (
            len(argv) != 2
            or REPOSITORY.fullmatch(argv[0]) is None
            or re.fullmatch(r"[A-Za-z0-9._/-]{1,255}", argv[1]) is None
            or argv[1].startswith("/")
            or ".." in argv[1].split("/")
        ):
            raise AthenaEvidenceError("effective branch-rule arguments are malformed")
        endpoint = (
            f"repos/{argv[0]}/rules/branches/{argv[1]}"
            if relative == RULES_COMMAND
            else f"repos/{argv[0]}/branches/{argv[1]}/protection"
        )
        command = [
            "gh", "api", "--hostname", "github.com", "--method", "GET",
            "-H", "Accept: application/vnd.github+json",
            endpoint,
        ]
        if relative == RULES_COMMAND:
            command.extend(["-f", "per_page=100", "--paginate", "--slurp"])
    elif relative == CHECK_RUNS_COMMAND:
        if (
            len(argv) != 2
            or REPOSITORY.fullmatch(argv[0]) is None
            or HEX_40.fullmatch(argv[1]) is None
        ):
            raise AthenaEvidenceError("head check-run arguments are malformed")
        command = [
            "gh", "api", "--hostname", "github.com", "--method", "GET",
            "-H", "Accept: application/vnd.github+json",
            f"repos/{argv[0]}/commits/{argv[1]}/check-runs?per_page=100",
            "--paginate", "--slurp",
        ]
    elif relative == MERGE_READINESS_COMMAND:
        if (
            len(argv) != 3
            or REPOSITORY.fullmatch(argv[0]) is None
            or re.fullmatch(r"[1-9][0-9]*", argv[1]) is None
            or HEX_40.fullmatch(argv[2]) is None
        ):
            raise AthenaEvidenceError("pull-request readiness arguments are malformed")
        command = [
            "gh", "pr", "view", argv[1], "--repo", argv[0],
            "--json", "url,state,headRefOid,reviewDecision",
        ]
    else:
        if relative not in PLUGIN_COMMANDS and relative != CHAIN_COMMAND:
            raise AthenaEvidenceError("the Athena helper is not allowlisted")
        command = []
    try:
        if relative in {
            RULES_COMMAND,
            BRANCH_PROTECTION_COMMAND,
            CHECK_RUNS_COMMAND,
            MERGE_READINESS_COMMAND,
        }:
            result = _run_bounded_process(
                command,
                input_text=input_text,
                cwd=cwd,
                environment=_sanitized_environment(),
            )
        else:
            with _private_script_copy(
                adapter, CHAIN_ADAPTER_SHA256
            ) as private_adapter:
                if relative in PLUGIN_COMMANDS:
                    command = [
                        sys.executable, "-I", "-S", "-B", private_adapter,
                        "run-helper", "--plugin-root", root,
                        "--relative", relative, "--", *argv,
                    ]
                else:
                    command = [
                        sys.executable, "-I", "-S", "-B", private_adapter,
                        "--plugin-root", root, *argv,
                    ]
                result = _run_bounded_process(
                    command,
                    input_text=input_text,
                    cwd=cwd,
                    environment=_sanitized_environment(),
                )
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired) as exc:
        raise AthenaEvidenceError("the Athena read did not complete") from exc
    stdout = result.stdout if isinstance(result.stdout, str) else ""
    stderr = result.stderr if isinstance(result.stderr, str) else ""
    if (
        len(stdout.encode("utf-8")) > MAX_OUTPUT_BYTES
        or len(stderr.encode("utf-8")) > MAX_STDERR_BYTES
    ):
        raise AthenaEvidenceError("the Athena read exceeded its output bound")
    if result.returncode != 0:
        diagnostic = " ".join(stderr.split())[:300]
        raise AthenaEvidenceError(
            f"the Athena read failed: {diagnostic or 'no diagnostic'}"
        )
    if not stdout.strip():
        raise AthenaEvidenceError("the Athena read returned empty output")
    if relative == RULES_COMMAND:
        pages = _load_json(stdout, "live effective branch-rule pages")
        if not isinstance(pages, list) or not pages or len(pages) > MAX_RULE_PAGES:
            raise AthenaEvidenceError(
                "live effective branch-rule pagination is incomplete"
            )
        flattened: list[object] = []
        for page in pages:
            if not isinstance(page, list) or len(page) > MAX_RULES_PER_PAGE:
                raise AthenaEvidenceError(
                    "live effective branch-rule pagination is malformed"
                )
            flattened.extend(page)
        return _canonical_json(flattened)
    if relative == CHECK_RUNS_COMMAND:
        pages = _load_json(stdout, "live head check-run pages")
        if not isinstance(pages, list) or not pages or len(pages) > MAX_RULE_PAGES:
            raise AthenaEvidenceError("live head check-run pagination is incomplete")
        total: int | None = None
        checks: list[object] = []
        for page in pages:
            if not isinstance(page, dict):
                raise AthenaEvidenceError("live head check-run pagination is malformed")
            page_total = page.get("total_count")
            page_checks = page.get("check_runs")
            if (
                type(page_total) is not int
                or page_total < 0
                or page_total > MAX_CHECK_RUNS
                or not isinstance(page_checks, list)
                or len(page_checks) > MAX_RULES_PER_PAGE
            ):
                raise AthenaEvidenceError("live head check-run pagination is malformed")
            if total is None:
                total = page_total
            elif page_total != total:
                raise AthenaEvidenceError("live head check-run totals changed")
            checks.extend(page_checks)
        if total is None or len(checks) != total or not checks:
            raise AthenaEvidenceError("live head check-run pagination is incomplete")
        return _canonical_json(checks)
    if relative == MERGE_READINESS_COMMAND:
        value = _load_object(stdout, "live pull-request readiness")
        if set(value) != {"url", "state", "headRefOid", "reviewDecision"}:
            raise AthenaEvidenceError("live pull-request readiness is malformed")
        expected_url = f"https://github.com/{argv[0]}/pull/{argv[1]}"
        decision = value["reviewDecision"]
        if decision in {None, ""}:
            decision = "UNAVAILABLE"
        if (
            value["url"] != expected_url
            or value["state"] != "OPEN"
            or value["headRefOid"] != argv[2]
            or not isinstance(decision, str)
        ):
            raise AthenaEvidenceError("live pull-request readiness is stale or malformed")
        return _canonical_json({
            "repository": argv[0],
            "number": int(argv[1]),
            "url": expected_url,
            "state": "OPEN",
            "head_oid": argv[2],
            "review_decision": decision,
        })
    return stdout.strip()


def canonical_carrier(
    runner: Callable[..., str], body: str, *, cwd: str | None = None
) -> dict:
    """Extract and independently verify one carrier through Athena's public CLI."""
    extracted = _load_object(
        runner(
            "skills/review-exchange/scripts/review_exchange.py",
            ["extract", "-"],
            input_text=body,
            cwd=cwd,
        ),
        "Athena extracted carrier",
    )
    verified = _load_object(
        runner(
            "skills/review-exchange/scripts/review_exchange.py",
            ["verify", "-"],
            input_text=_canonical_json(extracted),
            cwd=cwd,
        ),
        "Athena verified carrier",
    )
    if verified != extracted:
        raise AthenaEvidenceError("Athena extract and verify results differ")
    return verified


def _collector_argv(
    pr_url: str,
    repository: str,
    number: int,
    base_oid: str,
    head_oid: str,
    requirement_url: str,
) -> list[str]:
    return [
        "--expected-base-oid",
        base_oid,
        "--expected-head-oid",
        head_oid,
        "--expected-host",
        "github.com",
        "--expected-repository",
        repository,
        "--expected-pr-number",
        str(number),
        "--expected-pr-url",
        pr_url,
        "--requirement-issue",
        requirement_url,
        str(number),
    ]


def _validated_collector(
    value: dict,
    *,
    pr_url: str,
    repository: str,
    number: int,
    base_oid: str,
    head_oid: str,
    requirement_url: str,
    envelope: dict,
    expected_base_ref: str,
    expected_head_ref: str,
) -> dict:
    identity = value.get("reviewed_identity")
    expected_identity = {
        "forge_host": "github.com",
        "repository": repository,
        "number": number,
        "url": pr_url,
        "state": "OPEN",
        "base_oid": base_oid,
        "head_oid": head_oid,
    }
    if identity != expected_identity:
        raise AthenaEvidenceError("Athena evidence does not bind the open PR")
    scope = value.get("reviewed_scope")
    requirements = value.get("reviewed_linked_requirements")
    expected_scope_fields = {
        "title", "body", "closingIssuesReferences", "state", "isDraft",
        "baseRefName", "headRefName",
    }
    if (
        not isinstance(scope, dict)
        or set(scope) != {"fields", "sha256"}
        or not isinstance(scope["fields"], dict)
        or set(scope["fields"]) != expected_scope_fields
        or not isinstance(scope["fields"]["title"], str)
        or (
            scope["fields"]["body"] is not None
            and not isinstance(scope["fields"]["body"], str)
        )
        or not isinstance(scope["fields"]["closingIssuesReferences"], list)
        or not all(
            isinstance(item, dict)
            for item in scope["fields"]["closingIssuesReferences"]
        )
        or scope["fields"]["state"] != "OPEN"
        or scope["fields"]["isDraft"] is not False
        or scope["fields"]["baseRefName"] != expected_base_ref
        or scope["fields"]["headRefName"] != expected_head_ref
        or HEX_64.fullmatch(scope.get("sha256", "")) is None
        or not isinstance(requirements, dict)
        or set(requirements) != {"count", "items", "sha256"}
        or type(requirements["count"]) is not int
        or not isinstance(requirements["items"], list)
        or requirements["count"] != len(requirements["items"])
        or HEX_64.fullmatch(requirements.get("sha256", "")) is None
    ):
        raise AthenaEvidenceError("Athena evidence is incomplete or malformed")
    requirement_urls: list[str] = []
    requirement_ids: set[str] = set()
    for item in requirements["items"]:
        if not isinstance(item, dict) or set(item) != {
            "id", "repository", "number", "url", "content_sha256"
        }:
            raise AthenaEvidenceError("Athena requirement evidence is malformed")
        issue_id = item["id"]
        issue_repo = item["repository"]
        issue_number = item["number"]
        expected_url = f"https://github.com/{issue_repo}/issues/{issue_number}"
        if (
            not isinstance(issue_id, str)
            or not issue_id
            or issue_id in requirement_ids
            or REPOSITORY.fullmatch(issue_repo or "") is None
            or type(issue_number) is not int
            or issue_number < 1
            or item["url"] != expected_url
            or HEX_64.fullmatch(item.get("content_sha256", "")) is None
        ):
            raise AthenaEvidenceError("Athena requirement evidence is malformed")
        requirement_ids.add(issue_id)
        requirement_urls.append(expected_url)
    if requirement_url not in requirement_urls or len(set(requirement_urls)) != len(
        requirement_urls
    ):
        raise AthenaEvidenceError("the trusted task requirement is not bound")
    state = envelope.get("state")
    if (
        not isinstance(state, dict)
        or state.get("artifact_binding", {}).get("revision") != head_oid
        or state.get("artifact_binding", {}).get("sha256") != scope["sha256"]
        or state.get("requirements_sha256") != requirements["sha256"]
    ):
        raise AthenaEvidenceError("the terminal state does not bind live evidence")
    return {
        "reviewed_identity": identity,
        "reviewed_scope": scope,
        "reviewed_linked_requirements": requirements,
    }


def _validated_checks(value: object, head_oid: str) -> dict:
    if not isinstance(value, list) or not value or len(value) > MAX_CHECK_RUNS:
        raise AthenaEvidenceError("live check evidence is incomplete or malformed")
    check_ids: set[int] = set()
    successful = False
    checks: list[dict] = []
    for check in value:
        if not isinstance(check, dict):
            raise AthenaEvidenceError("live check evidence is malformed")
        check_id = check.get("id")
        if (
            type(check_id) is not int
            or check_id < 1
            or check_id in check_ids
            or not isinstance(check.get("name"), str)
            or not check["name"].strip()
            or check.get("head_sha") != head_oid
            or check.get("status") != "completed"
            or check.get("conclusion") not in {"success", "neutral", "skipped"}
        ):
            raise AthenaEvidenceError("live check evidence is not successful")
        check_ids.add(check_id)
        successful = successful or check["conclusion"] == "success"
        checks.append(check)
    if not successful:
        raise AthenaEvidenceError("live check evidence has no successful check")
    return {
        "check_evidence": {
            "status": "head_bound",
            "head_oid": head_oid,
            "count": len(checks),
        },
        "checks": checks,
    }


def _validated_readiness(
    value: object,
    *,
    repository: str,
    number: int,
    pr_url: str,
    head_oid: str,
) -> dict:
    if (
        not isinstance(value, dict)
        or set(value) != {
            "repository", "number", "url", "state", "head_oid",
            "review_decision",
        }
        or value["repository"] != repository
        or value["number"] != number
        or type(value["number"]) is not int
        or value["url"] != pr_url
        or value["state"] != "OPEN"
        or value["head_oid"] != head_oid
        or value["review_decision"] not in {
            "APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED", "UNAVAILABLE"
        }
    ):
        raise AthenaEvidenceError("live pull-request readiness is stale or malformed")
    decision = value["review_decision"]
    approval_gate = {
        "APPROVED": "satisfied",
        "CHANGES_REQUESTED": "blocked",
        "REVIEW_REQUIRED": "blocked",
    }.get(decision, "unknown")
    return {
        "merge_readiness": {
            "auto_merge_approval_gate": approval_gate,
            "authority": "Repository policy is separate from Athena source review.",
            "review_decision": decision,
        },
    }


def _validated_policy(value: object, collector: dict) -> dict:
    """Bind live effective rules to exact successful Checks API contexts."""
    if not isinstance(value, list) or not value:
        raise AthenaEvidenceError("live effective branch rules are unavailable")
    required: set[tuple[str, int]] = set()
    pull_request_rules = 0
    approvals_required = 0
    thread_resolution_required = False
    allowed_merge_methods: set[str] | None = None
    for rule in value:
        if not isinstance(rule, dict) or not isinstance(rule.get("type"), str):
            raise AthenaEvidenceError("live effective branch rules are malformed")
        if rule["type"] == "required_status_checks":
            parameters = rule.get("parameters")
            if not isinstance(parameters, dict):
                raise AthenaEvidenceError("required-check policy is malformed")
            checks = parameters.get("required_status_checks")
            if not isinstance(checks, list) or not checks:
                raise AthenaEvidenceError("required-check policy is empty")
            for check in checks:
                if not isinstance(check, dict):
                    raise AthenaEvidenceError("required-check policy is malformed")
                context = check.get("context")
                integration_id = check.get("integration_id")
                if (
                    not isinstance(context, str)
                    or not context.strip()
                    or type(integration_id) is not int
                    or integration_id < 1
                ):
                    raise AthenaEvidenceError("required-check policy is malformed")
                required.add((context, integration_id))
        elif rule["type"] == "pull_request":
            parameters = rule.get("parameters")
            if not isinstance(parameters, dict):
                raise AthenaEvidenceError("pull-request policy is malformed")
            approval_count = parameters.get("required_approving_review_count")
            thread_resolution = parameters.get("required_review_thread_resolution")
            merge_methods = parameters.get("allowed_merge_methods")
            if (
                type(approval_count) is not int
                or approval_count < 0
                or type(thread_resolution) is not bool
                or not isinstance(merge_methods, list)
                or not merge_methods
                or not all(
                    method in {"merge", "squash", "rebase"}
                    for method in merge_methods
                )
            ):
                raise AthenaEvidenceError("pull-request policy is malformed")
            pull_request_rules += 1
            approvals_required = max(approvals_required, approval_count)
            thread_resolution_required = (
                thread_resolution_required or thread_resolution
            )
            methods = set(merge_methods)
            allowed_merge_methods = (
                methods
                if allowed_merge_methods is None
                else allowed_merge_methods.intersection(methods)
            )
    if (
        not required
        or pull_request_rules < 1
        or not thread_resolution_required
        or not allowed_merge_methods
    ):
        raise AthenaEvidenceError("live branch policy lacks required delivery gates")
    if (
        approvals_required > 0
        and collector["merge_readiness"]["auto_merge_approval_gate"] != "satisfied"
    ):
        raise AthenaEvidenceError("required pull-request approvals are not satisfied")
    observed: dict[tuple[str, int], list[dict]] = {}
    for check in collector["checks"]:
        app = check.get("app")
        app_id = app.get("id") if isinstance(app, dict) else None
        if type(app_id) is int and app_id > 0:
            observed.setdefault((check["name"], app_id), []).append(check)
    for identity in required:
        matches = observed.get(identity, [])
        if len(matches) != 1 or matches[0].get("conclusion") != "success":
            raise AthenaEvidenceError(
                "a live required check is missing, ambiguous, or unsuccessful"
            )
    return {
        "required_status_checks": [
            {"context": context, "integration_id": integration_id}
            for context, integration_id in sorted(required)
        ],
        "required_approvals": approvals_required,
        "required_thread_resolution": thread_resolution_required,
        "allowed_merge_methods": sorted(allowed_merge_methods),
    }


def _validated_branch_protection(value: object, collector: dict) -> dict:
    """Bind classic branch protection without assuming it matches rulesets."""
    if not isinstance(value, dict):
        raise AthenaEvidenceError("live branch protection is unavailable")
    conversation = value.get("required_conversation_resolution")
    force_pushes = value.get("allow_force_pushes")
    deletions = value.get("allow_deletions")
    reviews = value.get("required_pull_request_reviews")
    if (
        not isinstance(conversation, dict)
        or conversation.get("enabled") is not True
        or not isinstance(force_pushes, dict)
        or force_pushes.get("enabled") is not False
        or not isinstance(deletions, dict)
        or deletions.get("enabled") is not False
        or not isinstance(reviews, dict)
        or type(reviews.get("required_approving_review_count")) is not int
        or reviews["required_approving_review_count"] < 0
    ):
        raise AthenaEvidenceError("live branch protection is incomplete")
    approval_count = reviews["required_approving_review_count"]
    if (
        approval_count > 0
        and collector["merge_readiness"]["auto_merge_approval_gate"] != "satisfied"
    ):
        raise AthenaEvidenceError("branch-protection approvals are not satisfied")

    required = value.get("required_status_checks")
    app_bound: set[tuple[str, int]] = set()
    legacy_contexts: set[str] = set()
    if required is not None:
        if not isinstance(required, dict) or type(required.get("strict")) is not bool:
            raise AthenaEvidenceError("branch-protection checks are malformed")
        checks = required.get("checks", [])
        contexts = required.get("contexts", [])
        if not isinstance(checks, list) or not isinstance(contexts, list):
            raise AthenaEvidenceError("branch-protection checks are malformed")
        for check in checks:
            if not isinstance(check, dict):
                raise AthenaEvidenceError("branch-protection checks are malformed")
            context = check.get("context")
            app_id = check.get("app_id")
            if (
                not isinstance(context, str)
                or not context.strip()
                or type(app_id) is not int
                or app_id < 1
            ):
                raise AthenaEvidenceError("branch-protection checks are malformed")
            app_bound.add((context, app_id))
        for context in contexts:
            if not isinstance(context, str) or not context.strip():
                raise AthenaEvidenceError("branch-protection checks are malformed")
            legacy_contexts.add(context)

    checks_by_identity: dict[tuple[str, int], list[dict]] = {}
    checks_by_name: dict[str, list[dict]] = {}
    for check in collector["checks"]:
        app = check.get("app")
        app_id = app.get("id") if isinstance(app, dict) else None
        checks_by_name.setdefault(check["name"], []).append(check)
        if type(app_id) is int and app_id > 0:
            checks_by_identity.setdefault((check["name"], app_id), []).append(check)
    for identity in app_bound:
        matches = checks_by_identity.get(identity, [])
        if len(matches) != 1 or matches[0].get("conclusion") != "success":
            raise AthenaEvidenceError(
                "a branch-protection check is missing, ambiguous, or unsuccessful"
            )
    for context in legacy_contexts:
        matches = checks_by_name.get(context, [])
        if len(matches) != 1 or matches[0].get("conclusion") != "success":
            raise AthenaEvidenceError(
                "a branch-protection context is missing, ambiguous, or unsuccessful"
            )
    return {
        "required_approvals": approval_count,
        "required_conversation_resolution": True,
        "allow_force_pushes": False,
        "allow_deletions": False,
        "required_status_checks": [
            {"context": context, "integration_id": integration_id}
            for context, integration_id in sorted(app_bound)
        ],
        "required_legacy_contexts": sorted(legacy_contexts),
    }


def _validated_chain(
    value: dict,
    *,
    pr_url: str,
    repository: str,
    number: int,
    base_oid: str,
    head_oid: str,
    envelope: dict,
    collector: dict,
    reviewer_login: str,
) -> None:
    expected_keys = {
        "schema_id", "schema_version", "binding", "terminal",
        "selected_state_sha256s", "verified_state_sha256s",
        "implementation_labels", "unresolved_thread_count",
    }
    if set(value) != expected_keys:
        raise AthenaEvidenceError("Athena chain proof is malformed")
    binding = {
        "repository": repository,
        "number": number,
        "url": pr_url,
        "base_oid": base_oid,
        "head_oid": head_oid,
    }
    terminal = value.get("terminal")
    state_digest = envelope.get("state_sha256")
    if (
        value.get("schema_id") != "odysseus.athena-readonly-chain-proof"
        or value.get("schema_version") != 1
        or value.get("binding") != binding
        or not isinstance(terminal, dict)
        or set(terminal) != {
            "review_id", "reviewer_login", "state_sha256", "reviewed_scope_sha256",
            "requirements_sha256",
        }
        or not isinstance(terminal["review_id"], str)
        or not terminal["review_id"]
        or not isinstance(terminal["reviewer_login"], str)
        or terminal["reviewer_login"] != reviewer_login
        or terminal["state_sha256"] != state_digest
        or terminal["reviewed_scope_sha256"]
        != collector["reviewed_scope"]["sha256"]
        or terminal["requirements_sha256"]
        != collector["reviewed_linked_requirements"]["sha256"]
        or not isinstance(value.get("selected_state_sha256s"), list)
        or not isinstance(value.get("verified_state_sha256s"), list)
        or state_digest not in value["selected_state_sha256s"]
        or state_digest not in value["verified_state_sha256s"]
        or len(value["selected_state_sha256s"])
        != len(set(value["selected_state_sha256s"]))
        or len(value["verified_state_sha256s"])
        != len(set(value["verified_state_sha256s"]))
        or value.get("implementation_labels") != ["state:implementation-go"]
        or value.get("unresolved_thread_count") != 0
    ):
        raise AthenaEvidenceError("Athena chain proof does not authorize delivery")


def require_live_evidence(
    runner: Callable[..., str],
    *,
    pr_url: str,
    repository: str,
    base_oid: str,
    head_oid: str,
    envelope: dict,
    requirement_url: str,
    reviewer_login: str,
    expected_base_ref: str,
    expected_head_ref: str,
    cwd: str | None = None,
) -> dict:
    """Double-bind head checks and the exact live Athena logical chain."""
    if REPOSITORY.fullmatch(repository) is None:
        raise AthenaEvidenceError("the repository identity is malformed")
    if HEX_40.fullmatch(base_oid) is None or HEX_40.fullmatch(head_oid) is None:
        raise AthenaEvidenceError("the pull-request object identifiers are malformed")
    for name, reference in (
        ("base", expected_base_ref),
        ("head", expected_head_ref),
    ):
        if (
            not isinstance(reference, str)
            or re.fullmatch(r"[A-Za-z0-9._/-]{1,255}", reference) is None
            or reference.startswith("/")
            or ".." in reference.split("/")
        ):
            raise AthenaEvidenceError(f"the expected {name} reference is malformed")
    match = re.fullmatch(
        rf"https://github\.com/{re.escape(repository)}/pull/([1-9][0-9]*)",
        pr_url,
    )
    if match is None:
        raise AthenaEvidenceError("the pull-request URL is malformed")
    if not isinstance(reviewer_login, str) or re.fullmatch(
        r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})", reviewer_login
    ) is None:
        raise AthenaEvidenceError("ATHENA_REVIEWER_LOGIN is not configured safely")
    number = int(match.group(1))
    collector_argv = _collector_argv(
        pr_url, repository, number, base_oid, head_oid, requirement_url
    )
    first_source = _validated_collector(
        _load_object(
            runner(
                "skills/pr-review/scripts/collect_evidence.py",
                collector_argv,
                cwd=cwd,
            ),
            "Athena evidence",
        ),
        pr_url=pr_url,
        repository=repository,
        number=number,
        base_oid=base_oid,
        head_oid=head_oid,
        requirement_url=requirement_url,
        envelope=envelope,
        expected_base_ref=expected_base_ref,
        expected_head_ref=expected_head_ref,
    )
    first_checks = _validated_checks(
        _load_json(
            runner(CHECK_RUNS_COMMAND, [repository, head_oid], cwd=cwd),
            "live head check runs",
        ),
        head_oid,
    )
    first_readiness = _validated_readiness(
        _load_object(
            runner(
                MERGE_READINESS_COMMAND,
                [repository, str(number), head_oid],
                cwd=cwd,
            ),
            "live pull-request readiness",
        ),
        repository=repository,
        number=number,
        pr_url=pr_url,
        head_oid=head_oid,
    )
    first = {**first_source, **first_checks, **first_readiness}
    base_branch = expected_base_ref
    first_rules_raw = _load_json(
        runner(RULES_COMMAND, [repository, base_branch], cwd=cwd),
        "live effective branch rules",
    )
    first_policy = _validated_policy(first_rules_raw, first)
    first_protection_raw = _load_json(
        runner(BRANCH_PROTECTION_COMMAND, [repository, base_branch], cwd=cwd),
        "live branch protection",
    )
    first_protection = _validated_branch_protection(first_protection_raw, first)
    chain_argv = [
        "--repository", repository,
        "--number", str(number),
        "--url", pr_url,
        "--base-oid", base_oid,
        "--head-oid", head_oid,
        "--terminal-state-sha256", envelope["state_sha256"],
        "--reviewer-login", reviewer_login,
    ]
    first_chain = _load_object(
        runner(CHAIN_COMMAND, chain_argv, cwd=cwd),
        "Athena chain proof",
    )
    _validated_chain(
        first_chain,
        pr_url=pr_url,
        repository=repository,
        number=number,
        base_oid=base_oid,
        head_oid=head_oid,
        envelope=envelope,
        collector=first,
        reviewer_login=reviewer_login,
    )
    second_source = _validated_collector(
        _load_object(
            runner(
                "skills/pr-review/scripts/collect_evidence.py",
                collector_argv,
                cwd=cwd,
            ),
            "Athena evidence recheck",
        ),
        pr_url=pr_url,
        repository=repository,
        number=number,
        base_oid=base_oid,
        head_oid=head_oid,
        requirement_url=requirement_url,
        envelope=envelope,
        expected_base_ref=expected_base_ref,
        expected_head_ref=expected_head_ref,
    )
    second_checks = _validated_checks(
        _load_json(
            runner(CHECK_RUNS_COMMAND, [repository, head_oid], cwd=cwd),
            "live head check-run recheck",
        ),
        head_oid,
    )
    second_readiness = _validated_readiness(
        _load_object(
            runner(
                MERGE_READINESS_COMMAND,
                [repository, str(number), head_oid],
                cwd=cwd,
            ),
            "live pull-request readiness recheck",
        ),
        repository=repository,
        number=number,
        pr_url=pr_url,
        head_oid=head_oid,
    )
    second = {**second_source, **second_checks, **second_readiness}
    if second != first:
        raise AthenaEvidenceError("Athena evidence changed during verification")
    second_rules_raw = _load_json(
        runner(RULES_COMMAND, [repository, base_branch], cwd=cwd),
        "live effective branch-rule recheck",
    )
    second_protection_raw = _load_json(
        runner(BRANCH_PROTECTION_COMMAND, [repository, base_branch], cwd=cwd),
        "live branch-protection recheck",
    )
    if _canonical_json(second_rules_raw) != _canonical_json(first_rules_raw):
        raise AthenaEvidenceError("live effective branch rules changed")
    if _canonical_json(second_protection_raw) != _canonical_json(
        first_protection_raw
    ):
        raise AthenaEvidenceError("live branch protection changed")
    second_policy = _validated_policy(second_rules_raw, second)
    second_protection = _validated_branch_protection(
        second_protection_raw, second
    )
    if second_policy != first_policy:
        raise AthenaEvidenceError("live effective branch policy changed")
    if second_protection != first_protection:
        raise AthenaEvidenceError("live branch protection changed")
    second_chain = _load_object(
        runner(CHAIN_COMMAND, chain_argv, cwd=cwd),
        "Athena chain-proof recheck",
    )
    _validated_chain(
        second_chain,
        pr_url=pr_url,
        repository=repository,
        number=number,
        base_oid=base_oid,
        head_oid=head_oid,
        envelope=envelope,
        collector=second,
        reviewer_login=reviewer_login,
    )
    if _canonical_json(second_chain) != _canonical_json(first_chain):
        raise AthenaEvidenceError("Athena chain proof changed during verification")
    return {
        **first,
        "effective_policy": {
            **first_policy,
            "branch_protection": first_protection,
        },
    }
