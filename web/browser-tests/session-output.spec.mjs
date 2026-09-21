import { test, expect } from "@playwright/test";
import { resolve } from "node:path";
import { FleetView } from "../server/view.mjs";
import { createDashboardServer } from "../server/http.mjs";

let server, url, reads, reply, view;
const scope = {
  sessionId: "output-one",
  workerId: "worker-one",
  generation: 2,
};
const retained = () => ({
  ...scope,
  receiptDigest: "a".repeat(64),
  ownership: "historical",
  bundle: {
    schema: "hi/fleet/session-output/v1",
    identity: { ...scope, providerThreadId: "thread-one" },
    provider: { name: "codex", version: "0.153.4" },
    capture: {
      profile: "completed_command_items",
      complete: false,
      retainedItems: 2,
      observedCompletedItems: 3,
      omittedItems: 1,
      retentionLimited: true,
    },
    items: [
      {
        turnId: "turn-one",
        itemId: "item-one",
        command: "just example-test",
        cwd: "/work/example",
        status: "failed",
        exitCode: 1,
        durationMs: 42,
        completedAtMs: 1000,
        recordDigest: "b".repeat(64),
        output: {
          kind: "provider_aggregate",
          text: "Private fixture output: <b>plain text</b>\nΔ test failed",
          captureTruncated: true,
          providerTruncated: null,
        },
      },
      {
        turnId: "turn-one",
        itemId: "item-two",
        command: "just example-empty",
        cwd: "/work/example",
        status: "completed",
        exitCode: null,
        durationMs: null,
        completedAtMs: 2000,
        recordDigest: "c".repeat(64),
        output: {
          kind: "provider_aggregate",
          text: null,
          captureTruncated: false,
          providerTruncated: null,
        },
      },
    ],
  },
});

test.beforeEach(async () => {
  reads = [];
  reply = { code: 200, body: retained() };
  view = new FleetView();
  view.setSource("agamemnon", "connected");
  view.setResources("sessions", [
    {
      id: scope.sessionId,
      workerId: scope.workerId,
      generation: scope.generation,
      kind: "session",
      subject: "Synthetic output session",
      taskId: "task-one",
      status: "completed",
    },
  ]);
  // This fixture has no real controller, worker, provider, or artifact source.
  server = createDashboardServer({
    view,
    staticDir: resolve("dist"),
    sessionOutput: {
      read: async (input) => {
        reads.push(input);
        return reply;
      },
    },
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  url = `http://127.0.0.1:${server.address().port}`;
});

test.afterEach(async () => {
  server.closeAllConnections();
  await new Promise((done) => server.close(done));
});

async function select(page) {
  await page.goto(url);
  await page
    .getByRole("button", { name: "Synthetic output session", exact: true })
    .click();
}

test("completed output loads on request with commands disabled and remains plain private text", async ({
  page,
}) => {
  await select(page);
  expect(reads).toEqual([]);
  await page
    .getByRole("button", { name: "Load command logs", exact: true })
    .click();
  const pane = page.getByLabel("Recorded command output");
  await expect(pane).toContainText("Private fixture output: <b>plain text</b>");
  await expect(pane.locator("b")).toHaveCount(0);
  await expect(pane).toContainText("Historical output");
  await expect(pane).toContainText("1 omitted");
  await expect(pane).toContainText("Collector truncated this output");
  await expect(pane).toContainText(
    "Output unavailable or empty in the provider record",
  );
  await expect(pane).toContainText("Exit code: unknown");
  await expect(pane).toContainText("Exit code: 1");
  await expect(pane).toContainText("Completeness is unknown");
  expect(reads).toEqual([scope]);
  expect(
    await page.evaluate(() => ({
      local: { ...localStorage },
      session: { ...sessionStorage },
    })),
  ).toEqual({ local: {}, session: {} });
  await page.getByLabel("Close details").click();
  await expect(
    page.getByText("Private fixture output", { exact: false }),
  ).toHaveCount(0);
});

test("missing registered output and unavailable ownership have explicit states", async ({
  page,
}) => {
  reply = { code: 404, body: { error: "not_registered" } };
  await select(page);
  await page
    .getByRole("button", { name: "Load command logs", exact: true })
    .click();
  const pane = page.getByLabel("Recorded command output");
  await expect(pane).toContainText(
    "No collected output is registered for this session",
  );
  reply = { code: 503, body: { error: "unavailable" } };
  await page
    .getByRole("button", { name: "Load command logs", exact: true })
    .click();
  await expect(pane).toContainText(
    "Output or its current ownership check is unavailable",
  );
  await expect(pane).not.toContainText("No commands ran");
});

test("loaded output is a snapshot across a later ownership update and can be refreshed", async ({
  page,
}) => {
  reply.body.ownership = "current";
  await select(page);
  const load = page.getByRole("button", {
    name: "Load command logs",
    exact: true,
  });
  await load.click();
  const pane = page.getByLabel("Recorded command output");
  await expect(pane).toContainText("Private fixture output");
  view.setResources("sessions", [
    {
      id: scope.sessionId,
      workerId: scope.workerId,
      generation: scope.generation,
      kind: "session",
      subject: "Synthetic output session",
      taskId: "task-one",
      status: "failed",
      claimStatus: "released",
    },
  ]);
  await expect(page.getByLabel("Item and trace details")).toContainText(
    "released",
  );
  await expect(pane).toContainText("Private fixture output");
  await expect(pane).not.toContainText("matches the current session owner");
  await expect(pane).toContainText("when these logs were loaded");
  expect(reads).toEqual([scope]);
  reply.body.ownership = "historical";
  await load.click();
  await expect(pane).toContainText("Historical output");
  expect(reads).toEqual([scope, scope]);
});
