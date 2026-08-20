import { assertEquals } from "@std/assert";
import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import {
  appAttestClientDataV1,
  AppAttestVerificationError,
  type AppAttestVerificationErrorCode,
  type AppAttestVerificationPolicy,
} from "../_shared/app-attest.ts";
import { containsFingerprint } from "../_shared/scoring_http.ts";
import {
  appAttestPolicyFromEnvironment,
  canonicalScoreRevisionJSON,
  type ScoreSubmissionDependencies,
  type ScoringRpcClient,
  submitScoreRevisionHandler,
} from "./index.ts";

const authUserID = "e1000000-0000-4000-8000-000000000001";
const profileID = "e2000000-0000-4000-8000-000000000001";
const challengeID = "e3200000-0000-4000-8000-000000000001";
const installationID = "e3100000-0000-4000-8000-000000000001";
const keyID = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=";
const challenge = "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=";
const payloadSHA256 =
  "35f7065ad17014d3373037266cbad0b0ec4308267022cc340076e62052445cc5";
const grantID = "e3300000-0000-4000-8000-000000000001";
const fixedNow = new Date("2026-08-15T19:01:00Z");
const publicKeyPEM = `-----BEGIN PUBLIC KEY-----\n${
  "A".repeat(120)
}\n-----END PUBLIC KEY-----`;
const policy: AppAttestVerificationPolicy = {
  appId: "TEAM123456.com.example.HealthComp",
  environment: "development",
  allowedValidationCategories: [3],
  allowedBundleVersions: ["1"],
  now: fixedNow,
};

const score = {
  version: 1,
  competitionId: "63000000-0000-0000-0000-000000000001",
  semanticEventId: "64000000-0000-4000-8000-000000000001",
  dayOrdinal: 1,
  clientRevision: "9007199254740993",
  evaluatedAt: "2026-08-12T12:00:00Z",
  moveMode: "activeEnergyKilocalories",
  standMode: "standHours",
  moveBasisPoints: 10000,
  exerciseBasisPoints: 5000,
  standBasisPoints: 12500,
  availabilityReason: "available",
  scoringPolicyIdentity: "healthcomp.activity-score.v1",
  wireContentSHA256:
    "37df3f48a20b0b6e042e2450241af9c84ec7696ee505b97d9052dc201afb7fd9",
};
const proof = {
  version: 1,
  challengeID,
  installationID,
  keyID,
  proofKind: "attestation",
  object: Buffer.from("synthetic-attestation").toString("base64"),
};
const envelope = { version: 1, score, appAttest: proof };
const context = {
  version: 1,
  challengeID,
  challenge,
  profileID,
  installationID,
  payloadSHA256,
  keyID,
  proofKind: "attestation",
  expiresAt: "2026-08-15T19:05:00+00:00",
  registeredKey: null,
};
const grant = {
  version: 1,
  grantID,
  expiresAt: "2026-08-15T19:03:00+00:00",
};
const appended = {
  disposition: "appended",
  acceptedCentiPoints: 27500,
  wireContentSHA256: score.wireContentSHA256,
  acceptedServerSeq: "3",
  competitionCursor: "9",
};

interface RpcCall {
  client: "user" | "service";
  name: string;
  args: Record<string, unknown>;
}

function request(
  value: unknown = envelope,
  authorization = "Bearer user-jwt",
  method = "POST",
  contentType = "application/json",
): Request {
  const headers = new Headers();
  if (authorization) headers.set("authorization", authorization);
  if (contentType) headers.set("content-type", contentType);
  return new Request("http://localhost/functions/v1/submit-score-revision", {
    method,
    headers,
    body: method === "POST" ? JSON.stringify(value) : undefined,
  });
}

function rpcClient(
  rpc: ScoringRpcClient["rpc"],
  authenticated = true,
): ScoringRpcClient {
  return {
    auth: {
      getUser: () =>
        Promise.resolve({
          data: { user: authenticated ? { id: authUserID } : null },
          error: authenticated ? null : { message: "invalid token" },
        }),
    },
    rpc,
  };
}

type TestScoreSubmissionDependencies = ScoreSubmissionDependencies & {
  reportVerificationFailure?: (
    code: AppAttestVerificationErrorCode,
  ) => void;
};

function dependencies(
  overrides: Partial<TestScoreSubmissionDependencies> = {},
  calls: RpcCall[] = [],
): TestScoreSubmissionDependencies {
  return {
    createUserClient: () =>
      rpcClient((name, args) => {
        calls.push({ client: "user", name, args });
        return Promise.resolve({ data: appended, error: null });
      }),
    createServiceClient: () =>
      rpcClient((name, args) => {
        calls.push({ client: "service", name, args });
        if (name === "load_app_attest_context") {
          return Promise.resolve({ data: context, error: null });
        }
        return Promise.resolve({ data: grant, error: null });
      }),
    now: () => fixedNow,
    appAttestPolicy: () => policy,
    verifyAttestation: () => ({
      keyID,
      publicKeyPEM,
      receipt: new TextEncoder().encode("receipt"),
      environment: "development",
      validationCategory: 3,
      bundleVersion: "1",
    }),
    verifyAssertion: () => ({
      signCount: 2,
      validationCategory: 3,
      bundleVersion: "1",
    }),
    ...overrides,
  };
}

function expectedClientData(
  selectedContext: Pick<
    typeof context,
    | "challengeID"
    | "challenge"
    | "profileID"
    | "installationID"
    | "payloadSHA256"
  > = context,
): Uint8Array {
  return appAttestClientDataV1({
    challengeID: selectedContext.challengeID,
    challenge: Buffer.from(selectedContext.challenge, "base64"),
    profileID: selectedContext.profileID,
    installationID: selectedContext.installationID,
    payloadSHA256: Buffer.from(selectedContext.payloadSHA256, "hex"),
    purpose: "score_revision",
  });
}

Deno.test("score JSON is frozen cross-language and submission requires the exact proof envelope", async () => {
  const canonical =
    '{"availabilityReason":"available","clientRevision":"9007199254740993","competitionId":"63000000-0000-0000-0000-000000000001","dayOrdinal":1,"evaluatedAt":"2026-08-12T12:00:00Z","exerciseBasisPoints":5000,"moveBasisPoints":10000,"moveMode":"activeEnergyKilocalories","scoringPolicyIdentity":"healthcomp.activity-score.v1","semanticEventId":"64000000-0000-4000-8000-000000000001","standBasisPoints":12500,"standMode":"standHours","version":1,"wireContentSHA256":"37df3f48a20b0b6e042e2450241af9c84ec7696ee505b97d9052dc201afb7fd9"}';
  assertEquals(canonicalScoreRevisionJSON(score), canonical);
  assertEquals(
    createHash("sha256").update(canonical).digest("hex"),
    payloadSHA256,
  );

  for (
    const invalid of [
      score,
      { version: 1, score },
      { version: 1, score, appAttest: proof, unexpected: true },
    ]
  ) {
    const response = await submitScoreRevisionHandler(request(invalid), {
      ...dependencies(),
      createUserClient: () => {
        throw new Error("invalid envelopes must fail before authentication");
      },
    });
    assertEquals(response.status, 400);
  }
});

Deno.test("attestation verifies canonical bindings, authorizes one grant, then submits as the user", async () => {
  const calls: RpcCall[] = [];
  let verifierInput:
    | Parameters<
      ScoreSubmissionDependencies["verifyAttestation"]
    >[0]
    | null = null;
  const response = await submitScoreRevisionHandler(
    request(),
    dependencies({
      verifyAttestation: (input) => {
        verifierInput = input;
        return {
          keyID,
          publicKeyPEM,
          receipt: new TextEncoder().encode("receipt"),
          environment: "development",
          validationCategory: 3,
          bundleVersion: "1",
        };
      },
      verifyAssertion: () => {
        throw new Error("attestation must not use assertion verification");
      },
    }, calls),
  );

  assertEquals(response.status, 200);
  assertEquals(await response.json(), appended);
  assertEquals(calls.map(({ client, name }) => `${client}:${name}`), [
    "service:load_app_attest_context",
    "service:authorize_app_attest_proof",
    "user:submit_attested_score_revision",
  ]);
  assertEquals(calls[0].args, {
    target_auth_user_id: authUserID,
    challenge_id: challengeID,
    installation_id: installationID,
    payload_sha256: payloadSHA256,
    key_id: keyID,
    proof_kind: "attestation",
  });
  assertEquals(
    Buffer.from(verifierInput!.attestation),
    Buffer.from(proof.object, "base64"),
  );
  assertEquals(
    Buffer.from(verifierInput!.clientDataHash).toString("hex"),
    createHash("sha256").update(expectedClientData()).digest("hex"),
  );
  assertEquals(verifierInput!.keyID, keyID);
  assertEquals(verifierInput!.policy, policy);
  assertEquals(calls[1].args, {
    target_auth_user_id: authUserID,
    challenge_id: challengeID,
    installation_id: installationID,
    payload_sha256: payloadSHA256,
    key_id: keyID,
    proof_kind: "attestation",
    public_key_pem: publicKeyPEM,
    receipt_base64: Buffer.from("receipt").toString("base64"),
    environment: "development",
    validation_category: 3,
    bundle_version: "1",
    sign_count: 0,
    competition_id: score.competitionId,
    semantic_event_id: score.semanticEventId,
    day_ordinal: score.dayOrdinal,
    client_revision: score.clientRevision,
    evaluated_at: score.evaluatedAt,
    wire_content_sha256: score.wireContentSHA256,
  });
  assertEquals(calls[2].args, {
    grant_id: grantID,
    competition_id: score.competitionId,
    semantic_event_id: score.semanticEventId,
    day_ordinal: score.dayOrdinal,
    client_revision: score.clientRevision,
    evaluated_at: score.evaluatedAt,
    move_mode: score.moveMode,
    stand_mode: score.standMode,
    move_basis_points: score.moveBasisPoints,
    exercise_basis_points: score.exerciseBasisPoints,
    stand_basis_points: score.standBasisPoints,
    availability_reason: score.availabilityReason,
    scoring_policy_identity: score.scoringPolicyIdentity,
    payload_sha256: payloadSHA256,
    expected_wire_content_sha256: score.wireContentSHA256,
  });
  assertEquals("participant_profile_id" in calls[2].args, false);
  assertEquals("accepted_centi_points" in calls[2].args, false);
});

Deno.test("assertion renewal uses only registered public state and preserves duplicate responses", async () => {
  const assertionProof = {
    ...proof,
    proofKind: "assertion",
    object: Buffer.from("synthetic-assertion").toString("base64"),
  };
  const assertionContext = {
    ...context,
    proofKind: "assertion",
    registeredKey: {
      publicKeyPEM,
      previousSignCount: 1,
      environment: "development",
      validationCategory: 3,
      bundleVersion: "1",
    },
  };
  const duplicate = { ...appended, disposition: "duplicate" };
  const calls: RpcCall[] = [];
  let verifierInput:
    | Parameters<
      ScoreSubmissionDependencies["verifyAssertion"]
    >[0]
    | null = null;
  const response = await submitScoreRevisionHandler(
    request({ version: 1, score, appAttest: assertionProof }),
    dependencies({
      createServiceClient: () =>
        rpcClient((name, args) => {
          calls.push({ client: "service", name, args });
          return Promise.resolve({
            data: name === "load_app_attest_context" ? assertionContext : grant,
            error: null,
          });
        }),
      createUserClient: () =>
        rpcClient((name, args) => {
          calls.push({ client: "user", name, args });
          return Promise.resolve({ data: duplicate, error: null });
        }),
      verifyAttestation: () => {
        throw new Error("assertion must not use attestation verification");
      },
      verifyAssertion: (input) => {
        verifierInput = input;
        return {
          signCount: 2,
          validationCategory: 3,
          bundleVersion: "1",
        };
      },
    }, calls),
  );

  assertEquals(response.status, 200);
  assertEquals(await response.json(), duplicate);
  assertEquals(
    Buffer.from(verifierInput!.clientData),
    Buffer.from(expectedClientData(assertionContext)),
  );
  assertEquals(verifierInput!.publicKeyPEM, publicKeyPEM);
  assertEquals(verifierInput!.previousSignCount, 1);
  assertEquals(calls[1].args.public_key_pem, null);
  assertEquals(calls[1].args.receipt_base64, null);
  assertEquals(calls[1].args.environment, "development");
  assertEquals(calls[1].args.sign_count, 2);
});

Deno.test("submission is POST-only, bearer-authenticated, and configuration-fail-closed", async () => {
  const wrongMethod = await submitScoreRevisionHandler(
    request(undefined, "Bearer user-jwt", "GET"),
    {
      ...dependencies(),
      createUserClient: () => {
        throw new Error("wrong method must not authenticate");
      },
    },
  );
  assertEquals(wrongMethod.status, 405);

  for (const authorization of ["", "Basic credential", "Bearer "]) {
    const response = await submitScoreRevisionHandler(
      request(envelope, authorization),
      {
        ...dependencies(),
        createUserClient: () => {
          throw new Error("malformed bearer must not create a client");
        },
      },
    );
    assertEquals(response.status, 401);
  }

  const invalidSession = await submitScoreRevisionHandler(request(), {
    ...dependencies(),
    createUserClient: () =>
      rpcClient(() => Promise.resolve({ data: null, error: null }), false),
    createServiceClient: () => {
      throw new Error("invalid session must not create a service client");
    },
  });
  assertEquals(invalidSession.status, 401);

  const missingConfiguration = await submitScoreRevisionHandler(request(), {
    ...dependencies(),
    appAttestPolicy: () => null,
    createServiceClient: () => {
      throw new Error("missing policy must fail before service access");
    },
  });
  assertEquals(missingConfiguration.status, 503);
  assertEquals(
    (await missingConfiguration.json()).error.code,
    "temporarily_unavailable",
  );
});

Deno.test("production policy configuration is exact, bounded, and rejects missing values", () => {
  const configured = new Map([
    ["APP_ATTEST_APP_ID", "TEAM123456.com.example.HealthComp"],
    ["APP_ATTEST_ENVIRONMENT", "production"],
    ["APP_ATTEST_ALLOWED_VALIDATION_CATEGORIES", "2,4"],
    ["APP_ATTEST_ALLOWED_BUNDLE_VERSIONS", "1,2"],
  ]);
  assertEquals(
    appAttestPolicyFromEnvironment((name) => configured.get(name), fixedNow),
    {
      appId: "TEAM123456.com.example.HealthComp",
      environment: "production",
      allowedValidationCategories: [2, 4],
      allowedBundleVersions: ["1", "2"],
      now: fixedNow,
    },
  );
  for (
    const mutation of [
      ["APP_ATTEST_APP_ID", undefined],
      ["APP_ATTEST_APP_ID", "bad-app-id"],
      ["APP_ATTEST_ENVIRONMENT", "sandbox"],
      ["APP_ATTEST_ALLOWED_VALIDATION_CATEGORIES", "2,2"],
      ["APP_ATTEST_ALLOWED_VALIDATION_CATEGORIES", "2, 4"],
      ["APP_ATTEST_ALLOWED_VALIDATION_CATEGORIES", "7"],
      ["APP_ATTEST_ALLOWED_BUNDLE_VERSIONS", ""],
      ["APP_ATTEST_ALLOWED_BUNDLE_VERSIONS", "1,1"],
    ] as const
  ) {
    const candidate = new Map(configured);
    if (mutation[1] === undefined) candidate.delete(mutation[0]);
    else candidate.set(mutation[0], mutation[1]);
    assertEquals(
      appAttestPolicyFromEnvironment((name) => candidate.get(name), fixedNow),
      null,
    );
  }
});

Deno.test("submission rejects malformed, oversized, noncanonical, and privacy-bearing proof envelopes", async () => {
  const privacyBytes = new TextEncoder().encode(
    `activity-snapshot:${"x".repeat(14)}`,
  );
  const invalidBodies: unknown[] = [
    null,
    {},
    { ...envelope, version: 2 },
    { ...envelope, extra: true },
    { ...envelope, score: { ...score, extra: true } },
    { ...envelope, score: { ...score, clientRevision: 1 } },
    { ...envelope, score: { ...score, moveMode: [score.moveMode] } },
    { ...envelope, score: { ...score, standMode: [score.standMode] } },
    {
      ...envelope,
      score: { ...score, availabilityReason: [score.availabilityReason] },
    },
    { ...envelope, appAttest: { ...proof, version: 2 } },
    { ...envelope, appAttest: { ...proof, extra: true } },
    {
      ...envelope,
      appAttest: { ...proof, challengeID: challengeID.toUpperCase() },
    },
    { ...envelope, appAttest: { ...proof, installationID: "not-a-uuid" } },
    { ...envelope, appAttest: { ...proof, keyID: `${"A".repeat(42)}B=` } },
    { ...envelope, appAttest: { ...proof, proofKind: "unknown" } },
    { ...envelope, appAttest: { ...proof, object: `${"A".repeat(42)}B=` } },
    {
      ...envelope,
      appAttest: {
        ...proof,
        proofKind: "assertion",
        object: Buffer.alloc(2049).toString("base64"),
      },
    },
    {
      ...envelope,
      appAttest: {
        ...proof,
        object: Buffer.alloc(96 * 1024 + 1).toString("base64"),
      },
    },
    {
      ...envelope,
      appAttest: {
        ...proof,
        object: Buffer.from(privacyBytes).toString("base64"),
      },
    },
  ];
  for (const invalidBody of invalidBodies) {
    const response = await submitScoreRevisionHandler(request(invalidBody), {
      ...dependencies(),
      createUserClient: () => {
        throw new Error("invalid input must fail before authentication");
      },
    });
    assertEquals(response.status, 400);
  }

  for (
    const invalidRequest of [
      new Request("http://localhost/functions/v1/submit-score-revision", {
        method: "POST",
        headers: {
          authorization: "Bearer user-jwt",
          "content-type": "application/json",
        },
        body: "{",
      }),
      request(envelope, "Bearer user-jwt", "POST", "text/plain"),
      request({ ...envelope, padding: "x".repeat(145 * 1024) }),
    ]
  ) {
    const response = await submitScoreRevisionHandler(invalidRequest, {
      ...dependencies(),
      createUserClient: () => {
        throw new Error("invalid input must fail before authentication");
      },
    });
    assertEquals(response.status, 400);
  }
});

Deno.test("context mismatch, expiry, replay, and cross-profile state fail before score mutation", async () => {
  for (
    const message of [
      "app_attest_context_unavailable",
      "app_attest_assertion_rejected",
      "app_attest_attestation_stale",
      "app_attest_key_unavailable",
    ]
  ) {
    let scoreCalled = false;
    const response = await submitScoreRevisionHandler(
      request(),
      dependencies({
        createServiceClient: () =>
          rpcClient((name) =>
            Promise.resolve(
              name === "load_app_attest_context"
                ? { data: context, error: null }
                : { data: null, error: { message, code: "P0001" } },
            )
          ),
        createUserClient: () =>
          rpcClient(() => {
            scoreCalled = true;
            return Promise.resolve({ data: appended, error: null });
          }),
      }),
    );
    assertEquals(response.status, 409);
    assertEquals(scoreCalled, false);
  }

  let verified = false;
  const unavailable = await submitScoreRevisionHandler(
    request(),
    dependencies({
      createServiceClient: () =>
        rpcClient(() =>
          Promise.resolve({
            data: null,
            error: {
              message: "app_attest_context_unavailable",
              code: "P0002",
              details: "private profile mismatch",
            },
          })
        ),
      verifyAttestation: () => {
        verified = true;
        throw new Error("must not verify unavailable context");
      },
    }),
  );
  assertEquals(unavailable.status, 409);
  assertEquals(verified, false);
  assertEquals(
    JSON.stringify(await unavailable.json()).includes("profile"),
    false,
  );

  for (
    const unavailableContext of [
      { ...context, challengeID: "e3200000-0000-4000-8000-000000000099" },
      { ...context, installationID: "e3100000-0000-4000-8000-000000000099" },
      { ...context, payloadSHA256: "a".repeat(64) },
      { ...context, keyID: "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=" },
      {
        ...context,
        proofKind: "assertion",
        registeredKey: {
          publicKeyPEM,
          previousSignCount: 1,
          environment: "development",
          validationCategory: 3,
          bundleVersion: "1",
        },
      },
    ]
  ) {
    const response = await submitScoreRevisionHandler(
      request(),
      dependencies({
        createServiceClient: () =>
          rpcClient(() =>
            Promise.resolve({ data: unavailableContext, error: null })
          ),
      }),
    );
    assertEquals(response.status, 409);
  }

  for (
    const malformedContext of [
      { ...context, registeredKey: { internal: "unexpected" } },
      { ...context, internal: "private" },
    ]
  ) {
    const response = await submitScoreRevisionHandler(
      request(),
      dependencies({
        createServiceClient: () =>
          rpcClient(() =>
            Promise.resolve({ data: malformedContext, error: null })
          ),
      }),
    );
    assertEquals(response.status, 503);
  }
});

Deno.test("invalid attestation, assertion, and equal counters are stable proof rejections", async () => {
  const codes = [
    "invalid_attestation",
    "invalid_assertion",
    "invalid_counter",
    "invalid_environment",
    "invalid_validation_category",
    "invalid_bundle_version",
  ] as const;
  for (const code of codes) {
    let authorizationCalled = false;
    const reportedCodes: AppAttestVerificationErrorCode[] = [];
    const assertion = code === "invalid_assertion" ||
      code === "invalid_counter";
    const selectedProof = assertion
      ? { ...proof, proofKind: "assertion" }
      : proof;
    const selectedContext = assertion
      ? {
        ...context,
        proofKind: "assertion",
        registeredKey: {
          publicKeyPEM,
          previousSignCount: 1,
          environment: "development",
          validationCategory: 3,
          bundleVersion: "1",
        },
      }
      : context;
    const response = await submitScoreRevisionHandler(
      request({ version: 1, score, appAttest: selectedProof }),
      dependencies({
        createServiceClient: () =>
          rpcClient((name) => {
            if (name === "authorize_app_attest_proof") {
              authorizationCalled = true;
            }
            return Promise.resolve({ data: selectedContext, error: null });
          }),
        verifyAttestation: () => {
          throw new AppAttestVerificationError(code);
        },
        verifyAssertion: () => {
          throw new AppAttestVerificationError(code);
        },
        reportVerificationFailure: (reportedCode) => {
          reportedCodes.push(reportedCode);
          if (reportedCode === "invalid_bundle_version") {
            throw new Error("synthetic reporter failure");
          }
        },
      }),
    );
    assertEquals(response.status, 401);
    assertEquals(
      (await response.json()).error.code,
      "app_attest_proof_rejected",
    );
    assertEquals(authorizationCalled, false);
    assertEquals(reportedCodes, [code]);
  }
});

Deno.test("concurrent proof replay permits one grant-backed score call", async () => {
  let authorizationCount = 0;
  let scoreCount = 0;
  const shared = dependencies({
    createServiceClient: () =>
      rpcClient((name) => {
        if (name === "load_app_attest_context") {
          return Promise.resolve({ data: context, error: null });
        }
        authorizationCount += 1;
        return Promise.resolve(
          authorizationCount === 1 ? { data: grant, error: null } : {
            data: null,
            error: {
              message: "app_attest_context_unavailable",
              code: "P0002",
            },
          },
        );
      }),
    createUserClient: () =>
      rpcClient(() => {
        scoreCount += 1;
        return Promise.resolve({ data: appended, error: null });
      }),
  });
  const responses = await Promise.all([
    submitScoreRevisionHandler(request(), shared),
    submitScoreRevisionHandler(request(), shared),
  ]);
  assertEquals(responses.map((response) => response.status).sort(), [200, 409]);
  assertEquals(scoreCount, 1);
});

Deno.test("a fresh proof after a lost response preserves semantic duplicate recovery", async () => {
  let attempt = 0;
  const calls: RpcCall[] = [];
  const replacementChallengeID = "e3200000-0000-4000-8000-000000000002";
  const replacementProof = {
    ...proof,
    challengeID: replacementChallengeID,
    object: Buffer.from("fresh-synthetic-attestation").toString("base64"),
  };
  const shared = dependencies({
    createServiceClient: () =>
      rpcClient((name, args) => {
        calls.push({ client: "service", name, args });
        if (name === "load_app_attest_context") {
          return Promise.resolve({
            data: { ...context, challengeID: args.challenge_id as string },
            error: null,
          });
        }
        return Promise.resolve({
          data: {
            ...grant,
            grantID: `e3300000-0000-4000-8000-00000000000${attempt + 1}`,
          },
          error: null,
        });
      }),
    createUserClient: () =>
      rpcClient((name, args) => {
        calls.push({ client: "user", name, args });
        attempt += 1;
        return Promise.resolve({
          data: attempt === 1
            ? appended
            : { ...appended, disposition: "duplicate" },
          error: null,
        });
      }),
  });

  const first = await submitScoreRevisionHandler(request(), shared);
  const recovered = await submitScoreRevisionHandler(
    request({ version: 1, score, appAttest: replacementProof }),
    shared,
  );
  assertEquals((await first.json()).disposition, "appended");
  assertEquals((await recovered.json()).disposition, "duplicate");
  assertEquals(
    calls.filter((call) => call.name === "submit_attested_score_revision")
      .length,
    2,
  );
});

Deno.test("database and infrastructure failures are typed without leaking internals", async () => {
  const cases = [
    ["competition_not_found", 404, "competition_not_found"],
    ["app_attest_grant_unavailable", 409, "app_attest_grant_unavailable"],
    ["secret_internal_failure", 503, "temporarily_unavailable"],
  ] as const;
  for (const [message, status, code] of cases) {
    const response = await submitScoreRevisionHandler(
      request(),
      dependencies({
        createUserClient: () =>
          rpcClient(() =>
            Promise.resolve({
              data: null,
              error: {
                message,
                code: "private-code",
                details: "private database details",
              },
            })
          ),
      }),
    );
    const serialized = JSON.stringify(await response.json());
    assertEquals(response.status, status);
    assertEquals(JSON.parse(serialized).error.code, code);
    assertEquals(serialized.includes("private"), false);
    assertEquals(serialized.includes("secret_internal_failure"), false);
  }

  const outage = await submitScoreRevisionHandler(
    request(),
    dependencies({
      createServiceClient: () =>
        rpcClient(() => Promise.reject(new Error("network detail"))),
    }),
  );
  assertEquals(outage.status, 503);
  assertEquals(JSON.stringify(await outage.json()).includes("network"), false);
});

Deno.test("canonical score conflicts remain unchanged and malformed output fails closed", async () => {
  const conflict = {
    disposition: "rejected",
    code: "revision_regression",
    acceptedCentiPoints: 27500,
    wireContentSHA256: score.wireContentSHA256,
    acceptedServerSeq: "3",
    competitionCursor: "9",
  };
  const malformed = [
    { disposition: "rejected", code: "revision_regression" },
    { ...appended, disposition: ["appended"] },
    { ...conflict, code: ["revision_regression"] },
  ];
  for (
    const [data, status] of [
      [conflict, 409],
      ...malformed.map((data) => [data, 503] as const),
    ] as const
  ) {
    const response = await submitScoreRevisionHandler(
      request(),
      dependencies({
        createUserClient: () =>
          rpcClient(() => Promise.resolve({ data, error: null })),
      }),
    );
    assertEquals(response.status, status);
    if (status === 409) assertEquals(await response.json(), conflict);
  }
});

Deno.test("every frozen privacy and digest-mutation vector remains executable", async () => {
  const fixture = JSON.parse(
    await Deno.readTextFile(
      new URL("../../tests/fixtures/scoring-v1.json", import.meta.url),
    ),
  );
  const selected = fixture.vectors.filter((vector: { kind: string }) =>
    ["invalid_wire", "privacy", "digest_mutation"].includes(vector.kind)
  );
  assertEquals(selected.length, 19);
  for (const vector of selected) {
    const candidate: Record<string, unknown> = { ...score };
    if (vector.kind === "privacy") candidate.probe = vector.value;
    if (vector.kind === "invalid_wire") {
      if (vector.field === "move_basis_points") {
        candidate.moveBasisPoints = vector.value;
      } else if (vector.field === "accepted_centi_points") {
        candidate.acceptedCentiPoints = vector.value;
      } else candidate.scoringPolicyIdentity = vector.value;
    }
    if (vector.kind === "digest_mutation") {
      const mapping: Record<string, string> = {
        competition_id: "competitionId",
        participant_id: "participantId",
        day_ordinal: "dayOrdinal",
        move_mode: "moveMode",
        stand_mode: "standMode",
        move_basis_points: "moveBasisPoints",
        exercise_basis_points: "exerciseBasisPoints",
        stand_basis_points: "standBasisPoints",
        availability_reason: "availabilityReason",
        policy_identity: "scoringPolicyIdentity",
        client_revision: "clientRevision",
      };
      const key = mapping[vector.field];
      candidate[key] = key.endsWith("Id")
        ? "00000000-0000-4000-8000-000000000099"
        : key.includes("BasisPoints") || key === "dayOrdinal"
        ? 2
        : key === "clientRevision"
        ? "8"
        : "mutated";
    }
    const response = await submitScoreRevisionHandler(
      request({ version: 1, score: candidate, appAttest: proof }),
      dependencies(),
    );
    assertEquals(response.status >= 400, true, vector.name);
  }
  assertEquals(containsFingerprint("benign-wire-digest-value"), false);
});
