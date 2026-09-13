import { randomBytes } from "node:crypto";
import { test, expect } from "@playwright/test";
import { resolve } from "node:path";
import { FleetView } from "../server/view.mjs";
import { createDashboardServer } from "../server/http.mjs";

const fixtureCredential = randomBytes(24).toString("base64url");

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
    token: fixtureCredential,
    staticDir: resolve("dist"),
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  url = `http://127.0.0.1:${server.address().port}`;
});
test.afterEach(async () => {
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
});
async function login(page) {
  await page.goto(url);
  await page.getByLabel("Local access token").fill(fixtureCredential);
  await page.getByRole("button", { name: "Open mission control" }).click();
  await expect(
    page.getByRole("heading", { name: "System flow", exact: true }),
  ).toBeVisible();
}

test("empty data has no fabricated workers, work items or traffic", async ({
  page,
}) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await login(page);
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
  await login(page);
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
  await login(page);
  await page.getByRole("button", { name: "Workers", exact: true }).click();
  await page.getByLabel("Filter host").selectOption("m1");
  await expect(page.locator(".worker-card")).toHaveCount(1);
  await expect(page.locator(".worker-card")).toContainText("m1-worker");
});
