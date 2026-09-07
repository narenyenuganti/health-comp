# App privacy manifest implementation plan

> Use superpowers:executing-plans to implement this plan task by task.

**Goal:** Package truthful required-reason API declarations in HealthComp itself.

**Architecture:** Add one app resource with the three reasons supported by the
existing source. Verify both the source document and its placement at the built
app root. Do not change authentication, scoring, storage, network behavior or
the separate uncommitted authentication-lifetime candidate.

**Tech stack:** Apple privacy manifest plist, XcodeGen, Bash, plutil and jq.

## Boundary and source audit

Start from merged main `7c4079e8614eb2a8d3001b80ab03284cac10c98e` on
`bugfix/app-privacy-manifest`. Preserve the existing mixed authentication index
and the root checkout's unrelated Package.resolved change. No credentials,
hosted services, device state or SDK dependency change belongs to this fix.

Apple documentation inspected September 7:

- [Required-reason API requirements](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [Manifest packaging](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)
- [Approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)

| App-owned category | Reason | Existing use |
| --- | --- | --- |
| UserDefaults | CA92.1 | SupabaseConfiguration's AuthRemovalPendingStore reads/writes its own pending-removal flag in standard defaults. No shared app-group or system preference reads. |
| FileTimestamp | C617.1 | Profile/event/outbox/App Attest/notification/observer stores inspect metadata using fstat/lstat for files inside the app container. Metadata includes type, size and identity, not only timestamps. |
| SystemBootTime | 35F9.1 | CompetitionEnvironmentClient derives a boot epoch and monotonic instant for local elapsed-time/finalization comparisons. LocalCompetitionRuntime and FinalizationPolicy use these locally; remote score construction explicitly uses a wall-clock now() date and a fixed wire schema without uptime, boot epoch or monotonic fields. |

Dependency manifests cannot substitute for app declarations. Leaving the app's
manifest missing is not acceptable for distribution. Removing these APIs would
unnecessarily change existing storage/timing behavior, so declare their actual
uses instead. No required-reason API information is used for fingerprinting.

This manifest deliberately covers **required-reason APIs only**. It does not
declare `NSPrivacyCollectedDataTypes: []` or claim that the app collects no data.
Profile/authentication and derived competition data still need their truthful
release privacy disclosures. Raw HealthKit data remains on-device. Passing the
manifest check is not full privacy, App Store or production acceptance.

## Task 1: Missing manifest RED

Create `scripts/verify-app-privacy-manifest.sh`. With no arguments it validates
`HealthComp/Resources/PrivacyInfo.xcprivacy`. `--manifest PATH` validates an
explicit fixture; `--app-bundle PATH` requires the same valid document at the
app root, not a nested dependency resource. Reject missing/malformed documents,
unknown/duplicate categories, missing/wrong reasons and unreviewed extra keys.

Run `bash scripts/verify-app-privacy-manifest.sh` before adding the resource.
Expected: exit1 and `app_privacy_manifest_missing`.

## Task 2: Minimal declaration and packaging GREEN

Create `HealthComp/Resources/PrivacyInfo.xcprivacy` with the single top-level
NSPrivacyAccessedAPITypes array and the three category/reason pairs above.
Run XcodeGen to update only `HealthComp.xcodeproj/project.pbxproj`; the existing
HealthComp source directory includes resources, so no new runtime build flag is
needed. Run the validator and regenerate twice to verify determinism.

Add `scripts/test-app-privacy-manifest.sh` using disposable plist fixtures:
valid source/root bundle, missing source/root, nested dependency-only manifest,
malformed plist, missing/wrong/duplicate category and extra no-collection claim.
Each negative case must fail with a named validator receipt, never plist bodies.

## Task 3: Build and CI contract

Run source verification and negative controls in `.github/workflows/ci.yml`.
After each existing unsigned Debug/Staging/Release device build, run the bundle
validator on `$RUNNER_TEMP/HealthComp-DerivedData/Build/Products/${configuration}-iphoneos/HealthComp.app`.
Reuse bounded local DerivedData and serialize corresponding device builds with
two compile jobs and synthetic configuration. Check actual app-root manifests,
package lock preservation, whitespace and secret scan.

## Task 4: Review and integrate

Record exact RED/GREEN and build evidence. Obtain independent review before
integration; no new agent is authorized solely by this plan. Conventionally
commit the exact scoped resource/project/scripts/workflow/plan paths and run
exact-head CI before merging. The authentication candidate needs a later merge
of this resource change and regenerated project; its previous tests do not
automatically qualify a modified candidate. Keep hosted/physical acceptance open.
