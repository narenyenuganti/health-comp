import { assertEquals, assertRejects } from "@std/assert";
import {
  AppleDeletionCallbackError,
  appleDeletionCallbackHandler,
  readAppleDeletionCallback,
} from "./apple_deletion_callback.ts";

const state = "a".repeat(64);
const code = "synthetic-apple-code";
const requestID = "b".repeat(64);

Deno.test("cancelled callback body never reaches code escrow", async () => {
  const abort = new AbortController();
  abort.abort();
  let stores = 0;
  const response = await appleDeletionCallbackHandler(
    new Request(callback(`state=${state}&code=${code}`), {
      signal: abort.signal,
    }),
    {
      receive: () => {
        stores++;
        return Promise.resolve({ requestID });
      },
    },
  );
  assertEquals(response.status, 400);
  assertEquals(await response.text(), "");
  assertEquals(response.headers.get("location"), null);
  assertEquals(stores, 0);
});

Deno.test("callback returns only an opaque handle after storage accepts the response", async () => {
  const response = await appleDeletionCallbackHandler(
    callback(`state=${state}&code=${code}`),
    {
      receive: (value) => {
        assertEquals(value, { kind: "authorized", state, code });
        return Promise.resolve({ requestID });
      },
    },
  );
  assertEquals(response.status, 303);
  assertEquals(
    response.headers.get("location"),
    `healthcomp-staging-auth://apple/deletion-callback?request_id=${requestID}`,
  );
  assertEquals(response.headers.get("cache-control"), "no-store");
  assertEquals(response.headers.get("referrer-policy"), "no-referrer");
  assertEquals(await response.text(), "");
});

Deno.test("callback cancellation goes through the same state validation", async () => {
  const response = await appleDeletionCallbackHandler(
    callback(`state=${state}&error=user_cancelled_authorize`),
    {
      receive: (value) => {
        assertEquals(value, { kind: "cancelled", state });
        return Promise.resolve({ requestID });
      },
    },
  );
  assertEquals(response.status, 303);
});

Deno.test("callback never redirects rejected state or malformed storage handles", async () => {
  for (const result of [null, { requestID: "unexpected-private-identifier" }]) {
    const response = await appleDeletionCallbackHandler(
      callback(`state=${state}&code=${code}`),
      {
        receive: () => Promise.resolve(result),
      },
    );
    assertEquals(response.headers.get("location"), null);
    assertEquals(response.status, result === null ? 400 : 503);
    assertEquals(await response.text(), "");
  }
});

Deno.test("callback does not pass malformed inputs to storage or disclose storage errors", async () => {
  let calls = 0;
  const store = {
    receive: () => {
      calls++;
      return Promise.reject(new Error("private synthetic detail"));
    },
  };
  const rejected = await appleDeletionCallbackHandler(
    callback(`state=${state}`),
    store,
  );
  assertEquals(rejected.status, 400);
  assertEquals(calls, 0);
  const failed = await appleDeletionCallbackHandler(
    callback(`state=${state}&code=${code}`),
    store,
  );
  assertEquals(failed.status, 503);
  assertEquals(failed.headers.get("location"), null);
  assertEquals(await failed.text(), "");
  assertEquals(calls, 1);
});
function callback(body: string, type = "application/x-www-form-urlencoded") {
  return new Request("https://example.invalid/apple-deletion-callback", {
    method: "POST",
    headers: { "content-type": type },
    body,
  });
}

Deno.test("deletion callback reads code-only Apple response without session exchange", async () => {
  assertEquals(
    await readAppleDeletionCallback(callback(`state=${state}&code=${code}`)),
    { kind: "authorized", state, code },
  );
});

Deno.test("deletion callback recognizes cancellation without an authorization code", async () => {
  assertEquals(
    await readAppleDeletionCallback(
      callback(`state=${state}&error=user_cancelled_authorize`),
    ),
    { kind: "cancelled", state },
  );
});

Deno.test("deletion callback rejects ambiguous or unexpected response fields", async () => {
  for (
    const body of [
      `state=${state}&code=${code}&code=${code}`,
      `state=${state}&state=${state}&code=${code}`,
      `state=${state}&code=${code}&error=user_cancelled_authorize`,
      `state=${state}&code=${code}&id_token=unrequested`,
      `state=${state}&code=${code}&user=unrequested`,
      `state=${state}&code=`,
      `code=${code}`,
      `state=wrong-shape&code=${code}`,
      `state=${state}&error=unknown`,
      `state=${state}&code=${code}%0A`,
      `state=${state}&code=${code}%xx`,
      `state=${state}&code=${"c".repeat(4097)}`,
    ]
  ) {
    await assertRejects(
      () => readAppleDeletionCallback(callback(body)),
      AppleDeletionCallbackError,
      "invalid_apple_deletion_callback",
    );
  }
});

Deno.test("deletion callback rejects query and JSON delivery", async () => {
  await assertRejects(() =>
    readAppleDeletionCallback(
      new Request(
        `https://example.invalid/callback?state=${state}&code=${code}`,
      ),
    ), AppleDeletionCallbackError);
  await assertRejects(() =>
    readAppleDeletionCallback(callback(
      JSON.stringify({ state, code }),
      "application/json",
    )), AppleDeletionCallbackError);
});

Deno.test("deletion callback bounds streamed bytes without trusting content length", async () => {
  let cancelled = false;
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      controller.enqueue(new Uint8Array(8192).fill(97));
    },
    cancel() {
      cancelled = true;
    },
  });
  const request = new Request("https://example.invalid/callback", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  await assertRejects(
    () => readAppleDeletionCallback(request),
    AppleDeletionCallbackError,
  );
  assertEquals(cancelled, true);
});
