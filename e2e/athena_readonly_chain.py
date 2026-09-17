#!/usr/bin/env python3
"""Verify one live Athena review chain without exposing delivery mutations.

This compatibility adapter is intentionally pinned to Athena 0.5.3.  It loads
only the audited implementation, wraps the live forge in a read-only facade,
and calls the review-chain verifier without constructing or invoking any
delivery operation. Histories needing external anchor annexes or historical
proof files fail closed; the ADR-020 mesh owns their future orchestration.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.util
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path
from collections.abc import Iterator
from typing import Any


SCHEMA_ID = "odysseus.athena-readonly-chain-proof"
COMMIT_OID = re.compile(r"[0-9a-f]{40}")
STATE_DIGEST = re.compile(r"[0-9a-f]{64}")
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
EXPECTED_HELPERS = {
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


class VerificationError(RuntimeError):
    """The live review cannot be proven safe for terminal delivery."""


def _read_regular_file(path: str, maximum_bytes: int = 8 * 1024 * 1024) -> bytes:
    """Read a bounded regular file without following its final symlink."""
    no_follow = getattr(os, "O_NOFOLLOW", None)
    if not isinstance(no_follow, int) or no_follow == 0:
        raise VerificationError("O_NOFOLLOW is required for Athena verification")
    try:
        descriptor = os.open(path, os.O_RDONLY | no_follow)
    except OSError as exc:
        raise VerificationError("an Athena helper cannot be opened safely") from exc
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise VerificationError("an Athena helper is not a regular file")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            value = stream.read(maximum_bytes + 1)
    finally:
        os.close(descriptor)
    if len(value) > maximum_bytes:
        raise VerificationError("an Athena helper exceeds its audited size bound")
    return value


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise VerificationError(f"duplicate release metadata key: {key}")
        result[key] = value
    return result


def _release_object(
    path: str, context: str, expected_sha256: str
) -> dict[str, object]:
    try:
        release_bytes = _read_regular_file(path, 64 * 1024)
        if hashlib.sha256(release_bytes).hexdigest() != expected_sha256:
            raise VerificationError(f"{context} bytes do not match release 0.5.3")
        payload = release_bytes.decode("utf-8")
        value = json.loads(
            payload,
            object_pairs_hook=_unique_object,
            parse_constant=lambda item: (_ for _ in ()).throw(
                VerificationError(f"nonfinite release metadata value: {item}")
            ),
        )
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise VerificationError(f"{context} is not valid JSON") from exc
    if not isinstance(value, dict):
        raise VerificationError(f"{context} is not a JSON object")
    return value


def _release_path(root: str, relative: str) -> str:
    candidate = os.path.normpath(os.path.join(root, relative))
    if (
        os.path.commonpath((root, candidate)) != root
        or os.path.realpath(candidate) != candidate
    ):
        raise VerificationError("Athena release metadata escapes the plugin tree")
    return candidate


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
        raise VerificationError("the Athena plugin manifest is not release 0.5.3")
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
        raise VerificationError("the Athena install manifest is not the pinned release")


def _verified_plugin_payloads(value: str) -> dict[str, bytes]:
    """Read each audited helper once and bind the exact bytes to its digest."""
    if not value or not os.path.isabs(value):
        raise VerificationError("ATHENA_PLUGIN_ROOT must be an absolute path")
    normalized = os.path.normpath(value)
    if normalized != value or os.path.realpath(value) != value:
        raise VerificationError("ATHENA_PLUGIN_ROOT must not contain symlinks")
    root = Path(value)
    try:
        root_metadata = os.lstat(root)
    except OSError as exc:
        raise VerificationError("ATHENA_PLUGIN_ROOT is unavailable") from exc
    if not stat.S_ISDIR(root_metadata.st_mode):
        raise VerificationError("ATHENA_PLUGIN_ROOT is not a directory")
    _verify_release_metadata(value)
    payloads: dict[str, bytes] = {}
    for relative, expected_digest in EXPECTED_HELPERS.items():
        candidate = _release_path(value, relative)
        payload = _read_regular_file(candidate)
        observed = hashlib.sha256(payload).hexdigest()
        if observed != expected_digest:
            raise VerificationError("the Athena helper release digest does not match")
        payloads[relative] = payload
    return payloads


def _write_private_file(path: Path, payload: bytes) -> None:
    no_follow = getattr(os, "O_NOFOLLOW", None)
    if not isinstance(no_follow, int) or no_follow == 0:
        raise VerificationError("O_NOFOLLOW is required for Athena staging")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | no_follow,
        0o400,
    )
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(descriptor)
    finally:
        os.close(descriptor)


@contextlib.contextmanager
def _materialized_plugin(value: str) -> Iterator[Path]:
    """Yield a private source-only copy created from the hash-verified bytes."""
    payloads = _verified_plugin_payloads(value)
    with tempfile.TemporaryDirectory(prefix="odysseus-athena-source-") as temporary:
        root = Path(temporary) / "plugin"
        root.mkdir(mode=0o700)
        for relative, payload in payloads.items():
            _write_private_file(root / relative, payload)
        yield root


def _load_delivery_module(root: Path) -> Any:
    path = root / "skills/pr-review/scripts/deliver_go.py"
    spec = importlib.util.spec_from_file_location("athena_locked_delivery", path)
    if spec is None or spec.loader is None:
        raise VerificationError("the audited Athena delivery helper cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class _ReadOnlyForge:
    """Expose only the two live reads used by Athena's chain verifier."""

    __slots__ = ("_delegate",)

    def __init__(self, delegate: Any) -> None:
        self._delegate = delegate

    def snapshot(self) -> Any:
        return self._delegate.snapshot()

    def is_ancestor(self, older_oid: str, newer_oid: str) -> bool:
        return bool(self._delegate.is_ancestor(older_oid, newer_oid))

    def collect_requirements_binding(self, *_args: Any, **_kwargs: Any) -> Any:
        raise VerificationError("the read-only verifier cannot collect delivery data")

    def verify_requirements_binding(self, *_args: Any, **_kwargs: Any) -> Any:
        raise VerificationError("the read-only verifier cannot mutate delivery state")

    def reply(self, *_args: Any, **_kwargs: Any) -> Any:
        raise VerificationError("the read-only verifier cannot reply")

    def resolve(self, *_args: Any, **_kwargs: Any) -> Any:
        raise VerificationError("the read-only verifier cannot resolve threads")

    def set_implementation_go(self, *_args: Any, **_kwargs: Any) -> Any:
        raise VerificationError("the read-only verifier cannot change labels")

    def set_implementation_no_go(self, *_args: Any, **_kwargs: Any) -> Any:
        raise VerificationError("the read-only verifier cannot change labels")

    def publish_terminal(self, *_args: Any, **_kwargs: Any) -> Any:
        raise VerificationError("the read-only verifier cannot publish reviews")


def _install_read_only_gh(delivery: Any, repository: str) -> None:
    """Restrict Athena's internal GitHub adapter to its three required reads."""
    original = delivery._gh
    owner, name = repository.split("/", maxsplit=1)

    def read_only_gh(*arguments: str, input_text: str | None = None) -> str:
        if input_text is not None or not arguments or arguments[0] != "api":
            raise VerificationError("Athena attempted a non-read-only GitHub call")
        is_graphql = len(arguments) >= 2 and arguments[1] == "graphql"
        forbidden_long = (
            "--method", "--input", "--raw-field", "--field",
        )
        has_forbidden_option = any(
            item in forbidden_long
            or any(
                item.startswith(f"{option}=")
                for option in forbidden_long
            )
            or item == "-X"
            or (item.startswith("-X") and len(item) > 2)
            or (item.startswith("-f") and len(item) > 2)
            or (item.startswith("-F") and len(item) > 2)
            for item in arguments
        )
        if has_forbidden_option:
            if is_graphql:
                raise VerificationError(
                    "Athena attempted a non-read-only GraphQL call"
                )
            raise VerificationError("Athena attempted a REST mutation")
        if is_graphql:
            if (
                len(arguments) != 12
                or tuple(arguments[2:5])
                != ("--hostname", "github.com", "-f")
                or arguments[6] != "-f"
                or arguments[7] != f"owner={owner}"
                or arguments[8] != "-f"
                or arguments[9] != f"name={name}"
                or arguments[10] != "-F"
                or re.fullmatch(r"number=[1-9][0-9]*", arguments[11]) is None
                or not arguments[5].startswith("query=")
            ):
                raise VerificationError(
                    "Athena attempted a non-read-only GraphQL call"
                )
            query = arguments[5][6:]
            if (
                not query.lstrip().startswith("query")
                or re.search(r"\bmutation\b", query, re.IGNORECASE)
            ):
                raise VerificationError("Athena attempted a GraphQL mutation")
        else:
            if tuple(arguments[1:]) == ("--hostname", "github.com", "user"):
                return original(*arguments)
            paths = [item for item in arguments if item.startswith("repos/")]
            if len(paths) != 1:
                raise VerificationError("Athena attempted an unknown REST operation")
            path = paths[0]
            permission = re.fullmatch(
                rf"repos/{re.escape(owner)}/{re.escape(name)}/collaborators/"
                r"[^/]+/permission",
                path,
            )
            comparison = re.fullmatch(
                rf"repos/{re.escape(owner)}/{re.escape(name)}/compare/"
                r"[0-9a-f]{40}\.\.\.[0-9a-f]{40}",
                path,
            )
            if permission is None and comparison is None:
                raise VerificationError("Athena attempted an unknown REST operation")
            if any(item in {"-f", "-F"} for item in arguments):
                raise VerificationError("Athena attempted a REST mutation")
        return original(*arguments)

    delivery._gh = read_only_gh


def verify_chain(arguments: argparse.Namespace) -> dict[str, Any]:
    """Return a bounded proof for one exact live, immutable review chain."""
    if COMMIT_OID.fullmatch(arguments.base_oid) is None:
        raise VerificationError("the base object identifier is malformed")
    if COMMIT_OID.fullmatch(arguments.head_oid) is None:
        raise VerificationError("the head object identifier is malformed")
    if STATE_DIGEST.fullmatch(arguments.terminal_state_sha256) is None:
        raise VerificationError("the terminal state digest is malformed")
    if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", arguments.repository) is None:
        raise VerificationError("the repository identity is malformed")
    expected_url = (
        f"https://github.com/{arguments.repository}/pull/{arguments.number}"
    )
    if arguments.url != expected_url:
        raise VerificationError("the pull-request URL is malformed")
    if re.fullmatch(
        r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})", arguments.reviewer_login
    ) is None:
        raise VerificationError("the trusted Athena reviewer login is malformed")

    with _materialized_plugin(arguments.plugin_root) as root, \
            tempfile.TemporaryDirectory(prefix="odysseus-athena-pycache-") as cache:
        sys.pycache_prefix = cache
        delivery = _load_delivery_module(root)
        _install_read_only_gh(delivery, arguments.repository)
        binding = delivery.ReviewBinding(
            repository=arguments.repository,
            number=arguments.number,
            url=arguments.url,
            base_oid=arguments.base_oid,
            head_oid=arguments.head_oid,
        )
        forge = _ReadOnlyForge(delivery.GitHubForge(binding, "github.com"))
        viewer = delivery._json_object(
            delivery._gh("api", "--hostname", "github.com", "user"),
            "authenticated viewer response",
        )
        if viewer.get("login") != arguments.reviewer_login:
            raise VerificationError("the authenticated viewer is not the Athena reviewer")
        snapshot = delivery._snapshot(forge, binding)
        states, _authors = delivery._review_carriers(snapshot, binding)
        if any(
            review.author != arguments.reviewer_login
            for review in snapshot.reviews
            if delivery.review_exchange.CARRIER_PREFIX in review.body
        ):
            raise VerificationError("an Athena carrier has the wrong publisher identity")
        if any(
            comment.author != arguments.reviewer_login
            for thread in snapshot.threads
            for comment in thread.comments
            if comment.viewer_did_author
            and "<!-- HomericIntelligence:review-" in comment.body
        ):
            raise VerificationError("an Athena review root has the wrong publisher identity")
        terminal_records = [
            (review, envelope)
            for review, envelope in states.values()
            if (
                review.head_oid == arguments.head_oid
                and review.author == arguments.reviewer_login
                and envelope["state_sha256"] == arguments.terminal_state_sha256
                and envelope["state"]["artifact_binding"]["revision"]
                == arguments.head_oid
                and envelope["state"]["surface"] == "pull_request"
                and envelope["state"]["phase"] == "complete"
                and envelope["state"]["verdict"] == "GO"
                and envelope["state"]["next_action"] == "finalize"
                and envelope["state"]["coverage_complete"] is True
            )
        ]
        if len(terminal_records) != 1:
            raise VerificationError("there is not one exact-head terminal Athena GO")
        terminal_review, terminal = terminal_records[0]
        chain = delivery._verify_state_chain(
            forge,
            terminal,
            snapshot,
            binding,
            None,
            (),
            recover_direct_reframe=False,
        )
        if (
            terminal["state_sha256"] not in chain.selected_state_sha256s
            or terminal["state_sha256"] not in chain.verified_state_sha256s
        ):
            raise VerificationError("the terminal state is outside the verified chain")
        implementation_labels = {
            label for label in snapshot.labels
            if label.startswith("state:implementation-")
        }
        if implementation_labels != {"state:implementation-go"}:
            raise VerificationError("the live implementation state is not exclusive GO")
        unresolved = [thread.id for thread in snapshot.threads if not thread.is_resolved]
        if unresolved:
            raise VerificationError("the live Athena review still has open threads")
        final_snapshot = delivery._snapshot(forge, binding)
        if final_snapshot != snapshot:
            raise VerificationError("the live Athena review changed during verification")
    return {
        "schema_id": SCHEMA_ID,
        "schema_version": 1,
        "binding": {
            "repository": binding.repository,
            "number": binding.number,
            "url": binding.url,
            "base_oid": binding.base_oid,
            "head_oid": binding.head_oid,
        },
        "terminal": {
            "review_id": terminal_review.id,
            "reviewer_login": terminal_review.author,
            "state_sha256": terminal["state_sha256"],
            "reviewed_scope_sha256": terminal["state"]["artifact_binding"]["sha256"],
            "requirements_sha256": terminal["state"]["requirements_sha256"],
        },
        "selected_state_sha256s": sorted(chain.selected_state_sha256s),
        "verified_state_sha256s": sorted(chain.verified_state_sha256s),
        "implementation_labels": sorted(implementation_labels),
        "unresolved_thread_count": 0,
    }


def _run_verified_helper(arguments: argparse.Namespace) -> int:
    """Execute one audited helper from a private source-only materialization."""
    if arguments.relative not in {
        "skills/pr-review/scripts/collect_evidence.py",
        "skills/review-exchange/scripts/review_exchange.py",
    }:
        raise VerificationError("the source-only helper is not allowlisted")
    helper_argv = list(arguments.helper_argv)
    if helper_argv[:1] == ["--"]:
        helper_argv = helper_argv[1:]
    with _materialized_plugin(arguments.plugin_root) as root, \
            tempfile.TemporaryDirectory(prefix="odysseus-athena-pycache-") as cache:
        sys.pycache_prefix = cache
        script = root / arguments.relative
        source = _read_regular_file(str(script))
        sys.path.insert(0, str(script.parent))
        original_argv = sys.argv
        sys.argv = [str(script), *helper_argv]
        namespace = {
            "__builtins__": __builtins__,
            "__file__": str(script),
            "__name__": "__main__",
            "__package__": None,
        }
        try:
            exec(compile(source, str(script), "exec"), namespace, namespace)
        except SystemExit as exc:
            if exc.code in {None, 0}:
                return 0
            if isinstance(exc.code, int):
                return exc.code
            print(str(exc.code), file=sys.stderr)
            return 1
        finally:
            sys.argv = original_argv
    return 0


def _helper_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin-root", required=True)
    parser.add_argument("--relative", required=True)
    parser.add_argument("helper_argv", nargs=argparse.REMAINDER)
    return parser


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin-root", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--number", required=True, type=int)
    parser.add_argument("--url", required=True)
    parser.add_argument("--base-oid", required=True)
    parser.add_argument("--head-oid", required=True)
    parser.add_argument("--terminal-state-sha256", required=True)
    parser.add_argument("--reviewer-login", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    values = sys.argv[1:] if argv is None else argv
    try:
        if values[:1] == ["run-helper"]:
            return _run_verified_helper(_helper_parser().parse_args(values[1:]))
        proof = verify_chain(_parser().parse_args(values))
    except (Exception, SystemExit) as exc:
        if isinstance(exc, KeyboardInterrupt):
            raise
        message = " ".join(str(exc).split())[:500] or "Athena chain verification failed"
        print(message, file=sys.stderr)
        return 1
    print(json.dumps(proof, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
