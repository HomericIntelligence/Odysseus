import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdir, mkdtemp, realpath, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
import * as fs from "node:fs/promises";
import { FleetView } from "../server/view.mjs";
import { openObservationHistory } from "../server/observation-history.mjs";

const root = fileURLToPath(new URL("../../", import.meta.url));

const event = (index) => ({
  source: "keystone",
  target: "hephaestus",
  operation: "deliver",
  eventId: `fixture-${index}`,
  sourceId: "fixture-source",
  sourceSequence: index,
  observedAt: "2026-09-20T12:00:00.000Z",
});

async function historyFixture(t, options = {}) {
  const parent = join(
    await realpath(homedir()),
    ".cache",
    "odysseus-history-tests",
  );
  await mkdir(parent, { recursive: true, mode: 0o700 });
  const directory = await mkdtemp(join(parent, "file-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const view = new FleetView({ historyLimit: 250 });
  const settings = {
    view,
    directory,
    port: 9876,
    sourceRoot: root,
    ...options,
  };
  const history = await openObservationHistory(settings);
  t.after(() => history.close());
  return {
    view,
    history,
    settings,
    directory,
    file: join(directory, "observations-9876.json"),
  };
}

test("history writer preserves a committed member replaced after startup", async (t) => {
  const fixture = await historyFixture(t);
  fixture.view.observe(event(1));
  assert.equal(await fixture.history.close(), true);
  const view = new FleetView({ historyLimit: 250 });
  const history = await openObservationHistory({ ...fixture.settings, view });
  t.after(() => history.close());
  const replaced = fixture.file + ".operator";
  await fs.writeFile(replaced, "operator replacement must survive", {
    mode: 0o600,
  });
  await fs.rename(replaced, fixture.file);
  view.observe(event(2));
  assert.equal(await history.close(), false);
  assert.equal(
    await fs.readFile(fixture.file, "utf8"),
    "operator replacement must survive",
  );
  assert.equal(view.snapshot().history.status, "unavailable");
  assert.equal(view.snapshot().history.persistedSequence, 1);
});

test("failed writes retain an explicit pending gap after the active write ends", async (t) => {
  const fixture = await historyFixture(t, {
    io: {
      ...fs,
      rename: async () => {
        throw new Error("fixture rename failure");
      },
    },
  });
  fixture.view.observe(event(1));
  assert.equal(await fixture.history.close(), false);
  assert.equal(fixture.view.snapshot().history.pending, true);
  assert.equal(fixture.view.snapshot().observations.length, 1);
  assert.equal(fixture.view.snapshot().history.persistedSequence, undefined);
});

test("a replaced temporary member cannot replace the committed archive", async (t) => {
  const fixture = await historyFixture(t);
  fixture.view.observe(event(1));
  await fixture.history.close();
  const committed = await fs.readFile(fixture.file);
  const view = new FleetView();
  const io = {
    ...fs,
    open: async (path, ...args) => {
      const handle = await fs.open(path, ...args);
      if (path.endsWith(".tmp")) {
        const close = handle.close.bind(handle);
        handle.close = async () => {
          await close();
          await fs.rename(path, path + ".interrupted");
          await fs.writeFile(path, "unowned temporary bytes", { mode: 0o600 });
        };
      }
      return handle;
    },
  };
  const history = await openObservationHistory({
    ...fixture.settings,
    view,
    io,
  });
  view.observe(event(2));
  assert.equal(await history.close(), false);
  assert.deepEqual(await fs.readFile(fixture.file), committed);
  assert.equal(
    await fs.readFile(fixture.file + ".tmp", "utf8"),
    "unowned temporary bytes",
  );
});

test("large live views export a bounded consistent restart history", () => {
  const view = new FleetView({ historyLimit: 2000 });
  for (let index = 1; index <= 1500; index++) view.observe(event(index));
  const history = view.exportHistory();
  assert.equal(view.snapshot().observations.length, 1500);
  assert.equal(history.observations.length, 250);
  assert.equal(history.observations[0].sequence, 1251);
  assert.equal(history.sequence, 1500);
  assert.equal(history.dropped, 1250);
  assert.ok(history.seen.length <= 1000);
});

test("replacement after rename cannot receive another file's persistence receipt", async (t) => {
  const fixture = await historyFixture(t);
  fixture.view.observe(event(1));
  await fixture.history.close();
  const view = new FleetView();
  const history = await openObservationHistory({
    ...fixture.settings,
    view,
    io: {
      ...fs,
      open: async (path, ...args) => {
        const handle = await fs.open(path, ...args);
        if (path === fixture.directory) {
          const sync = handle.sync.bind(handle);
          handle.sync = async () => {
            await sync();
            const replacement = fixture.file + ".replacement";
            await fs.writeFile(replacement, "operator replacement", {
              mode: 0o600,
            });
            await fs.rename(replacement, fixture.file);
          };
        }
        return handle;
      },
    },
  });
  view.observe(event(2));
  assert.equal(await history.close(), false);
  assert.equal(view.history.persistedSequence, 1);
  assert.equal(view.history.reason, "directory_sync_uncertain");
  assert.equal(await fs.readFile(fixture.file, "utf8"), "operator replacement");
});

test("invalid cache files remain unchanged and report unavailable history", async (t) => {
  const cases = {
    malformed: async (file) => fs.writeFile(file, "{broken"),
    duplicate: async (file, bytes) =>
      fs.writeFile(
        file,
        bytes.replace('"schema":', '"schema":"duplicate","schema":'),
      ),
    unsupported: async (file, bytes) =>
      fs.writeFile(
        file,
        bytes.replace("observation-history/v1", "observation-history/v2"),
      ),
    unknown: async (file, bytes) =>
      fs.writeFile(
        file,
        bytes.replace('"data":{', '"data":{"prompt":"private",'),
      ),
    unsafeInteger: async (file, bytes) =>
      fs.writeFile(
        file,
        bytes.replace('"sequence":1', '"sequence":9007199254740992'),
      ),
    utf8: async (file) => fs.writeFile(file, Buffer.from([0xff])),
    oversized: async (file) =>
      fs.writeFile(file, Buffer.alloc(4 * 1024 * 1024 + 1)),
    permissions: async (file) => fs.chmod(file, 0o644),
    directory: async (file) => {
      await fs.unlink(file);
      await fs.mkdir(file);
    },
    symlink: async (file) => {
      await fs.rename(file, file + ".other");
      await fs.symlink(file + ".other", file);
    },
    hardlink: async (file) => fs.link(file, file + ".other"),
  };
  for (const [name, change] of Object.entries(cases))
    await t.test(name, async (t) => {
      const fixture = await historyFixture(t);
      fixture.view.observe(event(1));
      await fixture.history.close();
      await change(fixture.file, await fs.readFile(fixture.file, "utf8"));
      const before = await fs.lstat(fixture.file);
      const bytes = before.isFile() ? await fs.readFile(fixture.file) : null;
      const view = new FleetView();
      const history = await openObservationHistory({
        ...fixture.settings,
        view,
      });
      view.observe(event(2));
      assert.equal(await history.close(), false);
      assert.equal(view.snapshot().history.status, "unavailable");
      assert.equal(view.snapshot().observations.length, 1);
      assert.equal((await fs.lstat(fixture.file)).ino, before.ino);
      if (bytes) assert.deepEqual(await fs.readFile(fixture.file), bytes);
    });
});

test("uncertain temporary member restores the committed cache read-only", async (t) => {
  const fixture = await historyFixture(t);
  fixture.view.observe(event(1));
  await fixture.history.close();
  const before = await fs.readFile(fixture.file);
  await fs.writeFile(fixture.file + ".tmp", "uncertain bytes", { mode: 0o600 });
  const view = new FleetView();
  const history = await openObservationHistory({ ...fixture.settings, view });
  assert.equal(view.snapshot().observations[0].origin, "restored");
  assert.equal(view.snapshot().history.reason, "recovery_required");
  view.observe(event(2));
  assert.equal(await history.close(), false);
  assert.deepEqual(await fs.readFile(fixture.file), before);
  assert.equal(
    await fs.readFile(fixture.file + ".tmp", "utf8"),
    "uncertain bytes",
  );
});

test("writer failures preserve usable bytes and never confirm a newer sequence", async (t) => {
  for (const phase of ["open", "write", "sync", "rename", "directory-sync"])
    await t.test(phase, async (t) => {
      const fixture = await historyFixture(t);
      fixture.view.observe(event(1));
      await fixture.history.close();
      const before = await fs.readFile(fixture.file);
      const fault = () => {
        throw new Error(`controlled ${phase} failure`);
      };
      const io = {
        ...fs,
        rename: phase === "rename" ? fault : fs.rename,
        open: async (path, ...args) => {
          if (phase === "open" && path.endsWith(".tmp")) fault();
          const handle = await fs.open(path, ...args);
          if (path.endsWith(".tmp") && phase === "write")
            handle.writeFile = fault;
          if (
            (path.endsWith(".tmp") && phase === "sync") ||
            (path === fixture.directory && phase === "directory-sync")
          )
            handle.sync = fault;
          return handle;
        },
      };
      const view = new FleetView();
      const history = await openObservationHistory({
        ...fixture.settings,
        view,
        io,
      });
      view.observe(event(2));
      assert.equal(await history.close(), false);
      assert.equal(view.snapshot().history.persistedSequence, 1);
      assert.equal(view.snapshot().history.pending, true);
      assert.equal(view.snapshot().observations.length, 2);
      const after = await fs.readFile(fixture.file);
      if (phase !== "directory-sync") assert.deepEqual(after, before);
      else {
        assert.equal(JSON.parse(after).data.sequence, 2);
        assert.equal(
          view.snapshot().history.reason,
          "directory_sync_uncertain",
        );
      }
    });
});

test("shutdown timeout keeps uncertainty when the filesystem completes later", async (t) => {
  const started = Promise.withResolvers();
  const release = Promise.withResolvers();
  const finished = Promise.withResolvers();
  const fixture = await historyFixture(t, {
    io: {
      ...fs,
      open: async (path, ...args) => {
        const handle = await fs.open(path, ...args);
        if (path.endsWith(".tmp")) {
          const originalSync = handle.sync.bind(handle);
          handle.sync = async () => {
            started.resolve();
            await release.promise;
            await originalSync();
            finished.resolve();
          };
        }
        return handle;
      },
    },
  });
  fixture.view.observe(event(1));
  const closing = fixture.history.close(20);
  await started.promise;
  assert.equal(await closing, false);
  assert.equal(
    fixture.view.snapshot().history.reason,
    "shutdown_flush_uncertain",
  );
  assert.equal(fixture.view.snapshot().history.pending, true);
  release.resolve();
  await finished.promise;
  await fixture.history.close();
  assert.equal(
    fixture.view.snapshot().history.reason,
    "shutdown_flush_uncertain",
  );
  assert.equal(fixture.view.snapshot().history.persistedSequence, undefined);
  assert.equal(fixture.view.snapshot().history.pending, true);
  await assert.rejects(fs.readFile(fixture.file), { code: "ENOENT" });
});

test("shutdown does not start a later write phase after a delayed open completes", async (t) => {
  const opened = Promise.withResolvers();
  const release = Promise.withResolvers();
  const releasedHandle = Promise.withResolvers();
  let writes = 0;
  const fixture = await historyFixture(t, {
    io: {
      ...fs,
      open: async (path, ...args) => {
        const handle = await fs.open(path, ...args);
        if (path.endsWith(".tmp")) {
          const originalWrite = handle.writeFile.bind(handle);
          const originalClose = handle.close.bind(handle);
          handle.writeFile = async (...values) => {
            writes++;
            return originalWrite(...values);
          };
          handle.close = async () => {
            await originalClose();
            releasedHandle.resolve();
          };
          opened.resolve();
          await release.promise;
        }
        return handle;
      },
    },
  });
  fixture.view.observe(event(1));
  const closing = fixture.history.close(20);
  await opened.promise;
  assert.equal(await closing, false);
  release.resolve();
  await releasedHandle.promise;
  assert.equal(writes, 0);
  assert.equal((await fs.stat(fixture.file + ".tmp")).size, 0);
  assert.equal(fixture.view.snapshot().history.persistedSequence, undefined);
});

test("late final metadata cannot turn a timed-out flush into confirmed persistence", async (t) => {
  const checking = Promise.withResolvers();
  const release = Promise.withResolvers();
  const returned = Promise.withResolvers();
  let renamed = false;
  const fixture = await historyFixture(t, {
    io: {
      ...fs,
      rename: async (...args) => {
        await fs.rename(...args);
        renamed = true;
      },
      lstat: async (path, ...args) => {
        const info = await fs.lstat(path, ...args);
        if (renamed && path.endsWith(".json")) {
          checking.resolve();
          await release.promise;
          returned.resolve();
        }
        return info;
      },
    },
  });
  fixture.view.observe(event(1));
  const closing = fixture.history.close(20);
  await checking.promise;
  assert.equal(await closing, false);
  release.resolve();
  await returned.promise;
  await fixture.history.close();
  assert.equal(fixture.view.snapshot().history.persistedSequence, undefined);
  assert.equal(
    fixture.view.snapshot().history.reason,
    "shutdown_flush_uncertain",
  );
  assert.equal(fixture.view.snapshot().history.status, "unavailable");
});

test("one active write coalesces subsequent observations to one latest snapshot", async (t) => {
  const started = Promise.withResolvers();
  const release = Promise.withResolvers();
  let writes = 0;
  const fixture = await historyFixture(t, {
    coalesceMs: 0,
    io: {
      ...fs,
      open: async (path, ...args) => {
        const handle = await fs.open(path, ...args);
        if (path.endsWith(".tmp")) {
          writes++;
          if (writes === 1) {
            const sync = handle.sync.bind(handle);
            handle.sync = async () => {
              started.resolve();
              await release.promise;
              await sync();
            };
          }
        }
        return handle;
      },
    },
  });
  fixture.view.observe(event(1));
  await started.promise;
  for (let index = 2; index <= 500; index++) fixture.view.observe(event(index));
  assert.equal(writes, 1);
  release.resolve();
  assert.equal(await fixture.history.close(), true);
  assert.equal(writes, 2);
  const cached = JSON.parse(await fs.readFile(fixture.file, "utf8"));
  assert.equal(cached.data.sequence, 500);
  assert.equal(cached.data.observations.length, 250);
  assert.equal(cached.data.dropped, 250);
  assert.equal(fixture.view.snapshot().history.pending, false);
});

test("byte retention remains bounded with explicit omission and valid restore", async (t) => {
  const fixture = await historyFixture(t, { maxBytes: 1200 });
  for (let index = 1; index <= 30; index++) fixture.view.observe(event(index));
  assert.equal(await fixture.history.close(), true);
  assert.ok((await fs.stat(fixture.file)).size <= 1200);
  assert.ok(fixture.view.snapshot().history.omitted > 0);
  const restored = new FleetView();
  const history = await openObservationHistory({
    ...fixture.settings,
    view: restored,
  });
  assert.equal(restored.snapshot().history.status, "restored");
  assert.ok(restored.snapshot().dropped > 0);
  assert.ok(restored.snapshot().coverageLosses > 0);
  assert.equal(await history.close(), true);
});

test(
  "a process interrupted before replacement restores only the committed prefix",
  { timeout: 10000 },
  async (t) => {
    const fixture = await historyFixture(t);
    fixture.view.observe(event(1));
    await fixture.history.close();
    const before = await fs.readFile(fixture.file);
    const script = `
    import * as fs from 'node:fs/promises';
    import { FleetView } from './web/server/view.mjs';
    import { openObservationHistory } from './web/server/observation-history.mjs';
    const view = new FleetView({ historyLimit: 250 });
    const history = await openObservationHistory({ view, directory: process.argv[1],
      sourceRoot: process.cwd(), port: 9876, io: { ...fs, rename: async () => {
        process.stdout.write('before-replace\\n');
        await new Promise(() => {});
      } } });
    view.observe(JSON.parse(process.argv[2]));
    await history.close();
  `;
    const child = spawn(
      process.execPath,
      [
        "--input-type=module",
        "-e",
        script,
        fixture.directory,
        JSON.stringify(event(2)),
      ],
      { cwd: root, stdio: ["ignore", "pipe", "pipe"] },
    );
    const exited = once(child, "exit");
    t.after(async () => {
      if (child.exitCode === null && child.signalCode === null)
        child.kill("SIGKILL");
      await exited;
    });
    const ready = once(child.stdout, "data");
    const timer = setTimeout(() => child.kill("SIGKILL"), 5000);
    try {
      const [data] = await Promise.race([
        ready,
        exited.then(() => {
          throw new Error("Child stopped before replacement boundary");
        }),
      ]);
      assert.match(String(data), /before-replace/);
      child.kill("SIGKILL");
      await exited;
    } finally {
      clearTimeout(timer);
    }
    assert.deepEqual(await fs.readFile(fixture.file), before);
    assert.ok((await fs.stat(fixture.file + ".tmp")).size > 0);
    const view = new FleetView();
    const history = await openObservationHistory({ ...fixture.settings, view });
    assert.equal(view.snapshot().observations.length, 1);
    assert.equal(view.snapshot().observations[0].sequence, 1);
    assert.equal(view.snapshot().history.reason, "recovery_required");
    assert.equal(await history.close(), false);
  },
);

async function availablePort() {
  const server = createServer();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function startBackend(port, directory) {
  const env = Object.fromEntries(
    Object.entries(process.env).filter(
      ([key]) =>
        !key.startsWith("ODYSSEUS_") &&
        !["AGAMEMNON_API_KEY", "NESTOR_AUTH_TOKEN"].includes(key),
    ),
  );
  const child = spawn(
    process.execPath,
    ["web/server/main.mjs", "--flow-stdin"],
    {
      cwd: root,
      env: {
        ...env,
        ODYSSEUS_WEB_PORT: String(port),
        ODYSSEUS_OBSERVATION_HISTORY_DIR: directory,
      },
      stdio: ["pipe", "pipe", "pipe"],
    },
  );
  let output = "";
  child.stdout.on("data", (chunk) => {
    output = (output + chunk).slice(-16384);
  });
  child.stderr.on("data", (chunk) => {
    output = (output + chunk).slice(-16384);
  });
  const exited = once(child, "exit");
  const stop = async () => {
    child.stdin.destroy();
    if (child.exitCode !== null || child.signalCode !== null) return;
    child.kill("SIGTERM");
    const timer = setTimeout(() => child.kill("SIGKILL"), 3000);
    try {
      await exited;
    } finally {
      clearTimeout(timer);
    }
  };
  const snapshot = async () => {
    const response = await fetch(`http://127.0.0.1:${port}/api/snapshot`, {
      signal: AbortSignal.timeout(1000),
    });
    assert.equal(response.status, 200);
    return response.json();
  };
  const until = async (predicate, message) => {
    const deadline = performance.now() + 5000;
    while (performance.now() < deadline) {
      assert.equal(child.exitCode, null, `Backend exited: ${output}`);
      const value = await snapshot();
      if (predicate(value)) return value;
      await delay(20);
    }
    assert.fail(message);
  };
  try {
    const deadline = performance.now() + 5000;
    while (!output.includes("Odysseus Fleet:")) {
      assert.equal(child.exitCode, null, `Backend exited: ${output}`);
      assert.ok(
        performance.now() < deadline,
        `Backend did not listen: ${output}`,
      );
      await delay(20);
    }
  } catch (error) {
    await stop();
    throw error;
  }
  return { child, snapshot, until, stop };
}

test(
  "real backend restores confirmed observation history without restoring work authority",
  { timeout: 20000 },
  async (t) => {
    const parent = join(
      await realpath(homedir()),
      ".cache",
      "odysseus-history-tests",
    );
    await mkdir(parent, { recursive: true, mode: 0o700 });
    const directory = await mkdtemp(join(parent, "restart-"));
    t.after(() => rm(directory, { recursive: true, force: true }));
    const port = await availablePort();
    const first = await startBackend(port, directory);
    t.after(first.stop);
    const privateSentinel = "must-not-be-persisted";
    const event = {
      source: "keystone",
      target: "hephaestus",
      operation: "deliver",
      eventId: "synthetic-restart-1",
      sourceId: "synthetic-source",
      sourceSequence: 1,
      observedAt: new Date().toISOString(),
      workerId: "synthetic-worker",
      generation: 1,
      prompt: privateSentinel,
      payload: { token: privateSentinel },
    };
    first.child.stdin.write(
      JSON.stringify({ type: "observation", observation: event }) + "\n",
    );
    const initial = await first.until(
      (value) => value.observations.length === 1,
      "Input was not observed",
    );
    assert.equal(JSON.stringify(initial).includes(privateSentinel), false);
    await first.until(
      (value) => value.history?.persistedSequence >= 1,
      "Observed history was not confirmed durable",
    );
    const cache = join(directory, `observations-${port}.json`);
    const committed = await fs.readFile(cache);
    await assert.rejects(startBackend(port, directory), /Backend exited/);
    assert.deepEqual(await fs.readFile(cache), committed);
    await first.stop();
    const second = await startBackend(port, directory);
    t.after(second.stop);
    const restored = await second.until(
      (value) => value.observations.length === 1,
      "Confirmed history disappeared after restart",
    );
    const { origin, ...record } = restored.observations[0];
    const { origin: previousOrigin, ...previous } = initial.observations[0];
    assert.equal(origin, "restored");
    assert.deepEqual(record, previous);
    assert.deepEqual(restored.items, []);
    assert.ok(
      Object.values(restored.resources).every((items) => items.length === 0),
    );
    assert.equal(restored.history.restartGap, true);
    assert.notEqual(
      restored.cursor.split(":")[0],
      initial.cursor.split(":")[0],
    );
    const response = await fetch(
      `http://127.0.0.1:${port}/api/events?after=${encodeURIComponent(initial.cursor)}`,
      { signal: AbortSignal.timeout(1500) },
    );
    const reader = response.body.getReader();
    let frame = "";
    while (!frame.includes("\n\n"))
      frame += new TextDecoder().decode((await reader.read()).value);
    await reader.cancel();
    assert.equal(
      JSON.parse(
        frame
          .split("\n")
          .find((line) => line.startsWith("data: "))
          .slice(6),
      ).gap,
      true,
    );
    second.child.stdin.write(
      JSON.stringify({ type: "observation", observation: event }) + "\n",
    );
    second.child.stdin.write(
      JSON.stringify({
        type: "observation",
        observation: {
          ...event,
          eventId: "synthetic-restart-2",
          sourceSequence: 3,
        },
      }) + "\n",
    );
    const advanced = await second.until(
      (value) => value.observations.length === 2,
      "New observation did not advance after replay",
    );
    assert.equal(advanced.observations[1].sequence, previous.sequence + 1);
    assert.equal(advanced.observations[1].origin, "live");
    assert.equal(advanced.sourceGaps, 1);
  },
);
