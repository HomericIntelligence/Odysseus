import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { lstat, open, realpath } from "node:fs/promises";
import { hostname } from "node:os";
import { dirname, isAbsolute, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { privateDirectoryOutsideWorkspaces } from "./private-storage.mjs";
import { parseIssueImportJson } from "./research-imports.mjs";
import { componentEndpoint, readComponentJson } from "./upstream.mjs";

const maximum = 2 * 1024 * 1024;
const identifier = /^[A-Za-z0-9_-]{1,128}$/;
const hostIdentifier = /^[A-Za-z0-9_.-]{1,255}$/;
const digestPattern = /^[0-9a-f]{64}$/;
const identityFields = [
  "workerId",
  "generation",
  "allocationId",
  "sessionId",
  "executionId",
  "taskId",
  "agentId",
  "providerThreadId",
];
const currentStates = new Set([
  "admitted",
  "running",
  "idle",
  "waiting",
  "draining",
  "cancelling",
  "interrupting",
]);
const allStates = new Set([
  "created",
  ...currentStates,
  "cancelled",
  "interrupted",
  "completed",
  "failed",
]);
const object = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const exact = (value, fields) =>
  object(value) &&
  Object.keys(value).length === fields.length &&
  fields.every((field) => Object.hasOwn(value, field));
const nonnegative = (value) => Number.isSafeInteger(value) && value >= 0;
const text = (value, limit, nonempty = false) =>
  typeof value === "string" &&
  value.isWellFormed() &&
  (!nonempty || value.length > 0) &&
  Buffer.byteLength(value) <= limit;
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const canonical = (value) =>
  JSON.stringify(value, (_, entry) =>
    object(entry)
      ? Object.fromEntries(
          Object.entries(entry).sort(([left], [right]) =>
            left < right ? -1 : left > right ? 1 : 0,
          ),
        )
      : entry,
  );
const validIdentity = (value) =>
  exact(value, identityFields) &&
  identityFields.every((field) =>
    field === "generation"
      ? Number.isSafeInteger(value[field]) && value[field] >= 1
      : text(value[field], 1024, true),
  ) &&
  identifier.test(value.workerId) &&
  identifier.test(value.sessionId);
const sameIdentity = (left, right) =>
  identityFields.every((field) => left[field] === right[field]);
const failure = (code, error, extra = {}) => ({
  code,
  body: { error, ...extra },
});
class BuildWorkspaceUnavailable extends Error {}

function validOutput(output) {
  if (
    !exact(output, [
      "kind",
      "text",
      "byteCount",
      "sha256",
      "providerTruncated",
      "captureTruncated",
    ]) ||
    output.kind !== "provider_aggregate" ||
    output.providerTruncated !== null ||
    typeof output.captureTruncated !== "boolean"
  )
    return false;
  if (output.text === null)
    return (
      output.byteCount === null &&
      output.sha256 === null &&
      !output.captureTruncated
    );
  return (
    text(output.text, 65536) &&
    output.byteCount === Buffer.byteLength(output.text) &&
    output.sha256 === digest(output.text)
  );
}

function validateBundle(bundle, expected) {
  if (
    !exact(bundle, ["schema", "identity", "provider", "capture", "items"]) ||
    bundle.schema !== "hi/fleet/session-output/v1" ||
    !validIdentity(bundle.identity) ||
    !sameIdentity(bundle.identity, expected) ||
    !exact(bundle.provider, ["name", "version"]) ||
    bundle.provider.name !== "codex" ||
    bundle.provider.version !== "0.153.4" ||
    !exact(bundle.capture, [
      "profile",
      "complete",
      "observedCompletedItems",
      "retainedItems",
      "omittedItems",
      "retentionLimited",
    ]) ||
    !Array.isArray(bundle.items) ||
    bundle.items.length > 64
  )
    throw new Error("Invalid retained output bundle");
  const capture = bundle.capture;
  if (
    capture.profile !== "completed_command_items" ||
    capture.complete !== false ||
    ![
      capture.observedCompletedItems,
      capture.retainedItems,
      capture.omittedItems,
    ].every(nonnegative) ||
    capture.observedCompletedItems > 4096 ||
    capture.retainedItems !== bundle.items.length ||
    capture.observedCompletedItems !==
      capture.retainedItems + capture.omittedItems ||
    typeof capture.retentionLimited !== "boolean"
  )
    throw new Error("Invalid capture scope");
  const identities = new Set();
  let recordBytes = 0;
  for (const entry of bundle.items) {
    if (
      !exact(entry, [
        "turnId",
        "itemId",
        "completedAtMs",
        "command",
        "cwd",
        "status",
        "exitCode",
        "durationMs",
        "output",
        "recordDigest",
      ]) ||
      !text(entry.turnId, 1024, true) ||
      !text(entry.itemId, 1024, true) ||
      !nonnegative(entry.completedAtMs) ||
      !text(entry.command, 16384) ||
      !text(entry.cwd, 4096) ||
      !["completed", "failed", "declined"].includes(entry.status) ||
      !(
        entry.exitCode === null ||
        (Number.isInteger(entry.exitCode) &&
          entry.exitCode >= -2147483648 &&
          entry.exitCode <= 2147483647)
      ) ||
      !(entry.durationMs === null || nonnegative(entry.durationMs)) ||
      !validOutput(entry.output)
    )
      throw new Error("Invalid retained command item");
    const key = JSON.stringify([entry.turnId, entry.itemId]);
    if (identities.has(key)) throw new Error("Duplicate command item");
    identities.add(key);
    const { recordDigest, ...item } = entry;
    if (recordDigest !== digest(canonical({ identity: bundle.identity, item })))
      throw new Error("Command item digest mismatch");
    recordBytes += Buffer.byteLength(canonical(entry));
    if (recordBytes > 1024 * 1024)
      throw new Error("Retained records exceed limit");
  }
  if (
    capture.retentionLimited !==
    (capture.omittedItems > 0 ||
      bundle.items.some((entry) => entry.output.captureTruncated))
  )
    throw new Error("Invalid retention limit scope");
  return bundle;
}

async function loadBundle(config, workspaces) {
  await privateDirectoryOutsideWorkspaces(dirname(config.path), workspaces);
  if ((await realpath(config.path)) !== config.path)
    throw new Error("Noncanonical output path");
  const file = await open(
    config.path,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  try {
    const before = await file.stat({ bigint: true });
    if (
      !before.isFile() ||
      before.nlink !== 1n ||
      before.uid !== BigInt(process.getuid()) ||
      before.mode & 0o077n ||
      before.size > BigInt(maximum)
    )
      throw new Error("Unsafe retained output file");
    const bytes = Buffer.alloc(maximum + 1);
    let size = 0;
    while (size < bytes.length) {
      const read = await file.read(bytes, size, bytes.length - size, null);
      if (!read.bytesRead) break;
      size += read.bytesRead;
    }
    const after = await file.stat({ bigint: true });
    const linked = await lstat(config.path, { bigint: true });
    const unchanged = [
      "dev",
      "ino",
      "size",
      "uid",
      "mode",
      "nlink",
      "mtimeNs",
      "ctimeNs",
    ];
    if (
      size > maximum ||
      BigInt(size) !== before.size ||
      unchanged.some(
        (key) => before[key] !== after[key] || after[key] !== linked[key],
      )
    )
      throw new Error("Retained output file changed");
    const retained = bytes.subarray(0, size);
    if (digest(retained) !== config.receiptDigest)
      throw new Error("Retained output receipt mismatch");
    const decoded = new TextDecoder("utf-8", {
      fatal: true,
      ignoreBOM: true,
    }).decode(retained);
    return validateBundle(parseIssueImportJson(decoded), config.identity);
  } finally {
    await file.close();
  }
}

export function createSessionOutputService({
  url,
  apiKey,
  bundles = [],
  executionHost = hostname(),
  fetchImpl = fetch,
} = {}) {
  const base = url && apiKey ? componentEndpoint(url) : null;
  if (typeof executionHost !== "string" || !hostIdentifier.test(executionHost))
    throw new Error("Execution host must identify this backend host");
  if (!Array.isArray(bundles))
    throw new Error("Session output bundles must be an array");
  const registrations = new Map();
  const scopeKey = (scope) =>
    JSON.stringify([scope.sessionId, scope.workerId, scope.generation]);
  for (const entry of bundles) {
    if (
      !exact(entry, ["path", "receiptDigest", "identity"]) ||
      typeof entry.path !== "string" ||
      !isAbsolute(entry.path) ||
      resolve(entry.path) !== entry.path ||
      !digestPattern.test(entry.receiptDigest) ||
      !validIdentity(entry.identity) ||
      registrations.has(scopeKey(entry.identity))
    )
      throw new Error("Invalid session output registration");
    registrations.set(scopeKey(entry.identity), structuredClone(entry));
  }
  const cached = new Map();
  const headers = {
    Authorization: `Bearer ${apiKey}`,
    Accept: "application/json",
  };
  const get = (path, deadline) =>
    fetchImpl(new URL(path, base), {
      method: "GET",
      headers,
      redirect: "error",
      signal: AbortSignal.any([deadline, AbortSignal.timeout(4000)]),
    });
  const protectedWorkspaces = async (deadline) => {
    // This imported-file reader never attaches to a remote worker. The backend's
    // own source tree is always protected, even with a complete empty local fleet.
    const roots = new Set([
      await realpath(fileURLToPath(new URL("../..", import.meta.url))),
    ]);
    for (const kind of ["sessions", "executions", "build-jobs"]) {
      const inventory = await readComponentJson(
        await get(`/v1/fleet/${kind}`, deadline),
      );
      if (
        !Array.isArray(inventory?.items) ||
        !Number.isSafeInteger(inventory.total) ||
        inventory.total !== inventory.items.length
      )
        throw new Error("Protected workspace inventory is incomplete");
      const identities = new Set();
      for (const record of inventory.items) {
        if (kind === "build-jobs" && record && Object.hasOwn(record, "build"))
          throw new BuildWorkspaceUnavailable();
        if (
          !record ||
          typeof record.id !== "string" ||
          !identifier.test(record.id) ||
          identities.has(record.id) ||
          typeof record.workerId !== "string" ||
          !identifier.test(record.workerId) ||
          typeof record.host !== "string" ||
          !hostIdentifier.test(record.host) ||
          typeof record.workspace !== "string" ||
          !isAbsolute(record.workspace)
        )
          throw new Error("Protected workspace identity is unavailable");
        identities.add(record.id);
        if (record.host === executionHost) roots.add(record.workspace);
      }
    }
    return [...roots];
  };
  return {
    async read(input) {
      if (
        !exact(input, ["sessionId", "workerId", "generation"]) ||
        typeof input.sessionId !== "string" ||
        !identifier.test(input.sessionId) ||
        typeof input.workerId !== "string" ||
        !identifier.test(input.workerId) ||
        !Number.isSafeInteger(input.generation) ||
        input.generation < 1
      )
        return failure(400, "invalid_scope");
      if (!base || registrations.size === 0)
        return failure(503, "not_configured");
      const key = scopeKey(input);
      const config = registrations.get(key);
      if (!config) return failure(404, "not_registered");
      try {
        const deadline = AbortSignal.timeout(10000);
        const workspaces = await protectedWorkspaces(deadline);
        // Recheck separation on every read, including cached imports: retained
        // workspaces from other workers must not become an output attachment.
        await privateDirectoryOutsideWorkspaces(
          dirname(config.path),
          workspaces,
        );
        if (!cached.has(key))
          cached.set(key, await loadBundle(config, workspaces));
        deadline.throwIfAborted();
        const response = await get(
          `/v1/fleet/sessions/${input.sessionId}`,
          deadline,
        );
        let ownership = "historical";
        if (response.status !== 404) {
          const owner = await readComponentJson(response);
          if (
            !object(owner) ||
            owner.schema !== "hi/fleet/v1" ||
            owner.kind !== "sessions" ||
            owner.id !== input.sessionId ||
            owner.sessionId !== owner.id ||
            !Number.isSafeInteger(owner.generation) ||
            owner.generation < 1 ||
            !["workerId", "agentId", "executionId"].every((field) =>
              text(owner[field], 1024, true),
            ) ||
            !Object.hasOwn(owner, "allocationId") ||
            !["allocationId", "taskId", "providerThreadId"].every(
              (field) => owner[field] == null || text(owner[field], 1024, true),
            ) ||
            !allStates.has(owner.status) ||
            !["unclaimed", "reserved", "claimed", "released"].includes(
              owner.claimStatus,
            )
          )
            throw new Error("Invalid canonical session");
          if (
            sameIdentity(owner, config.identity) &&
            currentStates.has(owner.status) &&
            ["reserved", "claimed"].includes(owner.claimStatus)
          )
            ownership = "current";
        }
        deadline.throwIfAborted();
        return {
          code: 200,
          body: {
            ...input,
            receiptDigest: config.receiptDigest,
            ownership,
            bundle: structuredClone(cached.get(key)),
          },
        };
      } catch (error) {
        return failure(
          503,
          "unavailable",
          error instanceof BuildWorkspaceUnavailable
            ? { reason: "build_workspace_unresolved" }
            : {},
        );
      }
    },
  };
}
