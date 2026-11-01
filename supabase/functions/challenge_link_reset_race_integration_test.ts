import { assertEquals, assertNotEquals } from "@std/assert";
import { randomBytes } from "node:crypto";
import postgres from "postgres";

Deno.test({
  name:
    "a challenge link reset waits for creates from the link and wins the race cleanly",
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const databaseURL = Deno.env.get("HEALTHCOMP_TEST_DATABASE_URL") ??
      "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
    if (
      !["127.0.0.1", "localhost", "::1"].includes(new URL(databaseURL).hostname)
    ) {
      throw new Error("challenge link race requires disposable local database");
    }
    const sql = postgres(databaseURL, { max: 12 });
    const users = Array.from({ length: 42 }, () => ({
      user: crypto.randomUUID(),
      profile: crypto.randomUUID(),
    }));
    const [owner, firstSender, ...senders] = users;
    try {
      for (const { user, profile } of users) {
        await sql`insert into auth.users(id,instance_id,aud,role,email,encrypted_password,created_at,updated_at)
        values(${user}::uuid,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',${`${user}@example.invalid`},'',now(),now())`;
        await sql`insert into public.profiles(id,auth_user_id,display_name,state)
        values(${profile}::uuid,${user}::uuid,'Challenge link race account','active')`;
      }
      const asOwner = async (rpc: "get" | "reset", lockTimeout?: string) => {
        return await sql.begin(async (tx) => {
          await tx`set local role authenticated`;
          if (lockTimeout) {
            await tx`select set_config('lock_timeout',${lockTimeout},true)`;
          }
          await tx`select set_config('request.jwt.claims',${
            JSON.stringify({ sub: owner.user, role: "authenticated" })
          },true)`;
          const rows = rpc === "get"
            ? await tx`select public.get_my_challenge_link()->>'code' code`
            : await tx`select public.reset_my_challenge_link()->>'code' code`;
          return rows[0].code as string;
        });
      };
      const fromLink = (
        tx: postgres.TransactionSql | postgres.ReservedSql,
        sender: string,
        code: string,
      ) =>
        tx`select public.create_competition_invite_from_link(
          decode(${
          randomBytes(32).toString("hex")
        },'hex'),'UTC',${sender}::uuid,
          ${crypto.randomUUID()}::uuid,1::smallint,${code}) id`;
      const create = async (sender: string, code: string) => {
        return await sql.begin(async (tx) => {
          await tx`set local role service_role`;
          await tx`select set_config('request.jwt.claims','{"role":"service_role"}',true)`;
          return (await fromLink(tx, sender, code))[0].id as string;
        });
      };

      // A create from the link holds it until commit: a reset waits.
      const firstCode = await asOwner("get");
      const holder = await sql.reserve();
      try {
        await holder`begin`;
        await holder`set local role service_role`;
        await holder`select set_config('request.jwt.claims','{"role":"service_role"}',true)`;
        const held =
          (await fromLink(holder, firstSender.user, firstCode))[0].id;
        const blocked = await Promise.allSettled([asOwner("reset", "300ms")]);
        assertEquals(
          blocked[0].status === "rejected" &&
            blocked[0].reason instanceof postgres.PostgresError &&
            blocked[0].reason.code === "55P03",
          true,
        );
        await holder`commit`;
        assertEquals(
          (await sql`select challenge_link_code code from public.competition_invites
            where competition_id = ${held}::uuid`)[0].code,
          firstCode,
        );
      } finally {
        holder.release();
      }
      const secondCode = await asOwner("reset");
      assertNotEquals(secondCode, firstCode);
      const stale = await Promise.allSettled([
        create(senders[0].user, firstCode),
      ]);
      assertEquals(
        stale[0].status === "rejected" &&
          stale[0].reason instanceof postgres.PostgresError &&
          stale[0].reason.message === "recipient_unavailable",
        true,
      );

      // Creates racing one reset: each either used the code it was given
      // before the reset, or is refused like an unknown code.
      const outcomes = await Promise.allSettled([
        ...senders.slice(1).map(({ user }) => create(user, secondCode)),
        asOwner("reset"),
      ]);
      const reset = outcomes.at(-1)!;
      assertEquals(reset.status, "fulfilled");
      const created = outcomes.slice(0, -1).flatMap((result) => {
        if (result.status === "fulfilled") return [result.value as string];
        assertEquals(
          result.reason instanceof postgres.PostgresError &&
            result.reason.message === "recipient_unavailable",
          true,
        );
        return [];
      });
      if (created.length > 0) {
        const codes = await sql`select distinct challenge_link_code code
          from public.competition_invites
          where competition_id::text = any(${sql.array(created)})`;
        assertEquals(codes.map((row) => row.code), [secondCode]);
      }
      const current = await asOwner("get");
      assertNotEquals(current, secondCode);
      assertEquals(
        current,
        (reset as PromiseFulfilledResult<string>).value,
      );
    } finally {
      await sql.end();
    }
  },
});
