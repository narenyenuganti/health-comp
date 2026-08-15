import * as asn1js from "asn1js";
import cbor from "cbor";
import { verifyAssertion as packageVerifyAssertion } from "node-app-attest";
import { Buffer } from "node:buffer";
import {
  createHash,
  createPublicKey,
  timingSafeEqual,
  X509Certificate,
} from "node:crypto";
import * as pkijs from "pkijs";

export type AppAttestEnvironment = "development" | "production";

export type AppAttestVerificationErrorCode =
  | "invalid_app_identity"
  | "invalid_assertion"
  | "invalid_attestation"
  | "invalid_bundle_version"
  | "invalid_certificate"
  | "invalid_client_data"
  | "invalid_counter"
  | "invalid_environment"
  | "invalid_extensions"
  | "invalid_key"
  | "invalid_policy"
  | "invalid_validation_category";

export class AppAttestVerificationError extends Error {
  constructor(
    readonly code: AppAttestVerificationErrorCode,
    options?: ErrorOptions,
  ) {
    super(code, options);
    this.name = "AppAttestVerificationError";
  }
}

export interface AppAttestVerificationPolicy {
  appId: string;
  environment: AppAttestEnvironment;
  allowedValidationCategories: readonly number[];
  allowedBundleVersions: readonly string[];
  now: Date;
}

export interface AppAttestClientDataV1 {
  challengeID: string;
  challenge: Uint8Array;
  profileID: string;
  installationID: string;
  payloadSHA256: Uint8Array;
  purpose: "score_revision";
}

export interface AppAttestPolicyExtensions {
  validationCategory: number;
  bundleVersion: string;
}

export interface VerifiedAppAttestAttestation
  extends AppAttestPolicyExtensions {
  keyID: string;
  publicKeyPEM: string;
  receipt: Uint8Array;
  environment: AppAttestEnvironment;
}

export interface VerifiedAppAttestAssertion extends AppAttestPolicyExtensions {
  signCount: number;
}

const encoder = new TextEncoder();
const clientDataDomain = encoder.encode("healthcomp-app-attest-v1\0");
const canonicalUUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const developmentAAGUID = Buffer.from("appattestdevelop", "ascii");
const productionAAGUID = Buffer.concat([
  Buffer.from("appattest", "ascii"),
  Buffer.alloc(7),
]);
const appleAppAttestationRootCA = new X509Certificate(
  `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYwJAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwKQXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNaFw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlvbiBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9ybmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdhNbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9auYen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijVoyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`,
);
const appAttestNonceOID = "1.2.840.113635.100.8.2";

function fail(
  code: AppAttestVerificationErrorCode,
  cause?: unknown,
): never {
  throw new AppAttestVerificationError(
    code,
    cause === undefined ? undefined : { cause },
  );
}

function uuidBytes(value: string): Uint8Array {
  if (
    !canonicalUUID.test(value) ||
    value === "00000000-0000-0000-0000-000000000000"
  ) {
    fail("invalid_client_data");
  }
  return Buffer.from(value.replaceAll("-", ""), "hex");
}

function tlv(tag: number, value: Uint8Array): Uint8Array {
  const result = new Uint8Array(5 + value.length);
  result[0] = tag;
  new DataView(result.buffer).setUint32(1, value.length, false);
  result.set(value, 5);
  return result;
}

function concatenate(values: readonly Uint8Array[]): Uint8Array {
  const result = new Uint8Array(
    values.reduce((length, value) => length + value.length, 0),
  );
  let offset = 0;
  for (const value of values) {
    result.set(value, offset);
    offset += value.length;
  }
  return result;
}

export function appAttestClientDataV1(
  value: AppAttestClientDataV1,
): Uint8Array {
  if (
    value.challenge.length !== 32 || value.payloadSHA256.length !== 32 ||
    value.purpose !== "score_revision"
  ) {
    fail("invalid_client_data");
  }
  return concatenate([
    clientDataDomain,
    tlv(1, uuidBytes(value.challengeID)),
    tlv(2, value.challenge),
    tlv(3, uuidBytes(value.profileID)),
    tlv(4, uuidBytes(value.installationID)),
    tlv(5, value.payloadSHA256),
    tlv(6, encoder.encode(value.purpose)),
  ]);
}

function exactKeys(value: unknown, expected: readonly string[]): boolean {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  return Object.keys(value as Record<string, unknown>).sort().join("|") ===
    [...expected].sort().join("|");
}

function decodeSingleCBOR(
  value: Uint8Array,
  code: AppAttestVerificationErrorCode,
) {
  try {
    const decoded = cbor.decodeAllSync(Buffer.from(value));
    if (decoded.length !== 1) fail(code);
    return decoded[0] as unknown;
  } catch (error) {
    if (error instanceof AppAttestVerificationError) throw error;
    fail(code, error);
  }
}

function decodePolicyExtensionObject(
  value: unknown,
): AppAttestPolicyExtensions {
  if (
    !exactKeys(value, [
      "apple_bundle_version_01",
      "apple_validation_category_01",
    ])
  ) {
    fail("invalid_extensions");
  }
  const extensions = value as Record<string, unknown>;
  const category = extensions.apple_validation_category_01;
  const bundleVersion = extensions.apple_bundle_version_01;
  if (
    !Buffer.isBuffer(category) || category.length !== 4 ||
    typeof bundleVersion !== "string" ||
    !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(bundleVersion)
  ) {
    fail("invalid_extensions");
  }
  const validationCategory = category.readUInt32LE(0);
  if (validationCategory > 10) fail("invalid_extensions");
  return { validationCategory, bundleVersion };
}

export function decodeAppAttestPolicyExtensions(
  encoded: Uint8Array,
): AppAttestPolicyExtensions {
  return decodePolicyExtensionObject(
    decodeSingleCBOR(encoded, "invalid_extensions"),
  );
}

interface NormalizedPolicy {
  appId: string;
  teamIdentifier: string;
  bundleIdentifier: string;
  environment: AppAttestEnvironment;
  allowedValidationCategories: Set<number>;
  allowedBundleVersions: Set<string>;
  now: number;
}

function normalizePolicy(
  policy: AppAttestVerificationPolicy,
): NormalizedPolicy {
  const match = /^([A-Z0-9]{10})\.(.{1,255})$/.exec(policy.appId);
  const now = policy.now.getTime();
  if (
    !match || !Number.isFinite(now) ||
    !["development", "production"].includes(policy.environment) ||
    policy.allowedValidationCategories.length === 0 ||
    policy.allowedBundleVersions.length === 0 ||
    policy.allowedValidationCategories.some((value) =>
      !Number.isInteger(value) || value < 1 || value > 10 ||
      [7, 8, 9].includes(value)
    ) ||
    policy.allowedBundleVersions.some((value) =>
      !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(value)
    )
  ) {
    fail("invalid_policy");
  }
  return {
    appId: policy.appId,
    teamIdentifier: match[1],
    bundleIdentifier: match[2],
    environment: policy.environment,
    allowedValidationCategories: new Set(policy.allowedValidationCategories),
    allowedBundleVersions: new Set(policy.allowedBundleVersions),
    now,
  };
}

function validatePolicyExtensions(
  extensions: AppAttestPolicyExtensions,
  policy: NormalizedPolicy,
) {
  if (!policy.allowedValidationCategories.has(extensions.validationCategory)) {
    fail("invalid_validation_category");
  }
  if (!policy.allowedBundleVersions.has(extensions.bundleVersion)) {
    fail("invalid_bundle_version");
  }
}

function sha256(value: Uint8Array | string): Buffer {
  return createHash("sha256").update(value).digest();
}

function equal(left: Uint8Array, right: Uint8Array): boolean {
  return left.length === right.length &&
    timingSafeEqual(Buffer.from(left), Buffer.from(right));
}

function decodeCanonicalKeyID(value: string): Buffer {
  if (typeof value !== "string" || value.length !== 44) fail("invalid_key");
  const decoded = Buffer.from(value, "base64");
  if (decoded.length !== 32 || decoded.toString("base64") !== value) {
    fail("invalid_key");
  }
  return decoded;
}

function validateAppIdentity(
  authenticatorData: Buffer,
  policy: NormalizedPolicy,
) {
  if (
    authenticatorData.length < 37 ||
    !equal(authenticatorData.subarray(0, 32), sha256(policy.appId))
  ) {
    fail("invalid_app_identity");
  }
}

function validateCertificates(
  certificateBytes: readonly Buffer[],
  now: number,
): { leaf: X509Certificate; intermediate: X509Certificate } {
  let leaf: X509Certificate;
  let intermediate: X509Certificate;
  try {
    leaf = new X509Certificate(certificateBytes[0]);
    intermediate = new X509Certificate(certificateBytes[1]);
  } catch (error) {
    fail("invalid_certificate", error);
  }
  const certificates = [leaf, intermediate, appleAppAttestationRootCA];
  if (
    leaf.ca || !intermediate.ca || !appleAppAttestationRootCA.ca ||
    leaf.issuer !== intermediate.subject ||
    intermediate.issuer !== appleAppAttestationRootCA.subject ||
    !intermediate.subject.includes("CN=Apple App Attestation CA 1") ||
    !intermediate.issuer.includes("CN=Apple App Attestation Root CA") ||
    leaf.publicKey.asymmetricKeyType !== "ec" ||
    leaf.publicKey.asymmetricKeyDetails?.namedCurve !== "prime256v1"
  ) {
    fail("invalid_certificate");
  }
  try {
    if (
      !leaf.verify(intermediate.publicKey) ||
      !intermediate.verify(appleAppAttestationRootCA.publicKey) ||
      !appleAppAttestationRootCA.verify(appleAppAttestationRootCA.publicKey)
    ) {
      fail("invalid_certificate");
    }
  } catch (error) {
    if (error instanceof AppAttestVerificationError) throw error;
    fail("invalid_certificate", error);
  }
  for (const certificate of certificates) {
    const validFrom = Date.parse(certificate.validFrom);
    const validTo = Date.parse(certificate.validTo);
    if (
      !Number.isFinite(validFrom) || !Number.isFinite(validTo) ||
      now < validFrom || now > validTo
    ) {
      fail("invalid_certificate");
    }
  }
  return { leaf, intermediate };
}

function certificateNonce(certificateBytes: Buffer): Buffer {
  let certificate: pkijs.Certificate;
  try {
    const parsed = asn1js.fromBER(certificateBytes);
    if (parsed.offset !== certificateBytes.length) fail("invalid_certificate");
    certificate = new pkijs.Certificate({ schema: parsed.result });
  } catch (error) {
    if (error instanceof AppAttestVerificationError) throw error;
    fail("invalid_certificate", error);
  }
  const matchingExtensions = (certificate.extensions ?? []).filter((
    extension,
  ) => extension.extnID === appAttestNonceOID);
  if (matchingExtensions.length !== 1) fail("invalid_certificate");

  try {
    const encoded = matchingExtensions[0].extnValue.valueBlock.valueHexView;
    const decoded = asn1js.fromBER(encoded);
    if (
      decoded.offset !== encoded.byteLength ||
      !(decoded.result instanceof asn1js.Sequence) ||
      decoded.result.valueBlock.value.length !== 1
    ) {
      fail("invalid_certificate");
    }
    const tagged = decoded.result.valueBlock.value[0];
    if (
      !(tagged instanceof asn1js.Constructed) ||
      tagged.idBlock.tagClass !== 3 || tagged.idBlock.tagNumber !== 1 ||
      tagged.valueBlock.value.length !== 1
    ) {
      fail("invalid_certificate");
    }
    const octetString = tagged.valueBlock.value[0];
    if (
      !(octetString instanceof asn1js.OctetString) ||
      octetString.valueBlock.isConstructed ||
      octetString.valueBlock.valueHexView.byteLength !== 32
    ) {
      fail("invalid_certificate");
    }
    return Buffer.from(octetString.valueBlock.valueHexView);
  } catch (error) {
    if (error instanceof AppAttestVerificationError) throw error;
    fail("invalid_certificate", error);
  }
}

function validateAttestationNonce(
  certificateBytes: Buffer,
  authenticatorData: Buffer,
  clientDataHash: Uint8Array,
) {
  if (clientDataHash.length < 16 || clientDataHash.length > 64) {
    fail("invalid_attestation");
  }
  const expected = sha256(Buffer.concat([
    authenticatorData,
    Buffer.from(clientDataHash),
  ]));
  if (!equal(certificateNonce(certificateBytes), expected)) {
    fail("invalid_attestation");
  }
}

function decodeAttestation(value: Uint8Array) {
  const decoded = decodeSingleCBOR(value, "invalid_attestation");
  if (!exactKeys(decoded, ["fmt", "attStmt", "authData"])) {
    fail("invalid_attestation");
  }
  const object = decoded as Record<string, unknown>;
  if (
    object.fmt !== "apple-appattest" ||
    !exactKeys(object.attStmt, ["receipt", "x5c"]) ||
    !Buffer.isBuffer(object.authData)
  ) {
    fail("invalid_attestation");
  }
  const statement = object.attStmt as Record<string, unknown>;
  if (
    !Array.isArray(statement.x5c) || statement.x5c.length !== 2 ||
    !statement.x5c.every(Buffer.isBuffer) ||
    !Buffer.isBuffer(statement.receipt) || statement.receipt.length === 0
  ) {
    fail("invalid_attestation");
  }
  const authData = object.authData as Buffer;
  if (
    authData.length < 88 || authData.length > 4_096 || authData[32] !== 0x40 ||
    authData.readUInt32BE(33) !== 0 || authData.readUInt16BE(53) !== 32
  ) {
    fail("invalid_attestation");
  }
  let trailing: unknown[];
  try {
    trailing = cbor.decodeAllSync(authData.subarray(87));
  } catch (error) {
    fail("invalid_attestation", error);
  }
  if (trailing.length !== 2 || !(trailing[0] instanceof Map)) {
    fail("invalid_attestation");
  }
  const cose = trailing[0] as Map<unknown, unknown>;
  if (
    cose.size !== 5 || cose.get(1) !== 2 || cose.get(3) !== -7 ||
    cose.get(-1) !== 1 || !Buffer.isBuffer(cose.get(-2)) ||
    !Buffer.isBuffer(cose.get(-3)) ||
    (cose.get(-2) as Buffer).length !== 32 ||
    (cose.get(-3) as Buffer).length !== 32
  ) {
    fail("invalid_attestation");
  }
  return {
    authData,
    certificateBytes: statement.x5c as Buffer[],
    receipt: statement.receipt as Buffer,
    cose,
    extensions: decodePolicyExtensionObject(trailing[1]),
  };
}

function validateCOSEKey(
  cose: Map<unknown, unknown>,
  leaf: X509Certificate,
  keyID: Buffer,
): string {
  let jwk: JsonWebKey;
  try {
    jwk = leaf.publicKey.export({ format: "jwk" });
  } catch (error) {
    fail("invalid_certificate", error);
  }
  if (
    typeof jwk.x !== "string" || typeof jwk.y !== "string" ||
    !equal(cose.get(-2) as Buffer, Buffer.from(jwk.x, "base64url")) ||
    !equal(cose.get(-3) as Buffer, Buffer.from(jwk.y, "base64url"))
  ) {
    fail("invalid_key");
  }
  const publicKeyBytes = Buffer.concat([
    Buffer.from([0x04]),
    Buffer.from(jwk.x, "base64url"),
    Buffer.from(jwk.y, "base64url"),
  ]);
  if (!equal(sha256(publicKeyBytes), keyID)) fail("invalid_key");
  const publicKeyPEM = leaf.publicKey.export({ type: "spki", format: "pem" });
  if (typeof publicKeyPEM !== "string") fail("invalid_key");
  return publicKeyPEM;
}

export function verifyAppAttestAttestation(input: {
  attestation: Uint8Array;
  clientDataHash: Uint8Array;
  keyID: string;
  policy: AppAttestVerificationPolicy;
}): VerifiedAppAttestAttestation {
  const policy = normalizePolicy(input.policy);
  const keyID = decodeCanonicalKeyID(input.keyID);
  const decoded = decodeAttestation(input.attestation);
  validateAppIdentity(decoded.authData, policy);
  const expectedEnvironment = policy.environment === "development"
    ? developmentAAGUID
    : productionAAGUID;
  if (!equal(decoded.authData.subarray(37, 53), expectedEnvironment)) {
    fail("invalid_environment");
  }
  if (
    !equal(decoded.authData.subarray(55, 87), keyID)
  ) {
    fail("invalid_key");
  }
  validatePolicyExtensions(decoded.extensions, policy);
  const { leaf } = validateCertificates(decoded.certificateBytes, policy.now);
  const publicKeyPEM = validateCOSEKey(decoded.cose, leaf, keyID);
  validateAttestationNonce(
    decoded.certificateBytes[0],
    decoded.authData,
    input.clientDataHash,
  );
  return {
    keyID: input.keyID,
    publicKeyPEM,
    receipt: new Uint8Array(decoded.receipt),
    environment: policy.environment,
    ...decoded.extensions,
  };
}

function decodeAssertion(value: Uint8Array) {
  const decoded = decodeSingleCBOR(value, "invalid_assertion");
  if (!exactKeys(decoded, ["authenticatorData", "signature"])) {
    fail("invalid_assertion");
  }
  const object = decoded as Record<string, unknown>;
  if (
    !Buffer.isBuffer(object.authenticatorData) ||
    !Buffer.isBuffer(object.signature)
  ) {
    fail("invalid_assertion");
  }
  const authData = object.authenticatorData as Buffer;
  const signature = object.signature as Buffer;
  if (
    authData.length < 38 || authData.length > 1_024 || authData[32] !== 0x40 ||
    signature.length < 64 || signature.length > 80
  ) {
    fail("invalid_assertion");
  }
  return {
    authData,
    signature,
    signCount: authData.readUInt32BE(33),
    extensions: decodeAppAttestPolicyExtensions(authData.subarray(37)),
  };
}

export function verifyAppAttestAssertion(input: {
  assertion: Uint8Array;
  clientData: Uint8Array;
  publicKeyPEM: string;
  previousSignCount: number;
  policy: AppAttestVerificationPolicy;
}): VerifiedAppAttestAssertion {
  const policy = normalizePolicy(input.policy);
  if (
    !Number.isInteger(input.previousSignCount) ||
    input.previousSignCount < 0 || input.previousSignCount > 0xffff_ffff ||
    input.clientData.length < 16 || input.clientData.length > 1_024 ||
    typeof input.publicKeyPEM !== "string" || input.publicKeyPEM.length > 2_048
  ) {
    fail("invalid_assertion");
  }
  const decoded = decodeAssertion(input.assertion);
  validateAppIdentity(decoded.authData, policy);
  validatePolicyExtensions(decoded.extensions, policy);
  if (decoded.signCount <= input.previousSignCount) fail("invalid_counter");
  try {
    const publicKey = createPublicKey(input.publicKeyPEM);
    if (
      publicKey.asymmetricKeyType !== "ec" ||
      publicKey.asymmetricKeyDetails?.namedCurve !== "prime256v1"
    ) {
      fail("invalid_key");
    }
    const verified = packageVerifyAssertion({
      assertion: Buffer.from(input.assertion),
      payload: Buffer.from(input.clientData),
      publicKey: input.publicKeyPEM,
      bundleIdentifier: policy.bundleIdentifier,
      teamIdentifier: policy.teamIdentifier,
      signCount: input.previousSignCount,
    });
    if (verified.signCount !== decoded.signCount) fail("invalid_assertion");
  } catch (error) {
    if (error instanceof AppAttestVerificationError) throw error;
    fail("invalid_assertion", error);
  }
  return { signCount: decoded.signCount, ...decoded.extensions };
}
