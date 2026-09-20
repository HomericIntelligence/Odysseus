import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { once } from "node:events";
import { test } from "node:test";
import { createDashboardServer } from "../server/http.mjs";
import { FleetView } from "../server/view.mjs";

const request = {
  schema: "hi/nestor/intake-request/v1",
  intakeId: "research-0123456789abcdef0123456789abcdef",
  workRepository: "HomericIntelligence/Odysseus",
  title: "Research a durable interface",
  body: "Publishable requirements with κόσμος and 🧭.",
};
const sha = (text) => createHash("sha256").update(text).digest("hex");
function receipt(input = request, phase = "created") {
  const normalized = {
    ...input,
    workRepository: input.workRepository.toLowerCase(),
  };
  const requestDigest = sha(
    JSON.stringify(
      Object.fromEntries(
        Object.entries(normalized).sort(([a], [b]) => a.localeCompare(b)),
      ),
    ),
  );
  const bodyDigest = sha(
    `${input.body}\n\n<!-- nestor:fleet-intake:v1 id=${input.intakeId} digest=${requestDigest} -->`,
  );
  return {
    schema: "hi/nestor/intake/v1",
    intakeId: input.intakeId,
    workRepository: normalized.workRepository,
    requestDigest,
    bodyDigest,
    phase,
    generation: 1,
    createdAt: "2026-09-12T12:00:00Z",
    ...(phase === "prepared" ? {} : { attemptId: "a".repeat(32) }),
    ...(phase === "created"
      ? {
          issue: {
            repository: normalized.workRepository,
            number: 42,
            url: `https://github.com/${normalized.workRepository}/issues/42`,
          },
          receipt: {
            kind: "confirmed_issue",
            observedAt: "2026-09-12T12:00:01Z",
          },
        }
      : {}),
  };
}
async function fixture(t, fetchImpl, extra = {}) {
  const upstreamToken = randomBytes(24).toString("hex");
  const calls = [];
  const server = createDashboardServer({
    view: new FleetView(),
    research: {
      url: "http://127.0.0.1:9999",
      token: upstreamToken,
      fetchImpl: async (...args) => {
        calls.push(args);
        return fetchImpl(...args);
      },
      ...extra,
    },
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => {
    server.closeAllConnections();
    server.close();
  });
  const origin = `http://127.0.0.1:${server.address().port}`;
  const headers = { origin, "content-type": "application/json" };
  const submit = (input = request, overrides = {}) =>
    fetch(`${origin}/api/research/intakes`, {
      method: "POST",
      headers,
      body: JSON.stringify(input),
      ...overrides,
    });
  const inspect = (digest = receipt().requestDigest) =>
    fetch(
      `${origin}/api/research/intakes/${request.intakeId}?requestDigest=${digest}`,
    );
  return { origin, headers, calls, submit, inspect, upstreamToken };
}

test("keyless local intake forwards exact publishable content and keeps Nestor credentials on backend", async (t) => {
  const f = await fixture(t, async () => Response.json(receipt()));
  const capability = await fetch(`${f.origin}/api/capabilities`);
  assert.deepEqual((await capability.json()).researchIntake, { enabled: true });
  const result = await f.submit();
  assert.equal(result.status, 200);
  assert.deepEqual(await result.json(), { intake: receipt() });
  assert.equal(f.calls.length, 1);
  const [url, options] = f.calls[0];
  assert.equal(String(url), "http://127.0.0.1:9999/v1/research/intakes");
  assert.equal(options.headers.authorization, `Bearer ${f.upstreamToken}`);
  assert.equal(options.redirect, "error");
  assert.ok(options.signal instanceof AbortSignal);
  assert.deepEqual(JSON.parse(options.body), request);
});

test("intake write requires a local host and same-origin intent before contacting Nestor", async (t) => {
  const f = await fixture(t, async () => Response.json(receipt()));
  for (const [headers, error] of [
    [{ "content-type": "application/json" }, "Origin required"],
    [{ ...f.headers, origin: "https://foreign.example" }, "Forbidden origin"],
    [
      {
        ...f.headers,
        host: "foreign.example",
        origin: "http://foreign.example",
      },
      "Forbidden origin",
    ],
    [{ ...f.headers, "sec-fetch-site": "cross-site" }, "Forbidden origin"],
  ]) {
    const result = await f.submit(request, { headers });
    assert.equal(result.status, 403);
    assert.deepEqual(await result.json(), { error });
    assert.equal(f.calls.length, 0);
  }
  assert.equal(f.calls.length, 0);
});

test("invalid or oversized intake never reaches the upstream", async (t) => {
  const f = await fixture(t, async () => Response.json(receipt()));
  for (const input of [
    null,
    { ...request, secret: "private" },
    { ...request, intakeId: "../other" },
    { ...request, workRepository: "org/../repo" },
    { ...request, body: "nestor:fleet-intake:forged" },
    { ...request, title: "é".repeat(129) },
    { ...request, body: "é".repeat(30001) },
    { ...request, title: "\ud800" },
  ]) {
    assert.equal((await f.submit(input)).status, 400);
  }
  assert.equal(f.calls.length, 0);
});

test("uncertain upstream outcome is sanitized and an explicit retry sends the same identity and content", async (t) => {
  let calls = 0;
  const f = await fixture(t, async () => {
    if (++calls === 1)
      throw new Error("private provider error with request body");
    return Response.json(receipt());
  });
  const first = await f.submit();
  assert.equal(first.status, 503);
  assert.deepEqual(await first.json(), {
    error: "intake_unconfirmed",
    intakeId: request.intakeId,
    outcome: "unknown",
  });
  assert.equal(f.calls.length, 1);
  assert.equal((await f.submit()).status, 200);
  assert.equal(f.calls[0][1].body, f.calls[1][1].body);
});

test("read-only status validates the retained content digest without synthesizing another POST", async (t) => {
  const f = await fixture(t, async () => Response.json(receipt()));
  const result = await f.inspect();
  assert.equal(result.status, 200);
  assert.deepEqual(await result.json(), { intake: receipt() });
  assert.equal(f.calls[0][1].method, "GET");
  assert.equal(f.calls[0][1].body, undefined);
  assert.equal(
    String(f.calls[0][0]),
    `http://127.0.0.1:9999/v1/research/intakes/${request.intakeId}`,
  );
  assert.equal((await f.inspect("f".repeat(64))).status, 409);
});

test("unconfirmed phases have no issue receipt and do not imply research dispatch", async (t) => {
  let phase = "prepared";
  const f = await fixture(t, async () =>
    Response.json(receipt(request, phase)),
  );
  for (phase of ["prepared", "creating"]) {
    const result = await f.submit();
    assert.equal(result.status, 200);
    assert.deepEqual(await result.json(), { intake: receipt(request, phase) });
  }
});

test("foreign, unconfirmed, unsafe and malformed receipts never expose issue links", async (t) => {
  let record;
  const f = await fixture(t, async () => Response.json(record));
  for (record of [
    { ...receipt(), intakeId: "research-foreign" },
    { ...receipt(), requestDigest: "f".repeat(64) },
    { ...receipt(), bodyDigest: "f".repeat(64) },
    { ...receipt(), generation: 2 },
    { ...receipt(), privateBody: "unexpected content" },
    { ...receipt(), receipt: undefined },
    { ...receipt(), phase: "creating" },
    {
      ...receipt(),
      issue: { ...receipt().issue, url: "https://foreign.example/issues/42" },
    },
    { ...receipt(), issue: { ...receipt().issue, number: 0 } },
  ]) {
    const result = await f.submit();
    assert.equal(result.status, 503);
    const body = await result.text();
    assert.ok(!body.includes("http"));
    assert.ok(!body.includes("unexpected content"));
  }
});

test("HTTP errors preserve uncertainty without forwarding raw upstream errors or credentials", async (t) => {
  let status;
  const f = await fixture(
    t,
    async () => new Response("untrusted PRIVATE error", { status }),
  );
  for (status of [400, 401, 404, 409, 429, 500, 503]) {
    const result = await f.submit();
    assert.equal(result.status, status === 409 ? 409 : 503);
    assert.ok(!(await result.text()).includes("PRIVATE"));
  }
  status = 404;
  const missing = await f.inspect();
  assert.equal(missing.status, 404);
  assert.deepEqual(await missing.json(), {
    error: "intake_not_found",
    intakeId: request.intakeId,
    outcome: "unknown",
  });
});

test("status requires one valid digest and a valid ID before upstream access", async (t) => {
  const f = await fixture(t, async () => Response.json(receipt()));
  for (const suffix of [
    request.intakeId,
    `${request.intakeId}?requestDigest=x`,
    `${request.intakeId}?requestDigest=${"a".repeat(64)}&requestDigest=${"a".repeat(64)}`,
    `bad!id?requestDigest=${"a".repeat(64)}`,
  ]) {
    const result = await fetch(`${f.origin}/api/research/intakes/${suffix}`);
    assert.equal(result.status, 400);
  }
  assert.equal(f.calls.length, 0);
});

test("intake configuration is disabled by default and invalid endpoints fail at startup", async (t) => {
  for (const research of [
    { url: "http://remote.example", token: "fixture" },
    { url: "https://user:pass@example.test", token: "fixture" },
    { url: "https://example.test", token: "" },
  ]) {
    assert.throws(() =>
      createDashboardServer({
        view: new FleetView(),
        research,
      }),
    );
  }
  const server = createDashboardServer({
    view: new FleetView(),
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => {
    server.closeAllConnections();
    server.close();
  });
  const origin = `http://127.0.0.1:${server.address().port}`;
  const result = await fetch(`${origin}/api/research/intakes`, {
    method: "POST",
    headers: { origin, "content-type": "application/json" },
    body: JSON.stringify(request),
  });
  assert.equal(result.status, 503);
  assert.deepEqual(await result.json(), {
    error: "not_configured",
    outcome: "not_submitted",
  });
});

test("supported empty requirements and UTF-8 title boundary retain the native request digest", async (t) => {
  const input = { ...request, title: "é".repeat(128), body: "" };
  const f = await fixture(t, async () => Response.json(receipt(input)));
  const result = await f.submit(input);
  assert.equal(result.status, 200);
  assert.deepEqual(await result.json(), { intake: receipt(input) });
});

test("bounded upstream receipt rejects excessive or invalid UTF-8 content", async (t) => {
  let response;
  const f = await fixture(t, async () => response);
  for (response of [
    new Response("x".repeat(2 * 1024 * 1024 + 1)),
    new Response(new Uint8Array([0xff, 0xfe])),
    Response.json({ ...receipt(), createdAt: "2026-02-31T12:00:00Z" }),
  ]) {
    assert.equal((await f.submit()).status, 503);
  }
});

test("in-flight intake requests are bounded and excess requests never reach Nestor", async (t) => {
  const pending = [];
  const f = await fixture(
    t,
    async () => new Promise((resolve) => pending.push(resolve)),
  );
  const requests = Array.from({ length: 4 }, () => f.submit());
  for (let i = 0; pending.length < 4 && i < 100; i++)
    await new Promise((done) => setTimeout(done, 5));
  try {
    assert.equal(pending.length, 4);
    const excess = await f.submit();
    assert.equal(excess.status, 429);
    assert.deepEqual(await excess.json(), {
      error: "busy",
      outcome: "not_submitted",
    });
    assert.equal(f.calls.length, 4);
  } finally {
    pending.forEach((resolve) => resolve(Response.json(receipt())));
    await Promise.all(requests);
  }
});
