import { test } from "node:test";
import assert from "node:assert/strict";
import { FleetView } from "../server/view.mjs";

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
