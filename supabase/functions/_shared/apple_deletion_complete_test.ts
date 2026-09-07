import { assertEquals } from "@std/assert";
import { DeletionPhase } from "../delete-account/index.ts";
import {
  AppleDeletionWebCompleteDependencies,
  appleDeletionWebCompleteHandler,
} from "./apple_deletion_complete.ts";

const requestID = "a".repeat(64);
const verifier = "b".repeat(64);
const nonce = "c".repeat(64);
const clientID = "com.example.web";

Deno.test("cancelled browser completion body never begins deletion", async () => {
  const abort = new AbortController();
  abort.abort();
  const { deps, calls } = fixture();
  deps.deletion.begin = () => {
    calls.push("begin");
    return Promise.reject(new Error("unexpected deletion begin"));
  };
  const response = await appleDeletionWebCompleteHandler(
    new Request(request(), { signal: abort.signal }),
    deps,
  );
  assertEquals(response.status, 400);
  assertEquals(await response.text(), "");
  assertEquals(calls, []);
});
const redirectURI =
  "https://example.invalid/functions/v1/apple-deletion-callback";
function request(
  body: unknown = { request_id: requestID, claim_verifier: verifier },
  bearer = "Bearer synthetic",
) {
  return new Request("https://example.invalid/complete", {
    method: "POST",
    headers: { authorization: bearer, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}
function fixture(initial: DeletionPhase = "prepared") {
  const calls: string[] = [];
  const progress = (phase: DeletionPhase) => ({
    profileId: "synthetic-profile",
    phase,
    appleProviderId: "synthetic-apple-subject",
    authUserId: "synthetic-user",
    appleClientId: clientID,
  });
  const deps: AppleDeletionWebCompleteDependencies = {
    deletion: {
      appleClientID: "com.example.native",
      now: () => new Date(0),
      authenticate: () => Promise.resolve("synthetic-user"),
      begin: () => Promise.resolve(progress(initial)),
      exchangeAuthorizationCode: () =>
        Promise.reject(new Error("native exchange forbidden")),
      storeAppleToken: (_id, _token, bound) => {
        assertEquals(bound, clientID);
        calls.push("store");
        return Promise.resolve(progress("token_ready"));
      },
      loadAppleToken: () => Promise.resolve("synthetic-refresh-token"),
      revokeAppleToken: (_token, bound) => {
        assertEquals(bound, clientID);
        calls.push("revoke");
        return Promise.resolve();
      },
      markAppleRevoked: () => Promise.resolve(progress("apple_revoked")),
      anonymize: () => Promise.resolve(progress("auth_delete_pending")),
      deleteAuthUser: () => {
        calls.push("delete");
        return Promise.resolve();
      },
      complete: () => Promise.resolve(progress("completed")),
    },
    claim: async (user, id, digest) => {
      assertEquals(user, "synthetic-user");
      assertEquals(id, requestID);
      const hash = new Uint8Array(
        await crypto.subtle.digest(
          "SHA-256",
          new TextEncoder().encode(verifier),
        ),
      );
      assertEquals(
        digest,
        [...hash].map((b) => b.toString(16).padStart(2, "0")).join(""),
      );
      calls.push("claim");
      return {
        authorizationCode: "synthetic-apple-code",
        clientID,
        redirectURI,
        nonce,
      };
    },
    webClient: () => ({
      clientID,
      redirectURI,
      exchange: (code) => {
        assertEquals(code, "synthetic-apple-code");
        calls.push("exchange");
        const payload = btoa(
          JSON.stringify({
            iss: "https://appleid.apple.com",
            sub: "synthetic-apple-subject",
            aud: clientID,
            nonce,
            exp: 600,
          }),
        );
        return Promise.resolve({
          refreshToken: "synthetic-refresh-token",
          idToken: `e30.${payload}.synthetic`,
        });
      },
    }),
  };
  return { deps, calls };
}

Deno.test("web completion claims once and runs the real shared deletion workflow", async () => {
  const { deps, calls } = fixture();
  const response = await appleDeletionWebCompleteHandler(request(), deps);
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { status: "deleted" });
  assertEquals(calls, ["claim", "exchange", "store", "revoke", "delete"]);
});
Deno.test("web completion retry skips consumed claim and exchange after token storage", async () => {
  const { deps, calls } = fixture("token_ready");
  const response = await appleDeletionWebCompleteHandler(request(), deps);
  assertEquals(response.status, 200);
  assertEquals(calls, ["revoke", "delete"]);
});
Deno.test("web completion can resume after in-memory claim data is lost", async () => {
  const { deps, calls } = fixture("token_ready");
  const response = await appleDeletionWebCompleteHandler(
    request({ resume: true }),
    deps,
  );
  assertEquals(response.status, 200);
  assertEquals(calls, ["revoke", "delete"]);
  const fresh = fixture("prepared");
  assertEquals(
    (await appleDeletionWebCompleteHandler(
      request({ resume: true }),
      fresh.deps,
    )).status,
    401,
  );
  assertEquals(fresh.calls, []);
});

Deno.test("web completion requires authenticated identity before claiming", async () => {
  const { deps, calls } = fixture();
  deps.deletion.authenticate = () => Promise.reject(new Error("denied"));
  assertEquals(
    (await appleDeletionWebCompleteHandler(request(), deps)).status,
    401,
  );
  assertEquals(calls, []);
});
Deno.test("web completion refuses a missing claim and mismatched server binding", async () => {
  for (
    const claim of [null, {
      authorizationCode: "synthetic-apple-code",
      nonce,
      clientID: "other-client",
      redirectURI,
    }]
  ) {
    const { deps, calls } = fixture();
    deps.claim = () => Promise.resolve(claim);
    assertEquals(
      (await appleDeletionWebCompleteHandler(request(), deps)).status,
      401,
    );
    assertEquals(calls, []);
  }
});
Deno.test("web completion rejects expansive request bodies before deletion begins", async () => {
  const { deps, calls } = fixture();
  deps.deletion.begin = () => {
    calls.push("begin");
    return Promise.reject(new Error("must not begin"));
  };
  const response = await appleDeletionWebCompleteHandler(
    request({
      request_id: requestID,
      claim_verifier: verifier,
      auth_user_id: "other",
    }),
    deps,
  );
  assertEquals(response.status, 400);
  assertEquals(calls, []);
});
