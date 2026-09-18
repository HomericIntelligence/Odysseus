import { useEffect, useRef, useState } from "react";

type IntakeRequest = {
  schema: "hi/nestor/intake-request/v1";
  intakeId: string;
  workRepository: string;
  title: string;
  body: string;
};
type RetainedIntake = {
  schema: "hi/odysseus/intake-draft/v1";
  request: IntakeRequest;
  requestDigest: string;
};
type IntakeRecord = {
  intakeId: string;
  requestDigest: string;
  phase: "prepared" | "creating" | "created";
  issue?: { repository: string; number: number; url: string };
};
const storageKey = "odysseus.research-intake.v1";
const encoder = new TextEncoder();
const plain = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const text = (value: unknown, max: number): value is string =>
  typeof value === "string" &&
  !/[\uD800-\uDFFF]/u.test(value) &&
  encoder.encode(value).length <= max;
function validRequest(value: unknown): value is IntakeRequest {
  return (
    plain(value) &&
    Object.keys(value).length === 5 &&
    value.schema === "hi/nestor/intake-request/v1" &&
    typeof value.intakeId === "string" &&
    /^research-[a-f0-9]{32}$/.test(value.intakeId) &&
    text(value.workRepository, 200) &&
    /^[A-Za-z0-9_-]+\/[A-Za-z0-9_.-]+$/.test(value.workRepository) &&
    !value.workRepository.includes("..") &&
    text(value.title, 256) &&
    value.title.length > 0 &&
    text(value.body, 60000) &&
    !value.body.includes("nestor:fleet-intake:") &&
    encoder.encode(JSON.stringify(value)).length <= 65536
  );
}
async function digest(input: IntakeRequest) {
  const canonical = {
    body: input.body,
    intakeId: input.intakeId,
    schema: input.schema,
    title: input.title,
    workRepository: input.workRepository.toLowerCase(),
  };
  const result = await crypto.subtle.digest(
    "SHA-256",
    encoder.encode(JSON.stringify(canonical)),
  );
  return Array.from(new Uint8Array(result), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}
function readRetained(): RetainedIntake | null {
  const stored = localStorage.getItem(storageKey);
  if (stored === null) return null;
  const value: unknown = JSON.parse(stored);
  if (
    !plain(value) ||
    Object.keys(value).length !== 3 ||
    value.schema !== "hi/odysseus/intake-draft/v1" ||
    !validRequest(value.request) ||
    typeof value.requestDigest !== "string" ||
    !/^[a-f0-9]{64}$/.test(value.requestDigest)
  )
    throw new Error("invalid retained intake");
  return value as RetainedIntake;
}
function recordFor(
  value: unknown,
  retained: RetainedIntake,
): IntakeRecord | null {
  if (
    !plain(value) ||
    value.schema !== "hi/nestor/intake/v1" ||
    value.intakeId !== retained.request.intakeId ||
    value.requestDigest !== retained.requestDigest ||
    value.workRepository !== retained.request.workRepository.toLowerCase() ||
    value.generation !== 1 ||
    !["prepared", "creating", "created"].includes(String(value.phase))
  )
    return null;
  if (value.phase === "created") {
    const issue = value.issue;
    if (
      !plain(issue) ||
      issue.repository !== value.workRepository ||
      !Number.isSafeInteger(issue.number) ||
      Number(issue.number) <= 0 ||
      issue.url !==
        `https://github.com/${value.workRepository}/issues/${issue.number}` ||
      !plain(value.receipt) ||
      value.receipt.kind !== "confirmed_issue"
    )
      return null;
  } else if (value.issue !== undefined || value.receipt !== undefined)
    return null;
  return value as IntakeRecord;
}

export function ResearchIntake() {
  const [enabled, setEnabled] = useState(false);
  const [capability, setCapability] = useState("Checking intake availability…");
  const [workRepository, setRepository] = useState("");
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [retained, setRetained] = useState<RetainedIntake | null>(null);
  const [record, setRecord] = useState<IntakeRecord | null>(null);
  const [message, setMessage] = useState("No intake submitted.");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const sending = useRef(false);
  useEffect(() => {
    try {
      const prior = readRetained();
      if (prior) {
        setRetained(prior);
        setMessage(
          "Outcome unknown. Check status or retry this retained intake unchanged.",
        );
      }
    } catch {
      setError(
        "Browser storage is unavailable or the retained intake is invalid. Resolve it before submitting; no request was sent.",
      );
    }
    const abort = new AbortController();
    void fetch("/api/capabilities", { signal: abort.signal })
      .then(async (response) => {
        if (!response.ok) throw new Error("unavailable");
        const value = await response.json();
        if (!abort.signal.aborted) {
          setEnabled(value.researchIntake?.enabled === true);
          setCapability(
            value.researchIntake?.enabled === true
              ? "Nestor intake is configured."
              : "Research intake is not configured on this backend.",
          );
        }
      })
      .catch(() => {
        if (!abort.signal.aborted)
          setCapability(
            "Intake availability is unknown. Sign in again or reload to retry.",
          );
      });
    return () => abort.abort();
  }, []);

  async function exchange(intent: RetainedIntake, inspect: boolean) {
    setRecord(null);
    setMessage(
      inspect
        ? "Checking Nestor's durable intake record…"
        : "Submitting the retained intake to Nestor…",
    );
    try {
      const response = await fetch(
        inspect
          ? `/api/research/intakes/${intent.request.intakeId}?requestDigest=${intent.requestDigest}`
          : "/api/research/intakes",
        {
          method: inspect ? "GET" : "POST",
          ...(inspect
            ? {}
            : {
                headers: { "content-type": "application/json" },
                body: JSON.stringify(intent.request),
              }),
          signal: AbortSignal.timeout(15000),
        },
      );
      if (!response.ok) {
        setMessage(
          response.status === 409
            ? "Conflict. Keep this intake unchanged and reconcile it with the operator."
            : response.status === 401
              ? "Outcome unknown. Sign in again, then check this retained intake."
              : response.status === 404
                ? "Outcome unknown. Nestor has no confirmed record yet; retry the same intake."
                : "Outcome unknown. Check status or retry the same intake.",
        );
        return;
      }
      const result = recordFor((await response.json()).intake, intent);
      if (!result) throw new Error("unconfirmed receipt");
      setRecord(result);
      setMessage(
        result.phase === "created"
          ? "Issue confirmed by Nestor."
          : result.phase === "creating"
            ? "Creation is awaiting confirmation. Keep this intake unchanged."
            : "Intake prepared. Retry the same intake to continue its creation attempt.",
      );
    } catch {
      setMessage("Outcome unknown. Check status or retry the same intake.");
    }
  }

  async function operate(mode: "submit" | "inspect" | "new") {
    if (sending.current || !enabled) return;
    sending.current = true;
    setBusy(true);
    setError("");
    try {
      if (!navigator.locks)
        throw new Error("browser storage coordination unavailable");
      await navigator.locks.request(storageKey, async () => {
        const current = readRetained();
        if (retained) {
          if (
            JSON.stringify(current) !== JSON.stringify(retained) ||
            (await digest(retained.request)) !== retained.requestDigest
          )
            throw new Error("retained intake changed");
          if (mode === "new") {
            if (record?.phase !== "created")
              throw new Error("intake is unconfirmed");
            localStorage.removeItem(storageKey);
            if (localStorage.getItem(storageKey) !== null)
              throw new Error("storage write failed");
            setRetained(null);
            setRecord(null);
            setRepository("");
            setTitle("");
            setBody("");
            setMessage("No intake submitted.");
          } else await exchange(retained, mode === "inspect");
          return;
        }
        if (current) {
          setRetained(current);
          setMessage(
            "Another view retained an intake. Check its status before continuing.",
          );
          return;
        }
        const request: IntakeRequest = {
          schema: "hi/nestor/intake-request/v1",
          intakeId: `research-${crypto.randomUUID().replaceAll("-", "")}`,
          workRepository,
          title,
          body,
        };
        if (!validRequest(request)) {
          setError(
            "Enter a repository, a title up to 256 UTF-8 bytes, and publishable requirements up to 60,000 bytes without reserved intake markers.",
          );
          return;
        }
        const intent: RetainedIntake = {
          schema: "hi/odysseus/intake-draft/v1",
          request,
          requestDigest: await digest(request),
        };
        const serialized = JSON.stringify(intent);
        localStorage.setItem(storageKey, serialized);
        if (localStorage.getItem(storageKey) !== serialized)
          throw new Error("storage write failed");
        setRetained(intent);
        await exchange(intent, false);
      });
    } catch {
      setError(
        "Browser storage or its retained intake could not be verified. No new request was sent. Reload to inspect the retained request; do not replace an uncertain intake.",
      );
    } finally {
      sending.current = false;
      setBusy(false);
    }
  }

  return (
    <section className="panel research-panel" aria-label="Research intake">
      <div className="panel-heading">
        <div>
          <h2>Start with an idea</h2>
          <p>Record publishable research requirements through Nestor.</p>
        </div>
      </div>
      <div className="research-content">
        <p>{capability}</p>
        <p className="fine-print">
          The title and requirements will be published to the work repository's
          GitHub issue. This browser retains the exact request across reloads
          for safe retries. Keep credentials and private interviews out of this
          form.
        </p>
        <form
          onSubmit={(event) => {
            event.preventDefault();
            void operate("submit");
          }}
        >
          <label htmlFor="research-repository">Work repository</label>
          <input
            id="research-repository"
            placeholder="HomericIntelligence/Odysseus"
            value={retained?.request.workRepository ?? workRepository}
            disabled={Boolean(retained) || busy}
            onChange={(e) => setRepository(e.target.value)}
            required
          />
          <label htmlFor="research-title">Research title</label>
          <input
            id="research-title"
            value={retained?.request.title ?? title}
            disabled={Boolean(retained) || busy}
            onChange={(e) => setTitle(e.target.value)}
            required
          />
          <label htmlFor="research-body">Publishable requirements</label>
          <textarea
            id="research-body"
            rows={7}
            value={retained?.request.body ?? body}
            disabled={Boolean(retained) || busy}
            onChange={(e) => setBody(e.target.value)}
          />
          <div className="research-actions">
            {!retained && (
              <button
                className="primary"
                type="submit"
                disabled={!enabled || busy}
              >
                Submit research intake
              </button>
            )}
            {retained && (
              <>
                <button
                  type="button"
                  disabled={!enabled || busy}
                  onClick={() => void operate("inspect")}
                >
                  Check intake status
                </button>
                {record?.phase === "created" ? (
                  <button
                    type="button"
                    disabled={!enabled || busy}
                    onClick={() => void operate("new")}
                  >
                    New research intake
                  </button>
                ) : (
                  <button
                    type="button"
                    disabled={!enabled || busy}
                    onClick={() => void operate("submit")}
                  >
                    Retry same intake
                  </button>
                )}
              </>
            )}
          </div>
        </form>
        {error && (
          <p className="warning" role="alert">
            {error}
          </p>
        )}
        <div
          className="research-status"
          role="status"
          aria-label="Research intake status"
        >
          <strong>{message}</strong>
          {retained && <p className="mono">{retained.request.intakeId}</p>}
          {record?.phase === "created" && record.issue && (
            <p>
              <a href={record.issue.url} target="_blank" rel="noreferrer">
                Open research issue
              </a>
            </p>
          )}
        </div>
        <p className="fine-print">
          Research dispatch is not implemented by this intake endpoint.
        </p>
      </div>
    </section>
  );
}
