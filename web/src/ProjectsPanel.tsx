import { useState } from "react";
import type { TrackedItem } from "./selectors";
import { pipelineOwners, type ProjectsProjection } from "./pipeline";
import "./ProjectsPanel.css";

const states = [
  "Pending",
  "Decomposing",
  "Delegated",
  "InProgress",
  "Escalated",
  "Completed",
  "Failed",
];
const label = (value?: string) =>
  value
    ? value.replaceAll("_", " ").replace(/^./, (value) => value.toUpperCase())
    : "Not reported";
const timestamp = (value?: string) =>
  value
    ? new Date(value).toISOString().replace("T", " ").replace(".000Z", " UTC")
    : "Not reported";

export function ProjectsPanel<T extends TrackedItem>({
  projection,
  sourceStatus,
  items,
  live,
  ownershipLive,
  onSelect,
}: {
  projection?: ProjectsProjection;
  sourceStatus?: string;
  items: T[];
  live: boolean;
  ownershipLive: boolean;
  onSelect: (item: T) => void;
}) {
  const [query, setQuery] = useState("");
  const [state, setState] = useState("");
  const observed = live && projection?.fresh;
  const rows = (projection?.items ?? [])
    .map((task) => ({ task, owners: pipelineOwners(task, items) }))
    .filter(
      (row) =>
        (!state || row.task.orchestrationState === state) &&
        (!query ||
          JSON.stringify(row).toLowerCase().includes(query.toLowerCase())),
    );
  const notConfigured = !sourceStatus || sourceStatus === "not_configured";
  return (
    <section className="pipeline" aria-label="GitHub pipeline projection">
      <div className="panel pipeline-health">
        <div className="panel-heading">
          <div>
            <h2>Issue-backed pipeline</h2>
            <p>
              Agamemnon records orchestration. Hephaestus reports review and
              implementation stages.
            </p>
          </div>
          <span
            className={`pipeline-status ${observed && projection?.state === "healthy" ? "healthy" : ""}`}
          >
            {projection ? label(projection.state) : "Unavailable"}
          </span>
        </div>
        <p className="pipeline-explanation">
          The GitHub board is a derived view. Board changes do not assign agents
          or approve work.
        </p>
        {projection && (
          <>
            <dl className="pipeline-timing">
              <div>
                <dt>Health read</dt>
                <dd>{timestamp(projection.observedAt)}</dd>
              </div>
              <div>
                <dt>Last rebuild attempt</dt>
                <dd>{timestamp(projection.lastAttemptAt)}</dd>
              </div>
              <div>
                <dt>Last successful rebuild</dt>
                <dd>{timestamp(projection.lastSuccessAt)}</dd>
              </div>
            </dl>
            <div
              className="pipeline-counts"
              aria-label="Last reported projection results"
            >
              {(
                [
                  ["Board items changed", projection.projected],
                  ["Unchanged", projection.unchanged],
                  ["Projection failures", projection.failed],
                  ["Metadata unavailable", projection.unavailable],
                ] as const
              ).map(([name, value]) => (
                <div key={name}>
                  <span>{name}</span>
                  <strong>{value ?? "Not measured"}</strong>
                </div>
              ))}
            </div>
            {!observed && (
              <p className="notice" role="status">
                Showing the last available projection. The source is{" "}
                {label(sourceStatus).toLowerCase()}; current board health is
                unknown.
              </p>
            )}
          </>
        )}
      </div>
      {!projection ? (
        <div className="panel empty">
          <h3>
            {notConfigured
              ? "Pipeline source not configured"
              : "Pipeline source unavailable"}
          </h3>
          <p>
            {notConfigured
              ? "Connect the Agamemnon service to see its issue-backed GitHub Projects view."
              : "No supported projection has arrived. The work backlog and board state are unknown."}
          </p>
        </div>
      ) : projection.state === "disabled" ? (
        <div className="panel empty">
          <h3>GitHub Projects projection is disabled</h3>
          <p>
            Configure the project mapping in Agamemnon to show the board here.
            Fleet work records remain available.
          </p>
        </div>
      ) : (
        <div className="panel">
          <div className="pipeline-filters">
            <input
              aria-label="Search pipeline"
              placeholder="Search a task, repository, agent, or host…"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
            />
            <select
              aria-label="Filter orchestration state"
              value={state}
              onChange={(event) => setState(event.target.value)}
            >
              <option value="">All orchestration states</option>
              {states.map((value) => (
                <option key={value}>{value}</option>
              ))}
            </select>
            <span>{rows.length} tasks</span>
          </div>
          {!ownershipLive && (
            <p className="notice" role="status">
              Current ownership is unavailable. Any displayed claims are from
              the last Fleet records.
            </p>
          )}
          <div className="table-scroll">
            <table className="pipeline-table">
              <thead>
                <tr>
                  <th>TASK / LINKS</th>
                  <th>ORCHESTRATION</th>
                  <th>IMPLEMENTATION STAGE</th>
                  <th>REPORTED AGENT / HOST</th>
                </tr>
              </thead>
              <tbody>
                {rows.map(({ task, owners }) => (
                  <tr key={task.taskId}>
                    <td>
                      <strong>
                        {task.repo
                          ? `${task.repo}${task.issue ? ` #${task.issue}` : ""}`
                          : task.taskId}
                      </strong>
                      <small>{task.taskId}</small>
                      <div className="pipeline-links">
                        {task.workIssueUrl && (
                          <a
                            href={task.workIssueUrl}
                            target="_blank"
                            rel="noreferrer"
                          >
                            Work issue
                          </a>
                        )}
                        {task.orchestrationIssueUrl && (
                          <a
                            href={task.orchestrationIssueUrl}
                            target="_blank"
                            rel="noreferrer"
                          >
                            Orchestration record
                          </a>
                        )}
                        {task.pullRequestUrls.map((url) => (
                          <a
                            key={url}
                            href={url}
                            target="_blank"
                            rel="noreferrer"
                          >
                            PR #{url.split("/").at(-1)}
                          </a>
                        ))}
                      </div>
                    </td>
                    <td>
                      {task.orchestrationState}
                      <small>Board item {task.state}</small>
                    </td>
                    <td>
                      {task.stageProjection === "available" && task.stageLabel
                        ? task.stageLabel
                        : "Stage unavailable"}
                      <small>From work issue labels</small>
                    </td>
                    <td>
                      {owners.length ? (
                        owners.map((owner) => (
                          <button
                            className="pipeline-owner"
                            key={`${owner.id}:${owner.generation}`}
                            onClick={() => onSelect(owner)}
                          >
                            <strong>{owner.agentId}</strong>
                            <span>
                              {typeof owner.host === "string"
                                ? owner.host
                                : "Host not reported"}{" "}
                              · {owner.workerId}
                            </span>
                            <small>
                              {label(owner.claimStatus)} ·{" "}
                              {ownershipLive
                                ? label(owner.activity)
                                : "Current activity unknown"}{" "}
                              · generation {owner.generation}
                            </small>
                          </button>
                        ))
                      ) : (
                        <span className="pipeline-muted">
                          {ownershipLive
                            ? "No current claim reported"
                            : "Current claim unknown"}
                        </span>
                      )}
                      {owners.length > 1 && (
                        <small>
                          Multiple claim records reported; inspect each owner.
                        </small>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {!rows.length && (
            <div className="empty">
              <h3>
                {projection.items.length
                  ? "No tasks match these filters"
                  : "No projected task records"}
              </h3>
              <p>
                {projection.items.length
                  ? "Change the search or orchestration state."
                  : "A missing projection does not establish that the work backlog is empty."}
              </p>
            </div>
          )}
        </div>
      )}
    </section>
  );
}
