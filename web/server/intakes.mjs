import { createHash } from "node:crypto";
import { componentEndpoint, readComponentJson } from "./upstream.mjs";

const idPattern = /^[a-z0-9][a-z0-9_-]{7,63}$/;
const digestPattern = /^[a-f0-9]{64}$/;
const repositoryPattern = /^[A-Za-z0-9_-]+\/[A-Za-z0-9_.-]+$/;
const timestampPattern = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const sha = (text) => createHash("sha256").update(text).digest("hex");
const object = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const exact = (value, fields) =>
  object(value) &&
  Object.keys(value).length === fields.length &&
  fields.every((key) => Object.hasOwn(value, key));
const string = (value, max) =>
  typeof value === "string" &&
  value.length > 0 &&
  !/[\uD800-\uDFFF]/u.test(value) &&
  Buffer.byteLength(value) <= max;
const matches = (value, pattern) =>
  typeof value === "string" && pattern.test(value);
const timestamp = (value) =>
  matches(value, timestampPattern) &&
  Number.isFinite(Date.parse(value)) &&
  new Date(value).toISOString() === value.replace("Z", ".000Z");
const repository = (value) =>
  string(value, 200) && repositoryPattern.test(value) && !value.includes("..");

function requestDigests(input) {
  if (
    !exact(input, ["schema", "intakeId", "workRepository", "title", "body"]) ||
    input.schema !== "hi/nestor/intake-request/v1" ||
    !matches(input.intakeId, idPattern) ||
    !repository(input.workRepository) ||
    !string(input.title, 256) ||
    !(input.body === "" || string(input.body, 60000)) ||
    input.body.includes("nestor:fleet-intake:") ||
    Buffer.byteLength(JSON.stringify(input)) > 65536
  )
    throw new Error("invalid_request");
  // nlohmann::json hashes sorted keys and canonical lower-case repository names.
  const canonical = {
    body: input.body,
    intakeId: input.intakeId,
    schema: input.schema,
    title: input.title,
    workRepository: input.workRepository.toLowerCase(),
  };
  const requestDigest = sha(JSON.stringify(canonical));
  const marker = `<!-- nestor:fleet-intake:v1 id=${input.intakeId} digest=${requestDigest} -->`;
  return { requestDigest, bodyDigest: sha(`${input.body}\n\n${marker}`) };
}

function validRecord(record, intakeId) {
  const fields = [
    "schema",
    "intakeId",
    "workRepository",
    "requestDigest",
    "bodyDigest",
    "phase",
    "generation",
    "createdAt",
  ];
  if (!object(record)) return false;
  if (["creating", "created"].includes(record.phase)) fields.push("attemptId");
  if (record.phase === "created") fields.push("issue", "receipt");
  if (
    !exact(record, fields) ||
    record.schema !== "hi/nestor/intake/v1" ||
    record.intakeId !== intakeId ||
    !repository(record.workRepository) ||
    record.workRepository !== record.workRepository.toLowerCase() ||
    !matches(record.requestDigest, digestPattern) ||
    !matches(record.bodyDigest, digestPattern) ||
    !["prepared", "creating", "created"].includes(record.phase) ||
    record.generation !== 1 ||
    !timestamp(record.createdAt) ||
    (record.phase !== "prepared" &&
      !matches(record.attemptId, /^[a-f0-9]{32}$/))
  )
    return false;
  if (record.phase !== "created") return true;
  return (
    exact(record.issue, ["repository", "number", "url"]) &&
    record.issue.repository === record.workRepository &&
    Number.isSafeInteger(record.issue.number) &&
    record.issue.number > 0 &&
    record.issue.url ===
      `https://github.com/${record.workRepository}/issues/${record.issue.number}` &&
    exact(record.receipt, ["kind", "observedAt"]) &&
    record.receipt.kind === "confirmed_issue" &&
    timestamp(record.receipt.observedAt)
  );
}

// This is an authenticated proxy, not a local intake store or dispatch queue.
export function createIntakeService({ url, token, fetchImpl = fetch }) {
  const endpoint = componentEndpoint(url);
  if (!string(token, 8192) || /[\r\n]/.test(token))
    throw new Error("Nestor credentials are required");
  async function call(intakeId, requestDigest, input, bodyDigest) {
    const uncertain = (error = "intake_unconfirmed", code = 503) => ({
      code,
      body: { error, intakeId, outcome: "unknown" },
    });
    try {
      const response = await fetchImpl(
        new URL(`/v1/research/intakes${input ? "" : `/${intakeId}`}`, endpoint),
        {
          method: input ? "POST" : "GET",
          headers: {
            authorization: `Bearer ${token}`,
            ...(input ? { "content-type": "application/json" } : {}),
          },
          ...(input ? { body: JSON.stringify(input) } : {}),
          redirect: "error",
          signal: AbortSignal.timeout(5000),
        },
      );
      if (response.status !== 200) {
        await response.body?.cancel();
        if (response.status === 409) return uncertain("intake_conflict", 409);
        if (!input && response.status === 404)
          return uncertain("intake_not_found", 404);
        return uncertain();
      }
      const record = await readComponentJson(response);
      if (!validRecord(record, intakeId)) return uncertain();
      if (record.requestDigest !== requestDigest)
        return input ? uncertain() : uncertain("intake_conflict", 409);
      if (
        input &&
        (record.bodyDigest !== bodyDigest ||
          record.workRepository !== input.workRepository.toLowerCase())
      )
        return uncertain();
      return { code: 200, body: { intake: record } };
    } catch {
      // Request bytes may already have reached Nestor. Do not retry or log its error.
      return uncertain();
    }
  }
  return {
    async submit(input) {
      let digests;
      try {
        digests = requestDigests(input);
      } catch {
        return {
          code: 400,
          body: { error: "invalid_request", outcome: "not_submitted" },
        };
      }
      return call(
        input.intakeId,
        digests.requestDigest,
        input,
        digests.bodyDigest,
      );
    },
    async inspect(intakeId, requestDigest) {
      if (
        !matches(intakeId, idPattern) ||
        !matches(requestDigest, digestPattern)
      )
        return { code: 400, body: { error: "invalid_request" } };
      return call(intakeId, requestDigest);
    },
  };
}
