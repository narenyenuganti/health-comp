# App Attest Rejection Diagnostics Design

## Evidence and boundary

The one approved physical retry against staging Function version 6 reached the
strict verifier and failed closed. The privacy-safe hosted event reported
`invalid_attestation`; the matching request returned HTTP 401. The retry window
contained one new attestation challenge and zero consumed challenges,
registered keys, submission grants, or accepted score revisions. The device
retained one terminal outbox entry with no scheduled retry. This proves the
failure is inside attestation verification, but the current code uses the same
error code for the outer CBOR object, authenticator-data layout, COSE credential
key, and certificate nonce binding. It does not identify a root cause.

## Selected design

Split only that internal diagnostic into four closed enum values:
`invalid_attestation_object`, `invalid_attestation_authenticator_data`,
`invalid_attestation_cose_key`, and `invalid_attestation_nonce`. Each value
names a fixed verifier stage, not a request or device attribute. The live
reporter continues to emit only `app_attest_verification_rejected` plus one enum
value, and the client continues to receive the same non-enumerating HTTP 401
`app_attest_proof_rejected`. No identity, challenge, key, certificate, proof,
payload, length, hash, score, HealthKit value, or error object crosses the
reporter seam.

The alternatives are less safe. Logging structural lengths or booleans could
create a device/proof fingerprint and would widen the diagnostic contract.
Retaining or exporting the attestation object would violate the established
privacy boundary. Treating the current code as a verifier defect would be
guesswork because the available evidence does not distinguish a format mismatch
from a nonce mismatch. The enum split is therefore instrumentation for the next
authorized physical attempt, not a claim that physical App Attest acceptance is
fixed.

## Verification and rollout

Focused tests mutate Apple's checked-in public fixture so all four stages are
exercised while valid fixture verification remains unchanged. Handler tests
prove every new code preserves the exact public 401 response and never reaches
authorization. The existing pinned Edge Runtime, hosted-regression, dependency
graph, secret, privacy, formatting, and full backend gates must remain green.
The change may be integrated into `main`, but staging deployment and any new
physical attempt remain separate action-time approval gates.
