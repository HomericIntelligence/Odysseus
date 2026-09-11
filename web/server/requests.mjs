import { createConnection } from "node:net";
import { createHash } from "node:crypto";
import { lstat } from "node:fs/promises";
import { resolve } from "node:path";
import { privateDirectoryOutsideWorkspaces } from "./private-storage.mjs";

const maximum = 1024 * 1024;
const methods = {
  "item/commandExecution/requestApproval": "command",
  "item/fileChange/requestApproval": "file",
  "item/tool/requestUserInput": "input",
};
const require = (value) => {
  if (!value) throw new Error("Private request unavailable");
};
const text = (value, limit = 16384) =>
  typeof value === "string" && value.length <= limit;
const requestId = (value) =>
  (text(value, 256) && value.length > 0) || Number.isSafeInteger(value);
const same = (left, right) => JSON.stringify(left) === JSON.stringify(right);
const canonical = (value) => {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object")
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonical(value[key])]),
    );
  return value;
};
export const requestFingerprint = (request) =>
  createHash("sha256")
    .update(JSON.stringify(canonical(request)))
    .digest("hex");

async function exchange(path, input, timeout = 3000) {
  const before = await lstat(path);
  require(
    before.isSocket() &&
      before.uid === process.getuid() &&
      !(before.mode & 0o077),
  );
  const reply = await new Promise((done, fail) => {
    const socket = createConnection({ path });
    const chunks = [];
    let size = 0;
    let finished = false;
    const end = (error, value) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      socket.destroy();
      if (error) fail(error);
      else done(value);
    };
    const timer = setTimeout(
      () => end(new Error("Private request timeout")),
      timeout,
    );
    socket.on("error", (error) => end(error));
    socket.on("end", () => end(new Error("Incomplete private response")));
    socket.on("connect", () => socket.write(JSON.stringify(input) + "\n"));
    socket.on("data", (chunk) => {
      size += chunk.length;
      if (size > maximum) return end(new Error("Private response limit"));
      chunks.push(chunk);
      const bytes = Buffer.concat(chunks);
      const newline = bytes.indexOf(10);
      if (newline < 0) return;
      try {
        require(newline === bytes.length - 1);
        const data = JSON.parse(
          new TextDecoder("utf-8", { fatal: true }).decode(
            bytes.subarray(0, newline),
          ),
        );
        require(data && typeof data === "object" && !Array.isArray(data));
        end(null, data);
      } catch (error) {
        end(error);
      }
    });
  });
  const after = await lstat(path);
  require(
    before.ino === after.ino &&
      before.dev === after.dev &&
      before.mode === after.mode &&
      before.uid === after.uid,
  );
  return reply;
}

function sessionFrom(inventory, record) {
  require(
    inventory.workerId === record.workerId &&
      inventory.generation === record.generation &&
      Array.isArray(inventory.sessions),
  );
  const matching = inventory.sessions.filter(
    (item) => item?.sessionId === record.id,
  );
  require(matching.length === 1);
  const session = matching[0];
  require(
    session.workerId === record.workerId &&
      session.generation === record.generation &&
      session.workspace === record.workspace &&
      !session.released &&
      session.admissionReserved === true &&
      !session.stopCommandId,
  );
  for (const key of ["agentId", "taskId", "executionId"])
    if (record[key] !== undefined) require(session[key] === record[key]);
  require(
    text(session.providerThreadId, 256) &&
      session.providerThreadId &&
      text(session.providerTurnId, 256) &&
      session.providerTurnId,
  );
  require(["waiting_approval", "waiting_input"].includes(session.activity));
  return session;
}

function project(pending, session) {
  require(
    pending &&
      requestId(pending.id) &&
      pending.sessionId === session.sessionId &&
      Object.hasOwn(methods, pending.method),
  );
  const params = pending.params;
  require(params && typeof params === "object" && !Array.isArray(params));
  require(
    params.threadId === session.providerThreadId &&
      params.turnId === session.providerTurnId &&
      text(params.itemId, 256) &&
      params.itemId,
  );
  require(Buffer.byteLength(JSON.stringify(params)) <= 65536);
  const kind = methods[pending.method];
  const result = {
    requestId: pending.id,
    kind,
    fingerprint: requestFingerprint(pending),
    details: JSON.stringify(params, null, 2),
    decisions: [],
  };
  if (kind === "input") {
    require(
      typeof params.isBlocking === "boolean" &&
        Array.isArray(params.questions) &&
        params.questions.length > 0 &&
        params.questions.length <= 16,
    );
    const ids = new Set();
    result.questions = params.questions.map((q) => {
      require(
        q &&
          text(q.id, 128) &&
          q.id &&
          !ids.has(q.id) &&
          text(q.header, 256) &&
          text(q.question),
      );
      ids.add(q.id);
      require(q.isOther === undefined || typeof q.isOther === "boolean");
      require(q.isSecret === undefined || typeof q.isSecret === "boolean");
      require(
        q.options == null ||
          (Array.isArray(q.options) &&
            q.options.length <= 32 &&
            q.options.every(
              (option) =>
                option && text(option.label, 1024) && text(option.description),
            )),
      );
      return {
        id: q.id,
        header: q.header,
        question: q.question,
        isOther: q.isOther ?? false,
        isSecret: q.isSecret ?? false,
        options: q.options ?? null,
      };
    });
  } else {
    require(Number.isSafeInteger(params.startedAtMs));
    const allowed = params.availableDecisions ?? [
      "accept",
      "decline",
      "cancel",
    ];
    require(Array.isArray(allowed));
    result.decisions = ["accept", "decline", "cancel"].filter((value) =>
      allowed.includes(value),
    );
    if (kind === "command") {
      result.command = text(params.command) ? params.command : null;
      if (!result.command || ![undefined, "command"].includes(params.kind))
        result.decisions = result.decisions.filter(
          (value) => value !== "accept",
        );
    } else result.evidenceAvailable = false;
  }
  return result;
}

function evidenceMatches(data, pending, record, session, request) {
  if (
    !data ||
    data.error ||
    data.workerId !== record.workerId ||
    data.generation !== record.generation ||
    data.requestId !== pending.id ||
    data.sessionId !== record.id ||
    data.threadId !== session.providerThreadId ||
    data.turnId !== session.providerTurnId ||
    data.itemId !== pending.params.itemId ||
    data.requestFingerprint !== request.fingerprint
  )
    return false;
  const changes = data.evidence?.changes;
  return (
    Array.isArray(changes) &&
    changes.length > 0 &&
    changes.length <= 64 &&
    Buffer.byteLength(JSON.stringify(data.evidence)) <= 131072 &&
    changes.every(
      (change) =>
        change &&
        text(change.path, 4096) &&
        text(change.diff, 65536) &&
        ["add", "delete", "update"].includes(change.kind?.type),
    )
  );
}

export function createRequestReader(workerStateDirs = {}) {
  require(
    workerStateDirs &&
      typeof workerStateDirs === "object" &&
      !Array.isArray(workerStateDirs),
  );
  for (const [worker, directory] of Object.entries(workerStateDirs))
    require(
      /^[A-Za-z0-9_-]{1,128}$/.test(worker) &&
        text(directory, 4096) &&
        directory.startsWith("/"),
    );
  return {
    workerIds: Object.keys(workerStateDirs),
    async read(record, workspaces) {
      require(
        Object.hasOwn(workerStateDirs, record.workerId) &&
          ["reserved", "claimed"].includes(record.claimStatus) &&
          ["admitted", "running", "idle", "waiting"].includes(record.status),
      );
      require(
        Array.isArray(workspaces) && workspaces.includes(record.workspace),
      );
      const directory = await privateDirectoryOutsideWorkspaces(
        workerStateDirs[record.workerId],
        workspaces,
      );
      const path = resolve(directory, "worker.sock");
      const deadline = Date.now() + 9000;
      const ask = (input) => {
        const remaining = deadline - Date.now();
        require(remaining > 0);
        return exchange(path, input, Math.min(3000, remaining));
      };
      const session = sessionFrom(
        await ask({ operation: "inventory" }),
        record,
      );
      const data = await ask({ operation: "requests", targetId: record.id });
      require(Array.isArray(data.requests) && data.requests.length <= 16);
      const ids = new Set();
      const requests = [];
      for (const pending of data.requests) {
        const request = project(pending, session);
        const key = JSON.stringify(pending.id);
        require(!ids.has(key));
        ids.add(key);
        if (request.kind === "file") {
          try {
            const evidence = await ask({
              operation: "request-evidence",
              targetId: record.id,
              requestId: pending.id,
            });
            if (evidenceMatches(evidence, pending, record, session, request)) {
              request.evidenceAvailable = true;
              request.changes = evidence.evidence.changes;
              // The UI decision must bind the displayed diff as well as the
              // provider request. Re-reading changed evidence invalidates it.
              request.fingerprint = requestFingerprint({
                requestFingerprint: request.fingerprint,
                evidence: evidence.evidence,
              });
            }
          } catch {
            /* Missing private evidence never permits acceptance. */
          }
          if (!request.evidenceAvailable)
            request.decisions = request.decisions.filter(
              (value) => value !== "accept",
            );
        }
        requests.push(request);
      }
      const latest = sessionFrom(await ask({ operation: "inventory" }), record);
      for (const key of [
        "providerThreadId",
        "providerTurnId",
        "activity",
        "workspace",
      ])
        require(same(session[key], latest[key]));
      require(Buffer.byteLength(JSON.stringify(requests)) <= maximum);
      return requests;
    },
  };
}

export function validateResponse(request, response) {
  require(response && typeof response === "object" && !Array.isArray(response));
  if (request.kind !== "input") {
    require(
      same(Object.keys(response), ["decision"]) &&
        request.decisions.includes(response.decision),
    );
    return;
  }
  require(
    same(Object.keys(response), ["answers"]) &&
      response.answers &&
      typeof response.answers === "object" &&
      !Array.isArray(response.answers),
  );
  require(
    same(
      Object.keys(response.answers).sort(),
      request.questions.map((q) => q.id).sort(),
    ),
  );
  for (const question of request.questions) {
    const answer = response.answers[question.id];
    require(
      answer &&
        same(Object.keys(answer), ["answers"]) &&
        Array.isArray(answer.answers) &&
        answer.answers.length > 0 &&
        answer.answers.length <= 32,
    );
    for (const value of answer.answers) {
      require(text(value, 8192) && value.trim());
      if (question.options?.length && !question.isOther)
        require(question.options.some((option) => option.label === value));
    }
  }
}
