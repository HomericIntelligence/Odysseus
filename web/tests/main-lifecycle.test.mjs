import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import * as fs from "node:fs/promises";
import { createServer } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";

const root = fileURLToPath(new URL("../../", import.meta.url));
const observation = (sequence) => ({
  source: "keystone",
  target: "hephaestus",
  operation: "deliver",
  eventId: `shutdown-${sequence}`,
  sourceId: "shutdown-fixture",
  sourceSequence: sequence,
  observedAt: new Date().toISOString(),
});

async function until(predicate, message, timeout = 4000) {
  const deadline = performance.now() + timeout;
  while (performance.now() < deadline) {
    if (await predicate()) return;
    await delay(10);
  }
  assert.fail(message);
}

async function fixture(t) {
  const parent = join(
    await fs.realpath(homedir()),
    ".cache",
    "odysseus-history-tests",
  );
  await fs.mkdir(parent, { recursive: true, mode: 0o700 });
  const directory = await fs.mkdtemp(join(parent, "shutdown-"));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const listener = createServer();
  listener.listen(0, "127.0.0.1");
  await once(listener, "listening");
  const port = listener.address().port;
  await new Promise((resolve) => listener.close(resolve));
  return {
    directory,
    port,
    cache: join(directory, `observations-${port}.json`),
  };
}

function backend(t, { directory, port }, { holdSync = false, natsUrl } = {}) {
  const env = Object.fromEntries(
    Object.entries(process.env).filter(
      ([key]) =>
        !key.startsWith("ODYSSEUS_") &&
        !["AGAMEMNON_API_KEY", "NESTOR_AUTH_TOKEN"].includes(key),
    ),
  );
  const child = spawn(
    process.execPath,
    [
      ...(holdSync
        ? ["--import", "./web/tests/fixtures/hold-history-sync.mjs"]
        : []),
      "web/server/main.mjs",
      "--flow-stdin",
    ],
    {
      cwd: root,
      env: {
        ...env,
        ODYSSEUS_WEB_PORT: String(port),
        ODYSSEUS_OBSERVATION_HISTORY_DIR: directory,
        ...(natsUrl
          ? { ODYSSEUS_NATS_URL: natsUrl, ODYSSEUS_NATS_ALLOW_LOCAL: "1" }
          : {}),
      },
      stdio: ["pipe", "pipe", "pipe", "ipc"],
    },
  );
  let output = "";
  let syncBlocked = false;
  child.stdout.on("data", (chunk) => {
    output += chunk;
  });
  child.stderr.on("data", (chunk) => {
    output += chunk;
  });
  child.on("message", (message) => {
    if (message.type === "history-sync-blocked") syncBlocked = true;
  });
  const exited = once(child, "exit");
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null)
      child.kill("SIGKILL");
    await exited;
  });
  const response = () =>
    fetch(`http://127.0.0.1:${port}/api/snapshot`, {
      signal: AbortSignal.timeout(1000),
    });
  const snapshot = async () => {
    const result = await response();
    assert.equal(result.status, 200);
    return result.json();
  };
  return {
    child,
    exited,
    response,
    snapshot,
    output: () => output,
    ready: () =>
      until(() => {
        assert.equal(child.exitCode, null, output);
        assert.equal(child.signalCode, null, output);
        return output.includes("Odysseus Fleet:");
      }, "Backend did not become ready"),
    blocked: () =>
      until(() => {
        assert.equal(
          child.signalCode,
          null,
          "Graceful shutdown was bypassed by a signal",
        );
        return syncBlocked;
      }, "History write did not reach sync"),
    observe: (sequence) =>
      child.stdin.write(
        JSON.stringify({
          type: "observation",
          observation: observation(sequence),
        }) + "\n",
      ),
    release: () => child.send({ type: "release-history-sync" }),
  };
}

async function assertStopping(first) {
  await until(
    async () => {
      assert.equal(
        first.child.signalCode,
        null,
        "Signal bypassed graceful shutdown",
      );
      try {
        return (await first.response()).status === 503;
      } catch {
        return false;
      }
    },
    "Retiring backend must retain its listener and reject HTTP intake",
    1500,
  );
}

async function assertLease(t, settings) {
  const second = backend(t, settings);
  assert.deepEqual(await second.exited, [1, null]);
  assert.match(second.output(), /EADDRINUSE/);
}

test(
  "shutdown retains the port lease until the final history sync completes",
  { timeout: 15000 },
  async (t) => {
    const settings = await fixture(t);
    const first = backend(t, settings, { holdSync: true });
    await first.ready();
    first.observe(1);
    await first.blocked();
    assert.equal((await first.snapshot()).observations.length, 1);
    const temporary = await fs.readFile(settings.cache + ".tmp");
    first.child.kill("SIGTERM");
    await assertStopping(first);
    await assertLease(t, settings);
    assert.deepEqual(await fs.readFile(settings.cache + ".tmp"), temporary);
    first.observe(2);
    first.release();
    assert.deepEqual(await first.exited, [0, null]);
    const second = backend(t, settings);
    await second.ready();
    const restored = await second.snapshot();
    assert.equal(restored.observations.length, 1);
    assert.equal(restored.observations[0].eventId, "shutdown-1");
    assert.equal(restored.observations[0].origin, "restored");
    assert.equal(restored.history.persistedSequence, 1);
  },
);

test(
  "shutdown releases the port after five seconds and fences a late history sync",
  { timeout: 15000 },
  async (t) => {
    const settings = await fixture(t);
    const first = backend(t, settings, { holdSync: true });
    await first.ready();
    first.observe(1);
    await first.blocked();
    first.child.kill("SIGTERM");
    const stoppedAt = performance.now();
    await assertStopping(first);
    await assertLease(t, settings);
    await until(
      () => first.output().includes("shutdown flush was not confirmed"),
      "Five-second flush deadline did not release the writer",
      6500,
    );
    assert.ok(performance.now() - stoppedAt >= 4900);
    const temporary = await fs.readFile(settings.cache + ".tmp");
    const second = backend(t, settings);
    await second.ready();
    const restored = await second.snapshot();
    assert.equal(restored.observations.length, 0);
    assert.equal(restored.history.reason, "recovery_required");
    first.release();
    assert.deepEqual(await first.exited, [0, null]);
    await assert.rejects(fs.stat(settings.cache), { code: "ENOENT" });
    assert.deepEqual(await fs.readFile(settings.cache + ".tmp"), temporary);
  },
);

async function pendingNats(t) {
  const sockets = new Set();
  let commands = "";
  const server = createServer((socket) => {
    sockets.add(socket);
    socket.on("error", () => {});
    socket.on("data", (chunk) => {
      commands += chunk;
    });
    socket.on("close", () => sockets.delete(socket));
    socket.write(
      'INFO {"server_id":"fixture","version":"2.10.0","proto":1,"max_payload":1048576}\r\n',
    );
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(async () => {
    for (const socket of sockets) socket.destroy();
    await new Promise((resolve) => server.close(resolve));
  });
  return {
    url: `nats://127.0.0.1:${server.address().port}`,
    pending: () =>
      until(() => commands.includes("PING"), "NATS handshake was not pending"),
    complete: () => {
      for (const socket of sockets) socket.write("PONG\r\n");
    },
    disconnected: () =>
      until(() => sockets.size === 0, "Late NATS connection was not closed"),
    commands: () => commands,
  };
}

test(
  "shutdown during pending NATS setup flushes intake and rejects a late attachment",
  { timeout: 15000 },
  async (t) => {
    const settings = await fixture(t);
    const nats = await pendingNats(t);
    const first = backend(t, settings, { holdSync: true, natsUrl: nats.url });
    await first.ready();
    await nats.pending();
    first.observe(1);
    await until(
      async () => (await first.snapshot()).observations.length === 1,
      "Observation was not accepted during NATS setup",
    );
    first.child.kill("SIGTERM");
    await first.blocked();
    await assertStopping(first);
    nats.complete();
    await nats.disconnected();
    assert.doesNotMatch(
      nats.commands(),
      /SUB /,
      "A late connection must not reopen observation intake",
    );
    first.release();
    assert.deepEqual(await first.exited, [0, null]);
    const second = backend(t, settings);
    await second.ready();
    const restored = await second.snapshot();
    assert.equal(restored.observations.length, 1);
    assert.equal(restored.observations[0].eventId, "shutdown-1");
    assert.equal(restored.history.persistedSequence, 1);
  },
);
