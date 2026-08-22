# Pre-iOS-27 App Attest Compatibility Design

## Evidence and root cause

The approved physical iOS 26.6 attempt reached staging twice. Both challenge
requests returned HTTP 200; both score submissions returned the unchanged
non-enumerating HTTP 401; and both fixed verifier diagnostics reported
`invalid_attestation_authenticator_data`. No challenge was consumed and no key,
grant, or score was accepted.

Apple's current App Attest guidance says the validation-category and
bundle-version authenticator-data extensions are new on iOS 27 and later. The
current HealthComp verifier requires an extension map after the credential COSE
key for every attestation and after the fixed header for every assertion. A
valid iOS 26.6 attestation has no extension map, so it fails before certificate,
nonce, app-identity, environment, or key validation.

## Selected compatibility contract

Accept both Apple-signed formats without weakening either:

- Legacy attestations contain the fixed authenticator fields and exactly one
  trailing CBOR object: the credential COSE key.
- Extended attestations contain the same fixed fields, the credential COSE key,
  and exactly one extension map. The map must retain its exact two-key shape and
  pass the configured category/version allowlists.
- Legacy assertions contain exactly the 37-byte fixed authenticator data.
- Extended assertions append exactly one extension map, which must pass the
  same strict allowlists.
- All formats retain certificate-chain, certificate-time, nonce, App ID,
  AAGUID/environment, key-ID, COSE-key, signature, and monotonically increasing
  counter verification.
- A missing extension object is represented as `null` category and `null`
  bundle version. HealthComp never invents or infers attested metadata.
- Extension presence is immutable for a registered key. A legacy key must keep
  producing legacy assertions; an extended key must keep producing extended
  assertions. A format transition fails closed as a proof rejection.

Cryptographic nonce/signature verification binds the full authenticator data,
so an attacker cannot remove an extension map from an extended proof without
invalidating the Apple attestation nonce or assertion signature.

## Hosted storage and migration

Add one forward-only migration after `20260811000900`; never edit or reconnect
historical migrations. Make `private.app_attest_keys.validation_category` and
`bundle_version` nullable only as an inseparable pair. Replace their constraints
so rows are valid precisely when both are absent, or both are present and retain
the current strict ranges and syntax.

The existing RPC signatures remain unchanged: PostgreSQL argument types already
permit null. `authorize_app_attest_proof` accepts a null pair, persists it, and
requires assertion metadata to match the registered key's presence and values.
`load_app_attest_context` returns the pair as JSON nulls for legacy keys. No new
public table, role grant, privileged endpoint, identifier, or telemetry field is
introduced.

## Rejected alternatives

- Requiring iOS 27 would exclude the selected physical device and materially
  narrow the private beta.
- Filling category `3` or bundle version `1` from build/server configuration
  would falsely label unauthenticated values as Apple-attested evidence.
- Skipping category/version checks when an extension map is present would weaken
  the new format.
- Logging proof bytes, structural values, lengths, hashes, or identifiers would
  violate the existing privacy-safe diagnostic boundary.

## Verification and rollout

Tests must first demonstrate the current rejection of an otherwise well-shaped
legacy authenticator and the current inability to store a null metadata pair.
The focused verifier must cover legacy and extended attestation/assertion
shapes, transition rejection, and exact extension validation. Handler tests must
prove nulls reach only the private authorization RPC while the public response
contract stays unchanged. pgTAP must prove pair constraints, legacy key/grant
creation, assertion continuity, replay resistance, RLS, cleanup, and preserved
append-only scores.

After focused GREEN, run the pinned Edge Runtime, hosted-regression, migration,
secret, privacy, formatting, and full backend matrices serially. Review and
integrate the fix before separately requesting staging migration/Function
deployment approval. A new physical launch always requires separate approval.
