import { assert, assertEquals } from "@std/assert";
import { handler as begin } from "../apple-deletion-begin/index.ts";
import { handler as callback } from "../apple-deletion-callback/index.ts";
import { handler as complete } from "../apple-deletion-complete/index.ts";
import { LiveDependencyConfiguration } from "../delete-account/index.ts";

function configuration(
  overrides: Record<string, string> = {},
): LiveDependencyConfiguration {
  const values: Record<string, string> = {
    HEALTHCOMP_ENABLE_APPLE_WEB_SIGN_IN: "YES",
    SUPABASE_URL: "https://xhfdfdrtxwptrwhvvlhg.supabase.co",
    SUPABASE_ANON_KEY: "synthetic-anon-key",
    SUPABASE_SERVICE_ROLE_KEY: "synthetic-service-key",
    APPLE_SIGN_IN_CLIENT_ID: "com.example.native",
    APPLE_WEB_SIGN_IN_CLIENT_ID: "com.example.web",
    ...overrides,
  };
  return {
    environment: (name) => {
      if (!(name in values)) throw new Error("synthetic missing value");
      return values[name];
    },
    fetch: () => Promise.reject(new Error("network forbidden")),
  };
}

Deno.test("all deployable entrypoints fail closed without staging opt-in", async () => {
  for (const handler of [begin, callback, complete]) {
    const response = await handler(
      new Request("https://example.invalid"),
      configuration({ HEALTHCOMP_ENABLE_APPLE_WEB_SIGN_IN: "NO" }),
    );
    assertEquals(response.status, 503);
    assertEquals(await response.text(), "");
    assertEquals(response.headers.get("cache-control"), "no-store");
    assertEquals(response.headers.get("referrer-policy"), "no-referrer");
  }
});

Deno.test("entrypoints route to the corresponding real handler", async () => {
  for (const handler of [begin, complete]) {
    const response = await handler(
      new Request("https://example.invalid", { method: "POST", body: "{}" }),
      configuration(),
    );
    assertEquals(response.status, 401);
  }
  const response = await callback(
    new Request("https://example.invalid", { method: "POST", body: "{}" }),
    configuration(),
  );
  assertEquals(response.status, 400);
});

Deno.test("entrypoints suppress configuration failure details", async () => {
  for (const handler of [begin, callback, complete]) {
    const configured = configuration();
    const environment = configured.environment;
    configured.environment = (name) => {
      if (name === "SUPABASE_SERVICE_ROLE_KEY") {
        throw new Error("synthetic private configuration detail");
      }
      return environment(name);
    };
    const response = await handler(
      new Request("https://example.invalid"),
      configured,
    );
    assertEquals(response.status, 503);
    assertEquals(await response.text(), "");
  }
});

Deno.test("endpoint retires the transport signals after real Auth and RPC routing", async () => {
  const configured = configuration();
  const signals: AbortSignal[] = [];
  configured.fetch = (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    const signal = init?.signal ??
      (input instanceof Request ? input.signal : null);
    assert(signal);
    signals.push(signal);
    if (url.pathname === "/auth/v1/user") {
      return Promise.resolve(
        Response.json({ id: "f1000000-0000-4000-8000-000000000001" }),
      );
    }
    assertEquals(url.pathname, "/rest/v1/rpc/begin_apple_deletion_web_request");
    return Promise.resolve(new Response(null, { status: 204 }));
  };
  const response = await begin(
    new Request("https://example.invalid", {
      method: "POST",
      headers: {
        authorization: "Bearer synthetic",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        nonce: "a".repeat(64),
        claim_verifier: "b".repeat(64),
      }),
    }),
    configured,
  );
  assertEquals(response.status, 200);
  assertEquals(signals.length, 2);
  assert(signals.every((signal) => signal.aborted));
});
