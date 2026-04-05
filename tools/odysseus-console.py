#!/usr/bin/env python3
"""Odysseus Console — Real-time NATS event viewer for HomericIntelligence.

Subscribes to all hi.* NATS subjects and prints events as they arrive,
providing real-time visibility into the distributed agent mesh.

Handles NATS connection gracefully: shows [DISCONNECTED] / [CONNECTED] state
instead of stack traces. Retries indefinitely until Ctrl+C.

Usage:
    NATS_URL=nats://100.92.173.32:4222 python3 tools/odysseus-console.py

Environment:
    NATS_URL    NATS server URL (default: nats://localhost:4222)
    SUBJECTS    Comma-separated subjects (default: all hi.* subjects)
"""

import asyncio
import json
import logging
import os
import signal
import sys
from datetime import datetime, timezone

# Suppress nats-py's internal traceback logging (it prints full stack traces
# on every failed connection attempt via logging.error with exc_info=True)
logging.getLogger("nats").setLevel(logging.CRITICAL)

NATS_URL = os.environ.get("NATS_URL", "nats://localhost:4222")
DEFAULT_SUBJECTS = [
    "hi.pipeline.>",
    "hi.tasks.>",
    "hi.agents.>",
    "hi.logs.>",
    "hi.research.>",
    "hi.myrmidon.>",
]

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


def print_status(state: str, detail: str = ""):
    colors = {"connected": GREEN, "disconnected": RED, "reconnecting": YELLOW}
    c = colors.get(state, DIM)
    print(f"{DIM}{_ts()}{RESET} {c}{BOLD}[{state.upper()}]{RESET} {detail}", flush=True)


async def main() -> None:
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
        print_status("disconnected", NATS_URL)

    async def on_reconnected():
        print_status("connected", f"Reconnected to {NATS_URL}")

    async def on_closed():
        print_status("disconnected", "Connection closed")

    async def on_message(msg):
        print(format_event(msg.subject, msg.data), flush=True)

    # Outer loop: handles initial connection failures.
    # Once connected, nats-py handles reconnection internally via callbacks.
    while not stop.is_set():
        nc = None
        try:
            print_status("reconnecting", f"Connecting to {NATS_URL}...")

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
                ),
                timeout=5,
            )

            print_status("connected", NATS_URL)

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
            print_status("disconnected", "Connection lost")

        except asyncio.TimeoutError:
            print_status("disconnected", f"Connection timed out ({NATS_URL})")
        except Exception as e:
            # Initial connection failed — friendly message, no stack trace
            err_msg = str(e)
            if not err_msg:
                err_msg = type(e).__name__
            print_status("disconnected", err_msg)

            # Clean up partial connection
            if nc is not None:
                try:
                    await nc.close()
                except Exception:
                    pass

        # Wait before retrying, but stop immediately on Ctrl+C
        if not stop.is_set():
            print_status("reconnecting", f"Retrying in {RETRY_INTERVAL}s...")
            try:
                await asyncio.wait_for(stop.wait(), timeout=RETRY_INTERVAL)
            except asyncio.TimeoutError:
                pass

    print(f"\n{DIM}Disconnected.{RESET}")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
