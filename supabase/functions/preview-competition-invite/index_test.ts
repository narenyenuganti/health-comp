import { assertEquals } from "@std/assert";
import {
  type InviteRpcClient,
  previewCompetitionInviteHandler,
} from "./index.ts";

const token = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";

function request(body: unknown, authorization = "Bearer test-jwt"): Request {
  return new Request("http://localhost/preview-competition-invite", {
    method: "POST",
    headers: { authorization, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

function client(
  result: { data: unknown; error: { message: string; code?: string } | null },
  onRpc: (name: string, args: Record<string, unknown>) => void = () => {},
): InviteRpcClient {
  return {
    auth: {
      getUser: () =>
        Promise.resolve({ data: { user: { id: "user-2" } }, error: null }),
    },
    rpc: (name, args) => {
      onRpc(name, args);
      return Promise.resolve(result as { data: string | null; error: null });
    },
  };
}

Deno.test("preview sends only the token digest and returns exact camelCase keys", async () => {
  let rpcName: string | undefined;
  let rpcArgs: Record<string, unknown> | undefined;
  const response = await previewCompetitionInviteHandler(request({ token }), {
    createUserClient: () =>
      client({
        data: {
          competition_id: "20000000-0000-4000-8000-000000000001",
          state: "pending",
          sender: {
            id: "30000000-0000-4000-8000-000000000001",
            display_name: "Naren",
          },
          time_zone_identifier: "America/Los_Angeles",
          expires_at: "2026-11-01T21:14:00+00:00",
        },
        error: null,
      }, (name, args) => {
        rpcName = name;
        rpcArgs = args;
      }),
  });

  assertEquals(response.status, 200);
  const text = await response.text();
  assertEquals(JSON.parse(text), {
    competitionId: "20000000-0000-4000-8000-000000000001",
    state: "pending",
    sender: {
      id: "30000000-0000-4000-8000-000000000001",
      displayName: "Naren",
    },
    timeZoneIdentifier: "America/Los_Angeles",
    expiresAt: "2026-11-01T21:14:00+00:00",
  });
  assertEquals(text.includes(token), false);
  assertEquals(rpcName, "preview_competition_invite");
  assertEquals(rpcArgs, {
    token_digest:
      "\\x630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd",
  });
  assertEquals(JSON.stringify(rpcArgs).includes(token), false);
});

Deno.test("preview rejects other methods and malformed bodies before authentication", async () => {
  const methodResponse = await previewCompetitionInviteHandler(
    new Request("http://localhost/preview-competition-invite"),
    {
      createUserClient: () => {
        throw new Error("must not create client");
      },
    },
  );
  assertEquals(methodResponse.status, 405);

  for (
    const body of [
      null,
      {},
      { token: "a".repeat(42) },
      { token, extra: true },
      { token: 1 },
    ]
  ) {
    const response = await previewCompetitionInviteHandler(request(body), {
      createUserClient: () => {
        throw new Error("must not create client");
      },
    });
    assertEquals(response.status, 400);
    assertEquals(await response.json(), {
      error: { code: "invalid_request", message: "Invalid invitation token" },
    });
  }
});

Deno.test("preview requires a verified bearer user", async () => {
  let rpcCalled = false;
  const response = await previewCompetitionInviteHandler(
    request({ token }, "Bearer invalid"),
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
    },
  );
  assertEquals(response.status, 401);
  assertEquals(rpcCalled, false);
});

Deno.test("preview maps database errors without details", async () => {
  for (
    const [message, code, status, body] of [
      ["cannot_claim_own_invite", "P0001", 409, {
        code: "self_claim_forbidden",
        message: "You cannot claim your own invitation",
      }],
      ["active_match_exists", "P0001", 409, {
        code: "active_match_exists",
        message: "A match with this account is in progress",
      }],
      ["authentication_required", "42501", 401, {
        code: "unauthorized",
        message: "Authentication required",
      }],
      ["invite_unavailable", "P0001", 404, {
        code: "invite_unavailable",
        message: "Invitation unavailable",
      }],
      ["anything_else", "P0001", 404, {
        code: "invite_unavailable",
        message: "Invitation unavailable",
      }],
      ["database connection timeout", "08006", 503, {
        code: "temporarily_unavailable",
        message: "Unable to open invitation right now",
      }],
    ] as const
  ) {
    const response = await previewCompetitionInviteHandler(
      request({ token }),
      {
        createUserClient: () =>
          client({ data: null, error: { message, code } }),
      },
    );
    assertEquals(response.status, status);
    assertEquals(await response.json(), { error: body });
  }
});

Deno.test("preview treats a malformed RPC result as retryable", async () => {
  const response = await previewCompetitionInviteHandler(request({ token }), {
    createUserClient: () =>
      client({ data: { competition_id: "x", state: "other" }, error: null }),
  });
  assertEquals(response.status, 503);
});
