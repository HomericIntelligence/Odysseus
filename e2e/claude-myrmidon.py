#!/usr/bin/env python3
"""Claude Code Myrmidon — Multi-stage NATS worker using Claude CLI.

Implements a 5-stage pipeline for task execution:
  1. PLANNER  — reads issue + codebase, produces plan + acceptance criteria
  2. TESTER   — writes validation test script from plan criteria
  3. IMPLEMENTER — writes the deliverable (code, docs, etc.)
  4. REVIEWER — reviews against fixed criteria, GO/NOGO verdict
  5. SHIPPER  — commits, creates PR, publishes completion

Stages 2-4 loop (max 5 iterations) until reviewer gives GO.
All progress is posted as GitHub issue comments.
All events flow through NATS for observability.

Usage:
    NATS_URL=nats://localhost:4222 python3 e2e/claude-myrmidon.py

Environment:
    NATS_URL        NATS server URL (default: nats://localhost:4222)
    REPO            GitHub repo (default: HomericIntelligence/Odysseus)
    WORKING_DIR     Working directory for claude invocations (default: cwd)
    MAX_ITERATIONS  Max review loop iterations (default: 5)
"""

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

# ─── Configuration ───────────────────────────────────────────────────────────
NATS_URL = os.environ.get("NATS_URL", "nats://localhost:4222")
REPO = os.environ.get("REPO", "HomericIntelligence/Odysseus")
WORKING_DIR = os.environ.get("WORKING_DIR", os.getcwd())
MAX_ITERATIONS = int(os.environ.get("MAX_ITERATIONS", "5"))
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"
NO_GITHUB = os.environ.get("NO_GITHUB", "0") == "1"

# Container configuration — claude CLI always runs inside the achaean-claude vessel
CLAUDE_IMAGE = os.environ.get("CLAUDE_IMAGE", "achaean-claude:latest")
CONTAINER_WORKSPACE = "/workspace"
CONTAINER_RUNTIME = os.environ.get("CONTAINER_RUNTIME", "podman")

STREAM_NAME = "homeric-myrmidon"
LOG_SUBJECT = "hi.logs.myrmidon.claude"

# ANSI colors
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
}


def now_iso():
    return datetime.now(timezone.utc).strftime("%FT%TZ")


def log(stage, msg):
    color = STAGE_COLORS.get(stage, NC)
    ts = datetime.now(timezone.utc).strftime("%H:%M:%S")
    print(f"{DIM}{ts}{NC} {color}{BOLD}[{stage.upper()}]{NC} {msg}", flush=True)


# ─── Helpers ─────────────────────────────────────────────────────────────────

def log_memory(stage: str):
    """Log current RSS memory usage."""
    rss_kb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    rss_mb = rss_kb / 1024
    log(stage, f"Memory: {rss_mb:.1f} MB RSS")


_CORE_KEYS = {"task_id", "team_id", "subject", "description", "issue_number"}


def prune_task_data(task_data: dict, keep_extra: tuple = ()) -> dict:
    """Strip accumulated stage outputs, keeping only core identity + specified extras."""
    allowed = _CORE_KEYS | set(keep_extra)
    return {k: v for k, v in task_data.items() if k in allowed}


def mock_claude_response(stage: str, iteration: int) -> str:
    """Return canned responses for dry-run mode."""
    if stage == "plan":
        return """# Implementation Plan

## PART 1 — Plan

### ADR-007: Symlinks Over Submodules

**Context:** The Odysseus meta-repo uses git submodules defined in .gitmodules,
but several paths are symlinks to local directories instead of real gitlinks.

**Decision:** Document why symlinks were chosen over standard submodule checkouts.

**Consequences:**
- CI/CD must handle symlink resolution
- Onboarding requires understanding the symlink layout
- Disaster recovery needs symlink recreation steps

## PART 2 — Acceptance Criteria

1. File exists at docs/adr/007-symlinks-over-submodules.md
2. Status field is "Accepted"
3. Context section explains the symlink vs submodule situation
4. Decision section documents the rationale
5. Consequences section covers CI/CD, onboarding, disaster recovery
6. Format matches existing ADRs (001-006)
7. Factually accurate submodule count and paths"""

    elif stage == "test":
        return """#!/usr/bin/env bash
set -euo pipefail
echo "DRY-RUN: all acceptance criteria checks pass"
exit 0"""

    elif stage == "implement":
        return "No-op: docs/adr/007-symlinks-over-submodules.md would be written here.\nSummary: [dry-run] File creation skipped."

    elif stage == "review":
        if iteration <= 1:
            return """Review of docs/adr/007-symlinks-over-submodules.md:

1. PASS: File exists at correct path
2. PASS: Status field present
3. FAIL: Context section missing detail on symlink count
4. PASS: Decision section documents rationale
5. PASS: Consequences cover CI/CD, onboarding, recovery
6. PASS: Format matches existing ADRs
7. FAIL: Submodule count not verified

VERDICT: NOGO

Remaining concerns:
1. Context section should specify exact number of symlinked paths
2. Submodule count needs verification against .gitmodules"""
        else:
            return """Review of docs/adr/007-symlinks-over-submodules.md:

1. PASS: File exists at correct path
2. PASS: Status field present
3. PASS: Context section explains symlink situation with counts
4. PASS: Decision section documents rationale
5. PASS: Consequences cover CI/CD, onboarding, recovery
6. PASS: Format matches existing ADRs
7. PASS: Factually accurate

VERDICT: GO

All acceptance criteria pass. All previous concerns resolved."""

    elif stage == "ship":
        return "No-op: PR would be created here\nhttps://github.com/HomericIntelligence/Odysseus/pull/dry-run"

    return f"[DRY-RUN] Unknown stage: {stage}"


# ─── Claude CLI Invocation ───────────────────────────────────────────────────
# Track session IDs per task+stage so iterations resume the same session.
# Key: "{task_id}-{stage}" → UUID session ID
_session_ids: dict[str, str] = {}


def _get_session_id(task_id: str, stage: str) -> str:
    """Get or create a deterministic session ID for a task+stage combo."""
    key = f"{task_id}-{stage}"
    if key not in _session_ids:
        _session_ids[key] = str(uuid.uuid4())
    return _session_ids[key]


def _build_container_cmd(claude_args: list[str], cwd: str = WORKING_DIR) -> list[str]:
    """Build a container run command with proper volume mappings.

    Maps the host WORKING_DIR to /workspace inside the achaean-claude container,
    plus the user's .claude config and ANTHROPIC_API_KEY for authentication.
    """
    home = os.path.expanduser("~")
    cmd = [
        CONTAINER_RUNTIME, "run", "--rm",
        "--network", "homeric-mesh",
        "-v", f"{cwd}:{CONTAINER_WORKSPACE}",
        "-v", f"{home}/.claude:{home}/.claude",
        "-w", CONTAINER_WORKSPACE,
        "-e", f"ANTHROPIC_API_KEY={os.environ.get('ANTHROPIC_API_KEY', '')}",
        "-e", f"HOME={home}",
        CLAUDE_IMAGE,
    ]
    cmd.extend(claude_args)
    return cmd


def invoke_claude(prompt: str, cwd: str = WORKING_DIR, stage: str = "",
                  iteration: int = 0, task_id: str = "") -> str:
    """Invoke Claude Code CLI inside the achaean-claude container.

    Resumes the same session for iterations > 0.
    """
    if DRY_RUN:
        log("claude", f"[DRY-RUN] Skipping claude -p ({len(prompt)} chars)")
        return mock_claude_response(stage, iteration)

    session_id = _get_session_id(task_id, stage) if task_id else ""
    is_resume = iteration > 0 and session_id

    claude_args = [
        "claude", "-p", prompt,
        "--permission-mode", "acceptEdits",
        "--allowedTools", "Bash,Read,Write,Edit,Glob,Grep",
    ]

    if is_resume:
        log("claude", f"Resuming session {session_id[:8]}... ({len(prompt)} chars)")
        claude_args.extend(["--resume", session_id])
    else:
        log("claude", f"Starting new session ({len(prompt)} chars)")
        if session_id:
            claude_args.extend(["--session-id", session_id])

    cmd = _build_container_cmd(claude_args, cwd=cwd)

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=600,  # 10 minute timeout per stage
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


# ─── GitHub Issue Comments ───────────────────────────────────────────────────
# Track comment IDs so we can edit-in-place instead of creating duplicates
_comment_ids: dict[str, int] = {}  # key: "stage-iteration" → GitHub comment ID
_comment_ids_loaded: set[int] = set()  # issue numbers already scanned


def _comment_key(stage: str, iteration: int) -> str:
    return f"{stage}-{iteration}"


def _load_existing_comment_ids(issue_number: int):
    """Fetch existing issue comments and populate _comment_ids for deduplication.

    Parses each comment body for '## Stage: STAGE (iteration N)' headers.
    Called lazily on first post_issue_comment per issue. Survives process restarts.
    """
    if issue_number in _comment_ids_loaded:
        return
    _comment_ids_loaded.add(issue_number)

    try:
        result = subprocess.run(
            ["gh", "api", "--paginate",
             f"repos/{REPO}/issues/{issue_number}/comments",
             "--jq", r'.[] | "\(.id)\t\(.body[0:80])"'],
            capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=30,
        )
        if result.returncode != 0:
            log("github", f"{YELLOW}Failed to load existing comments: {result.stderr[:200]}{NC}")
            return

        import re
        pattern = re.compile(r"## Stage: (\w+)(?:\s+\(iteration (\d+)\))?")
        for line in result.stdout.strip().splitlines():
            parts = line.split("\t", 1)
            if len(parts) < 2:
                continue
            comment_id_str, body_prefix = parts
            if not comment_id_str.isdigit():
                continue
            m = pattern.search(body_prefix)
            if m:
                stage_name = m.group(1).lower()
                iteration_num = int(m.group(2)) if m.group(2) else 0
                key = _comment_key(stage_name, iteration_num)
                _comment_ids[key] = int(comment_id_str)

        if _comment_ids:
            log("github", f"Loaded {len(_comment_ids)} existing comment(s) for issue #{issue_number}")
    except Exception as e:
        log("github", f"{YELLOW}Could not load existing comments: {e}{NC}")


def post_issue_comment(issue_number: int, stage: str, iteration: int, content: str):
    """Post or update a comment on the GitHub issue. Same stage+iteration edits in place."""
    if content.startswith("ERROR:") or not content.strip():
        log(stage, f"{YELLOW}Skipping empty/error comment{NC}")
        return
    if NO_GITHUB:
        log(stage, f"[NO_GITHUB] Would post to issue #{issue_number} ({len(content)} chars)")
        return

    _load_existing_comment_ids(issue_number)

    header = f"## Stage: {stage.upper()}"
    if iteration > 0:
        header += f" (iteration {iteration})"

    body = f"{header}\n\n{content}\n\n---\n*Updated by claude-myrmidon at {now_iso()}*"

    key = _comment_key(stage, iteration)
    try:
        if key in _comment_ids:
            # Edit existing comment
            comment_id = _comment_ids[key]
            subprocess.run(
                ["gh", "api", "-X", "PATCH",
                 f"repos/{REPO}/issues/comments/{comment_id}",
                 "-f", f"body={body}"],
                capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=30,
            )
            log(stage, f"Updated comment {comment_id} on issue #{issue_number}")
        else:
            # Create new comment and save ID
            result = subprocess.run(
                ["gh", "issue", "comment", str(issue_number),
                 "--repo", REPO, "--body", body],
                capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=30,
            )
            # Extract comment ID from the URL in output
            if result.stdout.strip():
                # gh issue comment prints the URL
                url = result.stdout.strip()
                # Fetch the latest comment to get its ID
                comments_json = subprocess.run(
                    ["gh", "api", f"repos/{REPO}/issues/{issue_number}/comments",
                     "--jq", ".[-1].id"],
                    capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=15,
                )
                if comments_json.stdout.strip().isdigit():
                    _comment_ids[key] = int(comments_json.stdout.strip())
            log(stage, f"Posted comment to issue #{issue_number}")
    except Exception as e:
        log(stage, f"{RED}Failed to post comment: {e}{NC}")


# ─── NATS Helpers ────────────────────────────────────────────────────────────
async def publish_json(js, subject: str, data: dict):
    """Publish a JSON message to a NATS JetStream subject."""
    payload = json.dumps(data).encode()
    log("nats", f"Publishing to {subject} ({len(payload)} bytes)")
    ack = await js.publish(subject, payload)
    log("nats", f"Published to {subject} (seq={ack.seq})")


async def publish_log(js, stage: str, message: str, task_id: str = "", team_id: str = ""):
    """Publish a structured log entry."""
    await publish_json(js, LOG_SUBJECT, {
        "level": "info",
        "service": "claude-myrmidon",
        "stage": stage,
        "message": message,
        "task_id": task_id,
        "team_id": team_id,
        "timestamp": now_iso(),
    })


# ─── Stage Handlers ─────────────────────────────────────────────────────────

async def stage_plan(task_data: dict, js) -> dict:
    """Stage 1: Plan the task and define acceptance criteria."""
    task_id = task_data.get("task_id", "unknown")
    team_id = task_data.get("team_id", "unknown")
    subject = task_data.get("subject", "unknown task")
    description = task_data.get("description", "")
    issue_number = task_data.get("issue_number", 7)

    log("plan", f"Planning task: {subject}")
    log_memory("plan")
    await publish_log(js, "plan", f"Starting plan for: {subject}", task_id, team_id)

    prompt = f"""You are a planning agent for the HomericIntelligence ecosystem.

Task: {subject}
Description: {description}
GitHub Issue: #{issue_number} on {REPO}

Instructions:
1. Read the GitHub issue: run `gh issue view {issue_number} --repo {REPO}`
2. Read existing ADRs at docs/adr/ for format reference
3. Read .gitmodules and check which paths are symlinks vs real dirs (use `ls -la`)
4. Read docs/architecture.md for context

Produce a structured plan with TWO parts:

PART 1 — Implementation Plan:
- ADR number and title
- Each section the ADR needs (Context, Decision, Consequences)
- Key facts to include (number of submodules, which are symlinks, why chosen)
- Impact areas to address (CI/CD, onboarding, disaster recovery, cloning)

PART 2 — Acceptance Criteria (the fixed rubric for review):
Number each criterion. These will NOT change between iterations.
1. File exists at the correct path
2. Status field is present
3. Context section explains the problem
4. Decision section documents the choice and rationale
5. Consequences section covers positive, negative, and neutral impacts
6. Format matches existing ADRs
7. Factually accurate

Output ONLY the plan as markdown. No preamble."""

    result = invoke_claude(prompt, stage="plan", iteration=0, task_id=task_id)
    post_issue_comment(issue_number, "plan", 0, result)

    # Publish next stage
    next_data = {**prune_task_data(task_data), "plan": result, "iteration": 1, "feedback": "", "concerns": ""}
    await publish_json(js, f"hi.myrmidon.claude.test.{task_id}", next_data)
    await publish_log(js, "plan", "Plan complete, dispatching to tester", task_id, team_id)
    log_memory("plan")

    return next_data


async def stage_test(task_data: dict, js) -> dict:
    """Stage 2: Write validation tests based on plan criteria."""
    task_id = task_data.get("task_id", "unknown")
    team_id = task_data.get("team_id", "unknown")
    plan = task_data.get("plan", "")
    iteration = task_data.get("iteration", 1)
    feedback = task_data.get("feedback", "")
    issue_number = task_data.get("issue_number", 7)

    log("test", f"Writing tests (iteration {iteration})")
    log_memory("test")
    await publish_log(js, "test", f"Writing tests iteration {iteration}", task_id, team_id)

    feedback_section = ""
    if feedback:
        feedback_section = f"""
Previous review feedback to incorporate into tests:
{feedback}
"""

    prompt = f"""You are a test agent for the HomericIntelligence ecosystem.

Based on this plan and acceptance criteria:
{plan}
{feedback_section}
Write a bash validation script that checks the ADR implementation.
The script should verify each acceptance criterion from the plan:
- File existence at the expected path
- Required sections present (Context, Decision, Consequences)
- Format compliance (compare structure against docs/adr/006-decouple-from-ai-maestro.md)
- Factual accuracy (grep for expected content like submodule mentions)
- Content completeness (each impact area addressed)

The script should:
- Print PASS or FAIL for each check with a description
- Exit 0 if ALL checks pass, exit 1 if any fail
- Use simple bash (grep, test, etc.) — no special dependencies

Output ONLY the bash script. No explanation. Start with #!/usr/bin/env bash."""

    result = invoke_claude(prompt, stage="test", iteration=iteration, task_id=task_id)
    post_issue_comment(issue_number, "test", iteration, f"```bash\n{result}\n```")

    # Save test script
    if not DRY_RUN:
        test_path = os.path.join(WORKING_DIR, "e2e", "test-adr-007.sh")
        with open(test_path, "w") as f:
            f.write(result)
        os.chmod(test_path, 0o755)
        log("test", f"Wrote test script to {test_path}")
    else:
        log("test", f"[DRY-RUN] Would write test script ({len(result)} chars)")

    # Publish next stage
    next_data = {**prune_task_data(task_data, keep_extra=("plan", "iteration", "feedback", "concerns")), "test_script": result}
    await publish_json(js, f"hi.myrmidon.claude.implement.{task_id}", next_data)
    await publish_log(js, "test", "Tests written, dispatching to implementer", task_id, team_id)
    log_memory("test")

    return next_data


async def stage_implement(task_data: dict, js) -> dict:
    """Stage 3: Implement the deliverable."""
    task_id = task_data.get("task_id", "unknown")
    team_id = task_data.get("team_id", "unknown")
    plan = task_data.get("plan", "")
    test_script = task_data.get("test_script", "")
    iteration = task_data.get("iteration", 1)
    feedback = task_data.get("feedback", "")
    concerns = task_data.get("concerns", "")
    issue_number = task_data.get("issue_number", 7)

    log("implement", f"Implementing (iteration {iteration})")
    log_memory("implement")
    await publish_log(js, "implement", f"Implementing iteration {iteration}", task_id, team_id)

    feedback_section = ""
    if feedback and iteration > 1:
        feedback_section = f"""
CRITICAL — Previous review feedback (MUST address ALL items):
{feedback}

Outstanding concerns from reviewer:
{concerns}
"""

    prompt = f"""You are an implementation agent for the HomericIntelligence ecosystem.

Write the file docs/adr/007-symlinks-over-submodules.md based on this plan:

{plan}

The following test script must pass against your output:
{test_script}
{feedback_section}
Instructions:
1. Read existing ADRs at docs/adr/ for format reference (especially 006)
2. Read .gitmodules to get accurate submodule data
3. Check which directories are symlinks: ls -la control/ infrastructure/ provisioning/ etc.
4. Write docs/adr/007-symlinks-over-submodules.md with accurate content
5. Run the test script e2e/test-adr-007.sh to verify your work passes

Output a brief summary of what you wrote (3-5 lines). The file should already be written."""

    result = invoke_claude(prompt, stage="implement", iteration=iteration, task_id=task_id)
    post_issue_comment(issue_number, "implement", iteration, result)

    # Publish next stage — drop feedback/concerns (implementer already used them)
    next_data = {**prune_task_data(task_data, keep_extra=("plan", "test_script", "iteration")), "implementation_summary": result}
    await publish_json(js, f"hi.myrmidon.claude.review.{task_id}", next_data)
    await publish_log(js, "implement", "Implementation done, dispatching to reviewer", task_id, team_id)
    log_memory("implement")

    return next_data


async def stage_review(task_data: dict, js) -> dict:
    """Stage 4: Review the implementation. GO or NOGO."""
    task_id = task_data.get("task_id", "unknown")
    team_id = task_data.get("team_id", "unknown")
    plan = task_data.get("plan", "")
    test_script = task_data.get("test_script", "")
    iteration = task_data.get("iteration", 1)
    previous_concerns = task_data.get("concerns", "")
    issue_number = task_data.get("issue_number", 7)

    log("review", f"Reviewing (iteration {iteration})")
    log_memory("review")
    await publish_log(js, "review", f"Reviewing iteration {iteration}", task_id, team_id)

    previous_section = ""
    if previous_concerns and iteration > 1:
        previous_section = f"""
CRITICAL — Previous review concerns that MUST be resolved:
{previous_concerns}

Grade ONLY on whether previous concerns are fixed + any new CRITICAL issues.
Do NOT introduce new minor concerns that weren't in previous reviews.
Do NOT shift the goalposts.
"""

    prompt = f"""You are a strict code reviewer for the HomericIntelligence ecosystem.

Review the file docs/adr/007-symlinks-over-submodules.md against:

1. The plan and acceptance criteria:
{plan}

2. The test script (run it: bash e2e/test-adr-007.sh):
{test_script}

3. ADR format reference: read docs/adr/006-decouple-from-ai-maestro.md

4. Factual accuracy: check .gitmodules and ls -la on submodule directories
{previous_section}
For EACH acceptance criterion from the plan, output:
- PASS: <criterion> — <brief explanation>
- FAIL: <criterion> — <what's wrong and how to fix>

Then output your verdict on a line by itself:
VERDICT: GO
or
VERDICT: NOGO

If NOGO, list ONLY the remaining unresolved concerns as a numbered list.

IMPORTANT:
- Only output GO when EVERY acceptance criterion passes.
- Do not lower the bar between iterations.
- Run the test script and include its output."""

    result = invoke_claude(prompt, stage="review", iteration=iteration, task_id=task_id)
    post_issue_comment(issue_number, "review", iteration, result)

    # Parse verdict
    verdict = "NOGO"
    if "VERDICT: GO" in result.upper() or "VERDICT:GO" in result.upper():
        verdict = "GO"

    log("review", f"Verdict: {GREEN if verdict == 'GO' else RED}{verdict}{NC}")
    await publish_log(js, "review", f"Verdict: {verdict} (iteration {iteration})", task_id, team_id)

    if verdict == "GO":
        # Ship it — only core keys needed
        ship_data = prune_task_data(task_data)
        await publish_json(js, f"hi.myrmidon.claude.ship.{task_id}", ship_data)
        log_memory("review")
        return ship_data
    else:
        # Extract concerns for next iteration
        concerns_text = result.split("VERDICT:")[-1] if "VERDICT:" in result else result
        next_iteration = iteration + 1

        if next_iteration > MAX_ITERATIONS:
            log("review", f"{RED}Max iterations ({MAX_ITERATIONS}) reached. Escalating.{NC}")
            post_issue_comment(
                issue_number, "review", iteration,
                f"**Max iterations ({MAX_ITERATIONS}) reached without GO.** Escalating to human review.\n\nLast concerns:\n{concerns_text}"
            )
            await publish_log(js, "review", f"Max iterations reached, escalating", task_id, team_id)
            log_memory("review")
            return task_data

        # Loop back to tester — carry plan (fixed contract) + new feedback
        next_data = {
            **prune_task_data(task_data, keep_extra=("plan",)),
            "iteration": next_iteration,
            "feedback": result,
            "concerns": concerns_text,
        }
        log("review", f"NOGO — looping back to tester (iteration {next_iteration})")
        await publish_json(js, f"hi.myrmidon.claude.test.{task_id}", next_data)
        log_memory("review")
        return next_data


async def stage_ship(task_data: dict, js) -> dict:
    """Stage 5: Commit, create PR, publish completion."""
    task_id = task_data.get("task_id", "unknown")
    team_id = task_data.get("team_id", "unknown")
    issue_number = task_data.get("issue_number", 7)

    log("ship", "Shipping approved implementation")
    log_memory("ship")
    await publish_log(js, "ship", "Shipping implementation", task_id, team_id)

    prompt = f"""You are a shipping agent for the HomericIntelligence ecosystem.

The ADR at docs/adr/007-symlinks-over-submodules.md has been reviewed and approved.

Steps:
1. Create a new branch: git checkout -b docs/adr-007-symlinks
2. Stage the file: git add docs/adr/007-symlinks-over-submodules.md
3. Commit: git commit -m "docs(adr): add ADR-007 documenting symlinks-instead-of-submodules decision

Closes #{issue_number}

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
4. Push: git push -u origin docs/adr-007-symlinks
5. Create PR: gh pr create --repo {REPO} --title "docs(adr): add ADR-007 symlinks-instead-of-submodules" --body "Closes #{issue_number}

Written by the claude-myrmidon pipeline (plan → test → implement → review → ship).

🤖 Generated with [Claude Code](https://claude.com/claude-code)"

Output the PR URL."""

    result = invoke_claude(prompt, stage="ship", iteration=0, task_id=task_id)
    post_issue_comment(issue_number, "ship", 0, f"**Shipped!**\n\n{result}")

    # Publish completion
    await publish_json(js, f"hi.tasks.{team_id}.{task_id}.completed", {
        "event": "task.completed",
        "data": {
            "team_id": team_id,
            "task_id": task_id,
            "result": result,
            "status": "completed",
        },
        "timestamp": now_iso(),
    })
    await publish_log(js, "ship", f"Task completed: {result}", task_id, team_id)

    log("ship", f"{GREEN}Task complete!{NC} {result}")
    log_memory("ship")
    return task_data


# ─── Main Loop ───────────────────────────────────────────────────────────────

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

    # Ensure streams exist with retention policies to prevent unbounded growth
    stream_configs = [
        ("homeric-myrmidon", ["hi.myrmidon.>"], 3600, 50 * 1024 * 1024),
        ("homeric-tasks", ["hi.tasks.>"], 86400, 10 * 1024 * 1024),
        ("homeric-logs", ["hi.logs.>"], 3600, 20 * 1024 * 1024),
    ]
    for stream_name, subjects, max_age, max_bytes in stream_configs:
        try:
            await js.find_stream_name_by_subject(subjects[0])
            # Update retention on existing stream
            await js.add_stream(name=stream_name, subjects=subjects,
                                max_age=max_age, max_bytes=max_bytes)
            log("main", f"Updated stream {stream_name} (max_age={max_age}s, max_bytes={max_bytes})")
        except Exception:
            await js.add_stream(name=stream_name, subjects=subjects,
                                max_age=max_age, max_bytes=max_bytes)
            log("main", f"Created stream {stream_name} (max_age={max_age}s, max_bytes={max_bytes})")

    # Create pull subscriptions for each stage
    consumers = {}
    stage_subjects = [
        ("claude-planner", "hi.myrmidon.claude.*", stage_plan),
        ("claude-tester", "hi.myrmidon.claude.test.*", stage_test),
        ("claude-implementer", "hi.myrmidon.claude.implement.*", stage_implement),
        ("claude-reviewer", "hi.myrmidon.claude.review.*", stage_review),
        ("claude-shipper", "hi.myrmidon.claude.ship.*", stage_ship),
    ]

    for consumer_name, filter_subject, handler in stage_subjects:
        try:
            sub = await js.pull_subscribe(
                filter_subject,
                durable=consumer_name,
                stream=STREAM_NAME,
            )
            consumers[consumer_name] = (sub, handler)
            log("main", f"Subscribed: {consumer_name} → {filter_subject}")
        except Exception as e:
            log("main", f"{YELLOW}Consumer {consumer_name}: {e}{NC}")

    print(f"\n{BOLD}╔══════════════════════════════════════════════════════╗{NC}")
    print(f"{BOLD}║  Claude Myrmidon — Multi-Stage Pipeline Worker       ║{NC}")
    print(f"{BOLD}╠══════════════════════════════════════════════════════╣{NC}")
    print(f"{BOLD}║{NC}  NATS: {NATS_URL}")
    print(f"{BOLD}║{NC}  Mode: {'DRY-RUN' if DRY_RUN else 'LIVE'} | GitHub: {'DISABLED' if NO_GITHUB else 'ENABLED'}")
    print(f"{BOLD}║{NC}  Container: {CLAUDE_IMAGE} via {CONTAINER_RUNTIME}")
    print(f"{BOLD}║{NC}  Workspace: {WORKING_DIR} → {CONTAINER_WORKSPACE}")
    print(f"{BOLD}║{NC}  Stages: plan → test → implement → review → ship")
    print(f"{BOLD}║{NC}  Max iterations: {MAX_ITERATIONS}")
    print(f"{BOLD}╚══════════════════════════════════════════════════════╝{NC}")
    log_memory("main")
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
                    log("main", f"Received on {consumer_name}: task_id={data.get('task_id', '?')}")
                    try:
                        await handler(data, js)
                    except Exception as e:
                        log("main", f"{RED}Handler error in {consumer_name}: {e}{NC}")
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
