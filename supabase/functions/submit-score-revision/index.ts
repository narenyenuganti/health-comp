import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import {
  appAttestClientDataV1,
  AppAttestVerificationError,
  type AppAttestVerificationErrorCode,
  type AppAttestVerificationPolicy,
  type VerifiedAppAttestAssertion,
  type VerifiedAppAttestAttestation,
  verifyAppAttestAssertion,
  verifyAppAttestAttestation,
} from "../_shared/app-attest.ts";
import {
  authenticatedContext,
  containsFingerprint,
  defaultServiceDependencies,
  defaultUserDependencies,
  error,
  isBigintString,
  isUuid,
  json,
  mapRpcError,
  type RpcError,
  type ScoringRpcClient,
  type ServiceDependencies,
  type UserDependencies,
} from "../_shared/scoring_http.ts";

export type { ScoringRpcClient } from "../_shared/scoring_http.ts";

export interface ScoreSubmissionDependencies
  extends UserDependencies, ServiceDependencies {
  now(): Date;
  appAttestPolicy(now: Date): AppAttestVerificationPolicy | null;
  verifyAttestation: typeof verifyAppAttestAttestation;
  verifyAssertion: typeof verifyAppAttestAssertion;
  reportVerificationFailure?(
    code: AppAttestVerificationErrorCode,
  ): void;
}

type ProofKind = "attestation" | "assertion";

interface ScoreRequest {
  version: 1;
  competitionId: string;
  semanticEventId: string;
  dayOrdinal: number;
  clientRevision: string;
  evaluatedAt: string;
  moveMode: string;
  standMode: string;
  moveBasisPoints: number | null;
  exerciseBasisPoints: number | null;
  standBasisPoints: number | null;
  availabilityReason: string;
  scoringPolicyIdentity: "healthcomp.activity-score.v1";
  wireContentSHA256: string;
}

interface AppAttestProof {
  version: 1;
  challengeID: string;
  installationID: string;
  keyID: string;
  proofKind: ProofKind;
  object: Uint8Array;
}

interface RegisteredKeyContext {
  publicKeyPEM: string;
  previousSignCount: number;
  environment: "development" | "production";
  validationCategory: number | null;
  bundleVersion: string | null;
}

interface AppAttestContext {
  version: 1;
  challengeID: string;
  challenge: Uint8Array;
  profileID: string;
  installationID: string;
  payloadSHA256: string;
  keyID: string;
  proofKind: ProofKind;
  expiresAt: string;
  registeredKey: RegisteredKeyContext | null;
}

interface AppAttestGrant {
  version: 1;
  grantID: string;
  expiresAt: string;
}

const maximumSubmissionBodyBytes = 140 * 1024;
const maximumAttestationBytes = 96 * 1024;
const maximumAssertionBytes = 2048;
const scoreKeys = [
  "availabilityReason",
  "clientRevision",
  "competitionId",
  "dayOrdinal",
  "evaluatedAt",
  "exerciseBasisPoints",
  "moveBasisPoints",
  "moveMode",
  "scoringPolicyIdentity",
  "semanticEventId",
  "standBasisPoints",
  "standMode",
  "version",
  "wireContentSHA256",
] as const;
const envelopeKeys = ["appAttest", "score", "version"] as const;
const proofKeys = [
  "challengeID",
  "installationID",
  "keyID",
  "object",
  "proofKind",
  "version",
] as const;
const contextKeys = [
  "challenge",
  "challengeID",
  "expiresAt",
  "installationID",
  "keyID",
  "payloadSHA256",
  "profileID",
  "proofKind",
  "registeredKey",
  "version",
] as const;
const registeredKeyKeys = [
  "bundleVersion",
  "environment",
  "previousSignCount",
  "publicKeyPEM",
  "validationCategory",
] as const;
const grantKeys = ["expiresAt", "grantID", "version"] as const;
const modes = new Set(["activeEnergyKilocalories", "moveMinutes"]);
const stands = new Set(["standHours", "rollHours", "unknown"]);
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
const rejectionCodes = new Set([
  "divergent_duplicate",
  "revision_regression",
  "window_stable",
  "competition_terminal",
  "competition_finalized",
]);

function exactKeys(
  value: Record<string, unknown>,
  expected: readonly string[],
): boolean {
  return Object.keys(value).sort().join("|") ===
    [...expected].sort().join("|");
}

function isCanonicalUuid(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      .test(
        value,
      );
}

function isCanonicalTimestamp(value: unknown): value is string {
  return typeof value === "string" && value.length <= 32 &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/
      .test(
        value,
      ) &&
    Number.isFinite(Date.parse(value));
}

function decodeCanonicalBase64(
  value: unknown,
  maximumBytes: number,
  exactBytes?: number,
): Uint8Array | null {
  if (
    typeof value !== "string" || value.length === 0 ||
    value.length > Math.ceil(maximumBytes / 3) * 4 ||
    value.length % 4 !== 0 ||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(
      value,
    )
  ) return null;
  try {
    const decoded = atob(value);
    if (
      decoded.length === 0 || decoded.length > maximumBytes ||
      (exactBytes !== undefined && decoded.length !== exactBytes) ||
      btoa(decoded) !== value
    ) return null;
    return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
  } catch {
    return null;
  }
}

async function readBoundedJson(request: Request): Promise<unknown | null> {
  const contentType = request.headers.get("content-type")?.split(";", 1)[0]
    .trim().toLowerCase();
  if (contentType !== "application/json") return null;
  const contentLength = request.headers.get("content-length");
  if (
    contentLength !== null &&
    (!/^[0-9]+$/.test(contentLength) ||
      Number(contentLength) > maximumSubmissionBodyBytes)
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
      if (length > maximumSubmissionBodyBytes) {
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
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    return null;
  }
}

function parseScore(value: unknown): ScoreRequest | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const score = value as Record<string, unknown>;
  if (
    !exactKeys(score, scoreKeys) || score.version !== 1 ||
    !isUuid(score.competitionId) ||
    score.competitionId === "00000000-0000-0000-0000-000000000000" ||
    !isUuid(score.semanticEventId) ||
    score.semanticEventId === "00000000-0000-0000-0000-000000000000" ||
    !Number.isInteger(score.dayOrdinal) || Number(score.dayOrdinal) < 1 ||
    Number(score.dayOrdinal) > 7 || !isBigintString(score.clientRevision) ||
    typeof score.evaluatedAt !== "string" ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$/.test(
      score.evaluatedAt,
    ) ||
    typeof score.moveMode !== "string" || !modes.has(score.moveMode) ||
    typeof score.standMode !== "string" || !stands.has(score.standMode) ||
    typeof score.availabilityReason !== "string" ||
    !reasons.has(score.availabilityReason) ||
    score.scoringPolicyIdentity !== "healthcomp.activity-score.v1" ||
    typeof score.wireContentSHA256 !== "string" ||
    !/^[0-9a-f]{64}$/.test(score.wireContentSHA256)
  ) return null;
  const basisPoints = [
    score.moveBasisPoints,
    score.exerciseBasisPoints,
    score.standBasisPoints,
  ];
  if (
    score.availabilityReason === "available"
      ? score.standMode === "unknown" ||
        !basisPoints.every((number) =>
          Number.isInteger(number) && Number(number) >= 0 &&
          Number(number) <= 20_000
        )
      : !basisPoints.every((number) => number === null)
  ) return null;
  return {
    version: 1,
    competitionId: score.competitionId,
    semanticEventId: score.semanticEventId,
    dayOrdinal: score.dayOrdinal as number,
    clientRevision: score.clientRevision,
    evaluatedAt: score.evaluatedAt,
    moveMode: score.moveMode as string,
    standMode: score.standMode as string,
    moveBasisPoints: score.moveBasisPoints as number | null,
    exerciseBasisPoints: score.exerciseBasisPoints as number | null,
    standBasisPoints: score.standBasisPoints as number | null,
    availabilityReason: score.availabilityReason as string,
    scoringPolicyIdentity: "healthcomp.activity-score.v1",
    wireContentSHA256: score.wireContentSHA256,
  };
}

function canonicalScoreJSON(score: ScoreRequest): string {
  return JSON.stringify({
    availabilityReason: score.availabilityReason,
    clientRevision: score.clientRevision,
    competitionId: score.competitionId,
    dayOrdinal: score.dayOrdinal,
    evaluatedAt: score.evaluatedAt,
    exerciseBasisPoints: score.exerciseBasisPoints,
    moveBasisPoints: score.moveBasisPoints,
    moveMode: score.moveMode,
    scoringPolicyIdentity: score.scoringPolicyIdentity,
    semanticEventId: score.semanticEventId,
    standBasisPoints: score.standBasisPoints,
    standMode: score.standMode,
    version: score.version,
    wireContentSHA256: score.wireContentSHA256,
  });
}

export function canonicalScoreRevisionJSON(value: unknown): string | null {
  const parsed = parseScore(value);
  return parsed ? canonicalScoreJSON(parsed) : null;
}

function parseProof(value: unknown): AppAttestProof | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const proof = value as Record<string, unknown>;
  if (
    !exactKeys(proof, proofKeys) || proof.version !== 1 ||
    !isCanonicalUuid(proof.challengeID) ||
    !isCanonicalUuid(proof.installationID) ||
    (proof.proofKind !== "attestation" && proof.proofKind !== "assertion")
  ) return null;
  const keyID = decodeCanonicalBase64(proof.keyID, 32, 32);
  const object = decodeCanonicalBase64(
    proof.object,
    proof.proofKind === "attestation"
      ? maximumAttestationBytes
      : maximumAssertionBytes,
  );
  if (!keyID || !object) return null;
  return {
    version: 1,
    challengeID: proof.challengeID,
    installationID: proof.installationID,
    keyID: proof.keyID as string,
    proofKind: proof.proofKind,
    object,
  };
}

function parseSubmission(
  value: unknown,
): { score: ScoreRequest; proof: AppAttestProof } | null {
  if (
    !value || typeof value !== "object" || Array.isArray(value) ||
    containsFingerprint(value)
  ) return null;
  const envelope = value as Record<string, unknown>;
  if (!exactKeys(envelope, envelopeKeys) || envelope.version !== 1) return null;
  const score = parseScore(envelope.score);
  const proof = parseProof(envelope.appAttest);
  return score && proof ? { score, proof } : null;
}

function parseRegisteredKey(value: unknown): RegisteredKeyContext | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const key = value as Record<string, unknown>;
  if (
    !exactKeys(key, registeredKeyKeys) ||
    typeof key.publicKeyPEM !== "string" ||
    key.publicKeyPEM.length < 100 || key.publicKeyPEM.length > 2048 ||
    !key.publicKeyPEM.startsWith("-----BEGIN PUBLIC KEY-----") ||
    !key.publicKeyPEM.includes("-----END PUBLIC KEY-----") ||
    !Number.isInteger(key.previousSignCount) ||
    Number(key.previousSignCount) < 0 ||
    Number(key.previousSignCount) > 0xffff_ffff ||
    (key.environment !== "development" && key.environment !== "production") ||
    !validPolicyMetadata(key.validationCategory, key.bundleVersion)
  ) return null;
  return {
    publicKeyPEM: key.publicKeyPEM,
    previousSignCount: key.previousSignCount as number,
    environment: key.environment,
    validationCategory: key.validationCategory as number | null,
    bundleVersion: key.bundleVersion as string | null,
  };
}

function parseContext(value: unknown): AppAttestContext | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const context = value as Record<string, unknown>;
  if (
    !exactKeys(context, contextKeys) || context.version !== 1 ||
    !isCanonicalUuid(context.challengeID) ||
    !isCanonicalUuid(context.profileID) ||
    !isCanonicalUuid(context.installationID) ||
    typeof context.payloadSHA256 !== "string" ||
    !/^[0-9a-f]{64}$/.test(context.payloadSHA256) ||
    !decodeCanonicalBase64(context.keyID, 32, 32) ||
    (context.proofKind !== "attestation" &&
      context.proofKind !== "assertion") ||
    !isCanonicalTimestamp(context.expiresAt)
  ) return null;
  const challenge = decodeCanonicalBase64(context.challenge, 32, 32);
  if (!challenge) return null;
  const registeredKey = context.registeredKey === null
    ? null
    : parseRegisteredKey(context.registeredKey);
  if (
    (context.proofKind === "attestation" && context.registeredKey !== null) ||
    (context.proofKind === "assertion" && !registeredKey)
  ) return null;
  return {
    version: 1,
    challengeID: context.challengeID,
    challenge,
    profileID: context.profileID,
    installationID: context.installationID,
    payloadSHA256: context.payloadSHA256,
    keyID: context.keyID as string,
    proofKind: context.proofKind,
    expiresAt: context.expiresAt,
    registeredKey,
  };
}

function parseGrant(value: unknown): AppAttestGrant | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const grant = value as Record<string, unknown>;
  return exactKeys(grant, grantKeys) && grant.version === 1 &&
      isCanonicalUuid(grant.grantID) && isCanonicalTimestamp(grant.expiresAt)
    ? { version: 1, grantID: grant.grantID, expiresAt: grant.expiresAt }
    : null;
}

function isScoreResponse(value: unknown): value is Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const response = value as Record<string, unknown>;
  const rejected = response.disposition === "rejected";
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
  if (!exactKeys(response, expectedKeys)) return false;
  if (
    rejected
      ? typeof response.code !== "string" ||
        !rejectionCodes.has(response.code)
      : response.disposition !== "appended" &&
        response.disposition !== "duplicate"
  ) return false;
  if (
    !(response.acceptedCentiPoints === null ||
      Number.isInteger(response.acceptedCentiPoints) &&
        Number(response.acceptedCentiPoints) >= 0 &&
        Number(response.acceptedCentiPoints) <= 60_000)
  ) return false;
  if (
    !(response.wireContentSHA256 === null ||
      typeof response.wireContentSHA256 === "string" &&
        /^[0-9a-f]{64}$/.test(response.wireContentSHA256))
  ) return false;
  if (
    !(response.acceptedServerSeq === null ||
      isBigintString(response.acceptedServerSeq))
  ) return false;
  return isBigintString(response.competitionCursor, true);
}

function sha256(value: Uint8Array | string): Buffer {
  return createHash("sha256").update(value).digest();
}

function temporarilyUnavailable(): Response {
  return error(
    503,
    "temporarily_unavailable",
    "Unable to process request right now",
  );
}

function contextUnavailable(): Response {
  return error(
    409,
    "app_attest_context_unavailable",
    "App Attest proof is unavailable or expired",
  );
}

function proofRejected(): Response {
  return error(401, "app_attest_proof_rejected", "App Attest proof rejected");
}

function proofConflict(): Response {
  return error(
    409,
    "app_attest_proof_conflict",
    "App Attest proof conflicts with accepted state",
  );
}

function mapAuthorizationError(rpcError: RpcError): Response {
  if (rpcError.message === "app_attest_context_unavailable") {
    return contextUnavailable();
  }
  if (
    [
      "app_attest_assertion_rejected",
      "app_attest_attestation_stale",
      "app_attest_key_unavailable",
    ].includes(rpcError.message)
  ) return proofConflict();
  if (rpcError.message === "competition_not_found") {
    return mapRpcError(rpcError);
  }
  return temporarilyUnavailable();
}

function mapSubmissionError(rpcError: RpcError): Response {
  if (rpcError.message === "app_attest_grant_unavailable") {
    return error(
      409,
      "app_attest_grant_unavailable",
      "App Attest grant is unavailable or expired",
    );
  }
  return mapRpcError(rpcError);
}

function validationCategory(value: unknown): value is number {
  return Number.isInteger(value) && Number(value) >= 1 && Number(value) <= 10 &&
    ![7, 8, 9].includes(Number(value));
}

function validPolicyMetadata(
  category: unknown,
  version: unknown,
  policy?: AppAttestVerificationPolicy,
): boolean {
  if (category === null && version === null) return true;
  return validationCategory(category) &&
    typeof version === "string" &&
    /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(version) &&
    (policy === undefined ||
      policy.allowedValidationCategories.includes(category) &&
        policy.allowedBundleVersions.includes(version));
}

function samePolicyMetadata(
  verified: VerifiedAppAttestAssertion,
  registered: RegisteredKeyContext,
): boolean {
  return verified.validationCategory === registered.validationCategory &&
    verified.bundleVersion === registered.bundleVersion;
}

function validAttestationResult(
  value: VerifiedAppAttestAttestation,
  expectedKeyID: string,
  policy: AppAttestVerificationPolicy,
): boolean {
  return value.keyID === expectedKeyID &&
    value.environment === policy.environment &&
    typeof value.publicKeyPEM === "string" &&
    value.publicKeyPEM.length >= 100 && value.publicKeyPEM.length <= 2048 &&
    value.publicKeyPEM.startsWith("-----BEGIN PUBLIC KEY-----") &&
    value.publicKeyPEM.includes("-----END PUBLIC KEY-----") &&
    value.receipt instanceof Uint8Array && value.receipt.length >= 1 &&
    value.receipt.length <= 65_536 &&
    validPolicyMetadata(
      value.validationCategory,
      value.bundleVersion,
      policy,
    );
}

function validAssertionResult(
  value: VerifiedAppAttestAssertion,
  registeredKey: RegisteredKeyContext,
  policy: AppAttestVerificationPolicy,
): boolean {
  return Number.isInteger(value.signCount) &&
    value.signCount > registeredKey.previousSignCount &&
    value.signCount <= 0xffff_ffff &&
    validPolicyMetadata(
      value.validationCategory,
      value.bundleVersion,
      policy,
    );
}

export function appAttestPolicyFromEnvironment(
  read: (name: string) => string | undefined,
  now: Date,
): AppAttestVerificationPolicy | null {
  const appId = read("APP_ATTEST_APP_ID");
  const environment = read("APP_ATTEST_ENVIRONMENT");
  const categoriesValue = read("APP_ATTEST_ALLOWED_VALIDATION_CATEGORIES");
  const versionsValue = read("APP_ATTEST_ALLOWED_BUNDLE_VERSIONS");
  if (
    !appId || appId.length > 266 ||
    !/^[A-Z0-9]{10}\.(?:[A-Za-z0-9-]+\.)+[A-Za-z0-9-]+$/.test(appId) ||
    (environment !== "development" && environment !== "production") ||
    !categoriesValue || categoriesValue.length > 32 ||
    !versionsValue || versionsValue.length > 1024 ||
    !Number.isFinite(now.getTime())
  ) return null;
  const categoryParts = categoriesValue.split(",");
  const categories = categoryParts.map(Number);
  const versions = versionsValue.split(",");
  if (
    categoryParts.length > 10 ||
    categoryParts.some((part, index) =>
      !/^(?:[1-9]|10)$/.test(part) || String(categories[index]) !== part
    ) ||
    categories.some((category) => !validationCategory(category)) ||
    new Set(categories).size !== categories.length || versions.length > 16 ||
    versions.some((version) =>
      !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(version)
    ) || new Set(versions).size !== versions.length
  ) return null;
  return {
    appId,
    environment,
    allowedValidationCategories: categories,
    allowedBundleVersions: versions,
    now,
  };
}

const defaultDependencies: ScoreSubmissionDependencies = {
  ...defaultUserDependencies,
  ...defaultServiceDependencies,
  now: () => new Date(),
  appAttestPolicy: (now) =>
    appAttestPolicyFromEnvironment((name) => Deno.env.get(name), now),
  verifyAttestation: verifyAppAttestAttestation,
  verifyAssertion: verifyAppAttestAssertion,
  reportVerificationFailure: (code) => {
    console.warn("app_attest_verification_rejected", code);
  },
};

async function rpc(
  client: ScoringRpcClient,
  name: string,
  args: Record<string, unknown>,
): Promise<Awaited<ReturnType<ScoringRpcClient["rpc"]>> | null> {
  try {
    return await client.rpc(name, args);
  } catch {
    return null;
  }
}

export async function submitScoreRevisionHandler(
  request: Request,
  dependencies: ScoreSubmissionDependencies = defaultDependencies,
): Promise<Response> {
  if (request.method !== "POST") {
    return error(405, "method_not_allowed", "Method not allowed");
  }
  const parsed = parseSubmission(await readBoundedJson(request));
  if (!parsed) return error(400, "invalid_request", "Invalid score revision");

  let authenticated: Awaited<ReturnType<typeof authenticatedContext>>;
  try {
    authenticated = await authenticatedContext(request, dependencies);
  } catch {
    return temporarilyUnavailable();
  }
  if (!authenticated) {
    return error(401, "unauthorized", "Authentication required");
  }

  let now: Date;
  let policy: AppAttestVerificationPolicy | null;
  try {
    now = dependencies.now();
    policy = dependencies.appAttestPolicy(now);
  } catch {
    return temporarilyUnavailable();
  }
  if (!policy) return temporarilyUnavailable();

  const canonicalScore = canonicalScoreJSON(parsed.score);
  const payloadDigest = sha256(canonicalScore);
  const payloadSHA256 = payloadDigest.toString("hex");
  let serviceClient: ScoringRpcClient;
  try {
    serviceClient = dependencies.createServiceClient();
  } catch {
    return temporarilyUnavailable();
  }
  const loaded = await rpc(serviceClient, "load_app_attest_context", {
    target_auth_user_id: authenticated.userId,
    challenge_id: parsed.proof.challengeID,
    installation_id: parsed.proof.installationID,
    payload_sha256: payloadSHA256,
    key_id: parsed.proof.keyID,
    proof_kind: parsed.proof.proofKind,
  });
  if (!loaded) return temporarilyUnavailable();
  if (loaded.error) {
    return loaded.error.message === "app_attest_context_unavailable"
      ? contextUnavailable()
      : temporarilyUnavailable();
  }
  const context = parseContext(loaded.data);
  if (!context) return temporarilyUnavailable();
  if (
    context.challengeID !== parsed.proof.challengeID ||
    context.installationID !== parsed.proof.installationID ||
    context.payloadSHA256 !== payloadSHA256 ||
    context.keyID !== parsed.proof.keyID ||
    context.proofKind !== parsed.proof.proofKind ||
    Date.parse(context.expiresAt) <= now.getTime()
  ) return contextUnavailable();

  let clientData: Uint8Array;
  try {
    clientData = appAttestClientDataV1({
      challengeID: context.challengeID,
      challenge: context.challenge,
      profileID: context.profileID,
      installationID: context.installationID,
      payloadSHA256: payloadDigest,
      purpose: "score_revision",
    });
  } catch {
    return temporarilyUnavailable();
  }

  let publicKeyPEM: string | null = null;
  let receiptBase64: string | null = null;
  let verifiedEnvironment: "development" | "production";
  let verifiedCategory: number | null;
  let verifiedBundleVersion: string | null;
  let signCount: number;
  try {
    if (context.proofKind === "attestation") {
      const verified = dependencies.verifyAttestation({
        attestation: parsed.proof.object,
        clientDataHash: sha256(clientData),
        keyID: context.keyID,
        policy,
      });
      if (!validAttestationResult(verified, context.keyID, policy)) {
        return temporarilyUnavailable();
      }
      publicKeyPEM = verified.publicKeyPEM;
      receiptBase64 = Buffer.from(verified.receipt).toString("base64");
      verifiedEnvironment = verified.environment;
      verifiedCategory = verified.validationCategory;
      verifiedBundleVersion = verified.bundleVersion;
      signCount = 0;
    } else {
      const registeredKey = context.registeredKey;
      if (!registeredKey) return temporarilyUnavailable();
      if (registeredKey.environment !== policy.environment) {
        return proofRejected();
      }
      const verified = dependencies.verifyAssertion({
        assertion: parsed.proof.object,
        clientData,
        publicKeyPEM: registeredKey.publicKeyPEM,
        previousSignCount: registeredKey.previousSignCount,
        policy,
      });
      if (!validAssertionResult(verified, registeredKey, policy)) {
        return temporarilyUnavailable();
      }
      if (!samePolicyMetadata(verified, registeredKey)) {
        return proofRejected();
      }
      verifiedEnvironment = registeredKey.environment;
      verifiedCategory = verified.validationCategory;
      verifiedBundleVersion = verified.bundleVersion;
      signCount = verified.signCount;
    }
  } catch (verificationError) {
    if (verificationError instanceof AppAttestVerificationError) {
      try {
        dependencies.reportVerificationFailure?.(verificationError.code);
      } catch {
        // Diagnostics must never change the non-enumerating client response.
      }
      return proofRejected();
    }
    return temporarilyUnavailable();
  }

  const authorized = await rpc(serviceClient, "authorize_app_attest_proof", {
    target_auth_user_id: authenticated.userId,
    challenge_id: context.challengeID,
    installation_id: context.installationID,
    payload_sha256: payloadSHA256,
    key_id: context.keyID,
    proof_kind: context.proofKind,
    public_key_pem: publicKeyPEM,
    receipt_base64: receiptBase64,
    environment: verifiedEnvironment,
    validation_category: verifiedCategory,
    bundle_version: verifiedBundleVersion,
    sign_count: signCount,
    competition_id: parsed.score.competitionId,
    semantic_event_id: parsed.score.semanticEventId,
    day_ordinal: parsed.score.dayOrdinal,
    client_revision: parsed.score.clientRevision,
    evaluated_at: parsed.score.evaluatedAt,
    wire_content_sha256: parsed.score.wireContentSHA256,
  });
  if (!authorized) return temporarilyUnavailable();
  if (authorized.error) return mapAuthorizationError(authorized.error);
  const grant = parseGrant(authorized.data);
  if (!grant) return temporarilyUnavailable();

  const submitted = await rpc(
    authenticated.client,
    "submit_attested_score_revision",
    {
      grant_id: grant.grantID,
      competition_id: parsed.score.competitionId,
      semantic_event_id: parsed.score.semanticEventId,
      day_ordinal: parsed.score.dayOrdinal,
      client_revision: parsed.score.clientRevision,
      evaluated_at: parsed.score.evaluatedAt,
      move_mode: parsed.score.moveMode,
      stand_mode: parsed.score.standMode,
      move_basis_points: parsed.score.moveBasisPoints,
      exercise_basis_points: parsed.score.exerciseBasisPoints,
      stand_basis_points: parsed.score.standBasisPoints,
      availability_reason: parsed.score.availabilityReason,
      scoring_policy_identity: parsed.score.scoringPolicyIdentity,
      payload_sha256: payloadSHA256,
      expected_wire_content_sha256: parsed.score.wireContentSHA256,
    },
  );
  if (!submitted) return temporarilyUnavailable();
  if (submitted.error) return mapSubmissionError(submitted.error);
  if (!isScoreResponse(submitted.data)) return temporarilyUnavailable();
  return submitted.data.disposition === "rejected"
    ? json(409, submitted.data)
    : json(200, submitted.data);
}

if (import.meta.main) {
  Deno.serve((request) => submitScoreRevisionHandler(request));
}
