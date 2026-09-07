import { assertEquals, assertRejects } from "@std/assert";
import { readAppleDeletionBody } from "./apple_deletion_body.ts";

Deno.test("deletion body accepts chunked bytes at its exact limit", async () => {
  const request = new Request("https://example.invalid", {
    method: "POST",
    body: new ReadableStream({
      start(controller) {
        controller.enqueue(new Uint8Array([1, 2]));
        controller.enqueue(new Uint8Array());
        controller.enqueue(new Uint8Array([3]));
        controller.close();
      },
    }),
  });
  assertEquals(
    await readAppleDeletionBody(request, 3),
    new Uint8Array([1, 2, 3]),
  );
});

Deno.test("deletion body cancels an oversized stream without waiting for producer cleanup", async () => {
  let cancelled = false;
  const request = new Request("https://example.invalid", {
    method: "POST",
    body: new ReadableStream({
      start(controller) {
        controller.enqueue(new Uint8Array(4));
      },
      cancel() {
        cancelled = true;
        return new Promise<void>(() => {});
      },
    }),
  });
  await assertRejects(() => readAppleDeletionBody(request, 3));
  assertEquals(cancelled, true);
  assertEquals(request.body?.locked, false);
});

Deno.test("deletion body ends an idle read at its deadline", async () => {
  let cancelled = false;
  const request = new Request("https://example.invalid", {
    method: "POST",
    body: new ReadableStream({
      cancel() {
        cancelled = true;
      },
    }),
  });
  await assertRejects(() => readAppleDeletionBody(request, 10, 10));
  assertEquals(cancelled, true);
  assertEquals(request.body?.locked, false);
});

Deno.test("deletion body observes request cancellation", async () => {
  const abort = new AbortController();
  const request = new Request("https://example.invalid", {
    method: "POST",
    signal: abort.signal,
    body: new ReadableStream({
      pull() {
        abort.abort();
      },
    }),
  });
  await assertRejects(() => readAppleDeletionBody(request, 10));
  assertEquals(request.body?.locked, false);
});

Deno.test("deletion body rejects a missing body and invalid bounds", async () => {
  await assertRejects(() =>
    readAppleDeletionBody(new Request("https://example.invalid"), 10)
  );
  await assertRejects(() =>
    readAppleDeletionBody(
      new Request("https://example.invalid", { method: "POST", body: "x" }),
      -1,
    )
  );
});
