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
const keys = new Set([
  "version",
  "competitionId",
  "semanticEventId",
  "attestationVersion",
  "basis",
  "acceptedRevisions",
  "windowCommitmentSHA256",
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
    !isBigintString(v.attestationVersion) ||
    !(["stable", "best_available"].includes(String(v.basis))) ||
    !Array.isArray(v.acceptedRevisions) || v.acceptedRevisions.length !== 7 ||
    !v.acceptedRevisions.every((x) => isBigintString(x, true)) ||
    (v.basis === "stable" && v.acceptedRevisions.includes("0")) ||
    typeof v.windowCommitmentSHA256 !== "string" ||
    !/^[0-9a-f]{64}$/.test(v.windowCommitmentSHA256)
  ) return null;
  return v;
}
export async function attestFinalWindowHandler(
  request: Request,
  deps: UserDependencies = defaultUserDependencies,
): Promise<Response> {
  if (request.method !== "POST") {
    return error(405, "method_not_allowed", "Method not allowed");
  }
  const parsed = parse(await body(request));
  if (!parsed) {
    return error(400, "invalid_request", "Invalid final-window attestation");
  }
  const client = await authenticated(request, deps);
  if (!client) return error(401, "unauthorized", "Authentication required");
  const { data, error: rpcError } = await client.rpc("attest_final_window", {
    competition_id: parsed.competitionId,
    semantic_event_id: parsed.semanticEventId,
    attestation_version: parsed.attestationVersion,
    basis: parsed.basis,
    accepted_revisions: parsed.acceptedRevisions,
    expected_window_commitment_sha256: parsed.windowCommitmentSHA256,
  });
  if (rpcError) return mapRpcError(rpcError);
  return json(200, data as Record<string, unknown>);
}
if (import.meta.main) {
  Deno.serve((request) => attestFinalWindowHandler(request));
}
