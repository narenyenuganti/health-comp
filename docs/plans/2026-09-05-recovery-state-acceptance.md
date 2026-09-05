# Recovery State Acceptance Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Qualify the missing Task 18 aggregate restored-authorization and deletion-state checks against the existing immutable application contract.

**Architecture:** A SELECT-only aggregate query runs inside the established fresh, read-only psql wrapper pattern. Real PostgreSQL fixtures test its catalog/row predicates and error boundaries; the same files run separately against the fully migrated CI schema. The receipt reports evidence, not overall readiness.

**Tech Stack:** PostgreSQL 17, psql, Bash, the existing bounded OrbStack fixture and Backend CI conventions.

---

## Design and execution boundary

Use `.worktrees/test-recovery-state-acceptance`, branch `test/recovery-state-acceptance`, based on merged main `ad46b51aa039874578c8d30226e52514f3c6e251`. Its tree equals fully tested PR90 head `eb5134c`; resulting-main CI is still running at plan creation. Preserve original main's unrelated package-lock change and all historical worktrees.

The prior source inventory placed the next component after full integration. This bounded scheduling refinement allows isolated design/test preparation during the current main-CI wait. Database/container execution, commit/push/new CI, and integration remain serialized behind the preceding main gates. Do not credit a preparation/static pass as SQL execution.

Choose the existing history component's packaged SELECT/query-plus-wrapper approach. Extending the one-profile support query would retain incomplete coverage and its individual timestamp. Installing a new target-side function would add mutation/privilege requirements to a read-only operation. Neither alternative is selected. Keep application behavior, immutable migrations, authentication, and operational authorization unchanged.

Read `docs/runbooks/backup-restore.md` sections 7 and Aggregate history component, `docs/runbooks/account-deletion.md` support/terminal boundaries, and migrations 00100, 00200, 00450, 00650, 00700, 00750, and 00800 before implementing their predicates. The dated continuation source inventory is navigation aid only; these checked-in sources define the contract.

## Receipt contract

Create `scripts/recovery-state-acceptance-query.sql` and `scripts/recovery-state-acceptance.sql`. The query returns exactly one version-1 JSON object, with these 31 nonnegative integer fields and no other output:

```text
receipt_version
application_tables_checked
application_tables_missing_or_unsupported
application_tables_unexpected
rls_flag_mismatches
table_privilege_mismatches
column_privilege_mismatches
policy_mismatches
profiles_checked
profiles_invalid_shape
profiles_anonymized
deletion_records_checked
deletion_records_invalid_shape
deletion_phase_profile_mismatches
deletions_prepared
deletions_token_ready
deletions_apple_revoked
deletions_auth_delete_pending
deletions_completed
anonymized_profiles_without_completed_deletion
deactivated_profiles_with_active_installations
deactivated_profiles_with_live_notification_work
deactivated_profiles_with_mute_links
deactivated_profiles_with_app_attest_rows
revoked_installations_with_app_attest_rows
anonymized_profiles_with_nonanonymized_participants
deactivated_profiles_with_unfinished_competitions
deactivated_profiles_with_unconsumed_cancelled_invites
completed_deletions_with_bad_completion_event_count
completion_events_without_completed_deletion
anonymized_profiles_in_results
```

`receipt_version` is 1. `application_tables_checked` must be17 for the expected supported application tables. These19 fields must be zero before crediting their predicates:

```text
application_tables_missing_or_unsupported
application_tables_unexpected
rls_flag_mismatches
table_privilege_mismatches
column_privilege_mismatches
policy_mismatches
profiles_invalid_shape
deletion_records_invalid_shape
deletion_phase_profile_mismatches
deactivated_profiles_with_active_installations
deactivated_profiles_with_live_notification_work
deactivated_profiles_with_mute_links
deactivated_profiles_with_app_attest_rows
revoked_installations_with_app_attest_rows
anonymized_profiles_with_nonanonymized_participants
deactivated_profiles_with_unfinished_competitions
deactivated_profiles_with_unconsumed_cancelled_invites
completed_deletions_with_bad_completion_event_count
completion_events_without_completed_deletion
```

The other ten fields are diagnostic counts. A nonzero violation count is failure evidence, not successful acceptance merely because psql exited zero. Callers must inspect the exact keys/types and each criterion; SQL failures yield no usable receipt.

Phase, anonymous-profile, and retained-result counts are diagnostic. Nonzero unfinished phases require the existing phase-specific quarantine/reconciliation procedure, not automatic resumption or reclassification as corruption. `anonymized_profiles_without_completed_deletion` identifies anonymity that cannot be credited as completed deletion from this state. `anonymized_profiles_in_results` counts anonymous profiles referenced by retained results without outputting identities or scores; it cannot establish genuine deletion or history preservation by itself. No pass, recoverable, production-ready, or external-evidence Boolean belongs in this receipt.

Counting units are explicit: RLS mismatch is per expected table; privilege mismatch is per role/table/privilege or role/table/column/privilege, combining held-privilege and grant-option mismatch once; policy mismatch is per expected missing/different policy plus each unexpected policy. Shape/phase checks count affected rows. Retirement fields count each affected profile or revoked installation once, even if several linked rows violate the predicate. Completion-event-without-completed-deletion counts events. A valid auth-delete-pending profile increases the diagnostic anonymous-without-completed count, not a corruption counter.

### Authorization predicates

The exact current baseline is 11 public tables with RLS enabled/no FORCE, private notification mutes with neither flag but revoked raw access, and five other private tables with RLS and FORCE. Preserve this per-table baseline and clarify the runbook's blanket wording; do not modify migrations to fit an invented all-table FORCE requirement.

Inspect table and column privileges for `anon`, `authenticated`, `service_role`, plus the PUBLIC pseudo-role. Authenticated has whole-table SELECT on competitions, participants, revisions, finalization attestations, results and awards, and column-only SELECT on profile id/display_name. It has no current installation SELECT grant. All other table/column access and grant options in this application scope are denied. Include PostgreSQL-17 MAINTAIN and all column-write privilege types. Use effective privilege inquiries so inherited/PUBLIC access is not missed; test expected positive reads as well as denied access.

Require the eight exact public SELECT policies: names, tables, authenticated-only role set, permissive mode, command, USING expression and null WITH CHECK. Compare a normalized PostgreSQL-17 deparse against the migration-defined expression; validate it against both source-derived synthetic policy definitions and the actual migrated schema. Do not execute helpers or replace an expression check with a policy-name count. Policy-helper function definitions and full managed-role/owner configuration remain separate schema-compatibility evidence; this component does not redefine platform BYPASSRLS or intentional private-schema helper access.

Expected application relations must be ordinary nonpartitioned tables without inheritance. Report missing/unsupported expected relations and unexpected public/private table/view/foreign/materialized relations; do not silently skip them. Other schema objects and full expected constraints/functions remain the existing schema-compatibility prerequisite.

### Deletion and retirement predicates

Use null-safe checks, e.g. `count(*) filter (where (required_shape) is not true)`. Reproduce the existing identity/state shape, not new product rules. Prepared is non-destructive with an active profile. Token-ready/apple-revoked pair with deleting; auth-delete-pending/completed pair with anonymous presentation. Preserve matching nonterminal profile/Auth references where defined; a pending anonymous profile still has private deletion Auth/Apple references, while completed has neither and has a completion marker. Missing corresponding rows are failures rather than inner-join omissions.

For deleting/anonymized profiles, check retirement of active installations, notification work in either profile direction, mute links, App Attest keys/challenges/grants, unfinished competitions, and unconsumed invites on their cancelled competitions. The existing live-notification-work count includes incomplete retirement: any pending/leased work or any related row retaining nonnull lease_token, lease_expires_at or leased_apns_token_sha256. Inspect only nullness, never values. Consumed invitations and unrelated profiles remain unaffected. Independently check revoked installations have no App Attest rows. Anonymous participants remain anonymized. Completed records have exactly one completion support event; such an event without a completed record is a violation. Count retained anonymous result participation without filtering away historical results.

Do not read Vault token contents/existence, reconstruct scrubbed identifiers, infer managed Auth/session retirement from null references, or treat synthetic/zero counts as genuine physical completion. Actual Auth deletion, session retirement, genuine retained shared history, deletions after the recovery point, and external-service quarantine remain independently required evidence.

### Read-only/privacy wrapper

Use a fresh top-level `psql -XqAt --file` connection, ON_ERROR_STOP on, ON_ERROR_ROLLBACK off, SQLSTATE-only errors, no context, repeatable-read/read-only, `row_security=off`, UTC, a 30-second statement timeout, fixed search_path, and rollback. The mode/origin guard proves effective settings, not connection freshness. No DDL, grants, role switches, token reads, temporary database objects, or writes occur in operator files. Unsupported types/schema or incomplete visibility must fail or report an explicit invalid category; never return a false zero via filtered rows. Transport/common recovery point remain separate caller prerequisites.

## Task 1 — Tests before operator implementation

**Files:** Create `scripts/test-recovery-state-acceptance.sh` and a projected synthetic fixture under `scripts/tests/recovery-state-fixtures.sql`; a separate assertion/case file is allowed only if it simplifies the harness.

1. Check operator/query presence before connection checks, scratch creation or fixture mutation. Run `bash scripts/test-recovery-state-acceptance.sh --static` with the files absent; require exit1 and a fixed `missing_operator_expected_red` or `missing_query_expected_red` category. Record this as preparation RED, not algorithm proof.
2. Prepare a guarded runtime harness using the existing FK/history conventions: explicit absolute Unix socket, no TCP/password/default connection settings, fixed `healthcomp_recovery_fixture` database/5432, PG17, non-recovery, explicit fixture superuser and empty application fixture catalog.
3. Use actual PostgreSQL tables, policies, grants and synthetic rows. A projected schema may include only source-typed columns needed by these predicates plus a denied-column control; it is not a substitute for actual migrated-schema compatibility. Install policy expressions from immutable source, not an oracle copied from the query.
4. Preserve pre-existing API roles and every role attribute. Create absent synthetic API roles only on the guarded disposable server and track ownership. Any unique test-only inherited-role membership must be absent before setup and removed exactly afterward. Never change hosted/shared roles or use broad cleanup. Commit fixtures only when fresh-connection visibility requires it; clean exact owned objects/roles and prove final emptiness. Ambiguous setup ownership requires parent disposal of the exact owned fixture server.
5. Cover clean empty and valid state in every phase; source-defined permission positives; table/column/PUBLIC/inherited/grant-option violations; missing/extra table, wrong RLS/FORCE, policy name/role/command/expression/check/extra policy; malformed/null profile/deletion shape and missing counterpart; pending-not-completed distinction; each retirement violation, including cancelled/unconsumed invitations and each retained lease field on otherwise terminal notification work; completion event zero/duplicate/orphan; anonymous retained-result counts and unaffected other-profile controls. Include consumed-invite and clean-terminal-work positive controls.
6. Prepare full-visibility and RLS-filter rejection with a positive read-permission control; wrapper mode/origin/timeout, SQLSTATE privacy and stop-on-error/sentinel controls. Mutated wrapper candidates must be rejected. Static checks do not substitute for these runtime checks.

## Task 2 — Observe real SQL RED, implement, then GREEN

**Files:** Create the two operator files above.

1. After preceding main CI is terminal, use one exact owned, network-none OrbStack PostgreSQL17 container, no ports/host-data mounts, one CPU/512MiB memory/256MiB ephemeral database storage, bounded logs and the already verified reusable image.
2. Before implementing predicates, run an immediate temporary zero-count query candidate against a real malformed-state case. Require the harness to reject its false receipt; never publish or use that candidate on actual data. Keep preparation fail-closed beforehand.
3. Implement the SELECT-only metadata and state predicates with explicit fixed receipt fields. Run each valid/invalid case, verify exact affected counts and unchanged unrelated counts, then run the full focused fixture suite. No test weakening or immutable migration changes.
4. Independently verify cleanup/empty catalog. After independent review, repeat the unchanged focused suite. Stop/remove only the owned fixture container and verify absence; retain bounded reusable image and privacy-safe evidence.

## Task 3 — Runbook, existing CI and integration

**Files:** Modify `docs/runbooks/backup-restore.md` and `.github/workflows/backend.yml`; update this plan's execution evidence.

1. Describe the entry file, exact receipt criteria, per-table authorization baseline, pending-phase quarantine and evidence limits. Reference packaged SQL rather than duplicate another SQL block. Keep NOT QUALIFIED FOR EXECUTION until all operational prerequisites genuinely pass.
2. Run new static/runtime checks in the existing disposable recovery fixture sequence. Require cleanup before invoking the actual wrapper/query as ordinary postgres against the fully migrated empty CI database. Validate exact receipt keys/types, expected17-table baseline and zero violation counts; empty real-schema compatibility is not hosted-history evidence.
3. Run existing runbook checks/negative controls, new shell syntax/static checks, workflow YAML/run-block syntax, layout, diff and staged secret checks. Obtain independent implementation/spec/privacy review and resolve actionable findings.
4. Conventionally commit one cohesive reviewed slice, push one PR batch after prior main CI, require exact-head Backend/iOS gates, merge head-pinned, and verify resulting-main ancestry/tree/CI. Keep all worktrees/branches. Do not promote staging/production under this test change.

## Documentation references

- [PostgreSQL 17 privilege inquiries](https://www.postgresql.org/docs/17/functions-info.html#FUNCTIONS-INFO-ACCESS-TABLE): effective table/column/PUBLIC and grant-option queries.
- [PostgreSQL 17 pg_policy](https://www.postgresql.org/docs/17/catalog-pg-policy.html): role, command, permissive and expression fields.
- [PostgreSQL 17 GRANT](https://www.postgresql.org/docs/17/sql-grant.html): table/column privilege types and grant semantics.

Context7's version-specific PostgreSQL17 documentation and the primary pages were checked during planning. Runtime deparse/permission behavior still requires real fixture and migrated-schema verification. Full Goal completion still requires the separate physical/two-account/history/export/restore/forward-repair/policy/production gates.

## Execution evidence — 2026-09-05

Preceding exact-main Backend33952894324 and iOS33952894313 both completed
successfully at `ad46b51`; iOS finished at08:04:54Z. No new database batch began
before those gates were terminal. The original dirty main checkout and every
historical branch/worktree were preserved.

Task1 preparation RED was independently observed before the operator existed:
exit1, `missing_operator_expected_red`, with no connection or fixture writes.
Plan review added the source-required unconsumed-cancelled-invitation and
retained-notification-lease checks. Test preparation review corrected empty
expected-vector handling and added null/unknown deletion phases and an explicit
psql error-rollback assertion. Frozen preparation was independently reviewed
with no remaining Critical/Important findings; static checks are not SQL credit.

Task2 used one owned network-none OrbStack PostgreSQL17.11 container, no ports
or host mounts, one CPU,512MiB memory and256MiB tmpfs database storage. A
deliberately false zero-violation candidate passed clean empty state and then
failed `malformed_profile_canary_receipt`, exit1. Exact cleanup was independently
confirmed by zero extra schemas/public relations. That candidate was replaced
before publication; it was never used on actual data.

The real query passed the state/permission suite until a test restore-step bug:
PostgreSQL17 table-level REVOKE also removed the pre-existing profile column
grants. An independent guarded, rolled-back transaction demonstrated the two
column privileges changing from true to false. Restoring the exact id/display_name
grants in that fixture undo fixed the test without changing its expected counts
or weakening the operator. Full GREEN then passed.

Independent review found no Critical/Important/Minor operator findings. An
unchanged final rerun passed155 state probes and eight wrapper probes, exit0,
including exact fixture cleanup and role-snapshot preservation. Independent
post-cleanup catalog readback was again zero/zero. The exact owned container
was stopped/auto-removed; zero OrbStack containers remained. Only synthetic,
rebuildable data was removed; the pinned291MB image is retained.

Task3 runbook/workflow integration was independently reviewed with no findings.
Local static verification passed the state parser/policy controls, existing
runbook checks/four negative controls, eleven FK parser controls, exact FK
runbook parity, layout, diff checks and workflow YAML/two Bash run blocks.
Commit/staged-secret verification, actual migrated-schema CI, exact-head full
matrix and resulting-main integration remain required at this checkpoint.
No hosted, physical, credential, paid-resource or production operation occurred.
