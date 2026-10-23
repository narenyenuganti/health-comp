import { assertEquals } from "@std/assert";
import { randomBytes } from "node:crypto";
import postgres from "postgres";

Deno.test({
  name:
    "recipient-bound invitation operations serialize duplicate creates and reject other claimants",
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    // Repeat without resetting: retained synthetic history must not collide.
    for (let attempt = 0; attempt < 2; attempt++) {
      const databaseURL = Deno.env.get("HEALTHCOMP_TEST_DATABASE_URL") ??
        "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
      if (
        !["127.0.0.1", "localhost", "::1"].includes(
          new URL(databaseURL).hostname,
        )
      ) {
        throw new Error("invitation race requires disposable local database");
      }
      const sql = postgres(databaseURL, { max: 8 });
      const users = Array.from({ length: 3 }, () => ({
        user: crypto.randomUUID(),
        profile: crypto.randomUUID(),
      }));
      try {
        for (const { user, profile } of users) {
          await sql`insert into auth.users(id,instance_id,aud,role,email,encrypted_password,created_at,updated_at)
          values(${user}::uuid,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',${`${user}@example.invalid`},'',now(),now())`;
          await sql`insert into public.profiles(id,auth_user_id,display_name,state)
          values(${profile}::uuid,${user}::uuid,'Invitation race account','active')`;
        }
        const create = async (
          key: string,
          digest: string,
          recipient = users[1].profile,
        ) => {
          return await sql.begin(async (tx) => {
            await tx`set local role service_role`;
            await tx`select set_config('request.jwt.claims','{"role":"service_role"}',true)`;
            return (await tx`select public.create_competition_invite(decode(${digest},'hex'),'UTC',null,
            ${
              users[0].user
            }::uuid,${key}::uuid,1::smallint,${recipient}::uuid) id`)[0].id;
          });
        };
        const key = crypto.randomUUID();
        const retryDigest = randomBytes(32).toString("hex");
        const retries = await Promise.all(
          Array.from({ length: 100 }, () => create(key, retryDigest)),
        );
        assertEquals(new Set(retries).size, 1);
        const duplicates = await Promise.allSettled(
          Array.from(
            { length: 100 },
            () => create(crypto.randomUUID(), randomBytes(32).toString("hex")),
          ),
        );
        assertEquals(
          duplicates.every((result) =>
            result.status === "rejected" &&
            result.reason instanceof postgres.PostgresError &&
            result.reason.message === "pending_invitation_exists"
          ),
          true,
        );
        const other = await create(
          crypto.randomUUID(),
          randomBytes(32).toString("hex"),
          users[2].profile,
        );
        assertEquals(other !== retries[0], true);

        const claim = async (user: string) => {
          return await sql.begin(async (tx) => {
            await tx`set local role authenticated`;
            await tx`select set_config('request.jwt.claims',${
              JSON.stringify({ sub: user, role: "authenticated" })
            },true)`;
            return (await tx`select public.claim_competition_invite(decode(${retryDigest},'hex')) id`)[
              0
            ].id;
          });
        };
        const claims = await Promise.allSettled(
          Array.from(
            { length: 100 },
            (_, index) => claim(users[index % 2 === 0 ? 1 : 2].user),
          ),
        );
        assertEquals(
          claims.every((result, index) =>
            index % 2 === 0
              ? result.status === "fulfilled" && result.value === retries[0]
              : result.status === "rejected" &&
                result.reason instanceof postgres.PostgresError &&
                result.reason.message === "invite_unavailable"
          ),
          true,
        );
        // Acceptance frees the sender/recipient pair without changing the accepted competition.
        assertEquals(
          await create(crypto.randomUUID(), randomBytes(32).toString("hex")) !==
            retries[0],
          true,
        );
      } finally {
        await sql.end();
      }
    }
  },
});
