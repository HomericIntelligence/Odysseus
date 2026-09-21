import { constants } from "node:fs";
import * as fs from "node:fs/promises";
import { resolve, sep } from "node:path";
import { privateDirectory } from "./private-storage.mjs";
import { parseIssueImportJson } from "./research-imports.mjs";
import { validateObservationHistory } from "./view.mjs";

const schema = "hi/odysseus/observation-history/v1";
const MAX_BYTES = 4 * 1024 * 1024;
const limits = {
  observations: 250,
  identities: 1000,
  sources: 1000,
  bytes: MAX_BYTES,
};
const keysMatch = (item, keys) =>
  item &&
  typeof item === "object" &&
  !Array.isArray(item) &&
  Object.keys(item).length === keys.length &&
  keys.every((key) => Object.hasOwn(item, key));
const saturated = (value) => Math.min(Number.MAX_SAFE_INTEGER, value + 1);

function encode(history, persistedAt, maxBytes) {
  const data = validateObservationHistory(history);
  let omitted = 0;
  for (;;) {
    const bytes = Buffer.from(
      JSON.stringify({ schema, data, persistedAt, limits }),
    );
    if (bytes.length <= maxBytes) return { bytes, data, omitted };
    if (data.observations.length) {
      data.observations.shift();
      data.dropped = saturated(data.dropped);
    } else if (data.seen.length) {
      data.seen.shift();
      data.coverageLosses = saturated(data.coverageLosses);
    } else if (data.sourceSequences.length) {
      data.sourceSequences.shift();
      data.coverageLosses = saturated(data.coverageLosses);
    } else throw new Error("History metadata exceeds the byte limit");
    omitted++;
  }
}

function decode(raw) {
  const value = parseIssueImportJson(
    new TextDecoder("utf-8", { fatal: true }).decode(raw),
  );
  if (
    !keysMatch(value, ["schema", "data", "persistedAt", "limits"]) ||
    value.schema !== schema ||
    !keysMatch(value.limits, Object.keys(limits)) ||
    Object.keys(limits).some((key) => value.limits[key] !== limits[key]) ||
    typeof value.persistedAt !== "string" ||
    !Number.isFinite(Date.parse(value.persistedAt)) ||
    new Date(value.persistedAt).toISOString() !== value.persistedAt
  )
    throw new Error("Unsupported observation history");
  return { ...value, data: validateObservationHistory(value.data) };
}

function safeFile(info) {
  if (
    !info.isFile() ||
    info.uid !== process.getuid() ||
    info.mode & 0o077 ||
    info.nlink !== 1
  )
    throw new Error("Unsafe history file");
}

// The listener for this port is the sole writer lease. No work authority is stored here.
export async function openObservationHistory({
  view,
  directory,
  port,
  sourceRoot,
  io = fs,
  now = Date.now,
  maxBytes = MAX_BYTES,
  coalesceMs = 1000,
}) {
  if (!directory) return { close: async () => true };
  if (
    !Number.isInteger(port) ||
    port < 1 ||
    port > 65535 ||
    !Number.isInteger(maxBytes) ||
    maxBytes < 512 ||
    maxBytes > MAX_BYTES ||
    !Number.isInteger(coalesceMs) ||
    coalesceMs < 0 ||
    coalesceMs > 1000
  )
    throw new Error("Invalid observation history configuration");
  view.history = { status: "initializing", restartGap: true, pending: false };
  let writable = false;
  let closed = false;
  let timer;
  let active;
  let pending;
  let dir;
  let directoryInfo;
  let committed;
  let committedInfo;
  let temporary;
  const unavailable = (reason) => {
    writable = false;
    view.history = { ...view.history, status: "unavailable", reason };
  };
  const verifyDirectory = async () => {
    if ((await privateDirectory(directory)) !== dir)
      throw new Error("History directory changed");
    const current = await io.lstat(dir);
    if (current.dev !== directoryInfo.dev || current.ino !== directoryInfo.ino)
      throw new Error("History directory replaced");
  };
  const sameVersion = (left, right) =>
    ["dev", "ino", "size", "mtimeMs", "ctimeMs"].every(
      (key) => left[key] === right[key],
    );
  const verifyCommitted = async () => {
    let current;
    try {
      current = await io.lstat(committed);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    if (!current && !committedInfo) return;
    if (!current || !committedInfo) throw new Error("History member changed");
    safeFile(current);
    if (!sameVersion(current, committedInfo))
      throw new Error("History member replaced");
  };
  try {
    dir = await privateDirectory(directory);
    const source = await io.realpath(sourceRoot);
    if (
      dir === source ||
      dir.startsWith(source + sep) ||
      source.startsWith(dir + sep)
    )
      throw new Error("History directory overlaps source");
    directoryInfo = await io.lstat(dir);
    committed = resolve(dir, `observations-${port}.json`);
    temporary = committed + ".tmp";
    let hasTemporary = false;
    try {
      await io.lstat(temporary);
      hasTemporary = true;
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    let handle;
    try {
      handle = await io.open(
        committed,
        constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
      );
      const before = await handle.stat();
      safeFile(before);
      if (before.size > maxBytes) throw new Error("History is oversized");
      const buffer = Buffer.alloc(maxBytes + 1);
      let length = 0;
      while (length < buffer.length) {
        const read = await handle.read(
          buffer,
          length,
          buffer.length - length,
          length,
        );
        if (!read.bytesRead) break;
        length += read.bytesRead;
      }
      const after = await handle.stat();
      safeFile(after);
      if (
        length > maxBytes ||
        length !== before.size ||
        after.size !== before.size ||
        after.mtimeMs !== before.mtimeMs ||
        after.ctimeMs !== before.ctimeMs
      )
        throw new Error("History changed during read");
      const cached = decode(buffer.subarray(0, length));
      committedInfo = after;
      await verifyCommitted();
      view.restoreHistory(cached.data);
      view.history = {
        ...view.history,
        status: "restored",
        persistedSequence: cached.data.sequence,
        persistedAt: cached.persistedAt,
        retained: cached.data.observations.length,
      };
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
      view.history.status = "new_archive";
    } finally {
      await handle?.close();
    }
    writable = !hasTemporary;
    if (hasTemporary) unavailable("recovery_required");
  } catch {
    unavailable("invalid_or_unreadable_archive");
  }

  const write = async (snapshot) => {
    let handle;
    let directoryHandle;
    let replaced = false;
    try {
      await verifyDirectory();
      await verifyCommitted();
      const persistedAt = new Date(now()).toISOString();
      const encoded = encode(snapshot, persistedAt, maxBytes);
      if (closed) return;
      handle = await io.open(
        temporary,
        constants.O_WRONLY |
          constants.O_CREAT |
          constants.O_EXCL |
          constants.O_NOFOLLOW,
        0o600,
      );
      if (closed) return;
      await handle.writeFile(encoded.bytes);
      if (closed) return;
      await handle.sync();
      if (closed) return;
      const writtenInfo = await handle.stat();
      safeFile(writtenInfo);
      await handle.close();
      handle = undefined;
      await verifyDirectory();
      await verifyCommitted();
      if (closed) return;
      const temporaryInfo = await io.lstat(temporary);
      safeFile(temporaryInfo);
      if (!sameVersion(temporaryInfo, writtenInfo))
        throw new Error("Temporary history member changed");
      if (closed) return;
      await io.rename(temporary, committed);
      replaced = true;
      if (closed) return;
      directoryHandle = await io.open(
        dir,
        constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW,
      );
      if (closed) return;
      await directoryHandle.sync();
      if (closed) return;
      committedInfo = await io.lstat(committed);
      safeFile(committedInfo);
      // Rename may change ctime, but confirmation still belongs to the file we wrote.
      if (
        !["dev", "ino", "size", "mtimeMs"].every(
          (key) => committedInfo[key] === writtenInfo[key],
        )
      )
        throw new Error("Committed history member changed before confirmation");
      if (closed) return;
      view.history = {
        ...view.history,
        status: "persisted",
        persistedAt,
        persistedSequence: snapshot.sequence,
        retained: encoded.data.observations.length,
        omitted: encoded.omitted,
        pending: Boolean(pending),
      };
    } catch {
      if (!closed)
        unavailable(replaced ? "directory_sync_uncertain" : "write_failed");
    } finally {
      await handle?.close().catch(() => {});
      await directoryHandle?.close().catch(() => {});
    }
  };
  const pump = () => {
    if (!writable || closed || active || !pending) return;
    const snapshot = pending;
    pending = undefined;
    active = write(snapshot).finally(() => {
      active = undefined;
      if (writable && !closed) view.history.pending = Boolean(pending);
      pump();
    });
  };
  view.onHistoryChange = () => {
    if (!writable || closed) return;
    pending = view.exportHistory();
    view.history.pending = true;
    if (!timer && !active)
      timer = setTimeout(() => {
        timer = undefined;
        pump();
      }, coalesceMs);
  };
  return {
    async close(timeoutMs = 5000) {
      view.onHistoryChange = undefined;
      clearTimeout(timer);
      timer = undefined;
      let deadlineTimer;
      const deadline = new Promise((resolve) => {
        deadlineTimer = setTimeout(() => {
          closed = true;
          unavailable("shutdown_flush_uncertain");
          resolve(false);
        }, timeoutMs);
      });
      const flush = async () => {
        pump();
        while (active) await active;
        return !pending && writable;
      };
      const completed = await Promise.race([flush(), deadline]);
      clearTimeout(deadlineTimer);
      closed = true;
      return completed;
    },
  };
}
