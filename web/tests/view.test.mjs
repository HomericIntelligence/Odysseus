import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { FleetView, validResourceCollection } from "../server/view.mjs";
import { activeAgentCount, matchPacket } from "../src/selectors.ts";

const buildContract = JSON.parse(
  readFileSync(
    new URL("./fixtures/agamemnon-build-contract.json", import.meta.url),
    "utf8",
  ),
);

test("subordinate builds retain tool ownership and parent linkage without reporting authorization as activity", () => {
  for (const point of [
    "admission",
    "persistedGrantDocument",
    "cancelResponse",
    "terminalResponse",
  ]) {
    const raw = buildContract[point].record;
    const view = new FleetView({ now: () => Date.parse(raw.updatedAt) });
    view.setResources("build-jobs", [raw]);
    const snapshot = view.snapshot();
    const item = snapshot.items[0];
    assert.equal(item.workerId, raw.build.allocation.workerId, point);
    assert.equal(item.allocationId, raw.build.allocation.id);
    assert.equal(item.generation, raw.build.allocation.generation);
    assert.equal(item.workspaceId, raw.build.snapshotWorkspace);
    assert.equal(item.status, raw.status);
    assert.equal(item.updatedAt, new Date(raw.updatedAt).toISOString());
    assert.deepEqual(item.parent, {
      targetKind: raw.parent.targetKind,
      targetId: raw.parent.targetId,
      sessionId: raw.parent.sessionId,
      executionId: raw.parent.executionId,
      taskId: raw.parent.taskId,
      agentId: raw.parent.agentId,
      workerId: raw.parent.claim.workerId,
      generation: raw.parent.generation,
    });
    assert.equal(item.activity, "unknown");
    assert.equal(item.lastActivityAt, undefined);
    assert.equal(item.host, undefined);
    assert.equal(item.agentId, undefined);
    assert.equal(item.taskId, undefined);
    assert.equal(item.sessionId, undefined);
    assert.equal(item.claimStatus, undefined);
    assert.equal(
      activeAgentCount(snapshot.items, Date.parse(raw.updatedAt)),
      0,
    );
    assert.equal(
      matchPacket(snapshot.items, {
        taskId: raw.parent.taskId,
        generation: raw.parent.generation,
      }),
      undefined,
    );
    assert.deepEqual(snapshot.observations, []);
    for (const secret of [
      "/work/parent-source",
      "policyDigest",
      "grantId",
      "sourceFiles",
      "just",
    ]) {
      assert.equal(JSON.stringify(snapshot).includes(secret), false, secret);
    }
  }
});

test("subordinate parent generations and provider placement cannot become child ownership", () => {
  const raw = structuredClone(buildContract.persistedGrantDocument.record);
  raw.parent.generation =
    raw.parent.claim.generation =
    raw.build.request.parent.generation =
      8;
  Object.assign(raw, {
    workerId: "spoof",
    host: "spoof-host",
    agentId: "spoof-agent",
    activity: "running",
    lastActivityAt: raw.updatedAt,
  });
  const view = new FleetView();
  view.setResources("workers", [
    { id: raw.build.allocation.workerId, generation: 1, host: "provider-host" },
  ]);
  view.setResources("build-jobs", [raw]);
  const item = view.snapshot().items[0];
  assert.equal(item.generation, 1);
  assert.equal(item.parent?.generation, 8);
  assert.equal(item.workerId, "tool-worker-1");
  assert.equal(item.host, undefined);
  assert.equal(item.agentId, undefined);
  assert.equal(item.activity, "unknown");
});

test("malformed subordinate identities remain visible without claiming an owner", () => {
  const mutations = [
    (r) => {
      r.build.schema = "hi/fleet/build/future";
    },
    (r) => {
      r.generation = 2;
    },
    (r) => {
      r.build.allocation.workerId = "bad worker";
    },
    (r) => {
      r.build.policy.allocation.workerId = "different";
    },
    (r) => {
      r.parent.claim.agentId = "different";
    },
    (r) => {
      r.build.request.parent.targetId = "different";
    },
    (r) => {
      r.build.snapshotWorkspace = "/private/path";
    },
  ];
  for (const mutate of mutations) {
    const raw = structuredClone(buildContract.admission.record);
    mutate(raw);
    const view = new FleetView();
    view.setResources("build-jobs", [raw]);
    const item = view.snapshot().items[0];
    assert.equal(item.id, raw.id);
    assert.equal(item.ownershipState, "unavailable");
    assert.equal(item.workerId, undefined);
    assert.equal(item.parent, undefined);
    assert.equal(item.activity, "unknown");
  }
});

test("paired malformed build IDs and snapshots remain private under distinct stable display keys", () => {
  const records = ["/private/sentinel", "/other/workspace"].map((id) => {
    const raw = structuredClone(buildContract.admission.record);
    raw.id = id;
    raw.build.snapshotWorkspace = `${id}-attempt-1`;
    return raw;
  });
  const view = new FleetView();
  view.setResources("build-jobs", records);
  const snapshot = view.snapshot();
  assert.equal(snapshot.items.length, 2);
  const keys = snapshot.items.map((item) => item.id);
  assert.equal(new Set(keys).size, 2);
  for (const item of snapshot.items) {
    assert.equal(item.ownershipState, "unavailable");
    assert.equal(item.identityState, "unavailable");
    assert.equal(item.subject, "Build identity unavailable");
    assert.equal(validResourceCollection([{ id: item.id }]), false);
    assert.equal(item.activity, "unknown");
    for (const field of [
      "workerId",
      "allocationId",
      "workspaceId",
      "parent",
      "generation",
      "taskId",
      "sessionId",
      "executionId",
      "agentId",
    ])
      assert.equal(item[field], undefined, field);
  }
  for (const raw of records) {
    assert.equal(JSON.stringify(snapshot).includes(raw.id), false);
    assert.equal(
      JSON.stringify(snapshot).includes(raw.build.snapshotWorkspace),
      false,
    );
  }
  assert.equal(activeAgentCount(snapshot.items, Date.now()), 0);
  assert.deepEqual(snapshot.observations, []);
  view.setResources("build-jobs", [...records].reverse());
  assert.deepEqual(
    view.snapshot().items.map((item) => item.id),
    [...keys].reverse(),
  );
  view.setResources("build-jobs", [
    { id: "/legacy/generic", workerId: "legacy-worker" },
  ]);
  assert.equal(view.snapshot().items[0].id, "/legacy/generic");
  assert.equal(view.snapshot().items[0].workerId, "legacy-worker");
});

test("generic build jobs retain their existing owner and observed activity", () => {
  const now = Date.parse("2026-09-13T12:00:00Z");
  const view = new FleetView({ now: () => now });
  view.setResources("build-jobs", [
    {
      id: "legacy",
      workerId: "legacy-worker",
      agentId: "legacy-agent",
      host: "legacy-host",
      status: "running",
      lastActivityAt: new Date(now).toISOString(),
    },
  ]);
  const item = view.snapshot().items[0];
  assert.equal(item.workerId, "legacy-worker");
  assert.equal(item.host, "legacy-host");
  assert.equal(item.agentId, "legacy-agent");
  assert.equal(item.activity, "running");
  assert.equal(item.buildType, undefined);
});

test("the controller's domain field remains distinct from the HMAS role in item metadata", () => {
  const view = new FleetView();
  view.setResources("sessions", [
    { id: "domain-session", domain: "research", hmasRole: "researcher" },
  ]);
  const item = view.snapshot().items[0];
  assert.equal(item.executionDomain, "research");
  assert.equal(item.hmasRole, "researcher");
});

const baseTime = Date.parse("2026-09-10T18:00:00Z");
const packet = (eventId, extra = {}) => ({
  eventId,
  observedAt: new Date(baseTime).toISOString(),
  source: "Agamemnon",
  target: "Keystone",
  transport: "nats",
  operation: "publish",
  messageId: "command-1",
  taskId: "issue-1",
  executionId: "execution-1",
  generation: 3,
  bytes: 192,
  ...extra,
});

test("an item links the canonical agent, execution and host without inferring activity from assignment", () => {
  const view = new FleetView({ now: () => baseTime });
  view.setResources("workers", [
    {
      id: "worker-1",
      host: "m1",
      poolId: "m1-agents",
      allocationId: "slurm-123",
    },
  ]);
  view.setResources("sessions", [
    {
      id: "session-1",
      taskId: "issue-1",
      agentId: "reviewer-1",
      workerId: "worker-1",
      executionId: "execution-1",
      generation: 3,
      status: "assigned",
    },
  ]);
  const [item] = view.snapshot().items;
  assert.ok(item, "an admitted session must be visible");
  assert.equal(item.agentId, "reviewer-1");
  assert.equal(item.host, "m1");
  assert.equal(item.allocationId, "slurm-123");
  assert.equal(item.activity, "unknown");
  assert.equal(item.status, "assigned");
});

test("only current-generation observed execution establishes activity; it becomes stale with time", () => {
  let time = baseTime;
  const view = new FleetView({ now: () => time, staleAfterMs: 5000 });
  view.setResources("sessions", [
    { id: "s1", executionId: "e1", generation: 3, status: "assigned" },
  ]);
  view.setResources("executions", [
    {
      id: "e1",
      generation: 2,
      status: "running",
      lastActivityAt: new Date(time).toISOString(),
    },
  ]);
  assert.equal(view.snapshot().items[0]?.activity, "unknown");
  view.setResources("executions", [
    {
      id: "e1",
      generation: 3,
      status: "running",
      stage: "review",
      lastActivityAt: new Date(time).toISOString(),
    },
  ]);
  assert.equal(view.snapshot().items[0]?.activity, "running");
  assert.equal(view.snapshot().items[0]?.stage, "review");
  time += 5001;
  assert.equal(view.snapshot().items[0]?.activity, "stale");
});

test("flow observations are deduplicated, correlated, sanitized, and never authorize work", () => {
  const view = new FleetView({ now: () => baseTime });
  assert.equal(
    view.observe(
      packet("p1", { payload: { token: "PRIVATE" }, prompt: "PRIVATE" }),
    ),
    true,
  );
  assert.equal(view.observe(packet("p1")), false);
  assert.equal(
    view.observe(
      packet("a1", {
        source: "Keystone",
        target: "Agamemnon",
        operation: "ack",
      }),
    ),
    true,
  );
  const snapshot = view.snapshot();
  assert.equal(snapshot.observations.length, 2);
  assert.equal(
    snapshot.observations[0].messageId,
    snapshot.observations[1].messageId,
  );
  assert.equal(snapshot.items.length, 0);
  assert.equal(JSON.stringify(snapshot).includes("PRIVATE"), false);
  assert.equal(snapshot.observations[0].bytes, 192);
});

test("bounded history exposes cursor gaps and backend restarts instead of silently claiming complete replay", () => {
  const view = new FleetView({
    now: () => baseTime,
    historyLimit: 2,
    instanceId: "test-epoch",
  });
  view.observe(packet("p1"));
  const cursor = view.snapshot().cursor;
  view.observe(packet("p2"));
  view.observe(packet("p3"));
  view.observe(packet("p4"));
  assert.equal(view.snapshot(cursor).gap, true);
  assert.equal(view.snapshot("another-epoch:1").gap, true);
  assert.equal(view.snapshot().observations.length, 2);
  assert.equal(view.snapshot().dropped, 2);
});

test("an upstream outage keeps last known items but marks the source unavailable", () => {
  const view = new FleetView({ now: () => baseTime });
  view.setResources("sessions", [{ id: "s1", status: "assigned" }]);
  view.setSource("agamemnon", "unavailable");
  assert.equal(view.snapshot().items.length, 1);
  assert.equal(view.snapshot().sources.agamemnon.status, "unavailable");
});

test("malformed or non-telemetry messages are rejected without exposing arbitrary content", () => {
  const view = new FleetView({ now: () => baseTime });
  assert.equal(
    view.observe({ taskId: "x", payload: "not an observation" }),
    false,
  );
  assert.equal(
    view.observe(packet("p1", { source: "unknown-component", bytes: -1 })),
    false,
  );
  assert.equal(
    view.observe(packet("p2", { operation: "run-arbitrary-code" })),
    false,
  );
  assert.equal(view.snapshot().observations.length, 0);
});

test("conflicting execution ownership and replacement worker placement never overwrite the admitted identity", () => {
  const view = new FleetView({ now: () => baseTime });
  view.setResources("sessions", [
    {
      id: "s1",
      taskId: "t1",
      workerId: "w1",
      agentId: "a1",
      executionId: "e1",
      generation: 3,
    },
  ]);
  view.setResources("workers", [
    { id: "w1", generation: 4, host: "replacement-host" },
  ]);
  view.setResources("executions", [
    {
      id: "e1",
      sessionId: "another-session",
      taskId: "another-task",
      agentId: "a2",
      workerId: "w2",
      generation: 3,
      status: "running",
      lastActivityAt: new Date(baseTime).toISOString(),
    },
  ]);
  const [item] = view.snapshot().items;
  assert.equal(item.taskId, "t1");
  assert.equal(item.agentId, "a1");
  assert.equal(item.host, undefined);
  assert.equal(item.activity, "unknown");
});

test("future activity timestamps do not establish current work and GitHub link queries are stripped", () => {
  const view = new FleetView({ now: () => baseTime });
  view.setResources("sessions", [
    {
      id: "s1",
      executionId: "e1",
      generation: 3,
      issueUrl:
        "https://github.com/HomericIntelligence/Odysseus/issues/1?token=PRIVATE#PRIVATE",
    },
  ]);
  view.setResources("executions", [
    {
      id: "e1",
      generation: 3,
      status: "running",
      lastActivityAt: new Date(baseTime + 60000).toISOString(),
    },
  ]);
  assert.equal(view.snapshot().items[0].activity, "unknown");
  assert.equal(JSON.stringify(view.snapshot()).includes("PRIVATE"), false);
});

test("source sequence gaps remain visible independently of the browser replay cursor", () => {
  const view = new FleetView({ now: () => baseTime });
  view.observe(
    packet("p1", {
      sourceId: "keystone:w1:consumer:epoch",
      sourceSequence: 1,
      transport: "nats-jetstream",
      workerId: "w1",
    }),
  );
  view.observe(
    packet("p2", {
      sourceId: "keystone:w1:consumer:epoch",
      sourceSequence: 3,
      transport: "nats-jetstream",
      workerId: "w1",
    }),
  );
  const result = view.snapshot();
  assert.equal(result.sourceGaps, 1);
  assert.equal(result.observations[1].sourceSequence, 3);
  assert.equal(result.observations[1].transport, "nats-jetstream");
});

test("actual session-targeted worker facts display model and waiting activity without an execution mirror", () => {
  const view = new FleetView({ now: () => baseTime });
  for (const activity of [
    "model_working",
    "tool_running",
    "waiting_approval",
    "waiting_input",
  ]) {
    view.setResources("sessions", [
      {
        id: "s1",
        generation: 3,
        agentId: "a1",
        workerId: "w1",
        activity,
        lastActivityAt: new Date(baseTime).toISOString(),
        claimStatus: "active",
      },
    ]);
    assert.equal(view.snapshot().items[0].activity, activity);
  }
});

test("source sequences are scoped to attachment identities, even for consumers on the same worker", () => {
  const view = new FleetView({ now: () => baseTime });
  view.observe(
    packet("p1", {
      workerId: "w1",
      sourceId: "keystone:w1:consumer-a:epoch1",
      sourceSequence: 1,
    }),
  );
  view.observe(
    packet("p2", {
      workerId: "w1",
      sourceId: "keystone:w1:consumer-b:epoch1",
      sourceSequence: 1,
    }),
  );
  view.observe(
    packet("p3", {
      workerId: "w1",
      sourceId: "keystone:w1:consumer-a:epoch2",
      sourceSequence: 1,
    }),
  );
  assert.equal(view.snapshot().sourceGaps, 0);
  assert.equal(
    view.snapshot().observations[0].sourceId,
    "keystone:w1:consumer-a:epoch1",
  );
});

test("newer session activity keeps canonical ownership and its associated stage and waiting reason", () => {
  const view = new FleetView({ now: () => baseTime });
  view.setResources("sessions", [
    {
      id: "s1",
      executionId: "e1",
      generation: 3,
      workerId: "w1",
      host: "m1",
      claimStatus: "active",
      activity: "waiting_approval",
      stage: "review",
      waitingReason: "Approval required",
      lastActivityAt: new Date(baseTime).toISOString(),
    },
  ]);
  view.setResources("executions", [
    {
      id: "e1",
      generation: 3,
      workerId: "w1",
      host: "old-host",
      claimStatus: "released",
      activity: "model_working",
      stage: "implement",
      lastActivityAt: new Date(baseTime - 1000).toISOString(),
    },
  ]);
  const item = view.snapshot().items[0];
  assert.equal(item.component, "hephaestus");
  assert.equal(item.host, "m1");
  assert.equal(item.claimStatus, "active");
  assert.equal(item.stage, "review");
  assert.equal(item.waitingReason, "Approval required");
});

test("gateway maximum-length source IDs preserve independent continuity", () => {
  const view = new FleetView({ now: () => baseTime });
  const sourceId = `keystone:${"w".repeat(128)}:${"c".repeat(128)}:${"e".repeat(32)}`;
  view.observe(packet("long-source-one", { sourceId, sourceSequence: 1 }));
  view.observe(packet("long-source-two", { sourceId, sourceSequence: 3 }));
  const snapshot = view.snapshot();
  assert.equal(snapshot.observations[0].sourceId, sourceId);
  assert.equal(snapshot.sourceGaps, 1);
});

test("source identity extension does not loosen other identifier bounds", () => {
  const view = new FleetView({ now: () => baseTime });
  view.observe(
    packet("bounded-identifiers", {
      sourceId: "x".repeat(513),
      taskId: "t".repeat(257),
    }),
  );
  const observation = view.snapshot().observations[0];
  assert.equal(observation.sourceId, undefined);
  assert.equal(observation.taskId, undefined);
});

test("history restore rejects more than 250 records without altering the view", () => {
  const source = new FleetView({ historyLimit: 300, now: () => baseTime });
  for (let index = 0; index < 251; index++)
    source.observe(packet(`large-${index}`));
  const history = source.exportHistory();
  history.observations = source
    .snapshot()
    .observations.map(({ origin, ...row }) => row);
  const target = new FleetView();
  assert.throws(
    () => target.restoreHistory(history),
    /Invalid observation history/,
  );
  assert.deepEqual(target.snapshot().observations, []);
});

test("history restore preserves sanitized identity windows without restoring resource authority", () => {
  const source = new FleetView({ now: () => baseTime });
  const privateWorkerSentinel = "private-worker-token";
  const input = packet("derived-identity", {
    workerId: { token: privateWorkerSentinel },
    payload: "private-payload",
    command: "private-command",
    sourceSequence: 1,
    sourceId: "gateway-history",
    prompt: "private-prompt",
  });
  source.observe(input);
  source.setResources("workers", [{ id: "current-worker", status: "running" }]);
  const history = source.exportHistory();
  assert.equal(JSON.stringify(history).includes("private-"), false);
  const target = new FleetView({ now: () => baseTime + 10000 });
  target.restoreHistory(history);
  assert.deepEqual(target.snapshot().resources.workers, []);
  assert.deepEqual(target.snapshot().sources, {});
  assert.equal(
    target.observe({ ...input, workerId: ["another-private-key"] }),
    false,
  );
  assert.equal(
    target.observe(
      packet("next", { sourceId: "gateway-history", sourceSequence: 3 }),
    ),
    true,
  );
  assert.equal(target.snapshot().sourceGaps, 1);
  assert.equal(
    target.snapshot().observations[0].receivedAt,
    new Date(baseTime).toISOString(),
  );
  assert.equal(target.snapshot().observations[0].origin, "restored");
  assert.equal(target.snapshot().observations[1].origin, "live");
});

test("history validation rejects altered metadata and leaves the original view intact", () => {
  const source = new FleetView({ now: () => baseTime });
  source.observe(packet("closed-history"));
  for (const change of [
    (value) => {
      value.observations[0].prompt = "private";
    },
    (value) => {
      value.observations[0].origin = "live";
    },
    (value) => {
      value.observations[0].sequence = 0;
    },
    (value) => {
      value.observations[0].sequence = 2;
    },
    (value) => {
      value.observations[0].receivedAt = "invalid";
    },
    (value) => {
      value.seen = [];
    },
    (value) => {
      value.seen.push(value.seen[0]);
    },
    (value) => {
      value.sourceSequences = [{ sourceId: "source", sequence: -1 }];
    },
    (value) => {
      value.coverageLosses = Number.MAX_SAFE_INTEGER + 1;
    },
    (value) => {
      value.resources = { workers: [{ id: "fake" }] };
    },
  ]) {
    const candidate = source.exportHistory();
    change(candidate);
    const target = new FleetView();
    assert.throws(
      () => target.restoreHistory(candidate),
      /Invalid observation history/,
    );
    assert.deepEqual(target.snapshot().observations, []);
  }
});

test("history sequence exhaustion preserves the last valid order and saturates counters", () => {
  const source = new FleetView();
  const history = source.exportHistory();
  for (const field of [
    "sequence",
    "invalid",
    "coverageLosses",
    "sourceGaps",
    "dropped",
  ])
    history[field] = Number.MAX_SAFE_INTEGER;
  source.restoreHistory(history);
  assert.equal(source.observe(packet("exhausted")), false);
  source.recordCoverageLoss("attachment", "invalid_frame");
  const persisted = source.exportHistory();
  assert.equal(persisted.sequence, Number.MAX_SAFE_INTEGER);
  assert.equal(persisted.invalid, Number.MAX_SAFE_INTEGER);
  assert.equal(persisted.coverageLosses, Number.MAX_SAFE_INTEGER);
  assert.equal(source.snapshot().observations.length, 0);
});
