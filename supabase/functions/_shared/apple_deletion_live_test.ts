import { assert, assertEquals } from "@std/assert";
import { createAppleDeletionWebHandlers } from "./apple_deletion_live.ts";

const projectURL = "https://xhfdfdrtxwptrwhvvlhg.supabase.co";
const env: Record<string, string> = {
  HEALTHCOMP_ENABLE_APPLE_WEB_SIGN_IN: "YES",
  SUPABASE_URL: projectURL,
  APPLE_WEB_SIGN_IN_CLIENT_ID: "com.example.staging.web",
  APPLE_SIGN_IN_CLIENT_ID: "com.example.staging.native",
  SUPABASE_ANON_KEY: "synthetic-anon",
  SUPABASE_SERVICE_ROLE_KEY: "synthetic-service",
};

Deno.test("web deletion factory completes and resumes using the bound web signing client", async () => {
  const keys = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const keyBytes = new Uint8Array(
    await crypto.subtle.exportKey("pkcs8", keys.privateKey),
  );
  const pem = `-----BEGIN PRIVATE KEY-----\n${
    btoa(String.fromCharCode(...keyBytes))
  }\n-----END PRIVATE KEY-----`;
  const values = {
    ...env,
    APPLE_SIGN_IN_KEY_ID: "SYNTHETIC1",
    APPLE_SIGN_IN_TEAM_ID: "SYNTHETIC2",
    APPLE_SIGN_IN_PRIVATE_KEY: pem,
  };
  const user = "f1000000-0000-4000-8000-000000000001";
  const profile = "f2000000-0000-4000-8000-000000000001";
  const nonce = "d".repeat(64);
  const webClient = env.APPLE_WEB_SIGN_IN_CLIENT_ID;
  const redirect = `${projectURL}/functions/v1/apple-deletion-callback`;
  const progress = (phase: string) => ({
    profile_id: profile,
    phase,
    auth_user_id: user,
    apple_provider_id: "synthetic-apple-subject",
    apple_client_id: webClient,
  });
  for (const resume of [false, true]) {
    const paths: string[] = [];
    const handlers = createAppleDeletionWebHandlers({
      environment: (n) => (values as Record<string, string>)[n] ?? "",
      fetch: async (input, init) => {
        const req = new Request(input, init);
        const url = new URL(req.url);
        paths.push(url.pathname);
        if (url.hostname === "appleid.apple.com") {
          const form = new URLSearchParams(await req.text());
          assertEquals(form.get("client_id"), webClient);
          const jwt = form.get("client_secret")!;
          const parts = jwt.split(".");
          const decode = (value: string) =>
            Uint8Array.from(
              atob(value.replaceAll("-", "+").replaceAll("_", "/")),
              (c) => c.charCodeAt(0),
            );
          const claims = JSON.parse(new TextDecoder().decode(decode(parts[1])));
          assertEquals(claims.sub, webClient);
          assert(
            await crypto.subtle.verify(
              { name: "ECDSA", hash: "SHA-256" },
              keys.publicKey,
              decode(parts[2]),
              new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
            ),
          );
          if (url.pathname === "/auth/token") {
            assertEquals(form.get("redirect_uri"), redirect);
            assertEquals(form.get("code"), "synthetic-web-code");
            const payload = btoa(
              JSON.stringify({
                iss: "https://appleid.apple.com",
                sub: "synthetic-apple-subject",
                aud: webClient,
                nonce,
                exp: Math.floor(Date.now() / 1000) + 300,
              }),
            );
            return Response.json({
              refresh_token: "synthetic-refresh-token",
              id_token: `e30.${payload}.synthetic`,
            });
          }
          assertEquals(url.pathname, "/auth/revoke");
          assertEquals(form.get("redirect_uri"), null);
          assertEquals(form.get("token"), "synthetic-refresh-token");
          return new Response(null, { status: 200 });
        }
        if (url.pathname === "/auth/v1/user") {
          return Response.json({ id: user });
        }
        if (url.pathname === `/auth/v1/admin/users/${user}`) {
          assertEquals(req.method, "DELETE");
          return Response.json({ id: user });
        }
        const body = await req.json();
        const name = url.pathname.split("/").at(-1);
        if (name === "begin_account_deletion") {
          return Response.json(progress(resume ? "token_ready" : "prepared"));
        }
        if (name === "claim_apple_deletion_web_request") {
          assertEquals(body.target_auth_user_id, user);
          return Response.json({
            authorization_code: "synthetic-web-code",
            apple_client_id: webClient,
            redirect_uri: redirect,
            nonce,
          });
        }
        if (name === "store_account_deletion_apple_token") {
          assertEquals(body.apple_client_id, webClient);
          assertEquals(body.refresh_token, "synthetic-refresh-token");
          return Response.json(progress("token_ready"));
        }
        if (name === "load_account_deletion_apple_token") {
          return Response.json("synthetic-refresh-token");
        }
        if (name === "mark_account_deletion_apple_revoked") {
          return Response.json(progress("apple_revoked"));
        }
        if (name === "anonymize_account_deletion") {
          return Response.json(progress("auth_delete_pending"));
        }
        if (name === "complete_account_deletion") {
          return Response.json(progress("completed"));
        }
        throw new Error("unexpected synthetic route");
      },
    });
    assert(handlers);
    const response = await handlers.complete(
      new Request(`${projectURL}/complete`, {
        method: "POST",
        headers: {
          authorization: "Bearer synthetic-user",
          "content-type": "application/json",
        },
        body: JSON.stringify(
          resume
            ? { resume: true }
            : { request_id: "a".repeat(64), claim_verifier: "c".repeat(64) },
        ),
      }),
    );
    assertEquals(response.status, 200);
    assertEquals(await response.json(), { status: "deleted" });
    const rpc = (name: string) => `/rest/v1/rpc/${name}`;
    assertEquals(paths, [
      "/auth/v1/user",
      rpc("begin_account_deletion"),
      ...(resume ? [] : [
        rpc("claim_apple_deletion_web_request"),
        "/auth/token",
        rpc("store_account_deletion_apple_token"),
      ]),
      rpc("load_account_deletion_apple_token"),
      "/auth/revoke",
      rpc("mark_account_deletion_apple_revoked"),
      rpc("anonymize_account_deletion"),
      `/auth/v1/admin/users/${user}`,
      rpc("complete_account_deletion"),
    ]);
  }
});
Deno.test("web deletion live factory remains unavailable outside opted-in exact staging", () => {
  for (
    const override of [{ HEALTHCOMP_ENABLE_APPLE_WEB_SIGN_IN: "NO" }, {
      SUPABASE_URL: "https://production.example.invalid",
    }, { APPLE_WEB_SIGN_IN_CLIENT_ID: "" }]
  ) {
    const values: Record<string, string | undefined> = { ...env, ...override };
    assertEquals(
      createAppleDeletionWebHandlers({
        environment: (n) => values[n] ?? "",
        fetch: () => Promise.reject(new Error("no network allowed")),
      }),
      null,
    );
  }
});
Deno.test("web deletion live factory maps authenticated begin and callback to actual SDK RPCs", async () => {
  const bodies: Record<string, unknown>[] = [];
  const paths: string[] = [];
  const handlers = createAppleDeletionWebHandlers({
    environment: (n) => {
      if (
        n.includes("PRIVATE_KEY") || n.includes("KEY_ID") ||
        n.includes("TEAM_ID")
      ) throw new Error("Apple secret read too early");
      return env[n] ?? "";
    },
    fetch: async (input, init) => {
      const req = new Request(input, init);
      const path = new URL(req.url).pathname;
      paths.push(path);
      if (path === "/auth/v1/user") {
        return Response.json({ id: "synthetic-user" });
      }
      bodies.push(await req.json());
      if (path.endsWith("begin_apple_deletion_web_request")) {
        return Response.json(null);
      }
      if (path.endsWith("receive_apple_deletion_web_callback")) {
        return Response.json(bodies[0].request_id);
      }
      throw new Error("unexpected request path");
    },
  });
  assert(handlers);
  const response = await handlers.begin(
    new Request(`${projectURL}/begin`, {
      method: "POST",
      headers: {
        authorization: "Bearer synthetic-user",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        claim_verifier: "c".repeat(64),
        nonce: "d".repeat(64),
      }),
    }),
  );
  assertEquals(response.status, 200);
  const result = await response.json();
  const state = new URL(result.authorization_url).searchParams.get("state")!;
  const callback = await handlers.callback(
    new Request(`${projectURL}/callback`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ state, code: "synthetic-apple-code" }),
    }),
  );
  assertEquals(callback.status, 303);
  assertEquals(paths, [
    "/auth/v1/user",
    "/rest/v1/rpc/begin_apple_deletion_web_request",
    "/rest/v1/rpc/receive_apple_deletion_web_callback",
  ]);
  assertEquals(bodies[0].target_auth_user_id, "synthetic-user");
  assertEquals(bodies[0].apple_client_id, env.APPLE_WEB_SIGN_IN_CLIENT_ID);
  assertEquals(bodies[1].state_digest, bodies[0].state_digest);
  assertEquals(bodies[1].was_cancelled, false);
});
