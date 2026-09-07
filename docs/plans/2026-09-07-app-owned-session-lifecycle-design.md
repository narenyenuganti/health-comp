# App-owned session lifecycle hardening

## Approved boundary

The user approved app-owned lifecycle hardening on September 7, without an SDK
fork or hosted changes. Preserve official Supabase Swift 2.55.1, one shared
project-wide client, the existing native flow and default-off browser controls.
This approval does not complete issue92 or authorize dependency replacement.

The user subsequently approved one shared client per authentication lifetime,
replaced only after confirmed retirement. This permits explicit fresh admission
after successful retirement, not per-operation or per-consumer clients. Failed
or pending retirement must deny access and replacement. The uncommitted candidate
now connects the verified registry, explicit storage removal, app-listener drain
and authentication coordinator. This is local fixture-tested candidate code,
not installed-device, hosted or integrated release evidence.

### Current candidate boundary

The live factory now supplies the post-runtime retirement callback. Native and
browser sign-in use explicit fresh admission; ordinary restoration after completed
retirement returns no session without creating another client. User sign-out
confirms the server before the app's separately retryable local-retirement stage.
Explicit storage retirement removes only configured session/legacy keys, verifies
removal and closes old callbacks under one lock. Failed removal retains the owner
and the pending-removal marker; old retirement cannot touch replacement storage.

Configured terminal-refresh and confirmed native/browser deletion paths now hand
off to retirement without premature local cleanup. App tests verify failed
retirement retries do not repeat server deletion, runtime or profile teardown.
Clients without retirement retain their previous inline-cleanup behavior. Explicit
sign-in admission rejects a populated lifetime, and a live signed-out app's warm
stop/restart does not allocate a replacement client.

Native and browser exchanges now share cancellation-after-persistence handling
tested with the actual live provider/storage guard and intercepted HTTP. Capture
the just-exchanged token only in memory, close registry admission, confirm a
session-local logout, then explicitly retire storage and drain app listeners.
Failed confirmation/removal retains the original owner for retry. A confirmed
logout is not repeated merely because local removal failed. Restoration and fresh
authentication report retirementRequired until cleanup completes; AppFeature
routes that outcome to its retryable retirement stage without global logout or
profile bootstrap. Native admission is checked before requesting credentials.

Storage writes close when removal preparation/retirement starts, not merely after
successful removal. Late old-owner writes cannot revive a cancelled session or
clear its pending-removal marker while cleanup awaits retry. Removal and verification
remain retryable; reads retain their existing fail-closed backing behavior until
full closure. These are app-owned guarantees, not whole-SDK shutdown or a durable
remote-receipt journal. The cancelled token and confirmation retry state remain
in memory; no credentials or identifiers are newly persisted by this work.

Before installation or integration, refresh the full exact-candidate matrix and
independent review; the earlier full Debug accessibility geometry failure is not resolved.
The detailed checkpoints below retain historical design context, not additional
evidence of completion. No SDK fork or hosted changes are authorized here.

## Approach

### Release scope clarification

The persisted decision in [issue92](https://github.com/narenyenuganti/health-comp/issues/92)
does not make an upstream response or a new SDK shutdown API a release gate.
Whole-SDK settlement remains an unproven property, not a demonstrated shipping
cross-account failure. Do not stall all app work on it or infer that a fork is
required. Conversely, the ticket does not waive a demonstrated isolation failure
or qualify the proposed rotating provider.

Keep candidate replacement uninstalled and unintegrated until its retirement
definition and all remaining paths are tested. App-level acceptance work traces each Auth, REST,
Functions and Realtime operation from captured owner through asynchronous
completion, including cleanup failure and delayed responses after teardown.
Use synthetic held-operation barriers and existing app reducers/adapters; do not
reproduce SDK vulnerabilities or exercise real accounts for this qualification.
Prove that old work cannot mutate the next profile, reopen retired storage, or
admit a fresh lifetime before server-confirmed completion and local cleanup.
App-created work must have explicit cancellation/settlement ownership. Report
SDK resource-settlement limits separately rather than substituting status,
deallocation or timers for a receipt.

Checking only that SupabaseClient deallocated is insufficient: its sub-client
fetch closures retain dependencies separately, AuthClient deinit schedules
session-manager shutdown, and Realtime deinit cancels internal tasks. This rules
out weak-reference disappearance as an all-work completion proof; it does not
by itself show a violation of the app's isolation contract.

Extend the existing app coordinator instead of adding a second auth client.
First, make explicit restoration participate in the same operation gate as
native/browser sign-in, sign-out and deletion. Restoration can refresh an
expired session and perform cleanup, so it is not an independent read. Reject
overlap before calling its dependency and release ownership only on settlement.
Keep the current fail-closed operationFailed behavior for overlapping calls.

This first slice is necessary but insufficient: SDK background work does not
enter this app coordinator. Subsequent design must establish session ownership
across persisted state, queued events and authenticated transport. User/profile
identity alone is not session ownership. Point-in-time Keychain absence is not
proof that all prior work settled. Do not conflate these properties.

Alternatives rejected for this slice: stopAutoRefresh alone has no awaited
all-work completion contract; SDK forking is outside the approval; replacing
the shared client per operation violates the project-wide client seam.

## Verification and sequencing

1. Add synthetic adapter-level tests for exclusive restoration ownership in
   both directions, without real accounts, SDK failure reproduction or network.
2. Observe the missing coordinator behavior, wrap restoration using the existing
   gate, and run focused adapter/app regressions.
3. Review session ownership and event/transport boundaries separately before
   choosing any further storage or lifecycle interface. Do not claim these
   boundaries are solved by step 2.
4. After the final candidate is reviewed, refresh the full test/build/secret
   matrix and integrate a conventional, scoped commit. Prior candidate tree
   57f914b2dcbd163b4cc83a5fd6440cbe3a877269 is historical after these edits.

No browser enablement, hosted deployment, real-account experiments, phone action,
credentials or private identifiers are needed for this first slice. Preserve
local profile data, server-confirmed remote completion and anonymized history.

## Ownership design checkpoint (not implemented)

The explicit adapter request boundary now includes restoration, bootstrap and
profile update. Its asynchronous event subscription remains concurrent. This
does not govern SDK background tasks or competition transports.

The official [session documentation](https://supabase.com/docs/guides/auth/sessions)
documents a UUID `session_id` claim in access tokens identifying an auth session.
Pinned SDK 2.55.1 also exposes an optional `sessionId` in its JWT claims type,
while its Session value does not expose a direct session identifier property.
Do not substitute the user's UUID or access-token equality for session identity.
The docs lookup alone does not qualify every refresh or migration path.

Proposed invariants for the next implementation design:

- Keep session identity internal and in memory; never put it in diagnostics,
  profile files or aggregate evidence receipts. It is not user-visible data.
- Pair session identity with an app-owned generation. A validly shaped identity
  is not a signature check, login permission or server authorization.
- Retirement must close admission for work owned by the retiring generation
  before reporting local completion. A snapshot read followed by asynchronous
  cleanup is insufficient; check ownership at the state-changing boundary.
- A fresh login must be explicitly admitted by the app coordinator. Ordinary
  background storage writes must not implicitly authorize a new account.
- An event must retain its originating ownership through queuing; stamping it
  with the current generation only when consumed cannot prove provenance.
  Current code has two AsyncStream mappings followed by a queued reducer action.
  Admission must cover the synchronous state mutation, not merely stream yield
  or send scheduling. Live events now carry AuthenticationEventOrigin through
  both mappings and the reducer uses withActiveOwner for synchronous mutation.
  Stream cancellation/draining and live retirement activation remain pending.
- Handle missing identity as an explicit qualification/error case rather than
  guessing from email, user ID or expiry. Preserve the DEBUG fixture boundary.

Before implementation, resolve how the SDK's storage callbacks (which expose
key/value rather than an operation lease) and sessionless signed-out events
will satisfy these invariants. If a proposed wrapper cannot prove provenance,
do not ship a permissive fallback or describe a partial guard as full isolation.
This checkpoint chooses the identity requirement, not a completed architecture.

## Per-lifetime provider alternative: feasibility findings

Implementation checkpoint: the provider now caches SupabaseAuthenticationLifetime,
an immutable unit containing the shared client and cleanup callbacks. Live storage
and configuration are constructed within its factory. Auth cleanup captures one
owner across awaits. Storage cleanup callbacks use the permanent storage guard.
Replacement/retirement are not activated. Event provenance/reducer admission is
implemented; stream retirement and HTTP/Realtime shutdown remain incomplete.
Findings below remain qualification requirements.

The app-created SDK event listener now belongs to an AuthenticationLifetimeTasks
set with permanent admission closure and cancel-and-await settlement. This drain
is not yet called by live retirement and does not own SDK-internal tasks. Retiring
code must not invoke drain from one of the tasks being drained. Outer mapping
stream settlement and complete transport shutdown still need qualification.

A possible app-owned approach binds immutable ownership to each SDK client
construction rather than trying to infer callback origin from current state.
All four consumers would still share one active project client, with no separate
Auth/REST/Functions/Realtime instances. Retired objects could outlive admission
but must have no access to the next lifetime's storage or callbacks. This would
change the current process-lifetime cache semantics and is not implemented.

Pinned-source checks identify the following requirements before adopting it:

1. Remove or qualify consumer-level cached client references, including the
   Realtime driver's cachedClient. Provider replacement alone would leave those
   consumers attached to the previous lifetime.
2. Give each construction a storage adapter with immutable lifetime ownership.
   Closing a lifetime must reject subsequent reads, writes and deletion of
   shared session state; a new lifetime must not reopen the old adapter.
3. Bind event subscriptions and callbacks to the construction that owns them.
   Ending the app stream must not relabel delayed old events as new events.
4. Own and invalidate each lifetime's HTTP URLSession. Do not claim this also
   closes Realtime: RealtimeClientOptions describes its session as a template,
   and the SDK creates a separate internal WebSocket session.
   Before invalidation, qualify request admission and in-flight settlement.
   Apple's invalidation delegate callback is immediate for invalidateAndCancel;
   it is not by itself an awaited completion receipt for every SDK caller.
   finishTasksAndInvalidate waits for session tasks, but still requires separate
   qualification of admission and the app/SDK tasks consuming those results.
5. Qualify Realtime retirement separately through supported interfaces, callback
   suppression and bounded retained objects. Do not equate synchronous
   disconnect invocation with awaited task settlement.
6. Preserve server-confirmed logout/deletion ordering, recovery on cleanup
   failure, zero-client DEBUG fixture behavior and ordinary session restoration.

Do not implement only a rotating provider cache and call the design complete.
An SDK object held by an old task or consumer must remain permanently unable to
affect a newer lifetime. Compare this alternative against the approved single
shared-client contract before changing its semantics; no replacement behavior
is enabled by this design note.
