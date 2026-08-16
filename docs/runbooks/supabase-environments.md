# Supabase and Apple Environments

This runbook is the source of truth for selecting, configuring, and promoting
HealthComp environments. It intentionally separates verified state from
required future work.

## Current environment inventory

Last read through the authenticated Supabase CLI and dashboard on 2026-08-15:

| Logical environment | Supabase target | Status | App configuration |
| --- | --- | --- | --- |
| Development | Disposable local CLI stack (project ID health-comp) | Verified locally | com.narenyenuganti.HealthComp, sandbox APNs, development App Attest |
| Staging | healthcomp-staging (xhfdfdrtxwptrwhvvlhg) | ACTIVE_HEALTHY; 14 migrations through 20260811000900 and nine Functions read back; Apple Auth and a topic-restricted server key are configured for the exact staging bundle; Function secrets, worker Vault entries, notification repair, and the corrected finalizer schedule are configured; both hosted jobs have succeeded | com.narenyenuganti.HealthComp.staging, sandbox APNs, development App Attest |
| Production | **TBD** | No project has been approved as HealthComp production | com.narenyenuganti.HealthComp, production APNs, production App Attest |

The 2026-08-15 staging promotion and readback established all of the following:

- the 14 local and remote migration versions match without gaps through
  `20260811000900`, and a second dry run is empty;
- all nine reviewed Edge Functions are `ACTIVE`;
- Apple Auth is enabled with only
  `com.narenyenuganti.HealthComp.staging` as its native Client ID; the optional
  web OAuth secret was not inspected and is not credited as evidence;
- `pg_net` 0.20.4 is installed in `extensions`, `pg_cron` 1.6.4 is installed in
  `pg_catalog`, hosted database lint reports no schema errors, and the private
  notification worker is not executable by `anon`, `authenticated`, or
  `service_role`;
- all 14 unconditional application-specific Function secret names are present;
  the conditional `HEALTHCOMP_AASA_APP_IDS` name is also present but remains
  un-routed and does not constitute invitation-domain or AASA evidence;
- one Apple key is restricted to sandbox APNs for only
  `com.narenyenuganti.HealthComp.staging` plus Sign in with Apple for the
  staging App ID; the private key was downloaded once and is not tracked;
- both notification-worker Vault names exist, the one-minute repair schedule
  continues to succeed, and its 2026-08-16 04:01 UTC pg_net request reached
  the worker with HTTP 200, no timeout or error, and zero leased, sent,
  retried, invalid-token, discarded, or unresolved work;
- the first five-minute finalizer run failed with `service_role_required`
  because hosted pg_cron executes as `postgres` without PostgREST JWT claims.
  The exact failing job was removed. Reviewed forward migration
  `20260811000900` is now applied, hosted lint reports no schema errors, and
  the corrected private five-minute job first succeeded at 2026-08-16 04:00
  UTC with no due competition left unfinalized.

Staging is not operationally ready for two-account or physical-device
verification. Paid-team signing material and the required staging/physical
evidence remain pending.

The inactive project named “naren-polymath's Project”
(vleyumieoroaipedqpsp) is not production merely because it is the other
project in the organization. Renaming/reactivating it or creating a fresh
healthcomp-production project is a material decision. Stop and obtain explicit
approval before either action.

HealthComp uses local development plus two hosted projects. It does not require
a third hosted development project.

## Non-negotiable boundaries

- Only lowercase supabase/ is deployable. SupabaseLegacy/ is reference
  material and must never be linked, pushed, repaired, or deployed.
- Never use db push with include-all, migration repair, or Functions deploy
  with prune for this rollout.
- Never infer a deployment target from an existing .temp/project-ref. Link one
  explicit ref, verify the readback, perform one promotion, then unlink.
- Never put a Supabase access token, database password, service-role key, Apple
  private key, APNs private key, generated Apple client-secret JWT, or worker
  token in Git, an xcconfig, a command argument, or a support transcript.
- The iOS app receives only the public project URL and publishable key.
- Raw HealthKit samples, values, goals, routes, workouts, heart rate, and local
  reversible fingerprints never leave the device.
- Applied migrations are immutable. Correct a deployed migration with a new
  reviewed forward migration or restore an approved backup.
- CI is validation-only. The checked-in workflows use no hosted credentials and
  cannot deploy.

## Configuration ownership

Use GitHub Environments named staging and production if a deployment workflow
is added later.

Environment variables (not secrets):

- SUPABASE_PROJECT_REF
- SUPABASE_URL
- SUPABASE_PUBLISHABLE_KEY
- APPLE_BUNDLE_ID

Environment secrets:

- SUPABASE_ACCESS_TOKEN
- SUPABASE_DB_PASSWORD

Supabase Edge Function secrets are entered directly in the matching project's
dashboard or by a reviewed secret-loading process that does not place values in
shell history. List and compare names only:

~~~bash
supabase secrets list --project-ref "$SUPABASE_PROJECT_REF"
~~~

Required application-specific names:

- INVITE_TOKEN_DERIVATION_KEY_V1
- APNS_KEY_ID
- APNS_TEAM_ID
- APNS_TOPIC
- APNS_PRIVATE_KEY
- HEALTHCOMP_NOTIFICATION_WORKER_TOKEN
- APPLE_SIGN_IN_KEY_ID
- APPLE_SIGN_IN_TEAM_ID
- APPLE_SIGN_IN_CLIENT_ID
- APPLE_SIGN_IN_PRIVATE_KEY
- APP_ATTEST_APP_ID
- APP_ATTEST_ENVIRONMENT
- APP_ATTEST_ALLOWED_VALIDATION_CATEGORIES
- APP_ATTEST_ALLOWED_BUNDLE_VERSIONS

HEALTHCOMP_AASA_APP_IDS is required only after an HTTPS invitation domain is
approved. Supabase supplies SUPABASE_URL, SUPABASE_ANON_KEY, and
SUPABASE_SERVICE_ROLE_KEY to deployed Functions; do not replace those
platform-managed values.

The notification worker also requires two Vault entries:

- healthcomp_notification_worker_url
- healthcomp_notification_worker_token

The Vault token and HEALTHCOMP_NOTIFICATION_WORKER_TOKEN must be the same
high-entropy value. Never retrieve either value into support output.

## Local iOS configuration

Public app inputs belong in ignored files:

- Configuration/Development.local.xcconfig
- Configuration/Staging.local.xcconfig
- Configuration/Production.local.xcconfig

Example shape:

~~~xcconfig
SUPABASE_URL = https:/$()/PROJECT_REF.supabase.co
SUPABASE_PUBLISHABLE_KEY = sb_publishable_VALUE_FROM_THE_SAME_PROJECT
HEALTHCOMP_INVITE_HOST =
~~~

The empty $() preserves // through xcconfig parsing. Never copy a sb_secret_
value or legacy service-role JWT into an app configuration.
HEALTHCOMP_INVITE_HOST stays blank until its exact HTTPS domain and AASA
response pass physical-device verification.

Before a signed build, inspect the resolved settings without printing a key:

~~~bash
xcodebuild \
  -project HealthComp.xcodeproj \
  -scheme "HealthComp Staging" \
  -configuration Staging \
  -showBuildSettings |
  grep -E 'PRODUCT_BUNDLE_IDENTIFIER|APS_ENVIRONMENT|APP_ATTEST_ENVIRONMENT'
~~~

Do not include SUPABASE_PUBLISHABLE_KEY in captured logs.

## Guarded promotion procedure

Run this from a clean checkout of the exact reviewed commit. Promote to staging
first. Repeat for production only after staging evidence is accepted.

### 1. Verify local source

~~~bash
git fetch origin --prune
git status --short --branch
git rev-parse HEAD origin/main
bash scripts/verify-supabase-layout.sh
bash scripts/verify-no-secrets.sh
~~~

Require a clean tree, an expected commit, and identical HEAD/origin/main.
Review the ordered filenames under supabase/migrations/. Stop if any path
points at SupabaseLegacy/.

### 2. Select exactly one target

For staging:

~~~bash
export HEALTHCOMP_ENVIRONMENT=staging
export SUPABASE_PROJECT_REF=xhfdfdrtxwptrwhvvlhg
~~~

Production has no approved ref. Do not substitute one.

Confirm the selected project name, organization, region, database major
version, and health with supabase projects list. The database major version
must match supabase/config.toml (17).

### 3. Link and read back

Ensure no previous link is active:

~~~bash
supabase unlink
supabase link --project-ref "$SUPABASE_PROJECT_REF"
~~~

Let the CLI securely prompt for the database password, or supply
SUPABASE_DB_PASSWORD through the approved environment secret mechanism.
Never pass the password as a literal command argument.

Read supabase/.temp/project-ref and require it to equal the exported ref
exactly. If it differs, unlink and stop.

Capture the pre-deployment migration list in an access-controlled temporary
file:

~~~bash
supabase migration list --linked > \
  "/tmp/healthcomp-$HEALTHCOMP_ENVIRONMENT-migrations-before.txt"
~~~

If the remote history contains an unexpected migration, a historical
SupabaseLegacy timestamp, or a divergent applied/local pairing, stop. Do not
repair history.

### 4. Dry-run and apply migrations

~~~bash
supabase db push --linked --dry-run
~~~

Review every proposed filename. A fresh environment should receive only the
checked-in lowercase migration chain. After explicit action-time approval:

~~~bash
supabase db push --linked
supabase migration list --linked > \
  "/tmp/healthcomp-$HEALTHCOMP_ENVIRONMENT-migrations-after.txt"
~~~

Compare before, proposed, and after lists. The post-list must be gap-free and
contain each expected migration exactly once.

### 5. Configure secrets and deploy Functions

Verify all environment-specific secret names before deployment. Then deploy
serially:

~~~bash
supabase functions deploy \
  --project-ref "$SUPABASE_PROJECT_REF" \
  --jobs 1
supabase functions list --project-ref "$SUPABASE_PROJECT_REF"
~~~

Do not add no-verify-jwt on the command line. The reviewed
supabase/config.toml is authoritative for Functions that perform their own
modern bearer verification. Do not use prune.

Read back deployed function names and versions. Smoke tests must use dedicated
staging identities and must not print access tokens, invite tokens, emails,
profile names, or score data.

### 6. Unlink and clear transient state

~~~bash
supabase unlink
unset HEALTHCOMP_ENVIRONMENT SUPABASE_PROJECT_REF SUPABASE_DB_PASSWORD
~~~

Delete only the exact temporary migration-list files after their non-sensitive
result has been recorded.

## Apple and Supabase provider checklist

Perform this separately for staging and production. A check mark requires live
portal/dashboard readback; source configuration alone is not proof.

1. Confirm the signed-in Apple account is an active member of the paid team
   that owns the App ID. Record the team ID only after reading Membership
   Details; do not infer it from an old project setting.
2. Register the exact App ID:
   - staging: com.narenyenuganti.HealthComp.staging
   - production: com.narenyenuganti.HealthComp
3. Enable Sign in with Apple, Push Notifications, HealthKit with background
   delivery, and App Attest for that App ID.
4. Do not add an Associated Domains entitlement, route, or domain until an
   invitation domain is selected. A portal capability toggle by itself is not
   signed-app or domain-association evidence.
5. Regenerate and install the provisioning profile after capability changes.
6. In the matching Supabase project, enable Apple Auth and register only the
   matching bundle ID as the native Client ID.
7. Configure the Apple provider key ID, paid-team ID, and generated client
   secret. Record the client-secret expiry date and rotate before expiry.
   Never store the generated JWT or .p8 in Git.
8. Keep Apple's server-to-server notification endpoint blank unless a reviewed
   handler is implemented.
9. Configure the deletion Function with the same environment's
   APPLE_SIGN_IN identity and private key.
10. Verify a real native ID token in that environment on a physical device.

## App Attest policy

Each project accepts one exact App ID and environment:

| Environment | APP_ATTEST_APP_ID | Environment | Categories | Current bundle versions |
| --- | --- | --- | --- | --- |
| Staging | PAID_TEAM_ID.com.narenyenuganti.HealthComp.staging | development | 3 | 1 |
| Production TestFlight | PAID_TEAM_ID.com.narenyenuganti.HealthComp | production | 2 | 1 |

Add category 4 only when an App Store build actually exists. Update the
bundle-version allowlist deliberately before distributing a new
CFBundleVersion; do not use wildcards. App Attest demonstrates possession of an
Apple-attested app instance and replay-resistant assertions. It does not prove
that HealthKit values are truthful.

## APNs policy

- Staging uses sandbox APNs and topic
  com.narenyenuganti.HealthComp.staging.
- TestFlight/production uses production APNs and topic
  com.narenyenuganti.HealthComp.
- Store the APNs .p8, key ID, and team ID only as environment-scoped Function
  secrets.
- Record token registration and foreground/background delivery only from a
  physical-device test. A simulator or successful generic build is not APNs
  evidence.
- The worker payload stays generic and route-only. Never add display names,
  points, Health data, or invitation tokens.

## Finalizer and notification repair schedules

These schedules are hosted environment state, not proof supplied by source.
Create them in staging first through Supabase Cron after migrations and worker
Vault entries are configured:

| Job name | Schedule | Command |
| --- | --- | --- |
| healthcomp-finalize-due | every 5 minutes | select private.run_due_competition_finalizer(); |
| healthcomp-notification-repair | every minute | select private.request_competition_notification_worker(); |

The finalizer definition requires migration `20260811000900`. Do not recreate
the job with the public RPC: hosted pg_cron has no service-role JWT claims, and
that command fails closed with `service_role_required`.

Staging readback on 2026-08-16 UTC confirmed both exact definitions active
under `postgres`. The corrected finalizer first succeeded at 04:00 UTC. The
notification repair job succeeded at 04:00 UTC and again at 04:02 UTC; its
04:01 UTC pg_net response returned HTTP 200. At readback there were no due
unfinished competitions, pending-due notification rows, or active/expired
leases.

Before creating or replacing anything, read the exact existing jobs:

~~~sql
select jobid, jobname, schedule, command, active
from cron.job
where jobname in (
  'healthcomp-finalize-due',
  'healthcomp-notification-repair'
)
order by jobname;
~~~

Apply only the two reviewed definitions and do not edit unrelated jobs. Verify
recent executions:

~~~sql
select j.jobname, d.status, d.start_time, d.end_time
from cron.job j
join cron.job_run_details d on d.jobid = j.jobid
where j.jobname in (
  'healthcomp-finalize-due',
  'healthcomp-notification-repair'
)
order by d.start_time desc
limit 20;
~~~

Cron success alone is insufficient. Also confirm due competitions progress and
pending/leased notification work does not remain past its retry window.

## Invitation-domain deferral

No HTTPS invitation domain has been selected. Therefore:

- HEALTHCOMP_INVITE_HOST remains empty;
- HEALTHCOMP_ALLOW_CUSTOM_INVITE_SCHEME is YES only in Staging and defaults to
  NO; an unconfigured build without that explicit opt-in fails before creating
  a server invitation;
- the Associated Domains entitlement is absent; the paid-team App ID capability
  was observed enabled, but no domain is configured and that toggle is not
  credited as evidence;
- HEALTHCOMP_AASA_APP_IDS is present in staging but is not routed or credited as
  AASA readiness;
- no DNS, TLS, route, cache, AASA, or physical universal-link evidence exists;
- healthcomp:// is generated only by the explicitly opted-in Staging build and
  remains a controlled fallback/testing route, not the final shareable
  production link.

The apple-app-site-association Function may be deployed but must not be routed
or credited as universal-link readiness. Once a domain is approved, configure
HEALTHCOMP_AASA_APP_IDS, add the exact applinks entitlement, serve
/.well-known/apple-app-site-association without redirect, verify headers and
cache behavior, and test cold/warm opening on a signed physical device.

## Completion evidence

For each hosted environment, retain only anonymized evidence:

- reviewed commit and migration before/after lists;
- deployed Function names/versions;
- provider/capability checklist with no key material;
- schedule definitions and non-sensitive run status;
- public build identifiers and configuration names;
- test counts, immutable result hashes, and timestamps;
- exact unresolved blockers.

Do not call an environment ready from dashboard configuration alone. Task 19
still requires two-account staging, adversarial isolation, and physical-device
evidence.

## Primary references

- [Supabase CLI workflows](https://supabase.com/docs/guides/local-development/cli-workflows)
- [Managing Supabase environments](https://supabase.com/docs/guides/deployment/managing-environments)
- [Deploying Edge Functions](https://supabase.com/docs/guides/functions/deploy)
- [Scheduling Edge Functions and Vault](https://supabase.com/docs/guides/functions/schedule-functions)
- [Supabase Sign in with Apple](https://supabase.com/docs/guides/auth/social-login/auth-apple)
- [Apple App Attest](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity)
- [Apple Associated Domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains)
