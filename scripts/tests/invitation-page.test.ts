const fakeToken = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const fakeCode = "AAAAAAAAAAAAAAAAAAAAAA";

for (
  const { page, route, value } of [
    { page: "invite.html", route: "invite", value: fakeToken },
    { page: "challenge.html", route: "challenge", value: fakeCode },
  ]
) {
  const html = await Deno.readTextFile(
    new URL(`../../web/${page}`, import.meta.url),
  );
  const script = html.match(/<script>([\s\S]*?)<\/script>/)?.[1];
  if (!script) throw new Error(`${page} script is missing`);
  const pathPrefix = route === "invite" ? "/invite/" : "/c/";

  for (
    const { name, hostname, path, expectedHref } of [
      {
        name: `Production ${route} fallback opens Release`,
        hostname: "healthcomp.app",
        path: value,
        expectedHref: `healthcomp://${route}/${value}`,
      },
      {
        name: `Staging ${route} fallback opens Staging`,
        hostname: "staging.healthcomp.app",
        path: value,
        expectedHref: `healthcomp-staging://${route}/${value}`,
      },
      {
        name: `Website preview retains Production ${route} fallback`,
        hostname: "healthcomp-preview.pages.dev",
        path: value,
        expectedHref: `healthcomp://${route}/${value}`,
      },
      {
        name: `Malformed ${route} link does not expose an app link`,
        hostname: "staging.healthcomp.app",
        path: "short",
        expectedHref: null,
      },
      {
        name: `${route} page rejects the other link's length`,
        hostname: "healthcomp.app",
        path: value === fakeToken ? fakeCode : fakeToken,
        expectedHref: null,
      },
    ]
  ) {
    Deno.test(name, () => {
      const link = { href: null, hidden: true };
      const document = {
        getElementById: (id: string) => {
          if (id !== "open") throw new Error("Unexpected page element");
          return link;
        },
      };
      new Function("location", "document", script)(
        { hostname, pathname: `${pathPrefix}${path}` },
        document,
      );
      if (
        link.href !== expectedHref || link.hidden !== (expectedHref === null)
      ) {
        throw new Error(`Incorrect ${route} fallback for ${hostname}`);
      }
    });
  }
}
