import {
  body,
  defaultServiceDependencies,
  error,
  json,
  mapRpcError,
  type ServiceDependencies,
} from "../_shared/scoring_http.ts";
export type { ScoringRpcClient } from "../_shared/scoring_http.ts";
interface Deps extends ServiceDependencies {
  serviceAuthorization: string;
}
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim();
const defaults: Deps = {
  ...defaultServiceDependencies,
  serviceAuthorization: serviceRoleKey ? `Bearer ${serviceRoleKey}` : "",
};
export async function finalizeCompetitionsHandler(
  request: Request,
  deps: Deps = defaults,
): Promise<Response> {
  if (request.method !== "POST") {
    return error(405, "method_not_allowed", "Method not allowed");
  }
  if (
    !deps.serviceAuthorization ||
    request.headers.get("authorization") !== deps.serviceAuthorization
  ) return error(401, "unauthorized", "Authentication required");
  const parsed = await body(request);
  if (
    !parsed || typeof parsed !== "object" || Array.isArray(parsed) ||
    Object.keys(parsed).some((k) => k !== "batchSize")
  ) return error(400, "invalid_request", "Invalid request");
  const size = (parsed as Record<string, unknown>).batchSize ?? 100;
  if (!Number.isInteger(size) || Number(size) < 1 || Number(size) > 1000) {
    return error(400, "invalid_request", "Invalid request");
  }
  const { data, error: rpcError } = await deps.createServiceClient().rpc(
    "finalize_due_competitions",
    { batch_size: size },
  );
  if (rpcError) return mapRpcError(rpcError);
  return json(200, { finalizedCount: String(data) });
}
if (import.meta.main) {
  Deno.serve((request) => finalizeCompetitionsHandler(request));
}
