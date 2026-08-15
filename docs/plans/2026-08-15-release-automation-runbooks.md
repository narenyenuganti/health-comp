# Release Automation and Operations Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add reproducible validation-only CI and truthful operational runbooks for HealthComp's local-development, hosted-staging, and hosted-production release path without deploying or committing credentials.

**Architecture:** Pull-request CI is split into an Ubuntu Supabase/Deno job and a macOS Swift/iOS job, both with read-only repository permissions and immutable action pins. Development remains a disposable local Supabase stack; staging and production are isolated hosted projects selected by an explicit project ref for every promotion. Runbooks distinguish implemented operations, live verified facts, deferred evidence, and blocked external configuration.

**Tech Stack:** GitHub Actions, Supabase CLI 2.113.0, Deno 2.9.5, PostgreSQL 17/pgTAP, Swift/XCTest, Xcode 16.4 with iOS 18.5 on `macos-15`, XcodeGen 2.46.0, Bash.

---

## Fixed decisions

- Use local Supabase for development and exactly two hosted projects for staging and production. Do not add a hosted development project.
- The confirmed staging project is `healthcomp-staging` (`xhfdfdrtxwptrwhvvlhg`). The production project is `TBD`; the inactive generic project must not be treated as production without an explicit decision.
- CI validates only local state. It receives no Supabase access token, database password, Apple key, APNs key, service-role key, or deployment permission.
- Hosted promotion is manual and serialized for the beta. Every promotion exports one target ref, links that exact ref, verifies the link readback, reads migrations before and after, and unlinks afterward.
- Never use `db push --include-all`, `migration repair`, or any path under `SupabaseLegacy/`.
- Associated Domains and universal-link evidence remain deferred because no invitation domain has been selected.
- Task 18 documents external staging/production operations but does not claim that provider configuration, deployment, schedules, backup restore, or physical-device evidence has run.

### Task 1: Add a mutation-sensitive credential and build-configuration guard

**Files:**

- Create: `scripts/verify-no-secrets.sh`
- Create: `scripts/test-verify-no-secrets.sh`
- Reuse: `scripts/verify-supabase-layout.sh`

**Step 1: Write the failing shell tests**

Create a disposable Git repository fixture and require the guard to:

- pass a clean repository with blank tracked Supabase build inputs;
- reject tracked `.env`, `.p8`, `.p12`, `.mobileprovision`, and `*.local.xcconfig` files;
- reject a PEM private-key block, `sb_secret_` value, GitHub token, AWS access key, literal JWT, and non-local password-bearing PostgreSQL URI;
- allow the documented local `postgres:postgres@127.0.0.1` test URI;
- reject a non-empty `SUPABASE_URL` or `SUPABASE_PUBLISHABLE_KEY` in tracked base/development configuration;
- report only a finding type and path, never the matched value.

**Step 2: Run the RED**

Run:

```bash
bash scripts/test-verify-no-secrets.sh
```

Expected: fail because `scripts/verify-no-secrets.sh` does not exist.

**Step 3: Implement the minimal guard**

Scan tracked Git blobs rather than the entire worktree so local ignored configuration and build output are never read or printed. Treat only loopback PostgreSQL credentials as a permitted test fixture. Check the two tracked Debug configuration sources structurally and delegate the historical-backend boundary to `verify-supabase-layout.sh`.

**Step 4: Run GREEN and the repository scan**

Run:

```bash
bash scripts/test-verify-no-secrets.sh
bash scripts/verify-no-secrets.sh
bash scripts/verify-supabase-layout.sh
```

Expected: all pass and no credential value appears in output.

### Task 2: Make the backend gate reproducible

**Files:**

- Create: `.github/workflows/backend.yml`
- Format only:
  - `supabase/functions/apple-app-site-association/index.ts`
  - `supabase/functions/apple-app-site-association/index_test.ts`
  - `supabase/functions/create-competition-invite/index.ts`
  - `supabase/functions/create-competition-invite/index_test.ts`
  - `supabase/functions/claim-competition-invite/index_test.ts`

**Step 1: Prove the inherited format RED**

Run:

```bash
deno fmt --config supabase/functions/deno.json --check supabase/functions
```

Expected: fail only on the five inherited files listed above.

**Step 2: Format only the known files**

Run `deno fmt --config supabase/functions/deno.json` with the five explicit paths, then rerun the full format check.

**Step 3: Add the validation-only workflow**

Use:

- `actions/checkout` pinned to `d23441a48e516b6c34aea4fa41551a30e30af803` (`v6`);
- `denoland/setup-deno` pinned to `22d081ff2d3a40755e97629de92e3bcbfa7cf2ed` (`v2.0.5`) with Deno `2.9.5`;
- `supabase/setup-cli` pinned to `46f7f98c7f948ad727d22c1e67fab04c223a0520` (`v3.0.0`) with CLI `2.113.0`;
- `permissions: contents: read`, branch-scoped concurrency cancellation, no secrets, and a bounded timeout.

The job must run the layout/credential guards, start a fresh local stack, reset migrations, run all pgTAP files, run the real local invitation/JWT integration, run Deno format/lint/tests (including race tests), lint the database with warnings fatal, write `supabase db diff --local` to a temporary file and require it to be empty, then stop the stack without backup.

**Step 4: Validate locally**

Parse the YAML, inspect action pins, and run the Deno format/lint/tests against one already-started disposable local stack. Do not start backend and Xcode gates concurrently.

### Task 3: Add deterministic Swift and iOS CI

**Files:**

- Create: `.github/workflows/ci.yml`

**Step 1: Add the macOS workflow**

Use `macos-15`, Xcode 16.4 at `/Applications/Xcode_16.4.app`, and the installed iOS 18.5 `iPhone 16 Pro`. Keep one sequential job so Core, simulator tests, and generic builds do not compete for disk.

Run:

- XcodeGen version assertion and two generations with identical project hashes and a clean tracked project diff;
- Core Debug and Release tests;
- `HealthCompTests` on the iOS 18.5 simulator with reserved non-secret Supabase fixture inputs;
- generic Debug, Staging, and Release device builds with signing disabled;
- final `git diff --check` and tracked-tree cleanliness.

Use a runner-temporary DerivedData path, disable the index store, and add no signing or provider secret.

**Step 2: Validate the workflow locally**

Parse the YAML and confirm every `uses:` reference is a full commit SHA. Run only a focused command-shape smoke locally; rely on the Task 17 469/469 iOS 18.4 evidence and the new PR run for the full hosted macOS gate.

### Task 4: Define guarded environment promotion

**Files:**

- Create: `docs/runbooks/supabase-environments.md`

Document:

- the three logical environments and current verified/TBD state;
- GitHub Environment variables versus secrets;
- explicit link, link-readback, migration-list, dry-run, push, function deployment, post-readback, and unlink order;
- the prohibition on historical migrations, `--include-all`, repair, pruning, and cross-environment reuse;
- per-environment Apple provider, App ID capabilities, provisioning, App Attest policy, APNs configuration, and schedule checklist;
- direct database finalizer and notification repair schedules, including verification queries;
- the no-domain Associated Domains/AASA deferral;
- rollback by restore or reviewed forward repair rather than rewriting applied migrations.

No real credential, private endpoint token, Apple identifier, email, or health datum belongs in the runbook.

### Task 5: Document support, deletion, and recovery truthfully

**Files:**

- Create: `docs/runbooks/competition-support.md`
- Create: `docs/runbooks/account-deletion.md`
- Create: `docs/runbooks/backup-restore.md`

**Step 1: Add read-only support diagnosis**

Use only implemented tables/functions. Redact user-facing identity and health data. State that raw invitation tokens are not recoverable, final scores are immutable, and direct row edits are forbidden. Mark invitation resend, operator cancellation, and arbitrary reconciliation mutation as unsupported until audited RPCs exist; do not invent commands.

**Step 2: Add account-deletion recovery**

Describe the implemented phase machine, safe read-only inspection, authenticated retry boundary, Apple revocation requirement, auth deletion, local cache wipe, completed-history anonymization, and escalation conditions. Preserve `Former competitor` history and never instruct operators to reverse-map anonymized records.

**Step 3: Add backup/restore rehearsal**

Separate automated platform backup/PITR facts from logical export. Require a staging-only restore rehearsal, pre/post counts plus immutable result-hash comparison, anonymized evidence, and explicit approval before any destructive restore. Record the rehearsal as pending until it actually runs.

### Task 6: Refresh operator entry points and verify the Task 18 unit

**Files:**

- Modify: `README.md`

Update the architecture status, current local verification commands, CI links, runbook links, raw-HealthKit boundary, and physical/staging evidence caveats.

Run focused gates, then the full Task 18 integration boundary serially:

```bash
set -euo pipefail
schema_diff="$(mktemp "${TMPDIR:-/tmp}/healthcomp-task18-schema.XXXXXX")"
cleanup() {
  supabase stop --no-backup >/dev/null 2>&1 || true
  rm -f -- "$schema_diff"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

bash scripts/test-verify-no-secrets.sh
bash scripts/verify-no-secrets.sh
bash scripts/verify-supabase-layout.sh
deno fmt --config supabase/functions/deno.json --check supabase/functions
deno lint --config supabase/functions/deno.json supabase/functions
supabase start
supabase db reset
supabase test db
deno test --config supabase/functions/deno.json --allow-env --allow-net --allow-read supabase/functions
bash scripts/verify-invitation-functions.sh
supabase db lint --local --level warning --fail-on warning
supabase db diff --local >"$schema_diff"
test ! -s "$schema_diff"
supabase stop --no-backup
trap - EXIT INT TERM HUP
rm -f -- "$schema_diff"
swift test --package-path Modules/CompetitionCore
swift test -c release --package-path Modules/CompetitionCore
git diff --check
```

Then run the iOS unit/build/XcodeGen commands encoded in `.github/workflows/ci.yml` with one bounded DerivedData directory. Stop Supabase and delete exact temporary artifacts after evidence is captured.

Request independent code and security review. Fix only validated findings with a new RED-to-GREEN cycle. Commit with:

```bash
git commit -m "ci: verify multi-user backend and iOS release"
```

Publish a ready PR, require the hosted backend and iOS workflows to pass on the exact head, and merge with a head-SHA guard.

## External completion gates after this source unit

1. Decide whether to rename/reactivate the inactive generic project or create a new `healthcomp-production` project. This is a material external choice and must not be inferred.
2. Configure and deploy staging with environment-scoped secrets, then read back migrations/functions/provider/schedules.
3. Create/configure production only after staging evidence is clean.
4. Rehearse a staging restore and preserve anonymized count/hash evidence.
5. Execute Task 19 two-account, adversarial, and physical-device verification. Universal links remain blocked until an HTTPS invitation domain is selected.
