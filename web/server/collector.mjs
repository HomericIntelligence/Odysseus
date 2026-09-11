import { readFile } from "node:fs/promises";
import { connect, credsAuthenticator } from "@nats-io/transport-node";
import { RESOURCE_KINDS, validResourceCollection } from "./view.mjs";
import { componentEndpoint, readComponentJson } from "./upstream.mjs";

export async function pollFleet({ view, url, apiKey, fetchImpl = fetch }) {
  if (!url || !apiKey) {
    view.setSource("agamemnon", "not_configured");
    return false;
  }
  try {
    const base = componentEndpoint(url);
    const results = await Promise.all(
      RESOURCE_KINDS.map(async (kind) => {
        const response = await fetchImpl(new URL(`/v1/fleet/${kind}`, base), {
          headers: {
            Authorization: `Bearer ${apiKey}`,
            Accept: "application/json",
          },
          redirect: "error",
          signal: AbortSignal.timeout(4000),
        });
        const data = await readComponentJson(response);
        if (
          !validResourceCollection(data.items) ||
          !Number.isSafeInteger(data.total) ||
          data.total !== data.items.length ||
          data.total > 2000
        )
          throw new Error("Incomplete resource collection");
        return [kind, data.items];
      }),
    );
    for (const [kind, items] of results) view.setResources(kind, items);
    view.setSource("agamemnon", "connected");
    return true;
  } catch {
    // Never forward upstream error bodies or URLs containing private material.
    view.setSource("agamemnon", "unavailable");
    return false;
  }
}

export function attachObservationInput(view, input) {
  let buffer = "";
  let skipping = false;
  input.setEncoding("utf8");
  input.on("data", (chunk) => {
    for (const part of chunk.split(/(?<=\n)/)) {
      if (!skipping) buffer += part;
      if (buffer.length > 65536) {
        buffer = "";
        skipping = true;
        view.recordCoverageLoss("attachment", "oversized_frame");
      }
      if (!part.endsWith("\n")) continue;
      if (!skipping && buffer.trim()) {
        try {
          const frame = JSON.parse(buffer);
          if (frame.type === "observation")
            view.observe(frame.observation ?? frame);
        } catch {
          view.recordCoverageLoss("attachment", "invalid_frame");
        }
      }
      buffer = "";
      skipping = false;
    }
  });
  input.on("end", () => {
    if (buffer) view.recordCoverageLoss("attachment", "truncated_frame");
    else view.setSource("attachment", "disconnected");
  });
  input.on("error", () => view.setSource("attachment", "unavailable"));
  view.setSource("attachment", "connected");
}

export async function connectObservations({
  view,
  url,
  credsFile,
  caFile,
  allowLocal = false,
}) {
  if (!url) {
    view.setSource("keystone", "not_configured");
    return null;
  }
  try {
    const endpoint = new URL(url);
    const local = ["127.0.0.1", "[::1]"].includes(endpoint.hostname);
    if (
      endpoint.username ||
      endpoint.password ||
      ((!allowLocal || !local) && endpoint.protocol !== "tls:")
    )
      throw new Error("TLS observation attachment required");
    const connection = await connect({
      servers: url,
      name: "odysseus-flow-observer",
      timeout: 3000,
      maxReconnectAttempts: -1,
      ...(credsFile
        ? { authenticator: credsAuthenticator(await readFile(credsFile)) }
        : {}),
      ...(endpoint.protocol === "tls:"
        ? { tls: caFile ? { caFile } : {} }
        : {}),
    });
    view.setSource("keystone", "connected");
    connection.subscribe("hi.fleet.observations.>", {
      callback: (error, message) => {
        if (error) {
          view.setSource("keystone", "unavailable");
          return;
        }
        if (message.data.length > 65536) {
          view.recordCoverageLoss("keystone", "oversized_frame");
          return;
        }
        try {
          const input = message.json();
          view.observe(input.observation ?? input);
        } catch {
          view.recordCoverageLoss("keystone", "invalid_frame");
        }
      },
    });
    // This Core subscription observes telemetry only; it never binds a work consumer.
    void (async () => {
      for await (const status of connection.status()) {
        if (status.type === "disconnect" || status.type === "reconnecting")
          view.setSource("keystone", "reconnecting");
        if (status.type === "reconnect")
          view.setSource("keystone", "connected");
      }
    })();
    void connection
      .closed()
      .then(() => view.setSource("keystone", "disconnected"));
    return connection;
  } catch {
    view.setSource("keystone", "unavailable");
    return null;
  }
}
