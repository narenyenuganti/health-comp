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

interface InvitePreviewRow {
  competition_id: string;
  state: "pending" | "accepted";
  sender: { id: string; display_name: string };
  time_zone_identifier: string;
  expires_at: string;
}

function parseToken(value: unknown): Uint8Array | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const body = value as Record<string, unknown>;
  if (Object.keys(body).length !== 1 || typeof body.token !== "string") {
    return null;
  }
  return base64UrlDecode(body.token);
}

function isPreviewRow(value: unknown): value is InvitePreviewRow {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const row = value as Record<string, unknown>;
  const sender = row.sender as Record<string, unknown> | null;
  return typeof row.competition_id === "string" &&
    (row.state === "pending" || row.state === "accepted") &&
    !!sender && typeof sender === "object" &&
    typeof sender.id === "string" &&
    typeof sender.display_name === "string" &&
    typeof row.time_zone_identifier === "string" &&
    typeof row.expires_at === "string";
}

// Recipient-only preview of one invite link: who sent it, the sender's
// calendar and when it expires. Every unavailable case is one 404.
export async function previewCompetitionInviteHandler(
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

  let client: Awaited<ReturnType<typeof authenticatedClient>>;
  try {
    client = await authenticatedClient(request, dependencies);
  } catch {
    return errorResponse(
      503,
      "temporarily_unavailable",
      "Unable to open invitation right now",
    );
  }
  if (!client) {
    return errorResponse(401, "unauthorized", "Authentication required");
  }

  const { data, error } = await client.rpc("preview_competition_invite", {
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
    if (error.message === "active_match_exists") {
      return errorResponse(
        409,
        "active_match_exists",
        "A match with this account is in progress",
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
      "Unable to open invitation right now",
    );
  }
  const row: unknown = data;
  if (!isPreviewRow(row)) {
    return errorResponse(
      503,
      "temporarily_unavailable",
      "Unable to open invitation right now",
    );
  }

  return jsonResponse(200, {
    competitionId: row.competition_id,
    state: row.state,
    sender: { id: row.sender.id, displayName: row.sender.display_name },
    timeZoneIdentifier: row.time_zone_identifier,
    expiresAt: row.expires_at,
  });
}

if (import.meta.main) {
  Deno.serve((request) => previewCompetitionInviteHandler(request));
}
