import { readFileSync } from "node:fs";
import { test, expect } from "@playwright/test";
import { resolve } from "node:path";
import { FleetView } from "../server/view.mjs";
import { createDashboardServer } from "../server/http.mjs";

const buildContract = JSON.parse(
  readFileSync(
    new URL("../tests/fixtures/agamemnon-build-contract.json", import.meta.url),
    "utf8",
  ),
);

test("subordinate build details separate the tool owner, retained parent and controller lifecycle", async ({
  page,
}) => {
  const raw = buildContract.persistedGrantDocument.record;
  view.setResources("build-jobs", [raw]);
  await openDashboard(page);
  await page.getByRole("button", { name: raw.id, exact: true }).click();
  const details = page.getByLabel("Item and trace details");
  await expect(details).toContainText("tool-worker-1");
  await expect(details).toContainText("tool-allocation-1");
  await expect(
    details.getByRole("heading", { name: "Retained parent" }),
  ).toBeVisible();
  await expect(details).toContainText("parent-agent");
  await expect(details).toContainText("real-parent-task");
  await expect(details).toContainText("authorized");
  await expect(details).toContainText("unknown");
  await expect(
    page.locator(".stats > div").first().locator("strong"),
  ).toHaveText("0/ 108 target");
  await expect(page.locator(".packet")).toHaveCount(0);
  await expect(page.locator("body")).not.toContainText("/work/parent-source");
  await expect(
    details.getByRole("button", { name: "Start session" }),
  ).toHaveCount(0);
  view.setResources("build-jobs", [buildContract.terminalResponse.record]);
  await expect(details).toContainText("cancelled");
  await expect(details).toContainText("tool-worker-1");
});

test("malformed build identity stays visible with a display key and no private path", async ({
  page,
}) => {
  const raw = structuredClone(buildContract.admission.record);
  raw.id = "/private/sentinel";
  raw.build.snapshotWorkspace = `${raw.id}-attempt-1`;
  view.setResources("build-jobs", [raw]);
  await openDashboard(page);
  const unavailable = page.getByRole("button", {
    name: "Build identity unavailable",
    exact: true,
  });
  await expect(unavailable).toBeVisible();
  await unavailable.click();
  const details = page.getByLabel("Item and trace details");
  await expect(
    details.locator("dt", { hasText: /^display key$/ }),
  ).toBeVisible();
  await expect(details).toContainText("unavailable");
  await expect(details).toContainText("unknown");
  await expect(page.locator("body")).not.toContainText("/private/sentinel");
  await expect(
    details.getByRole("button", { name: "Start session" }),
  ).toHaveCount(0);
  await expect(
    details.getByRole("button", { name: "Send input", exact: true }),
  ).toHaveCount(0);
  await expect(page.locator(".packet")).toHaveCount(0);
});

let view, server, url;
const session = () => ({
  id: "test-session",
  taskId: "test-task",
  subject: "Browser fixture: review a change",
  kind: "session",
  agentId: "test-agent",
  workerId: "test-worker",
  generation: 3,
  component: "hephaestus",
  claimStatus: "active",
  activity: "model_working",
  lastActivityAt: new Date().toISOString(),
  stage: "review",
});
test.beforeEach(async () => {
  view = new FleetView();
  view.setSource("agamemnon", "connected");
  view.setSource("test-fixture", "connected");
  server = createDashboardServer({
    view,
    staticDir: resolve("dist"),
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  url = `http://127.0.0.1:${server.address().port}`;
});
test.afterEach(async () => {
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
});
async function openDashboard(page) {
  await page.goto(url);
  await expect(
    page.getByRole("heading", { name: "System flow", exact: true }),
  ).toBeVisible();
}

test("direct navigation opens the dashboard without a local access key", async ({
  page,
  context,
}) => {
  const posts = [];
  page.on("request", (request) => {
    if (request.method() === "POST") posts.push(request.url());
  });
  await page.goto(url);
  await expect(
    page.getByRole("heading", { name: "System flow", exact: true }),
  ).toBeVisible();
  await expect(page.getByLabel("Local access token")).toHaveCount(0);
  await expect(page.locator(".connection")).toContainText("Live view");
  await expect(
    page.getByRole("heading", { name: "Waiting for admitted work" }),
  ).toBeVisible();
  await expect(page.locator(".packet")).toHaveCount(0);
  await page.reload();
  await expect(
    page.getByRole("heading", { name: "System flow", exact: true }),
  ).toBeVisible();
  await expect(page.locator(".connection")).toContainText("Live view");
  expect(await context.cookies()).toEqual([]);
  expect(posts).toEqual([]);
});

test("an unavailable observation stream leaves the dashboard visible and reconnects", async ({
  page,
}) => {
  await page.route("**/api/events", (route) => route.abort("failed"));
  await page.goto(url);
  await expect(
    page.getByRole("heading", { name: "System flow", exact: true }),
  ).toBeVisible();
  await expect(page.locator(".connection")).toContainText("reconnecting");
  await expect(page.getByLabel("Local access token")).toHaveCount(0);
  await expect(
    page.getByText("Waiting for connection", { exact: true }),
  ).toBeVisible();
  await expect(
    page.locator(".stats > div").first().locator("strong"),
  ).toHaveText("0/ 108 target");
  await expect(page.locator(".packet")).toHaveCount(0);
  await page.unroute("**/api/events");
  await expect(page.locator(".connection")).toContainText("Live view");
});

test("empty data has no fabricated workers, work items or traffic", async ({
  page,
}) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await openDashboard(page);
  await expect(
    page.getByRole("heading", { name: "Waiting for admitted work" }),
  ).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "No observed messages" }),
  ).toBeVisible();
  await expect(page.locator(".packet")).toHaveCount(0);
  await page.screenshot({
    path: "test-results/dashboard-empty.png",
    fullPage: true,
  });
  await page.getByRole("button", { name: "Workers", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "No registered workers" }),
  ).toBeVisible();
  expect(errors).toEqual([]);
});

test("live item details and packet traces follow actual source updates and matching generation", async ({
  page,
}) => {
  view.setResources("workers", [
    {
      id: "test-worker",
      generation: 3,
      host: "m1",
      allocationId: "test-allocation",
    },
  ]);
  view.setResources("sessions", [session()]);
  await openDashboard(page);
  await page
    .getByRole("button", { name: "Browser fixture: review a change" })
    .click();
  await expect(page.getByLabel("Item and trace details")).toContainText(
    "test-agent",
  );
  await expect(page.getByLabel("Item and trace details")).toContainText("m1");
  view.setResources("sessions", [
    {
      ...session(),
      activity: "waiting_approval",
      waitingReason: "Review requested",
    },
  ]);
  await expect(page.getByLabel("Item and trace details")).toContainText(
    "waiting approval",
  );
  await page.getByLabel("Close details").click();
  view.observe({
    eventId: "test-message",
    sourceId: "test-source",
    sourceSequence: 1,
    source: "keystone",
    target: "hephaestus",
    operation: "deliver",
    observedAt: new Date().toISOString(),
    taskId: "test-task",
    workerId: "test-worker",
    generation: 3,
    transport: "nats-jetstream",
    messageId: "test-command",
    payload: "PRIVATE-SHOULD-NOT-RENDER",
  });
  await page.locator(".trace-row").first().click();
  await expect(page.getByLabel("Item and trace details")).toContainText(
    "test-agent",
  );
  await expect(page.getByLabel("Item and trace details")).toContainText(
    "test-command",
  );
  await expect(page.locator("body")).not.toContainText(
    "PRIVATE-SHOULD-NOT-RENDER",
  );
  await page.getByLabel("Close details").click();
  await page.getByLabel("Search items and traces").fill("no matching item");
  await expect(
    page.getByRole("heading", { name: "No items match these filters" }),
  ).toBeVisible();
});

test("host filters apply to registered worker cards", async ({ page }) => {
  view.setResources("workers", [
    { id: "m1-worker", host: "m1" },
    { id: "m2-worker", host: "m2" },
  ]);
  await openDashboard(page);
  await page.getByRole("button", { name: "Workers", exact: true }).click();
  await page.getByLabel("Filter host").selectOption("m1");
  await expect(page.locator(".worker-card")).toHaveCount(1);
  await expect(page.locator(".worker-card")).toContainText("m1-worker");
});
