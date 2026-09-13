import { useEffect, useRef, useState } from "react";
import { matchPacket } from "./selectors";
import type { TrackedItem } from "./selectors";

type ResearchObservation = {
  eventId: string;
  source: string;
  target: string;
  operation: string;
  receivedAt: string;
  observedAt: string;
  sequence: number;
  sourceId?: string;
  taskId?: string;
  correlationId?: string;
  [key: string]: unknown;
};
export type ResearchViewProps = {
  items: TrackedItem[];
  sessions: TrackedItem[];
  observations: ResearchObservation[];
  ownershipLive: boolean;
  onSelect: (item: TrackedItem) => void;
  onPacket: (packet: ResearchObservation) => void;
};

type Issue = { repository: string; number: number; url: string };
export type ImportSelection = {
  intakeId: string;
  requestDigest: string;
  issue: Issue;
};
type ImportReference = {
  schema: "hi/agamemnon/research-import/v1";
  intakeId: string;
  requestDigest: string;
};
type ImportReceipt = {
  schema: "hi/agamemnon/research-import-receipt/v1";
  taskId: string;
  state: string;
  provenance: {
    schema: "hi/agamemnon/research-intake/v1";
    namespace: string;
    intakeId: string;
    requestDigest: string;
    bodyDigest: string;
    generation: 1;
    attemptId: string;
    issue: Issue;
    createdAt: string;
    confirmedAt: string;
  };
  issue: Issue;
  routing: { domain: "research"; hmasRole: "task-agent"; stage: "research" };
};
type RetainedImport = {
  schema: "hi/odysseus/research-import/v1";
  reference: ImportReference;
  issue: Issue;
  receipt: ImportReceipt | null;
  outcome?: "unknown" | "confirmed" | "conflict";
};
type Claim = {
  targetKind: "sessions" | "executions" | "build-jobs";
  targetId: string;
  workerId: string;
  agentId: string;
  generation: number;
};
type Owner = Claim & {
  status: string;
  claimStatus: string;
  sessionId?: string;
  executionId?: string;
};
type ManualResolution = {
  provenance: "manual";
  verifiedApproval: false;
  outcome: "completed" | "failed";
  decision: "approve_completion" | "reject_completion";
};
type TaskStatus = {
  taskId: string;
  state: string;
  assignment: { agentId: string } | null;
  claim: Claim | null;
  owner: Owner | null;
  resolution: ManualResolution | null;
};
const storageKey = "odysseus.research-import.v1";
const plain = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const matches = (value: unknown, pattern: RegExp): value is string =>
  typeof value === "string" && pattern.test(value);
const identifier = (value: unknown): value is string =>
  matches(value, /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/);
function validClaim(value: unknown): value is Claim {
  return (
    plain(value) &&
    Object.keys(value).length === 5 &&
    typeof value.targetKind === "string" &&
    ["sessions", "executions", "build-jobs"].includes(value.targetKind) &&
    identifier(value.targetId) &&
    identifier(value.workerId) &&
    typeof value.agentId === "string" &&
    value.agentId.length > 0 &&
    new TextEncoder().encode(value.agentId).length <= 1024 &&
    typeof value.generation === "number" &&
    Number.isSafeInteger(value.generation) &&
    value.generation >= 1
  );
}
function validOwner(
  value: unknown,
  claim: Claim | null,
): value is Owner | null {
  if (claim === null) return value === null;
  return (
    plain(value) &&
    (Object.keys(claim) as (keyof Claim)[]).every(
      (key) => value[key] === claim[key],
    ) &&
    typeof value.status === "string" &&
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
    ].includes(value.status) &&
    typeof value.claimStatus === "string" &&
    ["unclaimed", "reserved", "claimed", "released"].includes(
      value.claimStatus,
    ) &&
    (value.sessionId === undefined || identifier(value.sessionId)) &&
    (value.executionId === undefined || identifier(value.executionId)) &&
    (claim.targetKind !== "sessions" ||
      value.sessionId === undefined ||
      value.sessionId === claim.targetId) &&
    (claim.targetKind !== "executions" ||
      value.executionId === undefined ||
      value.executionId === claim.targetId)
  );
}
function validResolution(
  value: unknown,
  claim: Claim | null,
  state: unknown,
): value is ManualResolution | null {
  if (value === null) return true;
  return (
    claim !== null &&
    plain(value) &&
    Object.keys(value).length === 4 &&
    value.provenance === "manual" &&
    value.verifiedApproval === false &&
    ((state === "Completed" &&
      value.outcome === "completed" &&
      value.decision === "approve_completion") ||
      (state === "Failed" &&
        value.outcome === "failed" &&
        value.decision === "reject_completion"))
  );
}
function validIssue(value: unknown): value is Issue {
  return (
    plain(value) &&
    Object.keys(value).length === 3 &&
    matches(value.repository, /^[a-z0-9_-]+\/[a-z0-9_.-]+$/) &&
    value.repository.length <= 200 &&
    !value.repository.includes("..") &&
    typeof value.number === "number" &&
    Number.isSafeInteger(value.number) &&
    value.number > 0 &&
    value.number <= 2147483647 &&
    value.url ===
      `https://github.com/${value.repository}/issues/${value.number}`
  );
}
const sameIssue = (left: Issue, right: Issue) =>
  left.repository === right.repository &&
  left.number === right.number &&
  left.url === right.url;
const sameSelection = (value: RetainedImport, selection: ImportSelection) =>
  value.reference.intakeId === selection.intakeId &&
  value.reference.requestDigest === selection.requestDigest &&
  sameIssue(value.issue, selection.issue);
const unresolved = (value: RetainedImport) =>
  !value.receipt || value.outcome === "unknown" || value.outcome === "conflict";
const sameProvenance = (
  left: ImportReceipt["provenance"],
  right: ImportReceipt["provenance"],
) =>
  sameIssue(left.issue, right.issue) &&
  (Object.keys(left) as (keyof typeof left)[]).every(
    (key) => key === "issue" || left[key] === right[key],
  );
function readRetained(): RetainedImport | null {
  const raw = localStorage.getItem(storageKey);
  if (raw === null) return null;
  if (raw.length > 16384) throw new Error("invalid import storage");
  const value: unknown = JSON.parse(raw);
  if (
    !plain(value) ||
    !Object.keys(value).every((key) =>
      ["schema", "reference", "issue", "receipt", "outcome"].includes(key),
    ) ||
    value.schema !== "hi/odysseus/research-import/v1" ||
    !plain(value.reference) ||
    Object.keys(value.reference).length !== 3 ||
    value.reference.schema !== "hi/agamemnon/research-import/v1" ||
    !matches(value.reference.intakeId, /^[a-z0-9][a-z0-9_-]{7,63}$/) ||
    !matches(value.reference.requestDigest, /^[a-f0-9]{64}$/) ||
    !validIssue(value.issue) ||
    (value.receipt !== null && !plain(value.receipt)) ||
    (value.outcome !== undefined &&
      (typeof value.outcome !== "string" ||
        !["unknown", "confirmed", "conflict"].includes(value.outcome)))
  )
    throw new Error("invalid import storage");
  return value as RetainedImport;
}
function retain(value: RetainedImport) {
  const serialized = JSON.stringify(value);
  localStorage.setItem(storageKey, serialized);
  if (localStorage.getItem(storageKey) !== serialized)
    throw new Error("import storage write failed");
}
async function receiptFor(
  value: unknown,
  selection: ImportSelection,
  status: number,
): Promise<ImportReceipt | null> {
  if (!plain(value)) return null;
  const provenance = value.provenance;
  if (
    value.schema !== "hi/agamemnon/research-import-receipt/v1" ||
    !matches(value.taskId, /^research-[a-f0-9]{64}$/) ||
    typeof value.state !== "string" ||
    ![
      "Pending",
      "Decomposing",
      "Delegated",
      "InProgress",
      "Escalated",
      "Completed",
      "Failed",
    ].includes(value.state) ||
    (status === 201 && value.state !== "Pending") ||
    !validIssue(value.issue) ||
    !sameIssue(value.issue, selection.issue) ||
    !plain(provenance) ||
    provenance.schema !== "hi/agamemnon/research-intake/v1" ||
    !matches(provenance.namespace, /^[a-z0-9][a-z0-9_-]{0,63}$/) ||
    provenance.intakeId !== selection.intakeId ||
    provenance.requestDigest !== selection.requestDigest ||
    !matches(provenance.bodyDigest, /^[a-f0-9]{64}$/) ||
    provenance.generation !== 1 ||
    !matches(provenance.attemptId, /^[a-f0-9]{32}$/) ||
    !validIssue(provenance.issue) ||
    !sameIssue(provenance.issue, selection.issue) ||
    !matches(provenance.createdAt, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/) ||
    !matches(provenance.confirmedAt, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/) ||
    !plain(value.routing) ||
    value.routing.domain !== "research" ||
    value.routing.hmasRole !== "task-agent" ||
    value.routing.stage !== "research"
  )
    return null;
  const bytes = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(
      JSON.stringify({
        intakeId: provenance.intakeId,
        namespace: provenance.namespace,
        schema: "hi/agamemnon/research-task-key/v1",
      }),
    ),
  );
  const taskId =
    "research-" +
    Array.from(new Uint8Array(bytes), (byte) =>
      byte.toString(16).padStart(2, "0"),
    ).join("");
  return value.taskId === taskId ? (value as ImportReceipt) : null;
}
async function validateRetained(
  value: RetainedImport,
  selection: ImportSelection,
) {
  if (
    !sameSelection(value, selection) ||
    (value.receipt && !(await receiptFor(value.receipt, selection, 200)))
  )
    throw new Error("retained import conflicts with selection");
}

// Called only inside the parent's existing intake lock, before New intake.
export async function clearResolvedImport(selection: ImportSelection) {
  const value = readRetained();
  if (!value) return;
  await validateRetained(value, selection);
  if (unresolved(value)) throw new Error("import requires reconciliation");
  localStorage.removeItem(storageKey);
  if (localStorage.getItem(storageKey) !== null)
    throw new Error("import storage removal failed");
}

export function ResearchImport({
  enabled,
  busy,
  selection,
  withSelectionLock,
  onBusyChange,
  onUnresolvedChange,
  items,
  sessions,
  observations,
  ownershipLive,
  onSelect,
  onPacket,
}: {
  enabled: boolean;
  busy: boolean;
  selection: ImportSelection;
  withSelectionLock: (action: () => Promise<void>) => Promise<void>;
  onBusyChange: (value: boolean) => void;
  onUnresolvedChange: (value: boolean) => void;
} & ResearchViewProps) {
  const [operation, setOperation] = useState<RetainedImport | null>(null);
  const [message, setMessage] = useState("No research task imported.");
  const [error, setError] = useState("");
  const [task, setTask] = useState<TaskStatus | null>(null);
  const sending = useRef(false);
  useEffect(() => {
    let active = true;
    async function restore() {
      try {
        const current = readRetained();
        if (current) await validateRetained(current, selection);
        if (!active || sending.current) return;
        setOperation(current);
        setTask(null);
        onUnresolvedChange(Boolean(current && unresolved(current)));
        setMessage(
          current?.outcome === "conflict"
            ? "Import conflict. Reconciliation is required before replacing this selection."
            : current && unresolved(current)
              ? "Import outcome unknown. Retry the same import explicitly."
              : current?.receipt
                ? `Last confirmed task state: ${current.receipt.state}.`
                : current
                  ? "Import outcome unknown. Retry the same import explicitly."
                  : "No research task imported.",
        );
      } catch {
        if (!active) return;
        onUnresolvedChange(true);
        setError(
          "Browser storage or the selected import could not be verified. Reconciliation is required before importing or replacing it.",
        );
      }
    }
    void restore();
    const changed = (event: StorageEvent) => {
      if (event.key === storageKey || event.key === null) void restore();
    };
    window.addEventListener("storage", changed);
    return () => {
      active = false;
      window.removeEventListener("storage", changed);
    };
  }, [selection.intakeId, selection.requestDigest, selection.issue.url]);

  function conflict(intent: RetainedImport) {
    const changed = { ...intent, outcome: "conflict" as const };
    onUnresolvedChange(true);
    setTask(null);
    retain(changed);
    setOperation(changed);
    setMessage(
      "Import conflict. Keep the reference unchanged; reconciliation is required before replacement.",
    );
  }

  async function submit() {
    if (sending.current || busy || !enabled) return;
    sending.current = true;
    onBusyChange(true);
    setError("");
    try {
      await withSelectionLock(async () => {
        const current = readRetained();
        if (current) await validateRetained(current, selection);
        if (JSON.stringify(current) !== JSON.stringify(operation)) {
          setOperation(current);
          onUnresolvedChange(Boolean(current && unresolved(current)));
          setMessage(
            "Another view changed the retained import. Inspect it before retrying.",
          );
          return;
        }
        const intent: RetainedImport = {
          ...(current ?? {
            schema: "hi/odysseus/research-import/v1",
            reference: {
              schema: "hi/agamemnon/research-import/v1",
              intakeId: selection.intakeId,
              requestDigest: selection.requestDigest,
            },
            issue: selection.issue,
            receipt: null,
          }),
          outcome: "unknown",
        };
        retain(intent);
        setOperation(intent);
        setTask(null);
        onUnresolvedChange(true);
        setMessage("Submitting the retained import reference…");
        try {
          const response = await fetch("/api/research/imports", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(intent.reference),
            signal: AbortSignal.timeout(15000),
          });
          if (response.status !== 200 && response.status !== 201) {
            if (response.status === 409) {
              conflict(intent);
              return;
            }
            setMessage(
              response.status === 401
                ? "Import outcome unknown. Sign in again, then explicitly retry the same import."
                : "Import outcome unknown. Retry the same import explicitly.",
            );
            return;
          }
          const receipt = await receiptFor(
            await response.json(),
            selection,
            response.status,
          );
          if (
            !receipt ||
            (intent.receipt &&
              (receipt.taskId !== intent.receipt.taskId ||
                !sameProvenance(receipt.provenance, intent.receipt.provenance)))
          ) {
            conflict(intent);
            return;
          }
          const confirmed = {
            ...intent,
            receipt,
            outcome: "confirmed" as const,
          };
          retain(confirmed);
          setOperation(confirmed);
          onUnresolvedChange(false);
          setMessage(`Research task confirmed: ${receipt.state}.`);
        } catch {
          setMessage(
            "Import outcome unknown. The retained reference is unchanged; retry it explicitly.",
          );
        }
      });
    } catch {
      setError(
        "Browser storage, coordination or the retained selection could not be verified. No import request was sent. Reconcile it before retrying.",
      );
    } finally {
      sending.current = false;
      onBusyChange(false);
    }
  }

  async function refresh() {
    if (sending.current || busy || !enabled || !operation?.receipt) return;
    sending.current = true;
    onBusyChange(true);
    setError("");
    setTask(null);
    setMessage("Checking current task status…");
    try {
      await withSelectionLock(async () => {
        const current = readRetained();
        if (
          !current?.receipt ||
          JSON.stringify(current) !== JSON.stringify(operation)
        )
          throw new Error("retained selection changed");
        await validateRetained(current, selection);
        // Preserve a reconciliation guard before a read can reveal a conflict,
        // even if browser storage later becomes unwritable.
        const checking: RetainedImport = {
          ...current,
          outcome: current.outcome === "conflict" ? "conflict" : "unknown",
        };
        retain(checking);
        setOperation(checking);
        onUnresolvedChange(true);
        try {
          const response = await fetch(
            `/api/research/tasks/${current.receipt.taskId}`,
            {
              method: "GET",
              signal: AbortSignal.timeout(15000),
            },
          );
          if (response.status === 409) {
            conflict(checking);
            return;
          }
          if (!response.ok) throw new Error("task unavailable");
          const value: unknown = await response.json();
          if (
            !plain(value) ||
            value.schema !== "hi/odysseus/research-task/v1" ||
            value.layer !== "L3_TaskAgent" ||
            value.taskId !== current.receipt.taskId ||
            !(value.claim === null || validClaim(value.claim)) ||
            !validOwner(value.owner, value.claim as Claim | null) ||
            !validResolution(
              value.resolution,
              value.claim as Claim | null,
              value.state,
            ) ||
            !(
              value.assignment === null ||
              (plain(value.assignment) &&
                typeof value.assignment.agentId === "string" &&
                value.assignment.agentId.length > 0 &&
                value.assignment.agentId.length <= 1024)
            )
          ) {
            conflict(checking);
            return;
          }
          if (
            value.claim !== null &&
            (!plain(value.assignment) ||
              value.assignment.agentId !== (value.claim as Claim).agentId)
          ) {
            conflict(checking);
            return;
          }
          const identity = await receiptFor(
            {
              schema: "hi/agamemnon/research-import-receipt/v1",
              taskId: value.taskId,
              state: value.state,
              provenance: value.provenance,
              issue: value.issue,
              routing: current.receipt.routing,
            },
            selection,
            200,
          );
          if (
            !identity ||
            !sameProvenance(identity.provenance, current.receipt.provenance)
          ) {
            conflict(checking);
            return;
          }
          const confirmed: RetainedImport = {
            ...current,
            outcome: current.outcome === "conflict" ? "conflict" : "confirmed",
          };
          retain(confirmed);
          setOperation(confirmed);
          onUnresolvedChange(unresolved(confirmed));
          setTask({
            taskId: identity.taskId,
            state: identity.state,
            assignment: value.assignment as TaskStatus["assignment"],
            claim: value.claim as Claim | null,
            owner: value.owner as Owner | null,
            resolution: value.resolution as ManualResolution | null,
          });
          setMessage(
            `Current task state: ${identity.state}.${value.claim === null ? " No current owner claim." : ""}`,
          );
        } catch {
          setMessage(
            "Current task status and ownership are unavailable. The confirmed import receipt remains historical evidence.",
          );
        }
      });
    } catch {
      setMessage(
        "Current task status is unavailable. Browser storage or the retained selection could not be verified.",
      );
    } finally {
      sending.current = false;
      onBusyChange(false);
    }
  }

  const owner = task?.owner;
  const terminalClaim = Boolean(
    owner &&
    (["Completed", "Failed"].includes(task?.state ?? "") ||
      ["completed", "failed", "cancelled", "interrupted"].includes(
        owner.status,
      ) ||
      owner.claimStatus === "released"),
  );
  const candidate =
    task &&
    owner &&
    ownershipLive &&
    !terminalClaim &&
    owner.claimStatus === "claimed" &&
    owner.targetKind !== "build-jobs"
      ? matchPacket(
          items.filter((item) => item.kind === "session"),
          {
            taskId: task.taskId,
            workerId: owner.workerId,
            agentId: owner.agentId,
            generation: owner.generation,
            ...(owner.targetKind === "sessions"
              ? { sessionId: owner.targetId }
              : {
                  executionId: owner.targetId,
                  ...(owner.sessionId ? { sessionId: owner.sessionId } : {}),
                }),
          },
        )
      : undefined;
  // The display item may combine execution metadata. Navigation also requires
  // the underlying session record to report the complete matching identity.
  const rawMatches =
    candidate && task && owner
      ? sessions.filter(
          (session) =>
            session.id === candidate.id &&
            session.taskId === task.taskId &&
            session.workerId === owner.workerId &&
            session.agentId === owner.agentId &&
            session.generation === owner.generation &&
            (owner.targetKind !== "executions" ||
              session.executionId === owner.targetId),
        )
      : [];
  const ownerSession =
    candidate &&
    owner &&
    rawMatches.length === 1 &&
    candidate.claimStatus === owner.claimStatus &&
    candidate.status === owner.status &&
    (owner.targetKind !== "sessions" || candidate.id === owner.targetId)
      ? candidate
      : undefined;
  const trace = observations
    .filter(
      (packet) =>
        packet.correlationId === selection.intakeId ||
        (operation?.receipt && packet.taskId === operation.receipt.taskId),
    )
    .slice(-30)
    .reverse();

  if (!enabled && !operation) return null;
  return (
    <section className="research-status" aria-label="Research task">
      <h3>Research task</h3>
      <div className="research-actions">
        <button
          type="button"
          disabled={!enabled || busy}
          onClick={() => void submit()}
        >
          {operation ? "Retry same import" : "Import research task"}
        </button>
        {operation?.receipt && (
          <button
            type="button"
            disabled={!enabled || busy}
            onClick={() => void refresh()}
          >
            Refresh task status
          </button>
        )}
      </div>
      {error && (
        <p className="warning" role="alert">
          {error}
        </p>
      )}
      <div role="status" aria-label="Research task status">
        <strong>{message}</strong>
        {operation?.receipt && (
          <>
            <p className="mono">{operation.receipt.taskId}</p>
            <p>Confirmed import receipt: {operation.receipt.state}.</p>
          </>
        )}
        {task && <p>Read-only task status: {task.state}.</p>}
        {task?.resolution && (
          <p>
            Manual resolution: {task.resolution.outcome}. Approval is not
            verified.
          </p>
        )}
      </div>
      {operation?.receipt && (
        <section aria-label="Research task owner">
          <h3>Task ownership</h3>
          {task ? (
            <>
              <p>
                Retained assignment: {task.assignment?.agentId ?? "Unassigned"}.
              </p>
              {owner ? (
                <>
                  <p>
                    {terminalClaim
                      ? "Retained terminal claim."
                      : "Claim verified at the last task refresh."}
                  </p>
                  <dl>
                    <dt>Target</dt>
                    <dd>
                      {owner.targetKind} / {owner.targetId}
                    </dd>
                    <dt>Worker</dt>
                    <dd>{owner.workerId}</dd>
                    <dt>Agent</dt>
                    <dd>{owner.agentId}</dd>
                    <dt>Generation</dt>
                    <dd>{owner.generation}</dd>
                    <dt>Status</dt>
                    <dd>
                      {owner.status} / {owner.claimStatus}
                    </dd>
                  </dl>
                  <button
                    type="button"
                    disabled={busy || !ownerSession}
                    onClick={() => {
                      if (ownerSession) onSelect(ownerSession);
                    }}
                  >
                    Open owner session
                  </button>
                  {!ownerSession && (
                    <p>
                      Session navigation is unavailable without an exact current
                      session and generation.
                    </p>
                  )}
                </>
              ) : (
                <p>No current owner claim.</p>
              )}
            </>
          ) : (
            <p>
              Current task ownership is unavailable. Refresh task status to
              inspect it.
            </p>
          )}
          {!ownershipLive && (
            <p>Current Fleet ownership data is unavailable or stale.</p>
          )}
        </section>
      )}
      <section className="trace-panel" aria-label="Research task trace">
        <h3>Observed research messages</h3>
        <div className="trace-list">
          {trace.map((packet) => (
            <button
              type="button"
              className="trace-row"
              key={`${packet.sourceId ?? packet.source}:${packet.eventId}`}
              onClick={() => onPacket(packet)}
            >
              <span className="trace-dot" />
              <span>
                <strong>
                  {packet.source} → {packet.target}
                </strong>
                <small>
                  {packet.operation} · {packet.eventId}
                </small>
              </span>
            </button>
          ))}
          {!trace.length && (
            <p>No matching message observations are retained.</p>
          )}
        </div>
      </section>
      <p className="fine-print">
        Import records a task in Agamemnon. Worker admission and execution are
        separate.
      </p>
    </section>
  );
}
