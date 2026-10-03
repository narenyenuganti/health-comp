import { assertEquals } from "@std/assert";
import postgres from "postgres";

Deno.test("development correlation never waits on a concurrently locked installation", async () => {
  const databaseURL = Deno.env.get("HEALTHCOMP_TEST_DATABASE_URL") ??
    "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
  if (
    !["127.0.0.1", "localhost", "::1"].includes(new URL(databaseURL).hostname)
  ) {
    throw new Error(
      "notification correlation requires a disposable local database",
    );
  }
  const sql = postgres(databaseURL, { max: 3 });
  const userA = crypto.randomUUID(), userB = crypto.randomUUID();
  const profileA = crypto.randomUUID(), profileB = crypto.randomUUID();
  const competitionID = crypto.randomUUID(),
    installationID = crypto.randomUUID();
  try {
    await sql.begin(async (tx) => {
      await tx`insert into auth.users(id,aud,role,created_at,updated_at)
        values(${userA}::uuid,'authenticated','authenticated',now(),now()),
              (${userB}::uuid,'authenticated','authenticated',now(),now())`;
      await tx`insert into public.profiles(id,auth_user_id,display_name,state)
        values(${profileA}::uuid,${userA}::uuid,'Synthetic lock A','active'),
              (${profileB}::uuid,${userB}::uuid,'Synthetic lock B','active')`;
      await tx`insert into public.competitions(
        id,creator_profile_id,time_zone_identifier,start_day,scoring_policy_identity,
        lifecycle,invitation_expires_at,best_available_deadline)
        values(${competitionID}::uuid,${profileA}::uuid,'UTC','2000-01-01',
          'healthcomp.activity-score.v1','tallying','1999-12-31','2000-01-09')`;
      await tx`insert into public.competition_participants(competition_id,profile_id,role,state)
        values(${competitionID}::uuid,${profileA}::uuid,'creator','accepted'),
              (${competitionID}::uuid,${profileB}::uuid,'invitee','accepted')`;
      await tx`insert into public.device_installations(
        profile_id,installation_id,apns_token,environment,state)
        values(${profileA}::uuid,${installationID}::uuid,${
        "aa".repeat(32)
      },'sandbox','active')`;
      await tx`select set_config('request.jwt.claims','{"role":"service_role"}',true)`;
      await tx`select public.finalize_competition(${competitionID}::uuid)`;
    });
    const leased = await sql.begin(async (tx) => {
      await tx`select set_config('request.jwt.claims','{"role":"service_role"}',true)`;
      return (await tx`select public.lease_competition_notification_work(1,60) payload`)[
        0
      ]
        .payload.items;
    });
    assertEquals(leased.length, 1);
    assertEquals(leased[0].competitionId, competitionID);

    const installationLocker = await sql.reserve();
    try {
      await installationLocker`begin`;
      await installationLocker`select 1 from public.device_installations
        where profile_id=${profileA}::uuid and installation_id=${installationID}::uuid
        for update`;
      // The other connection must finish before this lock is released. A
      // blocking installation lock would time out instead of resolving work.
      const resolved = await sql.begin(async (tx) => {
        await tx`set local lock_timeout='250ms'`;
        await tx`set local statement_timeout='2s'`;
        await tx`select set_config('request.jwt.claims','{"role":"service_role"}',true)`;
        return (await tx`select public.resolve_competition_notification_work_with_delivery_log(
          ${leased[0].workId}::uuid,${
          leased[0].leaseToken
        }::uuid,'busy-installation-log') resolved`)[0]
          .resolved;
      });
      assertEquals(resolved, true);
      assertEquals(
        (await sql`select state,apns_development_delivery_log_id
          from private.competition_notification_work where id=${
          leased[0].workId
        }::uuid`)[0],
        { state: "sent", apns_development_delivery_log_id: null },
      );
    } finally {
      await installationLocker`rollback`;
      installationLocker.release();
    }
  } finally {
    try {
      await sql`delete from public.device_installations
        where profile_id=${profileA}::uuid and installation_id=${installationID}::uuid`;
    } finally {
      await sql.end();
    }
  }
});
