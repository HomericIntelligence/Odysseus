import { useEffect, useId, useRef, useState } from "react";
import "./SessionControls.css";

export type SessionControlItem = {
  id: string;
  kind: string;
  workerId?: string;
  generation?: number;
  historical?: boolean;
  claimStatus?: string;
  status?: string;
};

type Operation = "start" | "input" | "interrupt" | "cancel" | "resume";
type Command = {
  commandId: string;
  sessionId: string;
  workerId: string;
  generation: number;
  operation: Operation;
  text?: string;
};
type Capabilities = {
  key: string;
  enabled: boolean;
  operations: Operation[];
  inputWorkerIds: string[];
};
type Pending = {
  command: Readonly<Command>;
  phase: "sending" | "unknown" | "conflict";
};
type Receipt = {
  sessionId: string;
  commandId: string;
  operation: Operation;
  status: "submitted" | "invalid_request" | "not_configured";
};

const labels: Record<Operation, string> = {
  start: "Start session",
  input: "Send input",
  interrupt: "Request interruption",
  cancel: "Request cancellation",
  resume: "Resume session",
};
const operations = Object.keys(labels) as Operation[];
const identity = (item: SessionControlItem | null) =>
  item ? JSON.stringify([item.id, item.workerId, item.generation]) : "";
const commandIdentity = (command: Command) =>
  JSON.stringify([command.sessionId, command.workerId, command.generation]);

function knownEligibility(item: SessionControlItem, operation: Operation) {
  if (operation === "start") return item.status === "created";
  if (operation === "resume") return item.status === "interrupted";
  return (
    ["reserved", "claimed"].includes(item.claimStatus ?? "") &&
    ["admitted", "running", "idle", "waiting"].includes(item.status ?? "")
  );
}

/** Call above App's authentication gate: private command state survives sign-in renewal. */
export function useSessionControls({
  item,
  live,
}: {
  item: SessionControlItem | null;
  live: boolean;
}) {
  const inputId = useId();
  const key = identity(item);
  const [capabilities, setCapabilities] = useState<Capabilities | null>(null);
  const [capabilityError, setCapabilityError] = useState(false);
  const [refresh, setRefresh] = useState(0);
  const [draft, setDraft] = useState({ key: "", text: "" });
  const [pending, setPending] = useState<Pending | null>(null);
  const [receipt, setReceipt] = useState<Receipt | null>(null);
  const pendingRef = useRef<Readonly<Command> | null>(null);
  const sending = useRef(false);
  const isCurrent = Boolean(
    item?.kind === "session" &&
    !item.historical &&
    item.workerId &&
    Number.isSafeInteger(item.generation) &&
    item.generation! >= 1,
  );

  useEffect(() => {
    const controller = new AbortController();
    setCapabilities(null);
    setCapabilityError(false);
    if (!key || !live || !isCurrent) return () => controller.abort();
    void fetch("/api/capabilities", {
      credentials: "same-origin",
      cache: "no-store",
      signal: controller.signal,
    })
      .then(async (response) => {
        if (!response.ok) throw new Error("capabilities unavailable");
        const data = (await response.json()).sessionCommands;
        if (
          typeof data?.enabled !== "boolean" ||
          !Array.isArray(data.operations) ||
          !Array.isArray(data.inputWorkerIds) ||
          !data.inputWorkerIds.every(
            (value: unknown) => typeof value === "string",
          )
        )
          throw new Error("invalid capabilities");
        if (!controller.signal.aborted)
          setCapabilities({
            key,
            enabled: data.enabled,
            operations: operations.filter((operation) =>
              data.operations.includes(operation),
            ),
            inputWorkerIds: data.inputWorkerIds,
          });
      })
      .catch(() => {
        if (!controller.signal.aborted) setCapabilityError(true);
      });
    return () => controller.abort();
  }, [key, live, isCurrent, refresh]);

  const available = Boolean(
    live && isCurrent && capabilities?.key === key && capabilities.enabled,
  );
  const supported = (operation: Operation) =>
    Boolean(
      available &&
      capabilities?.operations.includes(operation) &&
      (operation !== "input" ||
        capabilities.inputWorkerIds.includes(item?.workerId ?? "")),
    );
  const inputSupported = supported("input");
  const text = draft.key === key ? draft.text : "";
  const canSubmit = (operation: Operation) =>
    !pending &&
    item &&
    supported(operation) &&
    knownEligibility(item, operation) &&
    (operation !== "input" || Boolean(text.trim()));
  // Retry checks identity and capability, not fresh-action eligibility: the
  // original command may itself have changed the observed session status.
  const canRetry = Boolean(
    pending &&
    pending.phase !== "sending" &&
    key === commandIdentity(pending.command) &&
    supported(pending.command.operation),
  );

  async function deliver(command: Readonly<Command>) {
    if (sending.current) return;
    sending.current = true;
    setPending({ command, phase: "sending" });
    const controller = new AbortController();
    const timer = window.setTimeout(() => controller.abort(), 20_000);
    try {
      const response = await fetch("/api/commands", {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(command),
        signal: controller.signal,
      });
      const result = await response.json();
      const matches = result.commandId === command.commandId;
      if (response.status === 202 && matches && result.status === "submitted") {
        pendingRef.current = null;
        setPending(null);
        if (command.operation === "input")
          setDraft((value) =>
            value.key === commandIdentity(command)
              ? { key: value.key, text: "" }
              : value,
          );
        setReceipt({
          sessionId: command.sessionId,
          commandId: command.commandId,
          operation: command.operation,
          status: "submitted",
        });
      } else if (
        (matches || result.commandId === undefined) &&
        ((response.status === 400 && result.error === "invalid_request") ||
          (response.status === 503 && result.error === "not_configured"))
      ) {
        // These backend responses establish rejection before controller dispatch.
        pendingRef.current = null;
        setPending(null);
        setReceipt({
          sessionId: command.sessionId,
          commandId: command.commandId,
          operation: command.operation,
          status: result.error,
        });
      } else {
        setPending({
          command,
          phase:
            response.status === 409 && matches && result.error === "conflict"
              ? "conflict"
              : "unknown",
        });
      }
    } catch {
      // A timeout, disconnect, or invalid response cannot establish non-delivery.
      setPending({ command, phase: "unknown" });
    } finally {
      window.clearTimeout(timer);
      sending.current = false;
    }
  }

  function submit(operation: Operation) {
    if (!canSubmit(operation) || !item || pendingRef.current || sending.current)
      return;
    const bytes = crypto.getRandomValues(new Uint8Array(16));
    const command: Readonly<Command> = Object.freeze({
      commandId:
        "ui-" +
        [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join(""),
      sessionId: item.id,
      workerId: item.workerId!,
      generation: item.generation!,
      operation,
      ...(operation === "input" ? { text } : {}),
    });
    pendingRef.current = command;
    setReceipt(null);
    void deliver(command);
  }

  if (item?.kind !== "session" && !pending && !receipt) return null;
  const blockedReason = !isCurrent
    ? "Select a current session with an observed worker and generation."
    : !live
      ? "Commands pause while live observations are disconnected or stale."
      : capabilityError
        ? "Command capabilities are unavailable."
        : !capabilities || capabilities.key !== key
          ? "Checking command capabilities…"
          : !capabilities.enabled
            ? "Session commands are not configured on this backend."
            : "Only operations allowed by the observed session state are enabled.";

  return (
    <section className="session-controls" aria-label="Session commands">
      <div className="session-controls-heading">
        <div>
          <h3>Session controls</h3>
          <p className="session-controls-target">
            {item?.kind === "session"
              ? `Selected session: ${item.id}`
              : "No session selected"}
          </p>
        </div>
        <button
          type="button"
          onClick={() => setRefresh((value) => value + 1)}
          disabled={!live || !isCurrent}
        >
          Refresh controls
        </button>
      </div>
      <p className="session-controls-hint">{blockedReason}</p>

      {pending && (
        <div
          className="session-command-receipt"
          role="status"
          aria-live="polite"
        >
          <strong>
            {pending.phase === "sending"
              ? "Submitting request"
              : pending.phase === "conflict"
                ? "Controller conflict"
                : "Outcome unknown"}
          </strong>
          <p>
            {labels[pending.command.operation]} · {pending.command.sessionId}
          </p>
          <code>{pending.command.commandId}</code>
          <p>
            {pending.phase === "sending"
              ? "Waiting for durable controller acceptance."
              : "The original request and command ID are retained. No automatic retry has been sent."}
          </p>
          {pending.command.text !== undefined &&
            pending.phase !== "sending" && (
              <label className="session-retained-input">
                Retained private request
                <textarea readOnly value={pending.command.text} rows={3} />
              </label>
            )}
          {pending.phase !== "sending" && (
            <>
              <button
                type="button"
                disabled={!canRetry}
                onClick={() => {
                  if (canRetry && pendingRef.current)
                    void deliver(pendingRef.current);
                }}
              >
                Retry same request
              </button>
              {key !== commandIdentity(pending.command) && (
                <p>
                  Select the original session, worker, and generation to retry
                  this request.
                </p>
              )}
            </>
          )}
        </div>
      )}

      {receipt && (
        <div
          className="session-command-receipt"
          role="status"
          aria-live="polite"
        >
          <strong>
            {receipt.status === "submitted"
              ? "Submitted to controller"
              : receipt.status === "not_configured"
                ? "Not submitted: backend not configured"
                : "Not submitted: request rejected"}
          </strong>
          <p>
            {labels[receipt.operation]} · {receipt.sessionId}
          </p>
          <code>{receipt.commandId}</code>
          {receipt.status === "submitted" ? (
            <p>
              {receipt.operation === "cancel" &&
                "Cancellation remains unconfirmed. "}
              Controller acceptance only; this receipt does not confirm worker
              completion. Follow the live session observations.
            </p>
          ) : (
            <p>
              The backend rejected this request before controller dispatch. Your
              input is retained.
            </p>
          )}
        </div>
      )}

      {capabilities?.enabled && capabilities.key === key && (
        <div className="session-controls-body">
          {inputSupported ? (
            <form
              className="session-input-form"
              onSubmit={(event) => {
                event.preventDefault();
                submit("input");
              }}
            >
              <label htmlFor={inputId}>Session input</label>
              <textarea
                id={inputId}
                value={text}
                rows={4}
                disabled={
                  Boolean(pending) || !item || !knownEligibility(item, "input")
                }
                onChange={(event) =>
                  setDraft({ key, text: event.target.value })
                }
                autoComplete="off"
                spellCheck={false}
              />
              <p>
                Input stays in this page's memory until acknowledged. It is not
                added to flow telemetry.
              </p>
              <button
                type="submit"
                className="session-send"
                disabled={!canSubmit("input")}
              >
                Send input
              </button>
            </form>
          ) : (
            capabilities.operations.includes("input") && (
              <p>Private input is not configured for this worker.</p>
            )
          )}
          <div className="session-control-actions">
            {operations
              .filter(
                (operation) =>
                  operation !== "input" &&
                  capabilities.operations.includes(operation),
              )
              .map((operation) => (
                <button
                  type="button"
                  key={operation}
                  className={operation === "cancel" ? "session-cancel" : ""}
                  disabled={!canSubmit(operation)}
                  onClick={() => submit(operation)}
                >
                  {labels[operation]}
                </button>
              ))}
            <p>
              Interruption and cancellation request a stop. Confirmation comes
              from the worker.
            </p>
          </div>
        </div>
      )}
    </section>
  );
}
