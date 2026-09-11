import { randomBytes } from "node:crypto";
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  mkdtemp,
  readFile,
  readdir,
  rm,
  chmod,
  symlink,
  writeFile,
  mkdir,
} from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createCommandService } from "../server/commands.mjs";

const fixtureCredential = randomBytes(24).toString("base64url");

const request = {
  commandId: "ui-" + "a".repeat(32),
  sessionId: "s1",
  workerId: "w1",
  generation: 3,
  operation: "input",
  text: "Private synthetic prompt",
};
async function fixture(t, options = {}) {
  const spool = await mkdtemp(
    fileURLToPath(new URL("../.test-spool-", import.meta.url)),
  );
  const workspace = await mkdtemp(
    fileURLToPath(new URL("../.test-spool-", import.meta.url)),
  );
  t.after(() => rm(spool, { recursive: true, force: true }));
  t.after(() => rm(workspace, { recursive: true, force: true }));
  const calls = [];
  const service = createCommandService({
    url: "http://127.0.0.1:59999",
    apiKey: fixtureCredential,
    inputSpools: { w1: spool },
    requestReader: options.requestReader,
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), ...init });
      if (new URL(url).pathname.startsWith("/v1/fleet/commands/"))
        return options.existingCommand
          ? Response.json(options.existingCommand)
          : Response.json({}, { status: 404 });
      if (init.method !== "POST")
        return Response.json({
          id: "s1",
          workerId: "w1",
          generation: 3,
          claimStatus: "claimed",
          status: "running",
          workspace,
          ...options.record,
        });
      if (options.failPost)
        throw new Error("private upstream detail must not escape");
      if (options.status)
        return Response.json(
          { error: "private upstream detail" },
          { status: options.status },
        );
      const body = JSON.parse(init.body);
      return Response.json(
        {
          command: {
            ...body,
            payload: Object.fromEntries(Object.entries(body.payload).sort()),
            targetKind: "sessions",
            targetId: "s1",
            workerId: "w1",
            operation: new URL(url).pathname.split("/").at(-1),
          },
          status: "pending",
        },
        { status: 202 },
      );
    },
  });
  return { service, calls, spool };
}

test("private text is durably spooled before only scoped references reach Agamemnon", async (t) => {
  const { service, calls, spool } = await fixture(t);
  assert.deepEqual(await service.submit(request), {
    code: 202,
    body: { commandId: request.commandId, status: "submitted" },
  });
  const post = calls.find((c) => c.method === "POST");
  assert.equal(post.headers.Authorization, `Bearer ${fixtureCredential}`);
  assert.equal(post.redirect, "error");
  assert.equal(post.body.includes(request.text), false);
  const body = JSON.parse(post.body);
  assert.equal(body.idempotencyKey, request.commandId);
  assert.match(body.payload.inputRef, /^[0-9a-f]{32}\.json$/);
  assert.deepEqual(
    JSON.parse(await readFile(resolve(spool, body.payload.inputRef), "utf8")),
    {
      schema: "hi/fleet/private-input/v1",
      commandId: request.commandId,
      workerId: "w1",
      generation: 3,
      sessionId: "s1",
      kind: "input",
      text: request.text,
    },
  );
});

test("approval responses retain typed IDs privately and send only references to the controller", async (t) => {
  const pending = {
    requestId: 19,
    fingerprint: "f".repeat(64),
    kind: "command",
    decisions: ["accept", "decline"],
  };
  const requestReader = { workerIds: ["w1"], read: async () => [pending] };
  const { service, calls, spool } = await fixture(t, { requestReader });
  const input = {
    ...request,
    operation: "respond",
    requestId: 19,
    requestFingerprint: pending.fingerprint,
    response: { decision: "accept" },
  };
  delete input.text;
  assert.equal((await service.submit(input)).code, 202);
  const post = calls.find((call) => call.method === "POST");
  const command = JSON.parse(post.body);
  assert.deepEqual(Object.keys(command.payload).sort(), [
    "requestId",
    "responseRef",
  ]);
  assert.equal(command.payload.requestId, "19");
  const body = JSON.parse(
    await readFile(resolve(spool, command.payload.responseRef), "utf8"),
  );
  assert.equal(body.kind, "response");
  assert.equal(body.requestId, 19);
  assert.deepEqual(body.response, { decision: "accept" });
  assert.equal(post.body.includes('"decision"'), false);
  assert.equal(post.body.includes(pending.fingerprint), false);
});

test("changed approval identity cannot create an authorized response", async (t) => {
  const requestReader = {
    workerIds: ["w1"],
    read: async () => [
      {
        requestId: 19,
        fingerprint: "a".repeat(64),
        kind: "command",
        decisions: ["accept"],
      },
    ],
  };
  const { service, calls, spool } = await fixture(t, { requestReader });
  const input = {
    ...request,
    operation: "respond",
    requestId: 19,
    requestFingerprint: "b".repeat(64),
    response: { decision: "accept" },
  };
  delete input.text;
  assert.equal((await service.submit(input)).code, 409);
  assert.equal(
    calls.some((call) => call.method === "POST"),
    false,
  );
  assert.deepEqual(await readdir(spool), []);
});

test("a retained durable approval can confirm an uncertain retry after the provider request disappears", async (t) => {
  const pending = {
    requestId: "request-1",
    fingerprint: "e".repeat(64),
    kind: "command",
    decisions: ["accept"],
  };
  const options = {
    failPost: true,
    requestReader: { workerIds: ["w1"], read: async () => [pending] },
  };
  const { service, calls, spool } = await fixture(t, options);
  const input = {
    ...request,
    operation: "respond",
    requestId: pending.requestId,
    requestFingerprint: pending.fingerprint,
    response: { decision: "accept" },
  };
  delete input.text;
  assert.equal((await service.submit(input)).body.outcome, "unknown");
  const posted = JSON.parse(calls.find((call) => call.method === "POST").body);
  options.existingCommand = {
    command: {
      ...posted,
      targetKind: "sessions",
      targetId: "s1",
      workerId: "w1",
      operation: "respond",
      payload: Object.fromEntries(Object.entries(posted.payload).sort()),
    },
    status: "completed",
  };
  options.requestReader.read = async () => {
    throw new Error("Request has already been answered");
  };
  assert.equal((await service.submit(input)).code, 202);
  assert.equal(calls.filter((call) => call.method === "POST").length, 1);
  assert.equal(
    (await service.submit({ ...input, response: { decision: "decline" } }))
      .code,
    409,
  );
  for (const name of await readdir(spool)) await rm(resolve(spool, name));
  assert.equal((await service.submit(input)).code, 503);
  assert.deepEqual(await readdir(spool), []);
});

test("private input cannot enter a workspace or an ancestor of a workspace", async (t) => {
  const options = { record: {} };
  const { service, calls, spool } = await fixture(t, options);
  const child = resolve(spool, "workspace");
  await mkdir(child);
  for (const workspace of [spool, resolve(spool, ".."), child]) {
    options.record.workspace = workspace;
    const result = await service.submit(request);
    assert.equal(result.code, 503);
    assert.equal(result.body.outcome, "not_submitted");
  }
  assert.equal(calls.filter((c) => c.method === "POST").length, 0);
  assert.deepEqual(await readdir(spool), ["workspace"]);
});

test("a configured shared temporary root is not a private input spool", async (t) => {
  const { service, spool, calls } = await fixture(t);
  const previous = process.env.TMPDIR;
  try {
    process.env.TMPDIR = spool;
    assert.equal((await service.submit(request)).code, 503);
    assert.equal(calls.filter((c) => c.method === "POST").length, 0);
  } finally {
    if (previous === undefined) delete process.env.TMPDIR;
    else process.env.TMPDIR = previous;
  }
});

test("an uncertain retry preserves the reference and cannot replace private input", async (t) => {
  const { service, calls, spool } = await fixture(t, { failPost: true });
  assert.deepEqual(await service.submit(request), {
    code: 503,
    body: {
      commandId: request.commandId,
      error: "unavailable",
      outcome: "unknown",
    },
  });
  const before = await readdir(spool);
  assert.equal((await service.submit(request)).body.outcome, "unknown");
  assert.deepEqual(await readdir(spool), before);
  const changed = await service.submit({ ...request, text: "Changed intent" });
  assert.equal(changed.code, 409);
  assert.equal(calls.filter((c) => c.method === "POST").length, 2);
});

test("stale ownership and malformed control requests cannot dispatch or create private files", async (t) => {
  const { service, calls, spool } = await fixture(t, {
    record: { generation: 4 },
  });
  assert.equal((await service.submit(request)).code, 409);
  for (const change of [
    { sessionId: "../wrong" },
    { operation: "drain" },
    { generation: 3.5 },
    { unexpected: "raw" },
    { text: "x".repeat(131073) },
  ])
    assert.equal((await service.submit({ ...request, ...change })).code, 400);
  assert.equal(calls.filter((c) => c.method === "POST").length, 0);
  assert.deepEqual(await readdir(spool), []);
});

test("private spool rejects unsafe modes and refuses linked or corrupt retry files", async (t) => {
  const { service, calls, spool } = await fixture(t, { failPost: true });
  await chmod(spool, 0o755);
  assert.equal((await service.submit(request)).code, 503);
  assert.equal(calls.filter((c) => c.method === "POST").length, 0);
  await chmod(spool, 0o700);
  await service.submit(request);
  const [file] = await readdir(spool);
  await rm(resolve(spool, file));
  const target = resolve(spool, "fixture-target");
  await writeFile(target, "sentinel", { mode: 0o600 });
  await symlink(target, resolve(spool, file));
  assert.equal((await service.submit(request)).code, 503);
  assert.equal(await readFile(target, "utf8"), "sentinel");
  assert.equal(calls.filter((c) => c.method === "POST").length, 1);
});

test("commands are disabled without explicit backend configuration; upstream bodies stay private", async (t) => {
  assert.equal(
    createCommandService({}).capabilities.sessionCommands.enabled,
    false,
  );
  assert.equal(
    (await createCommandService({}).submit(request)).body.error,
    "not_configured",
  );
  assert.throws(() =>
    createCommandService({ url: "http://remote.example", apiKey: "x" }),
  );
  const { service } = await fixture(t, { status: 409 });
  const result = await service.submit(request);
  assert.deepEqual(result, {
    code: 409,
    body: { commandId: request.commandId, error: "conflict" },
  });
});
