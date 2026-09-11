import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { open, realpath } from "node:fs/promises";
import { resolve, sep } from "node:path";
import { privateDirectory } from "./private-storage.mjs";
import { createRequestReader, validateResponse } from "./requests.mjs";

const operations = [
  "start",
  "input",
  "respond",
  "interrupt",
  "cancel",
  "resume",
];
const id = /^[A-Za-z0-9_-]{1,128}$/;
const commandId = /^ui-[0-9a-f]{32}$/;
const maximum = 128 * 1024;
const result = (code, input, error, extra = {}) => ({
  code,
  body: {
    ...(commandId.test(input?.commandId) ? { commandId: input.commandId } : {}),
    ...(error ? { error } : {}),
    ...extra,
  },
});
class Conflict extends Error {}

function endpoint(url) {
  const base = new URL(url);
  if (
    base.username ||
    base.password ||
    base.search ||
    base.hash ||
    (base.protocol !== "https:" &&
      !(
        base.protocol === "http:" &&
        ["127.0.0.1", "localhost", "[::1]"].includes(base.hostname)
      ))
  )
    throw new Error("Invalid controller endpoint");
  return base;
}

async function verifyStoredInput(path, data) {
  const existing = await open(
    path,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  try {
    const before = await existing.stat();
    if (
      !before.isFile() ||
      before.nlink !== 1 ||
      before.uid !== process.getuid() ||
      before.mode & 0o077 ||
      before.size > maximum
    )
      throw new Error("Unsafe private input");
    const buffer = Buffer.alloc(maximum + 1);
    let size = 0;
    while (size < buffer.length) {
      const read = await existing.read(
        buffer,
        size,
        buffer.length - size,
        null,
      );
      if (!read.bytesRead) break;
      size += read.bytesRead;
    }
    const after = await existing.stat();
    if (
      before.size !== after.size ||
      before.mtimeMs !== after.mtimeMs ||
      size > maximum
    )
      throw new Error("Private input changed");
    if (!data.equals(buffer.subarray(0, size)))
      throw new Conflict("Input identity reused");
  } finally {
    await existing.close();
  }
}

async function storeInput(directory, input, workspace, existingOnly = false) {
  const spool = await privateDirectory(directory);
  if (typeof workspace !== "string" || !workspace.startsWith("/"))
    throw new Error("Current workspace is unavailable");
  const source = await realpath(workspace);
  if (
    source === spool ||
    source.startsWith(spool + sep) ||
    spool.startsWith(source + sep)
  )
    throw new Error("Private input must be separate from source workspaces");
  const reference =
    createHash("sha256").update(input.commandId).digest("hex").slice(0, 32) +
    ".json";
  const data = Buffer.from(
    JSON.stringify({
      schema: "hi/fleet/private-input/v1",
      commandId: input.commandId,
      workerId: input.workerId,
      generation: input.generation,
      sessionId: input.sessionId,
      ...(input.operation === "respond"
        ? {
            kind: "response",
            requestId: input.requestId,
            response: input.response,
          }
        : { kind: "input", text: input.text }),
    }),
  );
  if (data.length > maximum) throw new Error("Private input too large");
  const path = resolve(spool, reference);
  if (existingOnly) {
    await verifyStoredInput(path, data);
    return reference;
  }
  let file;
  try {
    file = await open(
      path,
      constants.O_WRONLY |
        constants.O_CREAT |
        constants.O_EXCL |
        constants.O_NOFOLLOW,
      0o600,
    );
    await file.writeFile(data);
    await file.sync();
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
    await verifyStoredInput(path, data);
  } finally {
    await file?.close();
  }
  const parent = await open(
    spool,
    constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW,
  );
  try {
    await parent.sync();
  } finally {
    await parent.close();
  }
  return reference;
}

async function boundedJson(response) {
  const chunks = [];
  let size = 0;
  for await (const chunk of response.body) {
    size += chunk.length;
    if (size > 262144) throw new Error("Controller response too large");
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

export function createCommandService({
  url,
  apiKey,
  inputSpools = {},
  workerStateDirs = {},
  requestReader = createRequestReader(workerStateDirs),
  fetchImpl = fetch,
} = {}) {
  const base = url && apiKey ? endpoint(url) : null;
  if (
    !inputSpools ||
    Array.isArray(inputSpools) ||
    typeof inputSpools !== "object" ||
    Object.entries(inputSpools).some(
      ([worker, path]) =>
        !id.test(worker) || typeof path !== "string" || !path.startsWith("/"),
    )
  )
    throw new Error(
      "Input spools must map worker IDs to private absolute directories",
    );
  const approvalWorkers = requestReader.workerIds.filter((worker) =>
    Object.hasOwn(inputSpools, worker),
  );
  const capabilities = {
    sessionCommands: {
      enabled: Boolean(base),
      operations: base
        ? operations.filter(
            (operation) => operation !== "respond" || approvalWorkers.length,
          )
        : [],
      inputWorkerIds: base ? Object.keys(inputSpools) : [],
      approvalWorkerIds: base ? approvalWorkers : [],
    },
  };
  const headers = {
    Authorization: `Bearer ${apiKey}`,
    Accept: "application/json",
    "Content-Type": "application/json",
  };
  const scopeValid = (input) =>
    input &&
    id.test(input.sessionId) &&
    id.test(input.workerId) &&
    Number.isSafeInteger(input.generation) &&
    input.generation >= 1;
  const fetchCurrent = async (input) => {
    const response = await fetchImpl(
      new URL(`/v1/fleet/sessions/${input.sessionId}`, base),
      {
        method: "GET",
        headers,
        redirect: "error",
        signal: AbortSignal.timeout(4000),
      },
    );
    if (response.status === 404) throw new Conflict("Missing session");
    if (!response.ok) throw new Error("Controller unavailable");
    const record = await boundedJson(response);
    if (
      record.id !== input.sessionId ||
      record.workerId !== input.workerId ||
      record.generation !== input.generation
    )
      throw new Conflict("Owner changed");
    return record;
  };
  const matchesCommand = (command, input, payload) =>
    command &&
    command.commandId === input.commandId &&
    command.idempotencyKey === input.commandId &&
    command.targetKind === "sessions" &&
    command.targetId === input.sessionId &&
    command.workerId === input.workerId &&
    command.generation === input.generation &&
    command.operation === input.operation &&
    command.payload &&
    typeof command.payload === "object" &&
    !Array.isArray(command.payload) &&
    Object.keys(command.payload).length === Object.keys(payload).length &&
    Object.entries(payload).every(
      ([key, value]) =>
        Object.hasOwn(command.payload, key) && command.payload[key] === value,
    );
  return {
    capabilities,
    async requests(input) {
      if (!base || !approvalWorkers.includes(input?.workerId))
        return result(503, input, "not_configured");
      if (
        !scopeValid(input) ||
        Object.keys(input).some(
          (key) => !["sessionId", "workerId", "generation"].includes(key),
        )
      )
        return result(400, input, "invalid_request");
      try {
        const record = await fetchCurrent(input);
        const requests = await requestReader.read(record);
        return result(200, input, null, { ...input, requests });
      } catch (error) {
        return result(
          error instanceof Conflict ? 409 : 503,
          input,
          error instanceof Conflict ? "conflict" : "unavailable",
        );
      }
    },
    async submit(input) {
      if (!base) return result(503, input, "not_configured");
      if (
        !input ||
        typeof input !== "object" ||
        Array.isArray(input) ||
        !commandId.test(input.commandId) ||
        !id.test(input.sessionId) ||
        !id.test(input.workerId) ||
        !Number.isSafeInteger(input.generation) ||
        input.generation < 1 ||
        !operations.includes(input.operation) ||
        Object.keys(input).some(
          (key) =>
            ![
              "commandId",
              "sessionId",
              "workerId",
              "generation",
              "operation",
              ...(input.operation === "input" ? ["text"] : []),
              ...(input.operation === "respond"
                ? ["requestId", "requestFingerprint", "response"]
                : []),
            ].includes(key),
        ) ||
        (input.operation === "input" &&
          (typeof input.text !== "string" ||
            !input.text.trim() ||
            Buffer.byteLength(JSON.stringify(input)) > maximum - 1024)) ||
        (input.operation === "respond" &&
          ((!Number.isSafeInteger(input.requestId) &&
            !(
              typeof input.requestId === "string" &&
              input.requestId.length > 0 &&
              input.requestId.length <= 256
            )) ||
            !/^[0-9a-f]{64}$/.test(input.requestFingerprint) ||
            !input.response ||
            typeof input.response !== "object" ||
            Array.isArray(input.response) ||
            Buffer.byteLength(JSON.stringify(input)) > maximum - 1024))
      )
        return result(400, input, "invalid_request");
      if (
        input.operation === "input" &&
        !Object.hasOwn(inputSpools, input.workerId)
      )
        return result(503, input, "not_configured");
      if (
        input.operation === "respond" &&
        !approvalWorkers.includes(input.workerId)
      )
        return result(503, input, "not_configured");
      let submitted = false;
      try {
        // UI snapshots are observational; refresh the actual owner before every mutation.
        const record = await fetchCurrent(input);
        let payload =
          input.operation === "input"
            ? {
                inputRef: await storeInput(
                  inputSpools[input.workerId],
                  input,
                  record.workspace,
                ),
              }
            : {};
        if (input.operation === "respond") {
          // An uncertain retry may outlive the private provider request. Only
          // the exact durable intent plus its retained private bytes can confirm it.
          const previous = await fetchImpl(
            new URL(`/v1/fleet/commands/${input.commandId}`, base),
            {
              method: "GET",
              headers,
              redirect: "error",
              signal: AbortSignal.timeout(4000),
            },
          );
          if (previous.ok) {
            const retained = await boundedJson(previous);
            payload = {
              responseRef: await storeInput(
                inputSpools[input.workerId],
                input,
                record.workspace,
                true,
              ),
              requestId: String(input.requestId),
            };
            if (!matchesCommand(retained.command, input, payload))
              throw new Conflict("Intent changed");
            return result(202, input, null, { status: "submitted" });
          }
          if (previous.status !== 404)
            throw new Error("Command history unavailable");
          const pending = (await requestReader.read(record)).find(
            (request) =>
              request.requestId === input.requestId &&
              request.fingerprint === input.requestFingerprint,
          );
          if (!pending) throw new Conflict("Request changed");
          try {
            validateResponse(pending, input.response);
          } catch {
            return result(400, input, "invalid_request");
          }
          payload = {
            responseRef: await storeInput(
              inputSpools[input.workerId],
              input,
              record.workspace,
            ),
            requestId: String(input.requestId),
          };
        }
        submitted = true;
        const response = await fetchImpl(
          new URL(
            `/v1/fleet/sessions/${input.sessionId}/${input.operation}`,
            base,
          ),
          {
            method: "POST",
            headers,
            redirect: "error",
            signal: AbortSignal.timeout(4000),
            body: JSON.stringify({
              commandId: input.commandId,
              idempotencyKey: input.commandId,
              generation: input.generation,
              payload,
            }),
          },
        );
        if (response.status === 409) return result(409, input, "conflict");
        if (response.status === 400)
          return result(400, input, "invalid_request");
        if (response.status !== 202)
          throw new Error("Command acceptance uncertain");
        const accepted = await boundedJson(response);
        const command = accepted.command;
        if (!matchesCommand(command, input, payload))
          throw new Error("Command confirmation mismatch");
        return result(202, input, null, { status: "submitted" });
      } catch (error) {
        if (error instanceof Conflict) return result(409, input, "conflict");
        // Keep response bodies, input, auth, and spool locations out of UI errors.
        return result(503, input, "unavailable", {
          outcome: submitted ? "unknown" : "not_submitted",
        });
      }
    },
  };
}
