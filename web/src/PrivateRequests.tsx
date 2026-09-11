import { useEffect, useId, useState } from "react";

type Question = {
  id: string;
  header: string;
  question: string;
  isOther: boolean;
  isSecret: boolean;
  options: { label: string; description: string }[] | null;
};
type Request = {
  requestId: string | number;
  fingerprint: string;
  kind: "command" | "file" | "input";
  details: string;
  decisions: string[];
  command?: string | null;
  evidenceAvailable?: boolean;
  changes?: {
    path: string;
    kind: { type: string; move_path?: string };
    diff: string;
  }[];
  questions?: Question[];
};
export type PrivateResponse =
  { decision: string } | { answers: Record<string, { answers: string[] }> };
export type RequestDraft = { key: string; answers: Record<string, string> };
type Scope = { sessionId: string; workerId: string; generation: number };

/** Private details are read only while this authenticated view is mounted. */
export function PrivateRequests({
  scope,
  enabled,
  disabled,
  refresh,
  answered,
  draft,
  onDraft,
  onRespond,
}: {
  scope: Scope;
  enabled: boolean;
  disabled: boolean;
  refresh: number;
  answered: string[];
  draft: RequestDraft;
  onDraft: (draft: RequestDraft) => void;
  onRespond: (
    id: string | number,
    fingerprint: string,
    response: PrivateResponse,
  ) => void;
}) {
  const inputId = useId();
  const key = JSON.stringify([
    scope.sessionId,
    scope.workerId,
    scope.generation,
  ]);
  const [state, setState] = useState<{
    key: string;
    requests: Request[];
    status: "loading" | "ready" | "unavailable";
  }>({ key: "", requests: [], status: "loading" });
  const [reload, setReload] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout>;
    const load = async () => {
      if (controller.signal.aborted) return;
      setState((value) => ({
        key,
        requests: value.key === key ? value.requests : [],
        status: "loading",
      }));
      const requestController = new AbortController();
      const timeout = setTimeout(() => requestController.abort(), 12_000);
      try {
        const query = new URLSearchParams({
          sessionId: scope.sessionId,
          workerId: scope.workerId,
          generation: String(scope.generation),
        });
        const response = await fetch(`/api/requests?${query}`, {
          credentials: "same-origin",
          cache: "no-store",
          signal: AbortSignal.any([
            controller.signal,
            requestController.signal,
          ]),
        });
        if (!response.ok) throw new Error("Private requests unavailable");
        const data = await response.json();
        if (
          data.sessionId !== scope.sessionId ||
          data.workerId !== scope.workerId ||
          data.generation !== scope.generation ||
          !Array.isArray(data.requests) ||
          data.requests.length > 16
        )
          throw new Error("Private request ownership changed");
        if (!controller.signal.aborted)
          setState({ key, requests: data.requests, status: "ready" });
      } catch {
        if (!controller.signal.aborted)
          setState({ key, requests: [], status: "unavailable" });
      } finally {
        clearTimeout(timeout);
        if (!controller.signal.aborted) timer = setTimeout(load, 5000);
      }
    };
    if (enabled) void load();
    return () => {
      controller.abort();
      clearTimeout(timer);
    };
  }, [
    key,
    enabled,
    refresh,
    reload,
    scope.sessionId,
    scope.workerId,
    scope.generation,
  ]);
  const current = state.key === key;
  const ready = enabled && current && state.status === "ready";
  return (
    <section className="private-requests" aria-label="Private agent requests">
      <div className="session-controls-heading">
        <h4>Agent requests</h4>
        <button
          type="button"
          disabled={!enabled}
          onClick={() => setReload((value) => value + 1)}
        >
          Refresh requests
        </button>
      </div>
      <p>
        Requests and answers stay private. Each response is checked against the
        current worker and conversation before submission.
      </p>
      {!enabled ? (
        <p>Waiting for a current admitted session.</p>
      ) : !current || state.status === "loading" ? (
        <p>Checking current requests…</p>
      ) : state.status === "unavailable" ? (
        <p>Private requests are unavailable. Refresh to try again.</p>
      ) : (
        !state.requests.length && <p>No pending agent requests.</p>
      )}
      {current &&
        state.requests.map((request) => {
          const requestKey = key + request.fingerprint;
          const submitted = answered.includes(requestKey);
          const locked = disabled || !ready || submitted;
          const values = draft.key === requestKey ? draft.answers : {};
          return (
            <article className="private-request" key={request.fingerprint}>
              <h5>
                {request.kind === "command"
                  ? "Command approval"
                  : request.kind === "file"
                    ? "File change approval"
                    : "Agent questions"}
              </h5>
              {submitted && (
                <p>
                  Response submitted to controller. Waiting for the worker to
                  finish this request.
                </p>
              )}
              {request.command && <pre>{request.command}</pre>}
              {request.kind === "file" &&
                (!request.evidenceAvailable ? (
                  <p>
                    File change evidence is unavailable. Approval is disabled.
                  </p>
                ) : (
                  request.changes?.map((change, index) => (
                    <div key={index}>
                      <strong>
                        {change.kind.type}: {change.path}
                        {change.kind.move_path && ` → ${change.kind.move_path}`}
                      </strong>
                      <pre>{change.diff}</pre>
                    </div>
                  ))
                ))}
              <details>
                <summary>Request details</summary>
                <pre>{request.details}</pre>
              </details>
              {request.kind === "input" ? (
                <form
                  onSubmit={(event) => {
                    event.preventDefault();
                    if (
                      locked ||
                      !request.questions?.every((q) => values[q.id]?.trim())
                    )
                      return;
                    onRespond(request.requestId, request.fingerprint, {
                      answers: Object.fromEntries(
                        request.questions.map((q) => [
                          q.id,
                          { answers: [values[q.id]] },
                        ]),
                      ),
                    });
                  }}
                >
                  {request.questions?.map((question, index) => {
                    const fieldId = `${inputId}-${request.fingerprint}-${index}`;
                    const update = (value: string) =>
                      onDraft({
                        key: requestKey,
                        answers: { ...values, [question.id]: value },
                      });
                    return (
                      <div className="private-question" key={question.id}>
                        <label htmlFor={fieldId}>{question.question}</label>
                        {question.options?.length && !question.isOther ? (
                          <select
                            id={fieldId}
                            value={values[question.id] ?? ""}
                            disabled={locked}
                            onChange={(event) => update(event.target.value)}
                          >
                            <option value="" disabled>
                              Select an answer
                            </option>
                            {question.options.map((option) => (
                              <option key={option.label} value={option.label}>
                                {option.label} — {option.description}
                              </option>
                            ))}
                          </select>
                        ) : (
                          <>
                            <input
                              id={fieldId}
                              type={question.isSecret ? "password" : "text"}
                              list={
                                question.options?.length && !question.isSecret
                                  ? fieldId + "-options"
                                  : undefined
                              }
                              value={values[question.id] ?? ""}
                              maxLength={8192}
                              autoComplete="off"
                              spellCheck={false}
                              disabled={locked}
                              onChange={(event) => update(event.target.value)}
                            />
                            {question.options?.length && !question.isSecret ? (
                              <datalist id={fieldId + "-options"}>
                                {question.options.map((option) => (
                                  <option
                                    key={option.label}
                                    value={option.label}
                                  >
                                    {option.description}
                                  </option>
                                ))}
                              </datalist>
                            ) : null}
                          </>
                        )}
                      </div>
                    );
                  })}
                  <button
                    type="submit"
                    disabled={
                      locked ||
                      !request.questions?.every((q) => values[q.id]?.trim())
                    }
                  >
                    Send answers
                  </button>
                </form>
              ) : (
                <div className="private-request-actions">
                  <button
                    type="button"
                    disabled={locked || !request.decisions.includes("accept")}
                    onClick={() =>
                      onRespond(request.requestId, request.fingerprint, {
                        decision: "accept",
                      })
                    }
                  >
                    {request.kind === "command"
                      ? "Allow command"
                      : "Allow file changes"}
                  </button>
                  {request.decisions
                    .filter(
                      (decision) =>
                        decision === "decline" || decision === "cancel",
                    )
                    .map((decision) => (
                      <button
                        type="button"
                        key={decision}
                        disabled={locked}
                        onClick={() =>
                          onRespond(request.requestId, request.fingerprint, {
                            decision,
                          })
                        }
                      >
                        {decision === "decline" ? "Decline" : "Cancel request"}
                      </button>
                    ))}
                </div>
              )}
            </article>
          );
        })}
    </section>
  );
}
