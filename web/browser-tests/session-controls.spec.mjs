import { randomBytes } from "node:crypto";
import { test, expect } from "@playwright/test";
import { resolve } from "node:path";
import { FleetView } from "../server/view.mjs";
import { createDashboardServer } from "../server/http.mjs";

const fixtureCredential = randomBytes(24).toString("base64url");

let view, server, url;
const session = (id = "one") => ({
  id: `session-${id}`,
  subject: `Session control fixture ${id}`,
  kind: "session",
  taskId: `task-${id}`,
  agentId: `agent-${id}`,
  workerId: `worker-${id}`,
  generation: 3,
  status: "running",
  claimStatus: "claimed",
  activity: "model_working",
  component: "hephaestus",
  lastActivityAt: new Date().toISOString(),
});

test.beforeEach(async () => {
  view = new FleetView();
  view.setSource("agamemnon", "connected");
  view.setSource("isolated-control-fixture", "connected");
  view.setResources("sessions", [session(), session("two")]);
  // This server has no controller configuration. Routes below are browser-only
  // transport substitutes; synthetic session IDs can never reach a real service.
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

async function login(page, capability = {}) {
  await page.route("**/api/capabilities", (route) =>
    route.fulfill({
      json: {
        sessionCommands: {
          enabled: true,
          operations: ["start", "input", "interrupt", "cancel", "resume"],
          inputWorkerIds: ["worker-one", "worker-two"],
          ...capability,
        },
      },
    }),
  );
  await page.goto(url);
  await page.getByLabel("Local access token").fill(fixtureCredential);
  await page.getByRole("button", { name: "Open mission control" }).click();
  await page
    .getByRole("button", { name: "Session control fixture one", exact: true })
    .click();
}

test("uncertain input preserves command identity and never follows a changed selection", async ({
  page,
}) => {
  const requests = [];
  await page.route("**/api/commands", async (route) => {
    const request = route.request().postDataJSON();
    requests.push(request);
    await route.fulfill({
      status: requests.length === 1 ? 503 : 202,
      json:
        requests.length === 1
          ? {
              error: "unavailable",
              outcome: "unknown",
              commandId: request.commandId,
            }
          : { status: "submitted", commandId: request.commandId },
    });
  });
  await login(page);
  await page.getByLabel("Session input").fill("Private test message");
  await page.getByRole("button", { name: "Send input", exact: true }).click();
  await expect(page.getByLabel("Session commands")).toContainText(
    "Outcome unknown",
  );
  expect(requests).toHaveLength(1);
  expect(requests[0]).toMatchObject({
    sessionId: "session-one",
    workerId: "worker-one",
    generation: 3,
    operation: "input",
    text: "Private test message",
  });
  expect(requests[0].commandId).toMatch(/^ui-[0-9a-f]{32}$/);
  await page
    .getByRole("button", { name: "Session control fixture two", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Retry same request", exact: true }),
  ).toBeDisabled();
  expect(requests).toHaveLength(1);
  await page
    .getByRole("button", { name: "Session control fixture one", exact: true })
    .click();
  await page
    .getByRole("button", { name: "Retry same request", exact: true })
    .click();
  await expect(page.getByLabel("Session commands")).toContainText(
    "Submitted to controller",
  );
  expect(requests).toHaveLength(2);
  expect(requests[1]).toEqual(requests[0]);
  await expect(page.getByLabel("Session input")).toHaveValue("");
  await expect(page.getByLabel("Session commands")).toContainText(
    "this receipt does not confirm worker completion",
  );
});

test("capabilities and observed admission state gate commands", async ({
  page,
}) => {
  const requests = [];
  await page.route("**/api/commands", (route) => {
    requests.push(route.request().postDataJSON());
    return route.fulfill({
      status: 500,
      json: { error: "unexpected fixture dispatch" },
    });
  });
  await login(page, { inputWorkerIds: [] });
  await expect(page.getByLabel("Session input")).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: "Start session", exact: true }),
  ).toBeDisabled();
  await expect(
    page.getByRole("button", { name: "Resume session", exact: true }),
  ).toBeDisabled();
  await expect(
    page.getByRole("button", { name: "Request cancellation", exact: true }),
  ).toBeEnabled();
  view.setResources("sessions", [
    { ...session(), status: "cancelling" },
    session("two"),
  ]);
  await expect(
    page.getByRole("button", { name: "Request cancellation", exact: true }),
  ).toBeDisabled();
  expect(requests).toHaveLength(0);
});

test("sign-in renewal retains an uncertain command for same-identity retry", async ({
  page,
}) => {
  const requests = [];
  let signedOut = false;
  await page.route("**/api/snapshot", (route) =>
    signedOut
      ? route.fulfill({
          status: 401,
          json: { error: "Local sign-in required" },
        })
      : route.continue(),
  );
  await page.route("**/api/commands", async (route) => {
    const request = route.request().postDataJSON();
    requests.push(request);
    await route.fulfill({
      status: requests.length === 1 ? 503 : 202,
      json:
        requests.length === 1
          ? {
              error: "unavailable",
              outcome: "unknown",
              commandId: request.commandId,
            }
          : { status: "submitted", commandId: request.commandId },
    });
  });
  await login(page);
  await page.getByLabel("Session input").fill("Retain through sign-in renewal");
  await page.getByRole("button", { name: "Send input", exact: true }).click();
  await expect(page.getByLabel("Session commands")).toContainText(
    "Outcome unknown",
  );
  signedOut = true;
  server.closeAllConnections();
  await expect(page.getByLabel("Local access token")).toBeVisible();
  await expect(page.getByLabel("Retained private request")).toHaveCount(0);
  signedOut = false;
  await page.getByLabel("Local access token").fill(fixtureCredential);
  await page.getByRole("button", { name: "Open mission control" }).click();
  await expect(page.getByLabel("Session commands")).toContainText(
    "Outcome unknown",
  );
  await page
    .getByRole("button", { name: "Retry same request", exact: true })
    .click();
  await expect(page.getByLabel("Session commands")).toContainText(
    "Submitted to controller",
  );
  expect(requests).toHaveLength(2);
  expect(requests[1]).toEqual(requests[0]);
});

test("conflicts retain the original interruption request for explicit retry", async ({
  page,
}) => {
  const requests = [];
  await page.route("**/api/commands", async (route) => {
    const request = route.request().postDataJSON();
    requests.push(request);
    await route.fulfill({
      status: requests.length === 1 ? 409 : 202,
      json:
        requests.length === 1
          ? { error: "conflict", commandId: request.commandId }
          : { status: "submitted", commandId: request.commandId },
    });
  });
  await login(page);
  await page
    .getByRole("button", { name: "Request interruption", exact: true })
    .click();
  await expect(page.getByLabel("Session commands")).toContainText(
    "Controller conflict",
  );
  expect(requests).toHaveLength(1);
  await page
    .getByRole("button", { name: "Retry same request", exact: true })
    .click();
  await expect(page.getByLabel("Session commands")).toContainText(
    "Submitted to controller",
  );
  expect(requests).toHaveLength(2);
  expect(requests[1]).toEqual(requests[0]);
  expect(requests[0]).not.toHaveProperty("text");
});

test("pre-dispatch rejection retains input and cancellation never reports completion", async ({
  page,
}) => {
  const requests = [];
  await page.route("**/api/commands", async (route) => {
    const request = route.request().postDataJSON();
    requests.push(request);
    await route.fulfill({
      status: request.operation === "input" ? 400 : 202,
      json:
        request.operation === "input"
          ? { error: "invalid_request", commandId: request.commandId }
          : { status: "submitted", commandId: request.commandId },
    });
  });
  await login(page);
  await page.getByLabel("Session input").fill("Retain this unsent draft");
  await page.getByRole("button", { name: "Send input", exact: true }).click();
  await expect(page.getByLabel("Session commands")).toContainText(
    "request rejected",
  );
  await expect(page.getByLabel("Session input")).toHaveValue(
    "Retain this unsent draft",
  );
  await page
    .getByRole("button", { name: "Request cancellation", exact: true })
    .click();
  await expect(page.getByLabel("Session commands")).toContainText(
    "Cancellation remains unconfirmed",
  );
  await expect(page.getByLabel("Session input")).toHaveValue(
    "Retain this unsent draft",
  );
  expect(requests).toHaveLength(2);
  expect(requests[1]).not.toHaveProperty("text");
});

test("generation zero cannot enable session commands", async ({ page }) => {
  view.setResources("sessions", [{ ...session(), generation: 0 }]);
  await login(page);
  await expect(page.getByLabel("Session commands")).toContainText(
    "Select a current session with an observed worker and generation",
  );
  await expect(page.getByLabel("Session input")).toHaveCount(0);
});

test("mobile session controls stay visible and submit only the selected cancellation request", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const requests = [];
  await page.route("**/api/commands", async (route) => {
    const request = route.request().postDataJSON();
    requests.push(request);
    await route.fulfill({
      status: 202,
      json: { status: "submitted", commandId: request.commandId },
    });
  });
  await login(page);
  const controls = page.getByLabel("Session commands");
  await expect(controls).toBeVisible();
  const bounds = await controls.boundingBox();
  expect(bounds.x).toBeGreaterThanOrEqual(0);
  expect(bounds.x + bounds.width).toBeLessThanOrEqual(390);
  await page
    .getByRole("button", { name: "Request cancellation", exact: true })
    .click();
  await expect(controls).toContainText("Cancellation remains unconfirmed");
  expect(requests).toHaveLength(1);
  expect(requests[0]).toMatchObject({
    sessionId: "session-one",
    workerId: "worker-one",
    generation: 3,
    operation: "cancel",
  });
  expect(requests[0]).not.toHaveProperty("text");
});
