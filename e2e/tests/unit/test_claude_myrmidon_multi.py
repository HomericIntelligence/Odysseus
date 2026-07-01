"""Unit tests for claude-myrmidon-multi.py — multi-repo NATS pipeline harness.

Covers:
  - prune_task_data()
  - _extract_section()
  - mock_claude_response() — all stage variants
  - _build_container_cmd_scoped() — scope-specific volume mounts + userns
  - _get_session_id() / _created_sessions — session lifecycle tracking
  - Review verdict parsing (GO/NOGO)
  - Fan-in KV wiring — put/get/hydrate paths
  - Concurrent polling loop structure
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import uuid
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

# ── Make the harness importable ────────────────────────────────────────────
# The filename uses hyphens (claude-myrmidon-multi.py) which makes it
# unimportable via a normal `import` statement.  Use importlib to load it.
import importlib.util

_HARNESS_PATH = Path(__file__).resolve().parent.parent.parent / "claude-myrmidon-multi.py"

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
harness = _mod  # noqa: E402

# Short aliases
prune_task_data = harness.prune_task_data
_extract_section = harness._extract_section
mock_claude_response = harness.mock_claude_response
_build_container_cmd_scoped = harness._build_container_cmd_scoped
_get_session_id = harness._get_session_id
_created_sessions = harness._created_sessions
KV_BUCKET = harness.KV_BUCKET


# ── Fixtures ───────────────────────────────────────────────────────────────

@pytest.fixture(autouse=True)
def _reset_globals():
    """Reset mutable module-level state between tests."""
    old_repos = dict(harness.REPOS)
    old_title = harness.TASK_TITLE
    old_goal = harness.TASK_GOAL
    old_slug = harness.TASK_SLUG
    old_created = set(_created_sessions)
    old_ids = dict(harness._session_ids)
    old_runtime = harness.CONTAINER_RUNTIME
    old_go = dict(harness._repo_go_verdicts)
    old_pr = dict(harness._repo_pr_urls)
    old_exp = dict(harness._expected_repos)
    yield
    harness.REPOS.clear()
    harness.REPOS.update(old_repos)
    harness.TASK_TITLE = old_title
    harness.TASK_GOAL = old_goal
    harness.TASK_SLUG = old_slug
    _created_sessions.clear()
    _created_sessions.update(old_created)
    harness._session_ids.clear()
    harness._session_ids.update(old_ids)
    harness.CONTAINER_RUNTIME = old_runtime
    harness._repo_go_verdicts.clear()
    harness._repo_go_verdicts.update(old_go)
    harness._repo_pr_urls.clear()
    harness._repo_pr_urls.update(old_pr)
    harness._expected_repos.clear()
    harness._expected_repos.update(old_exp)


@pytest.fixture
def minimal_repos():
    """Set REPOS to a small subset for faster tests."""
    harness.REPOS.clear()
    harness.REPOS.update({
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
    })
    return harness.REPOS


@pytest.fixture
def mock_js():
    """AsyncMock for JetStream context."""
    js = AsyncMock()
    ack = MagicMock()
    ack.seq = 42
    js.publish = AsyncMock(return_value=ack)
    return js


@pytest.fixture
def mock_kv():
    """AsyncMock for NATS KV bucket."""
    kv = AsyncMock()

    # Simulate a simple in-memory KV store
    _store: dict[str, bytes] = {}

    async def _put(key, value):
        _store[key] = value
        return 1  # revision

    async def _get(key):
        if key in _store:
            entry = MagicMock()
            entry.value = _store[key]
            entry.key = key
            return entry
        return None

    kv.put = AsyncMock(side_effect=_put)
    kv.get = AsyncMock(side_effect=_get)
    return kv


def _make_task_data(**overrides) -> dict:
    """Build a minimal task_data dict, merging overrides."""
    base = {
        "task_id": "test-task-001",
        "team_id": "ecosystem",
        "issue_number": 8,
    }
    base.update(overrides)
    return base


# ═══════════════════════════════════════════════════════════════════════════
# 1. prune_task_data
# ═══════════════════════════════════════════════════════════════════════════

class TestPruneTaskData:
    def test_keeps_core_keys(self):
        data = {"task_id": "t1", "team_id": "t", "issue_number": 1,
                "repo_slug": "keystone", "plan": "big plan"}
        result = prune_task_data(data)
        assert result == {"task_id": "t1", "team_id": "t", "issue_number": 1}

    def test_keep_extra(self):
        data = {"task_id": "t1", "team_id": "t", "issue_number": 1,
                "repo_slug": "k", "plan": "p", "iteration": 3}
        result = prune_task_data(data, keep_extra=("repo_slug", "plan"))
        assert result["repo_slug"] == "k"
        assert result["plan"] == "p"
        assert "iteration" not in result

    def test_empty_input(self):
        assert prune_task_data({}) == {}

    def test_all_core_keys(self):
        data = {"task_id": "a", "team_id": "b", "subject": "s",
                "description": "d", "issue_number": 1}
        assert prune_task_data(data) == data


# ═══════════════════════════════════════════════════════════════════════════
# 2. _extract_section
# ═══════════════════════════════════════════════════════════════════════════

class TestExtractSection:
    def test_basic_extraction(self):
        text = "## PART 1\n### Repo: keystone\nDo stuff here\n### Repo: hephaestus\nOther stuff"
        result = _extract_section(text, "### Repo: keystone")
        assert "Do stuff here" in result
        assert "Other stuff" not in result

    def test_missing_header(self):
        text = "### Repo: keystone\nSome text"
        result = _extract_section(text, "### Repo: missing")
        assert result == ""

    def test_stops_at_next_h2(self):
        text = "### Repo: keystone\nContent\n## Next section\nMore"
        result = _extract_section(text, "### Repo: keystone")
        assert "Content" in result
        assert "More" not in result

    def test_no_content_after_header(self):
        text = "### Repo: keystone\n### Repo: other"
        result = _extract_section(text, "### Repo: keystone")
        assert result == ""

    def test_multiline_section(self):
        text = "### Repo: keystone\nLine 1\nLine 2\nLine 3\n### Repo: other\nEnd"
        result = _extract_section(text, "### Repo: keystone")
        assert "Line 1" in result
        assert "Line 2" in result
        assert "Line 3" in result


# ═══════════════════════════════════════════════════════════════════════════
# 3. mock_claude_response
# ═══════════════════════════════════════════════════════════════════════════

class TestMockClaudeResponse:
    def test_plan_contains_repos(self, minimal_repos):
        result = mock_claude_response("plan", "all", 0)
        assert "### Repo: keystone" in result
        assert "### Repo: hephaestus" in result
        assert "PART 1" in result
        assert "PART 2" in result

    def test_plan_criteria_per_repo(self, minimal_repos):
        result = mock_claude_response("plan", "all", 0)
        assert "### keystone Criteria" in result
        assert "### hephaestus Criteria" in result

    def test_test_returns_bash_script(self, minimal_repos):
        result = mock_claude_response("test", "keystone", 1)
        assert result.startswith("#!/usr/bin/env bash")
        assert "keystone" in result

    def test_implement_returns_summary(self):
        result = mock_claude_response("implement", "keystone", 1)
        assert "keystone" in result

    def test_review_nogo_on_first_iteration(self):
        result = mock_claude_response("review", "keystone", 1)
        assert "NOGO" in result

    def test_review_go_on_later_iterations(self):
        result = mock_claude_response("review", "keystone", 2)
        assert "GO" in result
        assert "NOGO" not in result

    def test_ship_returns_pr_url(self, minimal_repos):
        result = mock_claude_response("ship", "keystone", 0)
        assert "pull/dry-run" in result

    def test_ship_final_returns_url(self):
        result = mock_claude_response("ship-final", "odysseus", 0)
        assert "pull/dry-run-final" in result

    def test_unknown_stage(self):
        result = mock_claude_response("bogus", "keystone", 0)
        assert "Unknown stage" in result


# ═══════════════════════════════════════════════════════════════════════════
# 4. _build_container_cmd_scoped
# ═══════════════════════════════════════════════════════════════════════════

class TestBuildContainerCmdScoped:
    def test_plan_scope_readonly(self):
        cmd = _build_container_cmd_scoped(["claude", "-p", "test"], cwd="/tmp/ws", scope="plan")
        joined = " ".join(cmd)
        assert ":ro" in joined

    def test_implement_scope_readwrite(self):
        cmd = _build_container_cmd_scoped(["claude", "-p", "test"], cwd="/tmp/ws", scope="implement")
        # The workspace mount should NOT be read-only (gh config is always :ro)
        assert "/tmp/ws:/workspace" in cmd
        # Verify the workspace mount is not followed by :ro
        ws_idx = cmd.index("/tmp/ws:/workspace")
        assert cmd[ws_idx] == "/tmp/ws:/workspace"  # no :ro suffix

    def test_ship_scope_ro_workspace_rw_git(self):
        cmd = _build_container_cmd_scoped(["claude", "-p", "test"], cwd="/tmp/ws", scope="ship")
        joined = " ".join(cmd)
        assert "/tmp/ws:/workspace:ro" in joined
        assert "/tmp/ws/.git:/workspace/.git" in joined

    def test_ship_final_scope_readwrite(self):
        cmd = _build_container_cmd_scoped(["claude", "-p", "test"], cwd="/tmp/ws", scope="ship-final")
        # Workspace mount should be read-write (not have :ro suffix)
        ws_idx = cmd.index("/tmp/ws:/workspace")
        assert cmd[ws_idx] == "/tmp/ws:/workspace"  # no :ro suffix

    def test_userns_keep_id_for_podman(self):
        with patch.dict(os.environ, {"CONTAINER_RUNTIME": "podman"}):
            harness.CONTAINER_RUNTIME = "podman"
            cmd = _build_container_cmd_scoped(["claude"], cwd="/tmp", scope="plan")
            assert "--userns=keep-id" in cmd
            harness.CONTAINER_RUNTIME = os.environ.get("CONTAINER_RUNTIME", "podman")

    def test_user_flag_for_docker(self):
        with patch.dict(os.environ, {"CONTAINER_RUNTIME": "docker"}):
            harness.CONTAINER_RUNTIME = "docker"
            cmd = _build_container_cmd_scoped(["claude"], cwd="/tmp", scope="plan")
            assert "--user" in cmd
            assert "--userns=keep-id" not in cmd
            harness.CONTAINER_RUNTIME = os.environ.get("CONTAINER_RUNTIME", "podman")

    def test_contains_claude_image(self):
        cmd = _build_container_cmd_scoped(["claude"], cwd="/tmp", scope="plan")
        assert harness.CLAUDE_IMAGE in cmd

    def test_contains_network_flag(self):
        cmd = _build_container_cmd_scoped(["claude"], cwd="/tmp", scope="plan")
        assert "--network" in cmd

    def test_claude_args_appended(self):
        cmd = _build_container_cmd_scoped(["claude", "-p", "hello", "--allowedTools", "Bash"],
                                           cwd="/tmp", scope="implement")
        assert "claude" in cmd
        assert "-p" in cmd
        assert "hello" in cmd


# ═══════════════════════════════════════════════════════════════════════════
# 5. Session ID Management
# ═══════════════════════════════════════════════════════════════════════════

class TestSessionId:
    def test_creates_unique_id(self):
        sid1 = _get_session_id("t1", "keystone", "implement")
        sid2 = _get_session_id("t1", "keystone", "implement")
        assert sid1 == sid2  # same key → same id

    def test_different_keys_different_ids(self):
        sid1 = _get_session_id("t1", "keystone", "implement")
        sid2 = _get_session_id("t1", "hephaestus", "implement")
        assert sid1 != sid2

    def test_uuid_format(self):
        sid = _get_session_id("t1", "k", "plan")
        uuid.UUID(sid)  # raises if not valid UUID

    def test_created_sessions_tracking(self):
        sid = _get_session_id("t2", "k", "test")
        assert sid not in _created_sessions
        _created_sessions.add(sid)
        assert sid in _created_sessions


# ═══════════════════════════════════════════════════════════════════════════
# 6. Review Verdict Parsing
# ═══════════════════════════════════════════════════════════════════════════

class TestVerdictParsing:
    @pytest.mark.parametrize("text,expected", [
        ("VERDICT: GO", "GO"),
        ("VERDICT:GO", "GO"),
        ("Some text\nVERDICT: GO\nMore", "GO"),
        ("VERDICT: NOGO", "NOGO"),
        ("No verdict here", "NOGO"),
        ("verdict: go", "GO"),  # case-insensitive via .upper()
    ])
    def test_verdict_detection(self, text, expected):
        verdict = "NOGO"
        if "VERDICT: GO" in text.upper() or "VERDICT:GO" in text.upper():
            verdict = "GO"
        assert verdict == expected


# ═══════════════════════════════════════════════════════════════════════════
# 7. Fan-In KV Wiring — stage_drive_green
# ═══════════════════════════════════════════════════════════════════════════

class TestFanInKV:
    @pytest.mark.asyncio
    async def test_kv_put_on_ci_pass(self, mock_js, mock_kv, minimal_repos):
        """When CI passes and kv is provided, verdict and PR URL are persisted."""
        harness._expected_repos["t1"] = {"keystone", "hephaestus"}

        task_data = _make_task_data(
            task_id="t1", repo_slug="keystone",
            repo_github="HomericIntelligence/ProjectKeystone",
            pr_url="https://github.com/HomericIntelligence/ProjectKeystone/pull/42",
        )

        await harness.stage_drive_green(task_data, mock_js, kv=mock_kv)

        # Verify KV.put was called for verdict
        mock_kv.put.assert_any_call("fan-in.t1.verdicts.keystone", b"GO")
        # Verify KV.put was called for PR URL
        mock_kv.put.assert_any_call(
            "fan-in.t1.pr-urls.keystone",
            b"https://github.com/HomericIntelligence/ProjectKeystone/pull/42",
        )

    @pytest.mark.asyncio
    async def test_kv_hydrates_on_restart(self, mock_js, mock_kv, minimal_repos):
        """When in-memory state is incomplete, drive-green hydrates from KV."""
        harness._expected_repos["t2"] = {"keystone", "hephaestus"}
        # Only hephaestus in memory — missing keystone
        harness._repo_go_verdicts["t2"] = {"hephaestus"}

        # Pre-populate KV with keystone's verdict (simulates restart recovery)
        await mock_kv.put("fan-in.t2.verdicts.keystone", b"GO")
        await mock_kv.put("fan-in.t2.pr-urls.keystone", b"https://example.com/pull/1")

        task_data = _make_task_data(
            task_id="t2", repo_slug="keystone",
            repo_github="HomericIntelligence/ProjectKeystone",
            pr_url="https://example.com/pull/1",
        )

        await harness.stage_drive_green(task_data, mock_js, kv=mock_kv)

        # After hydration, both repos should be in the verdicts set
        assert "keystone" in harness._repo_go_verdicts["t2"]
        assert "hephaestus" in harness._repo_go_verdicts["t2"]

    @pytest.mark.asyncio
    async def test_kv_failure_is_non_fatal(self, mock_js, minimal_repos):
        """KV failures should not crash the handler."""
        harness._expected_repos["t3"] = {"keystone"}

        failing_kv = AsyncMock()
        failing_kv.put = AsyncMock(side_effect=Exception("KV connection lost"))
        failing_kv.get = AsyncMock(side_effect=Exception("KV connection lost"))

        task_data = _make_task_data(
            task_id="t3", repo_slug="keystone",
            repo_github="HomericIntelligence/ProjectKeystone",
            pr_url="https://example.com/pull/99",
        )

        # Should not raise
        result = await harness.stage_drive_green(task_data, mock_js, kv=failing_kv)
        assert result is not None

    @pytest.mark.asyncio
    async def test_no_kv_still_works(self, mock_js, minimal_repos):
        """Without kv=None (default), in-memory tracking still works."""
        harness._expected_repos["t4"] = {"keystone"}

        task_data = _make_task_data(
            task_id="t4", repo_slug="keystone",
            repo_github="HomericIntelligence/ProjectKeystone",
            pr_url="https://example.com/pull/50",
        )

        await harness.stage_drive_green(task_data, mock_js, kv=None)
        assert "keystone" in harness._repo_go_verdicts["t4"]


# ═══════════════════════════════════════════════════════════════════════════
# 8. Fan-In KV Wiring — stage_plan
# ═══════════════════════════════════════════════════════════════════════════

class TestPlanKV:
    @pytest.mark.asyncio
    async def test_plan_persists_expected_repos(self, mock_js, mock_kv, minimal_repos):
        """Plan stage persists expected repos to KV when available."""
        harness.TASK_TITLE = "Test Issue"
        harness.TASK_GOAL = "Do something"
        harness.TASK_SLUG = "test-issue"

        # Mock invoke_claude to return a plan that includes both repos
        plan_text = (
            "## PART 1 — Plan\n"
            "### Repo: keystone\nAdd recipes\n"
            "### Repo: hephaestus\nUpdate helpers\n"
            "## PART 2 — Acceptance Criteria\n"
            "### keystone Criteria\n1. Done\n"
            "### hephaestus Criteria\n1. Done\n"
        )

        task_data = _make_task_data()

        with patch("claude_myrmidon_multi.invoke_claude", return_value=plan_text), \
             patch("claude_myrmidon_multi.post_issue_comment"):
            await harness.stage_plan(task_data, mock_js, kv=mock_kv)

        # Verify KV.put was called for expected repos
        mock_kv.put.assert_any_call(
            "fan-in.test-task-001.expected",
            b"hephaestus,keystone",  # sorted
        )


# ═══════════════════════════════════════════════════════════════════════════
# 9. Stage Handler Signatures Accept kv kwarg
# ═══════════════════════════════════════════════════════════════════════════

class TestHandlerSignatures:
    """Verify all 7 stage handlers accept the kv= keyword argument."""

    @pytest.mark.asyncio
    async def test_stage_plan_accepts_kv(self, mock_js):
        with patch("claude_myrmidon_multi.invoke_claude", return_value="No repos"), \
             patch("claude_myrmidon_multi.post_issue_comment"):
            result = await harness.stage_plan(_make_task_data(), mock_js, kv=None)
        assert result is not None

    @pytest.mark.asyncio
    async def test_stage_test_accepts_kv(self, mock_js):
        with patch("claude_myrmidon_multi.invoke_claude", return_value="#!/bin/bash\necho ok"), \
             patch("claude_myrmidon_multi.post_issue_comment"):
            result = await harness.stage_test(
                _make_task_data(repo_slug="k", repo_plan="", repo_criteria=""),
                mock_js, kv=None,
            )
        assert result is not None

    @pytest.mark.asyncio
    async def test_stage_implement_accepts_kv(self, mock_js):
        with patch("claude_myrmidon_multi.invoke_claude", return_value="Done"), \
             patch("claude_myrmidon_multi.post_issue_comment"):
            result = await harness.stage_implement(
                _make_task_data(repo_slug="k", repo_plan="", test_script=""),
                mock_js, kv=None,
            )
        assert result is not None

    @pytest.mark.asyncio
    async def test_stage_review_accepts_kv(self, mock_js):
        with patch("claude_myrmidon_multi.invoke_claude", return_value="VERDICT: GO"), \
             patch("claude_myrmidon_multi.post_issue_comment"):
            result = await harness.stage_review(
                _make_task_data(repo_slug="k", repo_criteria="", test_script=""),
                mock_js, kv=None,
            )
        assert result is not None

    @pytest.mark.asyncio
    async def test_stage_drive_green_accepts_kv(self, mock_js):
        harness._expected_repos["t-dg"] = {"k"}
        result = await harness.stage_drive_green(
            _make_task_data(task_id="t-dg", repo_slug="k",
                           repo_github="org/repo", pr_url=""),
            mock_js, kv=None,
        )
        assert result is not None

    @pytest.mark.asyncio
    async def test_stage_ship_repo_accepts_kv(self, mock_js):
        with patch("claude_myrmidon_multi.invoke_claude", return_value="PR url"), \
             patch("claude_myrmidon_multi.post_issue_comment"):
            result = await harness.stage_ship_repo(
                _make_task_data(repo_slug="k", repo_github="org/repo", repo_path="p"),
                mock_js, kv=None,
            )
        assert result is not None

    @pytest.mark.asyncio
    async def test_stage_ship_odysseus_accepts_kv(self, mock_js):
        with patch("claude_myrmidon_multi.invoke_claude", return_value="PR url"), \
             patch("claude_myrmidon_multi.post_issue_comment"):
            result = await harness.stage_ship_odysseus(
                _make_task_data(repo_pr_urls={"k": "https://example.com/pull/1"}),
                mock_js, kv=None,
            )
        assert result is not None


# ═══════════════════════════════════════════════════════════════════════════
# 10. ANSI / Constants
# ═══════════════════════════════════════════════════════════════════════════

class TestConstants:
    def test_kv_bucket_name(self):
        assert KV_BUCKET == "odysseus-fan-in"

    def test_stage_colors_cover_all_stages(self):
        for stage in ("plan", "test", "implement", "review", "drive-green", "ship", "ship-final"):
            assert stage in harness.STAGE_COLORS

    def test_scope_tools_cover_all_scopes(self):
        for scope in ("plan", "review", "test", "implement", "ship", "ship-final"):
            assert scope in harness.SCOPE_TOOLS
