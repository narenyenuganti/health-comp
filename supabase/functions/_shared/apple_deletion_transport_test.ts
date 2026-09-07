import { assert, assertEquals, assertRejects } from "@std/assert";
import { createAppleDeletionTransport } from "./apple_deletion_transport.ts";

Deno.test("deletion transport preserves requests and owns their lifetime", async () => {
  let signal: AbortSignal | undefined | null;
  const scope = createAppleDeletionTransport((input, init) => {
    assertEquals(input, "https://example.invalid/rpc");
    assertEquals(init?.method, "POST");
    assertEquals(init?.body, "synthetic-body");
    signal = init?.signal;
    return Promise.resolve(new Response("ok"));
  });
  try {
    const response = await scope.fetch("https://example.invalid/rpc", {
      method: "POST",
      body: "synthetic-body",
    });
    assertEquals(await response.text(), "ok");
    assert(signal);
    assertEquals(signal.aborted, false);
  } finally {
    scope.close();
  }
  assertEquals(signal?.aborted, true);
  await assertRejects(() => scope.fetch("https://example.invalid/rpc"));
});

Deno.test("deletion transport stops admission for a cancelled caller signal", async () => {
  let calls = 0;
  const scope = createAppleDeletionTransport(() => {
    calls++;
    return Promise.resolve(new Response());
  });
  const abort = new AbortController();
  abort.abort();
  try {
    await assertRejects(() =>
      scope.fetch("https://example.invalid", { signal: abort.signal })
    );
    await assertRejects(() =>
      scope.fetch(
        new Request("https://example.invalid", { signal: abort.signal }),
      )
    );
    assertEquals(calls, 0);
  } finally {
    scope.close();
  }
});

Deno.test("deletion transport applies one shared deadline and rejects later requests", async () => {
  let calls = 0;
  const scope = createAppleDeletionTransport((_input, init) => {
    calls++;
    assert(init?.signal);
    return new Promise<Response>((_resolve, reject) => {
      init.signal!.addEventListener(
        "abort",
        () => reject(new Error("synthetic aborted transport")),
        { once: true },
      );
    });
  }, 10);
  try {
    await assertRejects(() => scope.fetch("https://example.invalid"));
    assertEquals(scope.expired, true);
    await assertRejects(() => scope.fetch("https://example.invalid/later"));
    assertEquals(calls, 1);
  } finally {
    scope.close();
  }
});
