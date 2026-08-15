import { assertEquals } from "@std/assert";
import postgres from "postgres";

const databaseURL = Deno.env.get("HEALTHCOMP_TEST_DATABASE_URL") ??
  "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
const sql = postgres(databaseURL, { max: 24 });
const claims = (id: string, role = "authenticated") =>
  JSON.stringify({ sub: id, role });
const payloadSHA256 = "11".repeat(32);
const publicKeyPEM = `-----BEGIN PUBLIC KEY-----\n${
  "A".repeat(120)
}\n-----END PUBLIC KEY-----`;

function randomHex(byteCount: number): string {
  return Array.from(crypto.getRandomValues(new Uint8Array(byteCount)))
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("");
}

function randomBase64(byteCount: number): string {
  return btoa(String.fromCharCode(
    ...crypto.getRandomValues(new Uint8Array(byteCount)),
  ));
}

function rejectionIncludes(
  result: PromiseSettledResult<unknown>,
  code: string,
): boolean {
  return result.status === "rejected" && String(result.reason).includes(code);
}

Deno.test({
  name: "App Attest challenge counter and grant races each permit one winner",
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    if (
      !["127.0.0.1", "localhost", "::1"].includes(new URL(databaseURL).hostname)
    ) {
      throw new Error(
        "App Attest race matrix requires a disposable local database",
      );
    }

    const userA = crypto.randomUUID();
    const userB = crypto.randomUUID();
    const profileA = crypto.randomUUID();
    const profileB = crypto.randomUUID();
    const installationRowID = crypto.randomUUID();
    const installationID = crypto.randomUUID();
    const profileRateInstallationIDs = Array.from(
      { length: 3 },
      () => crypto.randomUUID(),
    );
    const competitionID = crypto.randomUUID();
    const semanticEventID = crypto.randomUUID();
    const keyID = randomBase64(32);
    const profileRateKeyID = randomBase64(32);
    const evaluatedAt = "2026-08-15T12:00:00Z";

    await sql`
      insert into auth.users (
        id, instance_id, aud, role, email, encrypted_password,
        created_at, updated_at
      ) values
        (
          ${userA}::uuid,
          '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          ${`${userA}@example.invalid`}, '', now(), now()
        ),
        (
          ${userB}::uuid,
          '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          ${`${userB}@example.invalid`}, '', now(), now()
        )
    `;
    await sql`
      insert into public.profiles (id, auth_user_id, display_name, state)
      values
        (${profileA}::uuid, ${userA}::uuid, 'Attest Race A', 'active'),
        (${profileB}::uuid, ${userB}::uuid, 'Attest Race B', 'active')
    `;
    await sql.begin(async (tx) => {
      await tx`set constraints all deferred`;
      await tx`
        insert into public.competitions (
          id, creator_profile_id, time_zone_identifier, start_day,
          scoring_policy_identity, lifecycle, invitation_expires_at,
          best_available_deadline
        ) values (
          ${competitionID}::uuid, ${profileA}::uuid, 'UTC', '2026-08-15',
          'healthcomp.activity-score.v1', 'active',
          '2026-08-14T00:00:00Z', '2099-08-22T00:00:00Z'
        )
      `;
      await tx`
        insert into public.competition_participants (
          competition_id, profile_id, role, state
        ) values
          (${competitionID}::uuid, ${profileA}::uuid, 'creator', 'accepted'),
          (${competitionID}::uuid, ${profileB}::uuid, 'invitee', 'accepted')
      `;
    });
    await sql`
      insert into public.device_installations (
        id, profile_id, installation_id, apns_token, environment, state
      ) values (
        ${installationRowID}::uuid, ${profileA}::uuid,
        ${installationID}::uuid, ${randomHex(32)}, 'sandbox', 'active'
      )
    `;
    for (const profileRateInstallationID of profileRateInstallationIDs) {
      await sql`
        insert into public.device_installations (
          id, profile_id, installation_id, apns_token, environment, state
        ) values (
          ${crypto.randomUUID()}::uuid, ${profileB}::uuid,
          ${profileRateInstallationID}::uuid, ${randomHex(32)},
          'sandbox', 'active'
        )
      `;
    }

    for (let index = 0; index < 19; index++) {
      const seed = `profile-rate-${crypto.randomUUID()}`;
      await sql`
        insert into private.app_attest_challenges (
          profile_id, installation_id, requested_key_id, payload_sha256,
          challenge, proof_kind, created_at, expires_at, consumed_at
        ) values (
          ${profileB}::uuid,
          ${profileRateInstallationIDs[index % 3]}::uuid,
          ${profileRateKeyID}, digest(${`${seed}-payload`}, 'sha256'),
          digest(${`${seed}-challenge`}, 'sha256'), 'attestation',
          statement_timestamp(), statement_timestamp() + interval '5 minutes',
          statement_timestamp()
        )
      `;
    }
    async function issueAcrossProfile(index: number) {
      return await sql.begin(async (tx) => {
        await tx`select set_config('request.jwt.claims', ${
          claims(userB)
        }, true)`;
        return await tx`
          select public.issue_app_attest_challenge(
            ${profileRateInstallationIDs[index % 3]}::uuid,
            ${index.toString(16).padStart(2, "0").repeat(32)},
            ${profileRateKeyID}
          ) result
        `;
      });
    }
    const profileRateRace = await Promise.allSettled(
      Array.from({ length: 20 }, (_, index) => issueAcrossProfile(index)),
    );
    assertEquals(
      profileRateRace.filter((result) => result.status === "fulfilled").length,
      1,
    );
    assertEquals(
      profileRateRace.filter((result) =>
        rejectionIncludes(result, "app_attest_rate_limited")
      ).length,
      19,
    );
    assertEquals(
      (await sql`
        select count(*)::int value
        from private.app_attest_challenges
        where profile_id = ${profileB}::uuid
          and created_at > statement_timestamp() - interval '5 minutes'
      `)[0].value,
      20,
    );

    const wireDigest = (await sql`
      select encode(private.wire_score_digest_v1(
        ${competitionID}::uuid, ${profileA}::uuid, 1::smallint,
        'activeEnergyKilocalories', 'standHours',
        10000, 5000, 12500, 27500, 'available',
        'healthcomp.activity-score.v1', 1
      ), 'hex') value
    `)[0].value as string;

    async function issue(payload: string) {
      return await sql.begin(async (tx) => {
        await tx`select set_config('request.jwt.claims', ${
          claims(userA)
        }, true)`;
        const rows = await tx`
          select public.issue_app_attest_challenge(
            ${installationID}::uuid, ${payload}, ${keyID}
          ) result
        `;
        return rows[0].result as Record<string, unknown>;
      });
    }

    const issuePayloads = Array.from(
      { length: 20 },
      (_, index) => (index + 1).toString(16).padStart(2, "0").repeat(32),
    );
    const issueRace = await Promise.allSettled(issuePayloads.map(issue));
    assertEquals(
      issueRace.filter((result) => result.status === "fulfilled").length,
      3,
    );
    assertEquals(
      issueRace.filter((result) =>
        rejectionIncludes(result, "app_attest_challenge_limit")
      ).length,
      17,
    );
    assertEquals(
      (await sql`
        select count(*)::int value
        from private.app_attest_challenges
        where profile_id = ${profileA}::uuid and consumed_at is null
      `)[0].value,
      3,
    );

    const winningIssueIndex = issueRace.findIndex((result) =>
      result.status === "fulfilled"
    );
    const challenge = issueRace[winningIssueIndex];
    if (challenge.status !== "fulfilled") throw new Error("missing challenge");
    const challengeID = String(challenge.value.challengeID);
    const boundPayload = issuePayloads[winningIssueIndex];

    async function authorizeAttestation() {
      return await sql.begin(async (tx) => {
        await tx`select set_config('request.jwt.claims', ${
          claims("", "service_role")
        }, true)`;
        const rows = await tx`
          select public.authorize_app_attest_proof(
            ${userA}::uuid, ${challengeID}::uuid, ${installationID}::uuid,
            ${boundPayload}, ${keyID}, 'attestation', ${publicKeyPEM},
            'cmFjZS1yZWNlaXB0', 'production', 2, '1', 0,
            ${competitionID}::uuid, ${semanticEventID}::uuid,
            1, 1, ${evaluatedAt}::timestamptz, ${wireDigest}
          ) result
        `;
        return rows[0].result as Record<string, unknown>;
      });
    }

    const attestationRace = await Promise.allSettled(
      Array.from({ length: 20 }, authorizeAttestation),
    );
    assertEquals(
      attestationRace.filter((result) => result.status === "fulfilled").length,
      1,
    );
    assertEquals(
      attestationRace.filter((result) =>
        rejectionIncludes(result, "app_attest_context_unavailable")
      ).length,
      19,
    );
    assertEquals(
      (await sql`
        select count(*)::int value from private.app_attest_keys
        where profile_id = ${profileA}::uuid
      `)[0].value,
      1,
    );
    assertEquals(
      (await sql`
        select count(*)::int value from private.app_attest_submission_grants
        where profile_id = ${profileA}::uuid
      `)[0].value,
      1,
    );

    await sql`
      delete from private.app_attest_challenges
      where profile_id = ${profileA}::uuid and consumed_at is null
    `;
    const assertionChallenges = await Promise.all([
      issue(payloadSHA256),
      issue(payloadSHA256),
    ]);
    async function authorizeAssertion(challengeValue: Record<string, unknown>) {
      return await sql.begin(async (tx) => {
        await tx`select set_config('request.jwt.claims', ${
          claims("", "service_role")
        }, true)`;
        const rows = await tx`
          select public.authorize_app_attest_proof(
            ${userA}::uuid, ${String(challengeValue.challengeID)}::uuid,
            ${installationID}::uuid, ${payloadSHA256}, ${keyID},
            'assertion', null, null, 'production', 2, '1', 1,
            ${competitionID}::uuid, ${semanticEventID}::uuid,
            1, 1, ${evaluatedAt}::timestamptz, ${wireDigest}
          ) result
        `;
        return rows[0].result as Record<string, unknown>;
      });
    }

    const counterRace = await Promise.allSettled(
      assertionChallenges.map(authorizeAssertion),
    );
    assertEquals(
      counterRace.filter((result) => result.status === "fulfilled").length,
      1,
    );
    assertEquals(
      counterRace.filter((result) =>
        rejectionIncludes(result, "app_attest_assertion_rejected")
      ).length,
      1,
    );
    assertEquals(
      (await sql`
        select sign_count::int value from private.app_attest_keys
        where key_id = ${keyID}
      `)[0].value,
      1,
    );

    const assertionWinner = counterRace.find((result) =>
      result.status === "fulfilled"
    );
    if (!assertionWinner || assertionWinner.status !== "fulfilled") {
      throw new Error("missing assertion grant");
    }
    const grantID = String(assertionWinner.value.grantID);
    async function submit() {
      return await sql.begin(async (tx) => {
        await tx`select set_config('request.jwt.claims', ${
          claims(userA)
        }, true)`;
        const rows = await tx`
          select public.submit_attested_score_revision(
            ${grantID}::uuid, ${competitionID}::uuid,
            ${semanticEventID}::uuid, 1, 1, ${evaluatedAt}::timestamptz,
            'activeEnergyKilocalories', 'standHours', 10000, 5000, 12500,
            'available', 'healthcomp.activity-score.v1',
            ${payloadSHA256}, ${wireDigest}
          ) result
        `;
        return rows[0].result as Record<string, unknown>;
      });
    }

    const grantRace = await Promise.allSettled(
      Array.from({ length: 20 }, submit),
    );
    assertEquals(
      grantRace.filter((result) =>
        result.status === "fulfilled" &&
        result.value.disposition === "appended"
      ).length,
      1,
    );
    assertEquals(
      grantRace.filter((result) =>
        rejectionIncludes(result, "app_attest_grant_unavailable")
      ).length,
      19,
    );
    assertEquals(
      (await sql`
        select count(*)::int value from public.daily_score_revisions
        where competition_id = ${competitionID}::uuid
          and participant_profile_id = ${profileA}::uuid
      `)[0].value,
      1,
    );
    assertEquals(
      (await sql`
        select count(*)::int value
        from private.app_attest_submission_grants
        where id = ${grantID}::uuid and consumed_at is not null
      `)[0].value,
      1,
    );

    await sql`
      update public.profiles
      set state = 'deleting', updated_at = statement_timestamp()
      where id in (${profileA}::uuid, ${profileB}::uuid)
    `;
    assertEquals(
      (await sql`
        select count(*)::int value
        from private.app_attest_keys where profile_id = ${profileA}::uuid
      `)[0].value,
      0,
    );

    await sql.end();
  },
});
