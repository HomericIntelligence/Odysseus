import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { open, lstat, realpath } from "node:fs/promises";
import { resolve, sep } from "node:path";
import { tmpdir } from "node:os";

const operations = ["start", "input", "interrupt", "cancel", "resume"];
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

async function privateDirectory(path) {
  const canonical = await realpath(path);
  // The pinned native provider grants access to shared system scratch paths.
  if (
    canonical !== resolve(path) ||
    [
      "/tmp",
      "/private/tmp",
      "/var/tmp",
      "/private/var/tmp",
      "/private/var/folders",
      await realpath(tmpdir()),
    ].some((root) => canonical === root || canonical.startsWith(root + sep))
  )
    throw new Error(
      "Private spool must be canonical and outside shared scratch",
    );
  const info = await lstat(canonical);
  if (
    !info.isDirectory() ||
    info.isSymbolicLink() ||
    info.uid !== process.getuid() ||
    info.mode & 0o077
  )
    throw new Error("Private spool must be an owner-only directory");
  return canonical;
}

async function storeInput(directory, input, workspace) {
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
      kind: "input",
      text: input.text,
    }),
  );
  if (data.length > maximum) throw new Error("Private input too large");
  const path = resolve(spool, reference);
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
  const capabilities = {
    sessionCommands: {
      enabled: Boolean(base),
      operations: base ? operations : [],
      inputWorkerIds: base ? Object.keys(inputSpools) : [],
    },
  };
  const headers = {
    Authorization: `Bearer ${apiKey}`,
    Accept: "application/json",
    "Content-Type": "application/json",
  };
  return {
    capabilities,
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
            ].includes(key),
        ) ||
        (input.operation === "input" &&
          (typeof input.text !== "string" ||
            !input.text.trim() ||
            Buffer.byteLength(JSON.stringify(input)) > maximum - 1024))
      )
        return result(400, input, "invalid_request");
      if (
        input.operation === "input" &&
        !Object.hasOwn(inputSpools, input.workerId)
      )
        return result(503, input, "not_configured");
      let submitted = false;
      try {
        // UI snapshots are observational; refresh the actual owner before every mutation.
        const current = await fetchImpl(
          new URL(`/v1/fleet/sessions/${input.sessionId}`, base),
          {
            method: "GET",
            headers,
            redirect: "error",
            signal: AbortSignal.timeout(4000),
          },
        );
        if (current.status === 404) return result(409, input, "conflict");
        if (!current.ok) throw new Error("Controller unavailable");
        const record = await boundedJson(current);
        if (
          record.id !== input.sessionId ||
          record.workerId !== input.workerId ||
          record.generation !== input.generation
        )
          return result(409, input, "conflict");
        const payload =
          input.operation === "input"
            ? {
                inputRef: await storeInput(
                  inputSpools[input.workerId],
                  input,
                  record.workspace,
                ),
              }
            : {};
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
        if (
          !command ||
          command.commandId !== input.commandId ||
          command.idempotencyKey !== input.commandId ||
          command.targetKind !== "sessions" ||
          command.targetId !== input.sessionId ||
          command.workerId !== input.workerId ||
          command.generation !== input.generation ||
          command.operation !== input.operation ||
          JSON.stringify(command.payload) !== JSON.stringify(payload)
        )
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
