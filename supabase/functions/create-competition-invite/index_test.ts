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

Deno.test("create requires a chosen existing recipient before issuing a private link", async () => {
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
            data: "20000000-0000-4000-8000-000000000001",
            error: null,
          }),
      }),
      deriveToken: () => Promise.resolve(new Uint8Array(32)),
    },
  );

  assertEquals(response.status, 400);
  assertEquals((await response.json()).error.code, "invalid_request");
});

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
      recipientProfileId: "42000000-0000-4000-8000-000000000002",
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
    calls[0].args.recipient_profile_id,
    "42000000-0000-4000-8000-000000000002",
  );
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

Deno.test("create from a challenge link sends its code, never an account id", async () => {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const client = (error: { message: string } | null): InviteRpcClient => ({
    auth: {
      getUser: () =>
        Promise.resolve({
          data: { user: { id: "41000000-0000-4000-8000-000000000001" } },
          error: null,
        }),
    },
    rpc: (name, args) => {
      calls.push({ name, args });
      return Promise.resolve(
        error
          ? { data: null, error }
          : { data: "20000000-0000-4000-8000-000000000001", error: null },
      );
    },
  });
  const body = {
    timeZoneIdentifier: "UTC",
    idempotencyKey: "84000000-0000-4000-8000-000000000001",
    challengeLinkCode: "Xb3kP9qL2mN8vR4tY6wZ1a",
  };
  const created = await createCompetitionInviteHandler(request(body), {
    createUserClient: () => client(null),
    createServiceClient: () => client(null),
    deriveToken: () => Promise.resolve(new Uint8Array(32)),
  });
  assertEquals(created.status, 201);
  assertEquals(calls.length, 1);
  assertEquals(calls[0].name, "create_competition_invite_from_link");
  assertEquals(Object.keys(calls[0].args).sort(), [
    "challenge_link_code",
    "creation_idempotency_key",
    "creator_auth_user_id",
    "creator_time_zone_identifier",
    "token_derivation_version",
    "token_digest",
  ]);
  assertEquals(calls[0].args.challenge_link_code, "Xb3kP9qL2mN8vR4tY6wZ1a");

  // A reset (or unknown) code reads like any unavailable recipient.
  const reset = await createCompetitionInviteHandler(request(body), {
    createUserClient: () => client(null),
    createServiceClient: () => client({ message: "recipient_unavailable" }),
    deriveToken: () => Promise.resolve(new Uint8Array(32)),
  });
  assertEquals(reset.status, 404);
  assertEquals((await reset.json()).error.code, "recipient_unavailable");
});

Deno.test("create verifies the bearer user before calling the RPC", async () => {
  let rpcCalled = false;
  const response = await createCompetitionInviteHandler(
    request({
      timeZoneIdentifier: "UTC",
      idempotencyKey: "84000000-0000-4000-8000-000000000001",
      recipientProfileId: "42000000-0000-4000-8000-000000000002",
    }, "Bearer invalid"),
    {
      createUserClient: () => ({
        auth: {
          getUser: () =>
            Promise.resolve({
              data: { user: null },
              error: { message: "bad jwt", status: 401 },
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
      recipientProfileId: "not-a-uuid",
    }),
    request({
      timeZoneIdentifier: "UTC",
      idempotencyKey: "84000000-0000-4000-8000-000000000001",
      recipientProfileId: "42000000-0000-4000-8000-000000000002",
      extra: true,
    }),
    request({
      timeZoneIdentifier: "UTC",
      idempotencyKey: "84000000-0000-4000-8000-000000000001",
      recipientProfileId: "42000000-0000-4000-8000-000000000002",
      rematchParentId: "not-a-uuid",
    }),
    request({
      timeZoneIdentifier: "UTC",
      idempotencyKey: "not-a-uuid",
      recipientProfileId: "42000000-0000-4000-8000-000000000002",
    }),
    request({
      timeZoneIdentifier: "UTC",
      idempotencyKey: "84000000-0000-4000-8000-000000000001",
      recipientProfileId: "42000000-0000-4000-8000-000000000002",
      challengeLinkCode: "Xb3kP9qL2mN8vR4tY6wZ1a",
    }),
    request({
      timeZoneIdentifier: "UTC",
      idempotencyKey: "84000000-0000-4000-8000-000000000001",
      challengeLinkCode: "Xb3kP9qL2mN8vR4tY6wZ1a",
      rematchParentId: "20000000-0000-4000-8000-000000000001",
    }),
    request({
      timeZoneIdentifier: "UTC",
      idempotencyKey: "84000000-0000-4000-8000-000000000001",
      challengeLinkCode: "short",
    }),
    request({
      timeZoneIdentifier: "UTC",
      idempotencyKey: "84000000-0000-4000-8000-000000000001",
      challengeLinkCode: null,
    }),
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
      recipientProfileId: "42000000-0000-4000-8000-000000000002",
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
      recipientProfileId: "42000000-0000-4000-8000-000000000002",
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

Deno.test("create reports pending, overlap, reciprocal and unavailable recipients safely", async () => {
  // Friend privacy refusals use the same opaque response on id and link paths.
  for (
    const recipient of [
      { recipientProfileId: "42000000-0000-4000-8000-000000000002" },
      { challengeLinkCode: "abcdefghijklmnopqrstuv" },
    ]
  ) {
    for (
      const [code, status, message] of [
        [
          "pending_invitation_exists",
          409,
          "An invitation to this account is already pending",
        ],
        [
          "active_match_exists",
          409,
          "A match with this account is in progress",
        ],
        [
          "incoming_challenge_exists",
          409,
          "This account already challenged you",
        ],
        ["recipient_unavailable", 404, "Recipient unavailable"],
        [
          "invite_rate_limited",
          429,
          "Too many challenges sent. Try again later.",
        ],
      ] as const
    ) {
      const response = await createCompetitionInviteHandler(
        request({
          timeZoneIdentifier: "UTC",
          idempotencyKey: "84000000-0000-4000-8000-000000000001",
          ...recipient,
        }),
        {
          createUserClient: () => ({
            auth: {
              getUser: () =>
                Promise.resolve({
                  data: {
                    user: { id: "41000000-0000-4000-8000-000000000001" },
                  },
                  error: null,
                }),
            },
            rpc: () => Promise.reject(new Error("not used")),
          }),
          createServiceClient: () => ({
            auth: { getUser: () => Promise.reject(new Error("not used")) },
            rpc: () =>
              Promise.resolve({
                data: null,
                error: {
                  message: code,
                  code: "P0001",
                  details: "private database detail",
                },
              }),
          }),
          deriveToken: () => Promise.resolve(new Uint8Array(32)),
        },
      );
      assertEquals(response.status, status);
      assertEquals(await response.json(), { error: { code, message } });
    }
  }
});
