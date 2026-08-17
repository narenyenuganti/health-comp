# Supabase Ephemeral Transport Bugfix

## Problem

An authenticated staging relaunch reached the app-owned `Unable to connect`
state because every refresh-token POST failed locally with
`NSURLErrorNetworkConnectionLost` (`-1005`). The staging Auth logs contained no
request at the failure timestamps, while the same Simulator could reach the
project through Safari. A disposable URLSession probe using a synthetic refresh
token reproduced the boundary: shared and independently created default
sessions failed when the normal Supabase public headers were present, while an
ephemeral session reached Auth and received the expected HTTP 400 response.

## Decision

Construct the live Supabase client with one explicitly injected ephemeral
`URLSession` through `SupabaseClientOptions.GlobalOptions`. This is the SDK's
supported transport seam. Supabase authentication remains persisted by its
dedicated secure local-storage implementation; the HTTP session does not need
cookies, URL credentials, or a persistent response cache. Sharing one session
inside the provider also avoids creating a separate transport for each cached
service client.

Alternatives rejected:

- Retrying `-1005` on the unchanged shared/default session can repeat the
  failing transport path and can duplicate refresh-token requests.
- Applying a Simulator-only override would leave the reported physical-device
  failure mode unprotected and would not advance the production rollout.

## Verification

1. A focused test must first fail because the live transport is not ephemeral.
2. The test must prove the session disables persistent cookies, credentials,
   and URL caching and that the provider actually uses an injected session.
3. Existing Supabase configuration and authentication tests must remain green.
4. A Staging Simulator build must restore the existing authenticated session
   without replacing or clearing its profile-scoped local data.
5. No credentials, raw tokens, account details, or private screenshots enter
   source, test output, or release evidence.

## Result

- The focused configuration, authentication, profile-isolation, and remote-API
  gate passed all 52 tests.
- The canonical `HealthCompTests` gate passed all 457 tests with no failures or
  skips.
- CodeRabbit reported no findings in the uncommitted transport and test diff.
- A signed Staging build restored the existing authenticated Simulator profile
  without changing its data-container file count. Startup requests completed
  successfully, including authenticated HTTP 200 responses, and no `-1005` or
  missing-HealthKit-entitlement failure appeared.
- The Simulator receipt is transport and profile-persistence evidence only. It
  does not replace any required physical-device Sign in with Apple, HealthKit,
  background-delivery, APNs, App Attest, deletion, or universal-link gate.
