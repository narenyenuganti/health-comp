import { assertEquals } from "@std/assert";
import {
  competitionNotificationPayload,
  createApnsProviderToken,
  type NotificationRpcClient,
  type NotificationWorkerDependencies,
  sendCompetitionNotificationHandler,
} from "./index.ts";

function base64UrlBytes(value: string): Uint8Array<ArrayBuffer> {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/") +
    "=".repeat((4 - value.length % 4) % 4);
  const decoded = atob(normalized);
  const bytes = new Uint8Array(new ArrayBuffer(decoded.length));
  for (let index = 0; index < decoded.length; index += 1) {
    bytes[index] = decoded.charCodeAt(index);
  }
  return bytes;
}

function pemPrivateKey(pkcs8: ArrayBuffer): string {
  const bytes = new Uint8Array(pkcs8);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  const encoded = btoa(binary).match(/.{1,64}/g)?.join("\n") ?? "";
  return `-----BEGIN PRIVATE KEY-----\n${encoded}\n-----END PRIVATE KEY-----`;
}

const configuration = {
  keyId: "ABC123DEFG",
  teamId: "TEAM123456",
  topic: "com.narenyenuganti.HealthComp.staging",
  privateKey: "test-private-key",
};

const item = {
  workId: "c1000000-0000-4000-8000-000000000001",
  leaseToken: "c2000000-0000-4000-8000-000000000001",
  semanticId:
    "healthcomp.server-notification:v1:c3000000-0000-4000-8000-000000000001:score_update:7:c4000000-0000-4000-8000-000000000001:c5000000-0000-4000-8000-000000000001",
  competitionId: "c3000000-0000-4000-8000-000000000001",
  kind: "score_update" as const,
  apnsToken: "ab".repeat(32),
  environment: "sandbox" as const,
};
const workerAuthorization = `Bearer ${"w".repeat(43)}`;

function request(
  body = "{}",
  authorization = workerAuthorization,
): Request {
  return new Request("http://local/send-competition-notification", {
    method: "POST",
    headers: { authorization, "content-type": "application/json" },
    body,
  });
}

function dependencies(
  client: NotificationRpcClient,
  send: (request: Request) => Promise<Response> = () =>
    Promise.resolve(new Response(null, { status: 200 })),
): NotificationWorkerDependencies {
  return {
    workerAuthorization,
    configuration,
    createServiceClient: () => client,
    createProviderToken: () => Promise.resolve("provider-jwt"),
    send,
  };
}

Deno.test("notification worker is service-only before touching secrets or RPC", async () => {
  for (const authorization of [undefined, "Bearer wrong-worker-token"]) {
    const headers = authorization ? { authorization } : undefined;
    const response = await sendCompetitionNotificationHandler(
      new Request("http://local/send-competition-notification", {
        method: "POST",
        headers,
        body: "{}",
      }),
      {
        workerAuthorization,
        configuration: null,
        createServiceClient: () => {
          throw new Error("must not create a client");
        },
        createProviderToken: () => {
          throw new Error("must not sign");
        },
        send: () => {
          throw new Error("must not send");
        },
      },
    );
    assertEquals(response.status, 401);
  }
});

Deno.test("notification worker validates method and exact bounded body", async () => {
  const client: NotificationRpcClient = {
    rpc: () => {
      throw new Error("must not call RPC");
    },
  };
  const deps = dependencies(client);
  const method = await sendCompetitionNotificationHandler(
    new Request("http://local/send-competition-notification"),
    deps,
  );
  assertEquals(method.status, 405);

  for (
    const body of [
      "not-json",
      '{"batchSize":0}',
      '{"batchSize":null}',
      '{"batchSize":26}',
      '{"batchSize":101}',
      '{"batchSize":1,"unexpected":true}',
    ]
  ) {
    const response = await sendCompetitionNotificationHandler(
      request(body),
      deps,
    );
    assertEquals(response.status, 400);
  }
});

Deno.test("duplicate durable lease identities fail closed before APNs", async () => {
  let sends = 0;
  const client: NotificationRpcClient = {
    rpc: (name) => {
      if (name === "lease_competition_notification_work") {
        return Promise.resolve({
          data: { items: [item, { ...item }] },
          error: null,
        });
      }
      throw new Error("must not resolve malformed work");
    },
  };

  const response = await sendCompetitionNotificationHandler(
    request('{"batchSize":2}'),
    dependencies(client, () => {
      sends += 1;
      return Promise.resolve(new Response(null, { status: 200 }));
    }),
  );

  assertEquals(response.status, 502);
  assertEquals(sends, 0);
});

Deno.test("missing APNs configuration fails before leasing durable work", async () => {
  const response = await sendCompetitionNotificationHandler(request(), {
    workerAuthorization,
    configuration: null,
    createServiceClient: () => {
      throw new Error("must not create a client");
    },
    createProviderToken: () => {
      throw new Error("must not sign");
    },
    send: () => {
      throw new Error("must not send");
    },
  });
  assertEquals(response.status, 500);
  assertEquals(await response.json(), {
    error: {
      code: "notification_provider_unavailable",
      message: "Notification provider unavailable",
    },
  });
});

Deno.test("payloads are generic, route-only, and contain no score or identity", () => {
  assertEquals(competitionNotificationPayload(item), {
    aps: {
      alert: {
        title: "Competition updated",
        body: "Open HealthComp to see the latest confirmed activity update.",
      },
      sound: "default",
      "thread-id": "competition:c3000000-0000-4000-8000-000000000001",
    },
    "healthcomp.route.v": 1,
    "healthcomp.route.kind": "competition",
    "healthcomp.route.competitionID": "c3000000-0000-4000-8000-000000000001",
  });
  assertEquals(
    competitionNotificationPayload({ ...item, kind: "result" }),
    {
      aps: {
        alert: {
          title: "Competition complete",
          body: "Open HealthComp to see the confirmed result.",
        },
        sound: "default",
        "thread-id": "competition:c3000000-0000-4000-8000-000000000001",
      },
      "healthcomp.route.v": 1,
      "healthcomp.route.kind": "competition",
      "healthcomp.route.competitionID": "c3000000-0000-4000-8000-000000000001",
    },
  );
});

Deno.test("APNs provider token is a verifiable ES256 JWT", async () => {
  const keyPair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const privateKey = pemPrivateKey(
    await crypto.subtle.exportKey("pkcs8", keyPair.privateKey),
  );
  const before = Math.floor(Date.now() / 1000);
  const token = await createApnsProviderToken({
    ...configuration,
    privateKey,
  });
  const after = Math.floor(Date.now() / 1000);
  const [header, payload, signature, unexpected] = token.split(".");

  assertEquals(unexpected, undefined);
  assertEquals(
    JSON.parse(new TextDecoder().decode(base64UrlBytes(header))),
    { alg: "ES256", kid: configuration.keyId },
  );
  const claims = JSON.parse(
    new TextDecoder().decode(base64UrlBytes(payload)),
  );
  assertEquals(claims.iss, configuration.teamId);
  assertEquals(claims.iat >= before && claims.iat <= after, true);
  assertEquals(base64UrlBytes(signature).length, 64);
  assertEquals(
    await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      keyPair.publicKey,
      base64UrlBytes(signature),
      new TextEncoder().encode(`${header}.${payload}`),
    ),
    true,
  );
});

Deno.test("successful APNs post resolves durable work without leaking identifiers", async () => {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  let sentRequest: Request | undefined;
  const client: NotificationRpcClient = {
    rpc: (name, args) => {
      calls.push({ name, args });
      if (name === "lease_competition_notification_work") {
        return Promise.resolve({ data: { items: [item] }, error: null });
      }
      return Promise.resolve({ data: true, error: null });
    },
  };
  const response = await sendCompetitionNotificationHandler(
    request('{"batchSize":10}'),
    dependencies(client, (outbound) => {
      sentRequest = outbound;
      return Promise.resolve(new Response(null, { status: 200 }));
    }),
  );

  assertEquals(response.status, 200);
  assertEquals(await response.json(), {
    leasedCount: "1",
    sentCount: "1",
    retriedCount: "0",
    invalidTokenCount: "0",
    discardedCount: "0",
    unresolvedCount: "0",
  });
  assertEquals(calls, [
    {
      name: "lease_competition_notification_work",
      args: { batch_size: 10, lease_seconds: 180 },
    },
    {
      name: "resolve_competition_notification_work",
      args: {
        work_id: item.workId,
        lease_token: item.leaseToken,
        outcome: "sent",
        retry_after_seconds: null,
      },
    },
  ]);
  assertEquals(
    sentRequest?.url,
    `https://api.sandbox.push.apple.com/3/device/${item.apnsToken}`,
  );
  assertEquals(sentRequest?.method, "POST");
  assertEquals(
    sentRequest?.headers.get("authorization"),
    "bearer provider-jwt",
  );
  assertEquals(sentRequest?.headers.get("apns-topic"), configuration.topic);
  assertEquals(sentRequest?.headers.get("apns-push-type"), "alert");
  assertEquals(sentRequest?.headers.get("apns-id"), item.workId);
  const expiration = Number(
    sentRequest?.headers.get("apns-expiration"),
  );
  const now = Math.floor(Date.now() / 1000);
  assertEquals(
    Number.isInteger(expiration) && expiration >= now + 3500 &&
      expiration <= now + 3600,
    true,
  );
  assertEquals(
    sentRequest?.headers.get("apns-collapse-id"),
    `healthcomp:${item.competitionId}`,
  );
  assertEquals(
    JSON.parse(await sentRequest!.text()),
    competitionNotificationPayload(item),
  );
});

Deno.test("bounded APNs batch starts sends concurrently within its lease", async () => {
  const secondItem = {
    ...item,
    workId: "c1000000-0000-4000-8000-000000000002",
    leaseToken: "c2000000-0000-4000-8000-000000000002",
    semanticId: item.semanticId + ":second",
  };
  let activeSends = 0;
  let maximumActiveSends = 0;
  const client: NotificationRpcClient = {
    rpc: (name) => {
      if (name === "lease_competition_notification_work") {
        return Promise.resolve({
          data: { items: [item, secondItem] },
          error: null,
        });
      }
      return Promise.resolve({ data: true, error: null });
    },
  };

  const response = await sendCompetitionNotificationHandler(
    request('{"batchSize":2}'),
    dependencies(client, async () => {
      activeSends += 1;
      maximumActiveSends = Math.max(maximumActiveSends, activeSends);
      await new Promise((resolve) => setTimeout(resolve, 10));
      activeSends -= 1;
      return new Response(null, { status: 200 });
    }),
  );

  assertEquals(response.status, 200);
  assertEquals(maximumActiveSends, 2);
});

Deno.test("APNs invalid-token response revokes only through durable resolution", async () => {
  const resolutions: Record<string, unknown>[] = [];
  const client: NotificationRpcClient = {
    rpc: (name, args) => {
      if (name === "lease_competition_notification_work") {
        return Promise.resolve({ data: { items: [item] }, error: null });
      }
      resolutions.push(args);
      return Promise.resolve({ data: true, error: null });
    },
  };
  const response = await sendCompetitionNotificationHandler(
    request(),
    dependencies(
      client,
      () => Promise.resolve(new Response(null, { status: 410 })),
    ),
  );

  assertEquals(response.status, 200);
  assertEquals(resolutions, [{
    work_id: item.workId,
    lease_token: item.leaseToken,
    outcome: "invalid_token",
    retry_after_seconds: null,
  }]);
  assertEquals(await response.json(), {
    leasedCount: "1",
    sentCount: "0",
    retriedCount: "0",
    invalidTokenCount: "1",
    discardedCount: "0",
    unresolvedCount: "0",
  });
});

Deno.test("APNs BadDeviceToken response uses token-safe revocation", async () => {
  const resolutions: Record<string, unknown>[] = [];
  const client: NotificationRpcClient = {
    rpc: (name, args) => {
      if (name === "lease_competition_notification_work") {
        return Promise.resolve({ data: { items: [item] }, error: null });
      }
      resolutions.push(args);
      return Promise.resolve({ data: true, error: null });
    },
  };
  const response = await sendCompetitionNotificationHandler(
    request(),
    dependencies(client, () =>
      Promise.resolve(
        Response.json({ reason: "BadDeviceToken" }, { status: 400 }),
      )),
  );

  assertEquals(response.status, 200);
  assertEquals(resolutions[0], {
    work_id: item.workId,
    lease_token: item.leaseToken,
    outcome: "invalid_token",
    retry_after_seconds: null,
  });
});

Deno.test("transient APNs response schedules a bounded durable retry", async () => {
  const resolutions: Record<string, unknown>[] = [];
  const client: NotificationRpcClient = {
    rpc: (name, args) => {
      if (name === "lease_competition_notification_work") {
        return Promise.resolve({ data: { items: [item] }, error: null });
      }
      resolutions.push(args);
      return Promise.resolve({ data: true, error: null });
    },
  };
  const response = await sendCompetitionNotificationHandler(
    request(),
    dependencies(client, () =>
      Promise.resolve(
        new Response(null, {
          status: 429,
          headers: { "retry-after": "120" },
        }),
      )),
  );

  assertEquals(response.status, 200);
  assertEquals(resolutions[0], {
    work_id: item.workId,
    lease_token: item.leaseToken,
    outcome: "retry",
    retry_after_seconds: 120,
  });
});

Deno.test("network failure leaves no in-memory claim and schedules retry", async () => {
  const resolutions: Record<string, unknown>[] = [];
  const client: NotificationRpcClient = {
    rpc: (name, args) => {
      if (name === "lease_competition_notification_work") {
        return Promise.resolve({ data: { items: [item] }, error: null });
      }
      resolutions.push(args);
      return Promise.resolve({ data: true, error: null });
    },
  };
  const response = await sendCompetitionNotificationHandler(
    request(),
    dependencies(client, () => Promise.reject(new Error("offline"))),
  );

  assertEquals(response.status, 200);
  assertEquals(resolutions[0], {
    work_id: item.workId,
    lease_token: item.leaseToken,
    outcome: "retry",
    retry_after_seconds: 60,
  });
});

Deno.test("malformed lease projection fails closed and sends nothing", async () => {
  let didSend = false;
  const client: NotificationRpcClient = {
    rpc: () =>
      Promise.resolve({
        data: { items: [{ ...item, recipientProfileId: "private" }] },
        error: null,
      }),
  };
  const response = await sendCompetitionNotificationHandler(
    request(),
    dependencies(client, () => {
      didSend = true;
      return Promise.resolve(new Response(null, { status: 200 }));
    }),
  );

  assertEquals(response.status, 502);
  assertEquals(didSend, false);
  assertEquals(await response.json(), {
    error: {
      code: "notification_worker_unavailable",
      message: "Notification worker unavailable",
    },
  });
});

Deno.test("control characters in semantic IDs fail closed before APNs", async () => {
  let didSend = false;
  const client: NotificationRpcClient = {
    rpc: () =>
      Promise.resolve({
        data: { items: [{ ...item, semanticId: item.semanticId + "\n" }] },
        error: null,
      }),
  };
  const response = await sendCompetitionNotificationHandler(
    request(),
    dependencies(client, () => {
      didSend = true;
      return Promise.resolve(new Response(null, { status: 200 }));
    }),
  );

  assertEquals(response.status, 502);
  assertEquals(didSend, false);
});
