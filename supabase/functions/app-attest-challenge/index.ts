import {
  authenticated,
  containsFingerprint,
  defaultUserDependencies,
  error,
  json,
  type RpcError,
  type ScoringRpcClient,
  type UserDependencies,
} from "../_shared/scoring_http.ts";

export type AppAttestChallengeRpcClient = ScoringRpcClient;
export type AppAttestChallengeDependencies = UserDependencies;

const maximumBodyBytes = 1024;
const requestKeys = [
  "installationID",
  "keyID",
  "payloadSHA256",
  "version",
];
const responseKeys = [
  "challenge",
  "challengeID",
  "expiresAt",
  "proofKind",
  "version",
];

interface ChallengeRequest {
  installationID: string;
  payloadSHA256: string;
  keyID: string;
}

interface ChallengeResponse extends Record<string, unknown> {
  version: 1;
  challengeID: string;
  challenge: string;
  expiresAt: string;
  proofKind: "attestation" | "assertion";
}

function exactKeys(
  value: Record<string, unknown>,
  expected: string[],
): boolean {
  return Object.keys(value).sort().join("|") === expected.join("|");
}

function isCanonicalUuid(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      .test(
        value,
      );
}

function isCanonicalSha256Base64(value: unknown): value is string {
  if (
    typeof value !== "string" || value.length !== 44 ||
    !/^[A-Za-z0-9+/]{43}=$/.test(value)
  ) return false;
  try {
    const decoded = atob(value);
    return decoded.length === 32 && btoa(decoded) === value;
  } catch {
    return false;
  }
}

function isTimestamp(value: unknown): value is string {
  return typeof value === "string" && value.length <= 32 &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/
      .test(
        value,
      ) &&
    Number.isFinite(Date.parse(value));
}

async function readBoundedJson(request: Request): Promise<unknown | null> {
  const contentType = request.headers.get("content-type")?.split(";", 1)[0]
    .trim().toLowerCase();
  if (contentType !== "application/json") return null;

  const contentLength = request.headers.get("content-length");
  if (
    contentLength !== null &&
    (!/^[0-9]+$/.test(contentLength) ||
      Number(contentLength) > maximumBodyBytes)
  ) return null;
  if (!request.body) return null;

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.length;
      if (length > maximumBodyBytes) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
  } catch {
    return null;
  } finally {
    reader.releaseLock();
  }

  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  try {
    const jsonText = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    return JSON.parse(jsonText);
  } catch {
    return null;
  }
}

function parseRequest(value: unknown): ChallengeRequest | null {
  if (
    !value || typeof value !== "object" || Array.isArray(value) ||
    containsFingerprint(value)
  ) return null;
  const body = value as Record<string, unknown>;
  if (
    !exactKeys(body, requestKeys) || body.version !== 1 ||
    !isCanonicalUuid(body.installationID) ||
    typeof body.payloadSHA256 !== "string" ||
    !/^[0-9a-f]{64}$/.test(body.payloadSHA256) ||
    !isCanonicalSha256Base64(body.keyID)
  ) return null;
  return {
    installationID: body.installationID,
    payloadSHA256: body.payloadSHA256,
    keyID: body.keyID,
  };
}

function parseResponse(value: unknown): ChallengeResponse | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const response = value as Record<string, unknown>;
  if (
    !exactKeys(response, responseKeys) || response.version !== 1 ||
    !isCanonicalUuid(response.challengeID) ||
    !isCanonicalSha256Base64(response.challenge) ||
    !isTimestamp(response.expiresAt) ||
    (response.proofKind !== "attestation" &&
      response.proofKind !== "assertion")
  ) return null;
  return {
    version: 1,
    challengeID: response.challengeID,
    challenge: response.challenge,
    expiresAt: response.expiresAt,
    proofKind: response.proofKind,
  };
}

function temporarilyUnavailable(): Response {
  return error(
    503,
    "temporarily_unavailable",
    "Unable to issue a challenge right now",
  );
}

function mapChallengeError(rpcError: RpcError): Response {
  switch (rpcError.message) {
    case "authentication_required":
      return error(401, "unauthorized", "Authentication required");
    case "active_profile_required":
      return error(403, "active_profile_required", "Active profile required");
    case "app_attest_installation_unavailable":
      return error(
        404,
        "installation_unavailable",
        "Installation unavailable",
      );
    case "app_attest_rate_limited":
      return error(429, "rate_limited", "Too many challenge requests");
    case "app_attest_challenge_limit":
      return error(429, "challenge_limit", "Too many active challenges");
    case "invalid_app_attest_challenge_request":
    case "invalid_app_attest_digest":
      return error(400, "invalid_request", "Invalid challenge request");
    default:
      return temporarilyUnavailable();
  }
}

export async function appAttestChallengeHandler(
  request: Request,
  dependencies: AppAttestChallengeDependencies = defaultUserDependencies,
): Promise<Response> {
  if (request.method !== "POST") {
    return error(405, "method_not_allowed", "Method not allowed");
  }

  const parsed = parseRequest(await readBoundedJson(request));
  if (!parsed) {
    return error(400, "invalid_request", "Invalid challenge request");
  }

  let client: AppAttestChallengeRpcClient | null;
  try {
    client = await authenticated(request, dependencies);
  } catch {
    return temporarilyUnavailable();
  }
  if (!client) {
    return error(401, "unauthorized", "Authentication required");
  }

  let result: Awaited<ReturnType<AppAttestChallengeRpcClient["rpc"]>>;
  try {
    result = await client.rpc("issue_app_attest_challenge", {
      installation_id: parsed.installationID,
      payload_sha256: parsed.payloadSHA256,
      key_id: parsed.keyID,
    });
  } catch {
    return temporarilyUnavailable();
  }
  if (result.error) return mapChallengeError(result.error);

  const response = parseResponse(result.data);
  return response ? json(200, response) : temporarilyUnavailable();
}

if (import.meta.main) {
  Deno.serve((request) => appAttestChallengeHandler(request));
}
