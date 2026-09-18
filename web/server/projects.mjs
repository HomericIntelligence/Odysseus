import { componentEndpoint, readComponentJson } from "./upstream.mjs";

const healthStates = new Set([
  "disabled",
  "pending",
  "running",
  "healthy",
  "degraded",
  "misconfigured",
  "unavailable",
]);
const taskStates = new Set([
  "Pending",
  "Decomposing",
  "Delegated",
  "InProgress",
  "Escalated",
  "Completed",
  "Failed",
]);
const stageStates = new Set(["available", "partial", "unavailable"]);
const rowStates = new Set(["projected", "unchanged", "failed"]);
const id = (value) =>
  typeof value === "string" && /^[\w.:/-]{1,256}$/.test(value);
const date = (value) =>
  typeof value === "string" && Number.isFinite(Date.parse(value))
    ? new Date(value).toISOString()
    : undefined;
const count = (value) =>
  Number.isSafeInteger(value) && value >= 0 ? value : undefined;

function githubLink(value, kind) {
  try {
    const url = new URL(value);
    if (
      url.protocol === "https:" &&
      url.hostname === "github.com" &&
      !url.username &&
      !url.password &&
      !url.port &&
      new RegExp(`^/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/${kind}/[1-9][0-9]*$`).test(
        url.pathname,
      )
    )
      return url.origin + url.pathname;
  } catch {
    /* Only supported GitHub destinations enter the browser. */
  }
  return undefined;
}

export function projectMetadata(input) {
  if (
    !input ||
    input.schema !== "hi/projects-projection/v1" ||
    input.authority !== "github-issues" ||
    input.direction !== "issues-to-project" ||
    !healthStates.has(input.state) ||
    !stageStates.has(input.stageProjection) ||
    !Array.isArray(input.items) ||
    input.items.length > 2000
  )
    throw new Error("Unsupported Projects projection");
  const seen = new Set();
  const items = input.items.map((row) => {
    if (
      !row ||
      !id(row.taskId) ||
      seen.has(row.taskId) ||
      !taskStates.has(row.orchestrationState) ||
      !stageStates.has(row.stageProjection) ||
      !rowStates.has(row.state)
    )
      throw new Error("Incomplete Projects collection");
    seen.add(row.taskId);
    const result = {
      taskId: row.taskId,
      orchestrationState: row.orchestrationState,
      stageProjection: row.stageProjection,
      state: row.state,
      orchestrationIssueUrl: githubLink(row.orchestrationIssueUrl, "issues"),
      workIssueUrl: githubLink(row.workIssueUrl, "issues"),
      pullRequestUrls: Array.isArray(row.pullRequestUrls)
        ? [
            ...new Set(
              row.pullRequestUrls
                .slice(0, 100)
                .map((url) => githubLink(url, "pull"))
                .filter(Boolean),
            ),
          ]
        : [],
    };
    if (
      typeof row.repo === "string" &&
      /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(row.repo) &&
      row.repo.length <= 200
    )
      result.repo = row.repo;
    if (count(row.issue) && row.issue > 0) result.issue = row.issue;
    if (id(row.projectItemId)) result.projectItemId = row.projectItemId;
    if (
      row.stageProjection === "available" &&
      typeof row.stageLabel === "string" &&
      /^state:[a-zA-Z0-9_-]{1,80}$/.test(row.stageLabel)
    )
      result.stageLabel = row.stageLabel;
    if (typeof row.retryable === "boolean") result.retryable = row.retryable;
    // Error bodies and stage reasons stay in the owner service. Availability
    // is sufficient for this view and cannot accidentally expose private text.
    return result;
  });
  const result = {
    schema: input.schema,
    authority: input.authority,
    direction: input.direction,
    state: input.state,
    stageProjection: input.stageProjection,
    items,
  };
  if (["healthy", "degraded"].includes(input.state)) {
    for (const key of ["projected", "unchanged", "failed"])
      if (
        input[key] !== undefined &&
        input[key] !== items.filter((item) => item.state === key).length
      )
        throw new Error("Inconsistent projection counters");
    if (
      input.unavailable !== undefined &&
      (count(input.unavailable) === undefined ||
        input.unavailable > items.length)
    )
      throw new Error("Inconsistent metadata counter");
  }
  for (const key of ["projected", "unchanged", "failed", "unavailable"])
    if (count(input[key]) !== undefined) result[key] = input[key];
  for (const key of ["lastAttemptAt", "lastSuccessAt"])
    if (date(input[key])) result[key] = date(input[key]);
  if (id(input.projectId)) result.projectId = input.projectId;
  if (typeof input.retryable === "boolean") result.retryable = input.retryable;
  return result;
}

export async function pollProjects({ view, url, apiKey, fetchImpl = fetch }) {
  if (!url || !apiKey) {
    view.setSource("projects", "not_configured");
    return false;
  }
  try {
    const response = await fetchImpl(
      new URL("/v1/fleet/projects", componentEndpoint(url)),
      {
        headers: {
          Authorization: `Bearer ${apiKey}`,
          Accept: "application/json",
        },
        redirect: "error",
        signal: AbortSignal.timeout(4000),
      },
    );
    view.setProjects(await readComponentJson(response));
    view.setSource("projects", "connected");
    return true;
  } catch {
    view.setSource("projects", "unavailable");
    return false;
  }
}
