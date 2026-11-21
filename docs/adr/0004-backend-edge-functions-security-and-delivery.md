# ADR-0004: Backend Edge Functions Security, Deletion, and Push Delivery

- **Status:** Accepted
- **Date:** 2026-11-21
- **Scope:** `supabase/functions/`, `functions/`

## Context

Supabase Edge Functions sit at the trust boundary for authentication, App Attest proof verification, invitation privacy, Apple account deletion, and APNs push delivery. Mistakes here can silently sign users out during auth outages, leak account existence or provider internals, exhaust worker memory, or leave account deletion unresumable.

## Decisions

### 1. Auth Outage vs. Token Rejection Boundary (`503` vs `401`)
- `supabase/functions/_shared/scoring_http.ts` (`verifiedUserId`), `apple_deletion_begin.ts`, `apple_deletion_complete.ts`:
  - `verifiedUserId` returns `null` only when Auth answered and explicitly rejected the token (4xx other than `408` and `429`).
  - Because `auth-js` returns outages (network failures, `408`, `429`, `5xx`) as error objects rather than throwing, `verifiedUserId` converts them into thrown errors so every handler responds with retryable `503` instead of `401`, preventing clients from misinterpreting an outage as sign-out.

### 2. Bounded Request Parsing and Stack-Safe Fingerprint Checks
- `supabase/functions/_shared/scoring_http.ts`, `delete-account/index.ts`:
  - `readBoundedJson` streams at most `maximumBytes` (e.g., `8_192` pre-auth in `delete-account`) so chunked requests without `Content-Length` cannot exhaust worker memory.
  - `containsFingerprint` fails closed (`true`) when JSON nesting exceeds depth 16, preventing hostile deeply nested payloads from overflowing the stack.

### 3. Non-Enumerating and Diagnostic-Free Error Responses
- `preview-competition-invite/index.ts`, `create-competition-invite/index.ts`, `submit-score-revision/index.ts`, `_shared/apple_deletion_callback.ts`, `_shared/apple_deletion_endpoint.ts`, `_shared/apple_deletion_body.ts`:
  - Unavailable, reset, unknown, or friend-privacy-refused invite lookups and creates all return the same opaque error response (`404` on preview; uniform unavailable on create).
  - Server-side App Attest diagnostic recording must never alter the non-enumerating client rejection response.
  - Apple deletion endpoints, callbacks, and body readers never expose storage, provider, credential, or SDK construction diagnostics (returning empty `503` or generic invalid errors).

### 4. Invite Recipient & Rematch Invariants
- `create-competition-invite/index.ts`: Every invite targets exactly one recipient—either a `recipientProfileId` (rematches and 1.0.2 clients) or a live challenge link code validated by the database. Rematches are strictly between prior opponents and never accepted by link code.

### 5. Apple Account Deletion Workflow Safety
- `supabase/functions/_shared/apple_deletion_transport.ts`: Always `await` the real transport; never detach an RPC or deletion call with `Promise.race`, because a local timeout cannot prove remote rollback or non-acceptance.
- `_shared/apple_deletion_body.ts`: Request body stream cancellation fires `void reader.cancel().catch(() => {})` without awaiting because a producer's cancel hook may never settle.
- `_shared/apple_deletion_callback.ts`: HTTP parsing validates shape only; the backing store atomically verifies live state, expiry, and single-use ownership and never returns a profile ID.
- `_shared/apple_deletion_complete.ts`: Resolve trusted configuration (`webClient()`) before consuming any single-use grant.
- `_shared/apple_deletion_endpoint.ts`: Preserve a server-confirmed `200` completion even if transport budget expired afterward, while refusing to misreport budget exhaustion during auth as invalid credentials.
- `delete-account/index.ts`:
  - `continueAccountDeletion` is internal and requires an identity already verified by `authenticate`; fresh Apple authorization is requested only before durable token storage, never on resume.
  - Profile photos are deleted before anonymizing so any storage failure stays in a resumable phase; listing loops up to 20 pages until empty rather than trusting one page despite the 3-object storage policy.
  - If the auth user is already gone when confirming completion, return `200 { status: "deleted" }` because the row is already deleted via the `auth.users` foreign key and a `503` retry would hit `401`.
  - `redirectURI` is strictly server-owned from the original web authorization request (omitted for native, never populated from callback input). Client IDs must match an explicit server allowlist—never sign a client secret for an arbitrary client ID read from durable progress.
  - Non-JSON Apple revocation responses carry no structured error code, and Apple also returns `200` when a token is already invalid.

### 6. App Attest Verification and Bundle-Version Policy
- `supabase/functions/_shared/app-attest.ts`:
  - Accepts both Apple's `AT`-only (`0x40`) and `AT+ED` (`0xc0`) attestation flags, and recognizes published iOS 27 assertion payloads (`0x80` or `0xc0` with `37 < authData.length <= 1024`).
  - `createVerify("SHA256")` hashes the nonce internally (App Attest signs the nonce).
  - Never falls back to the former synthetic-only convention.
- `supabase/functions/submit-score-revision/index.ts`: A changed non-null `bundleVersion` (app update) signals a stale registration, returning `409` so the app re-attests (matching `authorize_app_attest_proof`); a null/non-null format mismatch stays a hard rejection.

### 7. APNs Notification Worker Policy
- `supabase/functions/send-competition-notification/index.ts`:
  - Reuses the APNs provider JWT in warm workers for 40 minutes (Apple asks for refreshes no faster than every 20 minutes and rejects tokens older than 60 minutes), evicting early on APNs `403`.
  - The iOS app owns all visible match score and result notifications (named, with scores, in the user's locale); server-sent alerts are strictly generic (no names) so they are safe on Lock Screens, and `null` payloads resolve work rows as `discarded` without calling APNs.
  - APNs `apns-id` is logged only as an opaque development identifier; APNs acceptance does not prove device delivery.
  - On `PGRST202` (schema cache missing the 3-argument `supports_friends` overload during a rollout before migrations finish), the worker falls back to the 2-argument `lease_competition_notification_work` overload.

### 8. Integration Test Safety and Concurrency Contracts
- `supabase/functions/*_integration_test.ts`:
  - Require explicit `HEALTHCOMP_TEST_DATABASE_URL` and `HEALTHCOMP_TEST_FUNCTIONS_URL` with no localhost defaults so mutating tests never hit another local project.
  - Concurrent race tests (`group_match_race_integration_test.ts`, `scoring_race_integration_test.ts`) assert that losing calls fail strictly with domain error `P0001`; deadlocks (`40P01`), lock timeouts, or unexpected exceptions fail the test even if final state looks valid.
  - `notification_delivery_log_integration_test.ts` asserts work resolution completes under a `250ms` `lock_timeout` while another connection holds `FOR UPDATE` on `device_installations`, proving delivery logging does not block on installation locks.
  - `friends_race_integration_test.ts` transitions test profiles to `'deleting'` on teardown because profiles have a no-delete trigger and deactivation releases test handles.
  - `invitation_recipient_race_integration_test.ts` rotates recipients across 20 accept-vs-cancel rounds so the per-pair 10/day `invite_rate_limited` cap is never hit, and repeats without DB reset to confirm retained synthetic history never collides.
