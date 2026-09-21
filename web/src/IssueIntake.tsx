import { useEffect, useRef, useState } from "react";
import {
  ImportedTaskOwner,
  ImportedTaskTrace,
  importedTaskStatus,
} from "./ResearchImport";
import type { ResearchViewProps, TaskStatus } from "./ResearchImport";

type Repository = { key: string; repository: string; repositoryId: string };
type Issue = { repository: string; number: number; url: string };
type Plan =
  | { kind: "issue_body"; digest: string }
  | { kind: "issue_comment"; nodeId: string; digest: string };
type Inspection = {
  schema: "hi/agamemnon/issue-inspection/v1";
  repositoryKey: string;
  repositoryId: string;
  issueId: string;
  issue: Issue;
  title: string;
  state: "open" | "closed";
  plan: Plan;
  observedAt: string;
};
type Reference = {
  schema: "hi/agamemnon/issue-import/v1";
  repositoryKey: string;
  issueNumber: number;
  repositoryId: string;
  issueId: string;
  plan: Plan;
};
type Provenance = {
  schema: "hi/agamemnon/issue-intake/v1";
  forge: "github";
  repositoryId: string;
  issueId: string;
  issue: Issue;
  plan: Plan;
  routing: Routing;
  observedAt: string;
};
type Routing = {
  domain: "pipeline";
  hmasRole: "task-agent";
  stage: "implementation";
};
type Receipt = {
  schema: "hi/agamemnon/issue-import-receipt/v1";
  taskId: string;
  state: string;
  provenance: Provenance;
  issue: Issue;
  routing: Routing;
};
type Retained = {
  schema: "hi/odysseus/issue-import/v1";
  reference: Reference;
  inspection: Inspection;
  receipt: Receipt | null;
  outcome: "selected" | "unknown" | "confirmed" | "conflict";
};
const storageKey = "odysseus.issue-import.v1";
const encoder = new TextEncoder();
const states = [
  "Pending",
  "Decomposing",
  "Delegated",
  "InProgress",
  "Escalated",
  "Completed",
  "Failed",
];
const routing: Routing = {
  domain: "pipeline",
  hmasRole: "task-agent",
  stage: "implementation",
};
const plain = (v: unknown): v is Record<string, unknown> =>
  v !== null && typeof v === "object" && !Array.isArray(v);
const keys = (v: unknown, names: string[]): v is Record<string, unknown> =>
  plain(v) &&
  Object.keys(v).length === names.length &&
  names.every((name) => Object.hasOwn(v, name));
const text = (v: unknown, max: number): v is string =>
  typeof v === "string" &&
  v.length > 0 &&
  !/[\uD800-\uDFFF]/u.test(v) &&
  encoder.encode(v).length <= max;
const native = (v: unknown): v is string => text(v, 128);
const key = (v: unknown): v is string =>
  typeof v === "string" && /^[a-z0-9][a-z0-9_-]{0,63}$/.test(v);
const number = (v: unknown): v is number =>
  typeof v === "number" && Number.isSafeInteger(v) && v >= 1 && v <= 2147483647;
const time = (v: unknown): v is string =>
  typeof v === "string" &&
  /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(v) &&
  Number.isFinite(Date.parse(v)) &&
  new Date(v).toISOString().replace(".000Z", "Z") === v;
function repository(v: unknown): v is Repository {
  return (
    keys(v, ["key", "repository", "repositoryId"]) &&
    key(v.key) &&
    native(v.repositoryId) &&
    text(v.repository, 255) &&
    /^[A-Za-z0-9_-]+\/[A-Za-z0-9_.-]+$/.test(v.repository) &&
    !v.repository.includes("..")
  );
}
function issue(v: unknown): v is Issue {
  return (
    keys(v, ["repository", "number", "url"]) &&
    text(v.repository, 255) &&
    /^[A-Za-z0-9_-]+\/[A-Za-z0-9_.-]+$/.test(v.repository) &&
    !v.repository.includes("..") &&
    number(v.number) &&
    v.url === `https://github.com/${v.repository}/issues/${v.number}`
  );
}
function plan(v: unknown): v is Plan {
  return (
    plain(v) &&
    ((keys(v, ["kind", "digest"]) && v.kind === "issue_body") ||
      (keys(v, ["kind", "nodeId", "digest"]) &&
        v.kind === "issue_comment" &&
        native(v.nodeId))) &&
    typeof v.digest === "string" &&
    /^[a-f0-9]{64}$/.test(v.digest)
  );
}
const samePlan = (a: Plan, b: Plan) =>
  a.kind === b.kind &&
  a.digest === b.digest &&
  (a.kind !== "issue_comment" ||
    (b.kind === "issue_comment" && a.nodeId === b.nodeId));
const sameIssue = (a: Issue, b: Issue) =>
  a.repository === b.repository && a.number === b.number && a.url === b.url;
const validRouting = (v: unknown): v is Routing =>
  keys(v, ["domain", "hmasRole", "stage"]) &&
  v.domain === routing.domain &&
  v.hmasRole === routing.hmasRole &&
  v.stage === routing.stage;
function inspection(v: unknown): v is Inspection {
  return (
    keys(v, [
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
    v.schema === "hi/agamemnon/issue-inspection/v1" &&
    key(v.repositoryKey) &&
    native(v.repositoryId) &&
    native(v.issueId) &&
    issue(v.issue) &&
    text(v.title, 1024) &&
    (v.state === "open" || v.state === "closed") &&
    plan(v.plan) &&
    time(v.observedAt)
  );
}
function reference(v: Inspection): Reference {
  return {
    schema: "hi/agamemnon/issue-import/v1",
    repositoryKey: v.repositoryKey,
    issueNumber: v.issue.number,
    repositoryId: v.repositoryId,
    issueId: v.issueId,
    plan: v.plan,
  };
}
function sameReference(a: unknown, b: Reference): boolean {
  return (
    keys(a, [
      "schema",
      "repositoryKey",
      "issueNumber",
      "repositoryId",
      "issueId",
      "plan",
    ]) &&
    a.schema === b.schema &&
    a.repositoryKey === b.repositoryKey &&
    a.issueNumber === b.issueNumber &&
    a.repositoryId === b.repositoryId &&
    a.issueId === b.issueId &&
    plan(a.plan) &&
    samePlan(a.plan, b.plan)
  );
}
function validProvenance(v: unknown, selected: Inspection): v is Provenance {
  return (
    keys(v, [
      "schema",
      "forge",
      "repositoryId",
      "issueId",
      "issue",
      "plan",
      "routing",
      "observedAt",
    ]) &&
    v.schema === "hi/agamemnon/issue-intake/v1" &&
    v.forge === "github" &&
    v.repositoryId === selected.repositoryId &&
    v.issueId === selected.issueId &&
    issue(v.issue) &&
    sameIssue(v.issue, selected.issue) &&
    plan(v.plan) &&
    samePlan(v.plan, selected.plan) &&
    validRouting(v.routing) &&
    time(v.observedAt)
  );
}
async function receiptFor(
  v: unknown,
  selected: Inspection,
  status: number,
): Promise<Receipt | null> {
  if (
    !keys(v, ["schema", "taskId", "state", "provenance", "issue", "routing"]) ||
    v.schema !== "hi/agamemnon/issue-import-receipt/v1" ||
    typeof v.state !== "string" ||
    !states.includes(v.state) ||
    (status !== 200 && status !== 201) ||
    (status === 201 && v.state !== "Pending") ||
    !validProvenance(v.provenance, selected) ||
    !issue(v.issue) ||
    !sameIssue(v.issue, selected.issue) ||
    !validRouting(v.routing)
  )
    return null;
  const digest = await crypto.subtle.digest(
    "SHA-256",
    encoder.encode(
      JSON.stringify({
        forge: "github",
        issueId: selected.issueId,
        repositoryId: selected.repositoryId,
        schema: "hi/agamemnon/issue-task-key/v1",
      }),
    ),
  );
  const taskId = `issue-${Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
  return v.taskId === taskId ? (v as Receipt) : null;
}
const sameReceiptIdentity = (a: Receipt, b: Receipt) =>
  a.taskId === b.taskId && a.provenance.observedAt === b.provenance.observedAt;
async function readRetained(): Promise<Retained | null> {
  const raw = localStorage.getItem(storageKey);
  if (raw === null) return null;
  if (encoder.encode(raw).length > 32768)
    throw new Error("invalid retained import");
  const value: unknown = JSON.parse(raw);
  if (
    !keys(value, ["schema", "reference", "inspection", "receipt", "outcome"]) ||
    value.schema !== "hi/odysseus/issue-import/v1" ||
    !inspection(value.inspection) ||
    !sameReference(value.reference, reference(value.inspection)) ||
    typeof value.outcome !== "string" ||
    !["selected", "unknown", "confirmed", "conflict"].includes(value.outcome) ||
    (value.receipt !== null &&
      !(await receiptFor(value.receipt, value.inspection, 200))) ||
    (value.outcome === "confirmed" && value.receipt === null) ||
    (value.outcome === "selected" && value.receipt !== null)
  )
    throw new Error("invalid retained import");
  return value as Retained;
}
function retain(value: Retained) {
  const raw = JSON.stringify(value);
  localStorage.setItem(storageKey, raw);
  if (localStorage.getItem(storageKey) !== raw)
    throw new Error("storage write failed");
}
async function readJson(response: Response): Promise<unknown> {
  if (!response.body) throw new Error("empty response");
  const reader = response.body.getReader();
  const parts: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      total += value.length;
      if (total > 65536) throw new Error("response too large");
      parts.push(value);
    }
    const joined = new Uint8Array(total);
    let offset = 0;
    for (const part of parts) {
      joined.set(part, offset);
      offset += part.length;
    }
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(joined));
  } finally {
    await reader.cancel();
  }
}

export function IssueIntake({
  enabled,
  ...view
}: { enabled: boolean } & ResearchViewProps) {
  const [repositories, setRepositories] = useState<Repository[]>([]);
  const [repositoryKey, setRepositoryKey] = useState("");
  const [issueNumber, setIssueNumber] = useState("");
  const [comment, setComment] = useState("");
  const [operation, setOperation] = useState<Retained | null>(null);
  const [task, setTask] = useState<TaskStatus | null>(null);
  const [message, setMessage] = useState(
    "Choose a registered repository and inspect an issue.",
  );
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const sending = useRef(false);
  useEffect(() => {
    let active = true;
    void readRetained()
      .then((prior) => {
        if (!active || !prior) return;
        setOperation(prior);
        setRepositoryKey(prior.reference.repositoryKey);
        setIssueNumber(String(prior.reference.issueNumber));
        setComment(
          prior.inspection.plan.kind === "issue_comment"
            ? prior.inspection.plan.nodeId
            : "",
        );
        setMessage(
          prior.outcome === "selected"
            ? "Issue inspected. Import requires an explicit action."
            : prior.outcome === "confirmed"
              ? "Confirmed import receipt retained. Refresh for current ownership."
              : "Outcome unknown or conflicting. Keep this selection and retry the same import.",
        );
      })
      .catch(() => {
        if (active)
          setError(
            "Browser storage is unavailable or invalid. Reconcile the retained import before continuing.",
          );
      });
    return () => {
      active = false;
    };
  }, []);
  useEffect(() => {
    if (!enabled) return;
    const abort = new AbortController();
    void (async () => {
      const response = await fetch("/api/issue-intakes/repositories", {
        signal: AbortSignal.any([abort.signal, AbortSignal.timeout(15000)]),
      });
      const value = await readJson(response);
      if (
        !response.ok ||
        !keys(value, ["schema", "repositories"]) ||
        value.schema !== "hi/agamemnon/issue-repositories/v1" ||
        !Array.isArray(value.repositories) ||
        value.repositories.length < 1 ||
        value.repositories.length > 64 ||
        !value.repositories.every(repository)
      )
        throw new Error("registry unavailable");
      const entries = value.repositories;
      if (
        ["key", "repositoryId", "repository"].some(
          (field) =>
            new Set(
              entries.map((entry) =>
                field === "repository"
                  ? entry.repository.toLowerCase()
                  : entry[field as keyof Repository],
              ),
            ).size !== entries.length,
        )
      )
        throw new Error("ambiguous registry");
      if (!abort.signal.aborted) setRepositories(entries);
    })().catch(() => {
      if (!abort.signal.aborted)
        setMessage("Registered repositories are unavailable. Reload to retry.");
    });
    return () => abort.abort();
  }, [enabled]);
  const selectedRepository = repositories.find(
    (entry) => entry.key === repositoryKey,
  );
  const locked = operation !== null && operation.outcome !== "selected";
  const validNumber =
    /^[1-9][0-9]{0,9}$/.test(issueNumber) && number(Number(issueNumber));
  const registered =
    operation &&
    repositories.some(
      (entry) =>
        entry.key === operation.reference.repositoryKey &&
        entry.repositoryId === operation.reference.repositoryId &&
        entry.repository === operation.inspection.issue.repository,
    );
  const unchangedForm =
    operation &&
    repositoryKey === operation.reference.repositoryKey &&
    Number(issueNumber) === operation.reference.issueNumber &&
    comment ===
      (operation.inspection.plan.kind === "issue_comment"
        ? operation.inspection.plan.nodeId
        : "");
  async function withLock(action: (current: Retained | null) => Promise<void>) {
    if (sending.current) return;
    sending.current = true;
    setBusy(true);
    try {
      if (!navigator.locks) throw new Error("coordination unavailable");
      await navigator.locks.request(
        storageKey,
        { ifAvailable: true },
        async (lock) => {
          const current = await readRetained();
          if (!lock || JSON.stringify(current) !== JSON.stringify(operation))
            throw new Error("selection changed or busy");
          await action(current);
        },
      );
    } catch {
      setError(
        "Browser storage or selection coordination failed. Keep the retained import; its outcome may be unknown.",
      );
    } finally {
      sending.current = false;
      setBusy(false);
    }
  }
  async function inspect() {
    if (
      !enabled ||
      error ||
      locked ||
      !selectedRepository ||
      !validNumber ||
      (comment !== "" && !native(comment))
    )
      return;
    await withLock(async (current) => {
      try {
        const response = await fetch(
          `/api/issue-intakes/${encodeURIComponent(repositoryKey)}/${issueNumber}${comment ? `?planCommentId=${encodeURIComponent(comment)}` : ""}`,
          { signal: AbortSignal.timeout(45000) },
        );
        const value = await readJson(response);
        if (
          !response.ok ||
          !inspection(value) ||
          value.repositoryKey !== selectedRepository.key ||
          value.repositoryId !== selectedRepository.repositoryId ||
          value.issue.repository !== selectedRepository.repository ||
          value.issue.number !== Number(issueNumber) ||
          (comment
            ? value.plan.kind !== "issue_comment" ||
              value.plan.nodeId !== comment
            : value.plan.kind !== "issue_body")
        )
          throw new Error("inspection unavailable");
        if (JSON.stringify(await readRetained()) !== JSON.stringify(current))
          throw new Error("selection changed");
        const next: Retained = {
          schema: "hi/odysseus/issue-import/v1",
          reference: reference(value),
          inspection: value,
          receipt: null,
          outcome: "selected",
        };
        retain(next);
        setOperation(next);
        setTask(null);
        setMessage(
          "Issue inspected. Import requires an explicit action; inspection does not approve the plan.",
        );
      } catch {
        setMessage(
          "Inspection is unavailable or changed. No import was submitted.",
        );
      }
    });
  }
  async function submit() {
    if (!enabled || error || !registered || !unchangedForm || !operation)
      return;
    await withLock(async (current) => {
      if (!current) return;
      const pending: Retained = { ...current, outcome: "unknown" };
      retain(pending);
      setOperation(pending);
      setTask(null);
      setMessage("Import outcome is pending. Keep this selection unchanged.");
      try {
        const response = await fetch("/api/issue-intakes", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(pending.reference),
          signal: AbortSignal.timeout(45000),
        });
        const value = await readJson(response);
        const confirmed = response.ok
          ? await receiptFor(value, pending.inspection, response.status)
          : null;
        if (JSON.stringify(await readRetained()) !== JSON.stringify(pending))
          throw new Error("selection changed");
        if (
          !confirmed ||
          (current.receipt && !sameReceiptIdentity(confirmed, current.receipt))
        ) {
          const failed: Retained = {
            ...pending,
            outcome:
              response.status === 409 || (response.ok && current.receipt)
                ? "conflict"
                : "unknown",
          };
          retain(failed);
          setOperation(failed);
          setMessage(
            failed.outcome === "conflict"
              ? "Conflict. Keep this selection and reconcile the import with the operator."
              : "Outcome unknown. Retry the same import; do not select another issue.",
          );
          return;
        }
        const next: Retained = {
          ...pending,
          receipt: confirmed,
          outcome: "confirmed",
        };
        retain(next);
        setOperation(next);
        setMessage(
          "Import confirmed by Agamemnon. Worker admission and execution are separate.",
        );
      } catch {
        setMessage(
          "Outcome unknown. Keep this selection and retry the same import.",
        );
      }
    });
  }
  async function refresh() {
    if (!enabled || error || !operation?.receipt) return;
    await withLock(async (current) => {
      if (!current?.receipt) return;
      setTask(null);
      try {
        const response = await fetch(`/api/tasks/${current.receipt.taskId}`, {
          signal: AbortSignal.timeout(15000),
        });
        const value = await readJson(response);
        const projected = importedTaskStatus(
          value,
          "hi/odysseus/imported-task/v1",
          current.receipt.taskId,
        );
        const identity = plain(value)
          ? await receiptFor(
              {
                schema: "hi/agamemnon/issue-import-receipt/v1",
                taskId: value.taskId,
                state: value.state,
                provenance: value.provenance,
                issue: value.issue,
                routing,
              },
              current.inspection,
              200,
            )
          : null;
        if (
          !response.ok ||
          !projected ||
          !identity ||
          !sameReceiptIdentity(identity, current.receipt) ||
          JSON.stringify(await readRetained()) !== JSON.stringify(current)
        )
          throw new Error("status unavailable");
        setTask(projected);
        setMessage(
          `Current task state: ${projected.state}.${projected.claim ? "" : " No current owner claim."}`,
        );
      } catch {
        setMessage(
          "Current task status and ownership are unavailable. The retained receipt remains historical evidence.",
        );
      }
    });
  }
  async function chooseAnother() {
    if (error || operation?.outcome !== "confirmed") return;
    await withLock(async (current) => {
      if (!current?.receipt || current.outcome !== "confirmed") return;
      localStorage.removeItem(storageKey);
      if (localStorage.getItem(storageKey) !== null)
        throw new Error("storage clear failed");
      setOperation(null);
      setTask(null);
      setRepositoryKey("");
      setIssueNumber("");
      setComment("");
      setMessage("Choose a registered repository and inspect an issue.");
    });
  }
  return (
    <section className="panel research-panel" aria-label="Planned issue intake">
      <div className="research-content">
        <h2>Import a planned issue</h2>
        <p>
          Agamemnon records the existing issue as a task. Import does not
          approve the plan or start a worker.
        </p>
        {!enabled && (
          <p>Planned issue import is not configured on this backend.</p>
        )}
        <form
          onSubmit={(event) => {
            event.preventDefault();
            void inspect();
          }}
        >
          <label>
            Planned issue repository
            <select
              value={repositoryKey}
              disabled={!enabled || busy || locked || !!error}
              onChange={(event) => setRepositoryKey(event.target.value)}
            >
              <option value="">Select a registered repository</option>
              {repositories.map((entry) => (
                <option key={entry.key} value={entry.key}>
                  {entry.repository}
                </option>
              ))}
            </select>
          </label>
          <label>
            Issue number
            <input
              value={issueNumber}
              inputMode="numeric"
              disabled={!enabled || busy || locked || !!error}
              onChange={(event) => setIssueNumber(event.target.value)}
            />
          </label>
          <label>
            Plan comment ID (optional)
            <input
              value={comment}
              disabled={!enabled || busy || locked || !!error}
              onChange={(event) => setComment(event.target.value)}
            />
          </label>
          <button
            type="submit"
            disabled={
              !enabled ||
              busy ||
              locked ||
              !!error ||
              !selectedRepository ||
              !validNumber ||
              (comment !== "" && !native(comment))
            }
          >
            Inspect planned issue
          </button>
        </form>
        {operation && (
          <div className="research-status">
            <h3>{operation.inspection.title}</h3>
            <p>
              <a
                href={operation.inspection.issue.url}
                target="_blank"
                rel="noreferrer"
              >
                Open planned issue
              </a>
            </p>
            <p>
              Inspected issue: {operation.inspection.state}. Plan source:{" "}
              {operation.inspection.plan.kind === "issue_body"
                ? "issue body"
                : "issue comment"}
              .
            </p>
            <button
              type="button"
              disabled={
                !enabled ||
                busy ||
                !!error ||
                !registered ||
                !unchangedForm ||
                (operation.outcome === "selected" &&
                  operation.inspection.state !== "open")
              }
              onClick={() => void submit()}
            >
              {operation.outcome === "selected"
                ? "Import planned issue"
                : "Retry same import"}
            </button>
            {operation.receipt && (
              <button
                type="button"
                disabled={!enabled || busy || !!error}
                onClick={() => void refresh()}
              >
                Refresh task status
              </button>
            )}
            {operation.outcome === "confirmed" && (
              <button
                type="button"
                disabled={busy || !!error}
                onClick={() => void chooseAnother()}
              >
                Choose another planned issue
              </button>
            )}
          </div>
        )}
        {error && (
          <p role="alert" className="warning">
            {error}
          </p>
        )}
        <div role="status" aria-label="Planned issue task status">
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
          <ImportedTaskOwner
            {...view}
            task={task}
            busy={busy}
            label="Planned issue task"
          />
        )}
        {operation && (
          <ImportedTaskTrace
            {...view}
            correlationId={operation.reference.issueId}
            taskId={operation.receipt?.taskId}
            label="Planned issue task"
          />
        )}
      </div>
    </section>
  );
}
