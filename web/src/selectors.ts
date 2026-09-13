export type TrackedItem = {
  id: string;
  kind: string;
  generation?: number;
  agentId?: string;
  workerId?: string;
  taskId?: string;
  sessionId?: string;
  executionId?: string;
  activity?: string;
  claimStatus?: string;
  lastActivityAt?: string;
  [key: string]: unknown;
};
export function sourceIsFresh(
  source: { status: string; observedAt: string } | undefined,
  now: number,
): boolean {
  if (source?.status !== "connected") return false;
  const age = now - Date.parse(source.observedAt);
  return Number.isFinite(age) && age >= -5000 && age <= 15000;
}
export function activeAgentCount(items: TrackedItem[], now: number): number {
  const working = items.filter(
    (item) =>
      item.kind === "session" &&
      item.taskId &&
      item.agentId &&
      item.workerId &&
      Number.isSafeInteger(item.generation) &&
      item.claimStatus === "claimed" &&
      ["running", "model_working", "tool_running"].includes(
        item.activity ?? "",
      ) &&
      item.lastActivityAt &&
      now - Date.parse(item.lastActivityAt) >= -5000 &&
      now - Date.parse(item.lastActivityAt) <= 15000,
  );
  return new Set(working.map((item) => item.agentId)).size;
}
export function matchPacket<T extends TrackedItem>(
  items: T[],
  packet: Record<string, unknown>,
): T | undefined {
  if (!Number.isSafeInteger(packet.generation)) return undefined;
  const matches = items.filter(
    (item) =>
      item.generation === packet.generation &&
      ["taskId", "sessionId", "executionId"].some(
        (key) => packet[key] && item[key] === packet[key],
      ) &&
      ["taskId", "sessionId", "executionId", "workerId", "agentId"].every(
        (key) => !packet[key] || item[key] === packet[key],
      ),
  );
  return matches.length === 1 ? matches[0] : undefined;
}
export function packetHost<T extends TrackedItem>(
  items: T[],
  packet: Record<string, unknown>,
): string | undefined {
  if (typeof packet.host === "string" && packet.host) return packet.host;
  const owner = matchPacket(items, packet);
  return typeof owner?.host === "string" ? owner.host : undefined;
}
export function currentItem<T extends TrackedItem>(
  items: T[],
  key: Pick<TrackedItem, "id" | "kind" | "generation">,
): T | undefined {
  return items.find(
    (item) =>
      item.id === key.id &&
      item.kind === key.kind &&
      item.generation === key.generation,
  );
}
