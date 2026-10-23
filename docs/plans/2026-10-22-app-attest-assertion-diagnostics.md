# App Attest assertion rejection diagnostics

## Evidence and boundary

Base: `91ee89aa83cea225700233b91c779bb20f15dc3e`.

Two aggregate-only Staging log queries over October 22, 07:40–07:49 UTC reported
two `invalid_assertion_object` failures from scoring Function version 16. They
are not bound to one phone, gesture, account or saved queue entry. The category
currently combines CBOR decoding, object keys, field types, authenticator-data
shape and signature-length rejection. Existing tests pass; neither the failing
sub-branch nor an incorrect validation rule is established.

Distinguish those existing rejection paths using five fixed internal codes:

- `invalid_assertion_cbor`
- `invalid_assertion_shape`
- `invalid_assertion_fields`
- `invalid_assertion_authenticator_data`
- `invalid_assertion_signature_length`

Preserve every accepted input, size/flag/type check, public HTTP status and
`app_attest_proof_rejected` response. Preserve the old generic internal code in
the type for compatibility. Report only fixed codes through the existing
reporter: no bytes, identifiers, Health values or new logging infrastructure.

## Verification

Use the existing public `verifyAppAttestAssertion` and
`submitScoreRevisionHandler` test interfaces. Observe RED then GREEN for
classification; do not represent this as reproducing or fixing the physical
failure. Cover malformed/non-single CBOR, wrong keys/types, authenticator-data
shape, and signature length. The handler must still reject before proof
authorization and return the same generic public response for every code.

The local cached Deno/CBOR runtime returned incomplete bytes from some
synchronous negative-fixture encodings. Use the existing asynchronous encoder
and assert the decoded fixture shape before expecting a later rejection stage.
This is test-fixture evidence, not proof that real Apple assertions are
truncated.

Run focused tests first, then the complete cached verifier and scoring-handler
tests, type checks and formatting. Obtain independent Standards and Spec review
against the fixed base before integration. No SDK/client change, validation
relaxation, key or queue reset, migration, new invitation, phone action or
production deployment belongs to this change. Any later Staging deployment must
use the exact reviewed, CI-qualified source.
