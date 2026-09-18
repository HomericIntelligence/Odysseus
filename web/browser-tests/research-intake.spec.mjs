import { createHash, randomBytes } from "node:crypto";
import { test, expect } from "@playwright/test";
import { resolve } from "node:path";
import { FleetView } from "../server/view.mjs";
import { createDashboardServer } from "../server/http.mjs";

let server, url, calls, reply;
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
  // The real backend proxy uses only this private transport fixture.
  server = createDashboardServer({
    view: new FleetView(),
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
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  url = `http://127.0.0.1:${server.address().port}`;
});
test.afterEach(async () => {
  server.closeAllConnections();
  await new Promise((done) => server.close(done));
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
