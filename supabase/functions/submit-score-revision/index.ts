import {
  authenticated,
  body,
  containsFingerprint,
  defaultUserDependencies,
  error,
  isBigintString,
  isUuid,
  json,
  mapRpcError,
  type UserDependencies,
} from "../_shared/scoring_http.ts";
export type { ScoringRpcClient } from "../_shared/scoring_http.ts";
const modes = new Set(["activeEnergyKilocalories", "moveMinutes"]),
  stands = new Set(["standHours", "rollHours", "unknown"]);
const reasons = new Set([
  "available",
  "sourceDataUnavailable",
  "unsupportedActivityConfiguration",
  "invalidSourceData",
  "missingMoveValue",
  "missingMoveGoal",
  "nonPositiveMoveGoal",
  "missingExerciseValue",
  "missingExerciseGoal",
  "nonPositiveExerciseGoal",
  "missingStandOrRollValue",
  "missingStandOrRollGoal",
  "nonPositiveStandOrRollGoal",
  "summaryPaused",
  "summaryPauseStateUnknown",
  "invalidNumericCalculation",
]);
const keys = new Set([
  "version",
  "competitionId",
  "semanticEventId",
  "dayOrdinal",
  "clientRevision",
  "evaluatedAt",
  "moveMode",
  "standMode",
  "moveBasisPoints",
  "exerciseBasisPoints",
  "standBasisPoints",
  "availabilityReason",
  "scoringPolicyIdentity",
  "wireContentSHA256",
]);
function parse(value: unknown): Record<string, unknown> | null {
  if (
    !value || typeof value !== "object" || Array.isArray(value) ||
    containsFingerprint(value)
  ) return null;
  const v = value as Record<string, unknown>;
  if (
    Object.keys(v).some((k) => !keys.has(k)) || v.version !== 1 ||
    !isUuid(v.competitionId) || !isUuid(v.semanticEventId) ||
    !Number.isInteger(v.dayOrdinal) || Number(v.dayOrdinal) < 1 ||
    Number(v.dayOrdinal) > 7 || !isBigintString(v.clientRevision) ||
    typeof v.evaluatedAt !== "string" ||
    !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z$/.test(v.evaluatedAt) ||
    !modes.has(String(v.moveMode)) || !stands.has(String(v.standMode)) ||
    !reasons.has(String(v.availabilityReason)) ||
    v.scoringPolicyIdentity !== "healthcomp.activity-score.v1" ||
    typeof v.wireContentSHA256 !== "string" ||
    !/^[0-9a-f]{64}$/.test(v.wireContentSHA256)
  ) return null;
  const nums = [v.moveBasisPoints, v.exerciseBasisPoints, v.standBasisPoints];
  if (
    v.availabilityReason === "available"
      ? v.standMode === "unknown" ||
        !nums.every((n) =>
          Number.isInteger(n) && Number(n) >= 0 && Number(n) <= 20000
        )
      : !nums.every((n) => n === null)
  ) return null;
  return v;
}
const rejectionCodes = new Set([
  "divergent_duplicate",
  "revision_regression",
  "window_stable",
  "competition_terminal",
  "competition_finalized",
]);
function isScoreResponse(value: unknown): value is Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const v = value as Record<string, unknown>;
  const rejected = v.disposition === "rejected";
  const expectedKeys = rejected
    ? [
      "acceptedCentiPoints",
      "acceptedServerSeq",
      "code",
      "competitionCursor",
      "disposition",
      "wireContentSHA256",
    ]
    : [
      "acceptedCentiPoints",
      "acceptedServerSeq",
      "competitionCursor",
      "disposition",
      "wireContentSHA256",
    ];
  if (Object.keys(v).sort().join("|") !== expectedKeys.join("|")) return false;
  if (
    rejected
      ? !rejectionCodes.has(String(v.code))
      : !["appended", "duplicate"].includes(String(v.disposition))
  ) return false;
  if (
    !(v.acceptedCentiPoints === null ||
      Number.isInteger(v.acceptedCentiPoints) &&
        Number(v.acceptedCentiPoints) >= 0 &&
        Number(v.acceptedCentiPoints) <= 60000)
  ) return false;
  if (
    !(v.wireContentSHA256 === null ||
      typeof v.wireContentSHA256 === "string" &&
        /^[0-9a-f]{64}$/.test(v.wireContentSHA256))
  ) return false;
  if (!(v.acceptedServerSeq === null || isBigintString(v.acceptedServerSeq))) {
    return false;
  }
  return isBigintString(v.competitionCursor, true);
}
export async function submitScoreRevisionHandler(
  request: Request,
  deps: UserDependencies = defaultUserDependencies,
): Promise<Response> {
  if (request.method !== "POST") {
    return error(405, "method_not_allowed", "Method not allowed");
  }
  const parsed = parse(await body(request));
  if (!parsed) return error(400, "invalid_request", "Invalid score revision");
  const client = await authenticated(request, deps);
  if (!client) return error(401, "unauthorized", "Authentication required");
  const { data, error: rpcError } = await client.rpc("submit_score_revision", {
    competition_id: parsed.competitionId,
    semantic_event_id: parsed.semanticEventId,
    day_ordinal: parsed.dayOrdinal,
    client_revision: parsed.clientRevision,
    evaluated_at: parsed.evaluatedAt,
    move_mode: parsed.moveMode,
    stand_mode: parsed.standMode,
    move_basis_points: parsed.moveBasisPoints,
    exercise_basis_points: parsed.exerciseBasisPoints,
    stand_basis_points: parsed.standBasisPoints,
    availability_reason: parsed.availabilityReason,
    scoring_policy_identity: parsed.scoringPolicyIdentity,
    expected_wire_content_sha256: parsed.wireContentSHA256,
  });
  if (rpcError) return mapRpcError(rpcError);
  if (!isScoreResponse(data)) {
    return error(
      503,
      "temporarily_unavailable",
      "Unable to process request right now",
    );
  }
  if (data.disposition === "rejected") {
    return json(409, data);
  }
  return json(200, data);
}
if (import.meta.main) {
  Deno.serve((request) => submitScoreRevisionHandler(request));
}
