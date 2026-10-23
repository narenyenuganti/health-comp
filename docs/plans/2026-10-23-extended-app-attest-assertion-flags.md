# Extended App Attest assertion compatibility

Base: `be09bdaad3f5cf2ed7feabebdcbde79ba674a539`.

## Evidence and scope

A phone-free Staging aggregate found two v17
`invalid_assertion_authenticator_data` rejections. These are not bound to an
exact phone or gesture. The independently published Block/Buzz iOS 27 assertion
has valid signature, identity and increasing counter, but its 99-byte extended
authenticator data uses `0xC0`, which our decoder rejects before those checks.
The same fixture passes an in-memory experiment accepting this exact flag.

Accept exact `0xC0` as well as exact `0x80` for extended assertion authenticator
data, keeping the existing 38–1024-byte bounds and strict single extension map.
Keep the legacy 37-byte `0x00`/`0x40` forms unchanged. Do not mask arbitrary bits
or accept any other flag combination. Preserve identity, signature, counter,
category, bundle-version, challenge and grant checks. No SDK, policy, key,
outbox, account, database or response changes belong to this fix.

## Verification

Use the existing public `verifyAppAttestAssertion` and scoring-handler test
interfaces. First reproduce rejection of the pinned public fixture, then make
the minimal decoder change. Verify the fixture's published counter and decoded
policy fields, plus tampered signature, replay counter, wrong identity,
category/version and unsupported-flag rejection. Preserve existing legacy,
malformed-CBOR and extension-map tests. Run the focused tests before full cached
verifier/handler tests and exact-head CI; obtain independent Standards and Spec
review. Include source provenance and its Apache-2.0 license with the fixture.

Public-fixture compatibility is not proof of the user's actual assertion flag,
physical acceptance/replay, or production readiness. This source-integration
step does not deploy, use the phone, reset keys, or replace the current match.
