import { createHash, randomBytes } from "node:crypto";
import { createServer } from "node:http";
import { test, expect } from "@playwright/test";
import { resolve } from "node:path";
import { FleetView } from "../server/view.mjs";
import { createDashboardServer } from "../server/http.mjs";

let server, url, calls, reply;
let view, importServer, importCalls, importReply;
const token = randomBytes(24).toString("hex");
const sha = (text) => createHash("sha256").update(text).digest("hex");
function confirmed(input) {
  const canonical = {
    body: input.body,
    intakeId: input.intakeId,
    schema: input.schema,
    title: input.title,
    workRepository: input.workRepository.toLowerCase(),
  };
  const requestDigest = sha(JSON.stringify(canonical));
  return {
    schema: "hi/nestor/intake/v1",
    intakeId: input.intakeId,
    workRepository: canonical.workRepository,
    requestDigest,
    bodyDigest: sha(
      `${input.body}\n\n<!-- nestor:fleet-intake:v1 id=${input.intakeId} digest=${requestDigest} -->`,
    ),
    phase: "created",
    generation: 1,
    createdAt: "2026-09-12T12:00:00Z",
    attemptId: "a".repeat(32),
    issue: {
      repository: canonical.workRepository,
      number: 42,
      url: `https://github.com/${canonical.workRepository}/issues/42`,
    },
    receipt: { kind: "confirmed_issue", observedAt: "2026-09-12T12:00:01Z" },
  };
}
test.beforeEach(async () => {
  calls = [];
  reply = async () => new Response("uncertain", { status: 503 });
  importCalls = [];
  importReply = async () => ({ code: 503, body: { error: "unconfirmed" } });
  importServer = createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const call = {
      method: request.method,
      path: request.url,
      body: Buffer.concat(chunks).toString("utf8"),
    };
    importCalls.push(call);
    const result = await importReply(call);
    if (result === null) {
      request.socket.destroy();
      return;
    }
    response.writeHead(result.code, { "content-type": "application/json" });
    response.end(JSON.stringify(result.body));
  });
  await new Promise((done) => importServer.listen(0, "127.0.0.1", done));
  view = new FleetView();
  // The real backend proxy uses only this private transport fixture.
  server = createDashboardServer({
    view,
    token,
    staticDir: resolve("dist"),
    research: {
      url: "http://127.0.0.1:9999",
      token: randomBytes(24).toString("hex"),
      fetchImpl: async (url, options) => {
        calls.push({
          url: String(url),
          method: options.method,
          body: options.body,
        });
        return reply(url, options);
      },
    },
    researchImport: {
      url: `http://127.0.0.1:${importServer.address().port}`,
      apiKey: randomBytes(24).toString("hex"),
      observe: (event) => view.observe(event),
    },
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  url = `http://127.0.0.1:${server.address().port}`;
});
test.afterEach(async () => {
  server.closeAllConnections();
  await new Promise((done) => server.close(done));
  importServer.closeAllConnections();
  await new Promise((done) => importServer.close(done));
});
async function open(page) {
  await page.goto(url);
  await page.getByLabel("Local access token").fill(token);
  await page.getByRole("button", { name: "Open mission control" }).click();
  await page
    .getByRole("button", { name: "Research intake", exact: true })
    .click();
}
async function fill(page) {
  await page.getByLabel("Work repository").fill("HomericIntelligence/Odysseus");
  await page.getByLabel("Research title").fill("Research durable intake");
  await page
    .getByLabel("Publishable requirements")
    .fill("Requirements with κόσμος and 🧭.");
}

test("phone intake keeps every navigation action within the viewport", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await open(page);
  await fill(page);
  const buttons = page
    .getByRole("navigation", { name: "Main navigation" })
    .getByRole("button");
  await expect(buttons).toHaveCount(5);
  for (const button of await buttons.all()) {
    const box = await button.boundingBox();
    expect(box).not.toBeNull();
    expect(box.x).toBeGreaterThanOrEqual(0);
    expect(box.x + box.width).toBeLessThanOrEqual(390);
  }
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth),
  ).toBeLessThanOrEqual(390);
  await page
    .getByRole("button", { name: "Submit research intake", exact: true })
    .click();
  await expect(
    page.getByRole("status", { name: "Research intake status" }),
  ).toContainText("Outcome unknown");
  expect(calls).toHaveLength(1);
});

test("uncertain intake survives reload and retries the identical request before showing a confirmed issue", async ({
  page,
}) => {
  await open(page);
  await fill(page);
  await page
    .getByRole("button", { name: "Submit research intake", exact: true })
    .click();
  await expect(
    page.getByRole("status", { name: "Research intake status" }),
  ).toContainText("Outcome unknown");
  expect(calls).toHaveLength(1);
  const original = calls[0].body;
  expect(JSON.parse(original).intakeId).toMatch(/^research-[a-f0-9]{32}$/);
  await expect(page.getByLabel("Research title")).toBeDisabled();
  await expect(
    page.getByRole("link", { name: "Open research issue" }),
  ).toHaveCount(0);
  await page.reload();
  await page
    .getByRole("button", { name: "Research intake", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Retry same intake", exact: true }),
  ).toBeEnabled();
  expect(calls).toHaveLength(1);
  reply = async () => Response.json(confirmed(JSON.parse(original)));
  await page
    .getByRole("button", { name: "Retry same intake", exact: true })
    .click();
  await expect(
    page.getByRole("link", { name: "Open research issue" }),
  ).toHaveAttribute(
    "href",
    "https://github.com/homericintelligence/odysseus/issues/42",
  );
  expect(calls).toHaveLength(2);
  expect(calls[1].body).toBe(original);
  await expect(
    page.getByRole("status", { name: "Research intake status" }),
  ).toContainText("Issue confirmed");
  await expect(
    page.getByText(
      "Research dispatch is not implemented by this intake endpoint.",
    ),
  ).toBeVisible();
});

test("status lookup is read-only and a conflicting receipt keeps the retained input locked", async ({
  page,
}) => {
  await open(page);
  await fill(page);
  await page
    .getByRole("button", { name: "Submit research intake", exact: true })
    .click();
  await expect(
    page.getByRole("status", { name: "Research intake status" }),
  ).toContainText("Outcome unknown");
  const input = JSON.parse(calls[0].body);
  reply = async () =>
    Response.json({ ...confirmed(input), requestDigest: "f".repeat(64) });
  await page
    .getByRole("button", { name: "Check intake status", exact: true })
    .click();
  await expect(
    page.getByRole("status", { name: "Research intake status" }),
  ).toContainText("Conflict");
  expect(calls).toHaveLength(2);
  expect(calls[1].method).toBe("GET");
  expect(calls[1].body).toBeUndefined();
  await expect(page.getByLabel("Publishable requirements")).toBeDisabled();
  await expect(
    page.getByRole("link", { name: "Open research issue" }),
  ).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: "New research intake", exact: true }),
  ).toHaveCount(0);
});

test("unavailable browser persistence fails before sending any intake", async ({
  page,
}) => {
  await page.addInitScript(() => {
    Storage.prototype.setItem = () => {
      throw new Error("fixture storage unavailable");
    };
  });
  await open(page);
  await fill(page);
  await page
    .getByRole("button", { name: "Submit research intake", exact: true })
    .click();
  await expect(page.getByRole("alert")).toContainText("Browser storage");
  expect(calls).toHaveLength(0);
});

test("another tab adopts the retained intake without submitting a different request", async ({
  page,
  context,
}) => {
  await open(page);
  await fill(page);
  const second = await context.newPage();
  await second.goto(url);
  await second
    .getByRole("button", { name: "Research intake", exact: true })
    .click();
  await fill(second);
  await second
    .getByLabel("Research title")
    .fill("A different idea in another tab");
  await page
    .getByRole("button", { name: "Submit research intake", exact: true })
    .click();
  await expect(
    page.getByRole("status", { name: "Research intake status" }),
  ).toContainText("Outcome unknown");
  await second
    .getByRole("button", { name: "Submit research intake", exact: true })
    .click();
  await expect(second.getByLabel("Research title")).toHaveValue(
    "Research durable intake",
  );
  await expect(second.getByLabel("Research title")).toBeDisabled();
  expect(calls).toHaveLength(1);
});

test("a changed retained digest blocks retry without sending replacement content", async ({
  page,
}) => {
  await open(page);
  await fill(page);
  await page
    .getByRole("button", { name: "Submit research intake", exact: true })
    .click();
  await expect(
    page.getByRole("status", { name: "Research intake status" }),
  ).toContainText("Outcome unknown");
  await page.evaluate(() => {
    const key = "odysseus.research-intake.v1";
    const value = JSON.parse(localStorage.getItem(key));
    value.request.body = "changed content";
    localStorage.setItem(key, JSON.stringify(value));
  });
  await page.reload();
  await page
    .getByRole("button", { name: "Research intake", exact: true })
    .click();
  await page
    .getByRole("button", { name: "Retry same intake", exact: true })
    .click();
  await expect(page.getByRole("alert")).toContainText("could not be verified");
  expect(calls).toHaveLength(1);
});

test("confirmed intake exposes an explicit research task import action", async ({
  page,
}) => {
  reply = async (_url, options) =>
    Response.json(confirmed(JSON.parse(options.body)));
  await open(page);
  await fill(page);
  const capabilities = await page.request.get(`${url}/api/capabilities`);
  expect(capabilities.status()).toBe(200);
  expect((await capabilities.json()).researchImport).toEqual({ enabled: true });
  await expect(
    page.getByRole("button", { name: "Import research task", exact: true }),
  ).toHaveCount(0);
  await page
    .getByRole("button", { name: "Submit research intake", exact: true })
    .click();
  await expect(
    page.getByRole("link", { name: "Open research issue" }),
  ).toHaveAttribute(
    "href",
    "https://github.com/homericintelligence/odysseus/issues/42",
  );
  expect(calls).toHaveLength(1);
  expect(importCalls).toHaveLength(0);
  expect(view.snapshot().resources.sessions).toEqual([]);
  await expect(
    page.getByRole("button", { name: "Import research task", exact: true }),
  ).toBeEnabled();
});

async function confirmCurrentIntake(page) {
  let retained;
  reply = async (_url, options) => {
    if (options.method === "POST") retained = JSON.parse(options.body);
    return Response.json(confirmed(retained));
  };
  await open(page);
  await fill(page);
  await page
    .getByRole("button", { name: "Submit research intake", exact: true })
    .click();
  await expect(
    page.getByRole("link", { name: "Open research issue" }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Import research task", exact: true }),
  ).toBeEnabled();
  return confirmed(retained);
}

function importedReceipt(record, state = "Pending") {
  const namespace = "nestor-main";
  return {
    schema: "hi/agamemnon/research-import-receipt/v1",
    taskId:
      "research-" +
      sha(
        JSON.stringify({
          intakeId: record.intakeId,
          namespace,
          schema: "hi/agamemnon/research-task-key/v1",
        }),
      ),
    state,
    provenance: {
      schema: "hi/agamemnon/research-intake/v1",
      namespace,
      intakeId: record.intakeId,
      requestDigest: record.requestDigest,
      bodyDigest: record.bodyDigest,
      generation: record.generation,
      attemptId: record.attemptId,
      issue: record.issue,
      createdAt: record.createdAt,
      confirmedAt: record.receipt.observedAt,
    },
    issue: record.issue,
    routing: { domain: "research", hmasRole: "task-agent", stage: "research" },
  };
}

test("explicit research import survives a lost response and reload with the same reference", async ({
  page,
}) => {
  const record = await confirmCurrentIntake(page);
  let retainedByAuthority;
  importReply = async () => {
    retainedByAuthority ??= importedReceipt(record);
    if (importCalls.length === 1) return null;
    return { code: 200, body: { ...retainedByAuthority, state: "InProgress" } };
  };
  expect(importCalls).toHaveLength(0);
  await page
    .getByRole("button", { name: "Import research task", exact: true })
    .click();
  await expect.poll(() => importCalls.length).toBe(1);
  expect(importCalls[0].method).toBe("POST");
  expect(importCalls[0].path).toBe("/v1/fleet/research-intakes");
  expect(JSON.parse(importCalls[0].body)).toEqual({
    schema: "hi/agamemnon/research-import/v1",
    intakeId: record.intakeId,
    requestDigest: record.requestDigest,
  });
  const original = importCalls[0].body;
  expect(retainedByAuthority.taskId).toBe(importedReceipt(record).taskId);
  const status = page.getByRole("status", { name: "Research task status" });
  await expect(status).toContainText(/unknown/i);
  const newIntake = page.getByRole("button", {
    name: "New research intake",
    exact: true,
  });
  if (await newIntake.count()) await expect(newIntake).toBeDisabled();

  await page.reload();
  await page
    .getByRole("button", { name: "Research intake", exact: true })
    .click();
  expect(importCalls).toHaveLength(1);
  // This explicit existing read restores the in-memory confirmed intake.
  await page
    .getByRole("button", { name: "Check intake status", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Retry same import", exact: true }),
  ).toBeEnabled();
  expect(importCalls).toHaveLength(1);
  expect(calls.map((call) => call.method)).toEqual(["POST", "GET"]);
  await page
    .getByRole("button", { name: "Retry same import", exact: true })
    .click();
  await expect.poll(() => importCalls.length).toBe(2);
  expect(importCalls[1].body).toBe(original);
  expect(importCalls[1].method).toBe("POST");
  await expect(status).toContainText("InProgress");
  await expect(
    page.getByText(retainedByAuthority.taskId, { exact: false }).first(),
  ).toBeVisible();
  expect(view.snapshot().resources.sessions).toEqual([]);
});

for (const failure of ["throws", "drops writes"]) {
  test(`research import persistence ${failure} prevents submission`, async ({
    page,
  }) => {
    await confirmCurrentIntake(page);
    await page.evaluate((mode) => {
      Storage.prototype.setItem = () => {
        if (mode === "throws") throw new Error("synthetic storage failure");
      };
    }, failure);
    await page
      .getByRole("button", { name: "Import research task", exact: true })
      .click();
    await expect(page.getByRole("alert")).toContainText(/storage/i);
    expect(importCalls).toHaveLength(0);
    expect(calls).toHaveLength(1);
  });
}

function canonicalTask(imported, state = "Pending") {
  return {
    task_id: imported.taskId,
    state,
    layer: "L3_TaskAgent",
    task: {
      id: imported.taskId,
      state,
      layer: "L3_TaskAgent",
      brief_id: "",
      parent_task_id: "",
      module: "",
      subject: "Controlled research task",
      description: "private task description",
      repo: imported.issue.repository,
      issue: imported.issue.number,
      assigned_lead_id: "",
      blocked_by: [],
      child_task_ids: [],
      delivery: {
        researchIntake: imported.provenance,
        privateData: "private delivery",
      },
      created_at: "2026-09-13T01:00:02Z",
      completed_at: "",
      escalations: [],
    },
  };
}

test("research task refresh is explicit GET only and retains the historical receipt when unavailable", async ({
  page,
}) => {
  const record = await confirmCurrentIntake(page);
  const imported = importedReceipt(record);
  let refreshes = 0;
  importReply = async (call) => {
    if (call.method === "POST") return { code: 201, body: imported };
    expect(call.path).toBe(`/v1/tasks/${imported.taskId}/state`);
    refreshes++;
    return refreshes === 1
      ? { code: 200, body: canonicalTask(imported, "InProgress") }
      : { code: 503, body: { error: "synthetic private upstream failure" } };
  };
  await page
    .getByRole("button", { name: "Import research task", exact: true })
    .click();
  const status = page.getByRole("status", { name: "Research task status" });
  await expect(status).toContainText("Pending");
  expect(importCalls.map((call) => call.method)).toEqual(["POST"]);
  const refresh = page.getByRole("button", {
    name: "Refresh task status",
    exact: true,
  });
  await expect(refresh).toBeEnabled();
  await refresh.click();
  await expect(status).toContainText("InProgress");
  expect(importCalls.map((call) => call.method)).toEqual(["POST", "GET"]);
  await refresh.click();
  await expect(status).toContainText(/unavailable/i);
  await expect(status).toContainText(imported.taskId);
  await expect(status).toContainText("Pending");
  expect(importCalls.map((call) => call.method)).toEqual([
    "POST",
    "GET",
    "GET",
  ]);
  expect(calls).toHaveLength(1);
  expect(view.snapshot().resources.sessions).toEqual([]);
  await expect(
    page.getByText("synthetic private upstream failure", { exact: false }),
  ).toHaveCount(0);
});

test("research import conflict after a known receipt preserves the reference and blocks replacement", async ({
  page,
}) => {
  const record = await confirmCurrentIntake(page);
  const imported = importedReceipt(record);
  importReply = async () =>
    importCalls.length === 1
      ? { code: 201, body: imported }
      : { code: 409, body: { error: "import_conflict" } };
  await page
    .getByRole("button", { name: "Import research task", exact: true })
    .click();
  const status = page.getByRole("status", { name: "Research task status" });
  await expect(status).toContainText("Pending");
  const original = importCalls[0].body;
  await page
    .getByRole("button", { name: "Retry same import", exact: true })
    .click();
  await expect(status).toContainText(/conflict/i);
  expect(importCalls).toHaveLength(2);
  expect(importCalls[1].body).toBe(original);
  await expect(status).toContainText(imported.taskId);
  await expect(
    page.getByRole("button", { name: "New research intake", exact: true }),
  ).toBeDisabled();
});

function taskOwner(imported, kind = "sessions") {
  const document = canonicalTask(imported, "Delegated");
  const claim = {
    schema: "hi/fleet/claim/v1",
    targetKind: kind,
    targetId: `${kind}-owned`,
    workerId: "worker-owned",
    agentId: "agent-owned",
    generation: 4,
    workspace: "/private/owner-worktree",
  };
  document.task.fleet_claim = claim;
  document.task.assigned_lead_id = claim.agentId;
  const resource = {
    schema: "hi/fleet/v1",
    kind,
    id: claim.targetId,
    taskId: imported.taskId,
    workerId: claim.workerId,
    agentId: claim.agentId,
    generation: claim.generation,
    workspace: claim.workspace,
    status: "running",
    claimStatus: "claimed",
    createdAt: "2026-09-13T01:00:03Z",
    lastActivityAt: null,
    waitingReason: null,
    ...(kind === "sessions"
      ? { sessionId: claim.targetId, executionId: "execution-owned" }
      : { executionId: claim.targetId }),
  };
  return { document, claim, resource };
}

async function refreshTask(page, taskId) {
  const [response] = await Promise.all([
    page.waitForResponse(
      (response) => response.url() === `${url}/api/research/tasks/${taskId}`,
    ),
    page
      .getByRole("button", { name: "Refresh task status", exact: true })
      .click(),
  ]);
  expect(response.status()).toBe(200);
  return response.json();
}

test("research task owner navigation requires the exact current session and generation", async ({
  page,
}) => {
  const record = await confirmCurrentIntake(page);
  const imported = importedReceipt(record);
  const { document, resource, claim } = taskOwner(imported);
  importReply = async (call) => ({
    code: call.method === "POST" ? 201 : 200,
    body:
      call.method === "POST"
        ? imported
        : call.path.includes("/v1/fleet/")
          ? resource
          : document,
  });
  view.setResources("sessions", [resource]);
  view.setSource("agamemnon", "connected");
  await page
    .getByRole("button", { name: "Import research task", exact: true })
    .click();
  await expect(
    page.getByRole("status", { name: "Research task status" }),
  ).toContainText("Pending");
  const projected = await refreshTask(page, imported.taskId);
  expect(projected.owner.workerId).toBe(claim.workerId);
  expect(importCalls.map((call) => call.method)).toEqual([
    "POST",
    "GET",
    "GET",
    "GET",
  ]);
  const owner = page.getByRole("region", {
    name: "Research task owner",
    exact: true,
  });
  await expect(owner).toContainText(claim.workerId);
  const navigate = owner.getByRole("button", {
    name: "Open owner session",
    exact: true,
  });
  await expect(navigate).toBeEnabled();
  await navigate.click();
  const detail = page.getByRole("complementary", {
    name: "Item and trace details",
  });
  await expect(detail).toContainText(claim.targetId);
  await expect(detail).toContainText(claim.workerId);
  await page
    .getByRole("button", { name: "Close details", exact: true })
    .click();
  for (const delta of [
    { generation: 5 },
    { workerId: "another-worker" },
    { agentId: "another-agent" },
  ]) {
    view.setResources("sessions", [resource]);
    await expect(navigate).toBeEnabled();
    view.setResources("sessions", [{ ...resource, ...delta }]);
    await expect(navigate).toBeDisabled();
  }
  view.setResources("sessions", [resource]);
  await expect(navigate).toBeEnabled();
  view.setSource("agamemnon", "disconnected");
  await expect(navigate).toBeDisabled();
  expect(view.snapshot().resources.sessions).toHaveLength(1);
  await expect(
    page
      .getByText("Observed issue agents", { exact: true })
      .locator("..")
      .locator("strong"),
  ).toContainText(/^0/);
});

test("research execution owner has no session navigation until an exact related session exists", async ({
  page,
}) => {
  const record = await confirmCurrentIntake(page);
  const imported = importedReceipt(record);
  const { document, resource, claim } = taskOwner(imported, "executions");
  resource.sessionId = "related-session";
  importReply = async (call) => ({
    code: call.method === "POST" ? 201 : 200,
    body:
      call.method === "POST"
        ? imported
        : call.path.includes("/v1/fleet/")
          ? resource
          : document,
  });
  view.setResources("executions", [resource]);
  view.setSource("agamemnon", "connected");
  await page
    .getByRole("button", { name: "Import research task", exact: true })
    .click();
  await expect(
    page.getByRole("status", { name: "Research task status" }),
  ).toContainText("Pending");
  expect((await refreshTask(page, imported.taskId)).owner.targetKind).toBe(
    "executions",
  );
  const owner = page.getByRole("region", {
    name: "Research task owner",
    exact: true,
  });
  await expect(owner).toContainText(claim.targetId);
  const navigate = owner.getByRole("button", {
    name: "Open owner session",
    exact: true,
  });
  await expect(navigate).toBeDisabled();
  const related = {
    ...resource,
    kind: "sessions",
    id: resource.sessionId,
    sessionId: resource.sessionId,
    executionId: resource.id,
  };
  view.setResources("sessions", [related]);
  await expect(navigate).toBeEnabled();
  view.setResources("sessions", [{ ...related, workerId: "other-worker" }]);
  await expect(navigate).toBeDisabled();
  view.setResources("sessions", [related]);
  await expect(navigate).toBeEnabled();
  await navigate.click();
  await expect(
    page.getByRole("complementary", { name: "Item and trace details" }),
  ).toContainText(resource.sessionId);
});

test("research task detail shows only actual correlated HTTP trace and opens existing message details", async ({
  page,
}) => {
  const record = await confirmCurrentIntake(page);
  const imported = importedReceipt(record);
  // A same-task session exists, but this task read has no claim and HTTP events have no generation.
  const { resource } = taskOwner(imported);
  view.setResources("sessions", [resource]);
  view.setSource("agamemnon", "connected");
  importReply = async (call) => ({
    code: call.method === "POST" ? 201 : 200,
    body:
      call.method === "POST" ? imported : canonicalTask(imported, "InProgress"),
  });
  const unrelated = await page.request.post(`${url}/api/research/imports`, {
    headers: { origin: url },
    data: {
      schema: "hi/agamemnon/research-import/v1",
      intakeId: "other-intake",
      requestDigest: "e".repeat(64),
    },
  });
  expect(unrelated.status()).toBe(503);
  await page
    .getByRole("button", { name: "Import research task", exact: true })
    .click();
  await expect(
    page.getByRole("status", { name: "Research task status" }),
  ).toContainText("Pending");
  await refreshTask(page, imported.taskId);
  expect(view.snapshot().observations).toHaveLength(6);
  const actual = view
    .snapshot()
    .observations.filter(
      (event) =>
        event.correlationId === record.intakeId ||
        event.taskId === imported.taskId,
    );
  expect(actual.map((event) => event.operation)).toEqual([
    "request",
    "response",
    "request",
    "response",
  ]);
  expect(
    actual.every(
      (event) => event.transport === "http" && event.generation === undefined,
    ),
  ).toBe(true);
  const trace = page.getByRole("region", {
    name: "Research task trace",
    exact: true,
  });
  await expect(trace).toContainText(actual.at(-1).eventId);
  await expect(trace.getByRole("button")).toHaveCount(4);
  await trace.getByRole("button").first().click();
  const detail = page.getByRole("complementary", {
    name: "Item and trace details",
  });
  await expect(detail).toContainText("Observed message");
  expect(actual.some((event) => event.eventId)).toBe(true);
  const text = await detail.innerText();
  expect(actual.some((event) => text.includes(event.eventId))).toBe(true);
  await expect(
    detail.getByRole("heading", { name: "Work ownership", exact: true }),
  ).toHaveCount(0);
  expect(view.snapshot().resources.sessions).toHaveLength(1);
  await expect(
    page.getByRole("button", { name: "Open owner session", exact: true }),
  ).toHaveCount(0);
});

test("research import returned issue must match the selected confirmed intake before retaining success", async ({
  page,
}) => {
  const record = await confirmCurrentIntake(page);
  const imported = importedReceipt(record);
  const wrong = structuredClone(imported);
  wrong.issue = {
    repository: "homeric/other",
    number: 7,
    url: "https://github.com/homeric/other/issues/7",
  };
  wrong.provenance.issue = wrong.issue;
  importReply = async () =>
    importCalls.length === 1
      ? { code: 201, body: wrong }
      : { code: 200, body: imported };
  const [response] = await Promise.all([
    page.waitForResponse(
      (response) => response.url() === `${url}/api/research/imports`,
    ),
    page
      .getByRole("button", { name: "Import research task", exact: true })
      .click(),
  ]);
  expect(response.status()).toBe(201);
  const status = page.getByRole("status", { name: "Research task status" });
  await expect(status).toContainText(/conflict/i);
  await expect(
    page.getByRole("button", { name: "New research intake", exact: true }),
  ).toBeDisabled();
  const original = importCalls[0].body;
  await page
    .getByRole("button", { name: "Retry same import", exact: true })
    .click();
  await expect(status).toContainText("Pending");
  expect(importCalls).toHaveLength(2);
  expect(importCalls[1].body).toBe(original);
  await expect(
    page.getByRole("link", { name: "Open research issue", exact: true }),
  ).toHaveAttribute("href", record.issue.url);
});

test("research import duplicate clicks and competing tabs share one locked reference", async ({
  page,
  context,
}) => {
  const record = await confirmCurrentIntake(page);
  const imported = importedReceipt(record);
  const second = await context.newPage();
  await second.goto(url);
  await second
    .getByRole("button", { name: "Research intake", exact: true })
    .click();
  await second
    .getByRole("button", { name: "Check intake status", exact: true })
    .click();
  await expect(
    second.getByRole("button", { name: "Import research task", exact: true }),
  ).toBeEnabled();
  let release;
  const held = new Promise((resolve) => {
    release = resolve;
  });
  importReply = async () => {
    if (importCalls.length === 1) await held;
    return { code: importCalls.length === 1 ? 201 : 200, body: imported };
  };
  try {
    await page
      .getByRole("button", { name: "Import research task", exact: true })
      .evaluate((button) => {
        button.click();
        button.click();
      });
    await expect.poll(() => importCalls.length).toBe(1);
    const competing = second.getByRole("button", {
      name: /^(Import research task|Retry same import)$/,
    });
    await competing.click();
    await expect(second.getByRole("alert")).toContainText(
      /coordination|busy|verified/i,
    );
    expect(importCalls).toHaveLength(1);
  } finally {
    release();
  }
  await expect(
    page.getByRole("status", { name: "Research task status" }),
  ).toContainText("Pending");
  await expect(
    second.getByRole("status", { name: "Research task status" }),
  ).toContainText("Pending");
  expect(importCalls).toHaveLength(1);
  await second
    .getByRole("button", { name: "Retry same import", exact: true })
    .click();
  await expect.poll(() => importCalls.length).toBe(2);
  expect(importCalls[1].body).toBe(importCalls[0].body);
});

test("research import sign-in renewal never posts automatically or changes an unknown reference", async ({
  page,
  context,
}) => {
  const record = await confirmCurrentIntake(page);
  const imported = importedReceipt(record);
  importReply = async () =>
    importCalls.length === 1 ? null : { code: 200, body: imported };
  await page
    .getByRole("button", { name: "Import research task", exact: true })
    .click();
  await expect(
    page.getByRole("status", { name: "Research task status" }),
  ).toContainText(/unknown/i);
  const original = importCalls[0].body;
  await context.clearCookies();
  await page.reload();
  await expect(page.getByLabel("Local access token")).toBeVisible();
  expect(importCalls).toHaveLength(1);
  await page.getByLabel("Local access token").fill(token);
  await page.getByRole("button", { name: "Open mission control" }).click();
  await page
    .getByRole("button", { name: "Research intake", exact: true })
    .click();
  await page
    .getByRole("button", { name: "Check intake status", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Retry same import", exact: true }),
  ).toBeEnabled();
  expect(importCalls).toHaveLength(1);
  await expect(
    page.getByRole("button", { name: "New research intake", exact: true }),
  ).toBeDisabled();
  await page
    .getByRole("button", { name: "Retry same import", exact: true })
    .click();
  await expect.poll(() => importCalls.length).toBe(2);
  expect(importCalls[1].body).toBe(original);
});

for (const field of ["requestDigest", "issue"])
  test(`research import retained ${field} mismatch prevents another POST`, async ({
    page,
  }) => {
    const record = await confirmCurrentIntake(page);
    const imported = importedReceipt(record);
    importReply = async () => ({ code: 201, body: imported });
    await page
      .getByRole("button", { name: "Import research task", exact: true })
      .click();
    await expect(
      page.getByRole("status", { name: "Research task status" }),
    ).toContainText("Pending");
    await page.evaluate((field) => {
      const entries = Object.entries(localStorage).map(([key, raw]) => [
        key,
        JSON.parse(raw),
      ]);
      const [key, value] = entries.find(
        ([, value]) => value.schema === "hi/odysseus/research-import/v1",
      );
      if (field === "requestDigest")
        value.reference.requestDigest = "f".repeat(64);
      else
        value.issue = {
          repository: "homeric/other",
          number: 7,
          url: "https://github.com/homeric/other/issues/7",
        };
      localStorage.setItem(key, JSON.stringify(value));
    }, field);
    await page
      .getByRole("button", { name: "Retry same import", exact: true })
      .click();
    await expect(page.getByRole("alert")).toContainText(
      /verified|storage|conflict/i,
    );
    expect(importCalls).toHaveLength(1);
  });

test("research import known explicit new selection clears only local state", async ({
  page,
}) => {
  const record = await confirmCurrentIntake(page);
  const imported = importedReceipt(record);
  importReply = async () => ({ code: 201, body: imported });
  await page
    .getByRole("button", { name: "Import research task", exact: true })
    .click();
  await expect(
    page.getByRole("status", { name: "Research task status" }),
  ).toContainText("Pending");
  await page
    .getByRole("button", { name: "New research intake", exact: true })
    .click();
  await expect(page.getByLabel("Research title")).toBeEnabled();
  await expect(page.getByLabel("Research title")).toHaveValue("");
  await expect(
    page.getByRole("button", { name: "Import research task", exact: true }),
  ).toHaveCount(0);
  expect(importCalls).toHaveLength(1);
  expect(calls).toHaveLength(1);
});

test("research task selected provenance conflict provides no owner action and survives reload", async ({
  page,
}) => {
  const record = await confirmCurrentIntake(page);
  const imported = importedReceipt(record);
  const document = canonicalTask(structuredClone(imported), "InProgress");
  document.task.delivery.researchIntake.requestDigest = "f".repeat(64);
  importReply = async (call) => ({
    code: call.method === "POST" ? 201 : 200,
    body: call.method === "POST" ? imported : document,
  });
  await page
    .getByRole("button", { name: "Import research task", exact: true })
    .click();
  await expect(
    page.getByRole("status", { name: "Research task status" }),
  ).toContainText("Pending");
  expect(
    (await refreshTask(page, imported.taskId)).provenance.requestDigest,
  ).not.toBe(imported.provenance.requestDigest);
  await expect(
    page.getByRole("status", { name: "Research task status" }),
  ).toContainText(/conflict/i);
  await expect(
    page.getByRole("button", { name: "Open owner session", exact: true }),
  ).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: "New research intake", exact: true }),
  ).toBeDisabled();
  const count = importCalls.length;
  await page.reload();
  await page
    .getByRole("button", { name: "Research intake", exact: true })
    .click();
  await page
    .getByRole("button", { name: "Check intake status", exact: true })
    .click();
  await expect(
    page.getByRole("status", { name: "Research task status" }),
  ).toContainText(/conflict/i);
  await expect(
    page.getByRole("button", { name: "New research intake", exact: true }),
  ).toBeDisabled();
  expect(importCalls).toHaveLength(count);
});

test("research task manual terminal resolution remains unverified historical ownership", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const record = await confirmCurrentIntake(page);
  const imported = importedReceipt(record);
  const { document, resource, claim } = taskOwner(imported);
  document.state = document.task.state = "Completed";
  document.task.fleet_resolution = {
    provenance: "manual",
    verifiedApproval: false,
    generation: claim.generation,
    outcome: "completed",
    decision: "approve_completion",
    decisionId: "private-decision",
    reviewerId: "private-reviewer",
    evidenceRef: "private-evidence",
  };
  resource.status = "completed";
  resource.claimStatus = "released";
  resource.resolution = document.task.fleet_resolution;
  importReply = async (call) => ({
    code: call.method === "POST" ? 201 : 200,
    body:
      call.method === "POST"
        ? imported
        : call.path.includes("/v1/fleet/")
          ? resource
          : document,
  });
  view.setResources("sessions", [resource]);
  view.setSource("agamemnon", "connected");
  await page
    .getByRole("button", { name: "Import research task", exact: true })
    .click();
  await expect(
    page.getByRole("status", { name: "Research task status" }),
  ).toContainText("Pending");
  expect(
    (await refreshTask(page, imported.taskId)).resolution.verifiedApproval,
  ).toBe(false);
  const status = page.getByRole("status", { name: "Research task status" });
  await expect(status).toContainText("Completed");
  await expect(status).toContainText(/manual/i);
  await expect(status).toContainText(/unverified|not verified/i);
  await expect(
    page
      .getByText("Observed issue agents", { exact: true })
      .locator("..")
      .locator("strong"),
  ).toContainText(/^0/);
  for (const secret of [
    "private-decision",
    "private-reviewer",
    "private-evidence",
    claim.workspace,
  ])
    await expect(page.getByText(secret, { exact: false })).toHaveCount(0);
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    ),
  ).toBe(true);
});
