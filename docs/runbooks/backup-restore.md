# Backup and Restore

This runbook separates Supabase platform database recovery from a CLI logical
export. Neither path is credited until a staging restore has actually been
rehearsed and its non-identifying integrity receipt has been compared.

## Current evidence status

As of the read-only inventory ending at `2026-08-23T06:06:35Z`:

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
  storage, realtime, cron, Vault, and migration history because a destination
  Supabase project supplies their definitions.
- A data-only dump intentionally includes application data and may include
  auth and storage table data while excluding internal migration tables and
  several platform schemas. It is highly sensitive even when HealthComp uses
  only Apple sign-in.
- Vault data is excluded. In-flight account-deletion refresh tokens and the
  notification worker URL/token are not a complete logical-backup surface.
- The ordinary data dump excludes `supabase_migrations`. Export its data as a
  fourth, explicit migration-history artifact so a fresh destination records
  exactly the application migrations whose schema is being restored. Do not
  synthesize that history with migration repair.
- Function code, Function secrets, provider settings, and project settings are
  not recreated by the four SQL files.
- Storage database rows are not the same as object bytes. HealthComp does not
  currently rely on Storage for competition data, but future use requires a
  separate object backup procedure.

Logical dump files can contain emails, provider identifiers, session/auth
metadata, profile UUIDs, display names, score revisions, results, device
tokens, and support events. Never commit, attach, paste, index, or upload them
to an unapproved service.

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
- chosen logical snapshot timestamp;
- operator and approver;
- named owner of the source migration/DDL freeze for the complete export
  window;
- encrypted local workspace and cleanup owner.

Disable Apple provider sign-in, schedules, external Function calls, and app
distribution on the destination. Do not install production or staging secret
values. The new project's credentials must remain isolated from app builds.

### 2. Capture source integrity evidence

Run the non-identifying receipt query in the source immediately before export.
Keep the output in the restricted rehearsal record; do not keep individual
rows, IDs, names, scores, or result hashes.

~~~sql
begin transaction read only;
set local statement_timeout = '30s';

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
      pg_catalog.coalesce(
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

Start from a clean checkout of the reviewed commit:

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
until the after-export readback succeeds, freeze Supabase migration deploys,
dashboard DDL, and operator schema changes. A named owner must enforce the
freeze; any schema change invalidates all four dumps.

Let the CLI prompt securely for the database password. Do not place it in a
command, file under the repository, or captured transcript.

Generate the four artifacts serially. The dedicated migration-history dump is
data-only because the fresh Supabase destination already owns the managed
`supabase_migrations` schema:

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

The exact before/after equality is the release of the source migration freeze.
If it fails, discard every dump from that attempt and start again after the
source history is understood; do not restore a mixed snapshot.

Confirm all four files are non-empty, readable only by the current user, and
not inside Git. Hash them without displaying content:

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
--password. Before schema restore, apply Supabase's required default-privilege
boundary:

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

Review generated SQL headers and sizes without exposing row content. Then run
roles, schema, application data, and migration-history data in that order,
stopping on the first error.

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
file reset that same session, and fails unless `origin` is restored after each
file.

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
reset session_replication_role;

do $healthcomp_origin_after_data$
begin
  if current_setting('session_replication_role') <> 'origin' then
    raise exception 'data_dump_did_not_restore_origin';
  end if;
end
$healthcomp_origin_after_data$;

set session_replication_role = replica;
\i migration-history.sql
reset session_replication_role;

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

Because the generated data import intentionally disables referential triggers,
run this read-only audit in a fresh origin session. It checks every simple
foreign key whose referencing table is in public or private and fails on the
first orphan without returning row contents:

~~~sql
begin transaction read only;
set local statement_timeout = '30s';

do $healthcomp_fk_audit$
declare
  foreign_key record;
  join_predicate text;
  non_null_predicate text;
  orphan_count bigint;
begin
  if exists (
    select 1
    from pg_catalog.pg_constraint constraint_record
    join pg_catalog.pg_class source_relation
      on source_relation.oid = constraint_record.conrelid
    join pg_catalog.pg_namespace source_namespace
      on source_namespace.oid = source_relation.relnamespace
    where constraint_record.contype = 'f'
      and source_namespace.nspname in ('public', 'private')
      and constraint_record.confmatchtype <> 's'
  ) then
    raise exception 'non_simple_foreign_key_requires_explicit_audit';
  end if;

  for foreign_key in
    select
      constraint_record.conname,
      constraint_record.conrelid,
      constraint_record.confrelid,
      constraint_record.conkey,
      constraint_record.confkey
    from pg_catalog.pg_constraint constraint_record
    join pg_catalog.pg_class source_relation
      on source_relation.oid = constraint_record.conrelid
    join pg_catalog.pg_namespace source_namespace
      on source_namespace.oid = source_relation.relnamespace
    where constraint_record.contype = 'f'
      and source_namespace.nspname in ('public', 'private')
    order by constraint_record.conname
  loop
    select
      pg_catalog.string_agg(
        pg_catalog.format(
          'source.%I = target.%I',
          source_attribute.attname,
          target_attribute.attname
        ),
        ' and ' order by source_key.ordinal_position
      ),
      pg_catalog.string_agg(
        pg_catalog.format(
          'source.%I is not null',
          source_attribute.attname
        ),
        ' and ' order by source_key.ordinal_position
      )
    into join_predicate, non_null_predicate
    from pg_catalog.unnest(foreign_key.conkey)
      with ordinality as source_key(source_attnum, ordinal_position)
    join pg_catalog.unnest(foreign_key.confkey)
      with ordinality as target_key(target_attnum, ordinal_position)
      using (ordinal_position)
    join pg_catalog.pg_attribute source_attribute
      on source_attribute.attrelid = foreign_key.conrelid
     and source_attribute.attnum = source_key.source_attnum
    join pg_catalog.pg_attribute target_attribute
      on target_attribute.attrelid = foreign_key.confrelid
     and target_attribute.attnum = target_key.target_attnum;

    execute pg_catalog.format(
      'select count(*) from %s source '
      || 'where (%s) and not exists ('
      || 'select 1 from %s target where %s)',
      foreign_key.conrelid::pg_catalog.regclass,
      non_null_predicate,
      foreign_key.confrelid::pg_catalog.regclass,
      join_predicate
    ) into orphan_count;

    if orphan_count <> 0 then
      raise exception 'foreign_key_orphan: %', foreign_key.conname;
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

### 8. Record evidence and clean up

The anonymized receipt contains only:

- source commit and source/destination environment labels;
- snapshot and rehearsal timestamps;
- PostgreSQL and CLI versions;
- migration version list;
- aggregate table counts;
- result count and aggregate result hash;
- command exit statuses and elapsed time;
- RLS/grant/invariant outcomes;
- exact missing environment surfaces and blockers;
- approver for destination deletion and local artifact disposal.

It must not contain project credentials, connection URIs, IDs from data rows,
names, emails, individual result hashes, scores, tokens, SQL dump excerpts, or
Apple identifiers.

After evidence acceptance and explicit approval, delete the disposable hosted
project through the dashboard. For local artifacts, first verify the exact
temporary path begins with the recorded healthcomp-staging-backup prefix and
contains only the four expected SQL files plus
`migrations-{expected,before,after,restored}.txt`. Dispose of the encrypted
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
