import { assertEquals } from "@std/assert";
import { containsFingerprint } from "../_shared/scoring_http.ts";
import { type ScoringRpcClient, submitScoreRevisionHandler } from "./index.ts";

const valid = {
  version: 1,
  competitionId: "63000000-0000-0000-0000-000000000001",
  semanticEventId: "64000000-0000-4000-8000-000000000001",
  dayOrdinal: 1,
  clientRevision: "9007199254740993",
  evaluatedAt: "2026-08-12T12:00:00Z",
  moveMode: "activeEnergyKilocalories",
  standMode: "standHours",
  moveBasisPoints: 10000,
  exerciseBasisPoints: 5000,
  standBasisPoints: 12500,
  availabilityReason: "available",
  scoringPolicyIdentity: "healthcomp.activity-score.v1",
  wireContentSHA256:
    "37df3f48a20b0b6e042e2450241af9c84ec7696ee505b97d9052dc201afb7fd9",
};
function req(body: unknown) {
  return new Request("http://local/submit", {
    method: "POST",
    headers: { authorization: "Bearer jwt" },
    body: JSON.stringify(body),
  });
}
function client(
  call: (name: string, args: Record<string, unknown>) => void,
): ScoringRpcClient {
  return {
    auth: {
      getUser: () =>
        Promise.resolve({ data: { user: { id: "u" } }, error: null }),
    },
    rpc: (name, args) => {
      call(name, args);
      return Promise.resolve({
        data: {
          disposition: "appended",
          acceptedCentiPoints: 27500,
          wireContentSHA256: valid.wireContentSHA256,
          acceptedServerSeq: "3",
          competitionCursor: "9",
        },
        error: null,
      });
    },
  };
}
Deno.test("submit validates v1 and sends bigint strings without participant or points", async () => {
  let args: Record<string, unknown> = {};
  const response = await submitScoreRevisionHandler(req(valid), {
    createUserClient: () => client((_n, a) => args = a),
  });
  assertEquals(response.status, 200);
  assertEquals(args.client_revision, "9007199254740993");
  assertEquals("participant_profile_id" in args, false);
  assertEquals("accepted_centi_points" in args, false);
  assertEquals(args.expected_wire_content_sha256, valid.wireContentSHA256);
});
Deno.test("submit rejects recursive extras fingerprints malformed IDs and numeric bigints", async () => {
  for (
    const body of [
      { ...valid, participantId: valid.competitionId },
      { ...valid, clientRevision: 1 },
      { ...valid, semanticEventId: "64000000-0000-4000-8000-00000000000A" },
      {
        ...valid,
        extra: { activitySnapshotFingerprint: "activity-snapshot:secret" },
      },
      { ...valid, opaque: "YWN0aXZpdHktc25hcHNob3Q6c2VjcmV0" },
      { ...valid, moveBasisPoints: 20001 },
      { ...valid, standMode: "unknown" },
    ]
  ) {
    assertEquals(
      (await submitScoreRevisionHandler(req(body), {
        createUserClient: () => {
          throw new Error("no auth");
        },
      })).status,
      400,
    );
  }
});
Deno.test("submit maps privacy and typed database errors", async () => {
  const response = await submitScoreRevisionHandler(req(valid), {
    createUserClient: () => ({
      auth: {
        getUser: () =>
          Promise.resolve({ data: { user: { id: "u" } }, error: null }),
      },
      rpc: () =>
        Promise.resolve({
          data: null,
          error: { message: "competition_not_found", code: "P0002" },
        }),
    }),
  });
  assertEquals(response.status, 404);
  assertEquals((await response.json()).error.code, "competition_not_found");
});
Deno.test("submit requires and preserves the canonical typed conflict response", async () => {
  const canonical = {
    disposition: "rejected",
    code: "revision_regression",
    acceptedCentiPoints: 27500,
    wireContentSHA256: valid.wireContentSHA256,
    acceptedServerSeq: "3",
    competitionCursor: "9",
  };
  for (
    const [data, status] of [[canonical, 409], [{
      disposition: "rejected",
      code: "revision_regression",
    }, 503]] as const
  ) {
    const response = await submitScoreRevisionHandler(req(valid), {
      createUserClient: () => ({
        auth: {
          getUser: () =>
            Promise.resolve({ data: { user: { id: "u" } }, error: null }),
        },
        rpc: () => Promise.resolve({ data, error: null }),
      }),
    });
    assertEquals(response.status, status);
    if (status === 409) assertEquals(await response.json(), canonical);
  }
});

Deno.test("every frozen invalid privacy and digest-mutation vector is executable", async () => {
  const fixture = JSON.parse(
    await Deno.readTextFile(
      new URL("../../tests/fixtures/scoring-v1.json", import.meta.url),
    ),
  );
  const selected = fixture.vectors.filter((v: { kind: string }) =>
    ["invalid_wire", "privacy", "digest_mutation"].includes(v.kind)
  );
  assertEquals(selected.length, 19);
  const privacy = selected.filter((vector: { kind: string }) =>
    vector.kind === "privacy"
  );
  assertEquals(privacy.length, 5);
  for (const vector of privacy) {
    assertEquals(containsFingerprint(vector.value), true, vector.name);
  }
  assertEquals(containsFingerprint("benign-wire-digest-value"), false);
  for (const vector of selected) {
    const candidate: Record<string, unknown> = { ...valid };
    if (vector.kind === "privacy") candidate.probe = vector.value;
    if (vector.kind === "invalid_wire") {
      if (vector.field === "move_basis_points") {
        candidate.moveBasisPoints = vector.value;
      } else if (vector.field === "accepted_centi_points") {
        candidate.acceptedCentiPoints = vector.value;
      } else candidate.scoringPolicyIdentity = vector.value;
    }
    if (vector.kind === "digest_mutation") {
      const mapping: Record<string, string> = {
        competition_id: "competitionId",
        participant_id: "participantId",
        day_ordinal: "dayOrdinal",
        move_mode: "moveMode",
        stand_mode: "standMode",
        move_basis_points: "moveBasisPoints",
        exercise_basis_points: "exerciseBasisPoints",
        stand_basis_points: "standBasisPoints",
        availability_reason: "availabilityReason",
        policy_identity: "scoringPolicyIdentity",
        client_revision: "clientRevision",
      };
      const key = mapping[vector.field];
      candidate[key] = key.endsWith("Id")
        ? "00000000-0000-4000-8000-000000000099"
        : key.includes("BasisPoints") || key === "dayOrdinal"
        ? 2
        : key === "clientRevision"
        ? "8"
        : "mutated";
    }
    const response = await submitScoreRevisionHandler(req(candidate), {
      createUserClient: () =>
        vector.kind === "digest_mutation"
          ? {
            auth: {
              getUser: () =>
                Promise.resolve({ data: { user: { id: "u" } }, error: null }),
            },
            rpc: () =>
              Promise.resolve({
                data: null,
                error: { message: "wire_digest_mismatch", code: "22023" },
              }),
          }
          : client(() => {}),
    });
    assertEquals(response.status >= 400, true, vector.name);
  }
});
