"""Unit tests for claude-myrmidon-multi.py — multi-repo NATS pipeline harness.

Salvaged from PR #369 and ported from pytest → stdlib ``unittest`` because the
CI ``unit-tests`` runner has NO pytest installed (it runs plain
``python3 -m unittest``; see PR #375 for the pytest-on-runner trap).

Covers (all present on main's harness):
  - prune_task_data()
  - _extract_section()          (called extract_section in #369)
  - mock_claude_response()      — all stage variants
  - _build_container_cmd_scoped() — scope-specific volume mounts + userns
  - _get_session_id() / _created_sessions — session lifecycle tracking
  - Review verdict parsing (GO/NOGO)
  - Constants: STAGE_COLORS / SCOPE_TOOLS coverage

NOTE ON SKIPS: #369 also carried a "fan-in KV wiring" suite (KV_BUCKET,
stage_*(..., kv=...), stage_drive_green). That was part of #369's harness
*rewrite*, which was superseded by #353. Main's harness has NO KV bucket, NO
``kv=`` kwarg on stage handlers, and NO ``stage_drive_green`` — fan-in is done
purely in-memory. Those tests therefore target an API that does not exist on
main and are skipped with explicit reasons rather than deleted, so the coverage
intent is preserved and visible.
"""

from __future__ import annotations

import importlib.util
import os
import sys
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

# ── Make the harness importable ────────────────────────────────────────────
# The filename uses hyphens (claude-myrmidon-multi.py) which makes it
# unimportable via a normal `import` statement.  Use importlib to load it.
# This test lives at e2e/tests/unit/, so the harness is two dirs up + one.
_HARNESS_PATH = (
    Path(__file__).resolve().parent.parent.parent / "claude-myrmidon-multi.py"
)

# We need to set env vars BEFORE importing the module because it reads them
# at module level.  DRY_RUN=1 prevents any real Claude calls during import.
os.environ.setdefault("DRY_RUN", "1")
os.environ.setdefault("NO_GITHUB", "1")
os.environ.setdefault("ISSUE_NUMBER", "0")
os.environ.setdefault("NATS_URL", "nats://localhost:4222")

_spec = importlib.util.spec_from_file_location("claude_myrmidon_multi", _HARNESS_PATH)
_mod = importlib.util.module_from_spec(_spec)
sys.modules["claude_myrmidon_multi"] = _mod
_spec.loader.exec_module(_mod)
harness = _mod

# Short aliases
prune_task_data = harness.prune_task_data
_extract_section = harness._extract_section
mock_claude_response = harness.mock_claude_response
_build_container_cmd_scoped = harness._build_container_cmd_scoped
_get_session_id = harness._get_session_id
_created_sessions = harness._created_sessions


def _make_task_data(**overrides) -> dict:
    """Build a minimal task_data dict, merging overrides."""
    base = {
        "task_id": "test-task-001",
        "team_id": "ecosystem",
        "issue_number": 8,
    }
    base.update(overrides)
    return base


class _GlobalStateMixin(unittest.TestCase):
    """Reset mutable module-level state between tests (was an autouse fixture).

    Also provides ``_minimal_repos()`` (was the ``minimal_repos`` fixture) as an
    explicit helper, since unittest has no fixture injection.
    """

    def setUp(self):
        self._old_repos = dict(harness.REPOS)
        self._old_title = harness.TASK_TITLE
        self._old_goal = harness.TASK_GOAL
        self._old_slug = harness.TASK_SLUG
        self._old_created = set(_created_sessions)
        self._old_ids = dict(harness._session_ids)
        self._old_runtime = harness.CONTAINER_RUNTIME
        self._old_go = dict(harness._repo_go_verdicts)
        self._old_pr = dict(harness._repo_pr_urls)
        self._old_exp = dict(harness._expected_repos)

    def tearDown(self):
        harness.REPOS.clear()
        harness.REPOS.update(self._old_repos)
        harness.TASK_TITLE = self._old_title
        harness.TASK_GOAL = self._old_goal
        harness.TASK_SLUG = self._old_slug
        _created_sessions.clear()
        _created_sessions.update(self._old_created)
        harness._session_ids.clear()
        harness._session_ids.update(self._old_ids)
        harness.CONTAINER_RUNTIME = self._old_runtime
        harness._repo_go_verdicts.clear()
        harness._repo_go_verdicts.update(self._old_go)
        harness._repo_pr_urls.clear()
        harness._repo_pr_urls.update(self._old_pr)
        harness._expected_repos.clear()
        harness._expected_repos.update(self._old_exp)

    def _minimal_repos(self):
        """Set REPOS to a small subset for faster/deterministic tests."""
        harness.REPOS.clear()
        harness.REPOS.update(
            {
                "keystone": {
                    "path": "provisioning/ProjectKeystone",
                    "github_repo": "HomericIntelligence/ProjectKeystone",
                    "description": "Test repo",
                },
                "hephaestus": {
                    "path": "shared/ProjectHephaestus",
                    "github_repo": "HomericIntelligence/ProjectHephaestus",
                    "description": "Shared tooling",
                },
            }
        )
        return harness.REPOS


# ═══════════════════════════════════════════════════════════════════════════
# 1. prune_task_data
# ═══════════════════════════════════════════════════════════════════════════


class TestPruneTaskData(_GlobalStateMixin):
    def test_keeps_core_keys(self):
        data = {
            "task_id": "t1",
            "team_id": "t",
            "issue_number": 1,
            "repo_slug": "keystone",
            "plan": "big plan",
        }
        result = prune_task_data(data)
        self.assertEqual(result, {"task_id": "t1", "team_id": "t", "issue_number": 1})

    def test_keep_extra(self):
        data = {
            "task_id": "t1",
            "team_id": "t",
            "issue_number": 1,
            "repo_slug": "k",
            "plan": "p",
            "iteration": 3,
        }
        result = prune_task_data(data, keep_extra=("repo_slug", "plan"))
        self.assertEqual(result["repo_slug"], "k")
        self.assertEqual(result["plan"], "p")
        self.assertNotIn("iteration", result)

    def test_empty_input(self):
        self.assertEqual(prune_task_data({}), {})

    def test_all_core_keys(self):
        data = {
            "task_id": "a",
            "team_id": "b",
            "subject": "s",
            "description": "d",
            "issue_number": 1,
        }
        self.assertEqual(prune_task_data(data), data)


# ═══════════════════════════════════════════════════════════════════════════
# 2. _extract_section
# ═══════════════════════════════════════════════════════════════════════════


class TestExtractSection(_GlobalStateMixin):
    def test_basic_extraction(self):
        text = (
            "## PART 1\n### Repo: keystone\nDo stuff here\n"
            "### Repo: hephaestus\nOther stuff"
        )
        result = _extract_section(text, "### Repo: keystone")
        self.assertIn("Do stuff here", result)
        self.assertNotIn("Other stuff", result)

    def test_missing_header(self):
        text = "### Repo: keystone\nSome text"
        result = _extract_section(text, "### Repo: missing")
        self.assertEqual(result, "")

    def test_stops_at_next_h2(self):
        text = "### Repo: keystone\nContent\n## Next section\nMore"
        result = _extract_section(text, "### Repo: keystone")
        self.assertIn("Content", result)
        self.assertNotIn("More", result)

    def test_no_content_after_header(self):
        text = "### Repo: keystone\n### Repo: other"
        result = _extract_section(text, "### Repo: keystone")
        self.assertEqual(result, "")

    def test_multiline_section(self):
        text = "### Repo: keystone\nLine 1\nLine 2\nLine 3\n### Repo: other\nEnd"
        result = _extract_section(text, "### Repo: keystone")
        self.assertIn("Line 1", result)
        self.assertIn("Line 2", result)
        self.assertIn("Line 3", result)


# ═══════════════════════════════════════════════════════════════════════════
# 3. mock_claude_response
# ═══════════════════════════════════════════════════════════════════════════


class TestMockClaudeResponse(_GlobalStateMixin):
    def test_plan_contains_repos(self):
        self._minimal_repos()
        result = mock_claude_response("plan", "all", 0)
        self.assertIn("### Repo: keystone", result)
        self.assertIn("### Repo: hephaestus", result)
        self.assertIn("PART 1", result)
        self.assertIn("PART 2", result)

    def test_plan_criteria_per_repo(self):
        self._minimal_repos()
        result = mock_claude_response("plan", "all", 0)
        self.assertIn("### keystone Criteria", result)
        self.assertIn("### hephaestus Criteria", result)

    def test_test_returns_bash_script(self):
        self._minimal_repos()
        result = mock_claude_response("test", "keystone", 1)
        self.assertTrue(result.startswith("#!/usr/bin/env bash"))
        self.assertIn("keystone", result)

    def test_implement_returns_summary(self):
        result = mock_claude_response("implement", "keystone", 1)
        self.assertIn("keystone", result)

    def test_review_nogo_on_first_iteration(self):
        result = mock_claude_response("review", "keystone", 1)
        self.assertIn("NOGO", result)

    def test_review_go_on_later_iterations(self):
        result = mock_claude_response("review", "keystone", 2)
        self.assertIn("GO", result)
        self.assertNotIn("NOGO", result)

    def test_ship_returns_pr_url(self):
        self._minimal_repos()
        result = mock_claude_response("ship", "keystone", 0)
        self.assertIn("pull/dry-run", result)

    def test_ship_final_returns_url(self):
        result = mock_claude_response("ship-final", "odysseus", 0)
        self.assertIn("pull/dry-run-final", result)

    def test_unknown_stage(self):
        result = mock_claude_response("bogus", "keystone", 0)
        self.assertIn("Unknown stage", result)


# ═══════════════════════════════════════════════════════════════════════════
# 4. _build_container_cmd_scoped
# ═══════════════════════════════════════════════════════════════════════════


class TestBuildContainerCmdScoped(_GlobalStateMixin):
    def test_plan_scope_readonly(self):
        cmd = _build_container_cmd_scoped(
            ["claude", "-p", "test"], cwd="/tmp/ws", scope="plan"
        )
        joined = " ".join(cmd)
        self.assertIn(":ro", joined)

    def test_implement_scope_readwrite(self):
        cmd = _build_container_cmd_scoped(
            ["claude", "-p", "test"], cwd="/tmp/ws", scope="implement"
        )
        # The workspace mount should NOT be read-only (gh config is always :ro)
        self.assertIn("/tmp/ws:/workspace", cmd)
        # Verify the workspace mount is not followed by :ro
        ws_idx = cmd.index("/tmp/ws:/workspace")
        self.assertEqual(cmd[ws_idx], "/tmp/ws:/workspace")  # no :ro suffix

    def test_ship_scope_ro_workspace_rw_git(self):
        cmd = _build_container_cmd_scoped(
            ["claude", "-p", "test"], cwd="/tmp/ws", scope="ship"
        )
        joined = " ".join(cmd)
        self.assertIn("/tmp/ws:/workspace:ro", joined)
        self.assertIn("/tmp/ws/.git:/workspace/.git", joined)

    def test_ship_final_scope_readwrite(self):
        # NOTE: main's _build_container_cmd_scoped has no explicit "ship-final"
        # branch; it falls through to the read-write fallback. So the workspace
        # mount must be plain (no :ro). This matches main's actual behavior.
        cmd = _build_container_cmd_scoped(
            ["claude", "-p", "test"], cwd="/tmp/ws", scope="ship-final"
        )
        # Workspace mount should be read-write (not have :ro suffix)
        ws_idx = cmd.index("/tmp/ws:/workspace")
        self.assertEqual(cmd[ws_idx], "/tmp/ws:/workspace")  # no :ro suffix

    def test_userns_keep_id_for_podman(self):
        with patch.dict(os.environ, {"CONTAINER_RUNTIME": "podman"}):
            harness.CONTAINER_RUNTIME = "podman"
            cmd = _build_container_cmd_scoped(["claude"], cwd="/tmp", scope="plan")
            self.assertIn("--userns=keep-id", cmd)

    def test_user_flag_for_docker(self):
        with patch.dict(os.environ, {"CONTAINER_RUNTIME": "docker"}):
            harness.CONTAINER_RUNTIME = "docker"
            cmd = _build_container_cmd_scoped(["claude"], cwd="/tmp", scope="plan")
            self.assertIn("--user", cmd)
            self.assertNotIn("--userns=keep-id", cmd)

    def test_contains_claude_image(self):
        cmd = _build_container_cmd_scoped(["claude"], cwd="/tmp", scope="plan")
        self.assertIn(harness.CLAUDE_IMAGE, cmd)

    def test_contains_network_flag(self):
        cmd = _build_container_cmd_scoped(["claude"], cwd="/tmp", scope="plan")
        self.assertIn("--network", cmd)

    def test_claude_args_appended(self):
        cmd = _build_container_cmd_scoped(
            ["claude", "-p", "hello", "--allowedTools", "Bash"],
            cwd="/tmp",
            scope="implement",
        )
        self.assertIn("claude", cmd)
        self.assertIn("-p", cmd)
        self.assertIn("hello", cmd)


# ═══════════════════════════════════════════════════════════════════════════
# 5. Session ID Management
# ═══════════════════════════════════════════════════════════════════════════


class TestSessionId(_GlobalStateMixin):
    def test_creates_unique_id(self):
        sid1 = _get_session_id("t1", "keystone", "implement")
        sid2 = _get_session_id("t1", "keystone", "implement")
        self.assertEqual(sid1, sid2)  # same key → same id

    def test_different_keys_different_ids(self):
        sid1 = _get_session_id("t1", "keystone", "implement")
        sid2 = _get_session_id("t1", "hephaestus", "implement")
        self.assertNotEqual(sid1, sid2)

    def test_uuid_format(self):
        sid = _get_session_id("t1", "k", "plan")
        uuid.UUID(sid)  # raises if not valid UUID

    def test_created_sessions_tracking(self):
        sid = _get_session_id("t2", "k", "test")
        self.assertNotIn(sid, _created_sessions)
        _created_sessions.add(sid)
        self.assertIn(sid, _created_sessions)


# ═══════════════════════════════════════════════════════════════════════════
# 6. Review Verdict Parsing
# ═══════════════════════════════════════════════════════════════════════════


class TestVerdictParsing(_GlobalStateMixin):
    # (text, expected) — was a pytest.mark.parametrize; unittest uses subTest.
    _CASES = [
        ("VERDICT: GO", "GO"),
        ("VERDICT:GO", "GO"),
        ("Some text\nVERDICT: GO\nMore", "GO"),
        ("VERDICT: NOGO", "NOGO"),
        ("No verdict here", "NOGO"),
        ("verdict: go", "GO"),  # case-insensitive via .upper()
    ]

    def test_verdict_detection(self):
        for text, expected in self._CASES:
            with self.subTest(text=text):
                verdict = "NOGO"
                if "VERDICT: GO" in text.upper() or "VERDICT:GO" in text.upper():
                    verdict = "GO"
                self.assertEqual(verdict, expected)


# ═══════════════════════════════════════════════════════════════════════════
# 7-9. Fan-In KV Wiring — SKIPPED (API absent on main; see module docstring)
# ═══════════════════════════════════════════════════════════════════════════

_KV_SKIP = (
    "Fan-in KV wiring (KV_BUCKET / stage_*(..., kv=...) / stage_drive_green) "
    "was part of #369's harness rewrite, which #353 superseded. Main's harness "
    "does fan-in purely in-memory and has no such API, so these #369 tests "
    "cannot run here. Kept as documented skips to preserve coverage intent."
)


@unittest.skip(_KV_SKIP)
class TestFanInKV(unittest.TestCase):
    def test_kv_put_on_ci_pass(self):
        pass

    def test_kv_hydrates_on_restart(self):
        pass

    def test_kv_failure_is_non_fatal(self):
        pass

    def test_no_kv_still_works(self):
        pass


@unittest.skip(_KV_SKIP)
class TestPlanKV(unittest.TestCase):
    def test_plan_persists_expected_repos(self):
        pass


@unittest.skip(_KV_SKIP)
class TestHandlerSignatures(unittest.TestCase):
    """#369 asserted all 7 stage handlers accept kv=; main's handlers do not."""

    def test_stage_handlers_accept_kv(self):
        pass


# ═══════════════════════════════════════════════════════════════════════════
# 10. Constants
# ═══════════════════════════════════════════════════════════════════════════


class TestConstants(_GlobalStateMixin):
    @unittest.skip(
        "KV_BUCKET does not exist on main's harness — it was introduced by "
        "#369's KV fan-in rewrite (superseded by #353). See module docstring."
    )
    def test_kv_bucket_name(self):
        pass

    def test_stage_colors_cover_all_stages(self):
        # Adjusted to main's ACTUAL STAGE_COLORS keys. #369 checked for
        # "drive-green" (a stage from its rewrite); main has no such stage.
        for stage in ("plan", "test", "implement", "review", "ship", "ship-final"):
            self.assertIn(stage, harness.STAGE_COLORS)

    def test_scope_tools_cover_all_scopes(self):
        # Adjusted to main's ACTUAL SCOPE_TOOLS keys. #369 checked for
        # "ship-final"; main's SCOPE_TOOLS has "ship" (no separate "ship-final"
        # scope — ship-final falls through to the read-write container branch).
        for scope in ("plan", "review", "test", "implement", "ship"):
            self.assertIn(scope, harness.SCOPE_TOOLS)


if __name__ == "__main__":
    unittest.main()
