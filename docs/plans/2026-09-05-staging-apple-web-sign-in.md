# Staging Apple Web Sign-In Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add and qualify optional browser-based Apple authentication in staging without changing personal iCloud, weakening deletion, or changing production.

**Architecture:** Keep native Apple sign-in as the default and use the existing shared Supabase client and profile transition machinery. A staging-only browser adapter owns presentation, cancellation and callback validation; it must not import arbitrary incoming URLs into Auth. Browser reauthorization for account deletion is a separate fresh-grant operation, not another login/session replacement.

**Tech Stack:** Swift, AuthenticationServices, Supabase Swift **2.55.1**, TCA, hosted Supabase Auth and existing deletion Edge/SQL contracts.

---

## Current continuation boundary — September 6 integration

The active app branch is `feature/paired-browser-auth-client`, based on merged
main `7c4079e8614eb2a8d3001b80ab03284cac10c98e`. PR93 integrated the paired
deletion backend and forward migrations as a disabled, undeployed candidate.
Its passing source gates do not establish hosted Apple or deletion acceptance.
The older mixed browser/SDK worktree remains preserved and must not be merged
wholesale. This branch reuses only callback guard1ceba3e, storage isolation750a845
and browser lifetimef535775; requalify their combined behavior before committing.

The user parked SDK lifecycle research in HealthComp issue92. Do not resume a
private fork, activate a dependency change, or treat historical SDK research
instructions as the next task. This deferral does not waive session isolation,
server-confirmed sign-out or zero previous-profile local-data requirements.

Next implement the app-owned serialized authentication and paired deletion
operations using the shared project client. Keep all browser controls disabled
until the implementation and real configuration are qualified. The deletion
backend returns only an opaque request_id in its dedicated callback, never an
Apple code or Supabase session. Validate the callback against its owning pending
request and send completion with that operation's in-memory claim verifier.
Preserve explicit deletion confirmation and server-confirmed local teardown;
even resume:true is a deletion operation, not a read-only probe.

## Approval and verified starting state

The user approved adding/testing the option in staging with no personal iCloud or production changes. Worktree `.worktrees/feature-staging-apple-web-sign-in`, branch `feature/staging-apple-web-sign-in`, starts at merged main `e20aa039b2517ab8d5dcd8c84c2c4f7abdeb6bfb`. Preserve original main's unrelated Package.resolved edit and all historical worktrees. Prior exact-main CI is the integration baseline; any new checks below report only their own scope.

September 5 read-only provider inspection found Apple enabled with only `com.narenyenuganti.HealthComp.staging` in Client IDs. No OAuth secret was revealed or assessed. Apple Developer's Services IDs list contained no registrations; the authenticated team is the app's configured team. Neither dashboard was edited. Native/web subject continuity, web callback registration and secret availability are not established.

Live source and the cached exact-tag SDK both pin 2.55.1. The 2.49.0 Task 9 reference is historical and must not guide this implementation.

## Chosen design and rejected shortcuts

Use an optional operation on the existing `AuthenticationClient` rather than replacing native sign-in or creating another project-wide Supabase client. Keep browser controls absent until the paired authentication/deletion design and configuration are ready. Production and DEBUG Test Lab behavior remain unchanged.

Reject a personal system Apple-account switch, session transfer/import, a local callback server, unconditional `onOpenURL -> auth.session(from:)`, and accepting another Apple audience without correct code exchange/revocation binding. No second physical phone is required. Browser evidence does not satisfy a separate native-authorization gate.

The current native deletion adapter always calls `ASAuthorizationAppleIDProvider`; a browser-selected second account would not match the personal account. The server correctly rejects the subject mismatch, but `begin_account_deletion` already creates a prepared record, so a mismatch probe is not read-only. Never run one as an inventory check.

## Task 1 — Local staging and callback contract (no live wiring)

**Files:**

- Create `HealthComp/Services/StagingAppleWebAuthenticationConfiguration.swift`.
- Create `scripts/tests/staging-apple-web-contract.swift` and `scripts/test-staging-apple-web-contract.sh`.

1. Write a standalone Foundation-only contract harness, compiling the actual app source in both ordinary and `HEALTHCOMP_STAGING` builds. Use one temporary directory, no Simulator, network, credentials or SDK session.
2. Observe missing implementation RED; then use a minimal disabled configuration implementation to observe a real valid-staging assertion fail. Do not count compilation failure as behavioral coverage.
3. Implement fail-closed configuration: explicit staging compilation, exact staging bundle and HTTPS project origin, an explicit opt-in. Define the dedicated fixed `healthcomp-staging-auth://apple/callback` return route. Do not enable it or register it with the app yet.
4. Validate operation-owned PKCE callback shape: exact scheme/host/path, no userinfo/port/fragment, exactly one nonempty bounded code, no duplicate/extra/error query parameters. This is URL-shape validation, not proof of PKCE, freshness, server identity or session isolation.
5. Run the harness GREEN and a permissive-validator mutation control RED. No raw callback, code or credential values may appear in receipts. Review this slice independently before committing.

Run `bash scripts/test-staging-apple-web-contract.sh`. Expected: bounded counts for ordinary-build denial and staging positive/negative cases; no external effects.

## Task 2 — Operation-owned browser/session adapter

**Files:** `AuthenticationClient.swift`, `SupabaseAuthenticationClient.swift`, a narrowly scoped browser adapter, and `AuthenticationClientTests.swift`/new focused test file.

1. Add failing tests for optional availability, normal cancellation, late callback after cancellation, concurrent native/browser attempts, wrong route, and session changes during exchange. Observe actual session-persistence behavior, not just reducer epochs.
2. Add the optional `signInWithAppleInBrowser` closure; nil means unavailable. Use the one shared client's PKCE support and a custom `ASWebAuthenticationSession` launch closure with ephemeral browsing requested. Retain/cancel the browser and serialize conflicting authentication operations through exchange completion.
3. Reject configuration before presentation/network. Require an actually signed-out SDK state; never replace an active account via this route. Check cancellation before exchange; cancellation during exchange must finish/clean up the same operation before another can start. Old cleanup cannot clear a newer session.
4. Validate the owned callback before calling SDK session exchange; no callback/token logging. Normalize cancellation to the existing quiet `.cancelled` failure. Preserve native nonce validation and Test Lab zero-client construction.
5. Verify focused tests with one worker, no test clones/parallel testing, and bounded existing or owned build artifacts. Do not launch the user's staging app just to run unit tests.

## Task 3 — Paired browser deletion reauthorization

**Files:** existing deletion client/Edge tests, `supabase/functions/delete-account/index.ts`, a forward migration only if needed, and `docs/runbooks/account-deletion.md`.

Design checkpoint before implementation: the managed Supabase OAuth code is **not** an Apple authorization code. A fresh Apple web grant must bind the same authenticated profile, operation nonce and allowlisted Services ID without replacing the app session. Determine and review the hosted HTTPS return/claim mechanism before adding any endpoint. Never send signing material to the app.

The existing durable deletion record has no native/web client binding. Any dual-route implementation must persist the selected allowlisted client with token storage, and use that client for resumed revocation; do not globally swap `APPLE_SIGN_IN_CLIENT_ID`. Preserve native request compatibility and revocation -> anonymization -> Auth deletion -> server-confirmed local teardown. Add fresh-grant, wrong-subject/audience/nonce, cancellation, replay/retry and preserved-history tests without live private data.

This is a required paired design, not permission to weaken existing checks or silently hide deletion for browser users. No browser option is exposed as usable while this remains unresolved.

### Reviewed return/claim direction (source implementation still pending)

Use an opaque authenticated claim rather than placing an Apple authorization code in the app callback URL. Source inspection cannot prove that every platform and hosted URL/header logger excludes raw credentials. This choice implements the existing return/claim checkpoint without a local server or a personal iCloud change.

1. An authenticated begin request, made only after deletion confirmation, binds the current user/profile, fresh nonce, fixed staging Services ID/return URL and a digest of an app-owned in-memory claim verifier. The server returns an Apple authorization URL and short-lived request handle.
2. A separate ephemeral browser session requests an Apple code with state/nonce and no profile scopes. It never performs a Supabase login/session exchange.
3. A bounded HTTPS form-post callback accepts only an existing unexpired state and retains the code encrypted in Vault. It performs no token exchange, deletion or session mutation. The proposed hosted path is `/functions/v1/apple-deletion-callback` on staging only.
4. Return control to `healthcomp-staging-auth://apple/deletion-callback` with opaque correlation/status only. No Apple code, token or private profile identifier belongs in that URL. Only the owning browser operation accepts it.
5. The authenticated completion requires the same user/profile and app-owned verifier, atomically claims the request and exchanges the Apple code with the request's fixed client/redirect. Preserve issuer, subject, audience, nonce and expiry validation.
6. Store the refresh token and exact `apple_client_id` atomically in durable deletion progress; resume revocation using that exact allowlisted client. Preserve native two-field requests and the existing revocation, anonymization, Auth deletion and confirmed local teardown ordering.
7. Add private, RLS-forced request state through a forward migration, with no direct anon/authenticated table grants. Expired/cancelled requests must destroy temporary Vault material; replay cannot repeat code exchange. Legacy token-ready records require a verified client binding or zero-row preflight, never guessed backfill.
8. Extend recovery acceptance/restore handling so restored expired or consumed web requests cannot become usable. Test interruption before/after token persistence and preserved anonymized history.

This protocol was independently reviewed as the safer design direction, not implemented or deployed. Exact callback/Services ID/provider configuration and real deletion qualification remain future gates.

### Task 2 implementation checkpoints and open SDK boundary

- The operation-owned browser presentation helper has a Foundation-only lifecycle harness. It is not connected to `AuthenticationClient`, URL routing or any UI. Its conditional iOS factory requests ephemeral browsing and owns presentation/cancellation.
- Before PKCE wiring, session-removal evidence must distinguish the exact project session key from the SDK's `<session-key>-code-verifier`. Tests also cover the legacy `supabase.session` migration source and fresh login after failed legacy retirement. The provider explicitly preserves the SDK's existing project storage namespace.
- The owned Keychain adapter normalizes only `errSecItemNotFound` to absence, preserves the SDK's default namespace and writes, and keeps other errors fail-closed. Real Keychain tests use unique synthetic services. Simulator test hosts require local ad-hoc signing for Keychain entitlements; unsigned hosts fail with `-34018`, which is not evidence of the storage regression. CI signs only Simulator tests with `CODE_SIGN_IDENTITY=-`; device build gates remain unsigned.
- A serialized app-auth operation gate and SDK-backed transaction tests are still required. Pinned SDK2.55.1 persists PKCE responses after HTTP without a cancellation/CAS check; an already in-flight refresh can also repersist after local removal. A reducer epoch or before/after user-ID check does not close these races. Cleanup must match the exact owned session, not merely the same user.
- The next SDK test should use the real `AuthClient` with in-memory storage and a deterministic injected `Configuration.fetch` latch. Prove durable cancellation cleanup, newer-session preservation and no PKCE interference with pending-removal state. Do not expose the browser operation until these properties and paired deletion are qualified.

## Task 4 — Staging UI and configuration

**Files:** `AccountFeature.swift`, `AccountView.swift`, `AppFeature.swift`, `HealthCompApp.swift`, `project.yml`, generated project/Info.plist, xcconfig and focused reducer/view tests.

1. Test native remains primary; browser control appears only for the eligible signed-out staging app; duplicate taps do not overlap; availability survives cancellation/retry/sign-out.
2. Route success through existing sign-in response, bootstrap and serialized profile mounting. Do not bypass installation retirement or profile teardown. Preserve all reconstructed account states.
3. Add the explicit staging compilation condition and staging-only auth URL registration. Production must not advertise or accept this callback; preserve invitation handling and no-domain/universal-link scope.
4. Keep the opt-in off until Tasks 2 and 3 are reviewed and their hosted configuration is ready. A manual Boolean is not evidence of deletion qualification.

## Task 5 — Exact external configuration and runtime qualification

1. Read the current staging App ID/primary association and signing-key configuration; inspect no secret values in transcript. Preview exact Services ID, HTTPS return URLs and credential scope before creating an Apple signing credential. Passwords/2FA stay in Apple's UI.
2. Register a staging-only Services ID associated with the staging App ID, using the hosted Supabase callback. Preserve the native ID and any unrelated registrations. Supply a Services-ID client secret to staging Auth privately, Services ID first in the mixed-ID allowlist. Record expiry/rotation ownership, not secret material.
3. Configure only the exact required staging app return URLs plus reviewed deletion callback. No wildcard production redirect, new auth provider, manual identity linking, database grant or production change.
4. Build a reviewed exact staging candidate; state-preserving over-install on the dedicated Simulator, then the idle physical phone. Minimize external app windows. Require user password/2FA entry only when needed.
5. Demonstrate legitimate second-account choice, existing subject/profile continuity, cancellation, server-confirmed sign-out and zero previous local profile data. Retain aggregate evidence only. Do not infer continuity from email/display name.
6. Qualify browser deletion reauthorization and retained history using the explicitly scoped test-account deletion workflow. Then continue genuine physical score/App Attest, one-phone replacement and remaining rollout gates. No broad production-ready claim.

## Review/integration and stop conditions

Each logical source slice gets focused RED/GREEN evidence and independent review. Full Core/iOS/Release/secret/privacy gates are serialized before integration; immutable migrations stay untouched. Do not merge an exposed browser login that lacks its deletion path. No new production deployment/configuration is authorized by this approval.

Stop at unavailable credentials, an uncertain Apple App ID association/client identity, unsupported callback/grant behavior, or a consequential unapproved external credential change. Report exact completed slices and the minimal input; do not run repeated native login attempts or ask again which personal Apple account is on the phone.

## Primary references

- [Supabase Apple authentication](https://supabase.com/docs/guides/auth/social-login/auth-apple): separate Services ID, web callback, mixed-ID order and six-month client-secret rotation.
- [Pinned Swift AuthClient](https://github.com/supabase/supabase-swift/blob/v2.55.1/Sources/Auth/AuthClient.swift): operation launch closure, PKCE exchange and SDK session persistence.
- Existing `docs/runbooks/account-deletion.md`, Task 18/19 production plan and release evidence remain authoritative for real rollout gates.
