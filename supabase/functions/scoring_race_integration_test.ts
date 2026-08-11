import { assertEquals } from "@std/assert";
import postgres from "postgres";

const databaseURL = Deno.env.get("HEALTHCOMP_TEST_DATABASE_URL") ??
  "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
const sql = postgres(databaseURL, { max: 24 });
const claims = (id: string, role = "authenticated") =>
  JSON.stringify({ sub: id, role });

Deno.test({
  name: "DB-backed scoring/finalization contention matrix runs 100-way",
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    if (
      !["127.0.0.1", "localhost", "::1"].includes(new URL(databaseURL).hostname)
    ) throw new Error("race matrix requires disposable local database");
    const userA = crypto.randomUUID(),
      userB = crypto.randomUUID(),
      profileA = crypto.randomUUID(),
      profileB = crypto.randomUUID();
    await sql`insert into auth.users(id,instance_id,aud,role,email,encrypted_password,created_at,updated_at) values(${userA}::uuid,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',${`${userA}@example.invalid`},'',now(),now()),(${userB}::uuid,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',${`${userB}@example.invalid`},'',now(),now())`;
    await sql`insert into public.profiles(id,auth_user_id,display_name,state) values(${profileA}::uuid,${userA}::uuid,'Race A','active'),(${profileB}::uuid,${userB}::uuid,'Race B','active')`;
    async function competition(deadline: string) {
      const id = crypto.randomUUID();
      await sql.begin(async (tx) => {
        await tx`set constraints all deferred`;
        await tx`insert into public.competitions(id,creator_profile_id,time_zone_identifier,start_day,scoring_policy_identity,lifecycle,invitation_expires_at,best_available_deadline) values(${id}::uuid,${profileA}::uuid,'UTC','2026-08-01','healthcomp.activity-score.v1','tallying','2026-07-31',${deadline}::timestamptz)`;
        await tx`insert into public.competition_participants(competition_id,profile_id,role,state) values(${id}::uuid,${profileA}::uuid,'creator','accepted'),(${id}::uuid,${profileB}::uuid,'invitee','accepted')`;
      });
      return id;
    }
    async function score(
      comp: string,
      semantic: string,
      day: number,
      revision: number,
      move: number,
      user = userA,
    ) {
      return await sql.begin(async (tx) => {
        await tx`select set_config('request.jwt.claims',${claims(user)},true)`;
        return await tx`select public.submit_score_revision(${comp}::uuid,${semantic}::uuid,${day},${revision},${`2026-08-0${day}T12:00:00Z`}::timestamptz,'activeEnergyKilocalories','standHours',${move},0,0,'available','healthcomp.activity-score.v1') result`;
      });
    }
    async function seedWindow(comp: string, profile: string, move: number) {
      await sql`insert into public.daily_score_revisions(competition_id,participant_profile_id,day_ordinal,semantic_event_id,client_revision,move_mode,stand_mode,move_basis_points,exercise_basis_points,stand_basis_points,accepted_centi_points,availability_reason,scoring_policy_identity,wire_content_sha256,server_seq,evaluated_at)
        select ${comp}::uuid,${profile}::uuid,d,gen_random_uuid()::text,d,'activeEnergyKilocalories','standHours',${move},0,0,${move},'available','healthcomp.activity-score.v1',private.wire_score_digest_v1(${comp}::uuid,${profile}::uuid,d::smallint,'activeEnergyKilocalories','standHours',${move},0,0,${move},'available','healthcomp.activity-score.v1',d),1,('2026-07-31'::timestamptz+d*interval '1 day') from generate_series(1,7) d`;
    }
    async function attest(comp: string, semantic: string, user: string) {
      return await sql.begin(async (tx) => {
        await tx`select set_config('request.jwt.claims',${claims(user)},true)`;
        return await tx`select public.attest_final_window(${comp}::uuid,${semantic}::uuid,1,'stable',array[1,2,3,4,5,6,7]::bigint[]) result`;
      });
    }
    const duplicateComp = await competition("2099-01-01");
    const semantic = crypto.randomUUID();
    const duplicates = await Promise.all(
      Array.from(
        { length: 100 },
        () => score(duplicateComp, semantic, 1, 1, 100),
      ),
    );
    assertEquals(
      duplicates.filter((r) => r[0].result.disposition === "appended").length,
      1,
    );
    assertEquals(
      duplicates.filter((r) => r[0].result.disposition === "duplicate").length,
      99,
    );
    assertEquals(
      (await sql`select count(*)::int n from public.daily_score_revisions where competition_id=${duplicateComp}::uuid`)[
        0
      ].n,
      1,
    );
    const divergent = await Promise.allSettled(
      Array.from(
        { length: 100 },
        (_, i) => score(duplicateComp, semantic, 1, 1, 101 + i),
      ),
    );
    assertEquals(
      divergent.every((r) =>
        r.status === "fulfilled" &&
        r.value[0].result.code === "divergent_duplicate"
      ),
      true,
    );
    const crossDay = await Promise.allSettled(
      Array.from(
        { length: 100 },
        () => score(duplicateComp, crypto.randomUUID(), 2, 1, 100),
      ),
    );
    assertEquals(
      crossDay.every((r) =>
        r.status === "fulfilled" &&
        r.value[0].result.code === "divergent_duplicate"
      ),
      true,
    );
    const stableRaceComp = await competition("2099-01-01");
    await seedWindow(stableRaceComp, profileA, 300);
    const stableRace = await Promise.allSettled([
      attest(stableRaceComp, crypto.randomUUID(), userA),
      ...Array.from(
        { length: 100 },
        () => score(stableRaceComp, crypto.randomUUID(), 7, 8, 301),
      ),
    ]);
    assertEquals(stableRace.length, 101);
    const stableWon = stableRace[0].status === "fulfilled" &&
      stableRace[0].value[0].result.disposition === "appended";
    const revisionEightCount =
      (await sql`select count(*)::int n from public.daily_score_revisions where competition_id=${stableRaceComp}::uuid and participant_profile_id=${profileA}::uuid and client_revision=8`)[
        0
      ].n;
    assertEquals(
      (stableWon && revisionEightCount === 0) ||
        (!stableWon && revisionEightCount === 1),
      true,
    );
    const deadlineComp = await competition("2026-08-10");
    const deadlineRace = await Promise.allSettled([
      ...Array.from(
        { length: 100 },
        () => score(deadlineComp, crypto.randomUUID(), 1, 1, 100),
      ),
      ...Array.from({ length: 100 }, () =>
        sql.begin(async (tx) => {
          await tx`select set_config('request.jwt.claims',${
            claims("", "service_role")
          },true)`;
          return await tx`select public.finalize_competition(${deadlineComp}::uuid) result`;
        })),
    ]);
    assertEquals(deadlineRace.length, 200);
    assertEquals(
      deadlineRace.slice(0, 100).every((result) =>
        result.status === "fulfilled" &&
        (result.value[0].result.disposition === "rejected" &&
          ["competition_finalized", "competition_terminal"].includes(
            result.value[0].result.code,
          ))
      ),
      true,
    );
    assertEquals(
      (await sql`select count(*)::int n from public.competition_results where competition_id=${deadlineComp}::uuid`)[
        0
      ].n,
      1,
    );
    assertEquals(
      (await sql`select count(*)::int n from public.competition_change_log where competition_id=${deadlineComp}::uuid and change_kind='competition_result_confirmed'`)[
        0
      ].n,
      1,
    );
    const stableComp = await competition("2099-01-01");
    await seedWindow(stableComp, profileA, 300);
    await seedWindow(stableComp, profileB, 100);
    const semanticA = crypto.randomUUID();
    const semanticB = crypto.randomUUID();
    const stableAttestations = await Promise.all([
      ...Array.from(
        { length: 100 },
        () => attest(stableComp, semanticA, userA),
      ),
      ...Array.from(
        { length: 100 },
        () => attest(stableComp, semanticB, userB),
      ),
    ]);
    assertEquals(stableAttestations.length, 200);
    assertEquals(
      stableAttestations.filter((result) =>
        result[0].result.disposition === "appended"
      ).length,
      2,
    );
    assertEquals(
      stableAttestations.filter((result) =>
        result[0].result.disposition === "duplicate"
      ).length,
      198,
    );
    assertEquals(
      (await sql`select count(*)::int n from public.competition_results where competition_id=${stableComp}::uuid`)[
        0
      ].n,
      1,
    );
    assertEquals(
      (await sql`select count(*)::int n from public.competition_change_log where competition_id=${stableComp}::uuid and change_kind='competition_result_confirmed'`)[
        0
      ].n,
      1,
    );
    assertEquals(
      (await sql`select count(*)::int n from public.competition_awards where competition_id=${stableComp}::uuid`)[
        0
      ].n,
      1,
    );
    for (
      const comp of [duplicateComp, stableRaceComp, deadlineComp, stableComp]
    ) {
      const cursor =
        (await sql`select count(*)::int n,count(distinct server_seq)::int unique_n,coalesce(min(server_seq),0)::int minimum,coalesce(max(server_seq),0)::int maximum from public.competition_change_log where competition_id=${comp}::uuid`)[
          0
        ];
      assertEquals(cursor.unique_n, cursor.n);
      assertEquals(cursor.n === 0 || cursor.minimum === 1, true);
      assertEquals(cursor.maximum, cursor.n);
    }
    await sql.end();
  },
});
