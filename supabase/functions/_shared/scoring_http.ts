import { createClient } from "@supabase/supabase-js";

export interface RpcError {
  message: string;
  code?: string;
  details?: string;
}
export interface ScoringRpcClient {
  auth: {
    getUser(): Promise<
      {
        data: { user: { id: string } | null };
        error: { message: string } | null;
      }
    >;
  };
  rpc(
    name: string,
    args: Record<string, unknown>,
  ): Promise<{ data: unknown; error: RpcError | null }>;
}
export interface UserDependencies {
  createUserClient(authorization: string): ScoringRpcClient;
}
export interface ServiceDependencies {
  createServiceClient(): ScoringRpcClient;
}

export const defaultUserDependencies: UserDependencies = {
  createUserClient(authorization) {
    const url = Deno.env.get("SUPABASE_URL"),
      key = Deno.env.get("SUPABASE_ANON_KEY");
    if (!url || !key) {
      throw new Error("Supabase function environment is not configured");
    }
    return createClient(url, key, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: authorization } },
    }) as unknown as ScoringRpcClient;
  },
};
export const defaultServiceDependencies: ServiceDependencies = {
  createServiceClient() {
    const url = Deno.env.get("SUPABASE_URL"),
      key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !key) {
      throw new Error("Supabase service environment is not configured");
    }
    return createClient(url, key, {
      auth: { persistSession: false, autoRefreshToken: false },
    }) as unknown as ScoringRpcClient;
  },
};
export function json(status: number, body: Record<string, unknown>) {
  return Response.json(body, {
    status,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json; charset=utf-8",
    },
  });
}
export function error(status: number, code: string, message: string) {
  return json(status, { error: { code, message } });
}
export async function authenticated(request: Request, deps: UserDependencies) {
  const authorization = request.headers.get("authorization");
  if (!authorization || !/^Bearer\s+\S+$/i.test(authorization)) return null;
  const client = deps.createUserClient(authorization);
  const result = await client.auth.getUser();
  return result.error || !result.data.user ? null : client;
}
export function isUuid(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(
      value,
    );
}
export function isBigintString(
  value: unknown,
  allowZero = false,
): value is string {
  return typeof value === "string" &&
    (allowZero ? /^(0|[1-9][0-9]{0,18})$/ : /^[1-9][0-9]{0,18}$/).test(value) &&
    BigInt(value) <= 9223372036854775807n;
}
const forbiddenPrefixes = [
  "activity-snapshot:",
  "accepted-activity-score:",
  "live-day-score:",
];
export function containsFingerprint(value: unknown): boolean {
  if (typeof value === "string") {
    if (forbiddenPrefixes.some((p) => value.startsWith(p))) return true;
    try {
      const normalized = value.replaceAll("-", "+").replaceAll("_", "/") +
        "=".repeat((4 - value.length % 4) % 4);
      const decoded = atob(normalized);
      if (forbiddenPrefixes.some((p) => decoded.startsWith(p))) return true;
    } catch { /* not base64 */ }
    return false;
  }
  if (Array.isArray(value)) return value.some(containsFingerprint);
  if (value && typeof value === "object") {
    return Object.entries(value as Record<string, unknown>).some(([k, v]) =>
      /fingerprint/i.test(k) || containsFingerprint(v)
    );
  }
  return false;
}
export async function body(request: Request): Promise<unknown | null> {
  try {
    return await request.json();
  } catch {
    return null;
  }
}
export function mapRpcError(rpcError: RpcError): Response {
  const message = rpcError.message;
  if (message === "competition_not_found") {
    return error(404, "competition_not_found", "Competition unavailable");
  }
  if (message === "authentication_required") {
    return error(401, "unauthorized", "Authentication required");
  }
  if (
    [
      "divergent_duplicate",
      "revision_regression",
      "attestation_regression",
      "attestation_downgrade",
      "window_stable",
      "competition_terminal",
      "window_not_stable",
      "best_available_not_ready",
    ].includes(message)
  ) return error(409, message, "Request conflicts with accepted state");
  if (
    [
      "invalid_score",
      "day_mismatch",
      "wrong_policy",
      "invalid_attestation",
      "revision_not_found",
      "wire_digest_mismatch",
      "window_commitment_mismatch",
    ].includes(message)
  ) return error(400, message, "Invalid request");
  return error(
    503,
    "temporarily_unavailable",
    "Unable to process request right now",
  );
}
