import { createHash, randomUUID } from "node:crypto";
import { isDeepStrictEqual } from "node:util";
import { componentEndpoint } from "./upstream.mjs";

const intakeIdPattern = /^[a-z0-9][a-z0-9_-]{7,63}$/;
const digestPattern = /^[a-f0-9]{64}$/;
const taskIdPattern = /^research-[a-f0-9]{64}$/;
const identifierPattern = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/;
const claimFields = [
  "targetKind",
  "targetId",
  "workerId",
  "agentId",
  "generation",
];
const states = new Set([
  "Pending",
  "Decomposing",
  "Delegated",
  "InProgress",
  "Escalated",
  "Completed",
  "Failed",
]);
const object = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const exact = (value, fields) =>
  object(value) &&
  Object.keys(value).length === fields.length &&
  fields.every((key) => Object.hasOwn(value, key));
const matches = (value, pattern) =>
  typeof value === "string" && pattern.test(value);
const timestamp = (value) =>
  matches(value, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/) &&
  Number.isFinite(Date.parse(value)) &&
  new Date(value).toISOString() === value.replace("Z", ".000Z");
const validIssue = (issue) =>
  exact(issue, ["repository", "number", "url"]) &&
  matches(issue.repository, /^[a-z0-9_-]+\/[a-z0-9_.-]+$/) &&
  issue.repository.length <= 200 &&
  !issue.repository.includes("..") &&
  Number.isSafeInteger(issue.number) &&
  issue.number > 0 &&
  issue.number <= 2147483647 &&
  issue.url === `https://github.com/${issue.repository}/issues/${issue.number}`;
const sameIssue = (left, right) =>
  validIssue(left) &&
  validIssue(right) &&
  ["repository", "number", "url"].every((key) => left[key] === right[key]);

function validProvenance(value) {
  return (
    exact(value, [
      "schema",
      "namespace",
      "intakeId",
      "requestDigest",
      "bodyDigest",
      "generation",
      "attemptId",
      "issue",
      "createdAt",
      "confirmedAt",
    ]) &&
    value.schema === "hi/agamemnon/research-intake/v1" &&
    matches(value.namespace, /^[a-z0-9][a-z0-9_-]{0,63}$/) &&
    matches(value.intakeId, intakeIdPattern) &&
    matches(value.requestDigest, digestPattern) &&
    matches(value.bodyDigest, digestPattern) &&
    value.generation === 1 &&
    matches(value.attemptId, /^[a-f0-9]{32}$/) &&
    validIssue(value.issue) &&
    timestamp(value.createdAt) &&
    timestamp(value.confirmedAt)
  );
}

function taskIdFor(provenance) {
  // Match nlohmann::json's lexical object-key order at the controller boundary.
  const key = JSON.stringify({
    intakeId: provenance.intakeId,
    namespace: provenance.namespace,
    schema: "hi/agamemnon/research-task-key/v1",
  });
  return "research-" + createHash("sha256").update(key).digest("hex");
}

function validReceipt(receipt, input, status) {
  return (
    exact(receipt, [
      "schema",
      "taskId",
      "state",
      "provenance",
      "issue",
      "routing",
    ]) &&
    receipt.schema === "hi/agamemnon/research-import-receipt/v1" &&
    validProvenance(receipt.provenance) &&
    receipt.provenance.intakeId === input.intakeId &&
    receipt.provenance.requestDigest === input.requestDigest &&
    receipt.taskId === taskIdFor(receipt.provenance) &&
    states.has(receipt.state) &&
    (status !== 201 || receipt.state === "Pending") &&
    sameIssue(receipt.issue, receipt.provenance.issue) &&
    exact(receipt.routing, ["domain", "hmasRole", "stage"]) &&
    receipt.routing.domain === "research" &&
    receipt.routing.hmasRole === "task-agent" &&
    receipt.routing.stage === "research"
  );
}

function validClaim(claim) {
  return (
    exact(claim, ["schema", ...claimFields, "workspace"]) &&
    claim.schema === "hi/fleet/claim/v1" &&
    ["sessions", "executions", "build-jobs"].includes(claim.targetKind) &&
    matches(claim.targetId, identifierPattern) &&
    matches(claim.workerId, identifierPattern) &&
    typeof claim.agentId === "string" &&
    claim.agentId.length > 0 &&
    Buffer.byteLength(claim.agentId) <= 1024 &&
    Number.isSafeInteger(claim.generation) &&
    claim.generation >= 1 &&
    typeof claim.workspace === "string" &&
    claim.workspace.length > 0 &&
    Buffer.byteLength(claim.workspace) <= 1024
  );
}

function validResolution(resolution, claim, state) {
  return (
    claim !== undefined &&
    exact(resolution, [
      "provenance",
      "verifiedApproval",
      "generation",
      "outcome",
      "decision",
      "decisionId",
      "reviewerId",
      "evidenceRef",
    ]) &&
    resolution.provenance === "manual" &&
    resolution.verifiedApproval === false &&
    resolution.generation === claim.generation &&
    ["decisionId", "reviewerId", "evidenceRef"].every(
      (key) =>
        typeof resolution[key] === "string" &&
        resolution[key].length > 0 &&
        Buffer.byteLength(resolution[key]) <= 1024,
    ) &&
    resolution.reviewerId !== claim.agentId &&
    ((state === "Completed" &&
      resolution.outcome === "completed" &&
      resolution.decision === "approve_completion") ||
      (state === "Failed" &&
        resolution.outcome === "failed" &&
        resolution.decision === "reject_completion"))
  );
}

function taskProjection(document, taskId, neutral = false) {
  if (!exact(document, ["task_id", "state", "layer", "task"])) return null;
  const task = document.task;
  const research = task?.delivery?.researchIntake;
  const direct = task?.delivery?.issueIntake;
  if (research !== undefined && direct !== undefined) return null;
  const provenance = direct ?? research;
  const validIdentity =
    direct !== undefined
      ? neutral &&
        validIssueProvenance(direct) &&
        issueTaskIdFor(direct) === taskId
      : validProvenance(research) && taskIdFor(research) === taskId;
  if (
    !object(task) ||
    !object(task.delivery) ||
    !validIdentity ||
    document.task_id !== taskId ||
    task.id !== taskId ||
    task.layer !== "L3_TaskAgent" ||
    document.layer !== task.layer ||
    !states.has(task.state) ||
    document.state !== task.state ||
    task.brief_id !== "" ||
    task.parent_task_id !== "" ||
    task.module !== "" ||
    !Array.isArray(task.blocked_by) ||
    task.blocked_by.length !== 0 ||
    !Array.isArray(task.child_task_ids) ||
    task.child_task_ids.length !== 0 ||
    task.repo !== provenance.issue.repository ||
    task.issue !== provenance.issue.number ||
    typeof task.assigned_lead_id !== "string" ||
    Buffer.byteLength(task.assigned_lead_id) > 1024
  )
    return null;
  const rawClaim = task.fleet_claim;
  if (
    Object.hasOwn(task, "fleet_claim") &&
    (!validClaim(rawClaim) || task.assigned_lead_id !== rawClaim.agentId)
  )
    return null;
  const rawResolution = task.fleet_resolution;
  if (
    Object.hasOwn(task, "fleet_resolution") &&
    !validResolution(rawResolution, rawClaim, task.state)
  )
    return null;
  const body = {
    schema: neutral
      ? "hi/odysseus/imported-task/v1"
      : "hi/odysseus/research-task/v1",
    taskId,
    state: task.state,
    layer: task.layer,
    provenance,
    issue: provenance.issue,
    assignment: task.assigned_lead_id
      ? { agentId: task.assigned_lead_id }
      : null,
    claim: rawClaim
      ? Object.fromEntries(claimFields.map((key) => [key, rawClaim[key]]))
      : null,
    owner: null,
    resolution: rawResolution
      ? {
          provenance: "manual",
          verifiedApproval: false,
          outcome: rawResolution.outcome,
          decision: rawResolution.decision,
        }
      : null,
  };
  return { body, rawClaim, rawResolution };
}

function validOwnerRecord(record) {
  return (
    object(record) &&
    record.schema === "hi/fleet/v1" &&
    [
      "created",
      "admitted",
      "running",
      "idle",
      "waiting",
      "draining",
      "cancelling",
      "interrupting",
      "cancelled",
      "interrupted",
      "completed",
      "failed",
    ].includes(record.status) &&
    ["unclaimed", "reserved", "claimed", "released"].includes(
      record.claimStatus,
    ) &&
    ["sessionId", "executionId"].every(
      (key) =>
        !Object.hasOwn(record, key) || matches(record[key], identifierPattern),
    )
  );
}

function matchesClaim(record, taskId, claim) {
  return (
    record.taskId === taskId &&
    record.kind === claim.targetKind &&
    record.id === claim.targetId &&
    ["workerId", "agentId", "generation", "workspace"].every(
      (key) => record[key] === claim[key],
    ) &&
    (record.kind !== "sessions" ||
      record.sessionId === undefined ||
      record.sessionId === record.id) &&
    (record.kind !== "executions" ||
      record.executionId === undefined ||
      record.executionId === record.id)
  );
}

const failure = (code, error, outcome = "unknown") => ({
  code,
  body: { error, outcome },
});

function rejectDuplicateKeys(text) {
  // JSON.parse already validated grammar. Track object keys in the lexical
  // tokens so repeated or escaped-equivalent keys cannot vanish during parsing.
  const stack = [];
  for (const [token] of text.matchAll(/"(?:\\.|[^"\\])*"|[{}\[\]:,]/g)) {
    if (token === "{") stack.push({ keys: new Set(), key: true });
    else if (token === "[") stack.push(null);
    else if (token === "}" || token === "]") stack.pop();
    else if (token === "," && stack.at(-1)) stack.at(-1).key = true;
    else if (token === ":" && stack.at(-1)) stack.at(-1).key = false;
    else if (token.startsWith('"') && stack.at(-1)?.key) {
      const key = JSON.parse(token);
      const current = stack.at(-1);
      if (current.keys.has(key)) throw new Error("Duplicate JSON key");
      current.keys.add(key);
      current.key = false;
    }
  }
}

export function parseIssueImportJson(text) {
  const value = JSON.parse(text, (key, item) => {
    if (
      !key.isWellFormed() ||
      (typeof item === "string" && !item.isWellFormed())
    )
      throw new Error("Invalid Unicode text");
    return item;
  });
  rejectDuplicateKeys(text);
  return value;
}

async function readImportJson(response, signal, parse = JSON.parse) {
  if (!response.ok || !response.body) throw new Error("Upstream unavailable");
  const reader = response.body.getReader();
  // Abort must reach this owned reader even after fetch has returned headers.
  const abort = () => {
    void reader.cancel().catch(() => {});
  };
  signal.addEventListener("abort", abort, { once: true });
  const chunks = [];
  let bytes = 0;
  try {
    signal.throwIfAborted();
    while (true) {
      const { value, done } = await reader.read();
      signal.throwIfAborted();
      if (done) break;
      bytes += value.length;
      if (bytes > 2 * 1024 * 1024)
        throw new Error("Import response exceeds limit");
      chunks.push(value);
    }
    return parse(
      new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks)),
    );
  } finally {
    signal.removeEventListener("abort", abort);
    try {
      await reader.cancel();
    } finally {
      reader.releaseLock();
    }
  }
}
const readIssueImportJson = (response, signal) =>
  readImportJson(response, signal, parseIssueImportJson);

function configuredEndpoint(url, apiKey) {
  const endpoint = componentEndpoint(url);
  if (
    typeof apiKey !== "string" ||
    !apiKey.length ||
    Buffer.byteLength(apiKey) > 8192 ||
    /[\r\n]/.test(apiKey)
  )
    throw new Error("Agamemnon credentials are required");
  return endpoint;
}

const registryKey = (value) => matches(value, /^[a-z0-9][a-z0-9_-]{0,63}$/);
const nativeId = (value) =>
  typeof value === "string" &&
  value.length > 0 &&
  value.isWellFormed() &&
  Buffer.byteLength(value) <= 128;
const repositoryName = (value) =>
  matches(value, /^[a-zA-Z0-9_-]+\/[a-zA-Z0-9_.-]+$/) &&
  value.length <= 255 &&
  ![".", ".."].includes(value.split("/")[1]);

const issueNumber = (value) =>
  Number.isSafeInteger(value) && value > 0 && value <= 2147483647;
const directIssue = (value) =>
  exact(value, ["repository", "number", "url"]) &&
  repositoryName(value.repository) &&
  issueNumber(value.number) &&
  value.url === `https://github.com/${value.repository}/issues/${value.number}`;
const issueRouting = (value) =>
  exact(value, ["domain", "hmasRole", "stage"]) &&
  value.domain === "pipeline" &&
  value.hmasRole === "task-agent" &&
  value.stage === "implementation";
const validPlan = (value) =>
  ((exact(value, ["kind", "digest"]) && value.kind === "issue_body") ||
    (exact(value, ["kind", "nodeId", "digest"]) &&
      value.kind === "issue_comment" &&
      nativeId(value.nodeId))) &&
  matches(value.digest, digestPattern);
const validIssueInput = (value) =>
  exact(value, [
    "schema",
    "repositoryKey",
    "issueNumber",
    "repositoryId",
    "issueId",
    "plan",
  ]) &&
  value.schema === "hi/agamemnon/issue-import/v1" &&
  registryKey(value.repositoryKey) &&
  issueNumber(value.issueNumber) &&
  nativeId(value.repositoryId) &&
  nativeId(value.issueId) &&
  validPlan(value.plan);

function issueTaskIdFor(value) {
  const key = JSON.stringify({
    forge: "github",
    issueId: value.issueId,
    repositoryId: value.repositoryId,
    schema: "hi/agamemnon/issue-task-key/v1",
  });
  return "issue-" + createHash("sha256").update(key).digest("hex");
}

function validIssueProvenance(value) {
  return (
    exact(value, [
      "schema",
      "forge",
      "repositoryId",
      "issueId",
      "issue",
      "plan",
      "routing",
      "observedAt",
    ]) &&
    value.schema === "hi/agamemnon/issue-intake/v1" &&
    value.forge === "github" &&
    nativeId(value.repositoryId) &&
    nativeId(value.issueId) &&
    directIssue(value.issue) &&
    validPlan(value.plan) &&
    issueRouting(value.routing) &&
    timestamp(value.observedAt)
  );
}

function validIssueReceipt(value, input, status) {
  return (
    exact(value, [
      "schema",
      "taskId",
      "state",
      "provenance",
      "issue",
      "routing",
    ]) &&
    value.schema === "hi/agamemnon/issue-import-receipt/v1" &&
    validIssueProvenance(value.provenance) &&
    value.provenance.repositoryId === input.repositoryId &&
    value.provenance.issueId === input.issueId &&
    value.provenance.issue.number === input.issueNumber &&
    isDeepStrictEqual(value.provenance.plan, input.plan) &&
    value.taskId === issueTaskIdFor(value.provenance) &&
    states.has(value.state) &&
    (status !== 201 || value.state === "Pending") &&
    isDeepStrictEqual(value.issue, value.provenance.issue) &&
    isDeepStrictEqual(value.routing, value.provenance.routing)
  );
}

function validInspection(value, key, number, comment) {
  return (
    exact(value, [
      "schema",
      "repositoryKey",
      "repositoryId",
      "issueId",
      "issue",
      "title",
      "state",
      "plan",
      "observedAt",
    ]) &&
    value.schema === "hi/agamemnon/issue-inspection/v1" &&
    value.repositoryKey === key &&
    nativeId(value.repositoryId) &&
    nativeId(value.issueId) &&
    directIssue(value.issue) &&
    value.issue.number === number &&
    typeof value.title === "string" &&
    Buffer.byteLength(value.title) <= 1024 &&
    ["open", "closed"].includes(value.state) &&
    validPlan(value.plan) &&
    timestamp(value.observedAt) &&
    (comment === undefined
      ? value.plan.kind === "issue_body"
      : value.plan.kind === "issue_comment" && value.plan.nodeId === comment)
  );
}

function observationReporter(observe, kind) {
  const sourceId = `odysseus:${kind}:${randomUUID()}`;
  let sourceSequence = 0;
  return (operation, messageId, correlationId, details) =>
    observe({
      eventId: randomUUID(),
      sourceId,
      sourceSequence: ++sourceSequence,
      source: operation === "request" ? "odysseus" : "agamemnon",
      target: operation === "request" ? "agamemnon" : "odysseus",
      transport: "http",
      operation,
      observedAt: new Date().toISOString(),
      messageId,
      correlationId,
      messageKind: kind,
      ...details,
    });
}

function controllerReader(
  endpoint,
  apiKey,
  fetchImpl,
  observation,
  readJson = readImportJson,
) {
  return async (path, correlationId, signal, details = {}) => {
    const messageId = randomUUID();
    observation("request", messageId, correlationId, {
      ...details,
      result: "attempted",
    });
    const response = await fetchImpl(new URL(path, endpoint), {
      method: "GET",
      headers: { authorization: `Bearer ${apiKey}` },
      redirect: "error",
      signal,
    });
    observation("response", messageId, correlationId, {
      ...details,
      result: `http-${response.status}`,
    });
    if (response.status !== 200) {
      await response.body?.cancel();
      return { status: response.status };
    }
    return { status: 200, document: await readJson(response, signal) };
  };
}

async function loadTask(read, taskId, signal, neutral = false) {
  const path = `/v1/tasks/${taskId}/state`;
  const response = await read(path, taskId, signal);
  if (response.status !== 200)
    return response.status === 404
      ? failure(404, "task_not_found")
      : failure(503, "task_unavailable");
  const task = taskProjection(response.document, taskId, neutral);
  if (!task) return failure(503, "task_unavailable");
  if (!task.rawClaim) return { code: 200, body: task.body };
  const claim = task.rawClaim;
  const target = await read(
    `/v1/fleet/${claim.targetKind}/${claim.targetId}`,
    taskId,
    signal,
  );
  if (target.status !== 200 || !validOwnerRecord(target.document))
    return failure(503, "task_unavailable");
  if (!matchesClaim(target.document, taskId, claim))
    return failure(409, "task_conflict");
  if (
    task.rawResolution &&
    (target.document.status !== task.rawResolution.outcome ||
      target.document.claimStatus !== "released" ||
      !isDeepStrictEqual(target.document.resolution, task.rawResolution))
  )
    return failure(409, "task_conflict");
  const recheck = await read(path, taskId, signal);
  if (recheck.status !== 200) return failure(503, "task_unavailable");
  const current = taskProjection(recheck.document, taskId, neutral);
  if (!current) return failure(503, "task_unavailable");
  if (!isDeepStrictEqual(task, current)) return failure(409, "task_conflict");
  task.body.owner = {
    ...task.body.claim,
    status: target.document.status,
    claimStatus: target.document.claimStatus,
  };
  for (const key of ["sessionId", "executionId"])
    if (Object.hasOwn(target.document, key))
      task.body.owner[key] = target.document[key];
  return { code: 200, body: task.body };
}

function validRegistry(value) {
  if (
    !exact(value, ["schema", "repositories"]) ||
    value.schema !== "hi/agamemnon/issue-repositories/v1" ||
    !Array.isArray(value.repositories) ||
    value.repositories.length < 1 ||
    value.repositories.length > 64
  )
    return false;
  const keys = new Set();
  const ids = new Set();
  const names = new Set();
  for (const entry of value.repositories) {
    if (
      !exact(entry, ["key", "repository", "repositoryId"]) ||
      !registryKey(entry.key) ||
      !repositoryName(entry.repository) ||
      !nativeId(entry.repositoryId) ||
      keys.has(entry.key) ||
      ids.has(entry.repositoryId) ||
      names.has(entry.repository.toLowerCase())
    )
      return false;
    keys.add(entry.key);
    ids.add(entry.repositoryId);
    names.add(entry.repository.toLowerCase());
  }
  return true;
}

// Keep the operation timer alive until headers AND body have been consumed.
// Every caller releases it in finally, including failed or cancelled reads.
function operationDeadline(milliseconds) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), milliseconds);
  return { signal: controller.signal, finish: () => clearTimeout(timer) };
}

export function createIssueImportService({
  url,
  apiKey,
  observe = () => {},
  fetchImpl = fetch,
}) {
  const endpoint = configuredEndpoint(url, apiKey);
  const observation = observationReporter(observe, "issue-import");
  const read = controllerReader(
    endpoint,
    apiKey,
    fetchImpl,
    observation,
    readIssueImportJson,
  );
  let pending = 0;
  return {
    async repositories() {
      if (pending >= 4) return failure(429, "busy", "not_submitted");
      pending++;
      const deadline = operationDeadline(5000);
      try {
        const response = await read(
          "/v1/fleet/issue-intakes/repositories",
          "issue-repositories",
          deadline.signal,
        );
        const registry = response.document;
        return validRegistry(registry)
          ? { code: 200, body: registry }
          : failure(503, "registry_unavailable", "not_submitted");
      } catch {
        return failure(503, "registry_unavailable", "not_submitted");
      } finally {
        deadline.finish();
        pending--;
      }
    },
    async inspect(key, number, comment) {
      if (
        !registryKey(key) ||
        !issueNumber(number) ||
        (comment !== undefined && !nativeId(comment))
      )
        return failure(400, "invalid_request", "not_submitted");
      if (pending >= 4) return failure(429, "busy", "not_submitted");
      pending++;
      const deadline = operationDeadline(40000);
      try {
        const query =
          comment === undefined
            ? ""
            : `?${new URLSearchParams({ planCommentId: comment })}`;
        const response = await read(
          `/v1/fleet/issue-intakes/${key}/${number}${query}`,
          `${key}:${number}`,
          deadline.signal,
        );
        if (response.status !== 200)
          return failure(
            [400, 404, 409].includes(response.status) ? response.status : 503,
            "issue_unavailable",
            "not_submitted",
          );
        return validInspection(response.document, key, number, comment)
          ? { code: 200, body: response.document }
          : failure(503, "issue_unavailable", "not_submitted");
      } catch {
        return failure(503, "issue_unavailable", "not_submitted");
      } finally {
        deadline.finish();
        pending--;
      }
    },
    async submit(input) {
      if (
        !validIssueInput(input) ||
        Buffer.byteLength(JSON.stringify(input)) > 4096
      )
        return failure(400, "invalid_request", "not_submitted");
      if (pending >= 4) return failure(429, "busy", "not_submitted");
      pending++;
      const deadline = operationDeadline(40000);
      try {
        const body = JSON.stringify(input);
        const messageId = randomUUID();
        observation("request", messageId, input.issueId, {
          bytes: Buffer.byteLength(body),
          result: "attempted",
        });
        const response = await fetchImpl(
          new URL("/v1/fleet/issue-intakes", endpoint),
          {
            method: "POST",
            headers: {
              authorization: `Bearer ${apiKey}`,
              "content-type": "application/json",
            },
            body,
            redirect: "error",
            signal: deadline.signal,
          },
        );
        observation("response", messageId, input.issueId, {
          result: `http-${response.status}`,
        });
        if (![200, 201].includes(response.status)) {
          await response.body?.cancel();
          return failure(
            [400, 404, 409].includes(response.status) ? response.status : 503,
            response.status === 409 ? "import_conflict" : "import_unconfirmed",
          );
        }
        const receipt = await readIssueImportJson(response, deadline.signal);
        return validIssueReceipt(receipt, input, response.status)
          ? { code: response.status, body: receipt }
          : failure(503, "import_unconfirmed");
      } catch {
        return failure(503, "import_unconfirmed");
      } finally {
        deadline.finish();
        pending--;
      }
    },
    async readTask(taskId) {
      if (!matches(taskId, /^(issue|research)-[a-f0-9]{64}$/))
        return failure(400, "invalid_request", "not_submitted");
      if (pending >= 4) return failure(429, "busy", "not_submitted");
      pending++;
      const deadline = operationDeadline(5000);
      try {
        return await loadTask(
          (path, id, signal) =>
            read(path, id, signal, {
              taskId: id,
              messageKind: "imported-task",
            }),
          taskId,
          deadline.signal,
          true,
        );
      } catch {
        return failure(503, "task_unavailable");
      } finally {
        deadline.finish();
        pending--;
      }
    },
  };
}

export function createResearchImportService({
  url,
  apiKey,
  observe = () => {},
  fetchImpl = fetch,
}) {
  const endpoint = configuredEndpoint(url, apiKey);
  let pending = 0;
  const observation = observationReporter(observe, "research-import");
  const request = controllerReader(endpoint, apiKey, fetchImpl, observation);
  const read = (path, taskId, signal) =>
    request(path, taskId, signal, { taskId, messageKind: "research-task" });
  return {
    async submit(input) {
      if (
        !exact(input, ["schema", "intakeId", "requestDigest"]) ||
        input.schema !== "hi/agamemnon/research-import/v1" ||
        !matches(input.intakeId, intakeIdPattern) ||
        !matches(input.requestDigest, digestPattern) ||
        Buffer.byteLength(JSON.stringify(input)) > 4096
      )
        return failure(400, "invalid_request", "not_submitted");
      if (pending >= 4) return failure(429, "busy", "not_submitted");
      pending++;
      const deadline = operationDeadline(40000);
      try {
        const body = JSON.stringify(input);
        const messageId = randomUUID();
        observation("request", messageId, input.intakeId, {
          bytes: Buffer.byteLength(body),
          result: "attempted",
        });
        const response = await fetchImpl(
          new URL("/v1/fleet/research-intakes", endpoint),
          {
            method: "POST",
            headers: {
              authorization: `Bearer ${apiKey}`,
              "content-type": "application/json",
            },
            body,
            redirect: "error",
            signal: deadline.signal,
          },
        );
        // Headers are an observed response, not proof of a valid import receipt.
        observation("response", messageId, input.intakeId, {
          result: `http-${response.status}`,
        });
        if (![200, 201].includes(response.status)) {
          await response.body?.cancel();
          const error = {
            400: "invalid_request",
            404: "intake_not_found",
            409: "import_conflict",
          }[response.status];
          return error
            ? failure(response.status, error)
            : failure(503, "import_unconfirmed");
        }
        const receipt = await readImportJson(response, deadline.signal);
        if (!validReceipt(receipt, input, response.status))
          return failure(503, "import_unconfirmed");
        return { code: response.status, body: receipt };
      } catch {
        // A request may have reached the controller; retain uncertainty, never retry.
        return failure(503, "import_unconfirmed");
      } finally {
        deadline.finish();
        pending--;
      }
    },
    async readTask(taskId) {
      if (!matches(taskId, taskIdPattern))
        return failure(400, "invalid_request", "not_submitted");
      if (pending >= 4) return failure(429, "busy", "not_submitted");
      pending++;
      const deadline = operationDeadline(5000);
      try {
        return await loadTask(read, taskId, deadline.signal);
      } catch {
        return failure(503, "task_unavailable");
      } finally {
        deadline.finish();
        pending--;
      }
    },
  };
}
