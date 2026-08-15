import { assertEquals } from "@std/assert";
import { appleAppSiteAssociationHandler } from "./index.ts";

const appIDs = [
  "ABCDE12345.com.narenyenuganti.HealthComp",
  "ABCDE12345.com.narenyenuganti.HealthComp.staging",
];

Deno.test("AASA serves only the invite path with explicit cache and JSON headers", async () => {
  const response = appleAppSiteAssociationHandler(
    new Request(
      "https://invites.example/.well-known/apple-app-site-association",
    ),
    appIDs,
  );

  assertEquals(response.status, 200);
  assertEquals(response.headers.get("content-type"), "application/json");
  assertEquals(
    response.headers.get("cache-control"),
    "public, max-age=3600, s-maxage=3600",
  );
  assertEquals(await response.json(), {
    applinks: {
      details: [{
        appIDs,
        components: [{
          "/": "/invite/*",
          comment: "Matches private HealthComp invitation links.",
        }],
      }],
    },
  });
});

Deno.test("AASA HEAD mirrors headers without a response body", async () => {
  const response = appleAppSiteAssociationHandler(
    new Request(
      "https://invites.example/.well-known/apple-app-site-association",
      { method: "HEAD" },
    ),
    appIDs,
  );

  assertEquals(response.status, 200);
  assertEquals(await response.text(), "");
  assertEquals(response.headers.get("content-type"), "application/json");
});

Deno.test("AASA rejects methods and fails closed for invalid app identifiers", async () => {
  const methodResponse = appleAppSiteAssociationHandler(
    new Request(
      "https://invites.example/.well-known/apple-app-site-association",
      { method: "POST" },
    ),
    appIDs,
  );
  assertEquals(methodResponse.status, 405);
  assertEquals(methodResponse.headers.get("allow"), "GET, HEAD");

  for (
    const invalid of [
      [],
      [""],
      ["not-an-app-id"],
      ["abcde12345.com.narenyenuganti.HealthComp"],
      ["ABCDE12345.com.narenyenuganti.HealthComp", "not-an-app-id"],
    ]
  ) {
    const response = appleAppSiteAssociationHandler(
      new Request(
        "https://invites.example/.well-known/apple-app-site-association",
      ),
      invalid,
    );
    assertEquals(response.status, 503);
    assertEquals(await response.text(), "Association unavailable");
  }
});
