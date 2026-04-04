"""NATS-to-Loki bridge for HomericIntelligence structured logging.

Subscribes to hi.logs.> on NATS JetStream and pushes log entries
to Loki's HTTP API for centralized log aggregation in Grafana.
"""

import asyncio
import json
import os
import signal
import sys
import time
from urllib.request import Request, urlopen

import nats


NATS_URL = os.environ.get("NATS_URL", "nats://localhost:4222")
LOKI_URL = os.environ.get("LOKI_URL", "http://localhost:3100")
SUBJECT = "hi.logs.>"
STREAM = "homeric-logs"
CONSUMER = "loki-bridge"
BATCH_SIZE = 50
FLUSH_INTERVAL = 2.0  # seconds


def push_to_loki(entries: list[dict]) -> None:
    """Push a batch of log entries to Loki's push API."""
    if not entries:
        return

    # Group entries by service label for Loki streams
    streams: dict[str, list] = {}
    for entry in entries:
        service = entry.get("service", "unknown")
        key = service
        if key not in streams:
            streams[key] = []
        ts_ns = str(int(entry.get("timestamp", time.time()) * 1e9))
        line = json.dumps(entry)
        streams[key].append([ts_ns, line])

    payload = {
        "streams": [
            {
                "stream": {"job": "nats-logs", "service": svc},
                "values": values,
            }
            for svc, values in streams.items()
        ]
    }

    req = Request(
        f"{LOKI_URL}/loki/api/v1/push",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        urlopen(req, timeout=5)
    except Exception as exc:
        print(f"[nats-loki-bridge] push error: {exc}", file=sys.stderr, flush=True)


async def main() -> None:
    nc = await nats.connect(NATS_URL)
    js = nc.jetstream()
    print(f"[nats-loki-bridge] connected to NATS at {NATS_URL}", flush=True)

    # Ensure the stream exists
    try:
        await js.find_stream_name_by_subject("hi.logs.>")
    except Exception:
        await js.add_stream(name=STREAM, subjects=["hi.logs.>"])
        print(f"[nats-loki-bridge] created stream {STREAM}", flush=True)

    # Create a durable pull subscription
    sub = await js.pull_subscribe(SUBJECT, CONSUMER, stream=STREAM)
    print(f"[nats-loki-bridge] subscribed to {SUBJECT} (consumer={CONSUMER})", flush=True)

    stop = asyncio.Event()

    def _signal_handler():
        print("[nats-loki-bridge] shutting down...", flush=True)
        stop.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, _signal_handler)

    batch: list[dict] = []
    last_flush = time.monotonic()

    while not stop.is_set():
        try:
            msgs = await sub.fetch(BATCH_SIZE, timeout=FLUSH_INTERVAL)
            for msg in msgs:
                try:
                    entry = json.loads(msg.data.decode())
                    # Inject NATS subject as metadata
                    entry.setdefault("nats_subject", msg.subject)
                    batch.append(entry)
                except json.JSONDecodeError:
                    batch.append({
                        "service": "unknown",
                        "message": msg.data.decode(),
                        "nats_subject": msg.subject,
                        "timestamp": time.time(),
                    })
                await msg.ack()
        except nats.errors.TimeoutError:
            pass
        except Exception as exc:
            print(f"[nats-loki-bridge] fetch error: {exc}", file=sys.stderr, flush=True)
            await asyncio.sleep(1)

        now = time.monotonic()
        if batch and (len(batch) >= BATCH_SIZE or now - last_flush >= FLUSH_INTERVAL):
            push_to_loki(batch)
            print(f"[nats-loki-bridge] flushed {len(batch)} entries to Loki", flush=True)
            batch = []
            last_flush = now

    # Flush remaining
    if batch:
        push_to_loki(batch)

    await nc.drain()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
