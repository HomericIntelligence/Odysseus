import { test } from "node:test";
import assert from "node:assert/strict";
import {
  activeAgentCount,
  matchPacket,
  currentItem,
} from "../src/selectors.ts";
import * as selectors from "../src/selectors.ts";
const now = Date.parse("2026-09-10T18:00:00Z");
test("controller source freshness is bounded independently of browser snapshots", () => {
  const connected = (age) => ({
    status: "connected",
    observedAt: new Date(now - age).toISOString(),
  });
  assert.equal(selectors.sourceIsFresh(connected(15000), now), true);
  assert.equal(selectors.sourceIsFresh(connected(15001), now), false);
  assert.equal(selectors.sourceIsFresh(connected(-5001), now), false);
  assert.equal(
    selectors.sourceIsFresh(
      { status: "connected", observedAt: "invalid" },
      now,
    ),
    false,
  );
  assert.equal(
    selectors.sourceIsFresh({ ...connected(0), status: "unavailable" }, now),
    false,
  );
});
const item = {
  id: "s1",
  kind: "session",
  taskId: "t1",
  agentId: "a1",
  workerId: "w1",
  generation: 3,
  claimStatus: "claimed",
  activity: "model_working",
  lastActivityAt: new Date(now).toISOString(),
};
test("108 occupancy excludes offloaded builds, unclaimed work, stale activity, and duplicate agent identities", () => {
  assert.equal(
    activeAgentCount(
      [
        item,
        { ...item, id: "another-view" },
        { ...item, kind: "build-job", agentId: "build-1" },
        { ...item, agentId: "unclaimed", claimStatus: "released" },
        {
          ...item,
          agentId: "stale",
          lastActivityAt: new Date(now - 16000).toISOString(),
        },
      ],
      now,
    ),
    1,
  );
});
test("packet linkage requires current generation and matching ownership", () => {
  assert.equal(
    matchPacket([item], { taskId: "t1", generation: 3, workerId: "w1" }),
    item,
  );
  assert.equal(
    matchPacket([item], { taskId: "t1", generation: 2, workerId: "w1" }),
    undefined,
  );
  assert.equal(
    matchPacket([item], {
      taskId: "t1",
      generation: 3,
      workerId: "replacement",
    }),
    undefined,
  );
  assert.equal(matchPacket([item], { taskId: "t1" }), undefined);
});
test("detail selection follows live changes but never switches to a replacement generation", () => {
  const update = { ...item, activity: "waiting_approval" };
  assert.equal(currentItem([update], item), update);
  assert.equal(currentItem([{ ...update, generation: 4 }], item), undefined);
});

test("reserved and noncanonical claims never count as observed issue agents", () => {
  for (const claimStatus of ["reserved", "active", "released", "unclaimed"]) {
    assert.equal(activeAgentCount([{ ...item, claimStatus }], now), 0);
  }
});

test("108 current claimed sessions count once per agent", () => {
  const items = Array.from({ length: 108 }, (_, index) => ({
    ...item,
    id: `session-${index}`,
    agentId: `agent-${index}`,
    taskId: `task-${index}`,
  }));
  assert.equal(activeAgentCount([...items, ...items], now), 108);
  assert.equal(activeAgentCount(items, now + 15001), 0);
});

test("ambiguous task-only correlation does not choose an arbitrary owner", () => {
  const peer = { ...item, id: "s2", agentId: "a2", workerId: "w2" };
  assert.equal(
    matchPacket([item, peer], { taskId: "t1", generation: 3 }),
    undefined,
  );
  assert.equal(
    matchPacket([item, peer], {
      taskId: "t1",
      generation: 3,
      workerId: "w2",
      agentId: "a2",
    }),
    peer,
  );
});

test("packet host fallback uses one current matching owner and preserves an observed host", () => {
  assert.equal(
    typeof selectors.packetHost,
    "function",
    "host-filter projection must be exported",
  );
  const owned = { ...item, host: "m1" };
  const packet = { taskId: "t1", generation: 3, workerId: "w1", agentId: "a1" };
  assert.equal(selectors.packetHost([owned], packet), "m1");
  assert.equal(
    selectors.packetHost([owned], { ...packet, generation: 2 }),
    undefined,
  );
  assert.equal(
    selectors.packetHost([owned], { ...packet, workerId: "wrong" }),
    undefined,
  );
  assert.equal(
    selectors.packetHost([owned], { ...packet, host: "laptop" }),
    "laptop",
  );
  assert.equal(
    selectors.packetHost([owned, { ...owned, id: "s2", workerId: "w2" }], {
      taskId: "t1",
      generation: 3,
    }),
    undefined,
  );
});
