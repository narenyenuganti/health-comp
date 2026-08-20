import { assertEquals } from "@std/assert";

const functionsURL = Deno.env.get("HEALTHCOMP_TEST_FUNCTIONS_URL") ??
  "http://127.0.0.1:54321/functions/v1";

Deno.test("local Edge Runtime boots the score endpoint before request validation", async () => {
  const endpoint = new URL("submit-score-revision", `${functionsURL}/`);
  if (!["127.0.0.1", "localhost", "::1"].includes(endpoint.hostname)) {
    throw new Error(
      "score boot probe requires a disposable local Edge Runtime",
    );
  }

  const response = await fetch(endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: "{}",
    signal: AbortSignal.timeout(10_000),
  });

  assertEquals(response.status, 400);
  assertEquals(await response.json(), {
    error: {
      code: "invalid_request",
      message: "Invalid score revision",
    },
  });
});
