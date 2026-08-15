import { assertEquals } from "@std/assert";
import {
  appAttestChallengeHandler,
  type AppAttestChallengeRpcClient,
} from "./index.ts";

const validKeyID = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=";
const validRequest = {
  version: 1,
  installationID: "e3100000-0000-4000-8000-000000000001",
  payloadSHA256:
    "37df3f48a20b0b6e042e2450241af9c84ec7696ee505b97d9052dc201afb7fd9",
  keyID: validKeyID,
};
const validResponse = {
  version: 1,
  challengeID: "e3200000-0000-4000-8000-000000000001",
  challenge: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=",
  expiresAt: "2026-08-15T19:05:00+00:00",
  proofKind: "attestation",
};

function request(
  value: unknown = validRequest,
  authorization = "Bearer user-jwt",
  method = "POST",
  contentType = "application/json",
): Request {
  const headers = new Headers();
  if (authorization) headers.set("authorization", authorization);
  if (contentType) headers.set("content-type", contentType);
  return new Request("http://localhost/functions/v1/app-attest-challenge", {
    method,
    headers,
    body: method === "POST" ? JSON.stringify(value) : undefined,
  });
}

function client(
  rpc: AppAttestChallengeRpcClient["rpc"],
  authenticated = true,
): AppAttestChallengeRpcClient {
  return {
    auth: {
      getUser: () =>
        Promise.resolve({
          data: { user: authenticated ? { id: "auth-user" } : null },
          error: authenticated ? null : { message: "invalid token" },
        }),
    },
    rpc,
  };
}

Deno.test("challenge is POST-only and requires a verified bearer session", async () => {
  let clientCreated = false;
  const wrongMethod = await appAttestChallengeHandler(
    request(undefined, "Bearer user-jwt", "GET"),
    {
      createUserClient: () => {
        clientCreated = true;
        throw new Error("must not authenticate a disallowed method");
      },
    },
  );
  assertEquals(wrongMethod.status, 405);
  assertEquals(clientCreated, false);

  for (const authorization of ["", "Basic credential", "Bearer "]) {
    const response = await appAttestChallengeHandler(
      request(validRequest, authorization),
      {
        createUserClient: () => {
          throw new Error("malformed bearer must not create a client");
        },
      },
    );
    assertEquals(response.status, 401);
    assertEquals(await response.json(), {
      error: { code: "unauthorized", message: "Authentication required" },
    });
  }

  let rpcCalled = false;
  const invalidSession = await appAttestChallengeHandler(request(), {
    createUserClient: () =>
      client(() => {
        rpcCalled = true;
        return Promise.resolve({ data: null, error: null });
      }, false),
  });
  assertEquals(invalidSession.status, 401);
  assertEquals(rpcCalled, false);
});

Deno.test("challenge sends only canonical bounded fields to the authenticated RPC", async () => {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  let receivedAuthorization = "";
  const response = await appAttestChallengeHandler(request(), {
    createUserClient: (authorization) => {
      receivedAuthorization = authorization;
      return client((name, args) => {
        calls.push({ name, args });
        return Promise.resolve({ data: validResponse, error: null });
      });
    },
  });

  assertEquals(response.status, 200);
  assertEquals(response.headers.get("cache-control"), "no-store");
  assertEquals(await response.json(), validResponse);
  assertEquals(receivedAuthorization, "Bearer user-jwt");
  assertEquals(calls, [{
    name: "issue_app_attest_challenge",
    args: {
      installation_id: validRequest.installationID,
      payload_sha256: validRequest.payloadSHA256,
      key_id: validRequest.keyID,
    },
  }]);
});

Deno.test("challenge rejects malformed, expansive, noncanonical, and privacy-bearing input", async () => {
  const privacyKeyBytes = new TextEncoder().encode(
    `activity-snapshot:${"x".repeat(14)}`,
  );
  let privacyKeyBinary = "";
  for (const byte of privacyKeyBytes) {
    privacyKeyBinary += String.fromCharCode(byte);
  }
  const invalidBodies: unknown[] = [
    null,
    {},
    { ...validRequest, version: 2 },
    { ...validRequest, unexpected: true },
    {
      ...validRequest,
      installationID: validRequest.installationID.toUpperCase(),
    },
    {
      ...validRequest,
      installationID: "e3100000-0000-0000-8000-000000000001",
    },
    {
      ...validRequest,
      payloadSHA256: validRequest.payloadSHA256.toUpperCase(),
    },
    { ...validRequest, payloadSHA256: "a".repeat(63) },
    { ...validRequest, keyID: `${"A".repeat(42)}B=` },
    { ...validRequest, keyID: `${"_".repeat(42)}8=` },
    { ...validRequest, keyID: btoa(privacyKeyBinary) },
  ];

  for (const invalidBody of invalidBodies) {
    const response = await appAttestChallengeHandler(request(invalidBody), {
      createUserClient: () => {
        throw new Error("invalid input must not authenticate");
      },
    });
    assertEquals(response.status, 400);
    assertEquals((await response.json()).error.code, "invalid_request");
  }

  for (
    const invalidRequest of [
      new Request("http://localhost/functions/v1/app-attest-challenge", {
        method: "POST",
        headers: {
          authorization: "Bearer user-jwt",
          "content-type": "application/json",
        },
        body: "{",
      }),
      request(validRequest, "Bearer user-jwt", "POST", "text/plain"),
      request({ ...validRequest, padding: "x".repeat(1024) }),
    ]
  ) {
    const response = await appAttestChallengeHandler(invalidRequest, {
      createUserClient: () => {
        throw new Error("invalid input must not authenticate");
      },
    });
    assertEquals(response.status, 400);
  }
});

Deno.test("challenge accepts only the exact canonical server response", async () => {
  const invalidResponses: unknown[] = [
    { ...validResponse, internal: "private" },
    { ...validResponse, version: 2 },
    { ...validResponse, challengeID: validResponse.challengeID.toUpperCase() },
    { ...validResponse, challenge: `${"A".repeat(42)}B=` },
    { ...validResponse, expiresAt: "not-a-timestamp" },
    { ...validResponse, proofKind: "unknown" },
  ];

  for (const data of invalidResponses) {
    const response = await appAttestChallengeHandler(request(), {
      createUserClient: () =>
        client(() => Promise.resolve({ data, error: null })),
    });
    assertEquals(response.status, 503);
    assertEquals(await response.json(), {
      error: {
        code: "temporarily_unavailable",
        message: "Unable to issue a challenge right now",
      },
    });
  }
});

Deno.test("challenge maps expected database failures without leaking details", async () => {
  const cases = [
    ["authentication_required", 401, "unauthorized"],
    ["active_profile_required", 403, "active_profile_required"],
    ["app_attest_installation_unavailable", 404, "installation_unavailable"],
    ["app_attest_rate_limited", 429, "rate_limited"],
    ["app_attest_challenge_limit", 429, "challenge_limit"],
    ["invalid_app_attest_challenge_request", 400, "invalid_request"],
    ["invalid_app_attest_digest", 400, "invalid_request"],
    ["secret_database_detail", 503, "temporarily_unavailable"],
  ] as const;

  for (const [message, status, code] of cases) {
    const response = await appAttestChallengeHandler(request(), {
      createUserClient: () =>
        client(() =>
          Promise.resolve({
            data: null,
            error: {
              message,
              code: "private-code",
              details: "private database details",
            },
          })
        ),
    });
    const serialized = JSON.stringify(await response.json());
    assertEquals(response.status, status);
    assertEquals(JSON.parse(serialized).error.code, code);
    assertEquals(serialized.includes("secret_database_detail"), false);
    assertEquals(serialized.includes("private"), false);
  }
});

Deno.test("challenge turns authentication and RPC outages into retryable responses", async () => {
  const authenticationFailure = await appAttestChallengeHandler(request(), {
    createUserClient: () => ({
      auth: {
        getUser: () => Promise.reject(new Error("auth network detail")),
      },
      rpc: () => Promise.reject(new Error("must not call RPC")),
    }),
  });
  assertEquals(authenticationFailure.status, 503);

  const rpcFailure = await appAttestChallengeHandler(request(), {
    createUserClient: () =>
      client(() => Promise.reject(new Error("database network detail"))),
  });
  assertEquals(rpcFailure.status, 503);
  assertEquals(
    JSON.stringify(await rpcFailure.json()).includes("network"),
    false,
  );
});
