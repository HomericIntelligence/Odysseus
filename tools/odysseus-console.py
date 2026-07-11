#!/usr/bin/env python3
"""Odysseus Console — NATS event viewer + pipeline entry point for HomericIntelligence.

Watch mode (default) subscribes to all hi.* NATS subjects and prints events as
they arrive, providing real-time visibility into the distributed agent mesh.
Interview questions published by research myrmidons (ADR-013 §5) are surfaced
as interactive prompts; answers are published back on the answer subject.

Submit mode registers a new high-level task with Nestor
(POST /v1/research) and then drops into watch mode so the interview can begin.

Handles NATS connection gracefully: shows [DISCONNECTED] / [CONNECTED] state
instead of stack traces. Retries indefinitely until Ctrl+C.

Usage:
    python3 tools/odysseus-console.py                       # watch mode
    python3 tools/odysseus-console.py submit "IDEA TEXT" \
        [--context TEXT] [--repo OWNER/NAME] [--no-watch]

Environment:
    NATS_URL            NATS server URL (default: nats://localhost:4222)
    NATS_CLIENT_TOKEN   Client auth token (ADR-009); omit if server has no auth
    NATS_CA_FILE        CA bundle for TLS verification (ADR-008); required for
                        nats+tls:// / tls:// URLs with a private CA
    SUBJECTS            Comma-separated subjects (default: all hi.* subjects)
    NESTOR_URL          Nestor base URL (default: http://localhost:8081)
    NESTOR_API_KEY      Bearer token for Nestor, if configured
"""

import argparse
import asyncio
import json
import logging
import os
import signal
import ssl
import sys
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone

# Suppress nats-py's internal traceback logging (it prints full stack traces
# on every failed connection attempt via logging.error with exc_info=True)
logging.getLogger("nats").setLevel(logging.CRITICAL)

NATS_URL = os.environ.get("NATS_URL", "nats://localhost:4222")
NESTOR_URL = os.environ.get("NESTOR_URL", "http://localhost:8081")
DEFAULT_SUBJECTS = [
    "hi.pipeline.>",
    "hi.tasks.>",
    "hi.agents.>",
    "hi.logs.>",
    "hi.research.>",
    # Role-addressed dispatch queues (hi.myrmidon.{domain}.{role}.task.>)
    # are documented in ADR-013, resolving the issue #211 removal.
    "hi.myrmidon.>",
]

INTERVIEW_PREFIX = "hi.pipeline.interview."

RETRY_INTERVAL = 3  # seconds between initial connection attempts

# ANSI colors
COLORS = {
    "hi.tasks":     "\033[0;32m",   # green
    "hi.agents":    "\033[0;36m",   # cyan
    "hi.logs":      "\033[0;33m",   # yellow
    "hi.pipeline":  "\033[0;34m",   # blue
    "hi.research":  "\033[0;35m",   # magenta
    "hi.myrmidon":  "\033[0;31m",   # red
}
RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[1;33m"


def color_for_subject(subject: str) -> str:
    for prefix, color in COLORS.items():
        if subject.startswith(prefix):
            return color
    return ""


def format_event(subject: str, data: bytes) -> str:
    color = color_for_subject(subject)
    ts = datetime.now(timezone.utc).strftime("%H:%M:%S.%f")[:-3]

    try:
        payload = json.loads(data.decode())
        body = json.dumps(payload, separators=(",", ":"))
        if len(body) > 200:
            body = body[:197] + "..."
    except (json.JSONDecodeError, UnicodeDecodeError):
        body = data.decode(errors="replace")[:200]

    return f"{DIM}{ts}{RESET} {color}{BOLD}{subject}{RESET} {body}"


def _ts() -> str:
    return datetime.now(timezone.utc).strftime("%H:%M:%S")


# Track whether the last output was an inline status (needs \r overwrite)
_last_was_inline = False


def _term_width() -> int:
    try:
        return os.get_terminal_size().columns
    except OSError:
        return 80


def print_status(state: str, detail: str = "", inline: bool = False):
    """Print a status line. Inline=True overwrites the current line (for transient states)."""
    global _last_was_inline
    colors = {"connected": GREEN, "disconnected": RED, "reconnecting": YELLOW}
    c = colors.get(state, DIM)
    line = f"{DIM}{_ts()}{RESET} {c}{BOLD}[{state.upper()}]{RESET} {detail}"

    if inline:
        # Pad to terminal width to overwrite previous content, then \r back
        visible_len = len(f"{_ts()} [{state.upper()}] {detail}")
        padding = max(0, _term_width() - visible_len)
        print(f"\r{line}{' ' * padding}", end="", flush=True)
        _last_was_inline = True
    else:
        # If previous output was inline, move to a new line first
        if _last_was_inline:
            print(flush=True)  # newline
        print(line, flush=True)
        _last_was_inline = False


def clear_inline():
    """Emit a newline if the last status was inline, so events print cleanly."""
    global _last_was_inline
    if _last_was_inline:
        print(flush=True)
        _last_was_inline = False


def envelope(**fields) -> dict:
    """ADR-013 §3 payload envelope."""
    return {
        "schema": "hi/v1",
        "ts": datetime.now(timezone.utc).isoformat(),
        "msg_id": str(uuid.uuid4()),
        **fields,
    }


def nats_connect_kwargs() -> dict:
    """Auth/TLS connect options per ADR-008/009: token + CA-verified TLS."""
    kwargs = {}
    token = os.environ.get("NATS_CLIENT_TOKEN")
    if token:
        kwargs["token"] = token
    ca_file = os.environ.get("NATS_CA_FILE")
    if ca_file:
        ctx = ssl.create_default_context(cafile=ca_file)
        kwargs["tls"] = ctx
    return kwargs


# ── Interview panel ─────────────────────────────────────────────────────────


class InterviewPanel:
    """Surfaces interview questions as prompts and publishes answers.

    Questions arrive on hi.pipeline.interview.{intake_id}.question.{q_id};
    answers go out on hi.pipeline.interview.{intake_id}.answer.{q_id}
    (ADR-013 §5). Questions are queued so events keep streaming while the
    user types; one question is prompted at a time.
    """

    def __init__(self, nc):
        self._nc = nc
        self._queue: asyncio.Queue = asyncio.Queue()
        self._task = asyncio.create_task(self._prompt_loop())

    @staticmethod
    def parse_question_subject(subject: str):
        """Return (intake_id, q_id) for a question subject, else None."""
        if not subject.startswith(INTERVIEW_PREFIX):
            return None
        parts = subject.split(".")
        # hi.pipeline.interview.{intake_id}.question.{q_id}
        if len(parts) == 6 and parts[4] == "question":
            return parts[3], parts[5]
        return None

    def on_question(self, subject: str, data: bytes) -> bool:
        """Queue a question event. Returns True if it was an interview question."""
        parsed = self.parse_question_subject(subject)
        if parsed is None:
            return False
        try:
            payload = json.loads(data.decode())
        except (json.JSONDecodeError, UnicodeDecodeError):
            payload = {}
        if payload.get("status") == "assumed":
            # Worker proceeded with assumptions — informational, no prompt.
            return False
        self._queue.put_nowait((parsed[0], parsed[1], payload))
        return True

    async def _prompt_loop(self):
        loop = asyncio.get_running_loop()
        while True:
            intake_id, q_id, payload = await self._queue.get()
            question = payload.get("question", "(no question text)")
            clear_inline()
            print(f"\n{YELLOW}{BOLD}❓ INTERVIEW [{intake_id}/{q_id}]{RESET}")
            print(f"{YELLOW}{question}{RESET}")
            try:
                answer = await loop.run_in_executor(None, input, f"{BOLD}answer> {RESET}")
            except (EOFError, RuntimeError):
                print(f"{DIM}stdin unavailable — question left for the GitHub fallback{RESET}")
                continue
            answer = answer.strip()
            if not answer:
                print(f"{DIM}empty answer skipped — question left for the GitHub fallback{RESET}")
                continue
            subject = f"{INTERVIEW_PREFIX}{intake_id}.answer.{q_id}"
            body = envelope(
                intake_id=intake_id, q_id=q_id, answer=answer, channel="console"
            )
            try:
                await self._nc.publish(subject, json.dumps(body).encode())
                await self._nc.flush(timeout=5)
                print(f"{GREEN}✓ answer published{RESET} {DIM}{subject}{RESET}\n")
            except Exception as e:  # noqa: BLE001 - console must not crash on publish
                print(f"{RED}✗ failed to publish answer: {e}{RESET}\n")

    def stop(self):
        self._task.cancel()


# ── Submit mode ─────────────────────────────────────────────────────────────


def submit_research(idea: str, context: str = "", repo: str = "") -> dict:
    """POST the idea to Nestor's intake endpoint and return its response."""
    body = {"idea": idea}
    if context:
        body["context"] = context
    if repo:
        body["repo"] = repo

    req = urllib.request.Request(
        f"{NESTOR_URL.rstrip('/')}/v1/research",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    api_key = os.environ.get("NESTOR_API_KEY")
    if api_key:
        req.add_header("Authorization", f"Bearer {api_key}")

    ca_file = os.environ.get("NATS_CA_FILE")
    ctx = ssl.create_default_context(cafile=ca_file) if ca_file else None
    with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
        return json.loads(resp.read().decode())


# ── Watch mode ──────────────────────────────────────────────────────────────


async def watch() -> None:
    try:
        import nats as nats_mod
    except ImportError:
        print("ERROR: nats-py not installed. Run: pip install nats-py", file=sys.stderr)
        sys.exit(1)

    subjects_env = os.environ.get("SUBJECTS", "")
    subjects = subjects_env.split(",") if subjects_env else DEFAULT_SUBJECTS

    # Banner
    print(f"{BOLD}╔══════════════════════════════════════════════════╗{RESET}")
    print(f"{BOLD}║  Odysseus Console — HomericIntelligence Mesh     ║{RESET}")
    print(f"{BOLD}╠══════════════════════════════════════════════════╣{RESET}")
    print(f"{BOLD}║{RESET}  NATS: {NATS_URL}")
    print(f"{BOLD}║{RESET}  Subjects: {', '.join(subjects)}")
    print(f"{BOLD}╚══════════════════════════════════════════════════╝{RESET}")
    print()

    stop = asyncio.Event()

    def _signal_handler():
        stop.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, _signal_handler)

    # nats-py lifecycle callbacks (must be coroutines)
    async def on_disconnected():
        print_status("disconnected", NATS_URL, inline=True)

    async def on_reconnected():
        print_status("connected", f"Reconnected to {NATS_URL}")

    async def on_closed():
        print_status("disconnected", "Connection closed", inline=True)

    # Outer loop: handles initial connection failures.
    # Once connected, nats-py handles reconnection internally via callbacks.
    while not stop.is_set():
        nc = None
        panel = None
        try:
            print_status("reconnecting", f"Connecting to {NATS_URL}...", inline=True)

            # Use allow_reconnect=False so connect() fails fast on first
            # attempt. Our outer loop handles retry. Once connected, transient
            # disconnects are detected via is_connected/is_closed polling.
            nc = await asyncio.wait_for(
                nats_mod.connect(
                    NATS_URL,
                    disconnected_cb=on_disconnected,
                    reconnected_cb=on_reconnected,
                    closed_cb=on_closed,
                    allow_reconnect=False,
                    connect_timeout=3,
                    **nats_connect_kwargs(),
                ),
                timeout=5,
            )

            print_status("connected", NATS_URL)

            panel = InterviewPanel(nc)

            async def on_message(msg):
                clear_inline()
                print(format_event(msg.subject, msg.data), flush=True)
                panel.on_question(msg.subject, msg.data)

            subs = []
            for subject in subjects:
                sub = await nc.subscribe(subject, cb=on_message)
                subs.append(sub)
                color = color_for_subject(subject)
                print(f"  {color}listening{RESET} {subject}")

            print(f"\n{DIM}Waiting for events... (Ctrl+C to quit){RESET}\n")

            # Block until user quits or connection is permanently closed
            while not stop.is_set() and not nc.is_closed:
                await asyncio.sleep(0.5)

            if stop.is_set():
                # Graceful shutdown
                for sub in subs:
                    try:
                        await sub.unsubscribe()
                    except Exception:
                        pass
                try:
                    await nc.drain()
                except Exception:
                    pass
                break

            # Connection permanently closed — outer loop retries
            print_status("disconnected", "Connection lost", inline=True)

        except asyncio.TimeoutError:
            print_status("disconnected", f"Connection timed out ({NATS_URL})", inline=True)
        except Exception as e:
            # Initial connection failed — friendly message, no stack trace
            err_msg = str(e)
            if not err_msg:
                err_msg = type(e).__name__
            print_status("disconnected", err_msg, inline=True)

            # Clean up partial connection
            if nc is not None:
                try:
                    await nc.close()
                except Exception:
                    pass
        finally:
            if panel is not None:
                panel.stop()

        # Wait before retrying, but stop immediately on Ctrl+C
        if not stop.is_set():
            print_status("reconnecting", f"Retrying in {RETRY_INTERVAL}s...", inline=True)
            try:
                await asyncio.wait_for(stop.wait(), timeout=RETRY_INTERVAL)
            except asyncio.TimeoutError:
                pass

    clear_inline()
    print(f"\n{DIM}Disconnected.{RESET}")


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="odysseus-console",
        description="NATS event viewer + pipeline entry point for HomericIntelligence.",
    )
    sub = parser.add_subparsers(dest="command")

    p_submit = sub.add_parser(
        "submit", help="Submit a high-level task to Nestor (POST /v1/research)"
    )
    p_submit.add_argument("idea", help="High-level task / idea text")
    p_submit.add_argument("--context", default="", help="Extra context for the researcher")
    p_submit.add_argument("--repo", default="", help="Target repo (OWNER/NAME), if known")
    p_submit.add_argument(
        "--no-watch",
        action="store_true",
        help="Exit after submitting instead of dropping into watch mode",
    )

    return parser.parse_args(argv)


def main() -> None:
    args = parse_args(sys.argv[1:])

    if args.command == "submit":
        try:
            result = submit_research(args.idea, args.context, args.repo)
        except urllib.error.HTTPError as e:
            print(f"{RED}✗ Nestor rejected the submission: HTTP {e.code}{RESET}", file=sys.stderr)
            sys.exit(1)
        except urllib.error.URLError as e:
            print(f"{RED}✗ Nestor unreachable at {NESTOR_URL}: {e.reason}{RESET}", file=sys.stderr)
            sys.exit(1)
        research_id = result.get("id", "?")
        print(f"{GREEN}✓ submitted{RESET} research_id={BOLD}{research_id}{RESET}")
        print(f"{DIM}dispatch: hi.myrmidon.research.chief-architect.task.{research_id}{RESET}")
        if args.no_watch:
            return
        print(f"{DIM}Entering watch mode for the interview... (Ctrl+C to quit){RESET}\n")

    asyncio.run(watch())


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
