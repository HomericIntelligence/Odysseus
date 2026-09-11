import { mkdir, readFile, writeFile, stat } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import { homedir } from "node:os";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { FleetView } from "./view.mjs";
import { createDashboardServer } from "./http.mjs";
import { createCommandService } from "./commands.mjs";
import { pollProjects } from "./projects.mjs";
import {
  attachObservationInput,
  connectObservations,
  pollFleet,
} from "./collector.mjs";

const stateDir =
  process.env.ODYSSEUS_WEB_STATE_DIR ??
  resolve(homedir(), ".local/state/odysseus-web");
await mkdir(stateDir, { recursive: true, mode: 0o700 });
let token = process.env.ODYSSEUS_WEB_TOKEN;
if (!token) {
  const path = resolve(stateDir, "access-token");
  try {
    await writeFile(path, randomBytes(32).toString("base64url"), {
      mode: 0o600,
      flag: "wx",
    });
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
  }
  const info = await stat(path);
  if ((info.mode & 0o077) !== 0 || info.uid !== process.getuid())
    throw new Error("Access token must be private and user-owned");
  token = (await readFile(path, "utf8")).trim();
  console.log(`Local sign-in token: ${path}`);
}
const view = new FleetView({ historyLimit: 250 });
const commands = createCommandService(
  process.env.ODYSSEUS_ENABLE_COMMANDS === "1"
    ? {
        url: process.env.ODYSSEUS_AGAMEMNON_URL,
        apiKey: process.env.AGAMEMNON_API_KEY,
        inputSpools: JSON.parse(process.env.ODYSSEUS_INPUT_SPOOLS ?? "{}"),
      }
    : {},
);
const server = createDashboardServer({
  view,
  token,
  commands,
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
