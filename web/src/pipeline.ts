import type { TrackedItem } from "./selectors";

export type PipelineTask = {
  taskId: string;
  orchestrationState: string;
  repo?: string;
  issue?: number;
  orchestrationIssueUrl?: string;
  workIssueUrl?: string;
  pullRequestUrls: string[];
  stageLabel?: string;
  stageProjection: string;
  state: string;
};
export type ProjectsProjection = {
  state: string;
  stageProjection: string;
  items: PipelineTask[];
  fresh: boolean;
  observedAt: string;
  lastAttemptAt?: string;
  lastSuccessAt?: string;
  projected?: number;
  unchanged?: number;
  failed?: number;
  unavailable?: number;
};

export function pipelineOwners<T extends TrackedItem>(
  task: Pick<PipelineTask, "taskId" | "workIssueUrl">,
  items: T[],
): T[] {
  return items.filter(
    (item) =>
      item.kind === "session" &&
      item.taskId === task.taskId &&
      item.agentId &&
      item.workerId &&
      Number.isSafeInteger(item.generation) &&
      (item.generation ?? 0) > 0 &&
      ["claimed", "reserved"].includes(item.claimStatus ?? "") &&
      (!task.workIssueUrl ||
        !item.issueUrl ||
        task.workIssueUrl === item.issueUrl),
  );
}
