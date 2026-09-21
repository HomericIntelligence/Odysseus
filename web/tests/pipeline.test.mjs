import { test } from "node:test";
import assert from "node:assert/strict";
import { pipelineOwners } from "../src/pipeline.ts";

test("pipeline ownership joins canonical task claims, keeps multiple reported owners explicit, and excludes builds and conflicting issues", () => {
  const task = {
    taskId: "task-1",
    workIssueUrl: "https://github.com/org/repo/issues/1",
  };
  const owner = {
    id: "session-1",
    kind: "session",
    taskId: "task-1",
    agentId: "agent-1",
    workerId: "worker-1",
    generation: 2,
    claimStatus: "claimed",
    issueUrl: task.workIssueUrl,
  };
  const items = [
    owner,
    { ...owner, id: "session-2", agentId: "agent-2", claimStatus: "reserved" },
    { ...owner, id: "wrong-task", taskId: "task-2" },
    {
      ...owner,
      id: "wrong-issue",
      issueUrl: "https://github.com/org/repo/issues/2",
    },
    { ...owner, id: "build", kind: "build-job" },
    { ...owner, id: "released", claimStatus: "released" },
    { ...owner, id: "missing-generation", generation: undefined },
  ];
  assert.deepEqual(
    pipelineOwners(task, items).map((item) => item.id),
    ["session-1", "session-2"],
  );
});
