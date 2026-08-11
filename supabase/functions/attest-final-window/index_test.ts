import { assertEquals } from "@std/assert";
import { attestFinalWindowHandler, type ScoringRpcClient } from "./index.ts";
const body = {
  version: 1,
  competitionId: "63000000-0000-0000-0000-000000000001",
  semanticEventId: "65000000-0000-4000-8000-000000000001",
  attestationVersion: "2",
  basis: "stable",
  acceptedRevisions: ["1", "2", "3", "4", "5", "6", "7"],
  windowCommitmentSHA256:
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
};
Deno.test("attest sends only owner revision identities to the narrow RPC", async () => {
  let args: Record<string, unknown> = {};
  const client: ScoringRpcClient = {
    auth: {
      getUser: () =>
        Promise.resolve({ data: { user: { id: "u" } }, error: null }),
    },
    rpc: (_n, a) => {
      args = a;
      return Promise.resolve({
        data: { disposition: "appended" },
        error: null,
      });
    },
  };
  const response = await attestFinalWindowHandler(
    new Request("http://local/attest", {
      method: "POST",
      headers: { authorization: "Bearer x" },
      body: JSON.stringify(body),
    }),
    { createUserClient: () => client },
  );
  assertEquals(response.status, 200);
  assertEquals(args.accepted_revisions, body.acceptedRevisions);
  assertEquals(
    args.expected_window_commitment_sha256,
    body.windowCommitmentSHA256,
  );
  assertEquals("participantId" in args, false);
});
Deno.test("attest rejects missing zeros for stable and recursive extras", async () => {
  for (
    const invalid of [{
      ...body,
      acceptedRevisions: ["0", "2", "3", "4", "5", "6", "7"],
    }, { ...body, debug: { liveDayScore: "live-day-score:secret" } }]
  ) {
    const response = await attestFinalWindowHandler(
      new Request("http://local/attest", {
        method: "POST",
        headers: { authorization: "Bearer x" },
        body: JSON.stringify(invalid),
      }),
      {
        createUserClient: () => {
          throw new Error("no");
        },
      },
    );
    assertEquals(response.status, 400);
  }
});
