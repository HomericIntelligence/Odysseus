import { createHash, randomUUID } from "node:crypto";
import { projectMetadata } from "./projects.mjs";

export const COMPONENTS = [
  "odysseus",
  "nestor",
  "telemachy",
  "agamemnon",
  "keystone",
  "myrmidons",
  "hephaestus",
  "achaeanfleet",
  "proteus",
  "hermes",
  "argus",
  "scylla",
  "charybdis",
  "mnemosyne",
  "github",
  "slurm",
  "codex",
];
export const RESOURCE_KINDS = [
  "pools",
  "workers",
  "sessions",
  "executions",
  "build-jobs",
];
const operations = new Set([
  "publish",
  "deliver",
  "ack",
  "nak",
  "redeliver",
  "inProgress",
  "request",
  "response",
]);
const activityStates = new Set([
  "running",
  "model_working",
  "tool_running",
  "waiting_for_input",
  "waiting_for_approval",
  "waiting_approval",
  "waiting_input",
  "idle",
  "disconnected",
  "completing",
  "succeeded",
  "failed",
  "cancelled",
  "interrupted",
]);
const terminalStates = new Set([
  "succeeded",
  "failed",
  "cancelled",
  "interrupted",
]);
const recordFields = [
  "id",
  "taskId",
  "subject",
  "name",
  "agentId",
  "executionId",
  "sessionId",
  "workerId",
  "host",
  "poolId",
  "allocationId",
  "component",
  "stage",
  "status",
  "activity",
  "claimStatus",
  "lastActivityAt",
  "waitingReason",
  "hmasRole",
  "executionDomain",
  "workspaceId",
  "workspacePolicy",
  "enforcementStatus",
  "provider",
  "credentialExpiryAt",
];
const traceFields = [
  "eventId",
  "sourceId",
  "messageId",
  "correlationId",
  "taskId",
  "executionId",
  "sessionId",
  "agentId",
  "workerId",
  "poolId",
  "allocationId",
  "host",
  "subject",
  "messageKind",
  "result",
];
const identifier = (value) =>
  typeof value === "string" && /^[\w.:/@*<>-]{1,256}$/.test(value)
    ? value
    : undefined;
// A gateway source combines two bounded identities and an attachment epoch.
// Keep its larger bound separate from task, event, and correlation identifiers.
const sourceIdentifier = (value) =>
  typeof value === "string" && /^[\w.:/@*<>-]{1,512}$/.test(value)
    ? value
    : undefined;
const text = (value) =>
  typeof value === "string"
    ? value.replace(/[\x00-\x1f\x7f]/g, " ").slice(0, 320)
    : undefined;
const date = (value) =>
  typeof value === "string" && Number.isFinite(Date.parse(value))
    ? new Date(value).toISOString()
    : undefined;
const integer = (value) =>
  Number.isSafeInteger(value) && value >= 0 ? value : undefined;

export function validResourceCollection(items) {
  if (!Array.isArray(items)) return false;
  const ids = new Set();
  return items.every((item) => {
    if (
      !item ||
      typeof item !== "object" ||
      Array.isArray(item) ||
      !identifier(item.id) ||
      ids.has(item.id)
    )
      return false;
    ids.add(item.id);
    return true;
  });
}

function record(input) {
  if (!input || !identifier(input.id)) return null;
  const output = {};
  for (const key of recordFields)
    if (text(input[key]) !== undefined) output[key] = text(input[key]);
  // Agamemnon's v1 resource calls the execution domain "domain".
  if (text(input.domain) !== undefined)
    output.executionDomain = text(input.domain);
  for (const key of [
    "generation",
    "capacity",
    "conversationsPerWorker",
    "cpus",
    "memoryGiB",
  ]) {
    if (integer(input[key]) !== undefined) output[key] = input[key];
  }
  if (date(input.lastActivityAt))
    output.lastActivityAt = date(input.lastActivityAt);
  else delete output.lastActivityAt;
  for (const key of ["issueUrl", "prUrl"]) {
    try {
      const url = new URL(input[key]);
      if (
        url.protocol === "https:" &&
        url.hostname === "github.com" &&
        !url.username &&
        !url.password &&
        /^\/[^/]+\/[^/]+\/(issues|pull)\/\d+$/.test(url.pathname)
      )
        output[key] = url.origin + url.pathname;
    } catch {
      /* Missing and non-GitHub links are not browser destinations. */
    }
  }
  return output;
}

// Subordinate tool workers are distinct from provider workers. Retained parent
// identifiers describe admission history; they cannot grant current ownership.
function buildRecord(input) {
  if (!Object.hasOwn(input, "build")) return record(input);
  const validBuildId = /^build-[0-9a-f]{64}$/.test(input.id);
  const states = new Set([
    "admitted",
    "authorized",
    "cancelling",
    "completed",
    "failed",
    "cancelled",
    "timed_out",
  ]);
  const output = {
    // # cannot occur in a controller resource ID. This display key keeps
    // malformed rows distinct without publishing their original identifiers.
    id: validBuildId
      ? input.id
      : `unavailable-build#${createHash("sha256").update(input.id).digest("hex")}`,
    ...(!validBuildId
      ? { identityState: "unavailable", subject: "Build identity unavailable" }
      : {}),
    buildType: "subordinate",
    component: "hephaestus",
    status: states.has(input.status) ? input.status : "unknown",
    updatedAt: date(input.updatedAt),
    ownershipState: "unavailable",
  };
  const build = input.build;
  const allocation = build?.allocation;
  const policyAllocation = build?.policy?.allocation;
  const parent = input.parent;
  const claim = parent?.claim;
  const requestedParent = build?.request?.parent;
  const validId = (value) =>
    typeof value === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(value);
  const positive = (value) => Number.isSafeInteger(value) && value > 0;
  if (
    !validBuildId ||
    input.schema !== "hi/fleet/v1" ||
    input.kind !== "build-jobs" ||
    build?.schema !== "hi/fleet/build/v1" ||
    !validId(allocation?.workerId) ||
    !validId(allocation?.id) ||
    !positive(allocation?.generation) ||
    input.generation !== allocation.generation ||
    !["workerId", "id", "generation"].every(
      (key) => allocation[key] === policyAllocation?.[key],
    ) ||
    build.attempt !== 1 ||
    build.snapshotWorkspace !== `${input.id}-attempt-1` ||
    !["sessions", "executions"].includes(parent?.targetKind) ||
    !positive(parent?.generation) ||
    !["targetId", "sessionId", "executionId", "taskId", "agentId"].every(
      (key) => validId(parent?.[key]),
    ) ||
    !["targetKind", "targetId", "sessionId", "executionId", "generation"].every(
      (key) => parent[key] === requestedParent?.[key],
    ) ||
    claim?.schema !== "hi/fleet/claim/v1" ||
    !validId(claim?.workerId) ||
    !["targetKind", "targetId", "agentId", "generation"].every(
      (key) => parent[key] === claim[key],
    )
  )
    return output;
  return {
    ...output,
    ownershipState: "reported",
    workerId: allocation.workerId,
    allocationId: allocation.id,
    generation: allocation.generation,
    workspaceId: build.snapshotWorkspace,
    parent: Object.fromEntries([
      ...[
        "targetKind",
        "targetId",
        "sessionId",
        "executionId",
        "taskId",
        "agentId",
        "generation",
      ].map((key) => [key, parent[key]]),
      ["workerId", claim.workerId],
    ]),
  };
}

// Disposable read projection: this class cannot claim, dispatch, or update work.
export class FleetView {
  constructor({
    now = Date.now,
    staleAfterMs = 15000,
    historyLimit = 1000,
    instanceId = randomUUID(),
  } = {}) {
    if (
      !Number.isInteger(historyLimit) ||
      historyLimit < 1 ||
      historyLimit > 10000
    )
      throw new Error("Invalid history limit");
    this.now = now;
    this.staleAfterMs = staleAfterMs;
    this.historyLimit = historyLimit;
    this.instanceId = instanceId;
    this.resources = Object.fromEntries(
      RESOURCE_KINDS.map((kind) => [kind, []]),
    );
    this.sources = {};
    this.observations = [];
    this.seen = new Set();
    this.sequence = 0;
    this.dropped = 0;
    this.invalid = 0;
    this.coverageLosses = 0;
    this.truncatedResources = false;
    this.sourceSequences = new Map();
    this.sourceGaps = 0;
  }

  setResources(kind, items) {
    if (!RESOURCE_KINDS.includes(kind) || !validResourceCollection(items))
      throw new Error("Invalid resource collection");
    this.truncatedResources ||= items.length > 2000;
    this.resources[kind] = items
      .slice(0, 2000)
      .map(kind === "build-jobs" ? buildRecord : record)
      .filter(Boolean);
  }

  setSource(source, status) {
    this.sources[source] = {
      status,
      observedAt: new Date(this.now()).toISOString(),
    };
  }

  setProjects(input) {
    const metadata = projectMetadata(input);
    this.projects = {
      ...metadata,
      observedAt: new Date(this.now()).toISOString(),
    };
  }

  recordCoverageLoss(source, status) {
    this.coverageLosses++;
    this.setSource(source, status);
  }

  observe(input) {
    if (!input || typeof input !== "object") {
      this.invalid++;
      this.coverageLosses++;
      return false;
    }
    const source = text(input.source)?.toLowerCase();
    const target = text(input.target)?.toLowerCase();
    if (
      !COMPONENTS.includes(source) ||
      !COMPONENTS.includes(target) ||
      !identifier(input.eventId) ||
      !operations.has(input.operation) ||
      !date(input.observedAt)
    ) {
      this.invalid++;
      this.coverageLosses++;
      return false;
    }
    const key = `${source}:${input.workerId ?? ""}:${input.eventId}`;
    if (this.seen.has(key)) return false;
    const output = {
      source,
      target,
      operation: input.operation,
      observedAt: date(input.observedAt),
      receivedAt: new Date(this.now()).toISOString(),
      sequence: ++this.sequence,
    };
    for (const key of traceFields) {
      const validate = key === "sourceId" ? sourceIdentifier : identifier;
      if (validate(input[key])) output[key] = input[key];
    }
    for (const key of ["generation", "bytes", "sourceSequence"])
      if (integer(input[key]) !== undefined) output[key] = input[key];
    if (
      [
        "nats",
        "nats-jetstream",
        "blazingmq",
        "ssh",
        "stdio",
        "http",
        "app-server",
      ].includes(input.transport)
    )
      output.transport = input.transport;
    if (output.sourceSequence !== undefined) {
      const sourceKey = output.sourceId;
      const previous = this.sourceSequences.get(sourceKey);
      if (
        sourceKey &&
        previous !== undefined &&
        output.sourceSequence !== previous + 1
      )
        this.sourceGaps++;
      if (sourceKey) this.sourceSequences.set(sourceKey, output.sourceSequence);
      else output.continuity = "unknown";
      if (this.sourceSequences.size > this.historyLimit * 4)
        this.sourceSequences.delete(this.sourceSequences.keys().next().value);
    }
    this.seen.add(key);
    if (this.seen.size > this.historyLimit * 4)
      this.seen.delete(this.seen.values().next().value);
    this.observations.push(output);
    if (this.observations.length > this.historyLimit) {
      this.observations.shift();
      this.dropped++;
    }
    return true;
  }

  snapshot(after) {
    const now = this.now();
    const executions = new Map(
      this.resources.executions.map((item) => [item.id, item]),
    );
    const workers = new Map(
      this.resources.workers.map((item) => [item.id, item]),
    );
    const sessions = this.resources.sessions.map((session) => {
      const candidate = executions.get(session.executionId);
      const execution =
        candidate &&
        Number.isSafeInteger(session.generation) &&
        candidate.generation === session.generation &&
        (!candidate.sessionId || candidate.sessionId === session.id) &&
        ["taskId", "agentId", "workerId"].every(
          (key) =>
            !candidate[key] || !session[key] || candidate[key] === session[key],
        )
          ? candidate
          : {};
      const workerCandidate = workers.get(
        session.workerId ?? execution.workerId,
      );
      const worker =
        workerCandidate &&
        (workerCandidate.generation === undefined ||
          workerCandidate.generation === session.generation)
          ? workerCandidate
          : {};
      const combined = {
        ...worker,
        ...session,
        id: session.id,
        kind: "session",
        component: "hephaestus",
        sessionId: session.id,
        workerId: session.workerId ?? execution.workerId,
      };
      const observed =
        session.activity &&
        date(session.lastActivityAt) &&
        (!date(execution.lastActivityAt) ||
          Date.parse(session.lastActivityAt) >=
            Date.parse(execution.lastActivityAt))
          ? session
          : execution;
      const lastActivityAt = date(observed.lastActivityAt);
      const observedActivity =
        observed.activity ??
        (observed === execution ? execution.status : undefined);
      combined.stage = observed.stage ?? session.stage;
      combined.waitingReason = observed.waitingReason;
      combined.activity =
        lastActivityAt &&
        Date.parse(lastActivityAt) <= now + 5000 &&
        activityStates.has(observedActivity)
          ? observedActivity
          : "unknown";
      if (
        lastActivityAt &&
        now - Date.parse(lastActivityAt) > this.staleAfterMs &&
        !terminalStates.has(combined.activity)
      )
        combined.activity = "stale";
      combined.lastActivityAt = lastActivityAt;
      return combined;
    });
    const builds = this.resources["build-jobs"].map((job) => ({
      ...job,
      kind: "build-job",
      activity:
        job.lastActivityAt &&
        Date.parse(job.lastActivityAt) <= now + 5000 &&
        activityStates.has(job.status)
          ? !terminalStates.has(job.status) &&
            now - Date.parse(job.lastActivityAt) > this.staleAfterMs
            ? "stale"
            : job.status
          : "unknown",
    }));
    const first = this.observations[0]?.sequence ?? this.sequence;
    let gap = false;
    if (after) {
      const [epoch, seq, extra] = String(after).split(":");
      gap =
        epoch !== this.instanceId ||
        extra !== undefined ||
        !/^\d+$/.test(seq ?? "") ||
        Number(seq) < first - 1 ||
        Number(seq) > this.sequence;
    }
    return {
      cursor: `${this.instanceId}:${this.sequence}`,
      generatedAt: new Date(now).toISOString(),
      gap,
      dropped: this.dropped,
      invalid: this.invalid,
      coverageLosses: this.coverageLosses,
      sourceGaps: this.sourceGaps,
      truncatedResources: this.truncatedResources,
      sources: this.sources,
      projects: this.projects
        ? {
            ...this.projects,
            fresh:
              this.sources.projects?.status === "connected" &&
              now - Date.parse(this.projects.observedAt) >= 0 &&
              now - Date.parse(this.projects.observedAt) <= 90000,
          }
        : undefined,
      resources: this.resources,
      items: [...sessions, ...builds],
      observations: this.observations.slice(),
      components: COMPONENTS,
    };
  }
}
