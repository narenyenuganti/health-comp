# App Attest Assertion-Stage Diagnostics Design

## Evidence boundary

Exact merged main `aa16411` completed a state-preserving physical staging
over-install, one launch, fresh native Sign in with Apple, and one authenticated
refresh without a visible warning. The bounded hosted window returned four
successful App Attest challenges, followed by two score-submission HTTP 400
responses and two HTTP 401 responses. Both 401 verifier diagnostics were the
existing closed label `invalid_assertion`; no score submission returned 200.

The current label covers assertion-object decoding, structural validation,
public-key parsing, curve validation, and ECDSA signature verification. It is
therefore insufficient to identify the next safe RED-to-GREEN correction.
Apple's current validation contract confirms that HealthComp's verifier uses
the required signed message: SHA256 over authenticator data concatenated with
SHA256 of client data. The previous one-hash correction is not disproven.

No proof bytes, request bodies, identifiers, counters, lengths, hashes,
signatures, keys, scores, Health values, or private screenshots are retained.

## Options

1. **Add closed assertion-stage codes.** Distinguish assertion object/shape,
   key, and signature stages while preserving the existing identity, policy,
   extension, and counter codes. This is the smallest privacy-safe diagnostic
   seam and matches the already integrated attestation-stage pattern.
2. **Log proof structure or metadata.** This could localize the failure in one
   run, but even lengths, flags, hashes, or proof fragments would expand the
   prohibited telemetry boundary and are rejected.
3. **Relax assertion verification.** Accepting additional flags, shapes, keys,
   or signatures before identifying the failing stage would weaken the App
   Attest gate and is rejected.

## Selected design

Add two fixed public diagnostic codes to `AppAttestVerificationErrorCode`:

- `invalid_assertion_object` for CBOR decoding, exact-key/type checks,
  authenticator-data shape, flag/extension-shape consistency, and signature
  envelope bounds;
- `invalid_assertion_signature` for ECDSA verifier construction or a signature
  that does not validate against the registered P-256 key and reconstructed
  client data.

Keep `invalid_key` for public-key parsing or non-P-256 keys. Preserve the
existing `invalid_app_identity`, `invalid_validation_category`,
`invalid_bundle_version`, `invalid_extensions`, `invalid_counter`, and
`invalid_policy` stages. Invalid verifier inputs that are not an assertion
object remain `invalid_assertion` so the public API contract does not change.

The Edge handler continues to emit only the fixed event
`app_attest_verification_rejected` plus one closed enum value. Every verifier
failure still returns the same non-enumerating HTTP 401
`app_attest_proof_rejected` response and never calls the authorization RPC.

## Verification and rollout

Tests first freeze object, key, and signature labels and prove all remain
fail-closed. Run the focused shared verifier and handler suites, formatting,
privacy/secret guards, the App Attest dependency-graph guard, and the pinned
Edge Runtime probe. Review and integrate the exact diff before deploying only
`submit-score-revision` to staging. A new physical attempt remains a separate
phone-required step and must retain only the resulting closed label and
aggregate HTTP counts.

