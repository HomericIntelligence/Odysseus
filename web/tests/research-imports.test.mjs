import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { createServer } from "node:http";
import { test } from "node:test";
import { createResearchImportService } from "../server/research-imports.mjs";
import { FleetView } from "../server/view.mjs";

const apiKey = randomBytes(24).toString("hex");
const input = {
  schema: "hi/agamemnon/research-import/v1",
  intakeId: "research-01",
  requestDigest: "a".repeat(64),
};
// Independent known vector from Agamemnon's test_fleet_research.cpp at a5809b8.
const taskId =
  "research-fa881bdde8da181cf538c601534b2c1ea548bd7addcb0efdf48bc5b904b0cb95";
function receipt(state = "Pending") {
  const issue = {
    repository: "homeric/research",
    number: 42,
    url: "https://github.com/homeric/research/issues/42",
  };
  return {
    schema: "hi/agamemnon/research-import-receipt/v1",
    taskId,
    state,
    provenance: {
      schema: "hi/agamemnon/research-intake/v1",
      namespace: "nestor-main",
      intakeId: input.intakeId,
      requestDigest: input.requestDigest,
      bodyDigest: "b".repeat(64),
      generation: 1,
      attemptId: "c".repeat(32),
      issue: { ...issue },
      createdAt: "2026-09-13T01:00:00Z",
      confirmedAt: "2026-09-13T01:00:01Z",
    },
    issue,
    routing: { domain: "research", hmasRole: "task-agent", stage: "research" },
  };
}
const jsonResponse = (body = receipt(), status = 201) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
function adapter(fetchImpl, options = {}) {
  return createResearchImportService({
    url: "http://127.0.0.1:9876/operator-base",
    apiKey,
    fetchImpl,
    ...options,
  });
}
async function loopback(t, handler) {
  const server = createServer(handler);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  });
  return `http://127.0.0.1:${server.address().port}`;
}

test("import preserves new versus replay state and the controller's lexical-key vector", async (t) => {
  for (const [status, state] of [
    [201, "Pending"],
    [200, "InProgress"],
    [200, "Completed"],
  ]) {
    await t.test(`${status} ${state}`, async () => {
      const calls = [];
      const service = adapter(async (url, options) => {
        calls.push({ url: String(url), ...options });
        return jsonResponse(receipt(state), status);
      });
      const result = await service.submit(input);
      assert.deepEqual(result, { code: status, body: receipt(state) });
      assert.equal(calls.length, 1);
      assert.equal(
        calls[0].url,
        "http://127.0.0.1:9876/v1/fleet/research-intakes",
      );
      assert.equal(calls[0].method, "POST");
      assert.equal(calls[0].headers.authorization, `Bearer ${apiKey}`);
      assert.deepEqual(JSON.parse(calls[0].body), input);
      assert.equal(calls[0].redirect, "error");
      assert.ok(calls[0].signal instanceof AbortSignal);
    });
  }
});

test("import configuration rejects invalid endpoints or credentials before transport", async (t) => {
  for (const [name, options] of [
    ["missing URL", { url: undefined }],
    ["remote HTTP", { url: "http://remote.example" }],
    ["URL credential", { url: "https://user:password@example.test" }],
    ["URL query", { url: "https://example.test/?route=other" }],
    ["URL fragment", { url: "https://example.test/#other" }],
    ["missing credential", { apiKey: undefined }],
    ["empty credential", { apiKey: "" }],
    ["wrong credential type", { apiKey: 42 }],
    ["header injection", { apiKey: "synthetic\r\nheader" }],
    ["credential byte bound", { apiKey: "λ".repeat(4097) }],
  ]) {
    await t.test(name, () => {
      let calls = 0;
      assert.throws(() => adapter(() => calls++, options));
      assert.equal(calls, 0);
    });
  }
});

test("invalid import references emit no request and preserve the transport boundary", async (t) => {
  for (const [name, value] of [
    ["null", null],
    ["array", []],
    ["wrong schema", { ...input, schema: "hi/nestor/intake/v1" }],
    ["missing digest", { schema: input.schema, intakeId: input.intakeId }],
    ["number ID", { ...input, intakeId: 42 }],
    ["short ID", { ...input, intakeId: "short" }],
    ["oversized ID", { ...input, intakeId: "r".repeat(65) }],
    ["path ID", { ...input, intakeId: "research/01" }],
    ["surrogate ID", { ...input, intakeId: "research-\ud800" }],
    ["digest type", { ...input, requestDigest: 42 }],
    ["digest short", { ...input, requestDigest: "a".repeat(63) }],
    ["digest long", { ...input, requestDigest: "a".repeat(65) }],
    ["digest case", { ...input, requestDigest: "A".repeat(64) }],
    ...["title", "body", "namespace", "repository", "url", "apiKey"].map(
      (key) => [key, { ...input, [key]: "must not be forwarded" }],
    ),
  ]) {
    await t.test(name, async () => {
      let calls = 0;
      const events = [];
      const service = adapter(
        async () => {
          calls++;
          return jsonResponse();
        },
        { observe: (event) => events.push(event) },
      );
      assert.deepEqual(await service.submit(value), {
        code: 400,
        body: { error: "invalid_request", outcome: "not_submitted" },
      });
      assert.equal(calls, 0);
      assert.deepEqual(events, []);
    });
  }
});

test("import refuses inconsistent receipts without coercion or exposing their contents", async (t) => {
  const cases = [
    ["schema", (v) => (v.schema = "other")],
    ["task key", (v) => (v.taskId = "research-" + "f".repeat(64))],
    ["new non-Pending state", (v) => (v.state = "InProgress")],
    ["unknown state", (v) => (v.state = "running")],
    ["routing domain", (v) => (v.routing.domain = "implementation")],
    ["routing role", (v) => (v.routing.hmasRole = "lead")],
    ["routing stage", (v) => (v.routing.stage = "execute")],
    ["provenance type", (v) => (v.provenance = [])],
    ["provenance schema", (v) => (v.provenance.schema = "other")],
    ["different intake", (v) => (v.provenance.intakeId = "research-02")],
    ["different digest", (v) => (v.provenance.requestDigest = "d".repeat(64))],
    ["different namespace", (v) => (v.provenance.namespace = "other")],
    ["body digest", (v) => (v.provenance.bodyDigest = "invalid")],
    ["generation type", (v) => (v.provenance.generation = "1")],
    ["generation value", (v) => (v.provenance.generation = 2)],
    ["attempt", (v) => (v.provenance.attemptId = "invalid")],
    ["timestamp", (v) => (v.provenance.confirmedAt = "not a date")],
    ["issue differs", (v) => (v.issue.number = 43)],
    ["issue type", (v) => (v.issue.number = "42")],
    ["issue URL", (v) => (v.issue.url = "https://elsewhere.example/42")],
    ["extra data", (v) => (v.privateData = "synthetic-private-content")],
  ];
  for (const [name, change] of cases) {
    await t.test(name, async () => {
      const invalid = receipt();
      change(invalid);
      let calls = 0;
      const service = adapter(async () => {
        calls++;
        return jsonResponse(invalid);
      });
      assert.deepEqual(await service.submit(input), {
        code: 503,
        body: { error: "import_unconfirmed", outcome: "unknown" },
      });
      assert.equal(calls, 1);
    });
  }
});

test("import bounds and strictly decodes the complete response body", async (t) => {
  const valid = JSON.stringify(receipt());
  for (const [name, bytes, code] of [
    ["exactly 2 MiB", Buffer.from(valid.padEnd(2 * 1024 * 1024)), 201],
    ["over 2 MiB", Buffer.from(valid.padEnd(2 * 1024 * 1024 + 1)), 503],
    ["invalid UTF-8", Buffer.from([0xff, 0xfe]), 503],
    ["truncated JSON", Buffer.from(valid.slice(0, -1)), 503],
  ]) {
    await t.test(name, async () => {
      const service = adapter(async () => new Response(bytes, { status: 201 }));
      assert.equal((await service.submit(input)).code, code);
    });
  }
});

test("remote failures remain finite and sanitized with no automatic mutation retry", async (t) => {
  for (const [status, code, error] of [
    [400, 400, "invalid_request"],
    [404, 404, "intake_not_found"],
    [409, 409, "import_conflict"],
    [503, 503, "import_unconfirmed"],
    [500, 503, "import_unconfirmed"],
  ]) {
    await t.test(String(status), async () => {
      let calls = 0;
      const service = adapter(async () => {
        calls++;
        return new Response("synthetic-private-error " + apiKey, { status });
      });
      assert.deepEqual(await service.submit(input), {
        code,
        body: { error, outcome: "unknown" },
      });
      assert.equal(calls, 1);
    });
  }
});

test("import refuses a real HTTP redirect without contacting its destination", async (t) => {
  let redirected = 0;
  const destination = await loopback(t, (_, response) => {
    redirected++;
    response.end("not an authorized destination");
  });
  let attempts = 0;
  const url = await loopback(t, (_, response) => {
    attempts++;
    response.writeHead(307, { location: destination });
    response.end();
  });
  const result = await createResearchImportService({ url, apiKey }).submit(
    input,
  );
  assert.equal(result.code, 503);
  assert.equal(result.body.outcome, "unknown");
  assert.equal(attempts, 1);
  assert.equal(redirected, 0);
});

test("four occupied import operations reject a fifth and release slots after failure", async () => {
  const releases = [];
  let fourStarted;
  const started = new Promise((resolve) => (fourStarted = resolve));
  const service = adapter(
    () =>
      new Promise((resolve) => {
        releases.push(resolve);
        if (releases.length === 4) fourStarted();
      }),
  );
  const operations = Array.from({ length: 4 }, () => service.submit(input));
  await started;
  assert.deepEqual(await service.submit(input), {
    code: 429,
    body: { error: "busy", outcome: "not_submitted" },
  });
  releases[0](new Response("invalid", { status: 201 }));
  assert.equal((await operations[0]).code, 503);
  const next = service.submit(input);
  assert.equal(releases.length, 5);
  for (const release of releases.slice(1)) release(jsonResponse());
  assert.deepEqual(
    (await Promise.all([...operations.slice(1), next])).map((v) => v.code),
    [201, 201, 201, 201],
  );
});

test("transport failures release their slots and cannot invent response observations", async () => {
  const events = [];
  let calls = 0;
  const service = adapter(
    async () => {
      calls++;
      throw new Error("synthetic-private-error " + apiKey);
    },
    { observe: (event) => events.push(event) },
  );
  for (let attempt = 0; attempt < 5; attempt++) {
    assert.deepEqual(await service.submit(input), {
      code: 503,
      body: { error: "import_unconfirmed", outcome: "unknown" },
    });
  }
  assert.equal(calls, 5);
  assert.equal(events.length, 5);
  assert.ok(events.every((event) => event.operation === "request"));
  assert.equal(JSON.stringify(events).includes(apiKey), false);
  assert.equal(
    JSON.stringify(events).includes("synthetic-private-error"),
    false,
  );
});

test("actual import HTTP observations enter FleetView without claiming worker execution or source freshness", async () => {
  const view = new FleetView({ historyLimit: 2 });
  const sources = structuredClone(view.snapshot().sources);
  const service = adapter(async () => jsonResponse(), {
    observe: (event) => view.observe(event),
  });
  assert.equal((await service.submit(input)).code, 201);
  const snapshot = view.snapshot();
  const events = snapshot.observations;
  assert.equal(events.length, 2);
  assert.deepEqual(
    events.map((event) => event.operation),
    ["request", "response"],
  );
  assert.ok(events.every((event) => event.transport === "http"));
  for (const event of events)
    assert.deepEqual(
      new Set([event.source, event.target]),
      new Set(["odysseus", "agamemnon"]),
    );
  assert.equal(events[0].source, "odysseus");
  assert.equal(events[0].target, "agamemnon");
  assert.ok(
    events.every(
      (event) =>
        typeof event.eventId === "string" && typeof event.sourceId === "string",
    ),
  );
  assert.notEqual(events[0].eventId, events[1].eventId);
  assert.equal(events[0].messageId, events[1].messageId);
  assert.ok(events[1].sourceSequence > events[0].sourceSequence);
  assert.equal(events[0].sourceId, events[1].sourceId);
  for (const event of events) {
    assert.equal(event.generation, undefined);
    assert.equal(event.workerId, undefined);
    if (event.operation === "request" && event.bytes !== undefined)
      assert.equal(event.bytes, Buffer.byteLength(JSON.stringify(input)));
    if (event.operation === "response" && event.bytes !== undefined)
      assert.equal(event.bytes, Buffer.byteLength(JSON.stringify(receipt())));
  }
  for (const secret of [
    apiKey,
    input.requestDigest,
    receipt().provenance.bodyDigest,
  ])
    assert.equal(JSON.stringify(events).includes(secret), false);
  assert.deepEqual(snapshot.resources.sessions, []);
  assert.deepEqual(snapshot.sources, sources);
});

function taskDocument(state = "Pending") {
  const imported = receipt(state);
  return {
    task_id: taskId,
    state,
    layer: "L3_TaskAgent",
    task: {
      id: taskId,
      brief_id: "",
      parent_task_id: "",
      layer: "L3_TaskAgent",
      state,
      subject: "Research intake",
      description: "synthetic-private-description",
      repo: imported.issue.repository,
      module: "",
      issue: imported.issue.number,
      assigned_lead_id: "",
      delivery: {
        researchIntake: imported.provenance,
        privateData: "synthetic-private-delivery",
      },
      blocked_by: [],
      child_task_ids: [],
      created_at: "2026-09-13T01:00:02Z",
      completed_at: "",
      escalations: [],
    },
  };
}

function claimedTask() {
  const document = taskDocument("Delegated");
  const claim = {
    schema: "hi/fleet/claim/v1",
    targetKind: "sessions",
    targetId: "session-owned",
    workerId: "worker-owned",
    agentId: "agent-owned",
    generation: 4,
    workspace: "/private/synthetic-worktree",
  };
  document.task.fleet_claim = claim;
  document.task.assigned_lead_id = claim.agentId;
  const resource = {
    schema: "hi/fleet/v1",
    id: claim.targetId,
    kind: claim.targetKind,
    taskId,
    workerId: claim.workerId,
    agentId: claim.agentId,
    generation: claim.generation,
    workspace: claim.workspace,
    status: "running",
    claimStatus: "claimed",
    createdAt: "2026-09-13T01:00:03Z",
    lastActivityAt: null,
    waitingReason: null,
    privateMetadata: "synthetic-owner-private-data",
  };
  return { document, claim, resource };
}

test("task owner lookup verifies the exact bare Fleet target then rereads the canonical claim", async () => {
  const { document, claim, resource } = claimedTask();
  const calls = [];
  const view = new FleetView();
  const sources = structuredClone(view.snapshot().sources);
  const service = adapter(
    async (url, options) => {
      calls.push({
        path: new URL(url).pathname,
        method: options.method,
        body: options.body,
      });
      return jsonResponse(
        new URL(url).pathname === `/v1/fleet/sessions/${claim.targetId}`
          ? resource
          : document,
        200,
      );
    },
    { observe: (event) => view.observe(event) },
  );
  const result = await service.readTask(taskId);
  assert.equal(result.code, 200);
  assert.deepEqual(calls, [
    { path: `/v1/tasks/${taskId}/state`, method: "GET", body: undefined },
    {
      path: `/v1/fleet/sessions/${claim.targetId}`,
      method: "GET",
      body: undefined,
    },
    { path: `/v1/tasks/${taskId}/state`, method: "GET", body: undefined },
  ]);
  assert.deepEqual(result.body.assignment, { agentId: claim.agentId });
  assert.deepEqual(result.body.claim, {
    targetKind: claim.targetKind,
    targetId: claim.targetId,
    workerId: claim.workerId,
    agentId: claim.agentId,
    generation: claim.generation,
  });
  for (const key of [
    "targetKind",
    "targetId",
    "workerId",
    "agentId",
    "generation",
  ])
    assert.equal(result.body.owner[key], claim[key]);
  assert.equal(result.body.owner.status, "running");
  assert.equal(result.body.owner.claimStatus, "claimed");
  for (const secret of [
    claim.workspace,
    "synthetic-private-description",
    "synthetic-private-delivery",
    "synthetic-owner-private-data",
  ])
    assert.equal(JSON.stringify(result.body).includes(secret), false);
  assert.deepEqual(view.snapshot().sources, sources);
  assert.deepEqual(view.snapshot().resources.sessions, []);
});

test("task identity rejects malformed standalone documents without owner discovery", async (t) => {
  const invalid = [
    [
      "outer ID",
      (d) => {
        d.task_id = "research-" + "0".repeat(64);
      },
    ],
    [
      "nested ID",
      (d) => {
        d.task.id = "other";
      },
    ],
    [
      "outer state",
      (d) => {
        d.state = "Failed";
      },
    ],
    [
      "unsupported state",
      (d) => {
        d.state = d.task.state = "Ready";
      },
    ],
    [
      "outer layer",
      (d) => {
        d.layer = "L2_ModuleLead";
      },
    ],
    [
      "nonresearch layer",
      (d) => {
        d.layer = d.task.layer = "L2_ModuleLead";
      },
    ],
    [
      "parent task",
      (d) => {
        d.task.parent_task_id = "parent";
      },
    ],
    [
      "brief",
      (d) => {
        d.task.brief_id = "brief";
      },
    ],
    [
      "module",
      (d) => {
        d.task.module = "module";
      },
    ],
    [
      "dependency",
      (d) => {
        d.task.blocked_by = ["dependency"];
      },
    ],
    [
      "child",
      (d) => {
        d.task.child_task_ids = ["child"];
      },
    ],
    [
      "repository",
      (d) => {
        d.task.repo = "homeric/other";
      },
    ],
    [
      "issue type",
      (d) => {
        d.task.issue = "42";
      },
    ],
    [
      "provenance schema",
      (d) => {
        d.task.delivery.researchIntake.schema = "other";
      },
    ],
    [
      "provenance key",
      (d) => {
        d.task.delivery.researchIntake.namespace = "another";
      },
    ],
    [
      "digest type",
      (d) => {
        d.task.delivery.researchIntake.requestDigest = 12;
      },
    ],
    [
      "generation type",
      (d) => {
        d.task.delivery.researchIntake.generation = "1";
      },
    ],
    [
      "canonical issue URL",
      (d) => {
        d.task.delivery.researchIntake.issue.url += "?other";
      },
    ],
    [
      "assignment type",
      (d) => {
        d.task.assigned_lead_id = 42;
      },
    ],
  ];
  for (const [name, change] of invalid)
    await t.test(name, async () => {
      const document = taskDocument();
      change(document);
      const paths = [];
      const service = adapter(async (url) => {
        paths.push(new URL(url).pathname);
        return jsonResponse(document, 200);
      });
      assert.deepEqual(await service.readTask(taskId), {
        code: 503,
        body: { error: "task_unavailable", outcome: "unknown" },
      });
      assert.deepEqual(paths, [`/v1/tasks/${taskId}/state`]);
    });
});

test("task claim validation refuses malformed or unassigned claims before target access", async (t) => {
  for (const [name, change] of [
    [
      "null",
      (d) => {
        d.task.fleet_claim = null;
      },
    ],
    [
      "schema",
      (d) => {
        d.task.fleet_claim.schema = "other";
      },
    ],
    [
      "unlisted kind",
      (d) => {
        d.task.fleet_claim.targetKind = "workers";
      },
    ],
    [
      "path selector",
      (d) => {
        d.task.fleet_claim.targetId = "../sessions";
      },
    ],
    [
      "worker type",
      (d) => {
        d.task.fleet_claim.workerId = 4;
      },
    ],
    [
      "agent type",
      (d) => {
        d.task.fleet_claim.agentId = 4;
      },
    ],
    [
      "generation type",
      (d) => {
        d.task.fleet_claim.generation = "4";
      },
    ],
    [
      "zero generation",
      (d) => {
        d.task.fleet_claim.generation = 0;
      },
    ],
    [
      "workspace type",
      (d) => {
        d.task.fleet_claim.workspace = null;
      },
    ],
    [
      "unknown selector",
      (d) => {
        d.task.fleet_claim.url = "http://elsewhere.test";
      },
    ],
    [
      "assignment mismatch",
      (d) => {
        d.task.assigned_lead_id = "other-agent";
      },
    ],
  ])
    await t.test(name, async () => {
      const { document } = claimedTask();
      change(document);
      const paths = [];
      const service = adapter(async (url) => {
        paths.push(new URL(url).pathname);
        return jsonResponse(document, 200);
      });
      assert.equal((await service.readTask(taskId)).code, 503);
      assert.deepEqual(paths, [`/v1/tasks/${taskId}/state`]);
    });
});

test("task owner matching rejects every changed raw identity without navigation or enumeration", async (t) => {
  for (const [field, value] of [
    ["taskId", "research-" + "1".repeat(64)],
    ["kind", "executions"],
    ["id", "other-session"],
    ["workerId", "other-worker"],
    ["agentId", "other-agent"],
    ["generation", 5],
    ["workspace", "/other/workspace"],
    ["sessionId", "other-session"],
  ])
    await t.test(field, async () => {
      const { document, resource, claim } = claimedTask();
      resource[field] = value;
      const paths = [];
      const service = adapter(async (url) => {
        paths.push(new URL(url).pathname);
        return jsonResponse(paths.length === 1 ? document : resource, 200);
      });
      assert.deepEqual(await service.readTask(taskId), {
        code: 409,
        body: { error: "task_conflict", outcome: "unknown" },
      });
      assert.deepEqual(paths, [
        `/v1/tasks/${taskId}/state`,
        `/v1/fleet/sessions/${claim.targetId}`,
      ]);
    });
});

test("task reread rejects valid claim assignment state and provenance changes", async (t) => {
  for (const [name, change] of [
    [
      "claim generation",
      (d) => {
        d.task.fleet_claim.generation++;
      },
    ],
    [
      "assignment and claim agent",
      (d) => {
        d.task.assigned_lead_id = d.task.fleet_claim.agentId = "next-agent";
      },
    ],
    [
      "state",
      (d) => {
        d.state = d.task.state = "InProgress";
      },
    ],
    [
      "provenance",
      (d) => {
        d.task.delivery.researchIntake.bodyDigest = "d".repeat(64);
      },
    ],
    [
      "claim released from task",
      (d) => {
        delete d.task.fleet_claim;
      },
    ],
  ])
    await t.test(name, async () => {
      const { document, resource } = claimedTask();
      const reread = structuredClone(document);
      change(reread);
      let requests = 0;
      const service = adapter(async () =>
        jsonResponse([document, resource, reread][requests++], 200),
      );
      assert.deepEqual(await service.readTask(taskId), {
        code: 409,
        body: { error: "task_conflict", outcome: "unknown" },
      });
      assert.equal(requests, 3);
    });
});

test("task reads retain assigned unclaimed and execution-only states without manufacturing sessions", async (t) => {
  await t.test("assigned unclaimed", async () => {
    const document = taskDocument("Delegated");
    document.task.assigned_lead_id = "assigned-agent";
    let requests = 0;
    const service = adapter(async () => {
      requests++;
      return jsonResponse(document, 200);
    });
    const result = await service.readTask(taskId);
    assert.equal(result.code, 200);
    assert.deepEqual(result.body.assignment, { agentId: "assigned-agent" });
    assert.equal(result.body.claim, null);
    assert.equal(result.body.owner, null);
    assert.equal(requests, 1);
  });
  for (const kind of ["executions", "build-jobs"])
    await t.test(kind, async () => {
      const { document, resource, claim } = claimedTask();
      claim.targetKind = resource.kind = kind;
      claim.targetId = resource.id = `${kind}-owned`;
      if (kind === "executions") resource.executionId = resource.id;
      const paths = [];
      const view = new FleetView();
      const service = adapter(
        async (url) => {
          paths.push(new URL(url).pathname);
          return jsonResponse(paths.length === 2 ? resource : document, 200);
        },
        { observe: (event) => view.observe(event) },
      );
      const result = await service.readTask(taskId);
      assert.equal(result.code, 200);
      assert.equal(result.body.owner.targetKind, kind);
      assert.equal(result.body.owner.sessionId, undefined);
      assert.equal(paths[1], `/v1/fleet/${kind}/${claim.targetId}`);
      assert.deepEqual(view.snapshot().resources.sessions, []);
    });
});

test("task manual resolution preserves terminal retained ownership without upgrading approval", async (t) => {
  for (const [state, outcome, decision] of [
    ["Completed", "completed", "approve_completion"],
    ["Failed", "failed", "reject_completion"],
  ])
    await t.test(state, async () => {
      const { document, resource, claim } = claimedTask();
      document.state = document.task.state = state;
      document.task.fleet_resolution = {
        provenance: "manual",
        verifiedApproval: false,
        generation: claim.generation,
        outcome,
        decision,
        decisionId: "private-decision",
        reviewerId: "private-reviewer",
        evidenceRef: "private-evidence",
      };
      resource.status = outcome;
      resource.claimStatus = "released";
      resource.resolution = structuredClone(document.task.fleet_resolution);
      const paths = [];
      const view = new FleetView();
      const service = adapter(
        async (url) => {
          paths.push(new URL(url).pathname);
          return jsonResponse(paths.length === 2 ? resource : document, 200);
        },
        { observe: (event) => view.observe(event) },
      );
      const result = await service.readTask(taskId);
      assert.equal(result.code, 200);
      assert.equal(result.body.state, state);
      assert.equal(result.body.owner.claimStatus, "released");
      assert.deepEqual(result.body.resolution, {
        provenance: "manual",
        verifiedApproval: false,
        outcome,
        decision,
      });
      assert.equal(result.body.assignment.agentId, claim.agentId);
      for (const secret of [
        "private-decision",
        "private-reviewer",
        "private-evidence",
        claim.workspace,
      ])
        assert.equal(JSON.stringify(result.body).includes(secret), false);
      assert.equal(paths.length, 3);
      assert.deepEqual(view.snapshot().resources.sessions, []);
    });
});

test("task manual resolution rejects unsupported approval and inconsistent terminal identity", async (t) => {
  for (const [name, change] of [
    [
      "approval upgrade",
      (d) => {
        d.task.fleet_resolution.verifiedApproval = true;
      },
    ],
    [
      "approval coercion",
      (d) => {
        d.task.fleet_resolution.verifiedApproval = "false";
      },
    ],
    [
      "provenance",
      (d) => {
        d.task.fleet_resolution.provenance = "automatic";
      },
    ],
    [
      "generation",
      (d) => {
        d.task.fleet_resolution.generation = 5;
      },
    ],
    [
      "outcome",
      (d) => {
        d.task.fleet_resolution.outcome = "running";
      },
    ],
    [
      "decision",
      (d) => {
        d.task.fleet_resolution.decision = "reject_completion";
      },
    ],
    [
      "nonterminal state",
      (d) => {
        d.state = d.task.state = "InProgress";
      },
    ],
    [
      "missing claim",
      (d) => {
        delete d.task.fleet_claim;
      },
    ],
  ])
    await t.test(name, async () => {
      const { document, resource } = claimedTask();
      document.state = document.task.state = "Completed";
      document.task.fleet_resolution = {
        provenance: "manual",
        verifiedApproval: false,
        generation: 4,
        outcome: "completed",
        decision: "approve_completion",
        decisionId: "private-decision",
        reviewerId: "private-reviewer",
        evidenceRef: "private-evidence",
      };
      resource.status = "completed";
      resource.claimStatus = "released";
      change(document);
      let count = 0;
      const service = adapter(async () =>
        jsonResponse(++count === 2 ? resource : document, 200),
      );
      const result = await service.readTask(taskId);
      assert.equal(result.code, 503);
      assert.equal(result.body.owner, undefined);
      assert.equal(result.body.resolution, undefined);
      assert.equal(count, 1);
    });
});

test("task failures preserve finite errors and never enumerate or replace missing identities", async (t) => {
  for (const [name, statuses, bodies, expected] of [
    ["task absent", [404], [], 404],
    ["task unavailable", [503], [], 503],
    ["target absent", [200, 404], [], 503],
    ["invalid target schema", [200, 200], [null, { schema: "other" }], 503],
    ["task reread absent", [200, 200, 404], [], 503],
  ])
    await t.test(name, async () => {
      const { document, resource, claim } = claimedTask();
      const paths = [];
      const service = adapter(async (url, options) => {
        assert.equal(options.method, "GET");
        assert.equal(options.body, undefined);
        const index = paths.push(new URL(url).pathname) - 1;
        return jsonResponse(
          bodies[index] ?? (index === 1 ? resource : document),
          statuses[index],
        );
      });
      const result = await service.readTask(taskId);
      assert.deepEqual(result, {
        code: expected,
        body: {
          error: expected === 404 ? "task_not_found" : "task_unavailable",
          outcome: "unknown",
        },
      });
      assert.deepEqual(
        paths,
        [
          `/v1/tasks/${taskId}/state`,
          `/v1/fleet/sessions/${claim.targetId}`,
          `/v1/tasks/${taskId}/state`,
        ].slice(0, statuses.length),
      );
    });
});

test("imports and task reads share four operation slots and release every completed read", async () => {
  const release = [];
  const paths = [];
  const service = adapter(async (url, options) => {
    paths.push({ path: new URL(url).pathname, method: options.method });
    return new Promise((resolve) =>
      release.push(() =>
        resolve(
          options.method === "POST"
            ? jsonResponse()
            : jsonResponse(taskDocument(), 200),
        ),
      ),
    );
  });
  const pending = [
    service.submit(input),
    service.readTask(taskId),
    service.submit(input),
    service.readTask(taskId),
  ];
  assert.equal(paths.length, 4);
  for (const call of [
    () => service.submit(input),
    () => service.readTask(taskId),
  ])
    assert.deepEqual(await call(), {
      code: 429,
      body: { error: "busy", outcome: "not_submitted" },
    });
  assert.equal(paths.length, 4);
  release.splice(0).forEach((done) => done());
  assert.deepEqual(
    (await Promise.all(pending)).map((r) => r.code),
    [201, 200, 201, 200],
  );
  const next = service.readTask(taskId);
  assert.equal(paths.length, 5);
  release.shift()();
  assert.equal((await next).code, 200);
});

test(
  "real HTTP operations enforce one five-second deadline across headers body and owner rereads",
  { concurrency: true, timeout: 9000 },
  async (t) => {
    await Promise.all(
      ["import headers", "import body", "owner reread body"].map((phase) =>
        t.test(phase, async (t) => {
          const { document, resource } = claimedTask();
          const requests = [];
          const timers = [];
          t.after(() => timers.forEach(clearTimeout));
          const url = await loopback(t, (request, response) => {
            requests.push({ method: request.method, path: request.url });
            const index = requests.length;
            if (phase === "owner reread body" && index <= 2) {
              // Two measured response delays spend the same operation budget; the last body never completes.
              timers.push(
                setTimeout(() => {
                  response.writeHead(200, {
                    "content-type": "application/json",
                  });
                  response.end(
                    JSON.stringify(index === 1 ? document : resource),
                  );
                }, 1800),
              );
            } else if (phase !== "import headers") {
              response.writeHead(phase === "import body" ? 201 : 200, {
                "content-type": "application/json",
              });
              response.write('{"schema":');
            }
          });
          const events = [];
          const service = createResearchImportService({
            url,
            apiKey,
            observe: (e) => events.push(e),
          });
          const started = performance.now();
          const result = await (phase === "owner reread body"
            ? service.readTask(taskId)
            : service.submit(input));
          const elapsed = performance.now() - started;
          assert.equal(result.code, 503);
          assert.ok(
            elapsed >= 4500 && elapsed < 7000,
            `actual elapsed ${elapsed} ms`,
          );
          assert.equal(requests.length, phase === "owner reread body" ? 3 : 1);
          assert.equal(
            events.filter((e) => e.operation === "request").length,
            requests.length,
          );
          assert.equal(
            events.filter((e) => e.operation === "response").length,
            phase === "import headers" ? 0 : requests.length,
          );
          assert.equal(
            events.some(
              (e) => e.operation === "ack" || Object.hasOwn(e, "generation"),
            ),
            false,
          );
          assert.equal(result.body.outcome, "unknown");
        }),
      ),
    );
  },
);
