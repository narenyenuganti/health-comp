import { assertEquals, assertMatch, assertNotEquals } from "@std/assert";
import {
  createCompetitionInviteHandler,
  deriveInviteTokenV1,
  type InviteRpcClient,
} from "./index.ts";

const encoder = new TextEncoder();

function request(body: unknown, authorization = "Bearer test-jwt"): Request {
  return new Request("http://localhost/create-competition-invite", {
    method: "POST",
    headers: {
      authorization,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

Deno.test("create deterministically derives one token and sends only its digest and recovery metadata to the RPC", async () => {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  let userRpcCalled = false;
  const userClient: InviteRpcClient = {
    auth: {
      getUser: () =>
        Promise.resolve({
          data: { user: { id: "41000000-0000-0000-0000-000000000001" } },
          error: null,
        }),
    },
    rpc: () => {
      userRpcCalled = true;
      return Promise.resolve({ data: null, error: null });
    },
  };
  const serviceClient: InviteRpcClient = {
    auth: {
      getUser: () =>
        Promise.reject(new Error("service client cannot verify users")),
    },
    rpc: (name, args) => {
      calls.push({ name, args });
      return Promise.resolve({
        data: "20000000-0000-0000-0000-000000000001",
        error: null,
      });
    },
  };
  const derivedBytes = new Uint8Array(
    Array.from({ length: 32 }, (_, index) => index),
  );
  const derivationCalls: Array<{ userId: string; idempotencyKey: string }> = [];
  const idempotencyKey = "84000000-0000-4000-8000-000000000001";

  const response = await createCompetitionInviteHandler(
    request({
      timeZoneIdentifier: "America/Los_Angeles",
      idempotencyKey,
    }),
    {
      createUserClient: () => userClient,
      createServiceClient: () => serviceClient,
      deriveToken: (userId, key) => {
        derivationCalls.push({ userId, idempotencyKey: key });
        return Promise.resolve(derivedBytes);
      },
    },
  );
  const payload = await response.json();

  assertEquals(response.status, 201);
  assertEquals(payload.competitionId, "20000000-0000-0000-0000-000000000001");
  assertMatch(payload.token, /^[A-Za-z0-9_-]{43}$/);
  assertEquals(calls.length, 1);
  assertEquals(calls[0].name, "create_competition_invite");
  assertEquals(
    calls[0].args.creator_time_zone_identifier,
    "America/Los_Angeles",
  );
  assertEquals(calls[0].args.rematch_parent_id, null);
  assertEquals(
    calls[0].args.creator_auth_user_id,
    "41000000-0000-0000-0000-000000000001",
  );
  assertEquals(calls[0].args.creation_idempotency_key, idempotencyKey);
  assertEquals(calls[0].args.token_derivation_version, 1);
  assertEquals(
    calls[0].args.token_digest,
    "\\x" + Array.from(
      new Uint8Array(await crypto.subtle.digest("SHA-256", derivedBytes)),
      (byte) => byte.toString(16).padStart(2, "0"),
    ).join(""),
  );
  assertEquals(derivationCalls, [{
    userId: "41000000-0000-0000-0000-000000000001",
    idempotencyKey,
  }]);
  assertEquals(JSON.stringify(calls).includes(payload.token), false);
  assertEquals(userRpcCalled, false);
});

Deno.test("create verifies the bearer user before calling the RPC", async () => {
  let rpcCalled = false;
  const response = await createCompetitionInviteHandler(
    request({
      timeZoneIdentifier: "UTC",
      idempotencyKey: "84000000-0000-4000-8000-000000000001",
    }, "Bearer invalid"),
    {
      createUserClient: () => ({
        auth: {
          getUser: () =>
            Promise.resolve({
              data: { user: null },
              error: { message: "bad jwt" },
            }),
        },
        rpc: () => {
          rpcCalled = true;
          return Promise.resolve({ data: null, error: null });
        },
      }),
      createServiceClient: () => {
        throw new Error(
          "service client must not be created before user verification",
        );
      },
      deriveToken: () => {
        throw new Error("must not derive before user verification");
      },
    },
  );

  assertEquals(response.status, 401);
  assertEquals(await response.json(), {
    error: { code: "unauthorized", message: "Authentication required" },
  });
  assertEquals(rpcCalled, false);
});

Deno.test("create rejects malformed JSON and invalid request fields without deriving a token", async () => {
  let derivationCalled = false;
  const client: InviteRpcClient = {
    auth: {
      getUser: () =>
        Promise.resolve({ data: { user: { id: "user-1" } }, error: null }),
    },
    rpc: () => Promise.resolve({ data: null, error: null }),
  };
  const invalidRequests = [
    request({ timeZoneIdentifier: "" }),
    request({
      timeZoneIdentifier: "UTC",
      idempotencyKey: "84000000-0000-4000-8000-000000000001",
      extra: true,
    }),
    request({
      timeZoneIdentifier: "UTC",
      idempotencyKey: "84000000-0000-4000-8000-000000000001",
      rematchParentId: "not-a-uuid",
    }),
    request({ timeZoneIdentifier: "UTC", idempotencyKey: "not-a-uuid" }),
    new Request("http://localhost/create-competition-invite", {
      method: "POST",
      headers: {
        authorization: "Bearer test-jwt",
        "content-type": "application/json",
      },
      body: "{",
    }),
  ];

  for (const invalidRequest of invalidRequests) {
    const response = await createCompetitionInviteHandler(invalidRequest, {
      createUserClient: () => client,
      createServiceClient: () => client,
      deriveToken: () => {
        derivationCalled = true;
        return Promise.resolve(
          encoder.encode("never derive a token here").slice(0, 32),
        );
      },
    });
    assertEquals(response.status, 400);
    assertEquals((await response.json()).error.code, "invalid_request");
  }
  assertEquals(derivationCalled, false);
});

Deno.test("V1 token derivation is deterministic and binds auth identity plus idempotency key", async () => {
  const secret = "local-test-derivation-secret-with-high-entropy";
  const userId = "41000000-0000-4000-8000-000000000001";
  const key = "84000000-0000-4000-8000-000000000001";
  const first = await deriveInviteTokenV1(userId, key, secret);
  const retry = await deriveInviteTokenV1(userId, key, secret);
  const otherUser = await deriveInviteTokenV1(
    "41000000-0000-4000-8000-000000000002",
    key,
    secret,
  );
  const otherKey = await deriveInviteTokenV1(
    userId,
    "84000000-0000-4000-8000-000000000002",
    secret,
  );

  assertEquals(first.length, 32);
  assertEquals(first, retry);
  assertNotEquals(first, otherUser);
  assertNotEquals(first, otherKey);
});

Deno.test("create returns typed database errors without exposing database details", async () => {
  const response = await createCompetitionInviteHandler(
    request({
      timeZoneIdentifier: "Not/A_Time_Zone",
      idempotencyKey: "84000000-0000-4000-8000-000000000001",
    }),
    {
      createUserClient: () => ({
        auth: {
          getUser: () =>
            Promise.resolve({ data: { user: { id: "user-1" } }, error: null }),
        },
        rpc: () =>
          Promise.resolve({
            data: null,
            error: {
              message: "invalid_time_zone",
              code: "22023",
              details: "private detail",
            },
          }),
      }),
      createServiceClient: () => ({
        auth: { getUser: () => Promise.reject(new Error("not used")) },
        rpc: () =>
          Promise.resolve({
            data: null,
            error: {
              message: "invalid_time_zone",
              code: "22023",
              details: "private detail",
            },
          }),
      }),
      deriveToken: () => Promise.resolve(new Uint8Array(32)),
    },
  );

  assertEquals(response.status, 400);
  assertEquals(await response.json(), {
    error: { code: "invalid_time_zone", message: "Invalid time zone" },
  });
});

Deno.test("create maps divergent idempotency reuse without database details", async () => {
  const response = await createCompetitionInviteHandler(
    request({
      timeZoneIdentifier: "UTC",
      idempotencyKey: "84000000-0000-4000-8000-000000000001",
    }),
    {
      createUserClient: () => ({
        auth: {
          getUser: () =>
            Promise.resolve({
              data: { user: { id: "41000000-0000-4000-8000-000000000001" } },
              error: null,
            }),
        },
        rpc: () => Promise.resolve({ data: null, error: null }),
      }),
      createServiceClient: () => ({
        auth: { getUser: () => Promise.reject(new Error("not used")) },
        rpc: () =>
          Promise.resolve({
            data: null,
            error: {
              message: "idempotency_conflict",
              code: "P0001",
              details: "private detail",
            },
          }),
      }),
      deriveToken: () => Promise.resolve(new Uint8Array(32)),
    },
  );

  assertEquals(response.status, 409);
  assertEquals(await response.json(), {
    error: {
      code: "idempotency_conflict",
      message: "Invitation request conflicts with an earlier request",
    },
  });
});
