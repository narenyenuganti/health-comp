import { createClient } from "@supabase/supabase-js";

export type DeletionPhase =
  | "prepared"
  | "token_ready"
  | "apple_revoked"
  | "auth_delete_pending"
  | "completed";

export interface DeletionProgress {
  profileId: string;
  phase: DeletionPhase;
  appleProviderId: string | null;
  authUserId: string | null;
}

export interface AppleTokenExchange {
  refreshToken: string;
  idToken: string;
}

export interface DeleteAccountDependencies {
  appleClientID: string;
  now(): Date;
  authenticate(authorization: string): Promise<string>;
  begin(authUserID: string): Promise<DeletionProgress>;
  exchangeAuthorizationCode(code: string): Promise<AppleTokenExchange>;
  storeAppleToken(
    profileID: string,
    refreshToken: string,
  ): Promise<DeletionProgress>;
  loadAppleToken(profileID: string): Promise<string>;
  revokeAppleToken(token: string): Promise<void>;
  markAppleRevoked(profileID: string): Promise<DeletionProgress>;
  anonymize(profileID: string): Promise<DeletionProgress>;
  deleteAuthUser(authUserID: string): Promise<void>;
  complete(profileID: string): Promise<DeletionProgress>;
}

export class AccountDeletionHTTPError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(code);
    this.name = "AccountDeletionHTTPError";
  }
}

interface DeleteAccountBody {
  authorizationCode: string;
  nonce: string;
}

function jsonResponse(status: number, body: Record<string, string>): Response {
  return Response.json(body, {
    status,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json; charset=utf-8",
    },
  });
}

function bearerAuthorization(request: Request): string | null {
  const value = request.headers.get("authorization")?.trim() ?? "";
  return /^Bearer\s+\S+$/i.test(value) ? value : null;
}

function containsControlOrWhitespace(value: string): boolean {
  for (const scalar of value) {
    const code = scalar.codePointAt(0)!;
    if (code <= 0x20 || code === 0x7f) return true;
  }
  return false;
}

async function parseBody(request: Request): Promise<DeleteAccountBody> {
  const contentType = request.headers.get("content-type")?.toLowerCase() ?? "";
  if (!contentType.startsWith("application/json")) {
    throw new AccountDeletionHTTPError(400, "invalid_request");
  }

  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declaredLength) && declaredLength > 8_192) {
    throw new AccountDeletionHTTPError(400, "invalid_request");
  }

  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > 8_192) {
    throw new AccountDeletionHTTPError(400, "invalid_request");
  }

  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new AccountDeletionHTTPError(400, "invalid_request");
  }

  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new AccountDeletionHTTPError(400, "invalid_request");
  }
  const record = value as Record<string, unknown>;
  const keys = Object.keys(record).sort();
  if (
    keys.length !== 2 ||
    keys[0] !== "authorization_code" ||
    keys[1] !== "nonce"
  ) {
    throw new AccountDeletionHTTPError(400, "invalid_request");
  }

  const authorizationCode = record.authorization_code;
  const nonce = record.nonce;
  if (
    typeof authorizationCode !== "string" ||
    authorizationCode.length < 16 ||
    authorizationCode.length > 4_096 ||
    containsControlOrWhitespace(authorizationCode) ||
    typeof nonce !== "string" ||
    !/^[0-9a-f]{64}$/.test(nonce)
  ) {
    throw new AccountDeletionHTTPError(400, "invalid_request");
  }

  return { authorizationCode, nonce };
}

function decodeBase64URL(value: string): Uint8Array {
  const base64 = value.replaceAll("-", "+").replaceAll("_", "/") +
    "=".repeat((4 - value.length % 4) % 4);
  return Uint8Array.from(
    atob(base64),
    (character) => character.charCodeAt(0),
  );
}

function decodeAppleClaims(idToken: string): Record<string, unknown> {
  const parts = idToken.split(".");
  if (parts.length !== 3) {
    throw new AccountDeletionHTTPError(403, "apple_identity_mismatch");
  }
  try {
    const decoded = JSON.parse(
      new TextDecoder().decode(decodeBase64URL(parts[1])),
    );
    if (!decoded || typeof decoded !== "object" || Array.isArray(decoded)) {
      throw new Error("invalid claims");
    }
    return decoded as Record<string, unknown>;
  } catch {
    throw new AccountDeletionHTTPError(403, "apple_identity_mismatch");
  }
}

function validateAppleIdentity(
  idToken: string,
  expectedProviderID: string | null,
  expectedClientID: string,
  expectedNonce: string,
  now: Date,
): void {
  if (!expectedProviderID) {
    throw new AccountDeletionHTTPError(403, "apple_identity_mismatch");
  }
  const claims = decodeAppleClaims(idToken);
  const audience = claims.aud;
  const hasExpectedAudience = audience === expectedClientID ||
    (Array.isArray(audience) && audience.includes(expectedClientID));
  const nowSeconds = Math.floor(now.getTime() / 1_000);
  if (
    claims.iss !== "https://appleid.apple.com" ||
    !hasExpectedAudience ||
    claims.sub !== expectedProviderID ||
    claims.nonce !== expectedNonce ||
    typeof claims.exp !== "number" ||
    !Number.isFinite(claims.exp) ||
    claims.exp <= nowSeconds
  ) {
    throw new AccountDeletionHTTPError(403, "apple_identity_mismatch");
  }
}

function requirePhase(
  progress: DeletionProgress,
  expected: DeletionPhase,
): DeletionProgress {
  if (progress.phase !== expected) {
    throw new AccountDeletionHTTPError(503, "account_deletion_retryable");
  }
  return progress;
}

export async function deleteAccountHandler(
  request: Request,
  dependencies: DeleteAccountDependencies,
): Promise<Response> {
  if (request.method !== "POST") {
    return jsonResponse(405, { error: "method_not_allowed" });
  }

  const authorization = bearerAuthorization(request);
  if (!authorization) {
    return jsonResponse(401, { error: "authentication_required" });
  }

  let body: DeleteAccountBody;
  try {
    body = await parseBody(request);
  } catch (error) {
    if (error instanceof AccountDeletionHTTPError) {
      return jsonResponse(error.status, { error: error.code });
    }
    return jsonResponse(400, { error: "invalid_request" });
  }

  let authUserID: string;
  try {
    authUserID = await dependencies.authenticate(authorization);
  } catch {
    return jsonResponse(401, { error: "authentication_required" });
  }

  try {
    let progress = await dependencies.begin(authUserID);

    if (progress.phase === "prepared") {
      const tokenExchange = await dependencies.exchangeAuthorizationCode(
        body.authorizationCode,
      );
      validateAppleIdentity(
        tokenExchange.idToken,
        progress.appleProviderId,
        dependencies.appleClientID,
        body.nonce,
        dependencies.now(),
      );
      progress = requirePhase(
        await dependencies.storeAppleToken(
          progress.profileId,
          tokenExchange.refreshToken,
        ),
        "token_ready",
      );
    }

    if (progress.phase === "token_ready") {
      const storedToken = await dependencies.loadAppleToken(
        progress.profileId,
      );
      await dependencies.revokeAppleToken(storedToken);
      progress = requirePhase(
        await dependencies.markAppleRevoked(progress.profileId),
        "apple_revoked",
      );
    }

    if (progress.phase === "apple_revoked") {
      progress = requirePhase(
        await dependencies.anonymize(progress.profileId),
        "auth_delete_pending",
      );
      if (
        progress.authUserId !== null &&
        progress.authUserId !== authUserID
      ) {
        throw new AccountDeletionHTTPError(
          503,
          "account_deletion_retryable",
        );
      }
    }

    if (progress.phase === "auth_delete_pending") {
      let deletionError: unknown;
      try {
        await dependencies.deleteAuthUser(authUserID);
      } catch (error) {
        deletionError = error;
      }

      try {
        progress = requirePhase(
          await dependencies.complete(progress.profileId),
          "completed",
        );
      } catch {
        if (deletionError) {
          throw new AccountDeletionHTTPError(
            503,
            "account_deletion_retryable",
          );
        }
        throw new AccountDeletionHTTPError(
          503,
          "account_deletion_retryable",
        );
      }
    }

    if (progress.phase !== "completed") {
      throw new AccountDeletionHTTPError(
        503,
        "account_deletion_retryable",
      );
    }

    return jsonResponse(200, { status: "deleted" });
  } catch (error) {
    if (error instanceof AccountDeletionHTTPError) {
      return jsonResponse(error.status, { error: error.code });
    }
    return jsonResponse(503, { error: "account_deletion_retryable" });
  }
}

export interface AppleClientSecretConfiguration {
  keyID: string;
  teamID: string;
  clientID: string;
  privateKeyPEM: string;
}

function base64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

function encodeJSON(value: Record<string, unknown>): string {
  return base64URL(new TextEncoder().encode(JSON.stringify(value)));
}

function privateKeyBytes(pem: string): ArrayBuffer {
  const normalized = pem.replaceAll("\\n", "\n").trim();
  const match = normalized.match(
    /^-----BEGIN PRIVATE KEY-----\n([A-Za-z0-9+/=\n\r]+)\n-----END PRIVATE KEY-----$/,
  );
  if (!match) throw new Error("invalid Apple private key");
  const base64 = match[1].replaceAll(/\s/g, "");
  const bytes = Uint8Array.from(
    atob(base64),
    (character) => character.charCodeAt(0),
  );
  return bytes.buffer;
}

function validConfigurationValue(value: string, maximum: number): boolean {
  return value.length > 0 && value.length <= maximum &&
    !containsControlOrWhitespace(value);
}

export async function createAppleClientSecret(
  configuration: AppleClientSecretConfiguration,
  now: Date = new Date(),
): Promise<string> {
  if (
    !validConfigurationValue(configuration.keyID, 64) ||
    !validConfigurationValue(configuration.teamID, 64) ||
    !validConfigurationValue(configuration.clientID, 255) ||
    configuration.privateKeyPEM.length === 0 ||
    configuration.privateKeyPEM.length > 16_384
  ) {
    throw new Error("invalid Apple client-secret configuration");
  }

  const issuedAt = Math.floor(now.getTime() / 1_000);
  const header = encodeJSON({
    alg: "ES256",
    kid: configuration.keyID,
    typ: "JWT",
  });
  const payload = encodeJSON({
    iss: configuration.teamID,
    iat: issuedAt,
    exp: issuedAt + 300,
    aud: "https://appleid.apple.com",
    sub: configuration.clientID,
  });
  const signingInput = `${header}.${payload}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    privateKeyBytes(configuration.privateKeyPEM),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64URL(new Uint8Array(signature))}`;
}

interface AppleTokenClientConfiguration {
  clientID: string;
  clientSecret(): Promise<string>;
  fetch: typeof fetch;
}

export function createAppleTokenClient(
  configuration: AppleTokenClientConfiguration,
): {
  exchangeAuthorizationCode(code: string): Promise<AppleTokenExchange>;
  revoke(token: string): Promise<void>;
} {
  async function post(
    path: "token" | "revoke",
    parameters: Record<string, string>,
  ): Promise<Response> {
    const clientSecret = await configuration.clientSecret();
    const body = new URLSearchParams({
      client_id: configuration.clientID,
      client_secret: clientSecret,
      ...parameters,
    });
    return await configuration.fetch(
      `https://appleid.apple.com/auth/${path}`,
      {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
          "cache-control": "no-store",
        },
        body,
        signal: AbortSignal.timeout(10_000),
      },
    );
  }

  return {
    exchangeAuthorizationCode: async (code) => {
      const response = await post("token", {
        code,
        grant_type: "authorization_code",
      });
      const text = await response.text();
      if (!response.ok) {
        let errorCode = "";
        try {
          const value = JSON.parse(text) as Record<string, unknown>;
          if (typeof value.error === "string") errorCode = value.error;
        } catch {
          // A non-JSON Apple response has no structured error code.
        }
        if (response.status === 400 && errorCode === "invalid_grant") {
          throw new AccountDeletionHTTPError(
            401,
            "reauthentication_required",
          );
        }
        throw new AccountDeletionHTTPError(
          503,
          "apple_token_exchange_retryable",
        );
      }

      let value: Record<string, unknown>;
      try {
        value = JSON.parse(text) as Record<string, unknown>;
      } catch {
        throw new AccountDeletionHTTPError(502, "apple_contract_mismatch");
      }
      if (
        typeof value.refresh_token !== "string" ||
        value.refresh_token.length < 16 ||
        value.refresh_token.length > 4_096 ||
        containsControlOrWhitespace(value.refresh_token) ||
        typeof value.id_token !== "string" ||
        value.id_token.length < 16 ||
        value.id_token.length > 16_384 ||
        containsControlOrWhitespace(value.id_token)
      ) {
        throw new AccountDeletionHTTPError(502, "apple_contract_mismatch");
      }
      return {
        refreshToken: value.refresh_token,
        idToken: value.id_token,
      };
    },
    revoke: async (token) => {
      const response = await post("revoke", {
        token,
        token_type_hint: "refresh_token",
      });
      if (!response.ok) {
        throw new AccountDeletionHTTPError(
          503,
          "apple_revocation_retryable",
        );
      }
    },
  };
}

function requiredEnvironment(name: string): string {
  const value = Deno.env.get(name)?.trim() ?? "";
  if (!value) throw new Error(`missing ${name}`);
  return value;
}

export interface LiveDependencyConfiguration {
  environment(name: string): string;
  fetch: typeof fetch;
}

function normalizeProgress(value: unknown): DeletionProgress {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("invalid account deletion progress");
  }
  const record = value as Record<string, unknown>;
  const phase = record.phase;
  if (
    typeof record.profile_id !== "string" ||
    ![
      "prepared",
      "token_ready",
      "apple_revoked",
      "auth_delete_pending",
      "completed",
    ].includes(String(phase))
  ) {
    throw new Error("invalid account deletion progress");
  }
  return {
    profileId: record.profile_id,
    phase: phase as DeletionPhase,
    appleProviderId: typeof record.apple_provider_id === "string"
      ? record.apple_provider_id
      : null,
    authUserId: typeof record.auth_user_id === "string"
      ? record.auth_user_id
      : null,
  };
}

export function createLiveDependencies(
  configuration: LiveDependencyConfiguration = {
    environment: requiredEnvironment,
    fetch,
  },
): DeleteAccountDependencies {
  const supabaseURL = configuration.environment("SUPABASE_URL");
  const supabaseAnonKey = configuration.environment("SUPABASE_ANON_KEY");
  const serviceRoleKey = configuration.environment("SUPABASE_SERVICE_ROLE_KEY");
  const admin = createClient(supabaseURL, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  function appleConfiguration(): AppleClientSecretConfiguration {
    return {
      keyID: configuration.environment("APPLE_SIGN_IN_KEY_ID"),
      teamID: configuration.environment("APPLE_SIGN_IN_TEAM_ID"),
      clientID: configuration.environment("APPLE_SIGN_IN_CLIENT_ID"),
      privateKeyPEM: configuration.environment("APPLE_SIGN_IN_PRIVATE_KEY"),
    };
  }

  function appleTokenClient() {
    const apple = appleConfiguration();
    return createAppleTokenClient({
      clientID: apple.clientID,
      clientSecret: () => createAppleClientSecret(apple),
      fetch: configuration.fetch,
    });
  }

  async function rpc(
    name: string,
    parameters: Record<string, unknown>,
  ): Promise<unknown> {
    const { data, error } = await admin.rpc(name, parameters);
    if (error) throw error;
    return data;
  }

  return {
    get appleClientID() {
      return appleConfiguration().clientID;
    },
    now: () => new Date(),
    authenticate: async (authorization) => {
      const userClient = createClient(supabaseURL, supabaseAnonKey, {
        auth: { persistSession: false, autoRefreshToken: false },
        global: { headers: { Authorization: authorization } },
      });
      const { data, error } = await userClient.auth.getUser();
      if (error || !data.user) throw error ?? new Error("missing user");
      return data.user.id;
    },
    begin: async (authUserID) =>
      normalizeProgress(
        await rpc(
          "begin_account_deletion",
          { target_auth_user_id: authUserID },
        ),
      ),
    exchangeAuthorizationCode: (code) =>
      appleTokenClient().exchangeAuthorizationCode(code),
    storeAppleToken: async (targetProfileID, refreshToken) =>
      normalizeProgress(
        await rpc(
          "store_account_deletion_apple_token",
          {
            target_profile_id: targetProfileID,
            refresh_token: refreshToken,
          },
        ),
      ),
    loadAppleToken: async (targetProfileID) => {
      const value = await rpc("load_account_deletion_apple_token", {
        target_profile_id: targetProfileID,
      });
      if (typeof value !== "string") throw new Error("missing Apple token");
      return value;
    },
    revokeAppleToken: (token) => appleTokenClient().revoke(token),
    markAppleRevoked: async (targetProfileID) =>
      normalizeProgress(
        await rpc(
          "mark_account_deletion_apple_revoked",
          { target_profile_id: targetProfileID },
        ),
      ),
    anonymize: async (targetProfileID) =>
      normalizeProgress(
        await rpc(
          "anonymize_account_deletion",
          { target_profile_id: targetProfileID },
        ),
      ),
    deleteAuthUser: async (targetAuthUserID) => {
      const { error } = await admin.auth.admin.deleteUser(
        targetAuthUserID,
        false,
      );
      if (error) throw error;
    },
    complete: async (targetProfileID) =>
      normalizeProgress(
        await rpc(
          "complete_account_deletion",
          { target_profile_id: targetProfileID },
        ),
      ),
  };
}

if (import.meta.main) {
  Deno.serve((request) => {
    try {
      return deleteAccountHandler(request, createLiveDependencies());
    } catch {
      return jsonResponse(503, { error: "account_deletion_unavailable" });
    }
  });
}
