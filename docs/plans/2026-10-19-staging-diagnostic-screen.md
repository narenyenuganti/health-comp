# Staging diagnostic reference screen

## Purpose and scope

The physical readiness-only debugger check failed before capture, and release
required closing Staging and cleaning up its orphaned Mac debugger. Another
identical attempt is not justified. Reuse the existing app-owned one-shot
capture through Account settings instead of adding a debugger dependency,
SDK fork, second client, local server or new server response.

The owner instructed the agent to make routine non-phone choices without
approval requests. Select a Staging-only temporary-display interface. Never
log, persist, share or copy its opaque request reference. A person, accessibility
tool, screenshot or OS snapshot could still record a visible reference; do not
claim screenshot prevention or secure memory erasure.

## Interface and invariants

- Only `HEALTHCOMP_STAGING` exposes the screen or its controls. Debug Test Lab
  and Release behavior stay unchanged.
- Account settings opens the screen. Explicitly arm once, return to Competition
  for one normal refresh, then return to inspect the reference within the
  original 60-second window. The screen itself never refreshes or sends HTTP.
- Reuse the same authentication-lifetime owner and exact request/header checks.
  Do not alter key reset/retry, verifier policy, scoring, or terminal outbox state.
- A read-only display snapshot does not consume or extend capture. A second
  matching task, cancellation, expiry or owner retirement removes it. It does not
  establish that a UI gesture caused the request.
- Reveal the reference only after an explicit Show action. Navigating away hides
  it; capture may remain armed while navigating to Competition. On scene
  inactivity, cancel any started capture but leave a never-armed slot off.
- UI reads recheck the existing deadline; periodic rendering is not a guarantee
  of instantaneous onscreen removal if iOS delays execution.

## Reach and verification

Use existing public interfaces as the test seams: operator controls, real shared
client/URLSession lifecycle, and the rendered Account settings flow. No test-only
backdoor or production diagnostic interface. Test one vertical slice at a time.

Affected callers: Account settings navigation, app scene lifecycle, capture
controls; existing Foundation and Staging XCTest fixtures; non-Staging absence
checks; operator instructions. Xcode generation is unchanged because the page
stays in the existing Account source file. No migration,
dependency, SDK, configuration value, hosted deployment or credential is needed.

Qualify display default-off/one-shot/deadline behavior, cancellation before and
after capture, owner retirement and replacement, and second-request ambiguity.
Keep the old destructive debugger entry points compatible but the live reader
disabled. Review immutable source before integration and require exact-head CI.
Any future installation, phone use or live log correlation is a separate physical
step, not authorized by these source-only tests. Existing paid/contact/production
holds remain; this diagnostic does not close scoring or the Goal.
