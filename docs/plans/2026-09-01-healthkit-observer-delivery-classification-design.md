# HealthKit Observer Delivery Classification Design

## Problem

`HealthKitProvider` currently labels every completion-bearing
`HKObserverQuery` callback as `observerWakeupBackground`. That label is written
unchanged into the profile-scoped delivery receipt. A normal foreground launch
can therefore create receipts that look like background delivery evidence.
Those receipts prove durable callback handling, but they do not prove that iOS
woke an already-backgrounded app.

The physical release gate needs a narrower, truthful claim. UIKit and SwiftUI
expose lifecycle state, not a HealthKit-specific launch reason. In particular,
an initial background phase does not prove that the process was already alive
or that HealthKit caused the launch. The app may only attribute a callback to a
warm background interval after this process has observed itself active and then
backgrounded without becoming active again.

## Constraints

- Capture classification synchronously at observer callback ingress, before
  asynchronous reconciliation or a later lifecycle transition can change it.
- Treat an initial, inactive, or background-at-launch state as ambiguous and
  fail closed to `observerWakeupForeground`.
- Emit `observerWakeupBackground` only while the process is in a background
  phase reached after an observed active phase.
- Keep HealthKit completion ownership, receipt-before-completion ordering,
  process-rooted replay, and profile-scoped teardown unchanged.
- Preserve the version 1 receipt document and its five privacy-safe fields; do
  not persist lifecycle traces, launch options, timestamps beyond the existing
  processed time, identities, Health data, or scores.
- Keep the deterministic DEBUG Test Lab independent of production lifecycle
  state.
- Do not claim cold-launch HealthKit provenance. Supporting that claim would
  require a separate launch-time observer architecture and evidence design.
- Do not reuse pre-fix receipts as physical proof. A physical gate must compare
  an exact transient pre-install baseline with the post-transition document and
  accept only a receipt newly appended by the selected artifact/process.

## Selected design

Add a small process-rooted, lock-protected
`HealthKitObserverDeliveryClassifier`. It accepts a closed app lifecycle phase
(`active`, `inactive`, or `background`) and remembers whether this process has
ever observed `active`. Its current trigger is:

- `observerWakeupBackground` only when the current phase is `background` and
  `active` was observed earlier in this process;
- `observerWakeupForeground` for every other state, including before any phase
  is observed and for an initial background phase.

`HealthCompApp` installs a process-rooted lifecycle bridge before constructing
its scene. The bridge observes `UIScene.willEnterForegroundNotification`,
`didActivateNotification`, `willDeactivateNotification`, and
`didEnterBackgroundNotification` synchronously through `NotificationCenter`.
The will-enter-foreground and will-deactivate hooks fail closed to inactive
before a potentially lagging SwiftUI update can leave the classifier at a stale
background value. The root scene also observes aggregate SwiftUI `scenePhase`
with its initial callback enabled, providing the initial snapshot and a
secondary source of the same closed phases. Tracking therefore remains alive
across signed-out, bootstrapping, and authenticated roots instead of being tied
to a profile or feature view.

`HealthKitObserverUpdateController` receives an injected trigger snapshot
closure. Its production closure reads the process classifier. The controller
invokes that closure as the first operation in `receive`, before acquiring the
controller condition, running ingress hooks, or yielding to an asynchronous
consumer. It carries the captured trigger on `HealthKitObserverWakeup`. The
provider signal actor then emits the captured trigger instead of substituting a
hard-coded background value. Test dependencies supply explicit triggers and do
not read global app state.

Both observer trigger cases still own HealthKit completion callbacks. One
shared `ActivityRefreshTrigger.isHealthKitObserverDelivery` predicate recognizes
exactly `observerWakeupForeground` and `observerWakeupBackground`; the fixture
source and receipt validator both use it so completion ownership and receipt
acceptance cannot drift. Other refresh triggers remain invalid in the delivery
receipt.

Rename the source-level contract and store to
`HealthKitObserverDeliveryReceipt` and `HealthKitObserverDeliveryReceiptStore`
so a foreground/ambiguous receipt cannot be mistaken for background proof by
its type name. Preserve the deployed `BackgroundDelivery` directory,
`background-delivery-receipts.v1.json` filename, schema version, and five-key
document as compatibility boundaries. The existing `trigger` field becomes the
authoritative observer-delivery classification; no migration is required.

## State transitions

| Prior state | Observed phase | Resulting attribution |
|---|---|---|
| Initial/unknown | `background` | Foreground/ambiguous |
| Initial/unknown | `inactive` | Foreground/ambiguous |
| Any | `active` | Foreground |
| Active observed | `inactive` | Foreground |
| Active observed | `background` | Background |
| Background | will enter foreground / `inactive` | Foreground |
| Background | `active` | Foreground |

The foreground value is intentionally conservative: it means “not proven to
be a warm background callback,” not necessarily that the UI was visibly active
at the exact callback instant.

## Rejected alternatives

1. **Use `UIApplication.shared.applicationState` at reconciliation time.**
   Rejected because lifecycle can change after callback ingress, producing a
   race and mislabeling the retained callback.
2. **Treat any initial background state as background proof.** Rejected because
   it cannot distinguish warm background delivery from process launch or
   restoration.
3. **Add a new ambiguous Core trigger or receipt schema version.** Rejected for
   this narrow fix because the existing foreground observer case is already a
   fail-closed representation and avoids broad journal/schema migration.
4. **Move or version the persistent receipt file.** Rejected because the
   current path is protected, bounded, profile-scoped, and already deployed;
   the source types can be renamed truthfully while the trigger field carries
   the distinction without a storage migration.

## Verification

Automated tests must prove the lifecycle state machine, initial inactive and
background fallbacks, active-to-background attribution, synchronous
will-enter-foreground reset, reactivation reset, and immutable capture at
callback ingress. Provider tests must prove both triggers reach the environment
signal with completion ownership intact. Receipt tests must prove both observer
cases round-trip under schema version 1 and unrelated triggers are rejected.
Remote-client tests must prove each observer trigger is retained through
durable commit-before-completion and failure retry behavior.

After focused and full automated matrices pass, a newly signed staging artifact
must replace the previously selected artifact. Only a callback received while
the app was observed transitioning from active to background may satisfy the
warm physical HealthKit background gate. The verifier must take an exact
pre-install baseline, compare signal identities only transiently, and retain
only a privacy-safe aggregate showing a newly appended receipt from the new
artifact/process after the controlled transition. Foreground, ambiguous, and
pre-fix receipts remain valid durability evidence but cannot satisfy that gate.
