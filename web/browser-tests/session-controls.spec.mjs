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

test("private command approval retains the exact response after an uncertain submission", async ({
  page,
}) => {
  const sent = [];
  await page.route("**/api/requests?*", (route) =>
    route.fulfill({
      json: {
        sessionId: "session-one",
        workerId: "worker-one",
        generation: 3,
        requests: [
          {
            requestId: 19,
            fingerprint: "a".repeat(64),
            kind: "command",
            command: "echo synthetic approval",
            details: "Synthetic approval fixture",
            decisions: ["accept", "decline", "cancel"],
          },
        ],
      },
    }),
  );
  await page.route("**/api/commands", (route) => {
    const input = route.request().postDataJSON();
    sent.push(input);
    return route.fulfill({
      status: sent.length === 1 ? 503 : 202,
      json:
        sent.length === 1
          ? {
              commandId: input.commandId,
              error: "unavailable",
              outcome: "unknown",
            }
          : { commandId: input.commandId, status: "submitted" },
    });
  });
  await login(page, {
    operations: ["respond"],
    approvalWorkerIds: ["worker-one"],
  });
  await expect(page.getByLabel("Private agent requests")).toContainText(
    "echo synthetic approval",
  );
  await page
    .getByRole("button", { name: "Allow command", exact: true })
    .click();
  await expect(page.getByLabel("Session commands")).toContainText(
    "Outcome unknown",
  );
  await page
    .getByRole("button", { name: "Retry same request", exact: true })
    .click();
  await expect(page.getByLabel("Session commands")).toContainText(
    "Submitted to controller",
  );
  expect(sent).toHaveLength(2);
  expect(sent[1]).toEqual(sent[0]);
  expect(sent[0]).toMatchObject({
    operation: "respond",
    requestId: 19,
    requestFingerprint: "a".repeat(64),
    response: { decision: "accept" },
  });
});

test("file requests without private evidence permit decline but never approval", async ({
  page,
}) => {
  await page.route("**/api/requests?*", (route) =>
    route.fulfill({
      json: {
        sessionId: "session-one",
        workerId: "worker-one",
        generation: 3,
        requests: [
          {
            requestId: "file-1",
            fingerprint: "b".repeat(64),
            kind: "file",
            details: "No diff supplied",
            decisions: ["decline", "cancel"],
            evidenceAvailable: false,
          },
        ],
      },
    }),
  );
  await login(page, {
    operations: ["respond"],
    approvalWorkerIds: ["worker-one"],
  });
  await expect(page.getByLabel("Private agent requests")).toContainText(
    "File change evidence is unavailable",
  );
  await expect(
    page.getByRole("button", { name: "Allow file changes", exact: true }),
  ).toBeDisabled();
  await expect(
    page.getByRole("button", { name: "Decline", exact: true }),
  ).toBeEnabled();
});

test("agent questions retain private answers through sign-in renewal", async ({
  page,
}) => {
  let signedOut = false;
  const sent = [];
  await page.route("**/api/snapshot", (route) =>
    signedOut
      ? route.fulfill({
          status: 401,
          json: { error: "Local sign-in required" },
        })
      : route.continue(),
  );
  await page.route("**/api/requests?*", (route) =>
    route.fulfill({
      json: {
        sessionId: "session-one",
        workerId: "worker-one",
        generation: 3,
        requests: [
          {
            requestId: "question-1",
            fingerprint: "c".repeat(64),
            kind: "input",
            details: "Synthetic interview",
            decisions: [],
            questions: [
              {
                id: "target",
                header: "Target",
                question: "Which fixture target?",
                isOther: false,
                isSecret: false,
                options: [
                  { label: "M1", description: "First fixture" },
                  { label: "M2", description: "Second fixture" },
                ],
              },
              {
                id: "note",
                header: "Note",
                question: "Private fixture note?",
                isOther: true,
                isSecret: true,
                options: null,
              },
            ],
          },
        ],
      },
    }),
  );
  await page.route("**/api/commands", (route) => {
    const input = route.request().postDataJSON();
    sent.push(input);
    return route.fulfill({
      status: 202,
      json: { commandId: input.commandId, status: "submitted" },
    });
  });
  await login(page, {
    operations: ["respond"],
    approvalWorkerIds: ["worker-one"],
  });
  await page.getByLabel("Which fixture target?").selectOption("M2");
  await page
    .getByLabel("Private fixture note?")
    .fill("Synthetic private answer");
  await expect(page.getByLabel("Private fixture note?")).toHaveAttribute(
    "type",
    "password",
  );
  signedOut = true;
  server.closeAllConnections();
  await expect(page.getByLabel("Local access token")).toBeVisible();
  await expect(page.getByLabel("Private agent requests")).toHaveCount(0);
  signedOut = false;
  await page.getByLabel("Local access token").fill(fixtureCredential);
  await page.getByRole("button", { name: "Open mission control" }).click();
  await expect(page.getByLabel("Private fixture note?")).toHaveValue(
    "Synthetic private answer",
  );
  await page.getByRole("button", { name: "Send answers", exact: true }).click();
  await expect(page.getByLabel("Session commands")).toContainText(
    "Submitted to controller",
  );
  expect(sent).toHaveLength(1);
  expect(sent[0].response).toEqual({
    answers: {
      target: { answers: ["M2"] },
      note: { answers: ["Synthetic private answer"] },
    },
  });
  await expect(
    page.getByRole("button", { name: "Send answers", exact: true }),
  ).toBeDisabled();
});

test("private requests from another generation cannot enable approval", async ({
  page,
}) => {
  await page.route("**/api/requests?*", (route) =>
    route.fulfill({
      json: {
        sessionId: "session-one",
        workerId: "worker-one",
        generation: 2,
        requests: [
          {
            requestId: 19,
            fingerprint: "a".repeat(64),
            kind: "command",
            command: "echo synthetic",
            details: "Old fixture",
            decisions: ["accept"],
          },
        ],
      },
    }),
  );
  await login(page, {
    operations: ["respond"],
    approvalWorkerIds: ["worker-one"],
  });
  await expect(page.getByLabel("Private agent requests")).toContainText(
    "Private requests are unavailable",
  );
  await expect(
    page.getByRole("button", { name: "Allow command", exact: true }),
  ).toHaveCount(0);
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
