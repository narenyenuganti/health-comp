import { assertEquals } from "@std/assert";

interface OfficialFixture {
  appId: string;
  clientDataHash: string;
  keyId: string;
  environment: "development" | "production";
  validationCategory: number;
  bundleVersion: string;
  verificationDate: string;
  attestation: string;
}

interface WorkerResult {
  status: "ok" | "error";
  keyMatches?: boolean;
  environment?: string;
  validationCategory?: number;
  bundleVersion?: string;
  hasPublicKey?: boolean;
  hasReceipt?: boolean;
  category?: string;
}

Deno.test("real attestation survives the hosted raw dependency graph", async () => {
  const fixture = JSON.parse(
    await Deno.readTextFile(
      new URL(
        "../../tests/fixtures/app-attest-official-2026.json",
        import.meta.url,
      ),
    ),
  ) as OfficialFixture;
  const moduleURL = new URL("./app-attest.ts", import.meta.url).href;
  const workerSource = `
    globalThis.process = { pid: undefined };
    globalThis.global = globalThis;
    const fixture = ${JSON.stringify(fixture)};
    const bytes = (value) =>
      Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
    try {
      const module = await import(${JSON.stringify(moduleURL)});
      const result = module.verifyAppAttestAttestation({
        attestation: bytes(fixture.attestation),
        clientDataHash: bytes(fixture.clientDataHash),
        keyID: fixture.keyId,
        policy: {
          appId: fixture.appId,
          environment: fixture.environment,
          allowedValidationCategories: [fixture.validationCategory],
          allowedBundleVersions: [fixture.bundleVersion],
          now: new Date(fixture.verificationDate),
        },
      });
      postMessage({
        status: "ok",
        keyMatches: result.keyID === fixture.keyId,
        environment: result.environment,
        validationCategory: result.validationCategory,
        bundleVersion: result.bundleVersion,
        hasPublicKey: result.publicKeyPEM.includes("BEGIN PUBLIC KEY"),
        hasReceipt: result.receipt.length > 1_000,
      });
    } catch (error) {
      postMessage({
        status: "error",
        category: error instanceof Error ? error.name : typeof error,
      });
    }
  `;
  const workerURL = URL.createObjectURL(
    new Blob([workerSource], { type: "text/javascript" }),
  );
  const worker = new Worker(workerURL, { type: "module" });

  try {
    const result = await new Promise<WorkerResult>((resolve, reject) => {
      const timeout = setTimeout(
        () => reject(new Error("hosted dependency probe timed out")),
        10_000,
      );
      worker.onmessage = (event: MessageEvent<WorkerResult>) => {
        clearTimeout(timeout);
        resolve(event.data);
      };
      worker.onerror = (event) => {
        clearTimeout(timeout);
        reject(event.error ?? new Error(event.message));
      };
    });

    assertEquals(result, {
      status: "ok",
      keyMatches: true,
      environment: "production",
      validationCategory: 1,
      bundleVersion: "1",
      hasPublicKey: true,
      hasReceipt: true,
    });
  } finally {
    worker.terminate();
    URL.revokeObjectURL(workerURL);
  }
});
