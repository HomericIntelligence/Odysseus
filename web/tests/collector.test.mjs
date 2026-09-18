import { randomBytes } from "node:crypto";
import { test } from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import { Readable } from "node:stream";
import { FleetView, RESOURCE_KINDS } from "../server/view.mjs";
import { attachObservationInput, pollFleet } from "../server/collector.mjs";

const fixtureCredential = randomBytes(24).toString("base64url");

test("collector authenticates only to the configured service and projects real resource responses", async () => {
  const calls = [];
  const view = new FleetView();
  const result = await pollFleet({
    view,
    url: "http://127.0.0.1:8080",
    apiKey: fixtureCredential,
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      const kind = new URL(url).pathname.split("/").at(-1);
      return new Response(
        JSON.stringify({
          items: kind === "sessions" ? [{ id: "s1", agentId: "agent-1" }] : [],
          total: kind === "sessions" ? 1 : 0,
        }),
      );
    },
  });
  assert.equal(result, true);
  assert.equal(calls.length, RESOURCE_KINDS.length);
  assert.equal(
    calls.every(
      (call) =>
        call.options.headers.Authorization === `Bearer ${fixtureCredential}`,
    ),
    true,
  );
  assert.equal(view.snapshot().items[0].agentId, "agent-1");
  assert.equal(
    JSON.stringify(view.snapshot()).includes(fixtureCredential),
    false,
  );
});

test("partial failures keep the prior coherent snapshot and report unavailable without forwarding error bodies", async () => {
  const view = new FleetView();
  view.setResources("sessions", [{ id: "existing" }]);
  const result = await pollFleet({
    view,
    url: "http://127.0.0.1:8080",
    apiKey: "test-key",
    fetchImpl: async () =>
      new Response("sensitive-upstream-error", { status: 503 }),
  });
  assert.equal(result, false);
  assert.equal(view.snapshot().items[0].id, "existing");
  assert.equal(view.snapshot().sources.agamemnon.status, "unavailable");
  assert.equal(
    JSON.stringify(view.snapshot()).includes("sensitive-upstream-error"),
    false,
  );
});

test("collector refuses plaintext remote credentials and redirect following", async () => {
  let calls = 0;
  const view = new FleetView();
  const fetchImpl = async (_url, options) => {
    calls++;
    assert.equal(options.redirect, "error");
    return new Response('{"items":[],"total":0}');
  };
  assert.equal(
    await pollFleet({
      view,
      url: "http://remote.example:8080",
      apiKey: "test-key",
      fetchImpl,
    }),
    false,
  );
  assert.equal(calls, 0);
  assert.equal(
    await pollFleet({
      view,
      url: "https://service.example",
      apiKey: "test-key",
      fetchImpl,
    }),
    true,
  );
});

for (const [name, content] of [
  ["invalid JSON", "{not-json}\n"],
  ["oversized frame", `${"x".repeat(65537)}\n`],
  ["truncated frame", '{"type":"observation"'],
]) {
  test(`coverage loss from ${name} remains visible after attachment EOF`, async () => {
    const view = new FleetView();
    const input = Readable.from([content]);
    attachObservationInput(view, input);
    await once(input, "end");
    assert.equal(view.snapshot().coverageLosses, 1);
    assert.equal(view.snapshot().observations.length, 0);
  });
}

for (const [name, malformed] of [
  ["null row", [{ id: "valid" }, null]],
  ["missing ID", [{ id: "valid" }, {}]],
  ["invalid ID", [{ id: "valid" }, { id: "contains spaces" }]],
  ["duplicate ID", [{ id: "same" }, { id: "same" }]],
]) {
  test(`collector rejects ${name} before replacing any resource collection`, async () => {
    const view = new FleetView();
    for (const kind of RESOURCE_KINDS)
      view.setResources(kind, [{ id: `old-${kind}` }]);
    const previous = view.snapshot().resources;
    const result = await pollFleet({
      view,
      url: "http://127.0.0.1:8080",
      apiKey: fixtureCredential,
      fetchImpl: async (url) => {
        const kind = new URL(url).pathname.split("/").at(-1);
        const items =
          kind === "build-jobs" ? malformed : [{ id: `new-${kind}` }];
        return new Response(JSON.stringify({ items, total: items.length }));
      },
    });
    assert.equal(result, false);
    assert.deepEqual(view.snapshot().resources, previous);
    assert.equal(view.snapshot().sources.agamemnon.status, "unavailable");
  });
}
