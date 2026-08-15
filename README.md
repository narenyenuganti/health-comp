# HealthComp

HealthComp is an iPhone Activity competition for private, two-person
competitions. The repository contains the authenticated Supabase path,
participant-scoped local storage, deterministic on-device scoring, durable
remote synchronization, notifications, App Attest enforcement, and
privacy-preserving account deletion.

This source is not yet production-ready. Hosted staging has not been deployed
and read back from this release unit, no production Supabase project has been
approved, and the required two-account and physical-device gates remain
pending. No HTTPS invitation domain has been selected, so universal links are
explicitly deferred.

## Current architecture

- Sign in with Apple creates one active Supabase profile per authenticated
  account.
- Each signed-in profile mounts an isolated local directory for its journal,
  outbox, remote materialization, and notification preferences.
- A creator shares a one-time invitation; the server stores only its digest.
  Accepted competitions contain exactly one creator and one invitee.
- The app re-reads the complete seven-day HealthKit window, computes
  deterministic daily scores on device, and uploads only the minimum
  competition score representation.
- Score revisions and remote changes are append-only, gap-free, idempotent,
  and protected by participant RLS and App Attest assertions.
- Realtime broadcasts and generic APNs notifications wake the app; the app
  then fetches participant-authorized state from the server.
- The server confirms finalization, immutable result history, awards, and
  deletion completion.
- Account deletion revokes Apple authorization, cancels unfinished work,
  deletes the Auth identity, and preserves completed shared history as Former
  competitor.
- DEBUG Test Labs provide deterministic local and multi-user UI fixtures
  without constructing live Supabase, HealthKit, or production-journal
  dependencies.

Raw HealthKit samples, values, goals, workouts, routes, heart rate, and local
reversible fingerprints never leave the device.

## Environment status

| Environment | Current truth |
| --- | --- |
| Development | Disposable local Supabase stack for backend tests plus deterministic DEBUG Test Labs for iOS. The live app requires an HTTPS Supabase URL. |
| Staging | healthcomp-staging, ref xhfdfdrtxwptrwhvvlhg, was observed ACTIVE_HEALTHY through the authenticated CLI on 2026-08-15 at reviewed base 083515c. That observation predates this Task 18 release unit; migrations, Functions, providers, secrets, schedules, backup state, deployment of this release, and physical-device behavior still require hosted readback. |
| Production | No project has been approved. Do not infer that the inactive generic project is production. |

See the [environment and promotion runbook](docs/runbooks/supabase-environments.md)
before any hosted change.

## Tech stack

- Swift 5.9, SwiftUI, and The Composable Architecture
- CompetitionCore, a Foundation-only deterministic domain package
- HealthKit, UserNotifications, AuthenticationServices, and DeviceCheck
- Supabase Swift 2.49.0
- PostgreSQL 17, pgTAP, Supabase CLI 2.113.0, and Deno 2.9.5
- XCTest and XCUITest with XcodeGen 2.46.0 as project source of truth
- Validation-only GitHub Actions with read-only repository permissions and
  immutable action pins

## Project structure

~~~text
.github/workflows/                  backend and iOS validation-only CI
Configuration/                      fail-closed checked-in build configuration
HealthComp/                         iOS app, live composition, and adapters
HealthCompTests/                    iOS unit and integration tests
HealthCompUITests/                  deterministic lifecycle/accessibility tests
Modules/CompetitionCore/           deterministic event-sourced domain engine
docs/plans/                         reviewed implementation boundaries
docs/runbooks/                      release, support, deletion, and recovery
scripts/                            backend isolation and credential guards
supabase/                           live migrations and Edge Functions
SupabaseLegacy/                     historical reference; never deploy
project.yml                         XcodeGen project definition
~~~

Only lowercase supabase/ is executable backend source. SupabaseLegacy/ must
never be linked, reset, pushed, repaired, or deployed.

## Local setup

1. Install Xcode and an iOS simulator compatible with the project.
2. Install XcodeGen 2.46.0, Supabase CLI 2.113.0, and Deno 2.9.5.
3. Start Docker before running the local Supabase test stack.
4. Generate the Xcode project from the repository root:

   ~~~bash
   xcodegen generate
   ~~~

5. Open HealthComp.xcodeproj.

The checked-in Base and Development configurations intentionally contain no
Supabase URL or key. Public hosted app inputs belong only in ignored files:

- Configuration/Development.local.xcconfig
- Configuration/Staging.local.xcconfig
- Configuration/Production.local.xcconfig

Use a project URL and publishable key from the same environment. Never place a
service-role key, secret key, database password, Apple key, or APNs key in an
app configuration. See the environment runbook for the exact file shape and
promotion boundary.

For deterministic UI work, enable one DEBUG Test Lab through its documented
launch arguments. Test Lab paths use fixtures and deliberately avoid the live
dependency graph. Real Sign in with Apple, HealthKit authorization/background
delivery, APNs, and App Attest require a signed physical-device build.

## Verification

Run the fast static boundary first:

~~~bash
set -euo pipefail
bash scripts/test-verify-no-secrets.sh
bash scripts/verify-no-secrets.sh
bash scripts/verify-supabase-layout.sh
deno fmt --config supabase/functions/deno.json --check supabase/functions
deno lint --config supabase/functions/deno.json supabase/functions
git diff --check
~~~

Run backend gates serially against one disposable local stack:

~~~bash
set -euo pipefail
schema_diff="$(mktemp "${TMPDIR:-/tmp}/healthcomp-schema-diff.XXXXXX")"
cleanup() {
  supabase stop --no-backup >/dev/null 2>&1 || true
  rm -f -- "$schema_diff"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

supabase start
supabase db reset
supabase test db
deno test \
  --config supabase/functions/deno.json \
  --allow-env \
  --allow-net \
  --allow-read \
  supabase/functions
bash scripts/verify-invitation-functions.sh
supabase db lint --local --level warning --fail-on warning
supabase db diff --local >"$schema_diff"
test ! -s "$schema_diff"
supabase stop --no-backup
trap - EXIT INT TERM HUP
rm -f -- "$schema_diff"
~~~

Run CompetitionCore in both configurations:

~~~bash
set -euo pipefail
swift test --package-path Modules/CompetitionCore
swift test --configuration release --package-path Modules/CompetitionCore
~~~

The canonical hosted command matrix is checked into:

- [Backend CI](.github/workflows/backend.yml): secret/layout guards, fresh
  migration reset, 713 pgTAP assertions, Deno tests including real local JWT
  invitation coverage, database lint, and zero schema diff.
- [iOS CI](.github/workflows/ci.yml): deterministic XcodeGen, Core Debug and
  Release, HealthCompTests on iOS 18.5, and unsigned Debug, Staging, and Release
  builds.

Do not run the backend and Xcode/simulator matrices concurrently on a bounded
development machine. Keep DerivedData and local Supabase artifacts temporary,
stop the stack after use, and delete only exact known scratch paths.

## Operational runbooks

- [Supabase and Apple environments](docs/runbooks/supabase-environments.md):
  explicit project selection, promotion, Apple provider/capabilities, App
  Attest, APNs, schedules, and the no-domain deferral.
- [Competition support](docs/runbooks/competition-support.md): privacy-safe
  read-only diagnosis, standard idempotent sweeps, and unsupported operator
  mutations.
- [Account deletion and recovery](docs/runbooks/account-deletion.md): durable
  Apple-bound phases, safe retry, terminal anonymization, and local teardown.
- [Backup and restore](docs/runbooks/backup-restore.md): platform backup versus
  logical export, staging-only rehearsal, aggregate integrity evidence, and
  destructive approval boundaries.

## Release boundary

Before a private beta of up to 25 people, the rollout still requires:

1. explicit production-project selection and isolated staging/production
   configuration;
2. clean hosted backend and iOS CI on the exact reviewed commit;
3. staging migration, Function, provider, secret-name, schedule, and backup
   readback;
4. two real accounts completing invitation, seven-day score/revision,
   finalization, history, notification, and deletion scenarios in staging;
5. adversarial participant-isolation and replay/idempotency checks;
6. physical-device Sign in with Apple, HealthKit, background delivery, APNs,
   App Attest, and account-deletion evidence;
7. a successful staging restore rehearsal with matching anonymized counts and
   aggregate result hash.

Universal-link evidence remains blocked until an HTTPS invitation domain is
approved. The healthcomp URL scheme is a controlled fallback/testing route,
not the final production invitation link.

No dashboard screenshot, simulator pass, unsigned build, or successful source
test alone makes the product production-ready.

## Scoring contract

The default policy adds the participant's Move, Exercise, and Stand or Roll
goal percentages and caps each accepted day at 600 points. Policy identity,
quantization, unavailable data, revisions, reconciliation, and the frozen
seven-day ledger are explicit domain state. The app does not claim
undocumented Apple score quantization.

## License

Private
