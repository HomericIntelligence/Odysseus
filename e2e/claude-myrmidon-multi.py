#!/usr/bin/env python3
"""Claude Code Myrmidon — Multi-repo NATS pipeline for cross-repo issue resolution.

Extends the single-repo claude-myrmidon.py pattern to handle multiple repositories
in parallel, with security-scoped container volume mappings per stage.

Architecture:
  1 PLANNER       → reads all repos, produces unified plan with per-repo sections
  4 LOOP WORKERS  → parallel [test → implement → review] loops (max 5 iterations each)
  4 REPO SHIPPERS → each creates a PR in its submodule's upstream repo
  1 ODYSSEUS SHIP → final PR: justfile delegation recipes + submodule pin updates (Closes #N)

Reuses:
  - hephaestus.automation: Planner, WorktreeManager, pr_manager, github_api, prompts
  - claude-myrmidon.py patterns: NATS transport, container cmd builder, stage routing

Usage:
    NATS_URL=nats://localhost:4222 python3 e2e/claude-myrmidon-multi.py

Environment:
    NATS_URL        NATS server URL (default: nats://localhost:4222)
    REPO            GitHub repo (default: HomericIntelligence/Odysseus)
    WORKING_DIR     Working directory for claude invocations (default: cwd)
    MAX_ITERATIONS  Max review loop iterations per repo (default: 5)
    DRY_RUN         Set to 1 for canned responses (no Claude API calls)
    NO_GITHUB       Set to 1 to skip GitHub issue comments
    ISSUE_NUMBER    GitHub issue number to solve (default: 8)
"""

from __future__ import annotations

import asyncio
import json
import os
import resource
import signal
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

# ─── Ensure hephaestus is importable from Odysseus root ────────────────────
_HEPHAESTUS_ROOT = Path(__file__).resolve().parent.parent / "shared" / "ProjectHephaestus"
if str(_HEPHAESTUS_ROOT) not in sys.path:
    sys.path.insert(0, str(_HEPHAESTUS_ROOT))

# ─── Configuration ──────────────────────────────────────────────────────────
NATS_URL = os.environ.get("NATS_URL", "nats://localhost:4222")
REPO = os.environ.get("REPO", "HomericIntelligence/Odysseus")
WORKING_DIR = os.environ.get("WORKING_DIR", os.getcwd())
MAX_ITERATIONS = int(os.environ.get("MAX_ITERATIONS", "5"))
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"
NO_GITHUB = os.environ.get("NO_GITHUB", "0") == "1"
ISSUE_NUMBER = int(os.environ.get("ISSUE_NUMBER", "8"))

# Cap concurrent HEAVY Claude agent invocations (each does clone -> pixi install
# (a ~0.5-1 GB conda/pypi SAT solve) -> C++ build). On the 16 GB / 8-core `hermes`
# WSL host, fanning all 16 repos out at once exhausted RAM + 16 GB swap and hung
# the VM (see CLAUDE.md "Resource limits & concurrency"). Default 3 keeps peak at
# ~3 x 3 GB with headroom; override with HERMES_MAX_CONCURRENT_AGENTS.
MAX_CONCURRENT_HEAVY = int(os.environ.get("HERMES_MAX_CONCURRENT_AGENTS", "3"))

# Container configuration
CLAUDE_IMAGE = os.environ.get("CLAUDE_IMAGE", "achaean-claude:latest")
CONTAINER_WORKSPACE = "/workspace"
CONTAINER_RUNTIME = os.environ.get("CONTAINER_RUNTIME", "podman")

STREAM_NAME = "homeric-myrmidon"
LOG_SUBJECT = "hi.logs.myrmidon.claude-multi"

# ─── Issue-driven task goal ─────────────────────────────────────────────────
# The harness is issue-generic: the work to perform is defined entirely by the
# GitHub issue body, not hardcoded per-task. These are populated once at startup
# from `gh issue view`. A short slug derived from the title is used for branch
# names, commit scopes, and test-script filenames so nothing is task-specific.
TASK_TITLE = ""
TASK_GOAL = ""
TASK_SLUG = "issue"


def _load_task_goal() -> None:
    """Fetch the issue title + body once; derive TASK_TITLE/TASK_GOAL/TASK_SLUG."""
    global TASK_TITLE, TASK_GOAL, TASK_SLUG
    try:
        out = subprocess.run(
            ["gh", "issue", "view", str(ISSUE_NUMBER), "--repo", REPO,
             "--json", "title,body"],
            capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=30,
        )
        data = json.loads(out.stdout)
        TASK_TITLE = data.get("title", "") or f"Issue #{ISSUE_NUMBER}"
        TASK_GOAL = data.get("body", "") or ""
    except Exception as e:
        TASK_TITLE = f"Issue #{ISSUE_NUMBER}"
        TASK_GOAL = ""
        print(f"WARN: could not load issue #{ISSUE_NUMBER}: {e}", file=sys.stderr)
    # Branch/commit/file-safe slug from the title (first ~4 words).
    import re as _re
    words = _re.sub(r"[^a-z0-9 ]", "", TASK_TITLE.lower()).split()
    TASK_SLUG = "-".join(words[:4]) or f"issue-{ISSUE_NUMBER}"

# ─── Repo Registry ──────────────────────────────────────────────────────────
REPOS: dict[str, dict] = {
    # Infrastructure
    "achaean-fleet": {
        "path": "infrastructure/AchaeanFleet",
        "github_repo": "HomericIntelligence/AchaeanFleet",
        "description": "OCI image build recipes (build-vessel)",
    },
    "argus": {
        "path": "infrastructure/ProjectArgus",
        "github_repo": "HomericIntelligence/ProjectArgus",
        "description": "Observability stack (Prometheus/Grafana)",
    },
    "hermes": {
        "path": "infrastructure/ProjectHermes",
        "github_repo": "HomericIntelligence/ProjectHermes",
        "description": "NATS event bridge (FastAPI webhook → JetStream)",
    },
    # Control plane
    "agamemnon": {
        "path": "control/ProjectAgamemnon",
        "github_repo": "HomericIntelligence/ProjectAgamemnon",
        "description": "Orchestration REST API (C++20, port 8080)",
    },
    "nestor": {
        "path": "control/ProjectNestor",
        "github_repo": "HomericIntelligence/ProjectNestor",
        "description": "Research + ideation service (C++20, port 8081)",
    },
    # Provisioning
    "telemachy": {
        "path": "provisioning/ProjectTelemachy",
        "github_repo": "HomericIntelligence/ProjectTelemachy",
        "description": "Declarative workflow runner (Telemachy)",
    },
    "keystone": {
        "path": "provisioning/ProjectKeystone",
        "github_repo": "HomericIntelligence/ProjectKeystone",
        "description": "C++20 MessageBus + ThreadPool library (HMAS transport)",
    },
    "myrmidons": {
        "path": "provisioning/Myrmidons",
        "github_repo": "HomericIntelligence/Myrmidons",
        "description": "Declarative agent fleet manifests (YAML → Agamemnon)",
    },
    # CI/CD
    "proteus": {
        "path": "ci-cd/ProjectProteus",
        "github_repo": "HomericIntelligence/ProjectProteus",
        "description": "CI/CD pipeline trigger recipes",
    },
    # Research
    "odyssey": {
        "path": "research/ProjectOdyssey",
        "github_repo": "HomericIntelligence/ProjectOdyssey",
        "description": "Mojo ML training framework (standalone, no mesh integration)",
    },
    "scylla": {
        "path": "research/ProjectScylla",
        "github_repo": "HomericIntelligence/ProjectScylla",
        "description": "Agent evaluation and benchmarking framework",
    },
    # Testing
    "charybdis": {
        "path": "testing/ProjectCharybdis",
        "github_repo": "HomericIntelligence/ProjectCharybdis",
        "description": "Chaos and resilience testing via Agamemnon /v1/chaos/*",
    },
    # Shared
    "mnemosyne": {
        "path": "shared/ProjectMnemosyne",
        "github_repo": "HomericIntelligence/ProjectMnemosyne",
        "description": "Skills marketplace and knowledge registry",
    },
    "hephaestus": {
        "path": "shared/ProjectHephaestus",
        "github_repo": "HomericIntelligence/ProjectHephaestus",
        "description": "Shared tooling, linting, and CI helpers",
    },
}

# Optional repo scoping for piloting/staged rollout: REPOS_FILTER="keystone" or
# "keystone,scylla" limits the run to those slugs (consumers, fan-out, fan-in all
# follow the filtered set). Empty = all repos.
_repos_filter = [s.strip() for s in os.environ.get("REPOS_FILTER", "").split(",") if s.strip()]
if _repos_filter:
    REPOS = {k: v for k, v in REPOS.items() if k in _repos_filter}

# ─── ANSI Colors ────────────────────────────────────────────────────────────
BOLD = "\033[1m"
DIM = "\033[2m"
GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
RED = "\033[0;31m"
CYAN = "\033[0;36m"
BLUE = "\033[0;34m"
MAGENTA = "\033[0;35m"
NC = "\033[0m"

STAGE_COLORS = {
    "plan": CYAN,
    "test": YELLOW,
    "implement": GREEN,
    "review": MAGENTA,
    "ship": BLUE,
    "ship-final": BLUE,
}


def now_iso():
    return datetime.now(timezone.utc).strftime("%FT%TZ")


def log(stage, msg):
    color = STAGE_COLORS.get(stage, NC)
    ts = datetime.now(timezone.utc).strftime("%H:%M:%S")
    print(f"{DIM}{ts}{NC} {color}{BOLD}[{stage.upper()}]{NC} {msg}", flush=True)


def log_memory(stage: str):
    rss_kb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    log(stage, f"Memory: {rss_kb / 1024:.1f} MB RSS")


# ─── Core Keys (for message pruning) ───────────────────────────────────────
_CORE_KEYS = {"task_id", "team_id", "subject", "description", "issue_number"}


def prune_task_data(task_data: dict, keep_extra: tuple = ()) -> dict:
    allowed = _CORE_KEYS | set(keep_extra)
    return {k: v for k, v in task_data.items() if k in allowed}


# ─── Session ID Management ─────────────────────────────────────────────────
_session_ids: dict[str, str] = {}
_created_sessions: set[str] = set()  # session ids that have actually been started


def _get_session_id(task_id: str, repo_slug: str, stage: str) -> str:
    key = f"{task_id}-{repo_slug}-{stage}"
    if key not in _session_ids:
        _session_ids[key] = str(uuid.uuid4())
    return _session_ids[key]


# ─── Security-Scoped Container Command Builder ─────────────────────────────

def _build_container_cmd_scoped(
    claude_args: list[str],
    cwd: str,
    scope: str,
    repo_subpath: str = "",
) -> list[str]:
    """Build a container run command with security-scoped volume mappings.

    Scopes:
        plan/review  — workspace read-only
        test/implement — workspace read-write
        ship — .git read-write, workspace read-only
    """
    home = os.path.expanduser("~")

    # Common mounts: claude session data + gh CLI config.
    # Issue #180: pass ANTHROPIC_API_KEY by name only (no `=value`) so podman
    # reads the value from this process's env and injects it into the container
    # without the value ever appearing on the command line (ps/proc/cmdline).
    # The image-baked npm `claude` still receives the key unchanged.
    if not os.environ.get("ANTHROPIC_API_KEY"):
        log("claude", f"{YELLOW}ANTHROPIC_API_KEY is unset — container auth may fail{NC}")
    common_mounts = [
        "-v", f"{home}/.claude:{home}/.claude",
        "-v", f"{home}/.config/gh:{home}/.config/gh:ro",
        "-e", "ANTHROPIC_API_KEY",  # name-only: value pulled from host env, not on cmdline
        "-e", f"HOME={home}",
    ]
    if os.path.exists(f"{home}/.claude.json"):
        common_mounts += ["-v", f"{home}/.claude.json:{home}/.claude.json"]

    if scope in ("plan", "review"):
        # Read-only workspace
        volume_mounts = ["-v", f"{cwd}:{CONTAINER_WORKSPACE}:ro"]
    elif scope in ("test", "implement"):
        # Read-write workspace
        volume_mounts = ["-v", f"{cwd}:{CONTAINER_WORKSPACE}"]
    elif scope == "ship":
        # Read-only workspace + read-write .git
        volume_mounts = [
            "-v", f"{cwd}:{CONTAINER_WORKSPACE}:ro",
            "-v", f"{cwd}/.git:{CONTAINER_WORKSPACE}/.git",
        ]
    else:
        # Fallback: read-write
        volume_mounts = ["-v", f"{cwd}:{CONTAINER_WORKSPACE}"]

    # Run as the invoking (non-root) user so the bind-mounted ~/.claude (owned by
    # the host user) is WRITABLE inside the container. Without this, rootless
    # podman maps the container's root to a high subuid that cannot write the
    # mounted config/session/lock files — claude then hangs silently on any
    # API/session operation (EACCES on ~/.claude/debug/*). keep-id maps the
    # container user 1:1 to the host uid/gid.
    userns = ["--userns=keep-id"] if CONTAINER_RUNTIME == "podman" else [
        "--user", f"{os.getuid()}:{os.getgid()}"
    ]

    cmd = [
        CONTAINER_RUNTIME, "run", "--rm",
        *userns,
        "--network", os.environ.get("CONTAINER_NETWORK", "odysseus_homeric-mesh"),
        *volume_mounts,
        *common_mounts,
        "-w", CONTAINER_WORKSPACE,
        CLAUDE_IMAGE,
    ]
    cmd.extend(claude_args)
    return cmd


# ─── Allowed Tools per Scope ───────────────────────────────────────────────

SCOPE_TOOLS = {
    "plan": "Read,Glob,Grep,Bash",
    "review": "Read,Glob,Grep,Bash",
    "test": "Bash,Read,Write,Edit,Glob,Grep",
    "implement": "Bash,Read,Write,Edit,Glob,Grep",
    "ship": "Bash",
}


# ─── Claude CLI Invocation ─────────────────────────────────────────────────

def invoke_claude(
    prompt: str,
    cwd: str = WORKING_DIR,
    scope: str = "implement",
    stage: str = "",
    iteration: int = 0,
    task_id: str = "",
    repo_slug: str = "",
) -> str:
    """Invoke Claude Code CLI inside a security-scoped container."""
    if DRY_RUN:
        log("claude", f"[DRY-RUN] Skipping claude -p ({len(prompt)} chars) scope={scope}")
        return mock_claude_response(stage, repo_slug, iteration)

    session_id = _get_session_id(task_id, repo_slug, stage) if task_id else ""
    # Resume only if THIS stage's session was actually created on a prior call.
    # The old `iteration > 0` test was wrong: every stage starts at iteration 1,
    # so the first test/implement/review/ship call tried to --resume a session
    # that was never created (each stage has its own session id), yielding empty
    # output and a spurious NOGO loop. Track created sessions explicitly.
    is_resume = bool(session_id) and session_id in _created_sessions

    claude_args = [
        "claude", "-p", prompt,
        "--permission-mode", "acceptEdits",
        "--allowedTools", SCOPE_TOOLS.get(scope, "Bash,Read,Write,Edit,Glob,Grep"),
    ]

    if is_resume:
        log("claude", f"Resuming session {session_id[:8]}... scope={scope} ({len(prompt)} chars)")
        claude_args.extend(["--resume", session_id])
    else:
        log("claude", f"Starting new session scope={scope} ({len(prompt)} chars)")
        if session_id:
            claude_args.extend(["--session-id", session_id])
            _created_sessions.add(session_id)

    cmd = _build_container_cmd_scoped(claude_args, cwd=cwd, scope=scope)

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=600,
        )
        output = result.stdout.strip()
        if result.returncode != 0:
            log("claude", f"{RED}Exit code {result.returncode}{NC}")
            if result.stderr:
                log("claude", f"stderr: {result.stderr[:500]}")
        if not output:
            log("claude", f"{YELLOW}Empty output — check stderr above{NC}")
            return "ERROR: Claude returned empty output"
        return output
    except subprocess.TimeoutExpired:
        log("claude", f"{RED}Timed out after 600s{NC}")
        return "ERROR: Claude invocation timed out after 10 minutes"
    except FileNotFoundError:
        log("claude", f"{RED}{CONTAINER_RUNTIME} not found in PATH{NC}")
        return f"ERROR: {CONTAINER_RUNTIME} not found"


# ─── Concurrency throttle for heavy invocations ────────────────────────────

# Lazily-created so the semaphore binds to the running event loop (constructing
# asyncio.Semaphore at import time has no loop to attach to).
_HEAVY_SEMAPHORE: "asyncio.Semaphore | None" = None


def _heavy_semaphore() -> "asyncio.Semaphore":
    global _HEAVY_SEMAPHORE
    if _HEAVY_SEMAPHORE is None:
        _HEAVY_SEMAPHORE = asyncio.Semaphore(MAX_CONCURRENT_HEAVY)
    return _HEAVY_SEMAPHORE


async def bounded_invoke_claude(*args, **kwargs) -> str:
    """Run a HEAVY ``invoke_claude`` under the global concurrency cap.

    Acquires ``MAX_CONCURRENT_HEAVY`` slots so at most N container agents run
    their clone -> pixi-solve -> build pipeline at once, and runs the blocking
    ``invoke_claude`` in a worker thread so the cap actually throttles
    concurrency instead of being defeated by the event loop serialising the
    synchronous subprocess call. Prevents the all-repos-at-once OOM that hung
    the `hermes` WSL host.
    """
    async with _heavy_semaphore():
        return await asyncio.to_thread(invoke_claude, *args, **kwargs)


# ─── Mock Responses for Dry-Run ────────────────────────────────────────────

def mock_claude_response(stage: str, repo_slug: str, iteration: int) -> str:
    if stage == "plan":
        sections = []
        for slug, info in REPOS.items():
            sections.append(f"""### Repo: {slug}
- Apply the issue's goal to `{info['path']}` ({info['description']}).""")
        criteria = []
        for slug in REPOS:
            criteria.append(f"""### {slug} Criteria
1. The repo satisfies its portion of the issue goal
2. Changes follow existing repo conventions""")
        return f"""## PART 1 — Plan
{chr(10).join(sections)}

## PART 2 — Acceptance Criteria
{chr(10).join(criteria)}"""

    elif stage == "test":
        return f"""#!/usr/bin/env bash
set -euo pipefail
echo "DRY-RUN: all checks pass for {repo_slug}"
exit 0"""

    elif stage == "implement":
        return f"[DRY-RUN] Implementation complete for {repo_slug}. Recipes added."

    elif stage == "review":
        if iteration <= 1:
            return f"""1. PASS: {repo_slug} change present
2. FAIL: a criterion not yet met

VERDICT: NOGO

Remaining concerns:
1. Address the outstanding acceptance criterion"""
        else:
            return f"""1. PASS: {repo_slug} change present
2. PASS: all criteria met

VERDICT: GO

All acceptance criteria pass."""

    elif stage == "ship":
        return f"[DRY-RUN] PR created for {repo_slug}\nhttps://github.com/{REPOS.get(repo_slug, {}).get('github_repo', REPO)}/pull/dry-run"

    elif stage == "ship-final":
        return f"[DRY-RUN] Final Odysseus PR created\nhttps://github.com/{REPO}/pull/dry-run-final"

    return f"[DRY-RUN] Unknown stage: {stage}"


# ─── GitHub Issue Comments ──────────────────────────────────────────────────

def post_issue_comment(issue_number: int, stage: str, iteration: int, content: str,
                       repo_slug: str = ""):
    if content.startswith("ERROR:") or not content.strip():
        return
    if NO_GITHUB:
        prefix = f"[{repo_slug}] " if repo_slug else ""
        log(stage, f"[NO_GITHUB] {prefix}Would post to issue #{issue_number} ({len(content)} chars)")
        return

    header = f"## Stage: {stage.upper()}"
    if repo_slug:
        header += f" [{repo_slug}]"
    if iteration > 0:
        header += f" (iteration {iteration})"

    body = f"{header}\n\n{content}\n\n---\n*Updated by claude-myrmidon-multi at {now_iso()}*"

    try:
        subprocess.run(
            ["gh", "issue", "comment", str(issue_number),
             "--repo", REPO, "--body", body],
            capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=30,
        )
        log(stage, f"Posted comment to issue #{issue_number}")
    except Exception as e:
        log(stage, f"{RED}Failed to post comment: {e}{NC}")


# ─── NATS Helpers ───────────────────────────────────────────────────────────

async def publish_json(js, subject: str, data: dict):
    payload = json.dumps(data).encode()
    log("nats", f"Publishing to {subject} ({len(payload)} bytes)")
    ack = await js.publish(subject, payload)
    log("nats", f"Published to {subject} (seq={ack.seq})")


async def publish_log(js, stage: str, message: str, task_id: str = "",
                      team_id: str = "", repo_slug: str = ""):
    await publish_json(js, LOG_SUBJECT, {
        "level": "info",
        "service": "claude-myrmidon-multi",
        "stage": stage,
        "repo": repo_slug,
        "message": message,
        "task_id": task_id,
        "team_id": team_id,
        "timestamp": now_iso(),
    })


# ─── Fan-In Coordination ───────────────────────────────────────────────────
_repo_go_verdicts: dict[str, set[str]] = {}   # task_id → set of repo slugs with GO
_repo_pr_urls: dict[str, dict[str, str]] = {}  # task_id → {repo_slug: pr_url}
_expected_repos: dict[str, set[str]] = {}      # task_id → set of repos that need work


# ─── Stage Handlers ────────────────────────────────────────────────────────

async def stage_plan(task_data: dict, js) -> dict:
    """Stage 1: Unified plan across all 4 repos."""
    task_id = task_data.get("task_id", "unknown")
    team_id = task_data.get("team_id", "unknown")
    issue_number = task_data.get("issue_number", ISSUE_NUMBER)

    log("plan", f"Planning multi-repo task for issue #{issue_number}")
    log_memory("plan")
    await publish_log(js, "plan", "Starting multi-repo plan", task_id, team_id)

    # Build repo context for the prompt
    repo_context = "\n".join(
        f"- **{slug}**: `{info['path']}` — {info['description']} (upstream: {info['github_repo']})"
        for slug, info in REPOS.items()
    )

    repo_headers = "\n".join(f"### Repo: {slug}\n(Per-repo plan for this repo.)" for slug in REPOS)
    criteria_headers = "\n".join(f"### {slug} Criteria\n1. (numbered criteria)" for slug in REPOS)

    prompt = f"""You are a planning agent for the HomericIntelligence ecosystem.

GitHub Issue: #{issue_number} on {REPO}
Title: {TASK_TITLE}

The issue defines the work to perform. Here is its full body — treat it as the
authoritative specification of WHAT to do:

<issue>
{TASK_GOAL}
</issue>

Instructions:
1. Re-read the issue if needed: `gh issue view {issue_number} --repo {REPO}`
2. For each repo below, read its directory to understand its current state as it
   relates to the issue's goal:

{repo_context}

3. Decompose the issue's goal into concrete, per-repo work. Only include a repo
   if the issue's goal actually requires changes there.

Produce a plan with EXACTLY this structure (use these repo slugs as headers):

## PART 1 — Plan
{repo_headers}

## PART 2 — Acceptance Criteria
{criteria_headers}

Use EXACTLY the repo slugs shown above as section headers. If a repo needs no
work for this issue, write "No changes required." under it. Output ONLY the plan."""

    result = invoke_claude(prompt, scope="plan", stage="plan", task_id=task_id, repo_slug="all")
    post_issue_comment(issue_number, "plan", 0, result)

    # Determine which repos actually need work (issue-generic: some may be
    # "No changes required"). Record the active set so fan-in knows how many
    # ship events to expect — otherwise the final ship would wait forever.
    active_repos = []
    for repo_slug in REPOS:
        repo_plan = _extract_section(result, f"### Repo: {repo_slug}")
        if repo_plan and "no changes required" not in repo_plan.lower():
            active_repos.append(repo_slug)
    if not active_repos:
        active_repos = list(REPOS)  # fall back to all if the plan was unparseable
    _expected_repos[task_id] = set(active_repos)
    log("plan", f"Active repos for this issue: {', '.join(active_repos)}")

    # Fan-out: publish one message per ACTIVE repo
    for repo_slug in active_repos:
        repo_plan = _extract_section(result, f"### Repo: {repo_slug}")
        repo_criteria = _extract_section(result, f"### {repo_slug} Criteria")

        next_data = {
            **prune_task_data(task_data),
            "plan": result,
            "repo_plan": repo_plan,
            "repo_criteria": repo_criteria,
            "repo_slug": repo_slug,
            "repo_path": REPOS[repo_slug]["path"],
            "repo_github": REPOS[repo_slug]["github_repo"],
            "iteration": 1,
            "feedback": "",
            "concerns": "",
        }
        await publish_json(
            js, f"hi.myrmidon.claude.test.{repo_slug}.{task_id}", next_data
        )
        log("plan", f"Dispatched to tester for {repo_slug}")

    await publish_log(js, "plan", f"Plan complete, dispatched to {len(active_repos)} repo testers", task_id, team_id)
    log_memory("plan")
    return task_data


def _extract_section(text: str, header: str) -> str:
    """Extract a markdown section starting at header, ending at next ### or ## header."""
    lines = text.split("\n")
    capturing = False
    result_lines = []
    for line in lines:
        if line.strip().startswith(header):
            capturing = True
            continue
        if capturing:
            if line.strip().startswith("### ") or line.strip().startswith("## "):
                break
            result_lines.append(line)
    return "\n".join(result_lines).strip()


async def stage_test(task_data: dict, js) -> dict:
    """Stage 2: Write validation tests for one repo."""
    task_id = task_data.get("task_id", "unknown")
    team_id = task_data.get("team_id", "unknown")
    repo_slug = task_data.get("repo_slug", "unknown")
    repo_plan = task_data.get("repo_plan", "")
    repo_criteria = task_data.get("repo_criteria", "")
    iteration = task_data.get("iteration", 1)
    feedback = task_data.get("feedback", "")
    issue_number = task_data.get("issue_number", ISSUE_NUMBER)

    log("test", f"[{repo_slug}] Writing tests (iteration {iteration})")
    log_memory("test")
    await publish_log(js, "test", f"Writing tests iteration {iteration}", task_id, team_id, repo_slug)

    feedback_section = ""
    if feedback:
        feedback_section = f"\nPrevious review feedback to address:\n{feedback}\n"

    prompt = f"""You are a test agent for the HomericIntelligence ecosystem.

Overall goal (from issue #{issue_number} — "{TASK_TITLE}"):
<issue>
{TASK_GOAL}
</issue>

Repo: {repo_slug} (path: {task_data.get('repo_path', '')})

Plan for this repo:
{repo_plan}

Acceptance criteria:
{repo_criteria}
{feedback_section}
Write a bash validation script that verifies this repo's portion of the issue
goal is satisfied — assert each acceptance criterion above against the actual
files in {task_data.get('repo_path', '')} (and the Odysseus root where relevant).

The script should:
- Print PASS or FAIL for each check with a description
- Exit 0 if ALL pass, exit 1 if any fail
- Use simple bash (grep, test, etc.)

Output ONLY the bash script. Start with #!/usr/bin/env bash."""

    result = await bounded_invoke_claude(prompt, scope="test", stage="test", iteration=iteration,
                                         task_id=task_id, repo_slug=repo_slug)
    post_issue_comment(issue_number, "test", iteration, f"```bash\n{result}\n```",
                       repo_slug=repo_slug)

    # Save test script
    if not DRY_RUN:
        test_path = os.path.join(WORKING_DIR, "e2e", f"test-{TASK_SLUG}-{repo_slug}.sh")
        with open(test_path, "w") as f:
            f.write(result)
        os.chmod(test_path, 0o755)
        log("test", f"[{repo_slug}] Wrote test script to {test_path}")

    next_data = {
        **prune_task_data(task_data, keep_extra=(
            "plan", "repo_plan", "repo_criteria", "repo_slug", "repo_path",
            "repo_github", "iteration", "feedback", "concerns",
        )),
        "test_script": result,
    }
    await publish_json(
        js, f"hi.myrmidon.claude.implement.{repo_slug}.{task_id}", next_data
    )
    await publish_log(js, "test", "Tests written, dispatching to implementer",
                      task_id, team_id, repo_slug)
    log_memory("test")
    return next_data


async def stage_implement(task_data: dict, js) -> dict:
    """Stage 3: Implement justfile recipes for one repo."""
    task_id = task_data.get("task_id", "unknown")
    team_id = task_data.get("team_id", "unknown")
    repo_slug = task_data.get("repo_slug", "unknown")
    repo_plan = task_data.get("repo_plan", "")
    test_script = task_data.get("test_script", "")
    iteration = task_data.get("iteration", 1)
    feedback = task_data.get("feedback", "")
    concerns = task_data.get("concerns", "")
    issue_number = task_data.get("issue_number", ISSUE_NUMBER)
    repo_path = task_data.get("repo_path", "")

    log("implement", f"[{repo_slug}] Implementing (iteration {iteration})")
    log_memory("implement")
    await publish_log(js, "implement", f"Implementing iteration {iteration}",
                      task_id, team_id, repo_slug)

    feedback_section = ""
    if feedback and iteration > 1:
        feedback_section = f"""
CRITICAL — Previous review feedback (MUST address ALL items):
{feedback}

Outstanding concerns:
{concerns}
"""

    prompt = f"""You are an implementation agent for the HomericIntelligence ecosystem.

Overall goal (from issue #{issue_number} — "{TASK_TITLE}"):
<issue>
{TASK_GOAL}
</issue>

Repo: {repo_slug} (submodule path: {repo_path})

Plan:
{repo_plan}

Test script that must pass:
{test_script}
{feedback_section}
Instructions:
1. Read {repo_path}/ to understand the current state relevant to the goal.
2. Make the changes this repo needs to satisfy the plan and the issue goal.
   Follow existing conventions in the repo; do not introduce unrelated changes.
3. Run the test script at e2e/test-{TASK_SLUG}-{repo_slug}.sh to verify.

Output a brief summary of what you did (3-5 lines). Files should already be written."""

    result = await bounded_invoke_claude(prompt, scope="implement", stage="implement", iteration=iteration,
                                         task_id=task_id, repo_slug=repo_slug)
    post_issue_comment(issue_number, "implement", iteration, result, repo_slug=repo_slug)

    next_data = {
        **prune_task_data(task_data, keep_extra=(
            "plan", "repo_plan", "repo_criteria", "repo_slug", "repo_path",
            "repo_github", "iteration", "test_script",
        )),
        "implementation_summary": result,
    }
    await publish_json(
        js, f"hi.myrmidon.claude.review.{repo_slug}.{task_id}", next_data
    )
    await publish_log(js, "implement", "Implementation done, dispatching to reviewer",
                      task_id, team_id, repo_slug)
    log_memory("implement")
    return next_data


async def stage_review(task_data: dict, js) -> dict:
    """Stage 4: Review implementation. GO or NOGO."""
    task_id = task_data.get("task_id", "unknown")
    team_id = task_data.get("team_id", "unknown")
    repo_slug = task_data.get("repo_slug", "unknown")
    repo_criteria = task_data.get("repo_criteria", "")
    test_script = task_data.get("test_script", "")
    iteration = task_data.get("iteration", 1)
    issue_number = task_data.get("issue_number", ISSUE_NUMBER)
    previous_concerns = task_data.get("concerns", "")

    log("review", f"[{repo_slug}] Reviewing (iteration {iteration})")
    log_memory("review")
    await publish_log(js, "review", f"Reviewing iteration {iteration}",
                      task_id, team_id, repo_slug)

    previous_section = ""
    if previous_concerns and iteration > 1:
        previous_section = f"""
CRITICAL — Previous concerns that MUST be resolved:
{previous_concerns}

Grade ONLY on whether previous concerns are fixed + any new CRITICAL issues.
Do NOT introduce new minor concerns. Do NOT shift the goalposts.
"""

    prompt = f"""You are a strict code reviewer for the HomericIntelligence ecosystem.

Overall goal (from issue #{issue_number} — "{TASK_TITLE}"):
<issue>
{TASK_GOAL}
</issue>

Review this repo's changes for {repo_slug} against:

1. Acceptance criteria:
{repo_criteria}

2. Test script (run it: bash e2e/test-{TASK_SLUG}-{repo_slug}.sh):
{test_script}

3. The issue goal above and existing conventions in the repo
{previous_section}
For EACH acceptance criterion, output:
- PASS: <criterion> — <explanation>
- FAIL: <criterion> — <what's wrong>

Then on a line by itself:
VERDICT: GO
or
VERDICT: NOGO

If NOGO, list ONLY remaining unresolved concerns.

IMPORTANT:
- Only GO when EVERY criterion passes.
- Run the test script and include output."""

    result = await bounded_invoke_claude(prompt, scope="review", stage="review", iteration=iteration,
                                         task_id=task_id, repo_slug=repo_slug)
    post_issue_comment(issue_number, "review", iteration, result, repo_slug=repo_slug)

    # Parse verdict
    verdict = "NOGO"
    if "VERDICT: GO" in result.upper() or "VERDICT:GO" in result.upper():
        verdict = "GO"

    log("review", f"[{repo_slug}] Verdict: {GREEN if verdict == 'GO' else RED}{verdict}{NC}")
    await publish_log(js, "review", f"Verdict: {verdict} (iteration {iteration})",
                      task_id, team_id, repo_slug)

    if verdict == "GO":
        # Dispatch to per-repo shipper
        ship_data = {**prune_task_data(task_data, keep_extra=(
            "repo_slug", "repo_path", "repo_github",
        ))}
        await publish_json(
            js, f"hi.myrmidon.claude.ship.{repo_slug}.{task_id}", ship_data
        )
        log_memory("review")
        return ship_data
    else:
        # NOGO — loop back to tester
        concerns_text = result.split("VERDICT:")[-1] if "VERDICT:" in result else result
        next_iteration = iteration + 1

        if next_iteration > MAX_ITERATIONS:
            log("review", f"[{repo_slug}] {RED}Max iterations ({MAX_ITERATIONS}) reached. Escalating.{NC}")
            post_issue_comment(
                issue_number, "review", iteration,
                f"**[{repo_slug}] Max iterations reached.** Escalating.\n\n{concerns_text}",
                repo_slug=repo_slug,
            )
            await publish_log(js, "review", "Max iterations reached, escalating",
                              task_id, team_id, repo_slug)
            log_memory("review")
            return task_data

        next_data = {
            **prune_task_data(task_data, keep_extra=(
                "plan", "repo_plan", "repo_criteria", "repo_slug", "repo_path", "repo_github",
            )),
            "iteration": next_iteration,
            "feedback": result,
            "concerns": concerns_text,
        }
        log("review", f"[{repo_slug}] NOGO — looping back to tester (iteration {next_iteration})")
        await publish_json(
            js, f"hi.myrmidon.claude.test.{repo_slug}.{task_id}", next_data
        )
        log_memory("review")
        return next_data


async def stage_ship_repo(task_data: dict, js) -> dict:
    """Stage 5a: Create PR in the submodule's upstream repo."""
    task_id = task_data.get("task_id", "unknown")
    team_id = task_data.get("team_id", "unknown")
    repo_slug = task_data.get("repo_slug", "unknown")
    repo_github = task_data.get("repo_github", "")
    repo_path = task_data.get("repo_path", "")
    issue_number = task_data.get("issue_number", ISSUE_NUMBER)

    log("ship", f"[{repo_slug}] Creating PR in {repo_github}")
    log_memory("ship")
    await publish_log(js, "ship", f"Shipping {repo_slug}", task_id, team_id, repo_slug)

    branch = f"feat/{TASK_SLUG}"
    prompt = f"""You are a shipping agent for the HomericIntelligence ecosystem.

The changes for {repo_slug} (for issue #{issue_number} — "{TASK_TITLE}") have been
reviewed and approved. Open a PR in this repo's upstream.

Steps:
1. cd into the submodule: cd {repo_path}
2. git fetch origin main
3. git checkout -b {branch} origin/main
4. Stage the changes you made for this issue: git add -A (only the files this
   issue's work touched — do not stage unrelated changes)
5. Commit with a message whose subject summarizes THIS issue's change for this
   repo, with body:

   Part of HomericIntelligence/Odysseus#{issue_number}

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
6. Push: git push -u origin {branch}
7. Create PR: gh pr create --repo {repo_github} \\
     --title "<concise title describing this repo's change for the issue>" \\
     --body "Part of HomericIntelligence/Odysseus#{issue_number}

<short description of what changed and why, per the issue goal>

Generated with [Claude Code](https://claude.com/claude-code)"

Output the PR URL."""

    result = await bounded_invoke_claude(prompt, scope="ship", stage="ship", task_id=task_id, repo_slug=repo_slug)
    post_issue_comment(issue_number, "ship", 0,
                       f"**[{repo_slug}] Shipped!**\n\n{result}", repo_slug=repo_slug)

    # Track completion for fan-in
    _repo_go_verdicts.setdefault(task_id, set()).add(repo_slug)
    _repo_pr_urls.setdefault(task_id, {})[repo_slug] = result

    await publish_log(js, "ship", f"{repo_slug} PR created: {result}", task_id, team_id, repo_slug)

    # Check fan-in: all 4 repos shipped?
    expected = _expected_repos.get(task_id, set(REPOS.keys()))
    if _repo_go_verdicts.get(task_id, set()) >= expected:
        log("ship", f"{GREEN}All {len(expected)} repo PRs created! Dispatching final Odysseus ship.{NC}")
        final_data = {
            **prune_task_data(task_data),
            "repo_pr_urls": _repo_pr_urls.get(task_id, {}),
        }
        await publish_json(js, f"hi.myrmidon.claude.ship-final.{task_id}", final_data)
    else:
        done = len(_repo_go_verdicts.get(task_id, set()))
        log("ship", f"[{repo_slug}] {done}/{len(expected)} repos shipped, waiting for others...")

    log_memory("ship")
    return task_data


async def stage_ship_odysseus(task_data: dict, js) -> dict:
    """Stage 5b: Final Odysseus PR — justfile delegation recipes + submodule pin updates."""
    task_id = task_data.get("task_id", "unknown")
    team_id = task_data.get("team_id", "unknown")
    issue_number = task_data.get("issue_number", ISSUE_NUMBER)
    repo_pr_urls = task_data.get("repo_pr_urls", {})

    log("ship-final", "Creating final Odysseus PR")
    log_memory("ship-final")
    await publish_log(js, "ship-final", "Creating Odysseus PR", task_id, team_id)

    pr_links = "\n".join(f"- **{slug}**: {url}" for slug, url in repo_pr_urls.items())
    shipped_paths = "\n".join(
        f"   git -C {REPOS[slug]['path']} fetch origin && git -C {REPOS[slug]['path']} checkout origin/main"
        for slug in repo_pr_urls if slug in REPOS
    )
    stage_paths = " ".join(REPOS[slug]["path"] for slug in repo_pr_urls if slug in REPOS)
    branch = f"feat/{TASK_SLUG}-odysseus"

    prompt = f"""You are the final shipping agent for the HomericIntelligence ecosystem.

Issue #{issue_number} — "{TASK_TITLE}". The per-repo PRs are done; now create the
final Odysseus meta-repo PR, including any Odysseus-root changes the issue calls
for (e.g. README/badge-table edits) plus submodule pin bumps for the shipped repos.

<issue>
{TASK_GOAL}
</issue>

Per-repo PRs already created:
{pr_links}

Steps:
1. git fetch origin main
2. git checkout -b {branch} origin/main
3. Make any Odysseus-root changes the issue requires (do this per the issue body).
4. Bump submodule pins for the repos that shipped:
{shipped_paths}
5. Stage: git add -A {stage_paths} (plus any Odysseus-root files you changed)
6. Commit with a subject summarizing the issue's Odysseus-level change, body:

   Closes #{issue_number}

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
7. Push: git push -u origin {branch}
8. Create PR: gh pr create --repo {REPO} \\
     --title "<concise title for the Odysseus-level change>" \\
     --body "Closes #{issue_number}

<summary of the meta-repo change + the per-repo PRs below>
{pr_links}

Generated with [Claude Code](https://claude.com/claude-code)"

Output the PR URL."""

    result = await bounded_invoke_claude(prompt, scope="ship", stage="ship-final", task_id=task_id, repo_slug="odysseus")
    post_issue_comment(issue_number, "ship-final", 0, f"**Odysseus shipped!**\n\n{result}")

    # Publish completion
    await publish_json(js, f"hi.tasks.{team_id}.{task_id}.completed", {
        "event": "task.completed",
        "data": {
            "team_id": team_id,
            "task_id": task_id,
            "result": result,
            "status": "completed",
            "repo_prs": repo_pr_urls,
        },
        "timestamp": now_iso(),
    })
    await publish_log(js, "ship-final", f"Task complete: {result}", task_id, team_id)

    log("ship-final", f"{GREEN}All done! Odysseus PR: {result}{NC}")
    log_memory("ship-final")
    return task_data


# ─── Main Loop ──────────────────────────────────────────────────────────────

async def main():
    try:
        import nats as nats_mod
        from nats.js.api import ConsumerConfig, DeliverPolicy, AckPolicy
    except ImportError:
        print("ERROR: nats-py not installed. Run: pip install nats-py", file=sys.stderr)
        sys.exit(1)

    nc = await nats_mod.connect(NATS_URL)
    js = nc.jetstream()
    log("main", f"Connected to NATS at {NATS_URL}")

    # Load the issue-defined goal (issue-generic: prompts are driven by this).
    _load_task_goal()
    log("main", f"Task goal loaded from issue #{ISSUE_NUMBER}: {TASK_TITLE!r} "
                f"({len(TASK_GOAL)} chars, slug={TASK_SLUG})")

    # Ensure streams exist
    stream_configs = [
        ("homeric-myrmidon", ["hi.myrmidon.>"], 3600, 50 * 1024 * 1024),
        ("homeric-tasks", ["hi.tasks.>"], 86400, 10 * 1024 * 1024),
        ("homeric-logs", ["hi.logs.>"], 3600, 20 * 1024 * 1024),
    ]
    for stream_name, subjects, max_age, max_bytes in stream_configs:
        try:
            existing = await js.find_stream_name_by_subject(subjects[0])
            # Stream already serves this subject — reconcile config via update,
            # not add (add_stream errors 10058 when the name exists with a
            # different retention config, e.g. one created by Agamemnon/worker).
            await js.update_stream(name=existing, subjects=subjects,
                                   max_age=max_age, max_bytes=max_bytes)
            log("main", f"Updated stream {existing}")
        except Exception:
            await js.add_stream(name=stream_name, subjects=subjects,
                                max_age=max_age, max_bytes=max_bytes)
            log("main", f"Created stream {stream_name}")

    # Register consumers: 1 planner + 4x(test+impl+review) + 4 per-repo ship + 1 final ship
    stage_subjects: list[tuple[str, str, any]] = [
        ("claude-multi-planner", "hi.myrmidon.claude.plan.*", stage_plan),
    ]

    for repo_slug in REPOS:
        stage_subjects.extend([
            (f"claude-multi-tester-{repo_slug}",
             f"hi.myrmidon.claude.test.{repo_slug}.*",
             stage_test),
            (f"claude-multi-impl-{repo_slug}",
             f"hi.myrmidon.claude.implement.{repo_slug}.*",
             stage_implement),
            (f"claude-multi-reviewer-{repo_slug}",
             f"hi.myrmidon.claude.review.{repo_slug}.*",
             stage_review),
            (f"claude-multi-shipper-{repo_slug}",
             f"hi.myrmidon.claude.ship.{repo_slug}.*",
             stage_ship_repo),
        ])

    stage_subjects.append(
        ("claude-multi-shipper-odysseus", "hi.myrmidon.claude.ship-final.*",
         stage_ship_odysseus),
    )

    consumers = {}
    for consumer_name, filter_subject, handler in stage_subjects:
        try:
            sub = await js.pull_subscribe(
                filter_subject,
                durable=consumer_name,
                stream=STREAM_NAME,
            )
            consumers[consumer_name] = (sub, handler)
            log("main", f"Subscribed: {consumer_name} -> {filter_subject}")
        except Exception as e:
            log("main", f"{YELLOW}Consumer {consumer_name}: {e}{NC}")

    repo_list = ", ".join(REPOS.keys())
    print(f"\n{BOLD}{'=' * 60}{NC}")
    print(f"{BOLD}  Claude Myrmidon Multi — Multi-Repo Pipeline{NC}")
    print(f"{BOLD}{'=' * 60}{NC}")
    print(f"  NATS: {NATS_URL}")
    print(f"  Mode: {'DRY-RUN' if DRY_RUN else 'LIVE'} | GitHub: {'DISABLED' if NO_GITHUB else 'ENABLED'}")
    print(f"  Container: {CLAUDE_IMAGE} via {CONTAINER_RUNTIME}")
    print(f"  Repos: {repo_list}")
    print(f"  Issue: #{ISSUE_NUMBER} | Max iterations: {MAX_ITERATIONS}")
    print(f"  Consumers: {len(consumers)}")
    print(f"  Stages: plan -> 4x[test->impl->review] -> 4x ship -> ship-final")
    print(f"{BOLD}{'=' * 60}{NC}")
    log_memory("main")

    # Auto-seed: publish the initial plan trigger so a single invocation kicks
    # off the pipeline for ISSUE_NUMBER (set SEED=0 to run as a passive daemon
    # that waits for an external plan publish instead).
    if os.environ.get("SEED", "1") == "1":
        seed_task_id = os.environ.get("TASK_ID", f"badge-{ISSUE_NUMBER}")
        seed_team_id = os.environ.get("TEAM_ID", "ecosystem")
        await publish_json(js, f"hi.myrmidon.claude.plan.{seed_task_id}", {
            "task_id": seed_task_id,
            "team_id": seed_team_id,
            "issue_number": ISSUE_NUMBER,
        })
        log("main", f"Seeded plan trigger for issue #{ISSUE_NUMBER} (task_id={seed_task_id})")

    print(f"\n{DIM}Waiting for tasks... (Ctrl+C to quit){NC}\n")

    # Main polling loop
    running = True

    def signal_handler(sig, frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    while running:
        for consumer_name, (sub, handler) in consumers.items():
            try:
                msgs = await sub.fetch(batch=1, timeout=1)
                for msg in msgs:
                    data = json.loads(msg.data.decode())
                    repo = data.get("repo_slug", "")
                    prefix = f"[{repo}] " if repo else ""
                    log("main", f"Received on {consumer_name}: {prefix}task_id={data.get('task_id', '?')}")
                    try:
                        await handler(data, js)
                    except Exception as e:
                        log("main", f"{RED}Handler error in {consumer_name}: {e}{NC}")
                        import traceback
                        traceback.print_exc()
                    await msg.ack()
            except Exception:
                pass  # Timeout or no messages — normal

        await asyncio.sleep(0.1)

    # Graceful shutdown
    log("main", "Shutting down")
    await nc.drain()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
