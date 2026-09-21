import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { FleetView } from "./view.mjs";
import { createDashboardServer } from "./http.mjs";
import { createCommandService } from "./commands.mjs";
import { createSessionOutputService } from "./session-output.mjs";
import { pollProjects } from "./projects.mjs";
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
server.listen(port, "127.0.0.1", () =>
  console.log(`Odysseus Fleet: http://127.0.0.1:${port}`),
);
let closing = false;
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
const nats = await connectObservations({
  view,
  url: process.env.ODYSSEUS_NATS_URL,
  credsFile: process.env.ODYSSEUS_NATS_CREDS_FILE,
  caFile: process.env.ODYSSEUS_NATS_CA_FILE,
  allowLocal: process.env.ODYSSEUS_NATS_ALLOW_LOCAL === "1",
});
const shutdown = async () => {
  closing = true;
  await nats?.close();
  server.closeAllConnections();
  server.close();
};
process.once("SIGINT", shutdown);
process.once("SIGTERM", shutdown);
