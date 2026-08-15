import { assertEquals, assertThrows } from "@std/assert";
import cbor from "cbor";
import { Buffer } from "node:buffer";
import { createHash, createSign, generateKeyPairSync } from "node:crypto";
import {
  appAttestClientDataV1,
  AppAttestVerificationError,
  type AppAttestVerificationPolicy,
  decodeAppAttestPolicyExtensions,
  verifyAppAttestAssertion,
  verifyAppAttestAttestation,
} from "./app-attest.ts";

interface OfficialFixture {
  version: number;
  source: string;
  appId: string;
  challenge: string;
  clientDataHash: string;
  keyId: string;
  environment: "development" | "production";
  validationCategory: number;
  bundleVersion: string;
  documentedBundleVersion: string;
  verificationDate: string;
  attestation: string;
}

const official = JSON.parse(
  await Deno.readTextFile(
    new URL(
      "../../tests/fixtures/app-attest-official-2026.json",
      import.meta.url,
    ),
  ),
) as OfficialFixture;

const officialPolicy = (): AppAttestVerificationPolicy => ({
  appId: official.appId,
  environment: official.environment,
  allowedValidationCategories: [official.validationCategory],
  allowedBundleVersions: [official.bundleVersion],
  now: new Date(official.verificationDate),
});

function bytes(from: number, count: number): Uint8Array {
  return Uint8Array.from({ length: count }, (_, index) => from + index);
}

function expectCode(
  code: AppAttestVerificationError["code"],
  operation: () => unknown,
) {
  const failure = assertThrows(operation, AppAttestVerificationError);
  if (!(failure instanceof AppAttestVerificationError)) {
    throw new Error("Expected AppAttestVerificationError");
  }
  assertEquals((failure as AppAttestVerificationError).code, code);
}

Deno.test("App Attest v1 client data has frozen cross-language bytes", () => {
  const encoded = appAttestClientDataV1({
    challengeID: "10000000-0000-4000-8000-000000000001",
    challenge: bytes(0, 32),
    profileID: "20000000-0000-4000-8000-000000000002",
    installationID: "30000000-0000-4000-8000-000000000003",
    payloadSHA256: bytes(32, 32),
    purpose: "score_revision",
  });
  assertEquals(
    Buffer.from(encoded).toString("hex"),
    "6865616c7468636f6d702d6170702d6174746573742d763100" +
      "010000001010000000000040008000000000000001" +
      "0200000020000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" +
      "030000001020000000000040008000000000000002" +
      "040000001030000000000040008000000000000003" +
      "0500000020202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f" +
      "060000000e73636f72655f7265766973696f6e",
  );
});

Deno.test("client data rejects noncanonical identifiers and wrong fixed lengths", () => {
  const valid = {
    challengeID: "10000000-0000-4000-8000-000000000001",
    challenge: bytes(0, 32),
    profileID: "20000000-0000-4000-8000-000000000002",
    installationID: "30000000-0000-4000-8000-000000000003",
    payloadSHA256: bytes(32, 32),
    purpose: "score_revision" as const,
  };
  expectCode("invalid_client_data", () =>
    appAttestClientDataV1({
      ...valid,
      challengeID: "10000000-0000-4000-8000-00000000000A",
    }));
  expectCode(
    "invalid_client_data",
    () => appAttestClientDataV1({ ...valid, challenge: bytes(0, 31) }),
  );
  expectCode(
    "invalid_client_data",
    () => appAttestClientDataV1({ ...valid, payloadSHA256: bytes(0, 33) }),
  );
});

Deno.test("Apple 2026 official attestation fixture passes the strict wrapper", () => {
  assertEquals(official.version, 1);
  assertEquals(official.documentedBundleVersion, "1.0");
  assertEquals(
    Buffer.from(official.clientDataHash, "base64").toString(),
    official.challenge,
  );
  const result = verifyAppAttestAttestation({
    attestation: Buffer.from(official.attestation, "base64"),
    clientDataHash: Buffer.from(official.clientDataHash, "base64"),
    keyID: official.keyId,
    policy: officialPolicy(),
  });
  assertEquals(result.keyID, official.keyId);
  assertEquals(result.environment, "production");
  assertEquals(result.validationCategory, 1);
  assertEquals(result.bundleVersion, "1");
  assertEquals(result.publicKeyPEM.includes("BEGIN PUBLIC KEY"), true);
  assertEquals(result.receipt.length > 1_000, true);
});

Deno.test("attestation rejects identity environment category version and certificate time", () => {
  const candidate = {
    attestation: Buffer.from(official.attestation, "base64"),
    clientDataHash: Buffer.from(official.clientDataHash, "base64"),
    keyID: official.keyId,
  };
  expectCode("invalid_app_identity", () =>
    verifyAppAttestAttestation({
      ...candidate,
      policy: { ...officialPolicy(), appId: "1234567890.com.example.other" },
    }));
  expectCode("invalid_environment", () =>
    verifyAppAttestAttestation({
      ...candidate,
      policy: { ...officialPolicy(), environment: "development" },
    }));
  expectCode("invalid_validation_category", () =>
    verifyAppAttestAttestation({
      ...candidate,
      policy: { ...officialPolicy(), allowedValidationCategories: [2] },
    }));
  expectCode("invalid_bundle_version", () =>
    verifyAppAttestAttestation({
      ...candidate,
      policy: { ...officialPolicy(), allowedBundleVersions: ["2"] },
    }));
  expectCode("invalid_certificate", () =>
    verifyAppAttestAttestation({
      ...candidate,
      policy: { ...officialPolicy(), now: new Date("2026-08-15T00:00:00Z") },
    }));
});

Deno.test("attestation rejects malformed CBOR client hash and key identifier", () => {
  const candidate = {
    attestation: Buffer.from(official.attestation, "base64"),
    clientDataHash: Buffer.from(official.clientDataHash, "base64"),
    keyID: official.keyId,
    policy: officialPolicy(),
  };
  expectCode("invalid_attestation", () =>
    verifyAppAttestAttestation({
      ...candidate,
      attestation: new Uint8Array([0xff]),
    }));
  expectCode("invalid_attestation", () =>
    verifyAppAttestAttestation({
      ...candidate,
      clientDataHash: new TextEncoder().encode("wrong_client_data_hash"),
    }));
  expectCode("invalid_key", () =>
    verifyAppAttestAttestation({
      ...candidate,
      keyID: Buffer.alloc(32, 7).toString("base64"),
    }));
});

Deno.test("attestation rejects a certificate with a tampered signature", async () => {
  const decoded = cbor.decodeFirstSync(
    Buffer.from(official.attestation, "base64"),
  ) as {
    fmt: string;
    attStmt: { x5c: Buffer[]; receipt: Buffer };
    authData: Buffer;
  };
  const leaf = Buffer.from(decoded.attStmt.x5c[0]);
  leaf[leaf.length - 1] ^= 1;
  const attestation = await cbor.encodeAsync({
    ...decoded,
    attStmt: {
      ...decoded.attStmt,
      x5c: [leaf, decoded.attStmt.x5c[1]],
    },
  });
  expectCode("invalid_certificate", () =>
    verifyAppAttestAttestation({
      attestation,
      clientDataHash: Buffer.from(official.clientDataHash, "base64"),
      keyID: official.keyId,
      policy: officialPolicy(),
    }));
});

function policyExtensions(category: number, bundleVersion: string) {
  const categoryBytes = Buffer.alloc(4);
  categoryBytes.writeUInt32LE(category);
  return {
    apple_bundle_version_01: bundleVersion,
    apple_validation_category_01: categoryBytes,
  };
}

Deno.test("policy extension decoder requires the exact signed shape", async () => {
  assertEquals(
    decodeAppAttestPolicyExtensions(
      await cbor.encodeAsync(policyExtensions(3, "1")),
    ),
    { validationCategory: 3, bundleVersion: "1" },
  );
  for (
    const value of [
      {},
      { ...policyExtensions(3, "1"), extra: true },
      { ...policyExtensions(3, "1"), apple_bundle_version_01: "" },
      {
        ...policyExtensions(3, "1"),
        apple_validation_category_01: Buffer.alloc(3),
      },
    ]
  ) {
    const encoded = await cbor.encodeAsync(value);
    expectCode(
      "invalid_extensions",
      () => decodeAppAttestPolicyExtensions(encoded),
    );
  }
});

async function syntheticAssertion() {
  const appId = "1234567890.com.example.myapp";
  const clientData = appAttestClientDataV1({
    challengeID: "10000000-0000-4000-8000-000000000001",
    challenge: bytes(0, 32),
    profileID: "20000000-0000-4000-8000-000000000002",
    installationID: "30000000-0000-4000-8000-000000000003",
    payloadSHA256: bytes(32, 32),
    purpose: "score_revision",
  });
  const rpIDHash = createHash("sha256").update(appId).digest();
  const counter = Buffer.alloc(4);
  counter.writeUInt32BE(1);
  const authenticatorData = Buffer.concat([
    rpIDHash,
    Buffer.from([0x40]),
    counter,
    await cbor.encodeAsync(policyExtensions(3, "1")),
  ]);
  const clientDataHash = createHash("sha256").update(clientData).digest();
  const nonce = createHash("sha256")
    .update(Buffer.concat([authenticatorData, clientDataHash]))
    .digest();
  const { privateKey, publicKey } = generateKeyPairSync("ec", {
    namedCurve: "prime256v1",
  });
  const signature = createSign("SHA256").update(nonce).end().sign(privateKey);
  return {
    appId,
    clientData,
    publicKeyPEM: publicKey.export({ type: "spki", format: "pem" }).toString(),
    assertion: await cbor.encodeAsync({ signature, authenticatorData }),
  };
}

Deno.test("assertion verifies signature identity policy and increasing counter", async () => {
  const fixture = await syntheticAssertion();
  const policy: AppAttestVerificationPolicy = {
    appId: fixture.appId,
    environment: "development",
    allowedValidationCategories: [3],
    allowedBundleVersions: ["1"],
    now: new Date("2026-08-15T00:00:00Z"),
  };
  assertEquals(
    verifyAppAttestAssertion({
      assertion: fixture.assertion,
      clientData: fixture.clientData,
      publicKeyPEM: fixture.publicKeyPEM,
      previousSignCount: 0,
      policy,
    }),
    { signCount: 1, validationCategory: 3, bundleVersion: "1" },
  );
  expectCode("invalid_counter", () =>
    verifyAppAttestAssertion({
      assertion: fixture.assertion,
      clientData: fixture.clientData,
      publicKeyPEM: fixture.publicKeyPEM,
      previousSignCount: 1,
      policy,
    }));
  expectCode("invalid_app_identity", () =>
    verifyAppAttestAssertion({
      assertion: fixture.assertion,
      clientData: fixture.clientData,
      publicKeyPEM: fixture.publicKeyPEM,
      previousSignCount: 0,
      policy: { ...policy, appId: "1234567890.com.example.other" },
    }));
  expectCode("invalid_bundle_version", () =>
    verifyAppAttestAssertion({
      assertion: fixture.assertion,
      clientData: fixture.clientData,
      publicKeyPEM: fixture.publicKeyPEM,
      previousSignCount: 0,
      policy: { ...policy, allowedBundleVersions: ["2"] },
    }));
  const decoded = cbor.decodeFirstSync(fixture.assertion) as {
    signature: Buffer;
    authenticatorData: Buffer;
  };
  const signature = Buffer.from(decoded.signature);
  signature[signature.length - 1] ^= 1;
  const tamperedAssertion = await cbor.encodeAsync({ ...decoded, signature });
  expectCode("invalid_assertion", () =>
    verifyAppAttestAssertion({
      assertion: tamperedAssertion,
      clientData: fixture.clientData,
      publicKeyPEM: fixture.publicKeyPEM,
      previousSignCount: 0,
      policy,
    }));
});
