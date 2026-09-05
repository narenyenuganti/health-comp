# Backup and Restore

This runbook separates Supabase platform database recovery from a CLI logical
export. Neither path is credited until a staging restore has actually been
rehearsed and its non-identifying integrity receipt has been compared.

## Execution readiness

**NOT QUALIFIED FOR EXECUTION.** The examples below are a reviewed procedure
draft, not an approved export/restore command sequence. Do not link, export,
import, create a target, or change a hosted setting from this document until
all of these prerequisites have their own verified evidence:

- explicit source/destination identity, capacity/cost, encrypted workspace,
  downtime window, operator, and action-time approval;
- one common recovery point covering the source receipts and every export,
  with an approved, enforceable freeze of all relevant writers or a separately
  validated shared-snapshot procedure;
- certificate and hostname verification on every database connection,
  including the actual dump process inside any container;
- destination quarantine verified before any import and maintained while
  imported schedules, network work, Auth data, and grants are present;
- a target-validated managed-schema/artifact manifest and an empty destination;
- independently completed deletion evidence, non-vacuous retained-history
  checks, and validated aggregate-only integrity queries for every required
  result format and competition;
- a reviewed forward-repair rehearsal and defined recovery measurements.

Missing evidence is a stop, not permission to weaken a check. Static snippet
tests and a successful dump cannot close these prerequisites or Task 18.

## Current evidence status

The following is **historical**, from the read-only inventory ending at
`2026-08-23T06:06:35Z`; it is not current project-health or entitlement proof:

- the authenticated healthcomp-staging backup page reports that the project is
  on the Free Plan and that project backups are not included; no restorable
  scheduled backup or PITR window is available;
- the dedicated `healthcomp-production` project exists and is active and
  healthy, but its backup availability, retention, PITR, RPO, and RTO have not
  been inspected or approved;
- no staging restore rehearsal has run;
- no recovery point objective or recovery time objective has been measured;
- no restore evidence may be reported as passing.

Read the matching project's Database Backups page immediately before planning
a recovery. Backup availability, retention, and PITR depend on current project
configuration and plan; this repository does not prove any of them.
See the dated [release evidence](../release/production-beta-evidence.md) for
later observations. None is permission to start a restore.

## Recovery boundaries

- Never restore production, overwrite a hosted project, invoke PITR, delete a
  project, or rotate a recovery credential without fresh action-time approval.
- Rehearse against a new, disposable, access-restricted staging restore target.
  Never point either shipping app bundle at that target.
- Select source and destination by explicit project ref. Read both names,
  organizations, regions, database versions, and health before proceeding.
- Only lowercase supabase/ is live source. Never restore, link, repair, or
  replay SupabaseLegacy/.
- Applied migrations remain immutable. After recovery, use a reviewed forward
  migration for any correction; never rewrite history or use migration repair
  to hide divergence.
- Preserve completed shared history and terminal anonymization. A restore must
  never reactivate an anonymized profile or reverse-map Former competitor.
- Never reopen a recovered production project when the recovery point may
  predate a completed account deletion. HealthComp does not yet have an
  external per-deletion suppression ledger that survives database rollback;
  absent independent proof that the recovery point is later than every
  completed deletion, keep the project offline and escalate.
- Raw HealthKit data is absent from the backend by design and therefore is not
  a backup input.

## What each mechanism covers

### Supabase automated backups and PITR

These are platform-managed database recovery mechanisms. The dashboard is the
only current source for available snapshots, PITR enablement, earliest/latest
recovery time, retention, and restore status.

A PITR restore changes the selected project's database and is destructive.
Treat a snapshot restore to an existing project the same way. Stop traffic,
capture current read-only evidence, choose an exact recovery timestamp, review
the target project ref, and obtain fresh approval before starting.

A database restore does not by itself prove that these environment surfaces
are correct:

- deployed Edge Function code and versions;
- Edge Function secrets;
- Apple Auth provider settings and client-secret expiry;
- App Attest and APNs configuration;
- Vault worker URL/token availability;
- Cron definitions and recent runs;
- iOS public URL/publishable-key configuration;
- DNS, TLS, invitation-domain, or Associated Domains state.

Read each surface back after recovery. Never copy production secrets into a
restore rehearsal.

### Supabase CLI logical export

The logical export is useful for portability and deterministic verification,
but is not equivalent to a platform snapshot or PITR.

- The default schema dump excludes Supabase-managed schemas such as auth,
  storage, realtime, cron, Vault, and migration history. Validate the exact
  definitions supplied by the actual destination instead of assuming them.
- A data-only dump intentionally includes application data and may include
  auth and storage table data while excluding internal migration tables and
  several platform schemas. It is highly sensitive even when HealthComp uses
  only Apple sign-in.
- In CLI 2.113.0, cron/network schemas are not excluded by the default data
  list. This does not prove that every operational payload is exported; it
  does require containment of any imported jobs or network work. Explicit
  schema selection changes the default exclusion behavior.
- Vault data is excluded. In-flight account-deletion refresh tokens and the
  notification worker URL/token are not a complete logical-backup surface.
- The ordinary data dump excludes `supabase_migrations`. Export its data as a
  separate history artifact, and validate whether the destination also needs
  a separately reviewed history-schema artifact. Do not assume four files are
  sufficient or synthesize missing history with migration repair.
- Function code, Function secrets, provider settings, and project settings are
  not recreated by the SQL artifacts.
- Storage database rows are not the same as object bytes. HealthComp does not
  currently rely on Storage for competition data, but future use requires a
  separate object backup procedure.

Logical dump files can contain emails, provider identifiers, session/auth
metadata, profile UUIDs, display names, score revisions, results, device
tokens, and support events. Never commit, attach, paste, index, or upload them
to an unapproved service.

### Pinned CLI and connection restrictions

CLI 2.113.0 source at `03880bb15379c308a73b078d98780eef1eb1bd63`
expands resolved connection values, including the password, into `db dump
--dry-run` stdout. `--file` does not redirect that dry-run output. Never capture
a credential-bearing or linked dry-run as a preflight receipt. Review the
public pinned scripts or credential-free synthetic inputs instead.

Its dump path passes host/port/user/password/database into the container, but
does not itself forward host certificate-verification variables or mount a
host CA file. Merely exporting `PGSSLMODE` on the Mac does not establish dump
transport. The draft CLI invocations below remain unqualified until an exact
execution procedure proves verification inside the dump process. This static
finding is not a claim of plaintext traffic or a live target configuration.

For direct `psql` receipt/import sessions, require `sslmode=verify-full` and a
reviewed readable CA through `sslrootcert`/`PGSSLROOTCERT`, with the exact
hostname bound to the intended project. Refuse missing/invalid CA or hostname
verification; do not fall back to `require`, `prefer`, or disabled TLS. Apply
the requirement independently to source, destination, and any pooler route.
Keep password entry in the human's private terminal. Raw import errors may
include row contents: retain only allowlisted error categories, not transcripts.

## Staging restore rehearsal

The first rehearsal uses healthcomp-staging as the source and a newly created
temporary project as the destination. It must not overwrite staging. Create or
delete that hosted target only with explicit approval.

### 1. Freeze the rehearsal scope

Record:

- reviewed source commit;
- source ref xhfdfdrtxwptrwhvvlhg and live project-name readback;
- destination ref and a name that clearly includes restore-rehearsal;
- matching PostgreSQL major version 17;
- recovery-point/cutoff timestamp and how it is established;
- operator and approver;
- named owner and bounded duration of the complete source write freeze,
  including app/API, Auth, scheduled workers, network work, migrations, DDL,
  and administrative writers relevant to the exported state;
- encrypted local workspace and cleanup owner.

Disable Apple provider sign-in, schedules, external Function calls, and app
distribution on the destination. Do not install production or staging secret
values. The new project's credentials must remain isolated from app builds.

Prove containment before the first import, including what prevents restored
active jobs or queued network requests from executing during data loading.
Default table-privilege revocation alone is insufficient. If the destination
cannot remain quarantined throughout schema/data import and validation, stop
before importing anything. Record only aggregate control outcomes.

Do not claim a source write freeze merely from unchanged migration versions or
table counts. Use a reviewed enforcement and breach-detection procedure that
covers all relevant writers; if any writer cannot be covered, stop and design
a consistent alternative. Keep the freeze through source receipt capture,
every artifact, and after-export validation. Any breach invalidates the entire
attempt, even if before/after counts happen to match.

### 2. Capture source integrity evidence

Run the non-identifying receipt query in the source immediately before export.
Keep the output in the restricted rehearsal record; do not keep individual
rows, IDs, names, scores, or result hashes.

All statements below share a repeatable-read snapshot. This does **not** bind
separate dump sessions to that snapshot; the qualified common-recovery-point
procedure remains mandatory. `row_security = off` makes a query fail when RLS
would apply rather than silently producing filtered counts; it does not grant
access or bypass RLS. Stop on permission/visibility errors, never grant broader
application privileges to make the receipt pass.

~~~sql
begin transaction isolation level repeatable read read only;
set local statement_timeout = '30s';
set local row_security = off;

select pg_catalog.jsonb_build_object(
  'profiles_total', (
    select pg_catalog.count(*) from public.profiles
  ),
  'profiles_anonymized', (
    select pg_catalog.count(*) from public.profiles
    where state = 'anonymized'
  ),
  'competitions_total', (
    select pg_catalog.count(*) from public.competitions
  ),
  'competitions_completed_or_archived', (
    select pg_catalog.count(*) from public.competitions
    where lifecycle in ('completed', 'archived')
  ),
  'participants_total', (
    select pg_catalog.count(*) from public.competition_participants
  ),
  'participants_anonymized', (
    select pg_catalog.count(*) from public.competition_participants
    where state = 'anonymized'
  ),
  'score_revisions_total', (
    select pg_catalog.count(*) from public.daily_score_revisions
  ),
  'attestations_total', (
    select pg_catalog.count(*)
    from public.participant_finalization_attestations
  ),
  'results_total', (
    select pg_catalog.count(*) from public.competition_results
  ),
  'awards_total', (
    select pg_catalog.count(*) from public.competition_awards
  ),
  'support_events_total', (
    select pg_catalog.count(*) from public.support_events
  )
) as healthcomp_counts;

select
  pg_catalog.count(*) as result_count,
  pg_catalog.encode(
    extensions.digest(
      coalesce(
        pg_catalog.string_agg(
          pg_catalog.encode(ordered_result.immutable_hash, 'hex'),
          '' order by ordered_result.immutable_hash
        ),
        ''
      ),
      'sha256'
    ),
    'hex'
  ) as aggregate_result_hash
from public.competition_results ordered_result;

rollback;
~~~

The aggregate hash is a comparison value, not proof that the application can
operate. It must match after restore, but never replaces RLS, migration,
Function, or staging E2E checks.

### 3. Create a bounded encrypted export workspace

Use an encrypted volume approved for restricted data. Create one exact
temporary directory and record its path. Do not use the repository directory,
Desktop, Downloads, cloud-synced folders, or a broad cleanup target.

~~~bash
set -euo pipefail
: "${HEALTHCOMP_ENCRYPTED_WORKSPACE:?set an approved encrypted volume path}"
[[ "$HEALTHCOMP_ENCRYPTED_WORKSPACE" = /* ]]
[[ -d "$HEALTHCOMP_ENCRYPTED_WORKSPACE" ]]
[[ ! -L "$HEALTHCOMP_ENCRYPTED_WORKSPACE" ]]
[[ -w "$HEALTHCOMP_ENCRYPTED_WORKSPACE" ]]
HEALTHCOMP_BACKUP_DIR="$(
  mktemp -d \
    "$HEALTHCOMP_ENCRYPTED_WORKSPACE/healthcomp-staging-backup.XXXXXX"
)"
export HEALTHCOMP_BACKUP_DIR
[[ -n "$HEALTHCOMP_BACKUP_DIR" ]]
[[ -d "$HEALTHCOMP_BACKUP_DIR" ]]
chmod 700 "$HEALTHCOMP_BACKUP_DIR"
~~~

Verify the named workspace's volume encryption before setting the variable;
the shell checks prove path shape and permissions, not encryption. APFS
copy-on-write and snapshots mean later file deletion is not a reliable secure
erase, so encryption from the outset and controlled key disposal are required.

### 4. Link the source explicitly and export

Only after the execution-readiness gate is satisfied, start from a clean
checkout of the reviewed commit. The following is still an unqualified draft,
not permission to link or use the CLI export path without verified transport:

~~~bash
set -euo pipefail
supabase unlink
supabase link --project-ref xhfdfdrtxwptrwhvvlhg
test "$(tr -d '\n' < supabase/.temp/project-ref)" = \
  xhfdfdrtxwptrwhvvlhg
find supabase/migrations \
  -maxdepth 1 \
  -type f \
  -name '[0-9]*_*.sql' |
  sed -E 's#^.*/([0-9]+)_.*#\1#' |
  LC_ALL=C sort >"$HEALTHCOMP_BACKUP_DIR/migrations-expected.txt"
supabase migration list --linked \
  >"$HEALTHCOMP_BACKUP_DIR/migrations-before.txt"
~~~

Require every displayed local version to have the identical remote version,
with no local-only, remote-only, duplicate, repaired, or SupabaseLegacy row.
Compare that reviewed table to `migrations-expected.txt`. From this readback
until after-export validation succeeds, maintain the complete source write
freeze from step 1. Any schema or relevant data change invalidates the entire
artifact set. Matching migration versions alone do not validate that freeze.

Let the CLI prompt securely for the database password. Do not place it in a
command, file under the repository, or captured transcript.

The draft below illustrates four serial artifacts; it does not establish the
final manifest. First read back the new destination's migration-history
definitions without exposing statements or private data. If definitions are
absent or incompatible, stop and review a separate history-schema artifact,
its import order and empty-target checks. Do not run an existence-dependent
query against a missing table, silently create substitute definitions, or
mark versions applied. Current Supabase guidance treats history schema and
data separately; actual managed-target compatibility must be demonstrated.

~~~bash
set -euo pipefail
cleanup_link() {
  supabase unlink >/dev/null 2>&1 || true
}
trap cleanup_link EXIT

supabase db dump --linked \
  --role-only \
  --file "$HEALTHCOMP_BACKUP_DIR/roles.sql"
supabase db dump --linked \
  --file "$HEALTHCOMP_BACKUP_DIR/schema.sql"
supabase db dump --linked \
  --data-only \
  --use-copy \
  --exclude storage.buckets_vectors \
  --exclude storage.vector_indexes \
  --file "$HEALTHCOMP_BACKUP_DIR/data.sql"
supabase db dump --linked \
  --data-only \
  --schema supabase_migrations \
  --file "$HEALTHCOMP_BACKUP_DIR/migration-history.sql"
supabase migration list --linked \
  >"$HEALTHCOMP_BACKUP_DIR/migrations-after.txt"
cmp -s \
  "$HEALTHCOMP_BACKUP_DIR/migrations-before.txt" \
  "$HEALTHCOMP_BACKUP_DIR/migrations-after.txt"
supabase unlink
trap - EXIT
~~~

Exact before/after migration equality is necessary but not sufficient. Capture
the same source receipt again under the still-enforced freeze and compare it,
then verify the freeze's independent breach evidence and artifact manifest.
Release only through the named operator's recorded decision. On any mismatch
or breach, quarantine the artifacts for approved disposal and begin a new
attempt after diagnosis; never restore a mixed recovery point.

Confirm every artifact in the approved manifest is non-empty, readable only
by the current user, and outside Git. The draft four-file check below must be
updated if a history-schema artifact is required; a fifth file must not be
silently omitted from verification, import, or cleanup. Hash without content:

~~~bash
set -euo pipefail
chmod 600 "$HEALTHCOMP_BACKUP_DIR"/*.sql
for required_dump in \
  roles.sql schema.sql data.sql migration-history.sql; do
  [[ -s "$HEALTHCOMP_BACKUP_DIR/$required_dump" ]]
done
shasum -a 256 "$HEALTHCOMP_BACKUP_DIR"/*.sql
~~~

The file hashes may be retained in the restricted receipt. The SQL files may
not.

### 5. Prepare the disposable destination

Read the destination project ref, name, organization, region, health, and
database version from the dashboard and CLI. Require a new empty Supabase
project. Stop if the destination resembles production, has users/traffic, or
is referenced by any app configuration.

Use the destination's direct database host and operator username. Never put
its password or full connection URI in a command. Force psql to prompt with
--password. Verify the step-1 quarantine and every session's certificate/host
policy first. Before schema restore, apply Supabase's required default-privilege
boundary; this is not the quarantine mechanism:

~~~bash
set -euo pipefail
psql -X \
  --host REPLACE_WITH_RESTORE_HOST \
  --port 5432 \
  --username REPLACE_WITH_RESTORE_USER \
  --dbname postgres \
  --password \
  --set ON_ERROR_STOP=on \
  --command \
  "ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated;"
psql -X \
  --host REPLACE_WITH_RESTORE_HOST \
  --port 5432 \
  --username REPLACE_WITH_RESTORE_USER \
  --dbname postgres \
  --password \
  --set ON_ERROR_STOP=on \
  --command "
    do \$healthcomp_empty_history\$
    begin
      if exists (
        select 1 from supabase_migrations.schema_migrations
      ) then
        raise exception 'destination_migration_history_not_empty';
      end if;
    end
    \$healthcomp_empty_history\$;
  "
~~~

If direct connectivity is unavailable, obtain the exact supported session-
pooler host and username from the destination's Connect panel. Do not guess
them and do not weaken network restrictions.

### 6. Restore serially

After the readiness gate, exact manifest, verified transport and pre-import
quarantine are proven, review SQL headers and sizes without exposing rows.
Follow the qualified import order, including any reviewed history-schema
artifact. The four-artifact example below applies only to a destination whose
managed history definitions have already passed compatibility/empty checks.
Stop on the first error and maintain quarantine throughout the operation.

Both CLI-generated data files must set `session_replication_role` to `replica`
before their data statements and reset the same session afterward. Require one
of each control in the correct order without printing dump content:

~~~bash
set -euo pipefail
for controlled_dump in data.sql migration-history.sql; do
  dump_path="$HEALTHCOMP_BACKUP_DIR/$controlled_dump"
  [[ "$(grep -c '^SET session_replication_role = replica;$' "$dump_path")" \
    -eq 1 ]]
  [[ "$(grep -c '^RESET ALL;$' "$dump_path")" -eq 1 ]]
  replica_line="$(
    grep -n '^SET session_replication_role = replica;$' "$dump_path" |
      cut -d: -f1
  )"
  reset_line="$(grep -n '^RESET ALL;$' "$dump_path" | cut -d: -f1)"
  [[ "$replica_line" -lt "$reset_line" ]]
done
~~~

Session settings do not cross connections. The wrapper below verifies an
`origin` session, establishes `replica` before each import, lets each generated
file reset that same session, and immediately checks `origin` after each
file. Do not insert a wrapper reset before those assertions: it would mask a
dump that failed to restore its session settings.

~~~bash
set -euo pipefail
psql -X \
  --host REPLACE_WITH_RESTORE_HOST \
  --port 5432 \
  --username REPLACE_WITH_RESTORE_USER \
  --dbname postgres \
  --password \
  --set ON_ERROR_STOP=on \
  --file "$HEALTHCOMP_BACKUP_DIR/roles.sql"
psql -X \
  --host REPLACE_WITH_RESTORE_HOST \
  --port 5432 \
  --username REPLACE_WITH_RESTORE_USER \
  --dbname postgres \
  --password \
  --set ON_ERROR_STOP=on \
  --file "$HEALTHCOMP_BACKUP_DIR/schema.sql"
(
  cd "$HEALTHCOMP_BACKUP_DIR"
  psql -X \
    --host REPLACE_WITH_RESTORE_HOST \
    --port 5432 \
    --username REPLACE_WITH_RESTORE_USER \
    --dbname postgres \
    --password \
    --set ON_ERROR_STOP=on <<'PSQL'
do $healthcomp_origin_before$
begin
  if current_setting('session_replication_role') <> 'origin' then
    raise exception 'restore_session_not_origin_before_data';
  end if;
end
$healthcomp_origin_before$;

set session_replication_role = replica;
\i data.sql

do $healthcomp_origin_after_data$
begin
  if current_setting('session_replication_role') <> 'origin' then
    raise exception 'data_dump_did_not_restore_origin';
  end if;
end
$healthcomp_origin_after_data$;

set session_replication_role = replica;
\i migration-history.sql

do $healthcomp_origin_after_history$
begin
  if current_setting('session_replication_role') <> 'origin' then
    raise exception 'migration_history_did_not_restore_origin';
  end if;
end
$healthcomp_origin_after_history$;
PSQL
)
psql -X \
  --host REPLACE_WITH_RESTORE_HOST \
  --port 5432 \
  --username REPLACE_WITH_RESTORE_USER \
  --dbname postgres \
  --password \
  --set ON_ERROR_STOP=on \
  --tuples-only \
  --command 'show session_replication_role;'
~~~

Both same-session assertions and the fresh-session readback must be `origin`.
Any other value is a failed rehearsal.

Do not ignore an error, add migration repair, or rerun a partially applied
file against the same destination. Preserve the non-sensitive error category,
discard the failed target with approval, correct the runbook or forward
migration, and restart from a fresh destination.

### 7. Verify the restore

Run the same count and aggregate-result-hash queries against the destination.
Require exact equality. Also verify:

1. all checked-in lowercase migration versions appear once and in order;
2. no SupabaseLegacy version appears;
3. RLS and force-RLS remain enabled on protected public/private tables;
4. grants do not give anon or authenticated direct access to private tables;
5. completed result hashes and append-only server sequences are internally
   valid;
6. anonymized profiles remain terminal, unnamed, and unlinked from Auth;
7. no unfinished deletion is treated as recoverable from a missing Vault
   token;
8. provider, Function, secret, Vault, schedule, and app configuration remain
   deliberately disabled on the rehearsal target.

These requirements need validated aggregate-only checks before execution, not
an operator's inference from matching table totals. In particular:

- check the support runbook's gap-free predicate across **every competition**,
  including empty logs, and compare checked/invalid counts with zero invalid;
- verify stored result content under each established version-specific hash
  contract, not only equality of the stored hashes. The existing
  `competition_result_immutable_hash_check` exempts version-1 frozen windows;
  its presence is not full coverage. Stop for any format without a validated
  verification rule; never expose individual hashes or weaken the contract;
- require independently completed deletion evidence and at least one genuine
  anonymized participant with preserved shared history. Zero-anonymized or
  fabricated deletion fixtures cannot close the hosted preservation gate;
- verify terminal unnamed/Auth-unlinked profiles, preserved immutable shared
  history, appropriate installation/session retirement, and unresolved-Vault
  quarantine using the account-deletion contract. Aggregate counts alone do
  not identify or reconcile deletions after a recovery point.

The examples in this document do not yet implement every acceptance check.
Until complete validated coverage is attached, a matching count/hash receipt
is partial evidence and the rehearsal cannot be credited as passing.

#### Aggregate history component

`scripts/recovery-history-integrity.sql` wraps the SELECT-only
`scripts/recovery-history-integrity-query.sql` in a repeatable-read, read-only
transaction with complete-visibility failure, UTC, a 30-second statement
timeout, stop-on-error, SQLSTATE-only errors, and rollback. Invoke the wrapper
as a top-level file using a fresh noninteractive `psql -X` session with quiet,
tuples-only, unaligned output. Transport, credentials and the common recovery
point still require the execution prerequisites above; this wrapper is not
an export runner and cannot bind separate connections to the same snapshot.
Its mode assertion cannot prove freshness or detect every existing transaction.
Do not capture verbose query/error output, use an existing transaction, or
treat a failed command's partial output as a receipt.

Its version-1 receipt has exactly twelve aggregate fields: receipt version;
checked/invalid competition counts; total/orphan change-row counts; total,
format-2 checked/invalid, legacy-unverified and unsupported result counts;
and two aggregate hash comparisons. It emits no individual identifiers,
scores, timestamps, row contents or per-result hashes. Require zero invalid
sequences, orphan changes, invalid format-2 results, legacy-unverified results
and unsupported results before crediting this component. Compare all fields
between the source and restore; require the separately established nonempty
and genuine-deletion history as well. Zero counts are not evidence of that
history. The receipt deliberately has no overall pass/readiness field.

The sequence predicate includes every competition, empty logs, null rows and
duplicate/gapped sequences, but cannot prove that earlier contents were never
rewritten. Format-2 checks use frozen commitments and the established
`healthcomp-result-v1` derivation, with necessary stored-window/outcome rules;
they do not prove prior accepted attestations or re-finalize results. Format
1 remains explicitly unverified because the repository does not establish a
stored-content hash derivation for it. Unknown formats also stop qualification.
No migration is changed or historical result converted to pass these checks.

The stored-hash aggregate alone omits changes to completion time and top-level
server sequence. The separate complete-result fingerprint includes every
stored result column, normalizing timestamps and binary hashes independently
of session rendering and sorting deterministically. Both include legacy and
anonymized retained results without filtering on current membership/profile
state. Matching fingerprints still require separate schema/FK, deletion,
grant/RLS, configuration, quarantine and recovery-point verification.

Backend CI exercises the actual query with synthetic PostgreSQL-17 fixtures,
the real immutable canonical helper definitions, and malformed-history
controls. Separate substituted-query probes test the wrapper's transaction
and error boundaries; the actual wrapper/query also runs against the fully
migrated CI schema. These local/CI checks are component qualification, not a
hosted backup, genuine deletion, restore, forward-repair or production pass.
**NOT QUALIFIED FOR EXECUTION remains in force for the operational runbook.**

Bind restored application history to the reviewed checkout mechanically. The
query emits version values only, never migration statements:

~~~bash
set -euo pipefail
psql -X \
  --host REPLACE_WITH_RESTORE_HOST \
  --port 5432 \
  --username REPLACE_WITH_RESTORE_USER \
  --dbname postgres \
  --password \
  --set ON_ERROR_STOP=on \
  --tuples-only \
  --no-align \
  --command \
  'select version::text from supabase_migrations.schema_migrations order by version' \
  >"$HEALTHCOMP_BACKUP_DIR/migrations-restored.txt"
cmp -s \
  "$HEALTHCOMP_BACKUP_DIR/migrations-expected.txt" \
  "$HEALTHCOMP_BACKUP_DIR/migrations-restored.txt"
~~~

Any mismatch is a failed rehearsal. Do not mark a missing control migration as
applied and do not use migration repair.

#### Foreign-key component

Because the generated data import intentionally disables referential triggers,
run `scripts/recovery-foreign-key-integrity.sql` after import as a fresh,
noninteractive, top-level `psql -XqAt --file` invocation. The execution-readiness,
verified-transport and private-credential requirements still apply. Do not use
an existing transaction or an outer include; the mode assertion does not prove
connection freshness.

The file asserts effective repeatable-read/read-only transaction modes and
`session_replication_role=origin`, sets `row_security=off` and a 30-second
statement timeout, stops on errors without automatic error rollback, emits
SQLSTATE-only errors without context, and rolls back. It neither grants access
nor bypasses RLS. Success requires exit zero and empty output; it is only an
FK component outcome, not a populated-history receipt or a recovery pass.

The audit checks catalog-declared FKs whose referencing relation is in `public`
or `private`; the referenced relation may be in another schema, including
`auth`. Its qualified comparison scope is native same-type UUID/UUID and
int8/int8 (`bigint`) noncollatable keys, including composites, with MATCH SIMPLE
and the corresponding `pg_catalog` equality operator recorded in `conpfeqop`.
A tuple with any null referencing component is exempt; otherwise the full
referenced tuple must exist. A NOT VALID flag does not replace checking rows.

Ordinary inheritance uses `ONLY` for both source and target scans: a child-only
target row cannot satisfy the parent's FK, and a source child does not inherit
its parent's FK. Partition parents/leaves, cloned FKs, other match modes, and
unsupported type/operator/collation shapes stop for explicit review instead
of being skipped. This is not a generic PostgreSQL verifier. SQLSTATE `0A000`
means unsupported shape, `23503` an orphan, `P0001` an effective mode/origin
failure, and `42501` a permission/visibility failure. Any error fails the component;
retain only the non-identifying category, never relation/constraint names,
keys, counts of private rows, or detailed query/error output.

This component does not detect missing constraints, prove expected schema or
grants/RLS configuration, validate result/history or deletion invariants, or
establish a common recovery point. Empty output cannot close those separate
checks. The static drift check requires the entire example below to remain
byte-identical to the packaged file. Backend CI separately exercises synthetic
FK/error-boundary cases and the fully migrated empty schema; neither is hosted
restore evidence. **NOT QUALIFIED FOR EXECUTION remains in force.**

~~~sql
\set ON_ERROR_STOP on
\set ON_ERROR_ROLLBACK off
\set VERBOSITY sqlstate
\set SHOW_CONTEXT never
begin transaction isolation level repeatable read read only;
set local statement_timeout = '30s';
set local row_security = off;

do $healthcomp_fk_mode_guard$
begin
  if (current_setting('transaction_isolation') = 'repeatable read'
    and current_setting('transaction_read_only') = 'on'
    and current_setting('session_replication_role') = 'origin') is not true
  then raise exception using errcode = 'P0001', message = 'foreign_key_audit_mode'; end if;
end
$healthcomp_fk_mode_guard$;

-- Current HealthComp FK types only, not a generic PostgreSQL verifier.
-- Schema presence/grants and connection freshness are separate prerequisites.
do $healthcomp_fk_audit$
declare
  foreign_key record;
  key_count bigint;
  supported_pairs boolean;
  join_predicate text;
  non_null_predicate text;
  orphan_count bigint;
begin
  for foreign_key in
    select constraint_record.conrelid, constraint_record.confrelid,
      constraint_record.conkey, constraint_record.confkey,
      constraint_record.conpfeqop, constraint_record.confmatchtype,
      constraint_record.conparentid,
      source_namespace.nspname as source_schema,
      source_relation.relname as source_table,
      source_relation.relkind as source_kind,
      source_relation.relispartition as source_partition,
      target_namespace.nspname as target_schema,
      target_relation.relname as target_table,
      target_relation.relkind as target_kind,
      target_relation.relispartition as target_partition
    from pg_catalog.pg_constraint constraint_record
    join pg_catalog.pg_class source_relation
      on source_relation.oid = constraint_record.conrelid
    join pg_catalog.pg_namespace source_namespace
      on source_namespace.oid = source_relation.relnamespace
    join pg_catalog.pg_class target_relation
      on target_relation.oid = constraint_record.confrelid
    join pg_catalog.pg_namespace target_namespace
      on target_namespace.oid = target_relation.relnamespace
    where constraint_record.contype = 'f'
      and source_namespace.nspname in ('public', 'private')
    order by constraint_record.oid
  loop
    -- Partition parents/leaves and FK action clones need different semantics.
    -- A missing/unsupported shape is a stop, never silently skipped.
    if (foreign_key.confmatchtype = 's'
      and foreign_key.conparentid = 0
      and foreign_key.source_kind = 'r' and not foreign_key.source_partition
      and foreign_key.target_kind = 'r' and not foreign_key.target_partition
      and pg_catalog.array_ndims(foreign_key.conkey) = 1
      and pg_catalog.array_ndims(foreign_key.confkey) = 1
      and pg_catalog.array_ndims(foreign_key.conpfeqop) = 1
      and pg_catalog.cardinality(foreign_key.conkey) > 0
      and pg_catalog.cardinality(foreign_key.conkey) = pg_catalog.cardinality(foreign_key.confkey)
      and pg_catalog.cardinality(foreign_key.conkey) = pg_catalog.cardinality(foreign_key.conpfeqop)
    ) is not true then
      raise exception using errcode = '0A000', message = 'foreign_key_unsupported_shape';
    end if;

    select pg_catalog.count(*),
      pg_catalog.bool_and((
        source_attribute.attnum > 0 and not source_attribute.attisdropped
        and target_attribute.attnum > 0 and not target_attribute.attisdropped
        and source_attribute.atttypid in ('pg_catalog.uuid'::pg_catalog.regtype,
          'pg_catalog.int8'::pg_catalog.regtype)
        and target_attribute.atttypid = source_attribute.atttypid
        and source_attribute.attcollation = 0 and target_attribute.attcollation = 0
        and equality_key.operator_oid = case source_attribute.atttypid
          when 'pg_catalog.uuid'::pg_catalog.regtype
            then 'pg_catalog.=(pg_catalog.uuid,pg_catalog.uuid)'::pg_catalog.regoperator
          when 'pg_catalog.int8'::pg_catalog.regtype
            then 'pg_catalog.=(pg_catalog.int8,pg_catalog.int8)'::pg_catalog.regoperator
        end
      ) is true),
      pg_catalog.string_agg(pg_catalog.format(
        'target.%I OPERATOR(pg_catalog.=) source.%I',
        target_attribute.attname, source_attribute.attname
      ), ' and ' order by source_key.ordinal_position),
      pg_catalog.string_agg(pg_catalog.format(
        'source.%I is not null', source_attribute.attname
      ), ' and ' order by source_key.ordinal_position)
    into key_count, supported_pairs, join_predicate, non_null_predicate
    from pg_catalog.unnest(foreign_key.conkey)
      with ordinality as source_key(source_attnum, ordinal_position)
    left join pg_catalog.unnest(foreign_key.confkey)
      with ordinality as target_key(target_attnum, ordinal_position)
      using (ordinal_position)
    left join pg_catalog.unnest(foreign_key.conpfeqop)
      with ordinality as equality_key(operator_oid, ordinal_position)
      using (ordinal_position)
    left join pg_catalog.pg_attribute source_attribute
      on source_attribute.attrelid = foreign_key.conrelid
      and source_attribute.attnum = source_key.source_attnum
    left join pg_catalog.pg_attribute target_attribute
      on target_attribute.attrelid = foreign_key.confrelid
      and target_attribute.attnum = target_key.target_attnum;

    if (key_count = pg_catalog.cardinality(foreign_key.conkey)
      and supported_pairs and join_predicate is not null
      and non_null_predicate is not null) is not true then
      raise exception using errcode = '0A000', message = 'foreign_key_unsupported_comparison';
    end if;

    -- MATCH SIMPLE exempts a tuple if ANY FK component is null. Ordinary
    -- inheritance does not inherit FKs or let a child satisfy its parent's key.
    execute pg_catalog.format(
      'select count(*) from ONLY %I.%I source '
      || 'where (%s) and not exists ('
      || 'select 1 from ONLY %I.%I target where %s)',
      foreign_key.source_schema, foreign_key.source_table, non_null_predicate,
      foreign_key.target_schema, foreign_key.target_table, join_predicate
    ) into orphan_count;
    if orphan_count <> 0 then
      raise exception using errcode = '23503', message = 'foreign_key_orphan';
    end if;
  end loop;
end
$healthcomp_fk_audit$;

rollback;
~~~

Run database lint and the read-only parts of the support runbooks. Do not run
the shipping app, send notifications, sign users in, or invoke account
deletion against restored identities.

The rehearsal passes only when restore commands exit cleanly, counts and the
aggregate result hash match, security invariants pass, and every non-database
environment surface is recorded as intentionally absent or separately
verified.

### 8. Rehearse a reviewed forward repair

Task 18 also requires rollback or forward repair. Before executing the restore,
approve one bounded rehearsal of the immutable forward-migration process on
the disposable target: record the selected reviewed change, expected pre/post
behavior, stop/cleanup path, and acceptance queries. Do not invent a live
migration, alter completed history, or rewrite migration versions here. If no
reviewed repair and acceptance scenario exists, this gate is still open.

After that rehearsal, recheck the complete integrity/privacy receipt and the
target's quarantine. Record actual execution and outcomes separately from the
initial restore. A clean restore alone does not satisfy forward-repair proof.

### 9. Record evidence and clean up

The anonymized receipt contains only:

- source commit and source/destination environment labels;
- independently established recovery-point/cutoff and freeze start/end;
- rehearsal start (before target provisioning/export), export/import bounds,
  and end (after all integrity/privacy and forward-repair acceptance checks);
- recovery-point age at the recorded restore/import start and elapsed time to a **validated
  quarantined database**, including provisioning/export/import/verification;
- PostgreSQL and CLI versions;
- migration version list;
- aggregate table counts;
- result count and aggregate result hash;
- command exit statuses and elapsed time;
- forward-repair scenario reference and its actual acceptance outcome;
- RLS/grant/invariant outcomes;
- exact missing environment surfaces and blockers;
- approver for destination deletion and local artifact disposal.

It must not contain project credentials, connection URIs, IDs from data rows,
names, emails, individual result hashes, scores, tokens, SQL dump excerpts, or
Apple identifiers.

If a recovery point cannot be established or a phase did not run, record the
measurement as unavailable, not zero. These observed durations are not an
approved production RPO/RTO and do not measure restoration of the disabled
Auth/Functions/APNs/app environment. Production data-loss/downtime objectives
and ongoing backup/retention policy require a separate explicit decision.

After evidence acceptance and explicit approval, delete the disposable hosted
project through the dashboard. For local artifacts, first verify the exact
temporary path begins with the recorded healthcomp-staging-backup prefix and
matches the exact approved artifact manifest, including any reviewed
history-schema file and `migrations-{expected,before,after,restored}.txt`.
Unexpected files or an unapproved target are a stop, not a broader deletion
authorization. Dispose of the encrypted
volume or
its encryption key according to policy, then remove that exact directory. Do
not recursively delete a workspace root, home directory, TMPDIR, or unresolved
variable.

## Emergency hosted recovery

Emergency production recovery remains blocked until a production project,
backup policy, retention, RPO/RTO, and incident authority are approved. When
they exist, the minimum decision record must include:

- exact affected project ref and current health;
- incident start and write-freeze time;
- latest known-good recovery timestamp and why it is safe;
- data-loss interval implied by that timestamp;
- independent evidence that the timestamp is later than every completed
  account deletion, or an explicit decision to keep the project offline;
- whether automated snapshot or PITR is available;
- independent target-ref review and fresh destructive approval;
- rollback/forward-repair plan if restore validation fails;
- post-restore environment and physical-device verification owner.

During a real restore, prevent app writes and scheduled workers before the
operation. After the database becomes available, compare the pre/post
non-identifying receipt, read back every external surface, run backend/RLS
gates, then perform two-account staging-equivalent verification before
reopening access. Never call a successful dashboard restore production-ready
without these checks.

The repository currently has no external per-deletion suppression ledger.
Database-resident Auth rows, deletion phases, support events, profiles, and
sessions rewind together during PITR. Aggregate anonymization counts cannot
identify which post-recovery-point deletions must be reapplied. Therefore a
production recovery point that may precede any completed deletion is a hard
stop: keep app traffic, Auth, Functions, and schedules disabled. Reopening
requires either a later recovery point proven by an independent completion
receipt or a separately reviewed privacy design for a minimal external ledger
and deterministic re-deletion. Do not invent that ledger during an incident.

## Special account-deletion recovery rule

The logical dump excludes Vault. A token_ready deletion in a logical restore
may have no Apple refresh token and cannot be safely completed or rolled back
by an operator. Quarantine the restore target and escalate to privacy/security
engineering. Never create a replacement token, change its phase, relink the
profile, or call the deletion completed.

A completed deletion must remain completed after any recovery. Former
competitor history remains visible to the other participant, while the deleted
person's Auth and Apple linkage remains absent. If independent evidence cannot
prove that property for every deletion affected by the rollback interval, the
recovered project must not reopen.

## Primary references

- [Supabase database backups](https://supabase.com/docs/guides/platform/backups)
- [Supabase CLI db dump](https://supabase.com/docs/reference/cli/supabase-db-dump)
- [Supabase migration and restore guide](https://supabase.com/docs/guides/platform/migrating-to-supabase)
- [Supabase point-in-time recovery](https://supabase.com/docs/guides/platform/backups#point-in-time-recovery)
- [Supabase logical restore and migration history](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore)
- [CLI 2.113.0 dump handler](https://github.com/supabase/cli/blob/03880bb15379c308a73b078d98780eef1eb1bd63/apps/cli/src/legacy/commands/db/dump/dump.handler.ts)
- [CLI 2.113.0 dump environment](https://github.com/supabase/cli/blob/03880bb15379c308a73b078d98780eef1eb1bd63/apps/cli/src/legacy/commands/db/shared/legacy-pg-dump.env.ts)
- [CLI 2.113.0 container options](https://github.com/supabase/cli/blob/03880bb15379c308a73b078d98780eef1eb1bd63/apps/cli/src/legacy/commands/db/shared/legacy-pg-dump.run.ts)
- [PostgreSQL transaction isolation](https://www.postgresql.org/docs/17/sql-set-transaction.html)
- [PostgreSQL certificate and hostname verification](https://www.postgresql.org/docs/17/libpq-ssl.html)
- [PostgreSQL conditional expressions](https://www.postgresql.org/docs/17/functions-conditional.html)
- [PostgreSQL row-visibility guard](https://www.postgresql.org/docs/17/runtime-config-client.html#GUC-ROW-SECURITY)
