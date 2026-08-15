import {
  defaultServiceDependencies,
  error,
  json,
  type RpcError,
} from "../_shared/scoring_http.ts";

export interface NotificationRpcClient {
  rpc(
    name: string,
    args: Record<string, unknown>,
  ): Promise<{ data: unknown; error: RpcError | null }>;
}

interface ApnsConfiguration {
  keyId: string;
  teamId: string;
  topic: string;
  privateKey: string;
}

interface NotificationWorkItem {
  workId: string;
  leaseToken: string;
  semanticId: string;
  competitionId: string;
  kind: "score_update" | "result";
  apnsToken: string;
  environment: "sandbox" | "production";
}

export interface NotificationWorkerDependencies {
  workerAuthorization: string;
  configuration: ApnsConfiguration | null;
  createServiceClient(): NotificationRpcClient;
  createProviderToken(configuration: ApnsConfiguration): Promise<string>;
  send(request: Request): Promise<Response>;
}

type ResolutionOutcome = "sent" | "retry" | "invalid_token" | "discard";

interface Resolution {
  outcome: ResolutionOutcome;
  retryAfterSeconds: number | null;
}

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const tokenPattern = /^[0-9a-f]{64,200}$/;
const semanticPrefix = "healthcomp.server-notification:v1:";
const maximumBatchSize = 25;
const maximumConcurrentSends = 5;
const leaseSeconds = 180;
const expirationSeconds = 60 * 60;

function configuredApns(): ApnsConfiguration | null {
  const keyId = Deno.env.get("APNS_KEY_ID")?.trim();
  const teamId = Deno.env.get("APNS_TEAM_ID")?.trim();
  const topic = Deno.env.get("APNS_TOPIC")?.trim();
  const privateKey = Deno.env.get("APNS_PRIVATE_KEY")
    ?.replaceAll("\\n", "\n")
    .trim();
  if (
    !keyId || !/^[A-Z0-9]{10}$/.test(keyId) ||
    !teamId || !/^[A-Z0-9]{10}$/.test(teamId) ||
    !topic || !/^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,253}[A-Za-z0-9])?$/.test(
      topic,
    ) ||
    !privateKey ||
    !privateKey.startsWith("-----BEGIN PRIVATE KEY-----") ||
    !privateKey.endsWith("-----END PRIVATE KEY-----")
  ) return null;
  return { keyId, teamId, topic, privateKey };
}

const workerToken = Deno.env.get("HEALTHCOMP_NOTIFICATION_WORKER_TOKEN")
  ?.trim();
const defaults: NotificationWorkerDependencies = {
  workerAuthorization:
    workerToken && /^[A-Za-z0-9_-]{43,128}$/.test(workerToken)
      ? `Bearer ${workerToken}`
      : "",
  configuration: configuredApns(),
  createServiceClient: () =>
    defaultServiceDependencies.createServiceClient() as NotificationRpcClient,
  createProviderToken: createApnsProviderToken,
  send: (request) => fetch(request),
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasExactKeys(
  value: Record<string, unknown>,
  expected: readonly string[],
): boolean {
  const actual = Object.keys(value).sort();
  return actual.length === expected.length &&
    actual.every((key, index) => key === [...expected].sort()[index]);
}

function parseBatchSize(value: unknown): number | null {
  if (!isRecord(value)) return null;
  if (Object.keys(value).some((key) => key !== "batchSize")) return null;
  const batchSize = "batchSize" in value ? value.batchSize : 25;
  return Number.isInteger(batchSize) && Number(batchSize) >= 1 &&
      Number(batchSize) <= maximumBatchSize
    ? Number(batchSize)
    : null;
}

async function constantTimeEqual(
  provided: string,
  expected: string,
): Promise<boolean> {
  const encoder = new TextEncoder();
  const [providedDigest, expectedDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(provided)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  const providedBytes = new Uint8Array(providedDigest);
  const expectedBytes = new Uint8Array(expectedDigest);
  let difference = 0;
  for (let index = 0; index < providedBytes.length; index += 1) {
    difference |= providedBytes[index] ^ expectedBytes[index];
  }
  return difference === 0;
}

function containsASCIIControlCharacter(value: string): boolean {
  for (const character of value) {
    const scalar = character.codePointAt(0)!;
    if (scalar <= 0x1f || scalar === 0x7f) return true;
  }
  return false;
}

function parseWorkItem(value: unknown): NotificationWorkItem | null {
  if (!isRecord(value)) return null;
  const keys = [
    "apnsToken",
    "competitionId",
    "environment",
    "kind",
    "leaseToken",
    "semanticId",
    "workId",
  ];
  if (!hasExactKeys(value, keys)) return null;
  if (
    typeof value.workId !== "string" || !uuidPattern.test(value.workId) ||
    typeof value.leaseToken !== "string" ||
    !uuidPattern.test(value.leaseToken) ||
    typeof value.competitionId !== "string" ||
    !uuidPattern.test(value.competitionId) ||
    typeof value.semanticId !== "string" ||
    !value.semanticId.startsWith(semanticPrefix) ||
    value.semanticId.length > 255 ||
    containsASCIIControlCharacter(value.semanticId) ||
    typeof value.apnsToken !== "string" ||
    !tokenPattern.test(value.apnsToken) ||
    (value.kind !== "score_update" && value.kind !== "result") ||
    (value.environment !== "sandbox" && value.environment !== "production")
  ) return null;
  return value as unknown as NotificationWorkItem;
}

function parseLeaseResponse(
  value: unknown,
  batchSize: number,
): NotificationWorkItem[] | null {
  if (!isRecord(value) || !hasExactKeys(value, ["items"])) return null;
  if (!Array.isArray(value.items) || value.items.length > batchSize) {
    return null;
  }
  const parsed: NotificationWorkItem[] = [];
  const workIDs = new Set<string>();
  const semanticIDs = new Set<string>();
  for (const raw of value.items) {
    const item = parseWorkItem(raw);
    if (
      !item || workIDs.has(item.workId) ||
      semanticIDs.has(item.semanticId)
    ) return null;
    workIDs.add(item.workId);
    semanticIDs.add(item.semanticId);
    parsed.push(item);
  }
  return parsed;
}

function base64Url(value: Uint8Array): string {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(
    /=+$/,
    "",
  );
}

function encodedJSON(value: Record<string, unknown>): string {
  return base64Url(new TextEncoder().encode(JSON.stringify(value)));
}

function pkcs8Bytes(pem: string): ArrayBuffer {
  const encoded = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replaceAll(/\s/g, "");
  if (!encoded) throw new Error("APNs private key is empty");
  try {
    const decoded = atob(encoded);
    const buffer = new ArrayBuffer(decoded.length);
    const bytes = new Uint8Array(buffer);
    for (let index = 0; index < decoded.length; index += 1) {
      bytes[index] = decoded.charCodeAt(index);
    }
    return buffer;
  } catch {
    throw new Error("APNs private key is invalid");
  }
}

export async function createApnsProviderToken(
  configuration: ApnsConfiguration,
): Promise<string> {
  const header = encodedJSON({ alg: "ES256", kid: configuration.keyId });
  const payload = encodedJSON({
    iss: configuration.teamId,
    iat: Math.floor(Date.now() / 1000),
  });
  const input = `${header}.${payload}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pkcs8Bytes(configuration.privateKey),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      new TextEncoder().encode(input),
    ),
  );
  if (signature.length !== 64) {
    throw new Error("APNs provider signature has an invalid shape");
  }
  return `${input}.${base64Url(signature)}`;
}

export function competitionNotificationPayload(
  item: Pick<NotificationWorkItem, "competitionId" | "kind">,
): Record<string, unknown> {
  const alert = item.kind === "result"
    ? {
      title: "Competition complete",
      body: "Open HealthComp to see the confirmed result.",
    }
    : {
      title: "Competition updated",
      body: "Open HealthComp to see the latest confirmed activity update.",
    };
  return {
    aps: {
      alert,
      sound: "default",
      "thread-id": `competition:${item.competitionId}`,
    },
    "healthcomp.route.v": 1,
    "healthcomp.route.kind": "competition",
    "healthcomp.route.competitionID": item.competitionId,
  };
}

function apnsRequest(
  item: NotificationWorkItem,
  configuration: ApnsConfiguration,
  providerToken: string,
): Request {
  const host = item.environment === "production"
    ? "api.push.apple.com"
    : "api.sandbox.push.apple.com";
  return new Request(`https://${host}/3/device/${item.apnsToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${providerToken}`,
      "content-type": "application/json",
      "apns-topic": configuration.topic,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": String(
        Math.floor(Date.now() / 1000) + expirationSeconds,
      ),
      "apns-id": item.workId,
      "apns-collapse-id": `healthcomp:${item.competitionId}`,
    },
    body: JSON.stringify(competitionNotificationPayload(item)),
    signal: AbortSignal.timeout(10_000),
  });
}

function retryAfter(response: Response): number {
  const raw = response.headers.get("retry-after");
  if (raw && /^[0-9]{1,5}$/.test(raw)) {
    return Math.min(3600, Math.max(1, Number(raw)));
  }
  return 60;
}

async function apnsReason(response: Response): Promise<string | null> {
  try {
    const body = await response.text();
    if (body.length > 1024) return null;
    const parsed: unknown = JSON.parse(body);
    return isRecord(parsed) && typeof parsed.reason === "string"
      ? parsed.reason
      : null;
  } catch {
    return null;
  }
}

async function resolution(response: Response): Promise<Resolution> {
  if (response.status === 200) {
    return { outcome: "sent", retryAfterSeconds: null };
  }
  if (response.status === 410) {
    return { outcome: "invalid_token", retryAfterSeconds: null };
  }
  if (response.status === 400) {
    const reason = await apnsReason(response);
    if (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic") {
      return { outcome: "invalid_token", retryAfterSeconds: null };
    }
    return { outcome: "discard", retryAfterSeconds: null };
  }
  if (
    response.status === 403 || response.status === 429 ||
    response.status >= 500
  ) {
    return { outcome: "retry", retryAfterSeconds: retryAfter(response) };
  }
  return { outcome: "discard", retryAfterSeconds: null };
}

async function parsedBody(request: Request): Promise<unknown | null> {
  try {
    return await request.json();
  } catch {
    return null;
  }
}

export async function sendCompetitionNotificationHandler(
  request: Request,
  deps: NotificationWorkerDependencies = defaults,
): Promise<Response> {
  if (request.method !== "POST") {
    return error(405, "method_not_allowed", "Method not allowed");
  }
  const providedAuthorization = request.headers.get("authorization") ?? "";
  if (
    !deps.workerAuthorization ||
    !await constantTimeEqual(
      providedAuthorization,
      deps.workerAuthorization,
    )
  ) return error(401, "unauthorized", "Authentication required");

  const batchSize = parseBatchSize(await parsedBody(request));
  if (batchSize === null) {
    return error(400, "invalid_request", "Invalid request");
  }
  if (!deps.configuration) {
    return error(
      500,
      "notification_provider_unavailable",
      "Notification provider unavailable",
    );
  }

  let providerToken: string;
  let client: NotificationRpcClient;
  try {
    providerToken = await deps.createProviderToken(deps.configuration);
    client = deps.createServiceClient();
  } catch {
    return error(
      500,
      "notification_provider_unavailable",
      "Notification provider unavailable",
    );
  }

  const leased = await client.rpc("lease_competition_notification_work", {
    batch_size: batchSize,
    lease_seconds: leaseSeconds,
  });
  if (leased.error) {
    return error(
      502,
      "notification_worker_unavailable",
      "Notification worker unavailable",
    );
  }
  const items = parseLeaseResponse(leased.data, batchSize);
  if (!items) {
    return error(
      502,
      "notification_worker_unavailable",
      "Notification worker unavailable",
    );
  }

  const counts = {
    sent: 0,
    retried: 0,
    invalidToken: 0,
    discarded: 0,
    unresolved: 0,
  };
  for (
    let offset = 0;
    offset < items.length;
    offset += maximumConcurrentSends
  ) {
    const outcomes = await Promise.all(
      items.slice(offset, offset + maximumConcurrentSends).map(
        async (item): Promise<Resolution | null> => {
          let decision: Resolution;
          try {
            decision = await resolution(
              await deps.send(
                apnsRequest(item, deps.configuration!, providerToken),
              ),
            );
          } catch {
            decision = { outcome: "retry", retryAfterSeconds: 60 };
          }
          try {
            const resolved = await client.rpc(
              "resolve_competition_notification_work",
              {
                work_id: item.workId,
                lease_token: item.leaseToken,
                outcome: decision.outcome,
                retry_after_seconds: decision.retryAfterSeconds,
              },
            );
            return resolved.error || resolved.data !== true ? null : decision;
          } catch {
            return null;
          }
        },
      ),
    );
    for (const decision of outcomes) {
      if (!decision) {
        counts.unresolved += 1;
        continue;
      }
      switch (decision.outcome) {
        case "sent":
          counts.sent += 1;
          break;
        case "retry":
          counts.retried += 1;
          break;
        case "invalid_token":
          counts.invalidToken += 1;
          break;
        case "discard":
          counts.discarded += 1;
          break;
      }
    }
  }

  if (counts.unresolved > 0) {
    return error(
      502,
      "notification_worker_unavailable",
      "Notification worker unavailable",
    );
  }
  return json(200, {
    leasedCount: String(items.length),
    sentCount: String(counts.sent),
    retriedCount: String(counts.retried),
    invalidTokenCount: String(counts.invalidToken),
    discardedCount: String(counts.discarded),
    unresolvedCount: String(counts.unresolved),
  });
}

if (import.meta.main) {
  Deno.serve((request) => sendCompetitionNotificationHandler(request));
}
