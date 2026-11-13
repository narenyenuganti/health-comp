import { assert, assertEquals } from "@std/assert";
import postgres from "postgres";
import {
  canonicalScoreRevisionJSON,
  type ScoringRpcClient,
  submitScoreRevisionHandler,
} from "./submit-score-revision/index.ts";

// An explicit URL prevents these mutating tests from finding another local project.
const databaseURL = Deno.env.get("HEALTHCOMP_TEST_DATABASE_URL");
const claims = (id: string, role = "authenticated") =>
  JSON.stringify({ sub: id, role });

// A losing call may fail only with a raised domain error (P0001); a deadlock
// (40P01), lock timeout or other exception is a regression the end state hides.
function assertOnlyDomainErrors(results: PromiseSettledResult<unknown>[]) {
  for (const result of results) {
    if (result.status === "rejected") {
      assertEquals((result.reason as { code?: string })?.code, "P0001");
    }
  }
}

Deno.test({
  name:
    "group admission, last accepts, cancellation, blocks and leave/upload races serialize",
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    assert(databaseURL, "HEALTHCOMP_TEST_DATABASE_URL is required");
    assert(
      ["127.0.0.1", "localhost", "::1"].includes(new URL(databaseURL).hostname),
    );
    const sql = postgres(databaseURL, { max: 8 });
    const users = Array.from({ length: 3 }, () => crypto.randomUUID());
    const profiles = users.map(() => crypto.randomUUID());
    const installations = users.map(() => crypto.randomUUID());
    try {
      for (let i = 0; i < users.length; i++) {
        await sql`insert into auth.users(id) values(${users[i]}::uuid)`;
        await sql`insert into public.profiles(id,auth_user_id,display_name,state) values(${
          profiles[i]
        }::uuid,${users[i]}::uuid,'Group race','active')`;
        await sql`insert into public.device_installations(profile_id,installation_id,apns_token,environment,state,supports_challenges,supports_reactions,supports_group_matches) values(${
          profiles[i]
        }::uuid,${installations[i]}::uuid,${
          crypto.randomUUID().replaceAll("-", "").repeat(2)
        },'sandbox','active',true,true,true)`;
      }
      const rpc = async (
        person: number,
        name: string,
        args: Record<string, unknown>,
        service = false,
      ) => {
        assert(
          [
            "create_group_match",
            "accept_group_match",
            "cancel_group_match",
            "block_challenger",
            "leave_group_match",
            "load_app_attest_context",
            "authorize_app_attest_proof",
            "submit_attested_score_revision",
          ].includes(name),
        );
        const [signature] =
          await sql`select p.proargnames names,array(select format_type(t,null) from unnest(p.proargtypes::oid[]) t) types from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=${name}`;
        const keys = Object.keys(args);
        const params = keys.map((key, i) => {
          const index = signature.names.indexOf(key);
          assert(index >= 0);
          return `${key} => $${i + 1}::${signature.types[index]}`;
        });
        return await sql.begin(async (tx) => {
          await tx`select set_config('request.jwt.claims',${
            claims(users[person], service ? "service_role" : "authenticated")
          },true)`;
          const [row] = await tx.unsafe(
            `select public.${name}(${params.join(",")}) result`,
            keys.map((key) => args[key]) as postgres.ParameterOrJSON<never>[],
          );
          return row.result;
        });
      };
      const seats = [{ kind: "human", profile_id: profiles[0] }, {
        kind: "human",
        profile_id: profiles[1],
      }, { kind: "bot", bot_mode: "pacer" }];
      const create = (key = crypto.randomUUID()) =>
        rpc(0, "create_group_match", {
          format: "three_way",
          seats,
          time_zone_identifier: "UTC",
          creation_idempotency_key: key,
        });
      const key = crypto.randomUUID();
      const duplicates = await Promise.all([create(key), create(key)]);
      assertEquals(duplicates[0], duplicates[1]);
      const cid = duplicates[0].competition_id;
      const accepted = await Promise.all([
        rpc(1, "accept_group_match", { competition_id: cid }),
        rpc(1, "accept_group_match", { competition_id: cid }),
      ]);
      assertEquals(accepted.map((r) => r.state), ["scheduled", "scheduled"]);
      assertEquals(
        (await sql`select count(*)::int n from public.competition_change_log where competition_id=${cid}::uuid and payload_snapshot->>'lifecycle'='scheduled'`)[
          0
        ].n,
        1,
      );
      assertEquals(
        (await sql`select count(*)::int n from private.competition_notification_work where competition_id=${cid}::uuid and kind='challenge_received'`)[
          0
        ].n,
        1,
      );
      await rpc(0, "cancel_group_match", { competition_id: cid });
      const cancelled = (await create()).competition_id;
      const cancelRace = await Promise.allSettled([
        rpc(1, "accept_group_match", { competition_id: cancelled }),
        rpc(0, "cancel_group_match", { competition_id: cancelled }),
      ]);
      assertEquals(cancelRace[1].status, "fulfilled");
      assertOnlyDomainErrors(cancelRace);
      assertEquals(
        (await sql`select lifecycle from public.competitions where id=${cancelled}::uuid`)[
          0
        ].lifecycle,
        "cancelled",
      );
      const blocked = (await create()).competition_id;
      assertOnlyDomainErrors(
        await Promise.allSettled([
          rpc(1, "accept_group_match", { competition_id: blocked }),
          rpc(1, "block_challenger", { competition_id: blocked }),
        ]),
      );
      assert(
        ["declined", "scheduled"].includes(
          (await sql`select lifecycle from public.competitions where id=${blocked}::uuid`)[
            0
          ].lifecycle,
        ),
      );
      assertEquals(
        (await sql`select count(*)::int n from private.account_blocks where blocker_profile_id=${
          profiles[1]
        }::uuid and blocked_profile_id=${profiles[0]}::uuid`)[0].n,
        1,
      );
      await sql`delete from private.account_blocks where blocker_profile_id=${
        profiles[1]
      }::uuid and blocked_profile_id=${profiles[0]}::uuid`;
      const live = (await create()).competition_id;
      await rpc(1, "accept_group_match", { competition_id: live });
      await sql`update public.competitions set start_day=current_date-1,invitation_expires_at=now()-interval '20 days',best_available_deadline=now()+interval '8 days' where id=${live}::uuid`;
      const score = async (rev: number) => {
        return await sql.begin(async (tx) => {
          await tx`select set_config('request.jwt.claims',${
            claims(users[0])
          },true)`;
          const [r] =
            await tx`select public.submit_score_revision(${live}::uuid,${crypto.randomUUID()}::uuid,1,${rev}::bigint,now(),'activeEnergyKilocalories','standHours',10000,0,0,'available','healthcomp.activity-score.v1') result`;
          return r.result;
        });
      };
      await score(1);
      const [bank, upload] = await Promise.all([
        rpc(0, "leave_group_match", { competition_id: live }),
        score(2),
      ]);
      assertEquals(
        bank.accepted_revisions[0],
        upload.disposition === "appended" ? "2" : "1",
      );
      assertEquals((await score(3)).code, "competition_terminal");

      // Exercise the actual edge handler and SQL authorize/grant/submit chain; only Apple crypto is synthetic.
      for (const terminalState of ["left", "finalized"]) {
        const match = (await create()).competition_id;
        await rpc(1, "accept_group_match", { competition_id: match });
        await sql`update public.competitions set start_day=current_date-1,invitation_expires_at=now()-interval '20 days',best_available_deadline=now()+interval '8 days' where id=${match}::uuid`;
        const [wire] =
          await sql`select encode(private.wire_score_digest_v1(${match}::uuid,${
            profiles[0]
          }::uuid,1::smallint,'activeEnergyKilocalories','standHours',10000,0,0,10000,'available','healthcomp.activity-score.v1',1),'hex') digest`;
        const value = {
          version: 1,
          competitionId: match,
          semanticEventId: crypto.randomUUID(),
          dayOrdinal: 1,
          clientRevision: "1",
          evaluatedAt: new Date().toISOString(),
          moveMode: "activeEnergyKilocalories",
          standMode: "standHours",
          moveBasisPoints: 10000,
          exerciseBasisPoints: 0,
          standBasisPoints: 0,
          availabilityReason: "available",
          scoringPolicyIdentity: "healthcomp.activity-score.v1",
          wireContentSHA256: wire.digest,
        };
        const edge = async (selected = value) => {
          const canonical = canonicalScoreRevisionJSON(selected);
          assert(canonical);
          const payload = Array.from(
            new Uint8Array(
              await crypto.subtle.digest(
                "SHA-256",
                new TextEncoder().encode(canonical),
              ),
            ),
          ).map((b) => b.toString(16).padStart(2, "0")).join("");
          const keyID = btoa(
            String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))),
          );
          const [challenge] =
            await sql`insert into private.app_attest_challenges(profile_id,installation_id,requested_key_id,payload_sha256,challenge,proof_kind,expires_at) values(${
              profiles[0]
            }::uuid,${
              installations[0]
            }::uuid,${keyID},decode(${payload},'hex'),extensions.gen_random_bytes(32),'attestation',now()+interval '5 minutes') returning id`;
          const client = (service: boolean): ScoringRpcClient => ({
            auth: {
              getUser: () =>
                Promise.resolve({
                  data: { user: { id: users[0] } },
                  error: null,
                }),
            },
            rpc: async (name, args) => {
              try {
                return { data: await rpc(0, name, args, service), error: null };
              } catch (error) {
                return {
                  data: null,
                  error: {
                    message: (error as Error).message,
                    code: (error as postgres.PostgresError).code,
                  },
                };
              }
            },
          });
          const response = await submitScoreRevisionHandler(
            new Request("http://localhost/functions/v1/submit-score-revision", {
              method: "POST",
              headers: {
                authorization: "Bearer synthetic",
                "content-type": "application/json",
              },
              body: JSON.stringify({
                version: 1,
                score: selected,
                appAttest: {
                  version: 1,
                  challengeID: challenge.id,
                  installationID: installations[0],
                  keyID,
                  proofKind: "attestation",
                  object: btoa("synthetic"),
                },
              }),
            }),
            {
              createUserClient: () => client(false),
              createServiceClient: () => client(true),
              now: () => new Date(),
              appAttestPolicy: () => ({
                appId: "TEAM123456.com.example.HealthComp",
                environment: "development",
                allowedValidationCategories: [3],
                allowedBundleVersions: ["1"],
                now: new Date(),
              }),
              verifyAttestation: () => ({
                keyID,
                publicKeyPEM: `-----BEGIN PUBLIC KEY-----\n${
                  "A".repeat(120)
                }\n-----END PUBLIC KEY-----`,
                receipt: new TextEncoder().encode("receipt"),
                environment: "development",
                validationCategory: 3,
                bundleVersion: "1",
              }),
              verifyAssertion: () => {
                throw new Error("unexpected assertion");
              },
            },
          );
          return { status: response.status, body: await response.json() };
        };
        const first = await edge();
        assertEquals(first.status, 200);
        assertEquals(first.body.disposition, "appended");
        if (terminalState === "left") {
          await rpc(0, "leave_group_match", { competition_id: match });
        } else {
          await sql`update public.competitions set start_day=current_date-10 where id=${match}::uuid`;
          await sql`select private.finalize_competition_locked(${match}::uuid,now()+interval '10 days')`;
        }
        const replay = await edge();
        assertEquals(replay.status, 200);
        assertEquals(replay.body.disposition, "duplicate");
        assertEquals(
          replay.body.acceptedServerSeq,
          first.body.acceptedServerSeq,
        );
        const fresh = await edge({
          ...value,
          semanticEventId: crypto.randomUUID(),
        });
        assertEquals(fresh.status, 409);
        assertEquals(fresh.body.code, "competition_terminal");
      }
    } finally {
      // Leave no deliverable work that could interfere with the next notification test.
      await sql`update private.competition_notification_work set state='discarded',lease_token=null,lease_expires_at=null,leased_apns_token_sha256=null,completed_at=now(),updated_at=now() where recipient_profile_id=any(${profiles}::uuid[]) and state in ('pending','leased')`;
      await sql.end();
    }
  },
});
