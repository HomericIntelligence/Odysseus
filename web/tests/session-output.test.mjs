import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  chmod,
  link,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { homedir } from "node:os";
import { createServer } from "node:http";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { createDashboardServer } from "../server/http.mjs";
import { FleetView } from "../server/view.mjs";

import { createSessionOutputService } from "../server/session-output.mjs";
const digest = (text) => createHash("sha256").update(text).digest("hex");
const canonical = (value) =>
  JSON.stringify(value, (_, item) =>
    item && typeof item === "object" && !Array.isArray(item)
      ? Object.fromEntries(
          Object.entries(item).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)),
        )
      : item,
  );
const identity = {
  workerId: "worker-one",
  generation: 2,
  allocationId: "allocation-one",
  sessionId: "session-one",
  executionId: "execution-one",
  taskId: "task-one",
  agentId: "agent-one",
  providerThreadId: "thread-one",
};
const scope = {
  sessionId: identity.sessionId,
  workerId: identity.workerId,
  generation: identity.generation,
};
function item(text = "Synthetic output: α 🛠\n") {
  return {
    turnId: "turn-one",
    itemId: "item-one",
    completedAtMs: 12,
    command: "just fixture",
    cwd: "/workspace",
    status: "failed",
    exitCode: 7,
    durationMs: 15,
    output: {
      kind: "provider_aggregate",
      text,
      byteCount: text === null ? null : Buffer.byteLength(text),
      sha256: text === null ? null : digest(text),
      providerTruncated: null,
      captureTruncated: false,
    },
  };
}
function bundle(items = [item()]) {
  return {
    schema: "hi/fleet/session-output/v1",
    identity: { ...identity },
    provider: { name: "codex", version: "0.153.4" },
    capture: {
      profile: "completed_command_items",
      complete: false,
      observedCompletedItems: items.length,
      retainedItems: items.length,
      omittedItems: 0,
      retentionLimited: false,
    },
    items: items.map((entry) => ({
      ...entry,
      recordDigest: digest(canonical({ identity, item: entry })),
    })),
  };
}
async function fixture(t, options = {}) {
  const cache = join(homedir(), ".cache");
  await mkdir(cache, { recursive: true });
  const directory = await mkdtemp(join(cache, "odysseus-session-output-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, "bundle.json");
  const data = options.bundle ?? bundle();
  const bytes = options.bytes ?? JSON.stringify(data);
  await writeFile(path, bytes, { mode: 0o600 });
  const calls = [];
  const registeredIdentity = options.identity ?? identity;
  const owner = {
    schema: "hi/fleet/v1",
    kind: "sessions",
    id: registeredIdentity.sessionId,
    ...registeredIdentity,
    host: "vm-worker",
    workspace: "/workspace",
    status: "running",
    claimStatus: "claimed",
  };
  const config = {
    path,
    receiptDigest: digest(bytes),
    identity: { ...registeredIdentity },
  };
  const settings = {
    url: "http://127.0.0.1:59999",
    apiKey: "fixture",
    executionHost: "dashboard-host",
    bundles: [config],
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), ...init });
      const kind = new URL(url).pathname.match(
        /^\/v1\/fleet\/(sessions|executions|build-jobs)$/,
      )?.[1];
      if (options.unavailable)
        throw new Error("Synthetic private upstream detail");
      if (kind) {
        const items = [
          ...(kind === "sessions" ? [owner] : []),
          ...(options.peers?.[kind] ?? []),
        ];
        return Response.json({
          items,
          total: items.length + (options.missingTotal ?? 0),
        });
      }
      return options.missingOwner
        ? new Response(null, { status: 404 })
        : Response.json(owner);
    },
    ...options.settings,
  };
  return {
    service: createSessionOutputService(settings),
    settings,
    calls,
    owner,
    config,
    directory,
    path,
    data,
  };
}

test("registered private output is displayed through the real read route while commands are disabled", async (t) => {
  const { service, data } = await fixture(t);
  const server = createDashboardServer({
    view: new FleetView(),
    sessionOutput: service,
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const url = `http://127.0.0.1:${server.address().port}`;
  const response = await fetch(
    `${url}/api/session-output?sessionId=session-one&workerId=worker-one&generation=2`,
  );
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.deepEqual(result.bundle, data);
  assert.equal(result.ownership, "current");
  assert.equal(response.headers.get("cache-control"), "no-store");
  const snapshot = await (await fetch(`${url}/api/snapshot`)).text();
  assert.equal(snapshot.includes("Synthetic output"), false);
  const capabilities = await (await fetch(`${url}/api/capabilities`)).json();
  assert.equal(capabilities.sessionCommands.enabled, false);
});

test("exact private text, nonzero exit, null and empty aggregates remain distinct", async (t) => {
  const entries = [
    item(),
    { ...item(null), itemId: "null-output" },
    { ...item(""), itemId: "empty-output" },
  ];
  const { service, data, config, calls } = await fixture(t, {
    bundle: bundle(entries),
  });
  const result = await service.read(scope);
  assert.deepEqual(result, {
    code: 200,
    body: {
      ...scope,
      receiptDigest: config.receiptDigest,
      ownership: "current",
      bundle: data,
    },
  });
  assert.ok(
    calls.every((call) => call.method === "GET" && call.redirect === "error"),
  );
  assert.ok(
    calls.every((call) => call.headers.Authorization === "Bearer fixture"),
  );
  assert.equal(JSON.stringify(result).includes("Bearer fixture"), false);
});

test("the genuine Hephaestus CLI export is accepted without rewriting its bytes", async (t) => {
  // Generated from a synthetic owned notification by Hephaestus export-output,
  // based on ff1f725ebbd0e216fc2d8c001a87756354fe8c61 plus retained-output code.
  // This is a producer/consumer fixture, not evidence of an actual model command.
  const bytes = await readFile(
    new URL("./fixtures/hephaestus-session-output.json", import.meta.url),
  );
  const receiptDigest =
    "6fd9f383bff485f65bff1277707e6431a6474c6438c23a7901de5009f53ece85";
  assert.equal(digest(bytes), receiptDigest);
  assert.equal(bytes.length, 923);
  const data = JSON.parse(bytes.toString("utf8"));
  const { service } = await fixture(t, {
    bundle: data,
    bytes,
    identity: data.identity,
  });
  const { sessionId, workerId, generation } = data.identity;
  const result = await service.read({ sessionId, workerId, generation });
  assert.equal(result.code, 200);
  assert.equal(result.body.receiptDigest, receiptDigest);
  assert.deepEqual(result.body.bundle, data);
  assert.equal(
    result.body.bundle.items[0].output.text,
    "résultat ✓\nstderr line\n",
  );
  assert.equal(result.body.bundle.items[0].exitCode, 7);
  assert.equal(result.body.bundle.capture.complete, false);
});

test("registration is fixed and browser selectors cannot name private files", async (t) => {
  const { service, calls } = await fixture(t);
  for (const input of [
    null,
    { ...scope, path: "/private/file" },
    { ...scope, generation: "2" },
    { ...scope, generation: 0 },
    { ...scope, sessionId: "../file" },
  ])
    assert.deepEqual(await service.read(input), {
      code: 400,
      body: { error: "invalid_scope" },
    });
  assert.deepEqual(await service.read({ ...scope, generation: 3 }), {
    code: 404,
    body: { error: "not_registered" },
  });
  assert.equal(calls.length, 0);
});

test("output configuration is independent from commands but requires controller credentials", async (t) => {
  const { service, calls } = await fixture(t, {
    settings: { apiKey: undefined },
  });
  assert.deepEqual(await service.read(scope), {
    code: 503,
    body: { error: "not_configured" },
  });
  assert.equal(calls.length, 0);
});

for (const [name, change] of Object.entries({
  "generation changed": { generation: 3 },
  "worker changed": { workerId: "other-worker" },
  "allocation changed": { allocationId: "other-allocation" },
  "execution changed": { executionId: "other-execution" },
  "task changed": { taskId: "other-task" },
  "agent changed": { agentId: "other-agent" },
  "provider thread changed": { providerThreadId: "other-thread" },
  "provider thread not confirmed": { providerThreadId: undefined },
  "provider thread null": { providerThreadId: null },
  "interactive task absent": { taskId: undefined },
  "native allocation null": { allocationId: null },
  "completed owner": { status: "completed" },
  "cancelled owner": { status: "cancelled" },
  "released owner": { claimStatus: "released" },
}))
  test(`retained output is historical when ${name}`, async (t) => {
    const { service, owner, data } = await fixture(t);
    Object.assign(owner, change);
    const result = await service.read(scope);
    assert.equal(result.code, 200);
    assert.equal(result.body.ownership, "historical");
    assert.deepEqual(result.body.bundle, data);
  });

for (const [name, change] of Object.entries({
  "generation absent": { generation: undefined },
  "generation text": { generation: "2" },
  "generation zero": { generation: 0 },
  "generation fractional": { generation: 1.5 },
  "wrong resource kind": { kind: "executions" },
  "session identity absent": { sessionId: undefined },
  "session identity contradicts id": { sessionId: "different-session" },
  "agent absent": { agentId: undefined },
  "agent empty": { agentId: "" },
  "agent too long": { agentId: "α".repeat(513) },
  "execution malformed": { executionId: {} },
  "task malformed": { taskId: 12 },
  "allocation absent": { allocationId: undefined },
  "allocation malformed": { allocationId: [] },
  "provider thread malformed": { providerThreadId: false },
}))
  test(`malformed canonical ownership is unavailable when ${name}`, async (t) => {
    const { service, owner } = await fixture(t);
    Object.assign(owner, change);
    assert.deepEqual(await service.read(scope), {
      code: 503,
      body: { error: "unavailable" },
    });
  });

test("deleted canonical session is historical while controller unavailability hides output", async (t) => {
  const missing = await fixture(t, { missingOwner: true });
  assert.equal(
    (await missing.service.read(scope)).body.ownership,
    "historical",
  );
  const unavailable = await fixture(t, { unavailable: true });
  assert.deepEqual(await unavailable.service.read(scope), {
    code: 503,
    body: { error: "unavailable" },
  });
});

test("a cached immutable bundle still requires fresh canonical ownership and returns detached values", async (t) => {
  const { service, path, data, owner, calls } = await fixture(t);
  const first = await service.read(scope);
  first.body.bundle.items[0].output.text = "caller mutation";
  await writeFile(path, "changed after immutable import");
  owner.generation = 3;
  const second = await service.read(scope);
  assert.equal(second.code, 200);
  assert.equal(second.body.ownership, "historical");
  assert.deepEqual(second.body.bundle, data);
  assert.equal(
    calls.filter((call) => new URL(call.url).pathname.endsWith("/session-one"))
      .length,
    2,
  );
});

test("a failed bundle read is not cached and the detached receipt covers capture counts", async (t) => {
  const { service, path, data } = await fixture(t);
  await writeFile(
    path,
    JSON.stringify({ ...data, capture: { ...data.capture, omittedItems: 1 } }),
  );
  assert.deepEqual(await service.read(scope), {
    code: 503,
    body: { error: "unavailable" },
  });
  await writeFile(path, JSON.stringify(data));
  assert.equal((await service.read(scope)).code, 200);
});

for (const [name, mutate] of Object.entries({
  "unknown bundle field": (data) => {
    data.extra = true;
  },
  "unknown identity field": (data) => {
    data.identity.extra = true;
  },
  "different identity": (data) => {
    data.identity.workerId = "other";
  },
  "unsupported provider": (data) => {
    data.provider.version = "0.155.1";
  },
  "complete capture claim": (data) => {
    data.capture.complete = true;
  },
  "count mismatch": (data) => {
    data.capture.retainedItems = 0;
  },
  "observation count mismatch": (data) => {
    data.capture.observedCompletedItems = 2;
  },
  "loss without limited flag": (data) => {
    data.capture.observedCompletedItems = 2;
    data.capture.omittedItems = 1;
  },
  "unexplained limited flag": (data) => {
    data.capture.retentionLimited = true;
  },
  "unknown item field": (data) => {
    data.items[0].extra = true;
  },
  "item digest mismatch": (data) => {
    data.items[0].recordDigest = "0".repeat(64);
  },
  "duplicate item": (data) => {
    data.items.push(structuredClone(data.items[0]));
    data.capture.observedCompletedItems = data.capture.retainedItems = 2;
  },
}))
  test(`invalid bundle is withheld: ${name}`, async (t) => {
    const data = bundle();
    mutate(data);
    const { service } = await fixture(t, { bundle: data });
    assert.deepEqual(await service.read(scope), {
      code: 503,
      body: { error: "unavailable" },
    });
  });

for (const [name, mutate] of Object.entries({
  "nonterminal item": (entry) => {
    entry.status = "inProgress";
  },
  "unknown output field": (entry) => {
    entry.output.extra = true;
  },
  "false output digest": (entry) => {
    entry.output.sha256 = "0".repeat(64);
  },
  "false output byte count": (entry) => {
    entry.output.byteCount = 1;
  },
  "claimed provider truncation": (entry) => {
    entry.output.providerTruncated = false;
  },
  "noninteger exit": (entry) => {
    entry.exitCode = 1.5;
  },
  "overflow exit": (entry) => {
    entry.exitCode = 2147483648;
  },
  "negative duration": (entry) => {
    entry.durationMs = -1;
  },
  "unsafe completion time": (entry) => {
    entry.completedAtMs = Number.MAX_SAFE_INTEGER + 1;
  },
  "oversized output": (entry) => {
    entry.output = item("x".repeat(65537)).output;
  },
  "oversized command": (entry) => {
    entry.command = "x".repeat(16385);
  },
  "oversized cwd": (entry) => {
    entry.cwd = "x".repeat(4097);
  },
  "oversized item ID": (entry) => {
    entry.itemId = "x".repeat(1025);
  },
  "missing null digest": (entry) => {
    entry.output.text = null;
    entry.output.byteCount = null;
  },
}))
  test(`self-consistent receipt cannot authorize an invalid item: ${name}`, async (t) => {
    const entry = item();
    mutate(entry);
    const { service } = await fixture(t, { bundle: bundle([entry]) });
    assert.equal((await service.read(scope)).code, 503);
  });

test("retention limits and available provider metadata preserve their qualified meanings", async (t) => {
  const entry = item("x".repeat(65536));
  entry.output.captureTruncated = true;
  entry.command = "x".repeat(16384);
  entry.cwd = "x".repeat(4096);
  entry.exitCode = -2147483648;
  entry.durationMs = null;
  const data = bundle([entry]);
  data.capture.observedCompletedItems = 3;
  data.capture.omittedItems = 2;
  data.capture.retentionLimited = true;
  const { service } = await fixture(t, { bundle: data });
  assert.deepEqual((await service.read(scope)).body.bundle, data);
});

for (const observed of [4096, 4097])
  test(`observed command count ${observed} obeys the producer ledger limit`, async (t) => {
    const data = bundle();
    data.capture.observedCompletedItems = observed;
    data.capture.omittedItems = observed - data.capture.retainedItems;
    data.capture.retentionLimited = true;
    const { service } = await fixture(t, { bundle: data });
    const result = await service.read(scope);
    assert.equal(result.code, observed === 4096 ? 200 : 503);
    if (observed === 4096) assert.deepEqual(result.body.bundle, data);
  });

test("whole-file, item-count and aggregate-record limits bound retained data", async (t) => {
  for (const data of [
    bundle(
      Array.from({ length: 65 }, (_, index) => ({
        ...item(""),
        itemId: `item-${index}`,
      })),
    ),
    bundle(
      Array.from({ length: 17 }, (_, index) => ({
        ...item("x".repeat(65536)),
        itemId: `item-${index}`,
      })),
    ),
  ]) {
    const { service } = await fixture(t, { bundle: data });
    assert.equal((await service.read(scope)).code, 503);
  }
  const { service } = await fixture(t, {
    bytes: " ".repeat(2 * 1024 * 1024 + 1),
  });
  assert.equal((await service.read(scope)).code, 503);
});

test("strict JSON rejects duplicate keys, invalid Unicode and nonfinite numbers", async (t) => {
  const json = JSON.stringify(bundle());
  for (const bytes of [
    json.replace('"schema":', '"schema":"other","schema":'),
    json.replace('"schema":', '"schem\\u0061":"other","schema":'),
    json.replace('"completedAtMs":12', '"completedAtMs":1e309'),
    json.replace('"command":"just fixture"', '"command":"\\ud800"'),
    Buffer.from([0xff, 0xfe]),
  ]) {
    const { service } = await fixture(t, { bytes });
    assert.equal((await service.read(scope)).code, 503);
  }
});

for (const [name, options] of Object.entries({
  "incomplete collection": { missingTotal: 1 },
  "unknown host": {
    peers: {
      sessions: [{ id: "other", workerId: "other", workspace: "/workspace" }],
    },
  },
  "duplicate resource": {
    peers: {
      sessions: [
        {
          id: "session-one",
          workerId: "other",
          host: "elsewhere",
          workspace: "/workspace",
        },
      ],
    },
  },
  "relative workspace": {
    peers: {
      executions: [
        {
          id: "other",
          workerId: "other",
          host: "elsewhere",
          workspace: "relative",
        },
      ],
    },
  },
  "unresolved local workspace": {
    peers: {
      sessions: [
        {
          id: "other",
          workerId: "other",
          host: "dashboard-host",
          workspace: "/does-not-exist-fixture",
        },
      ],
    },
  },
}))
  test(`private output is withheld for ${name}`, async (t) => {
    const { service } = await fixture(t, options);
    assert.equal((await service.read(scope)).code, 503);
  });

test("typed builds cannot bypass unresolved private workspace protection", async (t) => {
  const { service } = await fixture(t, {
    peers: {
      "build-jobs": [
        {
          id: "build-one",
          build: {},
          host: "elsewhere",
          workspace: "/workspace",
          status: "completed",
        },
      ],
    },
  });
  assert.deepEqual(await service.read(scope), {
    code: 503,
    body: { error: "unavailable", reason: "build_workspace_unresolved" },
  });
});

test("all local workspaces including retained workers protect imported storage", async (t) => {
  const options = { peers: { sessions: [] } };
  const { service, directory } = await fixture(t, options);
  options.peers.sessions.push({
    id: "old-session",
    workerId: "other",
    host: "dashboard-host",
    workspace: directory,
    status: "completed",
  });
  assert.equal((await service.read(scope)).code, 503);
});

test("private files require owner-only regular unlinked storage", async (t) => {
  for (const mode of [
    "permissions",
    "hardlink",
    "symlink",
    "directory",
    "parent-permissions",
  ]) {
    const { service, path, directory } = await fixture(t);
    if (mode === "permissions") await chmod(path, 0o644);
    if (mode === "hardlink") await link(path, join(directory, "second-link"));
    if (mode === "symlink") {
      const bytes = await readFile(path);
      await rm(path);
      const other = join(directory, "other.json");
      await writeFile(other, bytes, { mode: 0o600 });
      await symlink(other, path);
    }
    if (mode === "directory") {
      await rm(path);
      await mkdir(path);
    }
    if (mode === "parent-permissions") await chmod(directory, 0o755);
    assert.equal((await service.read(scope)).code, 503, mode);
  }
});

test("operator configuration is closed, unique and copied at startup", async (t) => {
  const { settings, service, config } = await fixture(t);
  for (const invalid of [
    null,
    {},
    [{ ...config, path: "relative" }],
    [{ ...config, receiptDigest: "bad" }],
    [{ ...config, extra: true }],
    [config, config],
    [{ ...config, identity: { ...identity, allocationId: "" } }],
  ])
    assert.throws(() =>
      createSessionOutputService({ ...settings, bundles: invalid }),
    );
  config.identity.taskId = "caller-mutated-task";
  config.path = "/does-not-exist";
  assert.equal((await service.read(scope)).code, 200);
});

test("the complete ownership read has one deadline across successive upstream calls", async (t) => {
  let now = 0;
  const deadlines = [];
  t.mock.method(AbortSignal, "timeout", (duration) => {
    const controller = new AbortController();
    deadlines.push({ expires: now + duration, controller });
    return controller.signal;
  });
  const { settings } = await fixture(t);
  const fetchImpl = settings.fetchImpl;
  settings.fetchImpl = async (url, init) => {
    now += 3500;
    for (const deadline of deadlines)
      if (now >= deadline.expires) deadline.controller.abort();
    init.signal.throwIfAborted();
    return fetchImpl(url, init);
  };
  const service = createSessionOutputService(settings);
  assert.deepEqual(await service.read(scope), {
    code: 503,
    body: { error: "unavailable" },
  });
});

test("native fetch aborts an unfinished controller body after response headers", async (t) => {
  const timeout = new AbortController();
  t.mock.method(AbortSignal, "timeout", () => timeout.signal);
  const controller = createServer((_, response) => {
    response.writeHead(200, { "content-type": "application/json" });
    response.write('{"items":[');
  });
  await new Promise((resolve) => controller.listen(0, "127.0.0.1", resolve));
  t.after(() => {
    controller.closeAllConnections();
    return new Promise((resolve) => controller.close(resolve));
  });
  const { settings } = await fixture(t);
  settings.url = `http://127.0.0.1:${controller.address().port}`;
  settings.fetchImpl = async (url, init) => {
    const response = await fetch(url, init);
    assert.equal(response.status, 200);
    timeout.abort();
    return response;
  };
  assert.deepEqual(await createSessionOutputService(settings).read(scope), {
    code: 503,
    body: { error: "unavailable" },
  });
});

test("a validated cache never substitutes for unavailable current inventory", async (t) => {
  const options = {};
  const { service } = await fixture(t, options);
  assert.equal((await service.read(scope)).code, 200);
  options.unavailable = true;
  assert.deepEqual(await service.read(scope), {
    code: 503,
    body: { error: "unavailable" },
  });
});

test("the dashboard checkout stays protected with no local agent workspaces", async (t) => {
  const { settings, path, config } = await fixture(t);
  const sourceDirectory = await mkdtemp(
    fileURLToPath(new URL("../.test-output-", import.meta.url)),
  );
  t.after(() => rm(sourceDirectory, { recursive: true, force: true }));
  config.path = join(sourceDirectory, "bundle.json");
  await writeFile(config.path, await readFile(path), { mode: 0o600 });
  assert.deepEqual(await createSessionOutputService(settings).read(scope), {
    code: 503,
    body: { error: "unavailable" },
  });
});
