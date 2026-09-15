import { createHash, randomUUID } from "node:crypto";
import { isDeepStrictEqual } from "node:util";
import { componentEndpoint, readComponentJson } from "./upstream.mjs";

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

function taskProjection(document, taskId) {
  if (!exact(document, ["task_id", "state", "layer", "task"])) return null;
  const task = document.task;
  const provenance = task?.delivery?.researchIntake;
  if (
    !object(task) ||
    !object(task.delivery) ||
    !validProvenance(provenance) ||
    document.task_id !== taskId ||
    task.id !== taskId ||
    taskIdFor(provenance) !== taskId ||
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
    schema: "hi/odysseus/research-task/v1",
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

export function createResearchImportService({
  url,
  apiKey,
  observe = () => {},
  fetchImpl = fetch,
}) {
  const endpoint = componentEndpoint(url);
  if (
    typeof apiKey !== "string" ||
    !apiKey.length ||
    Buffer.byteLength(apiKey) > 8192 ||
    /[\r\n]/.test(apiKey)
  )
    throw new Error("Agamemnon credentials are required");
  let pending = 0;
  const sourceId = `odysseus:research-import:${randomUUID()}`;
  let sourceSequence = 0;
  function observation(operation, messageId, correlationId, details) {
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
      messageKind: "research-import",
      ...details,
    });
  }
  async function read(path, taskId, signal) {
    const messageId = randomUUID();
    const details = { taskId, messageKind: "research-task" };
    observation("request", messageId, taskId, {
      ...details,
      result: "attempted",
    });
    const response = await fetchImpl(new URL(path, endpoint), {
      method: "GET",
      headers: { authorization: `Bearer ${apiKey}` },
      redirect: "error",
      signal,
    });
    observation("response", messageId, taskId, {
      ...details,
      result: `http-${response.status}`,
    });
    if (response.status !== 200) {
      await response.body?.cancel();
      return { status: response.status };
    }
    return { status: 200, document: await readComponentJson(response) };
  }
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
            signal: AbortSignal.timeout(5000),
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
        const receipt = await readComponentJson(response);
        if (!validReceipt(receipt, input, response.status))
          return failure(503, "import_unconfirmed");
        return { code: response.status, body: receipt };
      } catch {
        // A request may have reached the controller; retain uncertainty, never retry.
        return failure(503, "import_unconfirmed");
      } finally {
        pending--;
      }
    },
    async readTask(taskId) {
      if (!matches(taskId, taskIdPattern))
        return failure(400, "invalid_request", "not_submitted");
      if (pending >= 4) return failure(429, "busy", "not_submitted");
      pending++;
      try {
        const signal = AbortSignal.timeout(5000);
        const path = `/v1/tasks/${taskId}/state`;
        const response = await read(path, taskId, signal);
        if (response.status !== 200)
          return response.status === 404
            ? failure(404, "task_not_found")
            : failure(503, "task_unavailable");
        const task = taskProjection(response.document, taskId);
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
        const current = taskProjection(recheck.document, taskId);
        if (!current) return failure(503, "task_unavailable");
        if (!isDeepStrictEqual(task, current))
          return failure(409, "task_conflict");
        task.body.owner = {
          ...task.body.claim,
          status: target.document.status,
          claimStatus: target.document.claimStatus,
        };
        for (const key of ["sessionId", "executionId"])
          if (Object.hasOwn(target.document, key))
            task.body.owner[key] = target.document[key];
        return { code: 200, body: task.body };
      } catch {
        return failure(503, "task_unavailable");
      } finally {
        pending--;
      }
    },
  };
}
