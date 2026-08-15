import {
  authenticatedContext,
  base64UrlEncode,
  defaultDependencies,
  defaultServiceDependencies,
  errorResponse,
  type HandlerDependencies,
  isUuid,
  jsonResponse,
  type ServiceClientDependencies,
  sha256Hex,
} from "../_shared/invite_http.ts";

export type { InviteRpcClient } from "../_shared/invite_http.ts";

interface CreateDependencies
  extends HandlerDependencies, ServiceClientDependencies {
  deriveToken(userId: string, idempotencyKey: string): Promise<Uint8Array>;
}

const dependencies: CreateDependencies = {
  ...defaultDependencies,
  ...defaultServiceDependencies,
  deriveToken: (userId, idempotencyKey) => {
    const secret = Deno.env.get("INVITE_TOKEN_DERIVATION_KEY_V1");
    if (!secret) {
      throw new Error("Invite token derivation is not configured");
    }
    return deriveInviteTokenV1(userId, idempotencyKey, secret);
  },
};

const textEncoder = new TextEncoder();

export async function deriveInviteTokenV1(
  userId: string,
  idempotencyKey: string,
  secret: string,
): Promise<Uint8Array> {
  if (!isUuid(userId) || !isUuid(idempotencyKey)) {
    throw new Error("Invite token derivation requires UUID inputs");
  }
  const secretBytes = textEncoder.encode(secret);
  if (secretBytes.length < 32) {
    throw new Error("Invite token derivation key is too short");
  }
  const key = await crypto.subtle.importKey(
    "raw",
    secretBytes,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const message = textEncoder.encode(
    `healthcomp.invite-token.v1\0${userId.toLowerCase()}\0${idempotencyKey.toLowerCase()}`,
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, message));
}

function parseBody(value: unknown): {
  timeZoneIdentifier: string;
  rematchParentId: string | null;
  idempotencyKey: string;
} | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const body = value as Record<string, unknown>;
  const allowedKeys = new Set([
    "timeZoneIdentifier",
    "rematchParentId",
    "idempotencyKey",
  ]);
  if (Object.keys(body).some((key) => !allowedKeys.has(key))) return null;
  if (
    typeof body.timeZoneIdentifier !== "string" ||
    body.timeZoneIdentifier.length < 1 || body.timeZoneIdentifier.length > 255
  ) return null;
  if (
    body.rematchParentId !== undefined && body.rematchParentId !== null &&
    !isUuid(body.rematchParentId)
  ) {
    return null;
  }
  if (!isUuid(body.idempotencyKey)) return null;
  return {
    timeZoneIdentifier: body.timeZoneIdentifier,
    rematchParentId: (body.rematchParentId as string | null | undefined) ??
      null,
    idempotencyKey: body.idempotencyKey,
  };
}

export async function createCompetitionInviteHandler(
  request: Request,
  injected: CreateDependencies = dependencies,
): Promise<Response> {
  if (request.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Method not allowed");
  }

  let parsed: unknown;
  try {
    parsed = await request.json();
  } catch {
    return errorResponse(400, "invalid_request", "Invalid request");
  }
  const body = parseBody(parsed);
  if (!body) return errorResponse(400, "invalid_request", "Invalid request");

  const authenticated = await authenticatedContext(request, injected);
  if (!authenticated) {
    return errorResponse(401, "unauthorized", "Authentication required");
  }

  let bytes: Uint8Array;
  try {
    bytes = await injected.deriveToken(
      authenticated.userId,
      body.idempotencyKey,
    );
  } catch {
    return errorResponse(
      500,
      "invite_creation_failed",
      "Unable to create invitation",
    );
  }
  if (bytes.length !== 32) {
    throw new Error("Token generator must return 32 bytes");
  }
  const token = base64UrlEncode(bytes);
  const tokenDigest = `\\x${await sha256Hex(bytes)}`;
  const serviceClient = injected.createServiceClient();
  const { data, error } = await serviceClient.rpc("create_competition_invite", {
    token_digest: tokenDigest,
    creator_time_zone_identifier: body.timeZoneIdentifier,
    rematch_parent_id: body.rematchParentId,
    creator_auth_user_id: authenticated.userId,
    creation_idempotency_key: body.idempotencyKey,
    token_derivation_version: 1,
  });

  if (error) {
    if (error.message === "invalid_time_zone") {
      return errorResponse(400, "invalid_time_zone", "Invalid time zone");
    }
    if (error.message === "rematch_not_allowed") {
      return errorResponse(403, "rematch_not_allowed", "Rematch not allowed");
    }
    if (error.message === "idempotency_conflict") {
      return errorResponse(
        409,
        "idempotency_conflict",
        "Invitation request conflicts with an earlier request",
      );
    }
    if (
      error.message === "active_profile_required" ||
      error.message === "authentication_required"
    ) {
      return errorResponse(401, "unauthorized", "Authentication required");
    }
    return errorResponse(
      500,
      "invite_creation_failed",
      "Unable to create invitation",
    );
  }
  if (!data) {
    return errorResponse(
      500,
      "invite_creation_failed",
      "Unable to create invitation",
    );
  }

  return jsonResponse(201, { competitionId: data, token });
}

if (import.meta.main) {
  Deno.serve((request) => createCompetitionInviteHandler(request));
}
