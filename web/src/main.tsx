import { StrictMode, useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  activeAgentCount,
  currentItem,
  matchPacket,
  packetHost,
  sourceIsFresh,
} from "./selectors";
import { useSessionControls } from "./SessionControls";
import { ProjectsPanel } from "./ProjectsPanel";
import type { ProjectsProjection } from "./pipeline";
import "./style.css";

type Item = {
  id: string;
  kind: string;
  taskId?: string;
  subject?: string;
  agentId?: string;
  activity?: string;
  status?: string;
  component?: string;
  stage?: string;
  host?: string;
  workerId?: string;
  executionId?: string;
  sessionId?: string;
  poolId?: string;
  allocationId?: string;
  generation?: number;
  lastActivityAt?: string;
  waitingReason?: string;
  issueUrl?: string;
  workspaceId?: string;
  hmasRole?: string;
  claimStatus?: string;
  historical?: boolean;
  sourceStale?: boolean;
  lastReportedActivity?: string;
  [key: string]: unknown;
};
type Packet = {
  eventId: string;
  source: string;
  target: string;
  operation: string;
  receivedAt: string;
  observedAt: string;
  taskId?: string;
  messageId?: string;
  agentId?: string;
  workerId?: string;
  host?: string;
  bytes?: number;
  result?: string;
  sourceId?: string;
  sequence: number;
  [key: string]: unknown;
};
type Snapshot = {
  projects?: ProjectsProjection;
  cursor: string;
  generatedAt: string;
  items: Item[];
  observations: Packet[];
  resources: Record<string, Item[]>;
  sources: Record<string, { status: string; observedAt: string }>;
  components: string[];
  gap: boolean;
  dropped: number;
  invalid: number;
  sourceGaps: number;
  coverageLosses: number;
  truncatedResources: boolean;
};
const display = (value: unknown) =>
  value === undefined || value === null || value === ""
    ? "Not reported"
    : String(value).replaceAll("_", " ");
const title = (value: string) =>
  value === "achaeanfleet"
    ? "AchaeanFleet"
    : value.charAt(0).toUpperCase() + value.slice(1);
const active = (item: Item) =>
  ["running", "model_working", "tool_running"].includes(item.activity ?? "");
const age = (stamp?: string, now = Date.now()) =>
  stamp
    ? `${Math.max(0, Math.floor((now - Date.parse(stamp)) / 1000))}s ago`
    : "No observation";
const positions: Record<string, [number, number]> = {
  odysseus: [96, 188],
  nestor: [278, 88],
  telemachy: [465, 88],
  agamemnon: [464, 188],
  keystone: [675, 188],
  hephaestus: [887, 188],
  myrmidons: [887, 88],
  codex: [1080, 188],
  github: [278, 300],
  hermes: [465, 300],
  argus: [675, 300],
  slurm: [1080, 300],
  mnemosyne: [96, 414],
  scylla: [278, 414],
  charybdis: [465, 414],
  proteus: [675, 414],
  achaeanFleet: [887, 414],
};
// Identifiers match the component registry; positions are presentation only.
positions.achaeanfleet = positions.achaeanFleet;
delete positions.achaeanFleet;
const configuredEdges = [
  ["odysseus", "nestor"],
  ["nestor", "telemachy"],
  ["telemachy", "keystone"],
  ["odysseus", "agamemnon"],
  ["agamemnon", "keystone"],
  ["keystone", "hephaestus"],
  ["hephaestus", "codex"],
  ["myrmidons", "agamemnon"],
  ["github", "hermes"],
  ["hermes", "keystone"],
  ["keystone", "argus"],
  ["hephaestus", "slurm"],
  ["charybdis", "agamemnon"],
  ["scylla", "argus"],
  ["proteus", "achaeanfleet"],
  ["achaeanfleet", "hephaestus"],
  ["mnemosyne", "hephaestus"],
];
const pathFor = (source: string, target: string) => {
  const [x1, y1] = positions[source] ?? [0, 0];
  const [x2, y2] = positions[target] ?? [0, 0];
  const dx = (x2 - x1) / 2;
  return `M ${x1} ${y1} C ${x1 + dx} ${y1}, ${x2 - dx} ${y2}, ${x2} ${y2}`;
};

function Flow({
  packets,
  items,
  now,
  live,
  selected,
  onComponent,
  onPacket,
}: {
  packets: Packet[];
  items: Item[];
  now: number;
  live: boolean;
  selected: string;
  onComponent: (component: string) => void;
  onPacket: (packet: Packet) => void;
}) {
  const recent = packets.filter((p) => now - Date.parse(p.receivedAt) < 30000);
  const edges = new Map(
    configuredEdges.map(([source, target]) => [
      `${source}:${target}`,
      { source, target, count: 0 },
    ]),
  );
  for (const p of recent) {
    const key = `${p.source}:${p.target}`;
    const edge = edges.get(key) ?? {
      source: p.source,
      target: p.target,
      count: 0,
    };
    edge.count++;
    edges.set(key, edge);
  }
  return (
    <svg
      className="flow-map"
      viewBox="0 0 1180 485"
      role="group"
      aria-label="Live component message flow"
    >
      <defs>
        <pattern id="grid" width="24" height="24" patternUnits="userSpaceOnUse">
          <circle cx="1" cy="1" r="0.7" fill="#283632" />
        </pattern>
      </defs>
      <rect width="1180" height="485" fill="url(#grid)" />
      <text x="26" y="32" className="lane-label">
        INTAKE & KNOWLEDGE
      </text>
      <text x="396" y="32" className="lane-label">
        COORDINATION & TRANSPORT
      </text>
      <text x="866" y="32" className="lane-label">
        EXECUTION
      </text>
      {[...edges.values()].map((edge) => (
        <path
          key={`${edge.source}:${edge.target}`}
          d={pathFor(edge.source, edge.target)}
          className={`flow-edge ${live && edge.count ? "observed" : ""}`}
        >
          <title>
            {title(edge.source)} → {title(edge.target)} · {edge.count}{" "}
            observations in retained 30s window
          </title>
        </path>
      ))}
      {live &&
        recent
          .filter((p) => now - Date.parse(p.receivedAt) < 1800)
          .slice(-30)
          .map((p) => (
            <circle
              key={`${p.sourceId ?? p.source}:${p.eventId}`}
              r="4"
              className="packet"
              onClick={() => onPacket(p)}
            >
              <title>
                {p.operation} · {p.taskId ?? p.messageId ?? p.eventId}
              </title>
              <animateMotion
                dur="1.8s"
                repeatCount="1"
                path={pathFor(p.source, p.target)}
              />
            </circle>
          ))}
      {Object.entries(positions).map(([component, [x, y]]) => {
        const linked = items.filter(
          (item) => item.component?.toLowerCase() === component,
        );
        const seen = recent.some(
          (p) => p.source === component || p.target === component,
        );
        return (
          <g
            key={component}
            transform={`translate(${x},${y})`}
            className={`map-node ${selected === component ? "selected" : ""}`}
            role="button"
            tabIndex={0}
            aria-label={`Filter ${title(component)}`}
            onClick={() => onComponent(component)}
            onKeyDown={(event) => {
              if (event.key === "Enter" || event.key === " ") {
                event.preventDefault();
                onComponent(component);
              }
            }}
          >
            <rect x="-73" y="-29" width="146" height="58" rx="9" />
            <circle
              cx="-57"
              cy="-7"
              r="3"
              className={live && seen ? "node-live" : "node-quiet"}
            />
            <text x="-46" y="-3" className="node-title">
              {component === "achaeanfleet" ? "AchaeanFleet" : title(component)}
            </text>
            <text x="-56" y="16" className="node-meta">
              {linked.length
                ? `${linked.length} linked items`
                : seen
                  ? "Traffic observed"
                  : "No observations"}
            </text>
          </g>
        );
      })}
    </svg>
  );
}

function App() {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [authenticated, setAuthenticated] = useState(false);
  const [token, setToken] = useState("");
  const [loginError, setLoginError] = useState("");
  const [connection, setConnection] = useState("connecting");
  const [now, setNow] = useState(Date.now());
  const [tab, setTab] = useState("System flow");
  const [query, setQuery] = useState("");
  const [component, setComponent] = useState("");
  const [host, setHost] = useState("");
  const [selection, setSelected] = useState<Item | null>(null);
  const [packet, setPacket] = useState<Packet | null>(null);
  const detailPanel = useRef<HTMLElement>(null);
  const selectionTrigger = useRef<HTMLElement | null>(null);
  useEffect(() => {
    if (!selection && !packet) return;
    const panel = detailPanel.current;
    if (!panel) return;
    if (
      document.activeElement instanceof HTMLElement &&
      !panel.contains(document.activeElement)
    )
      selectionTrigger.current = document.activeElement;
    panel.focus({ preventScroll: true });
    if (window.innerWidth <= 1250) panel.scrollIntoView({ block: "start" });
  }, [selection?.id, selection?.kind, selection?.generation, packet?.eventId]);
  const closeDetails = () => {
    setSelected(null);
    setPacket(null);
    requestAnimationFrame(() => {
      if (selectionTrigger.current?.isConnected)
        selectionTrigger.current.focus();
    });
  };
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 500);
    return () => clearInterval(timer);
  }, []);
  useEffect(() => {
    void fetch("/api/snapshot")
      .then(async (response) => {
        if (response.ok) {
          setSnapshot(await response.json());
          setAuthenticated(true);
        } else
          setConnection(response.status === 401 ? "signed out" : "unavailable");
      })
      .catch(() => setConnection("unavailable"));
  }, []);
  useEffect(() => {
    if (!authenticated) return;
    const events = new EventSource("/api/events");
    events.addEventListener("snapshot", (event) => {
      try {
        setSnapshot(JSON.parse((event as MessageEvent).data));
        setConnection("connected");
      } catch {
        setConnection("invalid update");
      }
    });
    events.onerror = () => {
      setConnection("reconnecting");
      void fetch("/api/snapshot")
        .then((r) => {
          if (r.status === 401) {
            events.close();
            setAuthenticated(false);
          }
        })
        .catch(() => {});
    };
    return () => events.close();
  }, [authenticated]);
  const live =
    connection === "connected" &&
    Boolean(snapshot && now - Date.parse(snapshot.generatedAt) < 5000);
  const ownershipLive = live && sourceIsFresh(snapshot?.sources.agamemnon, now);
  const items = (snapshot?.items ?? []).map((item) =>
    ownershipLive
      ? item
      : {
          ...item,
          lastReportedActivity: item.activity,
          activity: "unknown",
          sourceStale: true,
        },
  );
  const workers: Item[] = (snapshot?.resources.workers ?? []).map((worker) => ({
    ...worker,
    kind: "worker",
    sourceStale: !ownershipLive,
  }));
  const selected: Item | null = selection
    ? (currentItem([...items, ...workers], selection) ?? {
        ...selection,
        activity: "historical",
        status: "not-current",
        historical: true,
      })
    : null;
  // Keep intent in App memory while the private controls are hidden at sign-out.
  const sessionControls = useSessionControls({
    item: selected,
    live: authenticated && ownershipLive,
  });
  const matchQuery = (item: unknown) =>
    !query || JSON.stringify(item).toLowerCase().includes(query.toLowerCase());
  const visibleItems = items.filter(
    (item) =>
      matchQuery(item) &&
      (!host || item.host === host) &&
      (!component || item.component?.toLowerCase() === component),
  );
  const packets = (snapshot?.observations ?? []).filter(
    (p) =>
      matchQuery(p) &&
      (!host || packetHost(items, p) === host) &&
      (!component || p.source === component || p.target === component),
  );
  const hosts = useMemo(
    () => [
      ...new Set(
        [...items, ...workers].map((i) => i.host).filter(Boolean) as string[],
      ),
    ],
    [items, workers],
  );
  const working = live ? activeAgentCount(items, now) : 0;
  const showPacket = (p: Packet) => {
    setPacket(p);
    setSelected(matchPacket(items, p) ?? null);
  };
  if (!authenticated)
    return (
      <main className="login-page">
        <div className="login-card">
          <span className="brand-mark">Ο</span>
          <p className="eyebrow">HOMERIC INTELLIGENCE</p>
          <h1>Welcome to Odysseus.</h1>
          <p>
            Your fleet, its work, and every observed connection in one place.
          </p>
          <form
            onSubmit={async (event) => {
              event.preventDefault();
              setLoginError("");
              try {
                const response = await fetch("/api/session", {
                  method: "POST",
                  headers: { "content-type": "application/json" },
                  body: JSON.stringify({ token }),
                });
                if (!response.ok) {
                  setLoginError("The access token was not accepted.");
                  return;
                }
                setToken("");
                setAuthenticated(true);
              } catch {
                setLoginError("The local backend is unavailable.");
              }
            }}
          >
            <label htmlFor="access-token">Local access token</label>
            <input
              id="access-token"
              type="password"
              autoComplete="off"
              value={token}
              onChange={(e) => setToken(e.target.value)}
              required
            />
            <button className="primary" type="submit">
              Open mission control <span>↗</span>
            </button>
            {loginError && (
              <p role="alert" className="warning">
                {loginError}
              </p>
            )}
          </form>
          <p className="fine-print">
            Use the private access-token file shown when the local web service
            starts. Provider and cluster credentials stay on the backend.
          </p>
        </div>
      </main>
    );
  return (
    <div className="app-shell">
      <aside className="sidebar">
        <a className="brand" href="/">
          <span className="brand-mark">Ο</span>
          <span>
            ODYSSEUS<small>HOMERIC FLEET</small>
          </span>
        </a>
        <div className="workspace-label">YOUR WORKSPACE</div>
        <nav aria-label="Main navigation">
          {["System flow", "Work items", "Workers", "Pipeline"].map(
            (name, i) => (
              <button
                key={name}
                className={tab === name ? "nav-active" : ""}
                onClick={() => setTab(name)}
              >
                <span className="nav-icon" aria-hidden="true">
                  {["⌘", "▤", "▦", "⇢"][i]}
                </span>
                {name}
              </button>
            ),
          )}
        </nav>
        <div className="workspace-label components-label">COMPONENTS</div>
        <div className="component-list">
          {(snapshot?.components ?? [])
            .filter((c) => !["github", "codex", "slurm"].includes(c))
            .map((c) => (
              <button
                key={c}
                className={component === c ? "component-active" : ""}
                onClick={() => {
                  setComponent(component === c ? "" : c);
                  if (tab === "Pipeline") setTab("System flow");
                }}
              >
                <span
                  className={`tiny-dot ${live && packets.some((p) => (p.source === c || p.target === c) && now - Date.parse(p.receivedAt) < 30000) ? "lit" : ""}`}
                />
                {c === "achaeanfleet" ? "AchaeanFleet" : title(c)}
              </button>
            ))}
        </div>
        <div className="sidebar-footer">
          <span className="tiny-dot lit" /> LOCAL CONTROL PLANE
          <small>12 laptop · 48 M1 · 48 M2 target</small>
        </div>
      </aside>
      <main className="main">
        <header className="topbar">
          <span>
            Homeric Intelligence <span className="slash">/</span>{" "}
            <strong>Mission control</strong>
          </span>
          <div className="connection">
            <span className={`tiny-dot ${live ? "lit" : ""}`} />
            {live ? "Live view" : display(connection)}
            <span className="clock">
              {new Date(now).toLocaleTimeString([], { hour12: false })}
            </span>
          </div>
        </header>
        <section className="page-heading">
          <div>
            <p className="eyebrow">FLEET OPERATIONS</p>
            <h1>{tab}</h1>
            <p>
              See who is working, where work runs, and how the system connects.
            </p>
          </div>
          <div className="scope-badge">LAPTOP + M1 + M2</div>
        </section>
        <section className="stats" aria-label="Fleet statistics">
          <div>
            <span>Observed issue agents</span>
            <strong>
              {working}
              <small>/ 108 target</small>
            </strong>
            <p>Unique agents with active issue claims</p>
          </div>
          <div>
            <span>Visible work items</span>
            <strong>
              {items.length}
              <small>items</small>
            </strong>
            <p>From confirmed service records</p>
          </div>
          <div>
            <span>Registered workers</span>
            <strong>
              {snapshot?.resources.workers?.length ?? 0}
              <small>workers</small>
            </strong>
            <p>Reported by Agamemnon</p>
          </div>
          <div>
            <span>Traffic observations</span>
            <strong>
              {
                packets.filter((p) => now - Date.parse(p.receivedAt) < 30000)
                  .length
              }
              <small>last 30s</small>
            </strong>
            <p>Within retained telemetry window</p>
          </div>
        </section>
        <div className="source-strip">
          {Object.entries(snapshot?.sources ?? {}).map(([source, state]) => (
            <span
              key={source}
              className={
                state.status === "connected" ? "source-ok" : "source-warning"
              }
            >
              <span
                className={`tiny-dot ${state.status === "connected" ? "lit" : ""}`}
              />
              {title(source)} <strong>{display(state.status)}</strong>
            </span>
          ))}
        </div>
        {snapshot?.gap ||
        snapshot?.sourceGaps ||
        snapshot?.dropped ||
        snapshot?.coverageLosses ||
        snapshot?.truncatedResources ? (
          <div className="notice" role="status">
            Telemetry coverage is partial. {snapshot.dropped} older observations
            left the bounded buffer; {snapshot.sourceGaps} source sequence gaps.{" "}
            {snapshot.coverageLosses ?? 0} observation frames rejected or
            truncated.{" "}
            {snapshot.gap ? "Reconnect required a fresh snapshot." : ""}{" "}
            {snapshot.truncatedResources ? "Resource view is truncated." : ""}
          </div>
        ) : null}
        {tab !== "Pipeline" && (
          <div className="toolbar">
            <div className="search">
              <span>⌕</span>
              <input
                aria-label="Search items and traces"
                placeholder="Search an item, agent, or message…"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
              />
            </div>
            <select
              aria-label="Filter host"
              value={host}
              onChange={(e) => setHost(e.target.value)}
            >
              <option value="">All hosts</option>
              {hosts.map((h) => (
                <option key={h}>{h}</option>
              ))}
            </select>
            {component && (
              <button className="filter-chip" onClick={() => setComponent("")}>
                {title(component)} ×
              </button>
            )}
            <span className="toolbar-right">
              {live ? "View connected" : "Waiting for connection"}
            </span>
          </div>
        )}
        {tab === "System flow" && (
          <section className="panel flow-panel">
            <div className="panel-heading">
              <div>
                <h2>The system, in motion</h2>
                <p>Select a component or observation to follow its work.</p>
              </div>
              <div className="legend">
                <span>
                  <i className="legend-line" />
                  Topology
                </span>
                <span>
                  <i className="legend-line observed" />
                  Observed
                </span>
              </div>
            </div>
            <Flow
              packets={packets}
              items={items}
              now={now}
              live={live}
              selected={component}
              onComponent={(c) => setComponent(component === c ? "" : c)}
              onPacket={showPacket}
            />
            <div className="flow-caption">
              <span>APPLICATION MESSAGE OBSERVATIONS</span>
              <span>
                {packets.length
                  ? "Publish, delivery, and acknowledgment remain distinct observations."
                  : "No traffic observed yet. Connections illuminate when real telemetry arrives."}
              </span>
            </div>
          </section>
        )}
        {tab === "Pipeline" ? (
          <ProjectsPanel
            projection={snapshot?.projects}
            sourceStatus={snapshot?.sources.projects?.status}
            items={items}
            live={live}
            ownershipLive={ownershipLive}
            onSelect={(item) => {
              setSelected(item);
              setPacket(null);
            }}
          />
        ) : tab === "Workers" ? (
          <section className="panel">
            <div className="panel-heading">
              <h2>Workers & allocations</h2>
              <span>{snapshot?.resources.workers?.length ?? 0} registered</span>
            </div>
            <div className="worker-grid">
              {(snapshot?.resources.workers ?? [])
                .filter(
                  (worker) =>
                    matchQuery(worker) && (!host || worker.host === host),
                )
                .map((worker) => (
                  <button
                    className="worker-card"
                    key={worker.id}
                    onClick={() => {
                      setSelected({ ...worker, kind: "worker" });
                      setPacket(null);
                    }}
                  >
                    <span className="eyebrow">{display(worker.host)}</span>
                    <h3>{worker.id}</h3>
                    <p>{display(worker.poolId)}</p>
                    <dl>
                      <dt>Allocation</dt>
                      <dd>{display(worker.allocationId)}</dd>
                      <dt>Status</dt>
                      <dd>{display(worker.status)}</dd>
                      <dt>Generation</dt>
                      <dd>{display(worker.generation)}</dd>
                    </dl>
                  </button>
                ))}
              {!snapshot?.resources.workers?.length && (
                <div className="empty">
                  <span>▦</span>
                  <h3>No registered workers</h3>
                  <p>
                    Workers appear after Agamemnon reports their registration.
                    The 108-agent target is not a live capacity measurement.
                  </p>
                </div>
              )}
            </div>
          </section>
        ) : (
          <div
            className={`lower-grid ${tab === "Work items" ? "items-only" : ""}`}
          >
            <section className="panel items-panel">
              <div className="panel-heading">
                <h2>What is working on each item</h2>
                <span>{visibleItems.length} items</span>
              </div>
              <div className="table-scroll">
                <table>
                  <thead>
                    <tr>
                      <th>WORK ITEM</th>
                      <th>AGENT / HOST</th>
                      <th>OBSERVED ACTIVITY</th>
                      <th>LAST ACTIVITY</th>
                    </tr>
                  </thead>
                  <tbody>
                    {visibleItems.map((item) => (
                      <tr
                        key={`${item.kind}:${item.id}`}
                        onClick={() => {
                          setSelected(item);
                          setPacket(null);
                        }}
                      >
                        <td>
                          <button className="item-link">
                            {item.subject ?? item.taskId ?? item.id}
                          </button>
                          <small>
                            {display(item.stage)} · {item.kind}
                          </small>
                        </td>
                        <td>
                          {display(item.agentId)}
                          <small>
                            {display(item.host)}
                            {item.workerId ? ` / ${item.workerId}` : ""}
                          </small>
                        </td>
                        <td>
                          <span
                            className={`status-badge ${active(item) && live ? "working" : ""}`}
                          >
                            {live ? display(item.activity) : "connection stale"}
                          </span>
                          {item.waitingReason && (
                            <small>{item.waitingReason}</small>
                          )}
                        </td>
                        <td className="mono">
                          {age(item.lastActivityAt, now)}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              {!visibleItems.length && (
                <div className="empty">
                  <span>▤</span>
                  <h3>
                    {items.length
                      ? "No items match these filters"
                      : "Waiting for admitted work"}
                  </h3>
                  <p>
                    {items.length
                      ? "Clear a filter to see the other work items."
                      : "Connect Agamemnon to see actual item ownership, stages, and execution evidence."}
                  </p>
                </div>
              )}
            </section>
            {tab === "System flow" && (
              <section className="panel trace-panel">
                <div className="panel-heading">
                  <h2>Message trace</h2>
                  <span className="mono">LIVE</span>
                </div>
                <div className="trace-list">
                  {packets
                    .slice(-30)
                    .reverse()
                    .map((p) => (
                      <button
                        className="trace-row"
                        key={`${p.sourceId ?? p.source}:${p.eventId}`}
                        onClick={() => showPacket(p)}
                      >
                        <span
                          className={`trace-dot ${p.result === "failed" ? "failed" : ""}`}
                        />
                        <span>
                          <strong>
                            {title(p.source)} <span>→</span> {title(p.target)}
                          </strong>
                          <small>
                            {p.operation} ·{" "}
                            {p.taskId ?? p.messageId ?? p.eventId}
                          </small>
                        </span>
                        <time>{age(p.receivedAt, now)}</time>
                      </button>
                    ))}
                  {!packets.length && (
                    <div className="empty">
                      <span>↝</span>
                      <h3>No observed messages</h3>
                      <p>
                        Keystone telemetry and allocation attachment
                        observations appear here. No traffic is simulated.
                      </p>
                    </div>
                  )}
                </div>
              </section>
            )}
          </div>
        )}
        <footer className="page-footer">
          <span>
            Odysseus · orchestration by Agamemnon · transport by Keystone
          </span>
          <span>
            {snapshot
              ? `Snapshot ${age(snapshot.generatedAt, now)}`
              : "Awaiting snapshot"}
          </span>
        </footer>
      </main>
      <aside
        className="detail-panel"
        aria-label="Item and trace details"
        hidden={!selected && !packet}
        ref={detailPanel}
        tabIndex={-1}
        onKeyDown={(event) => {
          if (event.key === "Escape") closeDetails();
        }}
      >
        <button
          className="close"
          aria-label="Close details"
          onClick={closeDetails}
        >
          ×
        </button>
        <p className="eyebrow">
          {selected?.historical
            ? "HISTORICAL SELECTION"
            : selected?.sourceStale
              ? "LAST REPORTED OWNERSHIP"
              : "CORRELATED EVIDENCE"}
        </p>
        <h2>
          {selected?.subject ?? selected?.taskId ?? "Message observation"}
        </h2>
        {selected?.issueUrl && (
          <a href={selected.issueUrl} target="_blank" rel="noreferrer">
            Open GitHub issue ↗
          </a>
        )}
        {selected?.sourceStale && (
          <p className="notice" role="status">
            Current ownership and activity are unknown. These are the last
            reported Fleet records.
          </p>
        )}
        {sessionControls}
        {selected && (
          <>
            <h3>Work ownership</h3>
            <dl>
              {[
                "id",
                "agentId",
                "hmasRole",
                "executionDomain",
                "component",
                "activity",
                ...(selected?.sourceStale ? ["lastReportedActivity"] : []),
                "stage",
                "workerId",
                "host",
                "poolId",
                "allocationId",
                "generation",
                "executionId",
                "sessionId",
                "workspaceId",
                "claimStatus",
                "waitingReason",
                "lastActivityAt",
              ].map((key) => (
                <div key={key}>
                  <dt>{key.replace(/([A-Z])/g, " $1")}</dt>
                  <dd>{display(selected[key])}</dd>
                </div>
              ))}
            </dl>
          </>
        )}
        {packet && (
          <>
            <h3>Observed message</h3>
            <dl>
              {Object.entries(packet).map(([key, value]) => (
                <div key={key}>
                  <dt>{key.replace(/([A-Z])/g, " $1")}</dt>
                  <dd>{display(value)}</dd>
                </div>
              ))}
            </dl>
            {!selected && (
              <p className="fine-print">
                No matching item is present in the current service snapshot.
              </p>
            )}
          </>
        )}
      </aside>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
