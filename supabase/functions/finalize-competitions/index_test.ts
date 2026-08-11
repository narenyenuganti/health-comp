import { assertEquals } from "@std/assert";
import { finalizeCompetitionsHandler, type ScoringRpcClient } from "./index.ts";
Deno.test("scheduled finalizer is service-only and returns no ledger", async () => {
  let name = "";
  const client: ScoringRpcClient = {
    auth: {
      getUser: () => Promise.resolve({ data: { user: null }, error: null }),
    },
    rpc: (n) => {
      name = n;
      return Promise.resolve({ data: 3, error: null });
    },
  };
  const response = await finalizeCompetitionsHandler(
    new Request("http://local/finalize", {
      method: "POST",
      headers: {
        authorization: "Bearer service-role-jwt",
      },
      body: '{"batchSize":100}',
    }),
    {
      serviceAuthorization: "Bearer service-role-jwt",
      createServiceClient: () => client,
    },
  );
  assertEquals(response.status, 200);
  assertEquals(name, "finalize_due_competitions");
  assertEquals(await response.json(), { finalizedCount: "3" });
});
Deno.test("scheduled finalizer rejects a normal authenticated-user bearer before creating service client", async () => {
  for (const authorization of [undefined, "Bearer user-jwt"]) {
    const headers = authorization ? { authorization } : undefined;
    const response = await finalizeCompetitionsHandler(
      new Request("http://local/finalize", {
        method: "POST",
        headers,
        body: "{}",
      }),
      {
        serviceAuthorization: "Bearer service-role-jwt",
        createServiceClient: () => {
          throw new Error("no");
        },
      },
    );
    assertEquals(response.status, 401);
  }
});
