# App Attest Physical Rejection Recovery Design

## Evidence and boundary

The first real request against staging Function version 5 failed closed after
the hosted-runtime compatibility fix. Privacy-safe evidence proves that the
physical app obtained one fresh attestation challenge, invoked
`submit-score-revision`, received HTTP 401, and then persisted the score as the
legacy terminal `appAttestRejected` state. The challenge remained unconsumed;
staging registered no App Attest key, issued no submission grant, and accepted
no score. The existing public response intentionally reports only
`app_attest_proof_rejected`, so it cannot identify which strict verifier check
failed. No proof object, key, challenge, account identifier, score, or raw
HealthKit value may be copied into diagnostics.

The selected design adds one privacy-safe backend observation and one durable
client migration. The backend reports only the closed
`AppAttestVerificationErrorCode` value to function logs while preserving the
same non-enumerating HTTP 401 response. The client treats the existing encoded
`appAttestRejected` value as a legacy beta state eligible for one recovery, and
persists all new proof rejections as `appAttestRejectedTerminal`. That new
encoding is never selected by startup recovery. A legacy entry moves once into
the durable `appAttestRejectionRecovery` state. That state preserves its origin
across transport backoff and process relaunch, then either converges and
disappears or fails into a durable support-inspectable terminal state.

## Alternatives rejected

A backend-only diagnostic would still leave the current score permanently
stranded and would require waiting for an unrelated future score revision. A
device sysdiagnose is large, may omit the server verifier decision, and does
not create a safe retry. Reinstalling or deleting local state would destroy the
evidence boundary and reset App Attest installation state; it is explicitly
outside this recovery. Returning the internal verifier reason to the client
would widen an attacker-visible oracle, so the public contract remains
unchanged.

## Data flow and failure handling

`submitScoreRevisionHandler` catches the existing typed verifier error, invokes
an injected reporter with only its enum code, and returns the same
`app_attest_proof_rejected` response. The live reporter emits a fixed event name
plus that code. Tests inject an in-memory reporter and prove that no request,
identity, proof, or payload value is passed through the seam.

On iOS startup, `CompetitionSyncCoordinator` scans a profile-scoped outbox. It
continues to recover the existing `appAttestUnavailable` state as before and
also migrates only legacy `appAttestRejected` score entries to the dedicated
recovery state. Retryable transport preserves that state and its bounded retry
schedule. Any subsequent App Attest availability/proof failure maps to
`appAttestRejectedTerminal`; a fresh coordinator must leave that state
untouched. The outbox remains append-safe, profile-scoped, idempotent, and
support-inspectable, with no direct file mutation or retry-time override
outside the coordinator contract.

## Verification

Strict RED-to-GREEN tests cover the reporter and its unchanged HTTP response,
legacy rejection recovery, failure into the new terminal encoding, and a
second coordinator lifetime that performs no further request. A relaunch test
also proves transport backoff retains the recovery provenance. Focused Deno
and XCTest suites run first. Then the existing App Attest dependency-graph and
pinned Edge Runtime gates, the full relevant backend/iOS matrix, secret/privacy
scans, deterministic project generation, clean-tree checks, and independent
Spec/Standards review must pass before integration. Deployment, installation,
and the final physical retry remain separate action-time approvals.
