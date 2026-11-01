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
      const users = Array.from({ length: 5 }, () => ({
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
          sender = users[0].user,
        ) => {
          return await sql.begin(async (tx) => {
            await tx`set local role service_role`;
            await tx`select set_config('request.jwt.claims','{"role":"service_role"}',true)`;
            return (await tx`select public.create_competition_invite(decode(${digest},'hex'),'UTC',null,
            ${sender}::uuid,${key}::uuid,1::smallint,${recipient}::uuid) id`)[0]
              .id;
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
        const otherDigest = randomBytes(32).toString("hex");
        const other = await create(
          crypto.randomUUID(),
          otherDigest,
          users[2].profile,
        );
        assertEquals(other !== retries[0], true);

        const claim = async (user: string, digest = retryDigest) => {
          return await sql.begin(async (tx) => {
            await tx`set local role authenticated`;
            await tx`select set_config('request.jwt.claims',${
              JSON.stringify({ sub: user, role: "authenticated" })
            },true)`;
            return (await tx`select public.claim_competition_invite(decode(${digest},'hex')) id`)[
              0
            ].id;
          });
        };
        const cancel = async (user: string, competition: string) => {
          return await sql.begin(async (tx) => {
            await tx`set local role authenticated`;
            await tx`select set_config('request.jwt.claims',${
              JSON.stringify({ sub: user, role: "authenticated" })
            },true)`;
            return (await tx`select public.cancel_competition(${competition}::uuid)->>'competition_id' id`)[
              0
            ].id;
          });
        };
        const acceptById = async (user: string, competition: string) => {
          return await sql.begin(async (tx) => {
            await tx`set local role authenticated`;
            await tx`select set_config('request.jwt.claims',${
              JSON.stringify({ sub: user, role: "authenticated" })
            },true)`;
            return (await tx`select public.accept_competition_challenge(${competition}::uuid)->>'competition_id' id`)[
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
        // The accepted match now blocks a new challenge between the pair.
        const overlap = await Promise.allSettled([
          create(crypto.randomUUID(), randomBytes(32).toString("hex")),
        ]);
        assertEquals(
          overlap[0].status === "rejected" &&
            overlap[0].reason instanceof postgres.PostgresError &&
            overlap[0].reason.message === "active_match_exists",
          true,
        );

        // Claim by token and accept in the app race to exactly one acceptance.
        const acceptances = await Promise.allSettled(
          Array.from(
            { length: 100 },
            (_, index) =>
              index % 2 === 0
                ? claim(users[2].user, otherDigest)
                : acceptById(users[2].user, other),
          ),
        );
        assertEquals(
          acceptances.every((result) =>
            result.status === "fulfilled" && result.value === other
          ),
          true,
        );
        assertEquals(
          (await sql`select count(*)::int n from public.competition_change_log
            where competition_id = ${other}::uuid
              and change_kind = 'participant_state_changed'`)[0].n,
          1,
        );

        // Accept and cancel of one challenge never deadlock: the creator's
        // cancel writes closed_by (a key-share check on profiles) while the
        // recipient's accept holds both profile rows.
        for (let round = 0; round < 20; round++) {
          const challenge = await create(
            crypto.randomUUID(),
            randomBytes(32).toString("hex"),
            users[4].profile,
            users[3].user,
          );
          const outcomes = await Promise.allSettled([
            acceptById(users[4].user, challenge),
            cancel(users[3].user, challenge),
          ]);
          assertEquals(outcomes[1].status, "fulfilled");
          assertEquals(
            outcomes[0].status === "fulfilled" ||
              (outcomes[0].reason instanceof postgres.PostgresError &&
                outcomes[0].reason.message === "invite_unavailable"),
            true,
          );
          assertEquals(
            (await sql`select lifecycle from public.competitions
              where id = ${challenge}::uuid`)[0].lifecycle,
            "cancelled",
          );
        }

        // Reciprocal creates between a free pair serialize: exactly one wins.
        const reciprocal = await Promise.allSettled(
          Array.from(
            { length: 40 },
            (_, index) =>
              index % 2 === 0
                ? create(
                  crypto.randomUUID(),
                  randomBytes(32).toString("hex"),
                  users[2].profile,
                  users[1].user,
                )
                : create(
                  crypto.randomUUID(),
                  randomBytes(32).toString("hex"),
                  users[1].profile,
                  users[2].user,
                ),
          ),
        );
        const winners = reciprocal.flatMap((result, index) =>
          result.status === "fulfilled" ? [index % 2] : []
        );
        assertEquals(winners.length, 1);
        assertEquals(
          reciprocal.every((result, index) =>
            result.status === "fulfilled" ||
            (result.reason instanceof postgres.PostgresError &&
              result.reason.message ===
                (index % 2 === winners[0]
                  ? "pending_invitation_exists"
                  : "incoming_challenge_exists"))
          ),
          true,
        );
      } finally {
        await sql.end();
      }
    }
  },
});
