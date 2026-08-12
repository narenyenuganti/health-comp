import { assertEquals } from "@std/assert";
import {
  claimCompetitionInviteHandler,
  type InviteRpcClient,
} from "./index.ts";

function request(token: unknown, authorization = "Bearer test-jwt"): Request {
  return new Request("http://localhost/claim-competition-invite", {
    method: "POST",
    headers: { authorization, "content-type": "application/json" },
    body: JSON.stringify({ token }),
  });
}

Deno.test("claim hashes a valid token and sends only its digest to the RPC", async () => {
  const token = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
  let rpcArgs: Record<string, unknown> | undefined;
  const client: InviteRpcClient = {
    auth: {
      getUser: () =>
        Promise.resolve({ data: { user: { id: "user-2" } }, error: null }),
    },
    rpc: (_name, args) => {
      rpcArgs = args;
      return Promise.resolve({
        data: "20000000-0000-0000-0000-000000000001",
        error: null,
      });
    },
  };

  const response = await claimCompetitionInviteHandler(request(token), {
    createUserClient: () => client,
  });

  assertEquals(response.status, 200);
  assertEquals(await response.json(), {
    competitionId: "20000000-0000-0000-0000-000000000001",
  });
  assertEquals(rpcArgs, {
    token_digest:
      "\\x630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd",
  });
  assertEquals(JSON.stringify(rpcArgs).includes(token), false);
});

Deno.test("claim rejects malformed tokens before authentication or RPC", async () => {
  let clientCreated = false;
  for (
    const token of [
      null,
      "",
      "abc=",
      "not+base64url",
      "a".repeat(42),
      "a".repeat(44),
    ]
  ) {
    const response = await claimCompetitionInviteHandler(request(token), {
      createUserClient: () => {
        clientCreated = true;
        throw new Error("must not create client");
      },
    });
    assertEquals(response.status, 400);
    assertEquals(await response.json(), {
      error: { code: "invalid_request", message: "Invalid invitation token" },
    });
  }
  assertEquals(clientCreated, false);
});

Deno.test("claim verifies the bearer user before calling the RPC", async () => {
  let rpcCalled = false;
  const response = await claimCompetitionInviteHandler(
    request("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8", "Bearer invalid"),
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
    },
  );

  assertEquals(response.status, 401);
  assertEquals(rpcCalled, false);
});

Deno.test("claim maps unknown expired and consumed invitations to one privacy-safe error", async () => {
  for (
    const databaseMessage of [
      "unknown",
      "expired",
      "consumed",
      "invite_unavailable",
    ]
  ) {
    const response = await claimCompetitionInviteHandler(
      request("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"),
      {
        createUserClient: () => ({
          auth: {
            getUser: () =>
              Promise.resolve({
                data: { user: { id: "user-2" } },
                error: null,
              }),
          },
          rpc: () =>
            Promise.resolve({
              data: null,
              error: { message: databaseMessage, code: "P0001" },
            }),
        }),
      },
    );
    assertEquals(response.status, 404);
    assertEquals(await response.json(), {
      error: { code: "invite_unavailable", message: "Invitation unavailable" },
    });
  }
});

Deno.test("claim reports self-claim distinctly without database details", async () => {
  const response = await claimCompetitionInviteHandler(
    request("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"),
    {
      createUserClient: () => ({
        auth: {
          getUser: () =>
            Promise.resolve({ data: { user: { id: "user-1" } }, error: null }),
        },
        rpc: () =>
          Promise.resolve({
            data: null,
            error: { message: "cannot_claim_own_invite", code: "P0001" },
          }),
      }),
    },
  );
  assertEquals(response.status, 409);
  assertEquals(await response.json(), {
    error: {
      code: "self_claim_forbidden",
      message: "You cannot claim your own invitation",
    },
  });
});

Deno.test("claim keeps unexpected database failures retryable", async () => {
  const response = await claimCompetitionInviteHandler(
    request("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"),
    {
      createUserClient: () => ({
        auth: {
          getUser: () =>
            Promise.resolve({ data: { user: { id: "user-2" } }, error: null }),
        },
        rpc: () =>
          Promise.resolve({
            data: null,
            error: { message: "database connection timeout", code: "08006" },
          }),
      }),
    },
  );

  assertEquals(response.status, 503);
  assertEquals(await response.json(), {
    error: {
      code: "temporarily_unavailable",
      message: "Unable to claim invitation right now",
    },
  });
});

// This test is enabled in the verification command after the local functions are
// served with their default platform JWT verification. It intentionally uses
// real Auth-issued access tokens, races an exact create retry, and then races two
// different authenticated claimants.
Deno.test({
  name:
    "local JWT integration recovers concurrent create and permits exactly one concurrent claimant",
  ignore: Deno.env.get("HEALTHCOMP_RUN_INVITE_INTEGRATION") !== "1",
  fn: async () => {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const databaseUrl = Deno.env.get("HEALTHCOMP_TEST_DATABASE_URL")!;
    const localHosts = new Set(["127.0.0.1", "localhost", "::1"]);
    if (
      !localHosts.has(new URL(supabaseUrl).hostname) ||
      !localHosts.has(new URL(databaseUrl).hostname)
    ) {
      throw new Error(
        "Invitation integration test requires the disposable local Supabase stack",
      );
    }
    const [{ createClient }, postgresModule] = await Promise.all([
      import("@supabase/supabase-js"),
      import("postgres"),
    ]);
    const sql = postgresModule.default(databaseUrl, { max: 1 });
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false },
    });
    const suffix = crypto.randomUUID();
    const password = `HealthComp-${crypto.randomUUID()}`;
    const users: Array<{ id: string; jwt: string }> = [];

    try {
      for (const name of ["creator", "claimant-a", "claimant-b"]) {
        const email = `${name}-${suffix}@example.invalid`;
        const { data, error } = await admin.auth.admin.createUser({
          email,
          password,
          email_confirm: true,
        });
        if (error || !data.user) {
          throw error ?? new Error("user creation failed");
        }
        await sql`insert into public.profiles (auth_user_id, display_name, state)
                values (${data.user.id}::uuid, ${name}, 'active')`;
        const userClient = createClient(supabaseUrl, anonKey, {
          auth: { persistSession: false },
        });
        const { data: sessionData, error: sessionError } = await userClient.auth
          .signInWithPassword({ email, password });
        if (sessionError || !sessionData.session) {
          throw sessionError ?? new Error("sign in failed");
        }
        users.push({ id: data.user.id, jwt: sessionData.session.access_token });
      }

      const idempotencyKey = crypto.randomUUID();
      const createRequest = () =>
        fetch(`${supabaseUrl}/functions/v1/create-competition-invite`, {
          method: "POST",
          headers: {
            authorization: `Bearer ${users[0].jwt}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            timeZoneIdentifier: "Pacific/Kiritimati",
            idempotencyKey,
          }),
        });
      const createResponses = await Promise.all([
        createRequest(),
        createRequest(),
      ]);
      assertEquals(
        createResponses.map((response) => response.status),
        [201, 201],
      );
      const invitations = await Promise.all(
        createResponses.map((response) => response.json()),
      );
      assertEquals(invitations[0], invitations[1]);
      const invitation = invitations[0];

      const divergentResponse = await fetch(
        `${supabaseUrl}/functions/v1/create-competition-invite`,
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${users[0].jwt}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            timeZoneIdentifier: "UTC",
            idempotencyKey,
          }),
        },
      );
      assertEquals(divergentResponse.status, 409);
      assertEquals(await divergentResponse.json(), {
        error: {
          code: "idempotency_conflict",
          message: "Invitation request conflicts with an earlier request",
        },
      });

      const [creationState] = await sql`
        select count(*)::int as competition_count,
               min(invite_token_derivation_version)::int as derivation_version
        from public.competitions
        where creator_profile_id = (
          select id from public.profiles where auth_user_id = ${users[0].id}::uuid
        ) and invite_creation_idempotency_key = ${idempotencyKey}::uuid`;
      assertEquals(creationState.competition_count, 1);
      assertEquals(creationState.derivation_version, 1);

      const claimResponses = await Promise.all(
        users.slice(1).map((user) =>
          fetch(`${supabaseUrl}/functions/v1/claim-competition-invite`, {
            method: "POST",
            headers: {
              authorization: `Bearer ${user.jwt}`,
              "content-type": "application/json",
            },
            body: JSON.stringify({ token: invitation.token }),
          })
        ),
      );
      assertEquals(claimResponses.map((response) => response.status).sort(), [
        200,
        404,
      ]);

      const [competition] = await sql`
        select lifecycle, time_zone_identifier,
               start_day = ((pg_catalog.now() at time zone 'Pacific/Kiritimati')::date + 1) as next_local_day,
               (select count(*)::int from public.competition_participants p
                where p.competition_id = c.id and p.role = 'invitee' and p.state = 'accepted') as invitees
        from public.competitions c where id = ${invitation.competitionId}::uuid`;
      assertEquals(competition.lifecycle, "scheduled");
      assertEquals(competition.time_zone_identifier, "Pacific/Kiritimati");
      assertEquals(competition.next_local_day, true);
      assertEquals(competition.invitees, 1);
    } finally {
      await sql.end();
      // The test targets only the explicit local disposable database. The
      // verification workflow resets it before any subsequent SQL suite.
    }
  },
});
