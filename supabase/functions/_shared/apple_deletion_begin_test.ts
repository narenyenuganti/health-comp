import { assert, assertEquals } from "@std/assert";
import {
  AppleDeletionWebBeginDependencies,
  appleDeletionWebBeginHandler,
  AppleDeletionWebBeginRecord,
} from "./apple_deletion_begin.ts";

const verifier = "c".repeat(64);
const nonce = "d".repeat(64);
const config = {
  clientID: "com.example.staging.web",
  projectURL: "https://example.invalid",
};

Deno.test("cancelled browser begin body never creates a grant", async () => {
  const abort = new AbortController();
  abort.abort();
  let stores = 0;
  const response = await appleDeletionWebBeginHandler(
    new Request(request(), { signal: abort.signal }),
    dependencies({
      begin: () => {
        stores++;
        return Promise.resolve();
      },
    }),
  );
  assertEquals(response.status, 400);
  assertEquals(await response.text(), "");
  assertEquals(stores, 0);
});
function request(
  body: unknown = { claim_verifier: verifier, nonce },
  bearer = "Bearer synthetic",
) {
  return new Request("https://example.invalid/begin", {
    method: "POST",
    headers: { authorization: bearer, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}
function dependencies(
  overrides: Partial<AppleDeletionWebBeginDependencies> = {},
): AppleDeletionWebBeginDependencies {
  return {
    authenticate: () => Promise.resolve("synthetic-authenticated-user"),
    configuration: () => config,
    begin: () => Promise.resolve(),
    ...overrides,
  };
}
async function digest(value: string) {
  const bytes = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
  );
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.test("web deletion begin binds authenticated identity and stores digests", async () => {
  const records: AppleDeletionWebBeginRecord[] = [];
  const response = await appleDeletionWebBeginHandler(
    request(),
    dependencies({
      begin: (record) => {
        records.push(record);
        return Promise.resolve();
      },
    }),
  );
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(Object.keys(body).sort(), ["authorization_url", "request_id"]);
  assert(/^[0-9a-f]{64}$/.test(body.request_id));
  const url = new URL(body.authorization_url);
  assertEquals(
    url.origin + url.pathname,
    "https://appleid.apple.com/auth/authorize",
  );
  assertEquals(url.searchParams.get("client_id"), config.clientID);
  assertEquals(
    url.searchParams.get("redirect_uri"),
    `${config.projectURL}/functions/v1/apple-deletion-callback`,
  );
  assertEquals(url.searchParams.get("response_type"), "code");
  assertEquals(url.searchParams.get("response_mode"), "form_post");
  assertEquals(url.searchParams.get("scope"), null);
  const state = url.searchParams.get("state")!;
  assert(/^[0-9a-f]{64}$/.test(state));
  assert(state !== body.request_id);
  assertEquals(records, [{
    authUserID: "synthetic-authenticated-user",
    requestID: body.request_id,
    stateDigest: await digest(state),
    verifierDigest: await digest(verifier),
    nonce,
    clientID: config.clientID,
    redirectURI: `${config.projectURL}/functions/v1/apple-deletion-callback`,
  }]);
  assertEquals(response.headers.get("cache-control"), "no-store");
});

Deno.test("web deletion begin requires authentication before configuration or storage", async () => {
  let otherCalls = 0;
  const deps = dependencies({
    authenticate: () => Promise.reject(new Error("synthetic denied")),
    configuration: () => {
      otherCalls++;
      return config;
    },
    begin: () => {
      otherCalls++;
      return Promise.resolve();
    },
  });
  assertEquals(
    (await appleDeletionWebBeginHandler(request(), deps)).status,
    401,
  );
  assertEquals(
    (await appleDeletionWebBeginHandler(request(undefined, ""), deps)).status,
    401,
  );
  assertEquals(otherCalls, 0);
});

Deno.test("web deletion begin rejects caller-supplied identity and configuration", async () => {
  let writes = 0;
  const deps = dependencies({
    begin: () => {
      writes++;
      return Promise.resolve();
    },
  });
  for (
    const extra of ["auth_user_id", "client_id", "redirect_uri", "request_id"]
  ) {
    const response = await appleDeletionWebBeginHandler(
      request({ claim_verifier: verifier, nonce, [extra]: "untrusted" }),
      deps,
    );
    assertEquals(response.status, 400);
  }
  assertEquals(writes, 0);
});

Deno.test("web deletion begin stays unavailable without valid server configuration", async () => {
  for (
    const configuration of [null, {
      ...config,
      projectURL: "http://example.invalid",
    }, { ...config, projectURL: "https://example.invalid/unexpected" }]
  ) {
    let writes = 0;
    const response = await appleDeletionWebBeginHandler(
      request(),
      dependencies({
        configuration: () => configuration,
        begin: () => {
          writes++;
          return Promise.resolve();
        },
      }),
    );
    assertEquals(response.status, 503);
    assertEquals(writes, 0);
  }
});

Deno.test("web deletion begin returns no authorization URL if durable preparation fails", async () => {
  const response = await appleDeletionWebBeginHandler(
    request(),
    dependencies({
      begin: () => Promise.reject(new Error("private synthetic detail")),
    }),
  );
  assertEquals(response.status, 503);
  assertEquals(await response.text(), "");
});
