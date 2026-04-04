#!/usr/bin/env python3
"""Odysseus Console — Real-time NATS event viewer for HomericIntelligence.

Subscribes to all hi.* NATS subjects and prints events as they arrive,
providing real-time visibility into the distributed agent mesh.

Usage:
    NATS_URL=nats://100.92.173.32:4222 python3 tools/odysseus-console.py

Environment:
    NATS_URL    NATS server URL (default: nats://localhost:4222)
    SUBJECTS    Comma-separated subjects (default: all hi.* subjects)
"""

import asyncio
import json
import os
import signal
import sys
from datetime import datetime, timezone


NATS_URL = os.environ.get("NATS_URL", "nats://localhost:4222")
DEFAULT_SUBJECTS = [
    "hi.pipeline.>",
    "hi.tasks.>",
    "hi.agents.>",
    "hi.logs.>",
    "hi.research.>",
    "hi.myrmidon.>",
]

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
        # Compact JSON, max 200 chars
        body = json.dumps(payload, separators=(",", ":"))
        if len(body) > 200:
            body = body[:197] + "..."
    except (json.JSONDecodeError, UnicodeDecodeError):
        body = data.decode(errors="replace")[:200]

    return f"{DIM}{ts}{RESET} {color}{BOLD}{subject}{RESET} {body}"


async def main() -> None:
    try:
        import nats as nats_mod
    except ImportError:
        print("ERROR: nats-py not installed. Run: pip install nats-py", file=sys.stderr)
        sys.exit(1)

    subjects_env = os.environ.get("SUBJECTS", "")
    subjects = subjects_env.split(",") if subjects_env else DEFAULT_SUBJECTS

    nc = await nats_mod.connect(NATS_URL)

    print(f"{BOLD}╔══════════════════════════════════════════════════╗{RESET}")
    print(f"{BOLD}║  Odysseus Console — HomericIntelligence Mesh     ║{RESET}")
    print(f"{BOLD}╠═════��════════════════════════════════════════════╣{RESET}")
    print(f"{BOLD}║{RESET}  NATS: {NATS_URL}")
    print(f"{BOLD}║{RESET}  Subjects: {', '.join(subjects)}")
    print(f"{BOLD}╚════════���═════════════════════════��═══════════════╝{RESET}")
    print()

    async def on_message(msg):
        print(format_event(msg.subject, msg.data), flush=True)

    subs = []
    for subject in subjects:
        sub = await nc.subscribe(subject, cb=on_message)
        subs.append(sub)
        color = color_for_subject(subject)
        print(f"  {color}listening{RESET} {subject}")

    print(f"\n{DIM}Waiting for events... (Ctrl+C to quit){RESET}\n")

    stop = asyncio.Event()

    def _signal_handler():
        stop.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, _signal_handler)

    await stop.wait()

    for sub in subs:
        await sub.unsubscribe()
    await nc.drain()
    print(f"\n{DIM}Disconnected.{RESET}")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
