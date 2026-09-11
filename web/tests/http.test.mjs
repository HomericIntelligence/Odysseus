import { randomBytes } from "node:crypto";
import { test } from "node:test";
import assert from "node:assert/strict";
import { get, request as httpRequest } from "node:http";
import { createDashboardServer } from "../server/http.mjs";
import { FleetView } from "../server/view.mjs";

const fixtureCredential = randomBytes(24).toString("base64url");

async function fixture(t, options = {}) {
  const view = new FleetView();
  const server = createDashboardServer({
    view,
    token: fixtureCredential,
    ...options,
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => {
    server.closeAllConnections();
    server.close();
  });
  const url = `http://127.0.0.1:${server.address().port}`;
  return { server, view, url };
}
async function login(url) {
  const response = await fetch(`${url}/api/session`, {
    method: "POST",
    headers: { origin: url, "content-type": "application/json" },
    body: JSON.stringify({ token: fixtureCredential }),
  });
  assert.equal(response.status, 200);
  assert.match(response.headers.get("set-cookie"), /HttpOnly.*SameSite=Strict/);
  return response.headers.get("set-cookie").split(";")[0];
}

test("a request-target decoder failure produces a bounded response without rejecting the handler", async (t) => {
  const { server, url } = await fixture(t);
  const output = {};
  const response = {
    setHeader() {},
    writeHead(status) {
      output.status = status;
    },
    end(value) {
      output.body = JSON.parse(value);
    },
  };
  // Inject a decoder fault directly. No malformed traffic is sent to a service.
  const request = {
    headers: { host: new URL(url).host },
    get url() {
      throw new TypeError("synthetic decoder failure");
    },
  };
  await server.listeners("request")[0](request, response);
  assert.equal(output.status, 400);
  assert.deepEqual(output.body, { error: "Invalid request target" });
});

test("private Unicode input survives an HTTP chunk boundary inside a code point", async (t) => {
  const submitted = [];
  const { url } = await fixture(t, {
    commands: {
      submit: async (input) => {
        submitted.push(input);
        return { code: 202, body: { status: "submitted" } };
      },
    },
  });
  const cookie = await login(url);
  const input = { text: "Review this 🌍 change\nwithout changing the input." };
  const bytes = Buffer.from(JSON.stringify(input));
  const split = bytes.indexOf(Buffer.from("🌍")) + 2;
  const status = await new Promise((resolve, reject) => {
    const request = httpRequest(
      `${url}/api/commands`,
      {
        method: "POST",
        headers: { cookie, origin: url, "content-type": "application/json" },
      },
      (response) => {
        response.resume();
        response.on("end", () => resolve(response.statusCode));
      },
    );
    request.on("error", reject);
    request.write(bytes.subarray(0, split), () => {
      setTimeout(() => request.end(bytes.subarray(split)), 20);
    });
  });
  assert.equal(status, 202);
  assert.deepEqual(submitted, [input]);
});

test("work and flow metadata require a local authenticated session", async (t) => {
  const { url, view } = await fixture(t);
  assert.equal((await fetch(`${url}/api/snapshot`)).status, 401);
  const cookie = await login(url);
  view.setResources("sessions", [
    { id: "s1", agentId: "myrmidon-1", token: fixtureCredential },
  ]);
  const response = await fetch(`${url}/api/snapshot`, { headers: { cookie } });
  assert.equal(response.status, 200);
  const body = await response.text();
  assert.equal(body.includes("myrmidon-1"), true);
  assert.equal(body.includes(fixtureCredential), false);
});

test("command submission requires an authenticated same-origin JSON request and bounded body", async (t) => {
  const submitted = [];
  const commands = {
    capabilities: { sessionCommands: { enabled: true } },
    submit: async (input) => {
      submitted.push(input);
      return {
        code: 202,
        body: { commandId: input.commandId, status: "submitted" },
      };
    },
  };
  const { url } = await fixture(t, { commands });
  const command = {
    commandId: "ui-" + "b".repeat(32),
    sessionId: "s1",
    workerId: "w1",
    generation: 3,
    operation: "input",
    text: "private synthetic input",
  };
  const send = (headers, input = command) =>
    fetch(`${url}/api/commands`, {
      method: "POST",
      headers: { "content-type": "application/json", ...headers },
      body: JSON.stringify(input),
    });
  assert.equal((await send({ origin: url })).status, 401);
  const cookie = await login(url);
  assert.equal((await send({ cookie })).status, 403);
  assert.equal(
    (await send({ cookie, origin: "https://elsewhere.example" })).status,
    403,
  );
  assert.deepEqual(
    await (
      await fetch(`${url}/api/capabilities`, { headers: { cookie } })
    ).json(),
    commands.capabilities,
  );
  const accepted = await send({ cookie, origin: url });
  assert.equal(accepted.status, 202);
  assert.equal((await accepted.json()).status, "submitted");
  assert.deepEqual(submitted, [command]);
  assert.equal(
    (
      await send(
        { cookie, origin: url },
        { ...command, text: "x".repeat(131073) },
      )
    ).status,
    400,
  );
  assert.equal(submitted.length, 1);
});

test("cross-origin login/stream and arbitrary Host requests are rejected", async (t) => {
  const { url } = await fixture(t);
  assert.equal(
    (
      await fetch(`${url}/api/session`, {
        method: "POST",
        headers: {
          origin: "https://elsewhere.example",
          "content-type": "application/json",
        },
        body: JSON.stringify({ token: fixtureCredential }),
      })
    ).status,
    403,
  );
  const cookie = await login(url);
  assert.equal(
    (
      await fetch(`${url}/api/events`, {
        headers: { origin: "https://elsewhere.example", cookie },
      })
    ).status,
    403,
  );
  const status = await new Promise((resolve, reject) => {
    get(
      `${url}/api/snapshot`,
      { headers: { host: "elsewhere.example", cookie } },
      (response) => {
        response.resume();
        resolve(response.statusCode);
      },
    ).on("error", reject);
  });
  assert.equal(status, 403);
});

test("SSE sends an authenticated snapshot with a replay cursor and visible restart gap", async (t) => {
  const { url } = await fixture(t);
  const cookie = await login(url);
  const abort = new AbortController();
  t.after(() => abort.abort());
  const response = await fetch(`${url}/api/events?after=old-epoch:9`, {
    headers: { cookie },
    signal: abort.signal,
  });
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type"), /text\/event-stream/);
  const reader = response.body.getReader();
  const first = new TextDecoder().decode((await reader.read()).value);
  assert.match(first, /event: snapshot/);
  assert.match(first, /"gap":true/);
  assert.match(first, /id: /);
  await reader.cancel();
});

test("invalid login and unrelated mutations fail without proxying work", async (t) => {
  const { url } = await fixture(t);
  assert.equal(
    (
      await fetch(`${url}/api/session`, {
        method: "POST",
        headers: { origin: url, "content-type": "application/json" },
        body: '{"token":"wrong"}',
      })
    ).status,
    401,
  );
  const cookie = await login(url);
  assert.equal(
    (
      await fetch(`${url}/api/anything`, {
        method: "POST",
        headers: { origin: url, cookie },
      })
    ).status,
    404,
  );
});
