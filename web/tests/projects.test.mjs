import { randomBytes } from "node:crypto";
import { test } from "node:test";
import assert from "node:assert/strict";
import { FleetView } from "../server/view.mjs";
import { pollProjects } from "../server/projects.mjs";
import { createServer } from "node:http";

const fixtureCredential = randomBytes(24).toString("base64url");

const projection = () => ({
  schema: "hi/projects-projection/v1",
  authority: "github-issues",
  direction: "issues-to-project",
  state: "degraded",
  stageProjection: "partial",
  projected: 1,
  unchanged: 0,
  failed: 0,
  unavailable: 1,
  lastAttemptAt: "2026-09-11T12:00:00Z",
  items: [
    {
      taskId: "task-1",
      orchestrationState: "InProgress",
      orchestrationIssueUrl:
        "https://github.com/HomericIntelligence/Agamemnon/issues/1",
      repo: "HomericIntelligence/Odysseus",
      issue: 2,
      workIssueUrl:
        "https://github.com/HomericIntelligence/Odysseus/issues/2?private=discard",
      pullRequestUrls: [
        "https://github.com/HomericIntelligence/Odysseus/pull/3",
        "https://foreign.example/private",
      ],
      stageLabel: "state:review",
      stageProjection: "available",
      state: "projected",
      error: "private-upstream-error",
      providerOutput: "private-content",
    },
  ],
});
const poll = (view, data, extra = {}) =>
  pollProjects({
    view,
    url: "http://127.0.0.1:8080",
    apiKey: fixtureCredential,
    fetchImpl: async () => new Response(JSON.stringify(data)),
    ...extra,
  });

test("Projects projects supported issue-backed metadata without private bodies or arbitrary destinations", async () => {
  const view = new FleetView();
  const calls = [];
  assert.equal(
    await poll(view, null, {
      fetchImpl: async (url, options) => {
        calls.push({ url, options });
        return new Response(JSON.stringify(projection()));
      },
    }),
    true,
  );
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url.pathname, "/v1/fleet/projects");
  assert.equal(
    calls[0].options.headers.Authorization,
    `Bearer ${fixtureCredential}`,
  );
  assert.equal(calls[0].options.redirect, "error");
  const snapshot = view.snapshot();
  assert.equal(
    snapshot.projects.items[0].workIssueUrl,
    "https://github.com/HomericIntelligence/Odysseus/issues/2",
  );
  assert.deepEqual(snapshot.projects.items[0].pullRequestUrls, [
    "https://github.com/HomericIntelligence/Odysseus/pull/3",
  ]);
  assert.equal(snapshot.projects.state, "degraded");
  assert.equal(snapshot.projects.fresh, true);
  assert.equal(JSON.stringify(snapshot).includes("private"), false);
});

test("failed Projects polls retain prior projection independently of Fleet resource availability", async () => {
  const view = new FleetView();
  view.setResources("sessions", [{ id: "existing" }]);
  view.setSource("agamemnon", "connected");
  await poll(view, projection());
  assert.equal(
    await poll(view, null, {
      fetchImpl: async () => new Response("private-failure", { status: 503 }),
    }),
    false,
  );
  const snapshot = view.snapshot();
  assert.equal(snapshot.projects.items[0].taskId, "task-1");
  assert.equal(snapshot.projects.fresh, false);
  assert.equal(snapshot.sources.projects.status, "unavailable");
  assert.equal(snapshot.sources.agamemnon.status, "connected");
  assert.equal(snapshot.items[0].id, "existing");
  assert.equal(JSON.stringify(snapshot).includes("private-failure"), false);
});

test("a connected snapshot does not refresh old Projects metadata", async () => {
  let now = Date.parse("2026-09-11T12:00:00Z");
  const view = new FleetView({ now: () => now });
  await poll(view, projection());
  now += 90001;
  assert.equal(view.snapshot().projects.fresh, false);
});

for (const [name, mutate] of [
  ["foreign authority", (value) => (value.authority = "project-board")],
  ["unknown schema", (value) => (value.schema = "future/v9")],
  ["duplicate task", (value) => value.items.push({ ...value.items[0] })],
  ["missing task", (value) => delete value.items[0].taskId],
  [
    "unknown canonical state",
    (value) => (value.items[0].orchestrationState = "Approved"),
  ],
  ["invalid collection", (value) => (value.items = null)],
  ["inconsistent completed counters", (value) => (value.projected = 1000)],
  [
    "truncated collection",
    (value) =>
      (value.items = Array.from({ length: 2001 }, (_, n) => ({
        ...value.items[0],
        taskId: `task-${n}`,
      }))),
  ],
])
  test(`Projects rejects ${name} before replacing the coherent projection`, async () => {
    const view = new FleetView();
    await poll(view, projection());
    const value = projection();
    mutate(value);
    assert.equal(await poll(view, value), false);
    assert.equal(view.snapshot().projects.items.length, 1);
    assert.equal(view.snapshot().projects.fresh, false);
  });

test("disabled Projects has unknown counters until measured and never means an empty completed backlog", async () => {
  const view = new FleetView();
  const value = projection();
  for (const key of [
    "projected",
    "unchanged",
    "failed",
    "unavailable",
    "lastAttemptAt",
  ])
    delete value[key];
  value.state = "disabled";
  value.items = [];
  assert.equal(await poll(view, value), true);
  assert.equal(view.snapshot().projects.projected, undefined);
  assert.equal(view.snapshot().projects.lastAttemptAt, undefined);
});

test("Projects rejects remote plaintext and absent credentials without calling upstream", async () => {
  const view = new FleetView();
  let calls = 0;
  const fetchImpl = async () => {
    calls++;
    throw Error("must not call");
  };
  assert.equal(
    await poll(view, null, { url: "http://remote.example", fetchImpl }),
    false,
  );
  assert.equal(await poll(view, null, { apiKey: undefined, fetchImpl }), false);
  assert.equal(calls, 0);
  assert.equal(view.snapshot().sources.projects.status, "not_configured");
});

test("Projects bounds response bytes before parsing", async () => {
  const view = new FleetView();
  assert.equal(
    await poll(view, null, {
      fetchImpl: async () => new Response(" ".repeat(2 * 1024 * 1024 + 1)),
    }),
    false,
  );
  assert.equal(view.snapshot().projects, undefined);
});

test("repeated health reads preserve the owner's old rebuild timestamps", async () => {
  let now = Date.parse("2026-09-11T12:00:00Z");
  const view = new FleetView({ now: () => now });
  const value = projection();
  value.lastSuccessAt = "2026-09-10T12:00:00Z";
  await poll(view, value);
  now += 30000;
  await poll(view, value);
  const result = view.snapshot().projects;
  assert.equal(result.fresh, true);
  assert.equal(result.observedAt, "2026-09-11T12:00:30.000Z");
  assert.equal(result.lastAttemptAt, "2026-09-11T12:00:00.000Z");
  assert.equal(result.lastSuccessAt, "2026-09-10T12:00:00.000Z");
});

test("real HTTP redirect cannot forward component credentials to another endpoint", async () => {
  let destinationCalls = 0;
  const destination = createServer((_req, res) => {
    destinationCalls++;
    res.end("{}");
  });
  await new Promise((resolve) => destination.listen(0, "127.0.0.1", resolve));
  const upstream = createServer((req, res) => {
    assert.equal(req.headers.authorization, `Bearer ${fixtureCredential}`);
    res.writeHead(302, {
      location: `http://127.0.0.1:${destination.address().port}/private`,
    });
    res.end();
  });
  await new Promise((resolve) => upstream.listen(0, "127.0.0.1", resolve));
  try {
    const view = new FleetView();
    assert.equal(
      await poll(view, null, {
        url: `http://127.0.0.1:${upstream.address().port}`,
        fetchImpl: fetch,
      }),
      false,
    );
    assert.equal(destinationCalls, 0);
    assert.equal(view.snapshot().sources.projects.status, "unavailable");
  } finally {
    for (const server of [upstream, destination]) {
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    }
  }
});
