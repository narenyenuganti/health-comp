const html = await Deno.readTextFile(
  new URL("../../web/invite.html", import.meta.url),
);
const script = html.match(/<script>([\s\S]*?)<\/script>/)?.[1];
if (!script) throw new Error("Invitation page script is missing");

const fakeToken = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
for (
  const { name, hostname, token, expectedHref } of [
    {
      name: "Production invitation fallback opens Release",
      hostname: "healthcomp.app",
      token: fakeToken,
      expectedHref: `healthcomp://invite/${fakeToken}`,
    },
    {
      name: "Staging invitation fallback opens Staging",
      hostname: "staging.healthcomp.app",
      token: fakeToken,
      expectedHref: `healthcomp-staging://invite/${fakeToken}`,
    },
    {
      name: "Website preview retains Production fallback",
      hostname: "healthcomp-preview.pages.dev",
      token: fakeToken,
      expectedHref: `healthcomp://invite/${fakeToken}`,
    },
    {
      name: "Malformed invitation does not expose an app link",
      hostname: "staging.healthcomp.app",
      token: "short",
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
      { hostname, pathname: `/invite/${token}` },
      document,
    );
    if (link.href !== expectedHref || link.hidden !== (expectedHref === null)) {
      throw new Error(`Incorrect invitation fallback for ${hostname}`);
    }
  });
}
