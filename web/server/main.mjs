import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { FleetView } from "./view.mjs";
import { createDashboardServer } from "./http.mjs";
import { createCommandService } from "./commands.mjs";
import { createSessionOutputService } from "./session-output.mjs";
import { pollProjects } from "./projects.mjs";
import { openObservationHistory } from "./observation-history.mjs";
import {
  attachObservationInput,
  connectObservations,
  pollFleet,
} from "./collector.mjs";

const view = new FleetView({ historyLimit: 250 });
const commands = createCommandService(
  process.env.ODYSSEUS_ENABLE_COMMANDS === "1"
    ? {
        url: process.env.ODYSSEUS_AGAMEMNON_URL,
        apiKey: process.env.AGAMEMNON_API_KEY,
        executionHost: process.env.ODYSSEUS_EXECUTION_HOST,
        inputSpools: JSON.parse(process.env.ODYSSEUS_INPUT_SPOOLS ?? "{}"),
        workerStateDirs: JSON.parse(
          process.env.ODYSSEUS_WORKER_STATE_DIRS ?? "{}",
        ),
      }
    : {},
);
const server = createDashboardServer({
  view,
  commands,
  sessionOutput: createSessionOutputService({
    url: process.env.ODYSSEUS_AGAMEMNON_URL,
    apiKey: process.env.AGAMEMNON_API_KEY,
    executionHost: process.env.ODYSSEUS_EXECUTION_HOST,
    bundles: JSON.parse(process.env.ODYSSEUS_SESSION_OUTPUT_BUNDLES ?? "[]"),
  }),
  research:
    process.env.ODYSSEUS_ENABLE_RESEARCH_INTAKE === "1"
      ? {
          url: process.env.ODYSSEUS_NESTOR_URL,
          token: process.env.NESTOR_AUTH_TOKEN,
        }
      : undefined,
  researchImport:
    process.env.ODYSSEUS_ENABLE_RESEARCH_IMPORT === "1"
      ? {
          url: process.env.ODYSSEUS_AGAMEMNON_URL,
          apiKey: process.env.AGAMEMNON_API_KEY,
          observe: (event) => view.observe(event),
        }
      : undefined,
  issueImport:
    process.env.ODYSSEUS_ENABLE_ISSUE_IMPORT === "1"
      ? {
          url: process.env.ODYSSEUS_AGAMEMNON_URL,
          apiKey: process.env.AGAMEMNON_API_KEY,
          observe: (event) => view.observe(event),
        }
      : undefined,
  staticDir: resolve(dirname(fileURLToPath(import.meta.url)), "../dist"),
});
const port = Number(process.env.ODYSSEUS_WEB_PORT ?? 8765);
if (!Number.isInteger(port) || port < 1 || port > 65535)
  throw new Error("Invalid web port");
// Own the port before touching its cache. HTTP intake waits for complete restore.
let ready = false;
const requestHandler = server.listeners("request")[0];
server.removeListener("request", requestHandler);
server.on("request", (request, response) => {
  if (!ready) {
    response.writeHead(503, {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    });
    response.end(JSON.stringify({ error: "initializing" }));
    return;
  }
  requestHandler(request, response);
});
await new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(port, "127.0.0.1", resolve);
});
const history = await openObservationHistory({
  view,
  directory: process.env.ODYSSEUS_OBSERVATION_HISTORY_DIR,
  port,
  sourceRoot: resolve(dirname(fileURLToPath(import.meta.url)), "../.."),
});
let closing = false;
let nats;
const observationAbort = new AbortController();
const shutdown = async () => {
  if (closing) return;
  closing = true;
  ready = false;
  observationAbort.abort();
  process.stdin.pause();
  process.stdin.removeAllListeners("data");
  const closeNats = nats?.close();
  const flushed = await history.close(5000);
  if (!flushed)
    console.error("Observation history shutdown flush was not confirmed");
  // Retain the writer lease until the flush completes or fences late write phases.
  server.closeAllConnections();
  server.close();
  await closeNats;
};
process.once("SIGINT", shutdown);
process.once("SIGTERM", shutdown);
ready = true;
console.log(`Odysseus Fleet: http://127.0.0.1:${port}`);
const poll = async () => {
  await pollFleet({
    view,
    url: process.env.ODYSSEUS_AGAMEMNON_URL,
    apiKey: process.env.AGAMEMNON_API_KEY,
  });
  if (!closing) setTimeout(poll, 3000).unref();
};
void poll();
const pollProjectView = async () => {
  await pollProjects({
    view,
    url: process.env.ODYSSEUS_AGAMEMNON_URL,
    apiKey: process.env.AGAMEMNON_API_KEY,
  });
  if (!closing) setTimeout(pollProjectView, 30000).unref();
};
void pollProjectView();
if (process.argv.includes("--flow-stdin"))
  attachObservationInput(view, process.stdin);
nats = await connectObservations({
  view,
  url: process.env.ODYSSEUS_NATS_URL,
  credsFile: process.env.ODYSSEUS_NATS_CREDS_FILE,
  caFile: process.env.ODYSSEUS_NATS_CA_FILE,
  allowLocal: process.env.ODYSSEUS_NATS_ALLOW_LOCAL === "1",
  signal: observationAbort.signal,
});
