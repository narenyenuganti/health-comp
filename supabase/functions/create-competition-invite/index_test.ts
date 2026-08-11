import { assertEquals, assertMatch } from "@std/assert";
import {
  createCompetitionInviteHandler,
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

Deno.test("create returns one base64url token and sends only its SHA-256 digest to the RPC", async () => {
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
  const randomBytes = new Uint8Array(
    Array.from({ length: 32 }, (_, index) => index),
  );

  const response = await createCompetitionInviteHandler(
    request({ timeZoneIdentifier: "America/Los_Angeles" }),
    {
      createUserClient: () => userClient,
      createServiceClient: () => serviceClient,
      randomBytes: () => randomBytes,
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
  assertEquals(
    calls[0].args.token_digest,
    "\\x" + Array.from(
      new Uint8Array(await crypto.subtle.digest("SHA-256", randomBytes)),
      (byte) => byte.toString(16).padStart(2, "0"),
    ).join(""),
  );
  assertEquals(JSON.stringify(calls).includes(payload.token), false);
  assertEquals(userRpcCalled, false);
});

Deno.test("create verifies the bearer user before calling the RPC", async () => {
  let rpcCalled = false;
  const response = await createCompetitionInviteHandler(
    request({ timeZoneIdentifier: "UTC" }, "Bearer invalid"),
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
      randomBytes: () => crypto.getRandomValues(new Uint8Array(32)),
    },
  );

  assertEquals(response.status, 401);
  assertEquals(await response.json(), {
    error: { code: "unauthorized", message: "Authentication required" },
  });
  assertEquals(rpcCalled, false);
});

Deno.test("create rejects malformed JSON and invalid request fields without allocating a token", async () => {
  let randomCalled = false;
  const client: InviteRpcClient = {
    auth: {
      getUser: () =>
        Promise.resolve({ data: { user: { id: "user-1" } }, error: null }),
    },
    rpc: () => Promise.resolve({ data: null, error: null }),
  };
  const invalidRequests = [
    request({ timeZoneIdentifier: "" }),
    request({ timeZoneIdentifier: "UTC", extra: true }),
    request({ timeZoneIdentifier: "UTC", rematchParentId: "not-a-uuid" }),
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
      randomBytes: () => {
        randomCalled = true;
        return encoder.encode("never allocate a token here").slice(0, 32);
      },
    });
    assertEquals(response.status, 400);
    assertEquals((await response.json()).error.code, "invalid_request");
  }
  assertEquals(randomCalled, false);
});

Deno.test("create returns typed database errors without exposing database details", async () => {
  const response = await createCompetitionInviteHandler(
    request({ timeZoneIdentifier: "Not/A_Time_Zone" }),
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
      randomBytes: () => new Uint8Array(32),
    },
  );

  assertEquals(response.status, 400);
  assertEquals(await response.json(), {
    error: { code: "invalid_time_zone", message: "Invalid time zone" },
  });
});
