import { createServer } from "node:http";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve, sep } from "node:path";

const hash = (value) => createHash("sha256").update(value).digest();
const equal = (left, right) =>
  typeof left === "string" && timingSafeEqual(hash(left), hash(right));
const json = (response, status, data) => {
  response.writeHead(status, {
    "content-type": "application/json",
    "cache-control": "no-store",
  });
  response.end(JSON.stringify(data));
};
async function body(request, limit = 4096) {
  if (!request.headers["content-type"]?.startsWith("application/json"))
    throw new Error("Expected JSON");
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > limit) throw new Error("Body too large");
    chunks.push(chunk);
  }
  return JSON.parse(
    new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks)),
  );
}

export function createDashboardServer({
  view,
  token,
  staticDir,
  sessionTtlMs = 1800000,
  commands,
} = {}) {
  if (!view || !token)
    throw new Error("View and private UI token are required");
  const sessions = new Map();
  let streams = 0;
  let pendingCommands = 0;
  const server = createServer(async (request, response) => {
    response.setHeader("x-content-type-options", "nosniff");
    response.setHeader("referrer-policy", "no-referrer");
    response.setHeader(
      "content-security-policy",
      "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
    );
    const port = server.address()?.port;
    const host = request.headers.host;
    const allowedHosts = [`127.0.0.1:${port}`, `localhost:${port}`];
    const origin = request.headers.origin;
    if (
      !allowedHosts.includes(host) ||
      (origin && origin !== `http://${host}`) ||
      request.headers["sec-fetch-site"] === "cross-site"
    )
      return json(response, 403, { error: "Forbidden origin" });
    let url;
    try {
      url = new URL(request.url, `http://${host}`);
    } catch {
      return json(response, 400, { error: "Invalid request target" });
    }
    for (const [key, expiry] of sessions)
      if (expiry <= Date.now()) sessions.delete(key);
    const cookie = request.headers.cookie
      ?.split(";")
      .map((part) => part.trim())
      .find((part) => part.startsWith("odysseus_session="))
      ?.slice(17);
    if (url.pathname === "/api/session" && request.method === "POST") {
      if (!origin) return json(response, 403, { error: "Origin required" });
      try {
        const input = await body(request);
        if (!equal(input.token, token))
          return json(response, 401, { error: "Invalid access token" });
        const session = randomBytes(32).toString("base64url");
        if (sessions.size >= 8) sessions.delete(sessions.keys().next().value);
        sessions.set(session, Date.now() + sessionTtlMs);
        response.setHeader(
          "set-cookie",
          `odysseus_session=${session}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${Math.floor(sessionTtlMs / 1000)}`,
        );
        return json(response, 200, { authenticated: true });
      } catch {
        return json(response, 400, { error: "Invalid login request" });
      }
    }
    if (url.pathname.startsWith("/api/")) {
      if (!sessions.has(cookie))
        return json(response, 401, { error: "Local sign-in required" });
      if (request.method === "GET" && url.pathname === "/api/capabilities")
        return json(
          response,
          200,
          commands?.capabilities ?? {
            sessionCommands: {
              enabled: false,
              operations: [],
              inputWorkerIds: [],
            },
          },
        );
      if (request.method === "POST" && url.pathname === "/api/commands") {
        if (!origin) return json(response, 403, { error: "Origin required" });
        if (!commands) return json(response, 503, { error: "not_configured" });
        if (pendingCommands >= 4)
          return json(response, 429, {
            error: "busy",
            outcome: "not_submitted",
          });
        pendingCommands++;
        try {
          const input = await body(request, 128 * 1024);
          const result = await commands.submit(input);
          return json(response, result.code, result.body);
        } catch {
          return json(response, 400, { error: "invalid_request" });
        } finally {
          pendingCommands--;
        }
      }
      if (request.method === "GET" && url.pathname === "/api/snapshot")
        return json(
          response,
          200,
          view.snapshot(url.searchParams.get("after")),
        );
      if (request.method === "GET" && url.pathname === "/api/events") {
        if (streams >= 8)
          return json(response, 429, { error: "Too many live views" });
        streams++;
        response.writeHead(200, {
          "content-type": "text/event-stream",
          "cache-control": "no-store",
          connection: "keep-alive",
        });
        let cursor =
          request.headers["last-event-id"] ?? url.searchParams.get("after");
        const send = () => {
          if (
            !sessions.has(cookie) ||
            sessions.get(cookie) <= Date.now() ||
            response.writableLength > 262144
          ) {
            response.end();
            return;
          }
          if (response.writableNeedDrain) return;
          const snapshot = view.snapshot(cursor);
          cursor = snapshot.cursor;
          response.write(
            `id: ${cursor}\nevent: snapshot\ndata: ${JSON.stringify(snapshot)}\n\n`,
          );
        };
        send();
        const timer = setInterval(send, 1000);
        timer.unref();
        response.once("close", () => {
          clearInterval(timer);
          streams--;
        });
        return;
      }
      return json(response, 404, { error: "Unknown API operation" });
    }
    if (request.method !== "GET" || !staticDir)
      return json(response, 404, { error: "Not found" });
    const relative =
      url.pathname === "/" ? "index.html" : url.pathname.slice(1);
    const root = resolve(staticDir);
    const path = resolve(root, relative);
    if (
      !path.startsWith(root + sep) ||
      (!relative.startsWith("assets/") && relative !== "index.html")
    )
      return json(response, 404, { error: "Not found" });
    try {
      const contents = await readFile(path);
      const contentType = path.endsWith(".js")
        ? "text/javascript"
        : path.endsWith(".css")
          ? "text/css"
          : "text/html";
      response.writeHead(200, {
        "content-type": contentType,
        "cache-control": "no-store",
      });
      response.end(contents);
    } catch {
      json(response, 404, {
        error: "Web assets not built; run just web-build",
      });
    }
  });
  server.requestTimeout = 10000;
  server.headersTimeout = 10000;
  return server;
}
