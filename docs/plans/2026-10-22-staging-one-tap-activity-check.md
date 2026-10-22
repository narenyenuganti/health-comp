# One-tap Staging Activity check

Base: `04d1792071285bbc206dd45547699ed075be1dae`.

## Evidence and scope

The October 22 physical check visibly armed the existing Activity observation,
then made one intended drag on Sharing. The observation remained Ready and was
cleared without a second gesture. That does not prove a scoring defect or that
the UI action never fired: remote reconciliation waits for its operation gate
before entering the observer. Staging scoring Function v17 is source-verified;
physical acceptance is still unproved.

The user asked for an autonomous workflow without timed Terminal copying or
unnecessary phone interactions. Add one Staging-only diagnostic button that
arms the existing observation and immediately requests the existing
`competition(.pullToRefresh)` action. Keep Diagnostics visible so its fixed
counts can be read without navigating away and back.

Reuse AccountSheet's existing ownership of the main store and its callback
pattern. Do not add a singleton refresh callback, new account delegate,
background task, persistent state, dependency, endpoint or debugger access.
The callback must not run if arming fails. Preserve one-shot/expiry/owner
retirement rules and the normal operation gate. Do not reset keys, queues or
accounts, change validation/retry behavior, or change production behavior.
Do not arm or reveal the separate HTTP request-reference capture.

Update the diagnostic instructions so they describe the button truthfully.
Production must have neither a diagnostic button nor an actionable diagnostic
refresh callback. Hosts without a real refresh callback must not pretend to
run a check.

## Verification

Use the existing Activity diagnostic control and normal refresh action as the
test interfaces. Start with a failing test for one successful combined request
and its resulting fixed summary, then cover failed arming (including a second
request and an unavailable/retired owner) without dispatching refresh. Keep
existing expiry, cancellation, owner-replacement, HTTP capture independence,
and trigger-forwarding tests passing. Verify Staging-only UI/wiring and updated
copy, compile non-Staging and Staging configurations, then obtain independent
Standards and Spec review before exact-head CI and integration.

Local test/compile evidence is not physical scoring acceptance. No phone
installation, launch, refresh, hosted change or production action belongs to
this source-only implementation step.
