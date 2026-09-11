import { randomBytes } from "node:crypto";
import { test, expect } from "@playwright/test";
import { resolve } from "node:path";
import { FleetView } from "../server/view.mjs";
import { createDashboardServer } from "../server/http.mjs";

const fixtureCredential = randomBytes(24).toString("base64url");

let view, server, url;
const fixture = () => ({
  schema: "hi/projects-projection/v1",
  authority: "github-issues",
  direction: "issues-to-project",
  state: "degraded",
  stageProjection: "unavailable",
  projected: 1,
  unchanged: 0,
  failed: 0,
  unavailable: 1,
  lastAttemptAt: "2026-09-11T12:00:00Z",
  lastSuccessAt: "2026-09-10T12:00:00Z",
  items: [
    {
      taskId: "task-browser",
      repo: "HomericIntelligence/Odysseus",
      issue: 123,
      orchestrationState: "InProgress",
      state: "projected",
      stageProjection: "unavailable",
      orchestrationIssueUrl:
        "https://github.com/HomericIntelligence/Agamemnon/issues/456",
      workIssueUrl:
        "https://github.com/HomericIntelligence/Odysseus/issues/123",
      pullRequestUrls: [
        "https://github.com/HomericIntelligence/Odysseus/pull/124",
      ],
    },
  ],
});
test.beforeEach(async () => {
  view = new FleetView();
  view.setSource("agamemnon", "connected");
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
async function openPipeline(page) {
  await page.goto(url);
  await page.getByLabel("Local access token").fill(fixtureCredential);
  await page.getByRole("button", { name: "Open mission control" }).click();
  await page.getByRole("button", { name: "Pipeline", exact: true }).click();
}

test("pipeline separates reported board health and review stage from current work ownership", async ({
  page,
}) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  view.setProjects(fixture());
  view.setSource("projects", "connected");
  view.setResources("sessions", [
    {
      id: "session-browser",
      taskId: "task-browser",
      agentId: "agent-browser",
      workerId: "worker-browser",
      generation: 2,
      host: "m2",
      claimStatus: "claimed",
      status: "running",
      activity: "tool_running",
      lastActivityAt: new Date().toISOString(),
    },
  ]);
  await openPipeline(page);
  const pipeline = page.getByLabel("GitHub pipeline projection");
  await expect(pipeline).toContainText("Degraded");
  await expect(pipeline).toContainText("2026-09-10");
  await expect(pipeline).toContainText("Stage unavailable");
  await expect(
    pipeline.getByRole("link", { name: "Work issue" }),
  ).toHaveAttribute(
    "href",
    "https://github.com/HomericIntelligence/Odysseus/issues/123",
  );
  await expect(pipeline.getByRole("link", { name: "PR #124" })).toBeVisible();
  await expect(pipeline).toContainText("agent-browser");
  await expect(pipeline).toContainText("m2");
  await page.screenshot({
    path: "test-results/pipeline-fixture-desktop.png",
    fullPage: true,
  });
  await pipeline.getByRole("button", { name: /agent-browser/ }).click();
  await expect(page.getByLabel("Item and trace details")).toContainText(
    "session-browser",
  );
  await page.getByLabel("Close details").click();
  await page.getByLabel("Filter orchestration state").selectOption("Pending");
  await expect(pipeline).toContainText("No tasks match these filters");
  expect(errors).toEqual([]);
});

test("source failure retains prior board data but cannot imply current ownership or a fresh rebuild", async ({
  page,
}) => {
  view.setProjects(fixture());
  view.setSource("projects", "connected");
  await openPipeline(page);
  view.setSource("projects", "unavailable");
  const pipeline = page.getByLabel("GitHub pipeline projection");
  await expect(pipeline).toContainText("Showing the last available projection");
  await expect(pipeline).toContainText("2026-09-10");
  await expect(pipeline).toContainText("No current claim reported");
});

test("unconfigured pipeline explains missing records and is usable at mobile width", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await openPipeline(page);
  await expect(
    page.getByRole("heading", { name: "Pipeline source not configured" }),
  ).toBeVisible();
  const width = await page.evaluate(() => ({
    page: document.documentElement.scrollWidth,
    viewport: innerWidth,
  }));
  expect(width.page).toBeLessThanOrEqual(width.viewport);
});

test("old connected controller reads cannot establish current ownership", async ({
  page,
}) => {
  view.setProjects(fixture());
  view.setSource("projects", "connected");
  view.sources.agamemnon.observedAt = new Date(
    Date.now() - 120000,
  ).toISOString();
  await openPipeline(page);
  await expect(page.getByLabel("GitHub pipeline projection")).toContainText(
    "Current ownership is unavailable",
  );
});

test("retained ownership stays explicitly unknown in details and cannot enable commands", async ({
  page,
}) => {
  view.setProjects(fixture());
  view.setSource("projects", "connected");
  view.setResources("sessions", [
    {
      id: "session-browser",
      taskId: "task-browser",
      agentId: "agent-browser",
      workerId: "worker-browser",
      generation: 2,
      claimStatus: "claimed",
      status: "running",
      activity: "tool_running",
      lastActivityAt: new Date().toISOString(),
    },
  ]);
  view.setSource("agamemnon", "unavailable");
  await page.route("**/api/capabilities", (route) =>
    route.fulfill({
      json: {
        sessionCommands: {
          enabled: true,
          operations: ["start", "input", "interrupt", "cancel", "resume"],
          inputWorkerIds: [],
        },
      },
    }),
  );
  await openPipeline(page);
  await page.getByRole("button", { name: /agent-browser/ }).click();
  const details = page.getByLabel("Item and trace details");
  await expect(details).toContainText("LAST REPORTED OWNERSHIP");
  await expect(details).toContainText(
    "Current ownership and activity are unknown",
  );
  await expect(
    details
      .locator("dl > div")
      .filter({ has: page.locator("dt", { hasText: /^activity$/ }) })
      .locator("dd"),
  ).toHaveText("unknown");
  await expect(page.getByLabel("Session commands")).toContainText(
    "Commands pause while live observations are disconnected or stale",
  );
  await expect(
    page.getByRole("button", { name: "Request cancellation", exact: true }),
  ).toHaveCount(0);
});

test("a mobile owner selection in 108 rows reveals and focuses its details and restores focus on close", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const value = fixture();
  value.items = Array.from({ length: 108 }, (_, i) => ({
    ...value.items[0],
    taskId: `task-${i}`,
  }));
  value.projected = 108;
  value.unavailable = 108;
  view.setProjects(value);
  view.setSource("projects", "connected");
  view.setResources("sessions", [
    {
      id: "mobile-session",
      taskId: "task-0",
      agentId: "mobile-agent",
      workerId: "mobile-worker",
      generation: 2,
      claimStatus: "claimed",
    },
  ]);
  await openPipeline(page);
  const owner = page.getByRole("button", { name: /mobile-agent/ });
  await owner.click();
  const details = page.getByLabel("Item and trace details");
  await expect(details).toBeFocused();
  await expect(details).toBeInViewport();
  await expect(page.getByLabel("Session commands")).toBeInViewport();
  await page.screenshot({
    path: "test-results/pipeline-fixture-mobile-details.png",
  });
  await page.getByLabel("Close details").click();
  await expect(owner).toBeFocused();
});
