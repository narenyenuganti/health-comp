const APP_ID_PATTERN = /^[A-Z0-9]{10}\.[A-Za-z0-9][A-Za-z0-9.-]{0,254}$/;

const successHeaders = {
  "cache-control": "public, max-age=3600, s-maxage=3600",
  "content-type": "application/json",
  "x-content-type-options": "nosniff",
};

function validAppIDs(appIDs: readonly string[]): boolean {
  return appIDs.length > 0 &&
    new Set(appIDs).size === appIDs.length &&
    appIDs.every((appID) => APP_ID_PATTERN.test(appID));
}

export function configuredAppIDs(
  value: string | undefined,
): readonly string[] {
  if (!value) return [];
  return value.split(",").map((entry) => entry.trim()).filter(Boolean);
}

export function appleAppSiteAssociationHandler(
  request: Request,
  appIDs: readonly string[],
): Response {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("Method not allowed", {
      status: 405,
      headers: {
        allow: "GET, HEAD",
        "cache-control": "no-store",
        "content-type": "text/plain; charset=utf-8",
      },
    });
  }

  if (!validAppIDs(appIDs)) {
    return new Response("Association unavailable", {
      status: 503,
      headers: {
        "cache-control": "no-store",
        "content-type": "text/plain; charset=utf-8",
      },
    });
  }

  const body = JSON.stringify({
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
  return new Response(request.method === "HEAD" ? null : body, {
    status: 200,
    headers: successHeaders,
  });
}

if (import.meta.main) {
  const appIDs = configuredAppIDs(
    Deno.env.get("HEALTHCOMP_AASA_APP_IDS"),
  );
  Deno.serve((request) =>
    appleAppSiteAssociationHandler(request, appIDs)
  );
}
