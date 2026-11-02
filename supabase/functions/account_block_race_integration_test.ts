import { assertEquals } from "@std/assert";
import { randomBytes } from "node:crypto";
import postgres from "postgres";

Deno.test({
  name:
    "a block waits for the profile locks and wins cleanly against concurrent creates",
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const databaseURL = Deno.env.get("HEALTHCOMP_TEST_DATABASE_URL") ??
      "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
    if (
      !["127.0.0.1", "localhost", "::1"].includes(new URL(databaseURL).hostname)
    ) {
      throw new Error("account block race requires disposable local database");
    }
    const sql = postgres(databaseURL, { max: 12 });
    const naren = { user: crypto.randomUUID(), profile: crypto.randomUUID() };
    const maya = { user: crypto.randomUUID(), profile: crypto.randomUUID() };
    try {
      for (const { user, profile } of [naren, maya]) {
        await sql`insert into auth.users(id,instance_id,aud,role,email,encrypted_password,created_at,updated_at)
        values(${user}::uuid,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',${`${user}@example.invalid`},'',now(),now())`;
        await sql`insert into public.profiles(id,auth_user_id,display_name,state)
        values(${profile}::uuid,${user}::uuid,'Account block race account','active')`;
      }
      const asUser = async <T>(
        user: string,
        run: (tx: postgres.TransactionSql) => Promise<T>,
        lockTimeout?: string,
      ) =>
        await sql.begin(async (tx) => {
          await tx`set local role authenticated`;
          if (lockTimeout) {
            await tx`select set_config('lock_timeout',${lockTimeout},true)`;
          }
          await tx`select set_config('request.jwt.claims',${
            JSON.stringify({ sub: user, role: "authenticated" })
          },true)`;
          return await run(tx);
        });
      const byID = (tx: postgres.TransactionSql | postgres.ReservedSql) =>
        tx`select public.create_competition_invite(
          decode(${randomBytes(32).toString("hex")},'hex'),'UTC',null,
          ${maya.user}::uuid,${crypto.randomUUID()}::uuid,1::smallint,
          ${naren.profile}::uuid) id`;
      const fromLink = (tx: postgres.TransactionSql, code: string) =>
        tx`select public.create_competition_invite_from_link(
          decode(${randomBytes(32).toString("hex")},'hex'),'UTC',
          ${maya.user}::uuid,${crypto.randomUUID()}::uuid,1::smallint,${code}) id`;
      const create = async (code?: string) =>
        await sql.begin(async (tx) => {
          await tx`set local role service_role`;
          await tx`select set_config('request.jwt.claims','{"role":"service_role"}',true)`;
          const rows = code ? await fromLink(tx, code) : await byID(tx);
          return rows[0].id as string;
        });
      const block = (seed: string, lockTimeout?: string) =>
        asUser(
          naren.user,
          (tx) => tx`select public.block_challenger(${seed}::uuid)`,
          lockTimeout,
        );
      const failure = (result: PromiseSettledResult<unknown>) =>
        result.status === "rejected" &&
          result.reason instanceof postgres.PostgresError
          ? result.reason
          : undefined;

      // Seed: Maya challenges Naren and he declines, so a block has a valid
      // key while a new create can still succeed.
      const code = await asUser(
        naren.user,
        async (tx) =>
          (await tx`select public.get_my_challenge_link()->>'code' code`)[0]
            .code as string,
      );
      const seed = await create();
      await asUser(
        naren.user,
        (tx) => tx`select public.decline_competition_challenge(${seed}::uuid)`,
      );

      // A create holds both profile locks until it ends: a block waits.
      const holder = await sql.reserve();
      try {
        await holder`begin`;
        await holder`set local role service_role`;
        await holder`select set_config('request.jwt.claims','{"role":"service_role"}',true)`;
        await byID(holder);
        const waited = await Promise.allSettled([block(seed, "100ms")]);
        assertEquals(failure(waited[0])?.code, "55P03");
        await holder`rollback`;
      } finally {
        holder.release();
      }

      // 20 by-id and link creates racing one block.
      const outcomes = await Promise.allSettled([
        ...Array.from(
          { length: 20 },
          (_, n) => create(n % 2 ? code : undefined),
        ),
        block(seed),
      ]);
      assertEquals(outcomes.at(-1)!.status, "fulfilled");
      const created = outcomes.slice(0, -1).flatMap((result) => {
        if (result.status === "fulfilled") return [result.value as string];
        const error = failure(result);
        assertEquals(error?.code === "40P01", false);
        assertEquals(
          ["pending_invitation_exists", "recipient_unavailable"].includes(
            error?.message ?? "",
          ),
          true,
        );
        return [];
      });
      assertEquals(created.length <= 1, true);
      for (const id of created) {
        const [row] =
          await sql`select lifecycle, closed_by_profile_id::text closer
          from public.competitions where id = ${id}::uuid`;
        assertEquals(row, { lifecycle: "declined", closer: naren.profile });
      }
      assertEquals(
        (await sql`select count(*)::int n from public.competitions
          where creator_profile_id = ${maya.profile}::uuid
            and invited_profile_id = ${naren.profile}::uuid
            and lifecycle = 'pending'`)[0].n,
        0,
      );
      assertEquals(
        (await sql`select count(*)::int n from private.account_blocks
          where blocker_profile_id = ${naren.profile}::uuid
            and blocked_profile_id = ${maya.profile}::uuid`)[0].n,
        1,
      );
      const after = await Promise.allSettled([create()]);
      assertEquals(failure(after[0])?.message, "recipient_unavailable");

      // A block waiting on the locks while Naren's deletion starts: the
      // deletion purges his blocks, so the block must not add one back.
      const deleter = await sql.reserve();
      try {
        await deleter`begin`;
        await deleter`update public.profiles set state = 'deleting'
          where id = ${naren.profile}::uuid`;
        const late = block(seed);
        for (let n = 0; n < 100; n++) {
          const [{ waiting }] = await sql`select count(*)::int waiting
            from pg_catalog.pg_stat_activity
            where wait_event_type = 'Lock' and query like '%block_challenger%'`;
          if (waiting > 0) break;
          await new Promise((resolve) => setTimeout(resolve, 20));
        }
        await deleter`commit`;
        const settled = await Promise.allSettled([late]);
        assertEquals(failure(settled[0])?.message, "active_profile_required");
      } finally {
        deleter.release();
      }
      assertEquals(
        (await sql`select count(*)::int n from private.account_blocks
          where blocker_profile_id = ${naren.profile}::uuid`)[0].n,
        0,
      );
    } finally {
      await sql.end();
    }
  },
});
