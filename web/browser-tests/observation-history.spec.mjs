import { test, expect } from "@playwright/test";
import { resolve } from "node:path";
import { FleetView } from "../server/view.mjs";
import { createDashboardServer } from "../server/http.mjs";

const instant = Date.parse("2026-09-20T19:20:30.000Z");
const receivedAt = new Date(instant).toISOString();
const observedAt = "2026-09-20T19:20:29.000Z";
let view, server, url;

const observation = (eventId, host = "retired-m1") => ({
  eventId,
  source: "keystone",
  target: "hephaestus",
  operation: "deliver",
  taskId: "history-task",
  sessionId: "history-session",
  workerId: "history-worker",
  agentId: "history-agent",
  generation: 3,
  observedAt,
  host,
});

function restore() {
  const prior = new FleetView({ now: () => instant });
  prior.observe({
    ...observation("retained-one"),
    payload: "PRIVATE_PAYLOAD_SENTINEL",
    prompt: "PRIVATE_PROMPT_SENTINEL",
    commandOutput: "PRIVATE_OUTPUT_SENTINEL",
  });
  prior.observe(observation("retained-two", "retired-m2"));
  view.restoreHistory(prior.exportHistory());
  view.history = {
    status: "restored",
    restartGap: true,
    pending: false,
    persistedSequence: 2,
    persistedAt: receivedAt,
    retained: 2,
  };
}

test.beforeEach(async ({ page }) => {
  // Date is fixed while browser timers keep running. A recent restored row must
  // never qualify as live merely because it is inside the animation window.
  await page.clock.setFixedTime(new Date(instant));
  view = new FleetView({ now: () => instant });
  server = createDashboardServer({ view, staticDir: resolve("dist") });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  url = `http://127.0.0.1:${server.address().port}`;
});

test.afterEach(async () => {
  server.closeAllConnections();
  await new Promise((done) => server.close(done));
});

async function openHistory(page) {
  await page.goto(url);
  await page
    .getByRole("button", { name: "Observation history", exact: true })
    .click();
  await expect(
    page.getByRole("heading", { name: "Observation history", exact: true }),
  ).toBeVisible();
}

test("restored history preserves metadata and filters hosts without current resources", async ({
  page,
}) => {
  restore();
  await openHistory(page);
  const table = page.getByRole("table", { name: "Retained observations" });
  await expect(table.locator("tbody tr")).toHaveCount(2);
  const first = table.getByRole("row").filter({ hasText: "retained-one" });
  await expect(first).toContainText(observedAt);
  await expect(first).toContainText(receivedAt);
  await expect(first.getByRole("cell").first()).toHaveText("1");
  await expect(first).toContainText("Restored");
  await expect(
    page.getByLabel("Filter host").getByRole("option", { name: "retired-m1" }),
  ).toHaveCount(1);
  await page.getByLabel("Filter host").selectOption("retired-m1");
  await expect(table.locator("tbody tr")).toHaveCount(1);
  await page.getByLabel("Search items and traces").fill("retained-two");
  await expect(table.locator("tbody tr")).toHaveCount(0);
  await page.getByLabel("Filter host").selectOption("");
  await expect(table.locator("tbody tr")).toHaveCount(1);
  await page.getByRole("button", { name: "retained-two", exact: true }).click();
  await expect(page.getByLabel("Item and trace details")).toContainText(
    "history-worker",
  );
  await expect(page.locator("body")).not.toContainText("PRIVATE_");
  await expect(page.getByLabel("Observation archive status")).toContainText(
    "Restart gap",
  );
});

test("recent restored observations do not animate or count as current traffic; new observations do", async ({
  page,
}) => {
  restore();
  await page.goto(url);
  await expect(page.locator(".connection")).toContainText("Live view");
  await expect(
    page.locator(".stats > div").nth(3).locator("strong"),
  ).toHaveText("0last 30s");
  await expect(
    page.locator(".stats > div").first().locator("strong"),
  ).toHaveText("0/ 108 target");
  await expect(
    page.locator(".stats > div").nth(2).locator("strong"),
  ).toHaveText("0workers");
  await expect(
    page.locator(
      ".packet, .node-live, .flow-edge.observed, .component-list .lit",
    ),
  ).toHaveCount(0);
  await expect(page.locator(".trace-row")).toHaveCount(0);
  view.observe(observation("new-live-observation", "current-laptop"));
  await expect(
    page.locator(".stats > div").nth(3).locator("strong"),
  ).toHaveText("1last 30s");
  await expect(page.locator(".packet")).toHaveCount(1);
  await expect(page.locator(".trace-row")).toHaveCount(1);
  await expect(page.locator(".flow-edge.observed")).toHaveCount(1);
  await expect(page.locator(".component-list .lit")).toHaveCount(2);
  await page
    .getByRole("button", { name: "Observation history", exact: true })
    .click();
  const table = page.getByRole("table", { name: "Retained observations" });
  await expect(table.locator("tbody tr")).toHaveCount(3);
  await expect(
    table.getByRole("row").filter({ hasText: "new-live-observation" }),
  ).toContainText("Live");
});

test("history selection cannot select matching current session controls", async ({
  page,
}) => {
  restore();
  view.setSource("agamemnon", "connected");
  view.setResources("sessions", [
    {
      id: "history-session",
      taskId: "history-task",
      kind: "session",
      subject: "Current session fixture",
      workerId: "history-worker",
      agentId: "history-agent",
      generation: 3,
      claimStatus: "claimed",
      status: "running",
      activity: "model_working",
      lastActivityAt: receivedAt,
    },
  ]);
  await page.route("**/api/capabilities", (route) =>
    route.fulfill({
      json: {
        sessionCommands: {
          enabled: true,
          operations: ["input"],
          inputWorkerIds: ["history-worker"],
        },
      },
    }),
  );
  await page.goto(url);
  await page
    .getByRole("button", { name: "Current session fixture", exact: true })
    .click();
  await expect(page.getByLabel("Session input")).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Load command logs" }),
  ).toBeVisible();
  await page.getByLabel("Close details").click();
  await page
    .getByRole("button", { name: "Observation history", exact: true })
    .click();
  await page.getByRole("button", { name: "retained-one", exact: true }).click();
  await expect(page.getByLabel("Item and trace details")).toContainText(
    "history-session",
  );
  await expect(page.getByLabel("Session commands")).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: "Load command logs" }),
  ).toHaveCount(0);
  await expect(
    page.getByRole("heading", { name: "Work ownership" }),
  ).toHaveCount(0);
});

for (const { name, history, expected } of [
  {
    name: "memory-only",
    history: { status: "memory_only" },
    expected: "Memory only",
  },
  {
    name: "missing archive",
    history: { status: "new_archive", restartGap: true },
    expected: "New archive",
  },
  {
    name: "empty committed archive",
    history: {
      status: "restored",
      retained: 0,
      persistedSequence: 0,
      persistedAt: receivedAt,
    },
    expected: "Empty committed archive",
  },
  {
    name: "corrupt archive",
    history: { status: "unavailable", reason: "invalid_or_unreadable_archive" },
    expected: "History unavailable",
  },
]) {
  test(`history reports ${name} separately from live source health`, async ({
    page,
  }) => {
    view.history = { pending: false, restartGap: false, ...history };
    await openHistory(page);
    const status = page.getByLabel("Observation archive status");
    await expect(status).toContainText(expected);
    await expect(
      page
        .getByRole("table", { name: "Retained observations" })
        .locator("tbody tr"),
    ).toHaveCount(0);
    await expect(
      page.locator(".stats > div").first().locator("strong"),
    ).toHaveText("0/ 108 target");
    if (history.reason)
      await expect(status).toContainText(history.reason.replaceAll("_", " "));
  });
}

test("pending persistence and partial retention show the last confirmed receipt", async ({
  page,
}) => {
  restore();
  view.history = {
    ...view.history,
    status: "persisted",
    pending: true,
    retained: 1,
    omitted: 1,
  };
  await openHistory(page);
  const status = page.getByLabel("Observation archive status");
  await expect(status).toContainText("Pending persistence");
  await expect(status).toContainText("1 retained in archive");
  await expect(status).toContainText("1 omitted");
  await expect(status).toContainText("Confirmed sequence 2");
  await expect(status).toContainText(receivedAt);
});
