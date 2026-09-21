import { createHash, randomBytes } from "node:crypto";
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer, get, request as httpRequest } from "node:http";
import { createDashboardServer } from "../server/http.mjs";
import { FleetView } from "../server/view.mjs";

const fixtureCredential = randomBytes(24).toString("base64url");

test("session output is read on demand without commands and never enters snapshots", async (t) => {
  const calls = [];
  const retained = {
    sessionId: "session-one",
    workerId: "worker-one",
    generation: 2,
    items: [{ output: "Private synthetic command output" }],
  };
  const { url } = await fixture(t, {
    sessionOutput: {
      read: async (scope) => {
        calls.push(scope);
        return { code: 200, body: retained };
      },
    },
  });
  const response = await fetch(
    `${url}/api/session-output?sessionId=session-one&workerId=worker-one&generation=2`,
  );
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(await response.json(), retained);
  assert.deepEqual(calls, [
    { sessionId: "session-one", workerId: "worker-one", generation: 2 },
  ]);
  const snapshot = await (await fetch(`${url}/api/snapshot`)).text();
  assert.equal(snapshot.includes("Private synthetic command output"), false);
});

test("session output rejects invalid selectors and foreign origin before reading", async (t) => {
  const calls = [];
  const { url } = await fixture(t, {
    sessionOutput: {
      read: async (scope) => {
        calls.push(scope);
        return { code: 200, body: {} };
      },
    },
  });
  const scope = "sessionId=session-one&workerId=worker-one&generation=2";
  for (const query of [
    "",
    scope + "&path=/private/file",
    scope + "&sessionId=other",
    scope.replace("generation=2", "generation=2e0"),
    scope.replace("generation=2", "generation=0"),
    scope.replace("session-one", "%2Fprivate%2Ffile"),
  ]) {
    const response = await fetch(`${url}/api/session-output?${query}`);
    assert.equal(response.status, 400, query);
  }
  for (const headers of [
    { origin: "https://foreign.example" },
    { "sec-fetch-site": "cross-site" },
  ]) {
    const response = await fetch(`${url}/api/session-output?${scope}`, {
      headers,
    });
    assert.equal(response.status, 403);
  }
  assert.deepEqual(calls, []);
});

test("session output reports disabled configuration instead of empty logs", async (t) => {
  const { url } = await fixture(t);
  const response = await fetch(
    `${url}/api/session-output?sessionId=session-one&workerId=worker-one&generation=2`,
  );
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: "not_configured" });
});

test("local dashboard opens without a token or session cookie", async (t) => {
  const { url, view } = await fixture(t);
  view.setResources("sessions", [{ id: "local-work", agentId: "worker-one" }]);
  const response = await fetch(`${url}/api/snapshot`);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("set-cookie"), null);
  assert.equal((await response.json()).resources.sessions[0].id, "local-work");
  const capabilities = await fetch(`${url}/api/capabilities`);
  assert.equal(capabilities.status, 200);
  assert.equal((await capabilities.json()).sessionCommands.enabled, false);
});

test("a non-loopback listener cannot expose dashboard data", async (t) => {
  const { server, url } = await fixture(t);
  const address = server.address();
  // Exercise the listener policy without opening a non-loopback socket.
  server.address = () => ({ ...address, address: "0.0.0.0" });
  const response = await fetch(`${url}/api/snapshot`);
  assert.equal(response.status, 403);
});

test("planned issue routes preserve local request checks and stay unavailable without configuration", async (t) => {
  const { url, view } = await fixture(t);
  const input = {
    schema: "hi/agamemnon/issue-import/v1",
    repositoryKey: "project",
    issueNumber: 42,
    repositoryId: "R_project",
    issueId: "I_work",
    plan: { kind: "issue_body", digest: "a".repeat(64) },
  };
  const routes = [
    ["/api/issue-intakes/repositories", "GET"],
    ["/api/issue-intakes/project/42", "GET"],
    ["/api/issue-intakes", "POST"],
    [`/api/tasks/issue-${"a".repeat(64)}`, "GET"],
  ];
  const send = (path, method, headers = {}) =>
    fetch(`${url}${path}`, {
      method,
      headers: {
        origin: url,
        "content-type": "application/json",
        ...headers,
      },
      ...(method === "POST" ? { body: JSON.stringify(input) } : {}),
    });
  for (const [path, method] of routes)
    assert.equal(
      (await send(path, method, { "sec-fetch-site": "cross-site" })).status,
      403,
    );

  for (const [path, method] of routes) {
    const response = await send(path, method);
    assert.equal(response.status, 503, path);
    assert.deepEqual(await response.json(), {
      error: "not_configured",
      outcome: "not_submitted",
    });
    assert.equal(response.headers.get("cache-control"), "no-store");
  }
  assert.deepEqual(view.snapshot().observations, []);
});

test("planned issue repository selection comes from authenticated controller configuration without Nestor", async (t) => {
  const calls = [];
  const apiKey = randomBytes(24).toString("hex");
  const registry = {
    schema: "hi/agamemnon/issue-repositories/v1",
    repositories: [
      { key: "first", repository: "Example/First", repositoryId: "R_first" },
      { key: "second", repository: "Example/Second", repositoryId: "R_second" },
    ],
  };
  const { url } = await fixture(t, {
    issueImport: {
      url: "http://127.0.0.1:9876/operator-base",
      apiKey,
      fetchImpl: async (target, options) => {
        calls.push({ target: String(target), ...options });
        return new Response(JSON.stringify(registry), { status: 200 });
      },
    },
  });
  assert.equal(
    (
      await fetch(`${url}/api/issue-intakes/repositories`, {
        headers: { origin: "https://elsewhere.example" },
      })
    ).status,
    403,
  );
  assert.deepEqual(calls, []);

  const response = await fetch(`${url}/api/issue-intakes/repositories`);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), registry);
  assert.equal(calls.length, 1);
  assert.equal(
    calls[0].target,
    "http://127.0.0.1:9876/v1/fleet/issue-intakes/repositories",
  );
  assert.equal(calls[0].method, "GET");
  assert.equal(calls[0].headers.authorization, `Bearer ${apiKey}`);
  assert.equal(calls[0].redirect, "error");
  assert.ok(calls[0].signal instanceof AbortSignal);
  const capability = await (await fetch(`${url}/api/capabilities`)).json();
  assert.equal(capability.issueImport.enabled, true);
  assert.equal(capability.researchIntake.enabled, false);
  assert.equal(capability.researchImport.enabled, false);
});

test("planned issue registry rejects duplicate native IDs and preserves reordered mappings", async (t) => {
  const entries = [
    { key: "first", repository: "Example/First", repositoryId: "R_first" },
    { key: "second", repository: "Example/Second", repositoryId: "R_second" },
  ];
  let repositories = [...entries].reverse();
  const calls = [];
  const { url } = await fixture(t, {
    issueImport: {
      url: "http://127.0.0.1:9876/operator-base",
      apiKey: randomBytes(24).toString("hex"),
      fetchImpl: async (target, options) => {
        calls.push([new URL(target).pathname, options.method]);
        return Response.json({
          schema: "hi/agamemnon/issue-repositories/v1",
          repositories,
        });
      },
    },
  });

  const read = () => fetch(`${url}/api/issue-intakes/repositories`);
  const positive = await read();
  assert.equal(positive.status, 200);
  assert.deepEqual(await positive.json(), {
    schema: "hi/agamemnon/issue-repositories/v1",
    repositories: [entries[1], entries[0]],
  });
  repositories = [entries[0], { ...entries[1], repositoryId: "R_first" }];
  const ambiguous = await read();
  assert.equal(ambiguous.status, 503);
  assert.deepEqual(await ambiguous.json(), {
    error: "registry_unavailable",
    outcome: "not_submitted",
  });
  assert.deepEqual(calls, [
    ["/v1/fleet/issue-intakes/repositories", "GET"],
    ["/v1/fleet/issue-intakes/repositories", "GET"],
  ]);
});

// Controlled wire examples follow Agamemnon issue510's frozen wire-v1 spec.
// They are not recorded controller output; the final producer fixture is separate.
async function plannedIssueFixture(t, options = {}) {
  const calls = [];
  const apiKey = randomBytes(24).toString("hex");
  const issue = {
    repository: "Example/Project",
    number: 42,
    url: "https://github.com/Example/Project/issues/42",
  };
  const input = {
    schema: "hi/agamemnon/issue-import/v1",
    repositoryKey: "project",
    issueNumber: 42,
    repositoryId: "R_project",
    issueId: "I_work",
    plan: { kind: "issue_body", digest: "a".repeat(64) },
  };
  const routing = {
    domain: "pipeline",
    hmasRole: "task-agent",
    stage: "implementation",
  };
  const inspection = {
    schema: "hi/agamemnon/issue-inspection/v1",
    repositoryKey: input.repositoryKey,
    repositoryId: input.repositoryId,
    issueId: input.issueId,
    issue,
    title: "Implement the selected plan",
    state: "open",
    plan: input.plan,
    observedAt: "2026-09-13T06:00:00Z",
  };
  const receipt = {
    schema: "hi/agamemnon/issue-import-receipt/v1",
    // Independently calculated with Python lexical JSON from the wire contract.
    taskId:
      "issue-25074367d8e8ec5e691f3246b29ff0a062128d856eab137b7f6c8885715188e2",
    state: "Pending",
    provenance: {
      schema: "hi/agamemnon/issue-intake/v1",
      forge: "github",
      repositoryId: input.repositoryId,
      issueId: input.issueId,
      issue,
      plan: input.plan,
      routing,
      observedAt: inspection.observedAt,
    },
    issue,
    routing,
  };
  const task = {
    task_id: receipt.taskId,
    state: "Pending",
    layer: "L3_TaskAgent",
    task: {
      id: receipt.taskId,
      state: "Pending",
      layer: "L3_TaskAgent",
      brief_id: "",
      parent_task_id: "",
      module: "",
      blocked_by: [],
      child_task_ids: [],
      repo: issue.repository,
      issue: issue.number,
      assigned_lead_id: "",
      description: "synthetic-private-plan",
      delivery: { issueIntake: receipt.provenance },
    },
  };
  const view = new FleetView();
  const server = await fixture(t, {
    view,
    issueImport: {
      url: "http://127.0.0.1:9876/operator-base",
      apiKey,
      observe: (event) => view.observe(event),
      fetchImpl: async (url, request) => {
        const call = {
          path: new URL(url).pathname + new URL(url).search,
          ...request,
        };
        calls.push(call);
        if (options.reply)
          return options.reply(call, { inspection, receipt, task });
        if (request.method === "POST")
          return new Response(JSON.stringify(receipt), { status: 201 });
        if (call.path.startsWith("/v1/tasks/"))
          return new Response(JSON.stringify(task), { status: 200 });
        return new Response(JSON.stringify(inspection), { status: 200 });
      },
    },
  });

  return { ...server, calls, apiKey, input, inspection, receipt, task };
}

test("planned issue inspection and explicit import preserve the selected native identity and snapshot", async (t) => {
  const { url, calls, input, inspection, receipt, view, apiKey } =
    await plannedIssueFixture(t);
  const inspected = await fetch(`${url}/api/issue-intakes/project/42`);
  assert.equal(inspected.status, 200);
  assert.deepEqual(await inspected.json(), inspection);
  assert.deepEqual(
    calls.map((call) => [call.path, call.method]),
    [["/v1/fleet/issue-intakes/project/42", "GET"]],
  );
  const imported = await fetch(`${url}/api/issue-intakes`, {
    method: "POST",
    headers: { origin: url, "content-type": "application/json" },
    body: JSON.stringify(input),
  });
  assert.equal(imported.status, 201);
  assert.deepEqual(await imported.json(), receipt);
  assert.equal(calls.length, 2);
  assert.equal(calls[1].path, "/v1/fleet/issue-intakes");
  assert.equal(calls[1].method, "POST");
  assert.deepEqual(JSON.parse(calls[1].body), input);
  for (const call of calls) {
    assert.equal(call.headers.authorization, `Bearer ${apiKey}`);
    assert.equal(call.redirect, "error");
    assert.ok(call.signal instanceof AbortSignal);
  }
  const events = view.snapshot().observations;
  assert.deepEqual(
    events.map((event) => event.operation),
    ["request", "response", "request", "response"],
  );
  assert.equal(events[0].messageId, events[1].messageId);
  assert.equal(events[2].messageId, events[3].messageId);
  assert.equal(events[2].correlationId, input.issueId);
  assert.equal(events[2].transport, "http");
  const raw = JSON.stringify(events);
  assert.equal(raw.includes(apiKey), false);
  assert.equal(raw.includes(input.plan.digest), false);
  assert.equal(raw.includes(inspection.title), false);
  assert.deepEqual(view.snapshot().resources.sessions, []);
});

test("planned issue selectors and request bodies reject ambiguous input before controller calls", async (t) => {
  const { url, calls, input } = await plannedIssueFixture(t);
  for (const path of [
    "/api/issue-intakes/project/42?digest=private",
    "/api/issue-intakes/project/42?planCommentId=one&planCommentId=two",
    "/api/issue-intakes/project/0",
    "/api/issue-intakes/project/2147483648",
    "/api/issue-intakes/project/42/extra",
    "/api/issue-intakes/%2Fother/42",
  ]) {
    assert.equal((await fetch(`${url}${path}`)).status, 400, path);
  }
  const validBody = JSON.stringify(input);
  for (const invalid of [
    { ...input, repository: "Other/Repository" },
    { ...input, issueNumber: 1.5 },
    { ...input, plan: { ...input.plan, digest: "A".repeat(64) } },
    { ...input, plan: { kind: "issue_comment", digest: input.plan.digest } },
    validBody.replace(
      '"repositoryKey":"project"',
      '"repositoryKey":"other","repositoryKey":"project"',
    ),
  ]) {
    const response = await fetch(`${url}/api/issue-intakes`, {
      method: "POST",
      headers: { origin: url, "content-type": "application/json" },
      body: typeof invalid === "string" ? invalid : JSON.stringify(invalid),
    });
    assert.equal(response.status, 400);
    assert.equal((await response.json()).outcome, "not_submitted");
  }
  assert.deepEqual(calls, []);
});

test("planned issue comment inspection binds the exact selected same-issue plan reference", async (t) => {
  const plan = {
    kind: "issue_comment",
    nodeId: "IC_selected",
    digest: "b".repeat(64),
  };
  const { url, calls, inspection } = await plannedIssueFixture(t, {
    reply: async (_call, value) =>
      new Response(JSON.stringify({ ...value.inspection, plan }), {
        status: 200,
      }),
  });
  const response = await fetch(
    `${url}/api/issue-intakes/project/42?planCommentId=IC_selected`,
  );
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ...inspection, plan });
  assert.equal(calls.length, 1);
  assert.equal(
    calls[0].path,
    "/v1/fleet/issue-intakes/project/42?planCommentId=IC_selected",
  );
});

test("planned issue task status is a neutral intrinsic projection without another task authority", async (t) => {
  const { url, calls, receipt, task } = await plannedIssueFixture(t);
  const response = await fetch(`${url}/api/tasks/${receipt.taskId}`);
  assert.equal(response.status, 200);
  const value = await response.json();
  assert.deepEqual(value, {
    schema: "hi/odysseus/imported-task/v1",
    taskId: receipt.taskId,
    state: task.state,
    layer: task.layer,
    provenance: receipt.provenance,
    issue: receipt.issue,
    assignment: null,
    claim: null,
    owner: null,
    resolution: null,
  });
  assert.deepEqual(
    calls.map((call) => [call.path, call.method]),
    [[`/v1/tasks/${receipt.taskId}/state`, "GET"]],
  );
  assert.equal(JSON.stringify(value).includes("synthetic-private-plan"), false);
});

test("neutral task route accepts claimed research provenance and rejects mixed kinds before owner lookup", async (t) => {
  const { receipt, taskState, upstreamCalls } = await researchImportFixture(t);
  const claim = {
    schema: "hi/fleet/claim/v1",
    targetKind: "sessions",
    targetId: "session-research",
    workerId: "worker-research",
    agentId: "agent-research",
    generation: 2,
    workspace: "/private/research-worktree",
  };
  taskState.state = taskState.task.state = "Delegated";
  taskState.task.assigned_lead_id = claim.agentId;
  taskState.task.fleet_claim = claim;
  const resource = {
    schema: "hi/fleet/v1",
    kind: claim.targetKind,
    id: claim.targetId,
    taskId: receipt.taskId,
    workerId: claim.workerId,
    agentId: claim.agentId,
    generation: claim.generation,
    workspace: claim.workspace,
    sessionId: claim.targetId,
    status: "admitted",
    claimStatus: "reserved",
  };
  let document = taskState;
  const direct = await plannedIssueFixture(t, {
    reply: async (call) =>
      Response.json(call.path.startsWith("/v1/tasks/") ? document : resource),
  });
  const read = (taskId) => fetch(`${direct.url}/api/tasks/${taskId}`);
  const positive = await read(receipt.taskId);
  assert.equal(positive.status, 200);
  const projected = await positive.json();
  assert.equal(projected.schema, "hi/odysseus/imported-task/v1");
  assert.equal(projected.taskId, receipt.taskId);
  assert.deepEqual(projected.provenance, receipt.provenance);
  assert.equal(projected.owner.workerId, claim.workerId);
  assert.equal(projected.owner.claimStatus, "reserved");
  assert.equal(JSON.stringify(projected).includes(claim.workspace), false);
  assert.deepEqual(
    direct.calls.map((call) => [call.path, call.method]),
    [
      [`/v1/tasks/${receipt.taskId}/state`, "GET"],
      [`/v1/fleet/sessions/${claim.targetId}`, "GET"],
      [`/v1/tasks/${receipt.taskId}/state`, "GET"],
    ],
  );
  // The direct identity/key/claim would all pass without the mixed-kind guard.
  // A research-key document with added direct provenance would instead fail
  // the separate direct-key check and would not isolate this boundary.
  document = structuredClone(direct.task);
  document.state = document.task.state = "Delegated";
  document.task.assigned_lead_id = claim.agentId;
  document.task.fleet_claim = claim;
  resource.taskId = direct.receipt.taskId;
  const directPositive = await read(direct.receipt.taskId);
  assert.equal(directPositive.status, 200);
  assert.deepEqual(
    (await directPositive.json()).provenance,
    direct.receipt.provenance,
  );
  assert.equal(direct.calls.length, 6);
  document.task.delivery.researchIntake = receipt.provenance;
  const mixed = await read(direct.receipt.taskId);
  assert.equal(mixed.status, 503);
  assert.deepEqual(await mixed.json(), {
    error: "task_unavailable",
    outcome: "unknown",
  });
  assert.deepEqual(
    direct.calls.slice(6).map((call) => [call.path, call.method]),
    [[`/v1/tasks/${direct.receipt.taskId}/state`, "GET"]],
  );
  assert.deepEqual(upstreamCalls, []);
});

test("planned issue identity rejects a lone surrogate before any controller call", async (t) => {
  const { url, calls, input } = await plannedIssueFixture(t);
  const response = await fetch(`${url}/api/issue-intakes`, {
    method: "POST",
    headers: { origin: url, "content-type": "application/json" },
    body: JSON.stringify({ ...input, issueId: "I_\ud800" }),
  });
  assert.equal(response.status, 400);
  assert.equal((await response.json()).outcome, "not_submitted");
  assert.deepEqual(calls, []);
});

test("planned issue receipts reject duplicate keys in actual upstream JSON", async (t) => {
  const { url, calls, input } = await plannedIssueFixture(t, {
    reply: async (_call, { receipt }) =>
      new Response(
        JSON.stringify(receipt).replace(
          '"state":"Pending"',
          '"state":"Completed","state":"Pending"',
        ),
        { status: 201 },
      ),
  });
  const response = await fetch(`${url}/api/issue-intakes`, {
    method: "POST",
    headers: { origin: url, "content-type": "application/json" },
    body: JSON.stringify(input),
  });
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {
    error: "import_unconfirmed",
    outcome: "unknown",
  });
  assert.equal(calls.length, 1);
});

test("actual controller issue fixture passes the adapter with Pending and reserved canonical ownership", async (t) => {
  // Exact output of Agamemnon FleetIssueConfigured.ExportsActualImportAndCanonicalOwnerTransition.
  // Its controlled GitHub/publisher execution is separate from this replay check.
  const raw = readFileSync(
    new URL("./fixtures/agamemnon-issue-contract.json", import.meta.url),
  );
  assert.equal(
    createHash("sha256").update(raw).digest("hex"),
    "b68d8ff2e4f5e2ca9d7a3e0384fd886702fab4f9f035b9461ee1cc1151dc4612",
  );
  const producer = JSON.parse(raw);
  let claimed = false;
  const { url, calls, view } = await plannedIssueFixture(t, {
    reply: async (call) => {
      let body;
      if (call.method === "POST") {
        assert.deepEqual(JSON.parse(call.body), producer.importRequest);
        return new Response(
          JSON.stringify(
            claimed ? producer.replayReceipt : producer.importReceipt,
          ),
          { status: claimed ? 200 : 201 },
        );
      }
      if (call.path.endsWith("/repositories")) body = producer.registry;
      else if (call.path.startsWith("/v1/fleet/issue-intakes/"))
        body = producer.inspection;
      else if (call.path.startsWith("/v1/tasks/"))
        body = claimed ? producer.claimedTask : producer.pendingTask;
      else body = producer.session;
      return new Response(JSON.stringify(body), { status: 200 });
    },
  });
  const get = async (path) => {
    const response = await fetch(`${url}${path}`);
    assert.equal(response.status, 200);
    return response.json();
  };
  assert.deepEqual(
    await get("/api/issue-intakes/repositories"),
    producer.registry,
  );
  assert.deepEqual(
    await get(
      `/api/issue-intakes/${producer.importRequest.repositoryKey}/${producer.importRequest.issueNumber}`,
    ),
    producer.inspection,
  );
  for (const expected of [producer.importReceipt, producer.replayReceipt]) {
    const response = await fetch(`${url}/api/issue-intakes`, {
      method: "POST",
      headers: { origin: url, "content-type": "application/json" },
      body: JSON.stringify(producer.importRequest),
    });
    assert.equal(response.status, claimed ? 200 : 201);
    assert.deepEqual(await response.json(), expected);
    const task = await get(`/api/tasks/${expected.taskId}`);
    assert.equal(task.schema, "hi/odysseus/imported-task/v1");
    assert.equal(task.state, expected.state);
    assert.deepEqual(task.provenance, expected.provenance);
    if (!claimed) assert.equal(task.owner, null);
    else {
      assert.equal(task.assignment.agentId, producer.session.agentId);
      assert.equal(task.claim.generation, producer.session.generation);
      assert.equal(task.owner.claimStatus, "reserved");
      assert.equal(task.owner.status, "admitted");
      assert.deepEqual(
        calls.slice(-3).map((call) => call.path),
        [
          `/v1/tasks/${expected.taskId}/state`,
          `/v1/fleet/sessions/${producer.session.id}`,
          `/v1/tasks/${expected.taskId}/state`,
        ],
      );
    }
    assert.equal(
      JSON.stringify(task).includes(producer.session.workspace),
      false,
    );
    claimed = true;
  }
  assert.equal(calls.filter((call) => call.method === "POST").length, 2);
  assert.deepEqual(view.snapshot().resources.sessions, []);
});

async function fixture(t, options = {}) {
  const view = options.view ?? new FleetView();
  const server = createDashboardServer({
    view,
    ...options,
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => {
    server.closeAllConnections();
    server.close();
  });
  const url = `http://127.0.0.1:${server.address().port}`;
  return { server, view, url };
}

test("a request-target decoder failure produces a bounded response without rejecting the handler", async (t) => {
  const { server, url } = await fixture(t);
  const output = {};
  const response = {
    setHeader() {},
    writeHead(status) {
      output.status = status;
    },
    end(value) {
      output.body = JSON.parse(value);
    },
  };
  // Inject a decoder fault directly. No malformed traffic is sent to a service.
  const request = {
    headers: { host: new URL(url).host },
    get url() {
      throw new TypeError("synthetic decoder failure");
    },
  };
  await server.listeners("request")[0](request, response);
  assert.equal(output.status, 400);
  assert.deepEqual(output.body, { error: "Invalid request target" });
});

test("private Unicode input survives an HTTP chunk boundary inside a code point", async (t) => {
  const submitted = [];
  const { url } = await fixture(t, {
    commands: {
      submit: async (input) => {
        submitted.push(input);
        return { code: 202, body: { status: "submitted" } };
      },
    },
  });

  const input = { text: "Review this 🌍 change\nwithout changing the input." };
  const bytes = Buffer.from(JSON.stringify(input));
  const split = bytes.indexOf(Buffer.from("🌍")) + 2;
  const status = await new Promise((resolve, reject) => {
    const request = httpRequest(
      `${url}/api/commands`,
      {
        method: "POST",
        headers: { origin: url, "content-type": "application/json" },
      },
      (response) => {
        response.resume();
        response.on("end", () => resolve(response.statusCode));
      },
    );
    request.on("error", reject);
    request.write(bytes.subarray(0, split), () => {
      setTimeout(() => request.end(bytes.subarray(split)), 20);
    });
  });
  assert.equal(status, 202);
  assert.deepEqual(submitted, [input]);
});

test("local work and flow metadata exclude private resource fields", async (t) => {
  const { url, view } = await fixture(t);

  view.setResources("sessions", [
    { id: "s1", agentId: "myrmidon-1", token: fixtureCredential },
  ]);
  const response = await fetch(`${url}/api/snapshot`);
  assert.equal(response.status, 200);
  const body = await response.text();
  assert.equal(body.includes("myrmidon-1"), true);
  assert.equal(body.includes(fixtureCredential), false);
});

test("command submission requires same-origin JSON intent and a bounded body", async (t) => {
  const submitted = [];
  const commands = {
    capabilities: { sessionCommands: { enabled: true } },
    submit: async (input) => {
      submitted.push(input);
      return {
        code: 202,
        body: { commandId: input.commandId, status: "submitted" },
      };
    },
  };
  const { url } = await fixture(t, { commands });
  const command = {
    commandId: "ui-" + "b".repeat(32),
    sessionId: "s1",
    workerId: "w1",
    generation: 3,
    operation: "input",
    text: "private synthetic input",
  };
  const send = (headers, input = command) =>
    fetch(`${url}/api/commands`, {
      method: "POST",
      headers: { "content-type": "application/json", ...headers },
      body: JSON.stringify(input),
    });
  assert.equal((await send({})).status, 403);
  assert.equal(
    (await send({ origin: "https://elsewhere.example" })).status,
    403,
  );
  assert.equal(
    (await send({ origin: url, "sec-fetch-site": "cross-site" })).status,
    403,
  );
  assert.deepEqual(submitted, []);
  assert.deepEqual(await (await fetch(`${url}/api/capabilities`)).json(), {
    ...commands.capabilities,
    researchIntake: { enabled: false },
    researchImport: { enabled: false },
  });
  const accepted = await send({ origin: url });
  assert.equal(accepted.status, 202);
  assert.equal((await accepted.json()).status, "submitted");
  assert.deepEqual(submitted, [command]);
  assert.equal(
    (await send({ origin: url }, { ...command, text: "x".repeat(131073) }))
      .status,
    400,
  );
  assert.equal(submitted.length, 1);
});

test("private request details preserve local origin and selected owner scope", async (t) => {
  const calls = [];
  const { url } = await fixture(t, {
    commands: {
      requests: async (scope) => {
        calls.push(scope);
        return {
          code: 200,
          body: {
            ...scope,
            requests: [
              {
                requestId: 19,
                kind: "command",
                command: "synthetic private command",
              },
            ],
          },
        };
      },
    },
  });
  const endpoint = `${url}/api/requests?sessionId=s1&workerId=w1&generation=3`;
  assert.equal(
    (
      await fetch(endpoint, {
        headers: { origin: "https://elsewhere.example" },
      })
    ).status,
    403,
  );
  assert.deepEqual(calls, []);

  const response = await fetch(endpoint);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(calls, [{ sessionId: "s1", workerId: "w1", generation: 3 }]);
  assert.equal(
    (await response.json()).requests[0].command,
    "synthetic private command",
  );
  assert.equal((await fetch(`${endpoint}&workerId=w2`)).status, 400);
  const snapshot = await (await fetch(`${url}/api/snapshot`)).text();
  assert.equal(snapshot.includes("synthetic private command"), false);
});

test("cross-origin snapshot/stream and arbitrary Host requests are rejected", async (t) => {
  const { url } = await fixture(t);
  assert.equal(
    (
      await fetch(`${url}/api/snapshot`, {
        headers: {
          origin: "https://elsewhere.example",
        },
      })
    ).status,
    403,
  );

  assert.equal(
    (
      await fetch(`${url}/api/events`, {
        headers: { origin: "https://elsewhere.example" },
      })
    ).status,
    403,
  );
  const status = await new Promise((resolve, reject) => {
    get(
      `${url}/api/snapshot`,
      { headers: { host: "elsewhere.example" } },
      (response) => {
        response.resume();
        resolve(response.statusCode);
      },
    ).on("error", reject);
  });
  assert.equal(status, 403);
});

test("local SSE sends a snapshot with a replay cursor and visible restart gap", async (t) => {
  const { url } = await fixture(t);

  const abort = new AbortController();
  t.after(() => abort.abort());
  const response = await fetch(`${url}/api/events?after=old-epoch:9`, {
    signal: abort.signal,
  });
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type"), /text\/event-stream/);
  const reader = response.body.getReader();
  const first = new TextDecoder().decode((await reader.read()).value);
  assert.match(first, /event: snapshot/);
  assert.match(first, /"gap":true/);
  assert.match(first, /id: /);
  await reader.cancel();
});

test("unrelated mutations fail without proxying work", async (t) => {
  const { url } = await fixture(t);

  assert.equal(
    (
      await fetch(`${url}/api/anything`, {
        method: "POST",
        headers: { origin: url },
      })
    ).status,
    404,
  );
});

async function researchImportFixture(t, options = {}) {
  const input = {
    schema: "hi/agamemnon/research-import/v1",
    intakeId: "research-" + "a".repeat(32),
    requestDigest: "b".repeat(64),
  };
  const issue = {
    repository: "homericintelligence/odysseus",
    number: 42,
    url: "https://github.com/homericintelligence/odysseus/issues/42",
  };
  const provenance = {
    schema: "hi/agamemnon/research-intake/v1",
    namespace: "pilot",
    intakeId: input.intakeId,
    requestDigest: input.requestDigest,
    bodyDigest: "c".repeat(64),
    generation: 1,
    attemptId: "d".repeat(32),
    issue,
    createdAt: "2026-09-12T12:00:00Z",
    confirmedAt: "2026-09-12T12:00:01Z",
  };
  const taskId =
    "research-" +
    createHash("sha256")
      .update(
        JSON.stringify({
          intakeId: input.intakeId,
          namespace: provenance.namespace,
          schema: "hi/agamemnon/research-task-key/v1",
        }),
      )
      .digest("hex");
  const receipt = {
    schema: "hi/agamemnon/research-import-receipt/v1",
    taskId,
    state: "Pending",
    provenance,
    issue,
    routing: { domain: "research", hmasRole: "task-agent", stage: "research" },
  };
  const taskState = {
    task_id: taskId,
    state: "Pending",
    layer: "L3_TaskAgent",
    task: {
      id: taskId,
      brief_id: "",
      parent_task_id: "",
      layer: "L3_TaskAgent",
      state: "Pending",
      subject: "Research intake",
      description: "synthetic-private-description",
      repo: issue.repository,
      module: "",
      issue: issue.number,
      assigned_lead_id: "",
      delivery: {
        researchIntake: provenance,
        privateMetadata: "synthetic-private-delivery",
      },
      blocked_by: [],
      child_task_ids: [],
      created_at: "2026-09-12T12:00:02Z",
      completed_at: "",
      escalations: [],
    },
  };
  const upstreamCalls = [];
  const commandCalls = [];
  const apiKey = randomBytes(24).toString("hex");
  const upstream = createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    upstreamCalls.push({
      method: request.method,
      path: request.url,
      authorization: request.headers.authorization,
      body: Buffer.concat(chunks).toString("utf8"),
    });
    if (
      request.method === "GET" &&
      request.url === `/v1/tasks/${taskId}/state`
    ) {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(taskState));
    } else {
      response.writeHead(201, { "content-type": "application/json" });
      response.end(JSON.stringify(receipt));
    }
  });
  await new Promise((done) => upstream.listen(0, "127.0.0.1", done));
  t.after(async () => {
    upstream.closeAllConnections();
    await new Promise((done) => upstream.close(done));
  });
  const view = options.view ?? new FleetView();
  const dashboard = await fixture(t, {
    view,
    researchImport: {
      url: `http://127.0.0.1:${upstream.address().port}`,
      apiKey,
      observe: (event) => view.observe(event),
    },
    commands: {
      submit: async (command) => {
        commandCalls.push(command);
        return { code: 202, body: { status: "submitted" } };
      },
    },
  });
  const send = (headers) =>
    fetch(`${dashboard.url}/api/research/imports`, {
      method: "POST",
      headers: { "content-type": "application/json", ...headers },
      body: JSON.stringify(input),
    });
  return {
    ...dashboard,
    input,
    receipt,
    taskState,
    apiKey,
    upstreamUrl: `http://127.0.0.1:${upstream.address().port}`,
    upstreamCalls,
    commandCalls,
    send,
  };
}

test("research import origin and cross-site failures have no upstream or worker effects", async (t) => {
  const { url, view, upstreamCalls, commandCalls, send } =
    await researchImportFixture(t);
  assert.equal((await send({})).status, 403);

  assert.equal(
    (await send({ origin: "https://elsewhere.example" })).status,
    403,
  );
  assert.equal(
    (await send({ origin: url, "sec-fetch-site": "cross-site" })).status,
    403,
  );
  assert.deepEqual(upstreamCalls, []);
  assert.deepEqual(commandCalls, []);
  assert.deepEqual(view.snapshot().resources.sessions, []);
  assert.deepEqual(view.snapshot().observations, []);
});

test("local research import forwards only the confirmed reference and returns its canonical task", async (t) => {
  const { url, input, receipt, apiKey, upstreamCalls, commandCalls, send } =
    await researchImportFixture(t);

  const response = await send({ origin: url });
  assert.equal(response.status, 201);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(await response.json(), receipt);
  assert.deepEqual(upstreamCalls, [
    {
      method: "POST",
      path: "/v1/fleet/research-intakes",
      authorization: `Bearer ${apiKey}`,
      body: JSON.stringify(input),
    },
  ]);
  assert.deepEqual(commandCalls, []);
});

test("research import capability is explicit and disabled configuration submits nothing", async (t) => {
  const { url } = await fixture(t);

  const capabilities = await (await fetch(`${url}/api/capabilities`)).json();
  const response = await fetch(`${url}/api/research/imports`, {
    method: "POST",
    headers: { origin: url, "content-type": "application/json" },
    body: JSON.stringify({
      schema: "hi/agamemnon/research-import/v1",
      intakeId: "research-01",
      requestDigest: "a".repeat(64),
    }),
  });
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {
    error: "not_configured",
    outcome: "not_submitted",
  });
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(capabilities.researchImport, { enabled: false });
});

test("research import capability reports configured service without submitting", async (t) => {
  const { url, upstreamCalls } = await researchImportFixture(t);

  const response = await fetch(`${url}/api/capabilities`);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(upstreamCalls, []);
  assert.deepEqual((await response.json()).researchImport, { enabled: true });
});

test("research import router rejects missing origin and malformed bodies before forwarding", async (t) => {
  const { url, input, upstreamCalls } = await researchImportFixture(t);

  for (const [name, body, headers, expected] of [
    ["missing origin", JSON.stringify(input), {}, 403],
    [
      "wrong content type",
      JSON.stringify(input),
      { origin: url, "content-type": "text/plain" },
      400,
    ],
    ["invalid UTF-8", Buffer.from([0xff, 0xfe]), { origin: url }, 400],
    [
      "extra selection",
      JSON.stringify({ ...input, url: "https://elsewhere.example" }),
      { origin: url },
      400,
    ],
    ["4097 bytes", JSON.stringify(input).padEnd(4097), { origin: url }, 400],
    [
      "multibyte overflow",
      JSON.stringify({ ...input, title: "λ".repeat(2100) }),
      { origin: url },
      400,
    ],
  ]) {
    await t.test(name, async () => {
      const response = await fetch(`${url}/api/research/imports`, {
        method: "POST",
        headers: { "content-type": "application/json", ...headers },
        body,
      });
      assert.equal(response.status, expected);
      assert.equal(response.headers.get("cache-control"), "no-store");
      assert.deepEqual(upstreamCalls, []);
    });
  }
  const accepted = await fetch(`${url}/api/research/imports`, {
    method: "POST",
    headers: { origin: url, "content-type": "application/json" },
    body: JSON.stringify(input).padEnd(4096),
  });
  assert.equal(accepted.status, 201);
  assert.equal(upstreamCalls.length, 1);
  assert.deepEqual(JSON.parse(upstreamCalls[0].body), input);
});

test("research task read rejects foreign origin before any canonical lookup", async (t) => {
  const { url, receipt, upstreamCalls, commandCalls } =
    await researchImportFixture(t);
  const response = await fetch(`${url}/api/research/tasks/${receipt.taskId}`, {
    headers: { origin: "https://elsewhere.example" },
  });
  assert.equal(response.status, 403);
  assert.deepEqual(upstreamCalls, []);
  assert.deepEqual(commandCalls, []);
});

test("local research task read projects the known unclaimed task using only canonical GET", async (t) => {
  const { url, view, receipt, apiKey, upstreamCalls, commandCalls } =
    await researchImportFixture(t);

  const response = await fetch(`${url}/api/research/tasks/${receipt.taskId}`);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(await response.json(), {
    schema: "hi/odysseus/research-task/v1",
    taskId: receipt.taskId,
    state: "Pending",
    layer: "L3_TaskAgent",
    provenance: receipt.provenance,
    issue: receipt.issue,
    assignment: null,
    claim: null,
    owner: null,
    resolution: null,
  });
  assert.deepEqual(upstreamCalls, [
    {
      method: "GET",
      path: `/v1/tasks/${receipt.taskId}/state`,
      authorization: `Bearer ${apiKey}`,
      body: "",
    },
  ]);
  assert.deepEqual(commandCalls, []);
  assert.deepEqual(view.snapshot().resources.sessions, []);
});

async function mainProcess(
  t,
  configuration = {},
  prepareDirectory = async () => {},
) {
  const directory = await mkdtemp(join(tmpdir(), "odysseus-main-fixture-"));
  await prepareDirectory(directory, configuration);
  const reservation = createServer();
  await new Promise((resolve) => reservation.listen(0, "127.0.0.1", resolve));
  const port = reservation.address().port;
  await new Promise((resolve) => reservation.close(resolve));
  const environment = {
    PATH: dirname(process.execPath),
    HOME: directory,
    LANG: "C.UTF-8",
    ODYSSEUS_WEB_PORT: String(port),
  };
  for (const [key, value] of Object.entries(configuration))
    if (value !== undefined) environment[key] = value;
  const child = spawn(
    process.execPath,
    [fileURLToPath(new URL("../server/main.mjs", import.meta.url))],
    {
      env: environment,
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  let stdout = "";
  let stderr = "";
  const closed = new Promise((resolve) =>
    child.once("close", (code, signal) => resolve({ code, signal })),
  );
  const started = new Promise((resolve, reject) => {
    const timer = setTimeout(
      () =>
        reject(
          new Error("Main fixture did not start or exit within five seconds"),
        ),
      5000,
    );
    const finish = (value) => {
      clearTimeout(timer);
      resolve(value);
    };
    child.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
      if (stdout.includes(`Odysseus Fleet: http://127.0.0.1:${port}`))
        finish({ kind: "listening" });
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    closed.then((result) => finish({ kind: "exit", ...result }));
  });
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null)
      child.kill("SIGTERM");
    let killTimer;
    let closeTimer;
    try {
      await Promise.race([
        closed,
        new Promise((resolve) => {
          killTimer = setTimeout(() => {
            child.kill("SIGKILL");
            resolve();
          }, 2000);
        }),
      ]);
      await Promise.race([
        closed,
        new Promise((_, reject) => {
          closeTimer = setTimeout(
            () =>
              reject(
                new Error("Owned main fixture did not exit after termination"),
              ),
            2000,
          );
        }),
      ]);
    } finally {
      clearTimeout(killTimer);
      clearTimeout(closeTimer);
      await rm(directory, { recursive: true, force: true });
    }
  });
  const outcome = await started;
  assert.equal(
    stderr.includes("EADDRINUSE"),
    false,
    "A port collision is a fixture setup failure",
  );
  return {
    url: `http://127.0.0.1:${port}`,
    outcome,
    stderr,
    stdout,
    directory,
  };
}

test("main serves loopback with no key and no writable UI-token state", async (t) => {
  const marker =
    "This file prevents creating the former default state directory.";
  const main = await mainProcess(t, {}, async (directory) => {
    await writeFile(join(directory, ".local"), marker, { flag: "wx" });
  });
  assert.equal(main.outcome.kind, "listening");
  const response = await fetch(`${main.url}/api/snapshot`);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("set-cookie"), null);
  assert.equal(
    (await response.json()).sources.agamemnon.status,
    "not_configured",
  );
  assert.equal(await readFile(join(main.directory, ".local"), "utf8"), marker);
  assert.equal(main.stdout.includes("Local sign-in token"), false);
});

test("main reads an explicitly registered output bundle with commands disabled", async (t) => {
  const cache = join(homedir(), ".cache");
  await mkdir(cache, { recursive: true, mode: 0o700 });
  const directory = await mkdtemp(join(cache, "odysseus-output-main-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const identity = {
    workerId: "fixture-worker",
    generation: 1,
    allocationId: "fixture-allocation",
    sessionId: "fixture-session",
    executionId: "fixture-execution",
    taskId: "fixture-task",
    agentId: "fixture-agent",
    providerThreadId: "fixture-thread",
  };
  const bundle = {
    schema: "hi/fleet/session-output/v1",
    identity,
    provider: { name: "codex", version: "0.153.4" },
    capture: {
      profile: "completed_command_items",
      complete: false,
      observedCompletedItems: 0,
      retainedItems: 0,
      omittedItems: 0,
      retentionLimited: false,
    },
    items: [],
  };
  const bytes = Buffer.from(JSON.stringify(bundle));
  const path = join(directory, "fixture.json");
  await writeFile(path, bytes, { flag: "wx", mode: 0o600 });
  const receiptDigest = createHash("sha256").update(bytes).digest("hex");
  const owner = {
    ...identity,
    id: identity.sessionId,
    schema: "hi/fleet/v1",
    kind: "sessions",
    host: "fixture-vm",
    workspace: "/work/fixture",
    status: "completed",
    claimStatus: "released",
  };
  const controller = createServer((request, response) => {
    assert.equal(request.method, "GET");
    assert.equal(request.headers.authorization, `Bearer ${fixtureCredential}`);
    response.writeHead(200, { "content-type": "application/json" });
    response.end(
      JSON.stringify(
        request.url === `/v1/fleet/sessions/${identity.sessionId}`
          ? owner
          : request.url === "/v1/fleet/sessions"
            ? { items: [owner], total: 1 }
            : { items: [], total: 0 },
      ),
    );
  });
  await new Promise((done) => controller.listen(0, "127.0.0.1", done));
  t.after(async () => {
    controller.closeAllConnections();
    await new Promise((done) => controller.close(done));
  });
  const main = await mainProcess(t, {
    ODYSSEUS_AGAMEMNON_URL: `http://127.0.0.1:${controller.address().port}`,
    AGAMEMNON_API_KEY: fixtureCredential,
    ODYSSEUS_SESSION_OUTPUT_BUNDLES: JSON.stringify([
      { path, receiptDigest, identity },
    ]),
  });
  assert.equal(main.outcome.kind, "listening");
  const response = await fetch(
    `${main.url}/api/session-output?sessionId=fixture-session&workerId=fixture-worker&generation=1`,
  );
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.ownership, "historical");
  assert.equal(result.receiptDigest, receiptDigest);
  assert.deepEqual(result.bundle, bundle);
  assert.equal(
    (await (await fetch(`${main.url}/api/capabilities`)).json()).sessionCommands
      .enabled,
    false,
  );
  assert.equal(main.stdout.includes(path), false);
});

test("main ignores legacy UI settings and preserves an existing token file", async (t) => {
  const retained = "synthetic legacy token remains unchanged\n";
  const main = await mainProcess(t, {}, async (directory, configuration) => {
    const legacyState = join(directory, "legacy-state");
    await mkdir(legacyState, { mode: 0o700 });
    await writeFile(join(legacyState, "access-token"), retained, {
      mode: 0o600,
      flag: "wx",
    });
    configuration.ODYSSEUS_WEB_STATE_DIR = legacyState;
    configuration.ODYSSEUS_WEB_TOKEN = "synthetic-legacy-override";
  });
  assert.equal(main.outcome.kind, "listening");
  const response = await fetch(`${main.url}/api/capabilities`);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("set-cookie"), null);
  assert.equal((await response.json()).sessionCommands.enabled, false);
  assert.equal(
    await readFile(
      join(main.directory, "legacy-state", "access-token"),
      "utf8",
    ),
    retained,
  );
  assert.equal(main.stdout.includes("Local sign-in token"), false);
});

test("planned issue main process uses the explicit feature flag and controller credentials", async (t) => {
  const registry = {
    schema: "hi/agamemnon/issue-repositories/v1",
    repositories: [
      {
        key: "project",
        repository: "Example/Project",
        repositoryId: "R_project",
      },
    ],
  };
  const calls = [];
  const authorityKey = randomBytes(24).toString("hex");
  const controller = createServer((request, response) => {
    calls.push({
      method: request.method,
      path: request.url,
      authorization: request.headers.authorization,
    });
    response.writeHead(200, { "content-type": "application/json" });
    response.end(
      JSON.stringify(
        request.url === "/v1/fleet/issue-intakes/repositories"
          ? registry
          : { items: [], total: 0 },
      ),
    );
  });
  await new Promise((done) => controller.listen(0, "127.0.0.1", done));
  t.after(async () => {
    controller.closeAllConnections();
    await new Promise((done) => controller.close(done));
  });
  for (const flag of [undefined, "1"]) {
    await t.test(flag ? "enabled" : "disabled", async (t) => {
      const main = await mainProcess(t, {
        ODYSSEUS_ENABLE_ISSUE_IMPORT: flag,
        ODYSSEUS_AGAMEMNON_URL: `http://127.0.0.1:${controller.address().port}`,
        AGAMEMNON_API_KEY: authorityKey,
      });
      assert.equal(main.outcome.kind, "listening");

      const capabilities = await (
        await fetch(`${main.url}/api/capabilities`)
      ).json();
      assert.equal(capabilities.issueImport?.enabled === true, flag === "1");
      const response = await fetch(
        `${main.url}/api/issue-intakes/repositories`,
      );
      assert.equal(response.status, flag ? 200 : 503);
      if (flag) assert.deepEqual(await response.json(), registry);
    });
  }
  assert.equal(
    calls.filter((call) => call.path === "/v1/fleet/issue-intakes/repositories")
      .length,
    1,
  );
  assert.ok(
    calls.every(
      (call) =>
        call.method === "GET" &&
        call.authorization === `Bearer ${authorityKey}`,
    ),
  );
  await t.test(
    "enabled incomplete configuration rejects startup",
    async (t) => {
      const main = await mainProcess(t, { ODYSSEUS_ENABLE_ISSUE_IMPORT: "1" });
      assert.equal(main.outcome.kind, "exit");
      assert.equal(main.outcome.code, 1);
    },
  );
});

test("research import main process requires explicit opt-in and wires the configured service", async (t) => {
  for (const [flag, enabled] of [
    [undefined, false],
    ["1", true],
  ]) {
    await t.test(enabled ? "enabled" : "disabled", async (t) => {
      const { upstreamUrl, apiKey, input, receipt, upstreamCalls } =
        await researchImportFixture(t);
      const main = await mainProcess(t, {
        ODYSSEUS_ENABLE_RESEARCH_IMPORT: flag,
        ODYSSEUS_AGAMEMNON_URL: upstreamUrl,
        AGAMEMNON_API_KEY: apiKey,
      });
      assert.equal(main.outcome.kind, "listening");

      const capabilities = await (
        await fetch(`${main.url}/api/capabilities`)
      ).json();
      assert.deepEqual(capabilities.researchImport, { enabled });
      const response = await fetch(`${main.url}/api/research/imports`, {
        method: "POST",
        headers: {
          origin: main.url,
          "content-type": "application/json",
        },
        body: JSON.stringify(input),
      });
      assert.equal(response.status, enabled ? 201 : 503);
      const imports = upstreamCalls.filter(
        (call) => call.path === "/v1/fleet/research-intakes",
      );
      assert.equal(imports.length, enabled ? 1 : 0);
      if (enabled) assert.deepEqual(await response.json(), receipt);
      // Main's existing full-resource collectors may make unrelated read-only GETs.
      assert.ok(
        upstreamCalls.every(
          (call) =>
            call.method === "GET" || call.path === "/v1/fleet/research-intakes",
        ),
      );
    });
  }
});

test("research import main process rejects enabled invalid configuration before accepting traffic", async (t) => {
  for (const configuration of [
    {},
    { ODYSSEUS_AGAMEMNON_URL: "http://127.0.0.1:9876" },
    {
      ODYSSEUS_AGAMEMNON_URL: "http://127.0.0.1:9876/?invalid",
      AGAMEMNON_API_KEY: fixtureCredential,
    },
  ]) {
    await t.test(JSON.stringify(Object.keys(configuration)), async (t) => {
      const main = await mainProcess(t, {
        ODYSSEUS_ENABLE_RESEARCH_IMPORT: "1",
        ...configuration,
      });
      assert.equal(main.outcome.kind, "exit");
      assert.equal(main.outcome.code, 1);
    });
  }
});

test("research task router rejects selectors and bodies before any upstream read", async (t) => {
  const { url, receipt, upstreamCalls } = await researchImportFixture(t);

  for (const suffix of [
    `${receipt.taskId}?namespace=other`,
    `${receipt.taskId}?digest=secret`,
    `${receipt.taskId}/extra`,
    "research-short",
    `research-${"A".repeat(64)}`,
    "%2Fother",
  ]) {
    const response = await fetch(`${url}/api/research/tasks/${suffix}`);
    assert.equal(response.status, 400);
    assert.equal(response.headers.get("cache-control"), "no-store");
  }
  const status = await new Promise((resolve, reject) => {
    const request = httpRequest(
      `${url}/api/research/tasks/${receipt.taskId}`,
      {
        method: "GET",
        headers: {
          "content-length": "2",
          "content-type": "application/json",
        },
      },
      (response) => {
        response.resume();
        response.on("end", () => resolve(response.statusCode));
      },
    );
    request.on("error", reject);
    request.end("{}");
  });
  assert.equal(status, 400);
  assert.equal(
    (
      await fetch(`${url}/api/research/tasks/${receipt.taskId}`, {
        method: "POST",
        headers: { origin: url },
      })
    ).status,
    404,
  );
  assert.equal((await fetch(`${url}/api/research/tasks`)).status, 404);
  assert.deepEqual(upstreamCalls, []);
  const disabled = await fixture(t);

  const response = await fetch(
    `${disabled.url}/api/research/tasks/${receipt.taskId}`,
  );
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {
    error: "not_configured",
    outcome: "not_submitted",
  });
});

test("actual import observations reach bounded local SSE history without leaking payload or freshness", async (t) => {
  const view = new FleetView({ historyLimit: 3 });
  const originalSources = structuredClone(view.snapshot().sources);
  const initialCursor = view.snapshot().cursor;
  const { url, input, receipt, apiKey, upstreamCalls } =
    await researchImportFixture(t, { view });

  const observed = [];
  for (let i = 0; i < 3; i++) {
    const response = await fetch(`${url}/api/research/imports`, {
      method: "POST",
      headers: { origin: url, "content-type": "application/json" },
      body: JSON.stringify(input),
    });
    assert.equal(response.status, 201);
    assert.deepEqual(await response.json(), receipt);
    observed.push(...view.snapshot().observations.slice(-2));
  }
  assert.equal(upstreamCalls.length, 3);
  assert.deepEqual(
    observed.map((e) => e.operation),
    ["request", "response", "request", "response", "request", "response"],
  );
  assert.equal(new Set(observed.map((e) => e.eventId)).size, 6);
  assert.deepEqual(
    observed.map((e) => e.sourceSequence),
    [1, 2, 3, 4, 5, 6],
  );
  for (let i = 0; i < 6; i += 2) {
    assert.equal(observed[i].messageId, observed[i + 1].messageId);
    assert.equal(observed[i].bytes, Buffer.byteLength(JSON.stringify(input)));
    assert.equal(observed[i].correlationId, input.intakeId);
  }
  const abort = new AbortController();
  t.after(() => abort.abort());
  const response = await fetch(
    `${url}/api/events?after=${encodeURIComponent(initialCursor)}`,
    { signal: abort.signal },
  );
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  const reader = response.body.getReader();
  let chunk = "";
  while (!chunk.includes("\n\n"))
    chunk += new TextDecoder().decode((await reader.read()).value);
  await reader.cancel();
  const snapshot = JSON.parse(
    chunk
      .split("\n")
      .find((line) => line.startsWith("data: "))
      .slice(6),
  );
  assert.equal(snapshot.gap, true);
  assert.equal(snapshot.dropped, 3);
  assert.deepEqual(snapshot.observations, observed.slice(-3));
  assert.deepEqual(snapshot.sources, originalSources);
  assert.deepEqual(snapshot.resources.sessions, []);
  for (const event of snapshot.observations) {
    assert.equal(event.transport, "http");
    assert.equal(event.generation, undefined);
    assert.equal(event.workerId, undefined);
  }
  for (const secret of [
    apiKey,
    input.requestDigest,
    receipt.provenance.bodyDigest,
    "synthetic-private-description",
    "synthetic-private-delivery",
  ])
    assert.equal(chunk.includes(secret), false);
});
