import { useEffect, useRef, useState } from "react";

type Scope = { sessionId: string; workerId: string; generation: number };
type CommandOutput = {
  turnId: string;
  itemId: string;
  command: string;
  cwd: string;
  status: string;
  exitCode: number | null;
  durationMs: number | null;
  completedAtMs: number;
  recordDigest: string;
  output: {
    text: string | null;
    captureTruncated: boolean;
  };
};
type Result = Scope & {
  receiptDigest: string;
  ownership: "current" | "historical";
  bundle: {
    schema: string;
    identity: Scope;
    capture: {
      profile: string;
      complete: boolean;
      retainedItems: number;
      observedCompletedItems: number;
      omittedItems: number;
    };
    items: CommandOutput[];
  };
};

/** Mount for one selected scope; retained output never enters shared view state. */
export function SessionOutput({ scope }: { scope: Scope }) {
  const [result, setResult] = useState<Result | null>(null);
  const [status, setStatus] = useState("idle");
  const pending = useRef<AbortController | null>(null);
  useEffect(() => () => pending.current?.abort(), []);
  const load = async () => {
    pending.current?.abort();
    const controller = new AbortController();
    pending.current = controller;
    const timeout = setTimeout(() => controller.abort(), 12000);
    setResult(null);
    setStatus("loading");
    try {
      const query = new URLSearchParams({
        sessionId: scope.sessionId,
        workerId: scope.workerId,
        generation: String(scope.generation),
      });
      const response = await fetch(`/api/session-output?${query}`, {
        cache: "no-store",
        credentials: "same-origin",
        signal: controller.signal,
      });
      const data = await response.json();
      if (!response.ok) {
        if (response.status === 404 && data.error === "not_registered")
          setStatus("not_registered");
        else if (response.status === 503 && data.error === "not_configured")
          setStatus("not_configured");
        else setStatus("unavailable");
        return;
      }
      if (
        data.sessionId !== scope.sessionId ||
        data.workerId !== scope.workerId ||
        data.generation !== scope.generation ||
        data.bundle?.identity?.sessionId !== scope.sessionId ||
        data.bundle?.identity?.workerId !== scope.workerId ||
        data.bundle?.identity?.generation !== scope.generation ||
        data.bundle?.schema !== "hi/fleet/session-output/v1" ||
        data.bundle?.capture?.profile !== "completed_command_items" ||
        data.bundle?.capture?.complete !== false ||
        !["current", "historical"].includes(data.ownership) ||
        !/^[0-9a-f]{64}$/.test(data.receiptDigest ?? "") ||
        !Array.isArray(data.bundle?.items) ||
        data.bundle.items.length > 64
      )
        throw new Error("Output identity unavailable");
      if (!controller.signal.aborted) {
        setResult(data);
        setStatus("ready");
      }
    } catch {
      if (pending.current === controller) setStatus("unavailable");
    } finally {
      clearTimeout(timeout);
    }
  };

  return (
    <section className="session-output" aria-label="Recorded command output">
      <h3>Command logs</h3>
      <p>
        Load collected output for this session. Live activity appears in the
        dashboard while work runs; these logs are retained snapshots.
      </p>
      <button
        type="button"
        disabled={status === "loading"}
        onClick={() => void load()}
      >
        {status === "loading" ? "Loading command logs…" : "Load command logs"}
      </button>
      <div role="status">
        {status === "not_registered" && (
          <p>No collected output is registered for this session.</p>
        )}
        {status === "not_configured" && (
          <p>Command log collection is not configured.</p>
        )}
        {status === "unavailable" && (
          <p>
            Output or its current ownership check is unavailable. Try again.
          </p>
        )}
      </div>
      {result && (
        <>
          <p className="notice">
            {result.ownership === "historical"
              ? "Historical output — this is retained evidence for the selected generation."
              : "Output matched the session owner when these logs were loaded. Load again to recheck ownership."}
          </p>
          <p>
            Combined stdout/stderr reported by Codex. Completeness is unknown.
            Only observed completed command records are included; these are not
            a full conversation or a complete test transcript.
          </p>
          <p>
            {result.bundle.capture.retainedItems} retained records of{" "}
            {result.bundle.capture.observedCompletedItems} observed;{" "}
            {result.bundle.capture.omittedItems} omitted.
          </p>
          <details>
            <summary>Output receipt</summary>
            <code>{result.receiptDigest}</code>
          </details>
          {result.bundle.items.map((item, index) => (
            <details
              className="command-output"
              key={item.recordDigest}
              open={index === 0}
            >
              <summary>{item.command}</summary>
              <p>
                Provider status: {item.status}. Exit code:{" "}
                {item.exitCode ?? "unknown"}.
              </p>
              <p>
                Working directory: <code>{item.cwd}</code>
              </p>
              <p>
                Turn: <code>{item.turnId}</code> · Item:{" "}
                <code>{item.itemId}</code>
              </p>
              {item.durationMs !== null && (
                <p>Reported duration: {item.durationMs} ms.</p>
              )}
              {item.output.captureTruncated && (
                <p className="notice">
                  Collector truncated this output to its retention limit.
                </p>
              )}
              {item.output.text === null ? (
                <p>Output unavailable or empty in the provider record.</p>
              ) : (
                <pre>
                  {item.output.text ||
                    "(Empty output string in the provider record)"}
                </pre>
              )}
            </details>
          ))}
        </>
      )}
    </section>
  );
}
