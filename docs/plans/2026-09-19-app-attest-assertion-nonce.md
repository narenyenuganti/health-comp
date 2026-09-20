# App Attest assertion nonce correction

## Evidence and contract

Base: `3100604a0667facbe2c68ba3041c3a09cf1a3bfe`.
The September 19 physical staging window produced one score HTTP 401 with the
closed label `invalid_assertion_signature`, followed by accepted replacement
enrollment. This is not successful assertion evidence.

The existing exported `verifyAppAttestAssertion` seam rejects the independent
published assertion fixture with that same label. The fixture is pinned to
`uebelack/node-app-attest` commit `f16c4bb71b737466872bc8b8a7dfd215364eaa83`;
its source and MIT notice are retained with the public data. It is not an Apple
official fixture or HealthComp physical evidence, and contains no private key.

[Apple's verification steps](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server)
compute `nonce = SHA256(authenticatorData || SHA256(clientData))` and verify the
signature for that nonce. Node's `createVerify("SHA256")` hashes its message
internally. With the published signature and public key unchanged, verification
of the nonce succeeds; verification of the un-hashed concatenation fails;
changing the payload also fails.

Commit `9aabf59` removed the nonce hash from both verifier and synthetic signer.
Their agreement masked the regression. This independent vector disproves the
one-hash assumption recorded in the August 24 diagnostics design; the original
physical rejection's complete end-to-end cause still requires a qualified retry.

## Smallest change and acceptance

- Restore nonce-message verification at the existing shared public seam. No
  fallback to the incorrect convention, new dependency, iOS change, migration,
  telemetry expansion, or relaxed trust boundary.
- Retain the independent fixture and rejection checks for changed payload,
  signature, identity, equal counter, and the former signing convention.
  Restore synthetic signing to the independently verified convention.
- Exercise public attestation and assertion fixtures in the existing pinned
  Edge Runtime worker; assertion payload tampering must still fail there.
- Run focused verifier/handler tests, full Deno and static guards, pinned runtime,
  independent review, and exact-head CI before integration/promotion.
- Deployment and a genuine physical assertion remain separate evidence gates.
  Do not claim local fixtures prove device acceptance, replay, or production
  readiness. No phone action is part of this source correction.

Focused regression command:

```sh
deno test --config supabase/functions/deno.json --allow-read \
  --filter 'published assertion' supabase/functions/_shared/app_attest_test.ts
```

Observed RED: one test fails with `invalid_assertion_signature` before the
correction. Observed GREEN: all 17 shared-verifier tests pass; the combined
verifier, handler, and process-shim suite passes 34/34 after the correction.

The non-database Deno suite passed 133 tests, zero failures, with one deliberate
ignored test. Formatting, lint, dependency-graph guard (and its tests), index
secret scan, layout isolation, privacy manifest, and the separately pinned
hosted-graph regression passed. Database integration remains for exact-head CI.

The actual pinned Edge Runtime probe on OrbStack initially failed on its second
request without a parsable response diagnostic. The probe now includes HTTP
status in failures. Two subsequent fresh runs passed both public fixtures and
the assertion payload-tampering control, without changing crypto code. The
initial transient is not diagnosed or claimed fixed. Each probe removed its
container and temporary files. No Xcode build or hosted mutation was performed.

## CI destination qualification

Exact-head Backend CI passed (787 database assertions, 136 Deno tests,
separate invitation integration13/13, and pinned runtime). iOS CI twice failed
before app tests with exit70: no available iOS18.5/iPhone16Pro destination.
Both attempts passed Core246/246 in Debug and Release. The runner's reported
image is identical to a previous passing main run and still documents that
Simulator, so image metadata alone is not proof of runtime availability.

The CI workflow now lists runtime/device availability, creates exactly one
iPhone16Pro with the pinned iOS18.5 runtime, waits for its boot, and passes that
device ID to both existing test suites. Missing/unbootable runtime fails the
bounded preparation step; there is no version fallback or skipped test. An
always-run cleanup deletes only that created CI device. No local Simulator or
phone is used. The original failure's registration/runtime cause remains
unresolved until the new workflow produces direct evidence.
