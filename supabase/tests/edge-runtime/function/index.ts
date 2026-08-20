import { Buffer } from "node:buffer";
import {
  AppAttestVerificationError,
  verifyAppAttestAttestation,
} from "./app-attest.ts";

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

Deno.serve(async (request: Request) => {
  try {
    const fixture = await request.json() as OfficialFixture;
    const result = verifyAppAttestAttestation({
      attestation: Buffer.from(fixture.attestation, "base64"),
      clientDataHash: Buffer.from(fixture.clientDataHash, "base64"),
      keyID: fixture.keyId,
      policy: {
        appId: fixture.appId,
        environment: fixture.environment,
        allowedValidationCategories: [fixture.validationCategory],
        allowedBundleVersions: [fixture.bundleVersion],
        now: new Date(fixture.verificationDate),
      },
    });

    const ok = result.keyID === fixture.keyId &&
      result.environment === fixture.environment &&
      result.validationCategory === fixture.validationCategory &&
      result.bundleVersion === fixture.bundleVersion &&
      result.publicKeyPEM.includes("BEGIN PUBLIC KEY") &&
      result.receipt.length > 1_000;
    return Response.json({ ok }, { status: ok ? 200 : 500 });
  } catch (error) {
    return Response.json(
      {
        ok: false,
        category: error instanceof Error ? error.name : typeof error,
        code: error instanceof AppAttestVerificationError
          ? error.code
          : "unexpected",
        causeCategory: error instanceof Error && error.cause instanceof Error
          ? error.cause.name
          : "none",
        causeCode: error instanceof Error && error.cause instanceof Error &&
            "code" in error.cause
          ? String(error.cause.code)
          : "none",
      },
      { status: 500 },
    );
  }
});
