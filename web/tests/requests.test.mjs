import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:net";
import { chmod, mkdtemp, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import {
  createRequestReader,
  requestFingerprint,
  validateResponse,
} from "../server/requests.mjs";

async function fixture(t) {
  const directory = await mkdtemp(
    fileURLToPath(new URL("../.test-spool-", import.meta.url)),
  );
  const workspace = await mkdtemp(
    fileURLToPath(new URL("../.test-spool-", import.meta.url)),
  );
  const record = {
    id: "s1",
    workerId: "w1",
    generation: 3,
    agentId: "a1",
    taskId: "t1",
    workspace,
    claimStatus: "claimed",
    status: "waiting",
  };
  const session = {
    ...record,
    sessionId: "s1",
    providerThreadId: "thread1",
    providerTurnId: "turn1",
    activity: "waiting_approval",
    admissionReserved: true,
    released: false,
  };
  const pending = {
    id: 19,
    sessionId: "s1",
    method: "item/commandExecution/requestApproval",
    params: {
      threadId: "thread1",
      turnId: "turn1",
      itemId: "item1",
      startedAtMs: 1,
      command: "echo synthetic",
      cwd: workspace,
      availableDecisions: ["accept", "decline", "cancel"],
    },
  };
  const state = { session, pending, generation: 3 };
  const calls = [];
  const server = createServer((socket) => {
    let data = "";
    socket.on("data", (chunk) => {
      data += chunk;
      if (!data.endsWith("\n")) return;
      const input = JSON.parse(data);
      calls.push(input);
      if (input.operation === "inventory") state.onInventory?.();
      socket.end(
        JSON.stringify(
          input.operation === "inventory"
            ? {
                workerId: "w1",
                generation: state.generation,
                sessions: [state.session],
              }
            : input.operation === "requests"
              ? { requests: [state.pending] }
              : (state.evidence ?? { error: "evidence_unavailable" }),
        ) + "\n",
      );
    });
  });
  await new Promise((done) =>
    server.listen(resolve(directory, "worker.sock"), done),
  );
  await chmod(resolve(directory, "worker.sock"), 0o600);
  t.after(async () => {
    await new Promise((done) => server.close(done));
    await rm(directory, { recursive: true, force: true });
    await rm(workspace, { recursive: true, force: true });
  });
  return {
    reader: createRequestReader({ w1: directory }),
    state,
    record,
    directory,
    calls,
  };
}

test("private approval reads bind actual socket inventory, request ID type and current turn", async (t) => {
  const { reader, record, calls } = await fixture(t);
  const [request] = await reader.read(record, [record.workspace]);
  assert.equal(request.requestId, 19);
  assert.equal(request.kind, "command");
  assert.equal(request.command, "echo synthetic");
  assert.match(request.fingerprint, /^[0-9a-f]{64}$/);
  assert.deepEqual(request.decisions, ["accept", "decline", "cancel"]);
  assert.deepEqual(
    calls.map((c) => c.operation),
    ["inventory", "requests", "inventory"],
  );
});

test("private worker socket is excluded from another protected workspace before attachment", async (t) => {
  const { reader, record, directory, calls } = await fixture(t);
  await assert.rejects(reader.read(record, [record.workspace, directory]));
  assert.deepEqual(calls, []);
});

test("private worker attachment requires a complete workspace inventory including its own", async (t) => {
  const { reader, record, directory, calls } = await fixture(t);
  for (const workspaces of [undefined, [], [directory]])
    await assert.rejects(reader.read(record, workspaces));
  assert.deepEqual(calls, []);
});

test("private approval reads reject changed generation, old-turn requests and public sockets", async (t) => {
  const { reader, record, state, directory } = await fixture(t);
  state.generation = 4;
  await assert.rejects(reader.read(record, [record.workspace]));
  state.generation = 3;
  state.pending.params.turnId = "previous-turn";
  await assert.rejects(reader.read(record, [record.workspace]));
  state.pending.params.turnId = "turn1";
  await chmod(resolve(directory, "worker.sock"), 0o666);
  await assert.rejects(reader.read(record, [record.workspace]));
});

test("file approval without matching private evidence cannot authorize acceptance", async (t) => {
  const { reader, record, state } = await fixture(t);
  state.pending.method = "item/fileChange/requestApproval";
  delete state.pending.params.command;
  const [request] = await reader.read(record, [record.workspace]);
  assert.equal(request.kind, "file");
  assert.equal(request.evidenceAvailable, false);
  assert.deepEqual(request.decisions, ["decline", "cancel"]);
  assert.throws(() => validateResponse(request, { decision: "accept" }));
  assert.doesNotThrow(() => validateResponse(request, { decision: "decline" }));
});

test("file approval binds the displayed changes and excludes mismatched private proof", async (t) => {
  const { reader, record, state } = await fixture(t);
  state.pending.method = "item/fileChange/requestApproval";
  delete state.pending.params.command;
  state.evidence = {
    workerId: "w1",
    generation: 3,
    requestId: 19,
    sessionId: "s1",
    threadId: "thread1",
    turnId: "turn1",
    itemId: "item1",
    requestFingerprint: requestFingerprint(state.pending),
    evidence: {
      changes: [
        {
          path: "fixture.txt",
          kind: { type: "update" },
          diff: "+first synthetic change",
        },
      ],
    },
  };
  const [first] = await reader.read(record, [record.workspace]);
  assert.equal(first.evidenceAvailable, true);
  assert.equal(first.changes[0].diff, "+first synthetic change");
  assert.doesNotThrow(() => validateResponse(first, { decision: "accept" }));
  state.evidence.evidence.changes[0].diff = "+second synthetic change";
  const [changed] = await reader.read(record, [record.workspace]);
  assert.notEqual(changed.fingerprint, first.fingerprint);
  state.evidence.requestId = "19";
  const [mismatch] = await reader.read(record, [record.workspace]);
  assert.equal(mismatch.evidenceAvailable, false);
  assert.equal(mismatch.changes, undefined);
  assert.throws(() => validateResponse(mismatch, { decision: "accept" }));
});

test("a turn changing during the private read invalidates the entire request view", async (t) => {
  const { reader, record, state } = await fixture(t);
  let reads = 0;
  state.onInventory = () => {
    if (++reads === 2) state.session.providerTurnId = "turn2";
  };
  await assert.rejects(reader.read(record, [record.workspace]));
});

test("user answers preserve provider shape and cannot answer a different question", async (t) => {
  const { reader, record, state } = await fixture(t);
  state.pending.method = "item/tool/requestUserInput";
  state.session.activity = "waiting_input";
  state.pending.params = {
    threadId: "thread1",
    turnId: "turn1",
    itemId: "item1",
    isBlocking: true,
    questions: [
      {
        id: "q1",
        header: "Target",
        question: "Which target?",
        options: [{ label: "M1", description: "First cluster" }],
        isOther: false,
        isSecret: false,
      },
    ],
  };
  const [request] = await reader.read(record, [record.workspace]);
  assert.equal(request.questions[0].id, "q1");
  assert.doesNotThrow(() =>
    validateResponse(request, { answers: { q1: { answers: ["M1"] } } }),
  );
  assert.throws(() =>
    validateResponse(request, { answers: { q2: { answers: ["M1"] } } }),
  );
  assert.throws(() =>
    validateResponse(request, { answers: { q1: { answers: ["M2"] } } }),
  );
});
