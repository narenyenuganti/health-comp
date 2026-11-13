import { assertEquals } from "@std/assert";
import postgres from "postgres";

Deno.test({
  name: "concurrent username claims return one winner and username_unavailable",
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const databaseURL = Deno.env.get("HEALTHCOMP_TEST_DATABASE_URL") ?? "";
    if (
      !databaseURL ||
      !["127.0.0.1", "localhost", "::1"].includes(new URL(databaseURL).hostname)
    ) {
      throw new Error("username race requires disposable local database");
    }
    const sql = postgres(databaseURL, { max: 3 });
    const users = [crypto.randomUUID(), crypto.randomUUID()];
    const username = `race_${
      crypto.randomUUID().replaceAll("-", "").slice(0, 15)
    }`;
    try {
      for (const user of users) {
        await sql`insert into auth.users(id) values(${user}::uuid)`;
        await sql`insert into public.profiles(id,auth_user_id,display_name,state)
          values(${user}::uuid,${user}::uuid,'Username race','active')`;
      }
      const results = await Promise.allSettled(
        users.map((user) =>
          sql.begin(async (tx) => {
            await tx`set local role authenticated`;
            await tx`select set_config('request.jwt.claims',${
              JSON.stringify({ role: "authenticated", sub: user })
            },true)`;
            return await tx`select public.set_username(${username})`;
          })
        ),
      );
      assertEquals(results.filter((r) => r.status === "fulfilled").length, 1);
      const loser = results.find((r) => r.status === "rejected");
      if (loser?.status !== "rejected") throw new Error("missing losing claim");
      assertEquals(loser.reason instanceof postgres.PostgresError, true);
      assertEquals(loser.reason.code, "P0001");
      assertEquals(loser.reason.message, "username_unavailable");
      assertEquals(
        (await sql`select count(*)::int n from public.profiles where username=${username}`)[
          0
        ].n,
        1,
      );
    } finally {
      // Profiles have a no-delete trigger; deactivation releases the test handle.
      await sql`update public.profiles set state='deleting' where id = any(${
        sql.array(users)
      }::uuid[])`;
      await sql.end();
    }
  },
});
