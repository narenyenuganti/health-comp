// deno-lint-ignore-file require-await
import { assert, assertEquals, assertRejects } from "@std/assert";
import {
  AccountDeletionHTTPError,
  AppleClientSecretConfiguration,
  AppleTokenExchange,
  continueAccountDeletion,
  createAppleClientSecret,
  createAppleTokenClient,
  createLiveDependencies,
  DeleteAccountDependencies,
  deleteAccountHandler,
  DeletionProgress,
} from "./index.ts";

const authUserID = "d1000000-0000-4000-8000-000000000001";
const profileID = "d2000000-0000-4000-8000-000000000001";
const appleProviderID = "apple-delete-alice";
const clientID = "com.example.HealthComp";
const nonce = "a".repeat(64);
const fixedNow = new Date("2026-08-14T20:00:00Z");

function request(
  body: unknown = {
    authorization_code: "fresh-apple-authorization-code",
    nonce,
  },
  authorization = "Bearer authenticated-user-jwt",
  method = "POST",
): Request {
  return new Request("http://localhost/functions/v1/delete-account", {
    method,
    headers: {
      authorization,
      "content-type": "application/json",
    },
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });
}

function base64URL(value: string | Uint8Array): string {
  const bytes = typeof value === "string"
    ? new TextEncoder().encode(value)
    : value;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

function fakeAppleIDToken(
  overrides: Record<string, unknown> = {},
): string {
  const payload = {
    iss: "https://appleid.apple.com",
    aud: clientID,
    sub: appleProviderID,
    nonce,
    exp: Math.floor(fixedNow.getTime() / 1000) + 300,
    ...overrides,
  };
  return `${base64URL('{"alg":"ES256","kid":"test"}')}.${
    base64URL(JSON.stringify(payload))
  }.signature`;
}

function progress(
  phase: DeletionProgress["phase"],
  authUserId: string | null = authUserID,
): DeletionProgress {
  return {
    profileId: profileID,
    phase,
    appleProviderId: phase === "completed" ? null : appleProviderID,
    authUserId,
    appleClientId: phase === "prepared" ? null : clientID,
  };
}

function dependencies(
  overrides: Partial<DeleteAccountDependencies> = {},
): DeleteAccountDependencies {
  return {
    appleClientID: clientID,
    now: () => fixedNow,
    authenticate: async () => authUserID,
    begin: async () => progress("prepared"),
    exchangeAuthorizationCode: async () => ({
      refreshToken: "test-refresh-token-for-account-deletion",
      idToken: fakeAppleIDToken(),
    }),
    storeAppleToken: async () => progress("token_ready"),
    loadAppleToken: async () => "test-refresh-token-for-account-deletion",
    revokeAppleToken: async () => {},
    markAppleRevoked: async () => progress("apple_revoked"),
    anonymize: async () => progress("auth_delete_pending"),
    deleteAuthUser: async () => {},
    complete: async () => progress("completed", null),
    ...overrides,
  };
}

Deno.test("delete account requires POST and a verified bearer session", async () => {
  const wrongMethod = await deleteAccountHandler(
    request(undefined, "Bearer jwt", "GET"),
    dependencies(),
  );
  assertEquals(wrongMethod.status, 405);

  for (const authorization of ["", "Basic credential", "Bearer "]) {
    const response = await deleteAccountHandler(
      request(undefined, authorization),
      dependencies(),
    );
    assertEquals(response.status, 401);
    assertEquals(await response.json(), { error: "authentication_required" });
  }
});

Deno.test("live dependencies do not require Apple secrets before authentication", async () => {
  const environmentReads: string[] = [];
  const live = createLiveDependencies({
    environment: (name) => {
      environmentReads.push(name);
      switch (name) {
        case "SUPABASE_URL":
          return "https://example.supabase.co";
        case "SUPABASE_ANON_KEY":
          return "test-anon-key";
        case "SUPABASE_SERVICE_ROLE_KEY":
          return "test-service-role-key";
        default:
          throw new Error(`unexpected pre-authentication read: ${name}`);
      }
    },
    fetch: (async () => {
      throw new Error("network must not be used before authentication");
    }) as typeof fetch,
  });

  const response = await deleteAccountHandler(
    request(undefined, ""),
    live,
  );

  assertEquals(response.status, 401);
  assertEquals(await response.json(), { error: "authentication_required" });
  assertEquals(environmentReads, [
    "SUPABASE_URL",
    "SUPABASE_ANON_KEY",
    "SUPABASE_SERVICE_ROLE_KEY",
  ]);
});

Deno.test("live deletion adapters route Auth and RPC through the configured fetch", async () => {
  const paths: string[] = [];
  const live = createLiveDependencies({
    environment: (name) => ({
      SUPABASE_URL: "https://example.invalid",
      SUPABASE_ANON_KEY: "synthetic-anon",
      SUPABASE_SERVICE_ROLE_KEY: "synthetic-service",
    }[name] ?? ""),
    fetch: (input, init) => {
      const req = new Request(input, init);
      paths.push(new URL(req.url).pathname);
      if (paths.length === 1) {
        return Promise.resolve(Response.json({ id: authUserID }));
      }
      return Promise.resolve(
        Response.json({
          profile_id: profileID,
          phase: "prepared",
          auth_user_id: authUserID,
          apple_provider_id: appleProviderID,
          apple_client_id: null,
        }),
      );
    },
  });
  assertEquals(await live.authenticate("Bearer synthetic-user"), authUserID);
  assertEquals((await live.begin(authUserID)).phase, "prepared");
  assertEquals(paths, ["/auth/v1/user", "/rest/v1/rpc/begin_account_deletion"]);
});

Deno.test("delete account rejects malformed or expansive reauthentication input", async () => {
  for (
    const body of [
      null,
      {},
      { authorization_code: "short", nonce },
      {
        authorization_code: "fresh-apple-authorization-code",
        nonce: "not-a-sha256-challenge",
      },
      {
        authorization_code: "fresh-apple-authorization-code",
        nonce,
        unexpected: true,
      },
    ]
  ) {
    const response = await deleteAccountHandler(request(body), dependencies());
    assertEquals(response.status, 400);
    assertEquals(await response.json(), { error: "invalid_request" });
  }
});

Deno.test("delete account executes durable phases in order", async () => {
  const calls: string[] = [];
  const response = await deleteAccountHandler(
    request(),
    dependencies({
      authenticate: async () => {
        calls.push("authenticate");
        return authUserID;
      },
      begin: async (userId) => {
        assertEquals(userId, authUserID);
        calls.push("begin");
        return progress("prepared");
      },
      exchangeAuthorizationCode: async (code) => {
        assertEquals(code, "fresh-apple-authorization-code");
        calls.push("exchange");
        return {
          refreshToken: "test-refresh-token-for-account-deletion",
          idToken: fakeAppleIDToken(),
        };
      },
      storeAppleToken: async (receivedProfileID, token) => {
        assertEquals(receivedProfileID, profileID);
        assertEquals(token, "test-refresh-token-for-account-deletion");
        calls.push("store-token");
        return progress("token_ready");
      },
      loadAppleToken: async () => {
        calls.push("load-token");
        return "test-refresh-token-for-account-deletion";
      },
      revokeAppleToken: async (token) => {
        assertEquals(token, "test-refresh-token-for-account-deletion");
        calls.push("revoke-apple");
      },
      markAppleRevoked: async () => {
        calls.push("mark-apple-revoked");
        return progress("apple_revoked");
      },
      anonymize: async () => {
        calls.push("anonymize");
        return progress("auth_delete_pending");
      },
      deleteAuthUser: async (userId) => {
        assertEquals(userId, authUserID);
        calls.push("delete-auth-user");
      },
      complete: async () => {
        calls.push("complete");
        return progress("completed", null);
      },
    }),
  );

  assertEquals(response.status, 200);
  assertEquals(await response.json(), { status: "deleted" });
  assertEquals(calls, [
    "authenticate",
    "begin",
    "exchange",
    "store-token",
    "load-token",
    "revoke-apple",
    "mark-apple-revoked",
    "anonymize",
    "delete-auth-user",
    "complete",
  ]);
});

Deno.test("Apple token identity is bound to provider, client, nonce, and lifetime", async () => {
  for (
    const overrides of [
      { sub: "another-apple-user" },
      { aud: "com.example.Other" },
      { nonce: "b".repeat(64) },
      { iss: "https://attacker.invalid" },
      { exp: Math.floor(fixedNow.getTime() / 1000) - 1 },
    ]
  ) {
    let stored = false;
    const response = await deleteAccountHandler(
      request(),
      dependencies({
        exchangeAuthorizationCode: async () => ({
          refreshToken: "test-refresh-token-for-account-deletion",
          idToken: fakeAppleIDToken(overrides),
        }),
        storeAppleToken: async () => {
          stored = true;
          return progress("token_ready");
        },
      }),
    );
    assertEquals(response.status, 403);
    assertEquals(await response.json(), { error: "apple_identity_mismatch" });
    assertEquals(stored, false);
  }
});

Deno.test("deletion persists the exchanging client identity with its token", async () => {
  let storedArguments: unknown[] = [];
  const response = await deleteAccountHandler(
    request(),
    dependencies({
      storeAppleToken: async (...args) => {
        storedArguments = args;
        return { ...progress("token_ready"), appleClientId: clientID };
      },
    }),
  );
  assertEquals(response.status, 200);
  assertEquals(storedArguments, [
    profileID,
    "test-refresh-token-for-account-deletion",
    clientID,
  ]);
});

Deno.test("deletion retry uses persisted client identity instead of current exchange client", async () => {
  let revokedArguments: unknown[] = [];
  const storedClientID = "com.example.HealthComp.staging.web";
  const response = await deleteAccountHandler(
    request(),
    dependencies({
      begin: async () => ({
        ...progress("token_ready"),
        appleClientId: storedClientID,
      }),
      revokeAppleToken: async (...args) => {
        revokedArguments = args;
      },
    }),
  );
  assertEquals(response.status, 200);
  assertEquals(revokedArguments, [
    "test-refresh-token-for-account-deletion",
    storedClientID,
  ]);
});

Deno.test("deletion refuses unbound legacy token without loading or revoking it", async () => {
  let tokenCalls = 0;
  const response = await deleteAccountHandler(
    request(),
    dependencies({
      begin: async () => ({ ...progress("token_ready"), appleClientId: null }),
      loadAppleToken: async () => {
        tokenCalls++;
        return "legacy-refresh-token";
      },
      revokeAppleToken: async () => {
        tokenCalls++;
      },
    }),
  );
  assertEquals(response.status, 503);
  assertEquals(tokenCalls, 0);
});

Deno.test("shared deletion workflow resumes durable token without requesting another grant", async () => {
  let grantCalls = 0;
  const response = await continueAccountDeletion(
    authUserID,
    dependencies({
      begin: async () => progress("token_ready"),
    }),
    async () => {
      grantCalls++;
      throw new Error("consumed grant must not be replayed");
    },
  );
  assertEquals(response.status, 200);
  assertEquals(grantCalls, 0);
});

Deno.test("shared deletion workflow validates and stores the supplied web grant binding", async () => {
  const webClient = "com.example.staging.web";
  const webNonce = "e".repeat(64);
  const stored: unknown[][] = [];
  const response = await continueAccountDeletion(
    authUserID,
    dependencies({
      exchangeAuthorizationCode: async () => {
        throw new Error("native exchange must not run");
      },
      storeAppleToken: async (...args) => {
        stored.push(args);
        return { ...progress("token_ready"), appleClientId: webClient };
      },
    }),
    async () => ({
      clientID: webClient,
      nonce: webNonce,
      tokens: {
        refreshToken: "synthetic-web-refresh-token",
        idToken: fakeAppleIDToken({ aud: webClient, nonce: webNonce }),
      },
    }),
  );
  assertEquals(response.status, 200);
  assertEquals(stored, [[profileID, "synthetic-web-refresh-token", webClient]]);
});

Deno.test("token-ready retry resumes without exchanging the single-use code", async () => {
  const calls: string[] = [];
  const response = await deleteAccountHandler(
    request(),
    dependencies({
      begin: async () => progress("token_ready"),
      exchangeAuthorizationCode: async () => {
        throw new Error("single-use code must not be replayed");
      },
      loadAppleToken: async () => {
        calls.push("load");
        return "persisted-refresh-token";
      },
      revokeAppleToken: async (token) => {
        calls.push(`revoke:${token}`);
      },
      markAppleRevoked: async () => {
        calls.push("mark");
        return progress("apple_revoked");
      },
      anonymize: async () => {
        calls.push("anonymize");
        return progress("auth_delete_pending");
      },
      deleteAuthUser: async () => {
        calls.push("delete-user");
      },
      complete: async () => {
        calls.push("complete");
        return progress("completed", null);
      },
    }),
  );

  assertEquals(response.status, 200);
  assertEquals(calls, [
    "load",
    "revoke:persisted-refresh-token",
    "mark",
    "anonymize",
    "delete-user",
    "complete",
  ]);
});

Deno.test("Apple revocation failure preserves the resumable token phase", async () => {
  let marked = false;
  const response = await deleteAccountHandler(
    request(),
    dependencies({
      begin: async () => progress("token_ready"),
      revokeAppleToken: async () => {
        throw new AccountDeletionHTTPError(
          503,
          "apple_revocation_retryable",
        );
      },
      markAppleRevoked: async () => {
        marked = true;
        return progress("apple_revoked");
      },
    }),
  );

  assertEquals(response.status, 503);
  assertEquals(await response.json(), { error: "apple_revocation_retryable" });
  assertEquals(marked, false);
});

Deno.test("lost auth-delete response succeeds only when durable completion confirms it", async () => {
  const recovered = await deleteAccountHandler(
    request(),
    dependencies({
      begin: async () => progress("auth_delete_pending"),
      deleteAuthUser: async () => {
        throw new Error("connection reset after commit");
      },
      complete: async () => progress("completed", null),
    }),
  );
  assertEquals(recovered.status, 200);

  const notCommitted = await deleteAccountHandler(
    request(),
    dependencies({
      begin: async () => progress("auth_delete_pending"),
      deleteAuthUser: async () => {
        throw new Error("connection reset before commit");
      },
      complete: async () => {
        throw new Error("auth user still exists");
      },
    }),
  );
  assertEquals(notCommitted.status, 503);
  assertEquals(await notCommitted.json(), {
    error: "account_deletion_retryable",
  });
});

Deno.test("completed deletion is idempotent and performs no external work", async () => {
  let externalCalls = 0;
  const response = await deleteAccountHandler(
    request(),
    dependencies({
      begin: async () => progress("completed", null),
      exchangeAuthorizationCode: async () => {
        externalCalls += 1;
        throw new Error("unexpected");
      },
      revokeAppleToken: async () => {
        externalCalls += 1;
      },
      deleteAuthUser: async () => {
        externalCalls += 1;
      },
    }),
  );
  assertEquals(response.status, 200);
  assertEquals(externalCalls, 0);
});

Deno.test("Apple token client validates exchange and successful revocation requests", async () => {
  const requests: Request[] = [];
  const responses = [
    new Response(
      JSON.stringify({
        refresh_token: "returned-refresh-token",
        id_token: fakeAppleIDToken(),
        access_token: "returned-access-token",
        token_type: "Bearer",
        expires_in: 3600,
      }),
      { status: 200, headers: { "content-type": "application/json" } },
    ),
    // Apple also uses 200 when the supplied token is already invalid.
    new Response(null, { status: 200 }),
  ];
  const tokenClient = createAppleTokenClient({
    clientID,
    clientSecret: async () => "signed-client-secret",
    fetch: async (input, init) => {
      requests.push(new Request(input, init));
      return responses.shift()!;
    },
  });

  const exchange = await tokenClient.exchangeAuthorizationCode(
    "fresh-apple-authorization-code",
  );
  assertEquals(exchange.refreshToken, "returned-refresh-token");
  await tokenClient.revoke("returned-refresh-token");

  assertEquals(requests.map((value) => value.url), [
    "https://appleid.apple.com/auth/token",
    "https://appleid.apple.com/auth/revoke",
  ]);
  assertEquals(
    new URLSearchParams(await requests[0].text()).get("redirect_uri"),
    null,
  );
  assertEquals(
    new URLSearchParams(await requests[1].text()).get("token_type_hint"),
    "refresh_token",
  );
});

Deno.test("Apple web token exchange carries its configured return URI only to token exchange", async () => {
  const requests: Request[] = [];
  const configuration = {
    clientID: "com.example.HealthComp.staging.web",
    redirectURI:
      "https://staging.example.invalid/functions/v1/apple-deletion-callback",
    clientSecret: async () => "signed-web-client-secret",
    fetch: async (input: RequestInfo | URL, init?: RequestInit) => {
      requests.push(new Request(input, init));
      return requests.length === 1
        ? Response.json({
          refresh_token: "returned-web-refresh-token",
          id_token: fakeAppleIDToken(),
        })
        : new Response(null, { status: 200 });
    },
  };
  const tokenClient = createAppleTokenClient(configuration);
  const exchange = await tokenClient.exchangeAuthorizationCode(
    "fresh-web-code",
  );
  await tokenClient.revoke(exchange.refreshToken);

  const tokenBody = new URLSearchParams(await requests[0].text());
  assertEquals(tokenBody.get("redirect_uri"), configuration.redirectURI);
  assertEquals(tokenBody.get("client_id"), configuration.clientID);
  assertEquals(tokenBody.get("client_secret"), "signed-web-client-secret");
  assertEquals(tokenBody.get("code"), "fresh-web-code");
  const revokeBody = new URLSearchParams(await requests[1].text());
  assertEquals(revokeBody.get("redirect_uri"), null);
  assertEquals(revokeBody.get("client_id"), configuration.clientID);
  assertEquals(revokeBody.get("token"), "returned-web-refresh-token");
});

Deno.test("Apple token client treats unsuccessful revocation as retryable", async () => {
  const tokenClient = createAppleTokenClient({
    clientID,
    clientSecret: async () => "signed-client-secret",
    fetch: async () => new Response(null, { status: 503 }),
  });

  await assertRejects(
    () => tokenClient.revoke("returned-refresh-token"),
    AccountDeletionHTTPError,
    "apple_revocation_retryable",
  );
});

Deno.test("Apple authorization-code rejection requires fresh reauthentication", async () => {
  const tokenClient = createAppleTokenClient({
    clientID,
    clientSecret: async () => "signed-client-secret",
    fetch: async () =>
      new Response(
        JSON.stringify({ error: "invalid_grant" }),
        { status: 400, headers: { "content-type": "application/json" } },
      ),
  });

  await assertRejects(
    () => tokenClient.exchangeAuthorizationCode("used-code"),
    AccountDeletionHTTPError,
    "reauthentication_required",
  );
});

function pem(bytes: ArrayBuffer): string {
  const encoded = base64URL(new Uint8Array(bytes))
    .replaceAll("-", "+")
    .replaceAll("_", "/");
  const padded = encoded + "=".repeat((4 - encoded.length % 4) % 4);
  const lines = padded.match(/.{1,64}/g) ?? [];
  return [
    "-----BEGIN PRIVATE KEY-----",
    ...lines,
    "-----END PRIVATE KEY-----",
  ].join("\n");
}

function decodeBase64URL(value: string): ArrayBuffer {
  const base64 = value.replaceAll("-", "+").replaceAll("_", "/") +
    "=".repeat((4 - value.length % 4) % 4);
  return Uint8Array.from(
    atob(base64),
    (character) => character.charCodeAt(0),
  ).buffer;
}

Deno.test("Apple client secret is a short-lived ES256 JWT and accepts escaped PEM newlines", async () => {
  const keyPair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const privateKey = await crypto.subtle.exportKey("pkcs8", keyPair.privateKey);
  const configuration: AppleClientSecretConfiguration = {
    keyID: "KEY1234567",
    teamID: "TEAM123456",
    clientID,
    privateKeyPEM: pem(privateKey).replaceAll("\n", "\\n"),
  };

  const token = await createAppleClientSecret(configuration, fixedNow);
  const parts = token.split(".");
  assertEquals(parts.length, 3);
  assertEquals(
    JSON.parse(new TextDecoder().decode(decodeBase64URL(parts[0]))),
    { alg: "ES256", kid: "KEY1234567", typ: "JWT" },
  );
  const claims = JSON.parse(
    new TextDecoder().decode(decodeBase64URL(parts[1])),
  );
  assertEquals(claims.iss, "TEAM123456");
  assertEquals(claims.sub, clientID);
  assertEquals(claims.aud, "https://appleid.apple.com");
  assertEquals(claims.exp - claims.iat, 300);
  assert(
    await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      keyPair.publicKey,
      decodeBase64URL(parts[2]),
      new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
    ),
  );
});

Deno.test("Apple token response shape cannot omit the refresh or identity token", async () => {
  for (
    const payload of [
      { id_token: fakeAppleIDToken() },
      { refresh_token: "returned-refresh-token" },
    ]
  ) {
    const tokenClient = createAppleTokenClient({
      clientID,
      clientSecret: async () => "signed-client-secret",
      fetch: async () =>
        new Response(
          JSON.stringify(payload),
          { status: 200, headers: { "content-type": "application/json" } },
        ),
    });
    await assertRejects(
      () => tokenClient.exchangeAuthorizationCode("fresh-code"),
      AccountDeletionHTTPError,
      "apple_contract_mismatch",
    );
  }
});

const _compileTimeExchangeShape: AppleTokenExchange = {
  refreshToken: "test",
  idToken: "test",
};
void _compileTimeExchangeShape;
