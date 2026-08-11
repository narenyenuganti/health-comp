import {
  authenticatedClient,
  base64UrlDecode,
  defaultDependencies,
  errorResponse,
  type HandlerDependencies,
  jsonResponse,
  sha256Hex,
} from "../_shared/invite_http.ts";

export type { InviteRpcClient } from "../_shared/invite_http.ts";

function parseToken(value: unknown): Uint8Array | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const body = value as Record<string, unknown>;
  if (Object.keys(body).length !== 1 || typeof body.token !== "string") {
    return null;
  }
  return base64UrlDecode(body.token);
}

export async function claimCompetitionInviteHandler(
  request: Request,
  dependencies: HandlerDependencies = defaultDependencies,
): Promise<Response> {
  if (request.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Method not allowed");
  }

  let parsed: unknown;
  try {
    parsed = await request.json();
  } catch {
    return errorResponse(400, "invalid_request", "Invalid invitation token");
  }
  const tokenBytes = parseToken(parsed);
  if (!tokenBytes) {
    return errorResponse(400, "invalid_request", "Invalid invitation token");
  }

  const client = await authenticatedClient(request, dependencies);
  if (!client) {
    return errorResponse(401, "unauthorized", "Authentication required");
  }

  const { data, error } = await client.rpc("claim_competition_invite", {
    token_digest: `\\x${await sha256Hex(tokenBytes)}`,
  });
  if (error) {
    if (error.message === "cannot_claim_own_invite") {
      return errorResponse(
        409,
        "self_claim_forbidden",
        "You cannot claim your own invitation",
      );
    }
    if (error.message === "authentication_required") {
      return errorResponse(401, "unauthorized", "Authentication required");
    }
    if (error.code === "P0001") {
      return errorResponse(404, "invite_unavailable", "Invitation unavailable");
    }
    return errorResponse(
      503,
      "temporarily_unavailable",
      "Unable to claim invitation right now",
    );
  }
  if (!data) {
    return errorResponse(404, "invite_unavailable", "Invitation unavailable");
  }

  return jsonResponse(200, { competitionId: data });
}

if (import.meta.main) {
  Deno.serve((request) => claimCompetitionInviteHandler(request));
}
