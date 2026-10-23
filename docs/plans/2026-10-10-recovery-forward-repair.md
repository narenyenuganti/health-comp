# Local restored-database forward repair

## Approved boundary

Continue the approved native PostgreSQL restore → reviewed migration → integrity
seam on `test/recovery-forward-repair`, based on merged `6404efa`. Only synthetic
data in newly owned OrbStack resources is allowed. No existing database,
credential, hosted project, phone, live competition, paid setup, Apple contact,
policy publication or production action is in scope.

Reuse `test-recovery-migrated-snapshot.sh` and its pinned PostgreSQL image,
native TLS export, networkless destination, Cron-off guard, role preparation,
actual history/state/FK queries and exact ownership-checked cleanup. Add one
explicit `--forward-repair` test case, retaining the original no-argument case.
Do not create or modify an application migration.

## Selected reviewed repair

`20260927001500_clear_retired_installation_tokens.sql`, already merged through
PR #114, clears only retired installations' APNs tokens, preserves installation
identity/history and active tokens, and prevents future retired-token retention.
Bootstrap the actual migration prefix through `20260913001400`, create one
synthetic completed competition and active/revoked installations, then export
and restore that database before applying the selected repair.

## Acceptance

1. Prove the restored pre-repair token-retention assertion fails. A skipped
   repair must not produce a success receipt.
2. Apply the exact checked-in migration transactionally with postconditions.
   Verify the retired token is null, the active token is unchanged, and every
   installation field other than the retired token is byte-equivalent as JSON.
3. Preserve actual history/result fingerprints, profiles, competition rows,
   owners, grants, RLS/policy receipt and FK integrity. Keep IDs/tokens/rows out
   of retained output; full-row comparisons use synthetic data only.
4. Prove future retirement clears its token and tokenless reactivation fails;
   roll back these test mutations. Duplicate migration execution must fail
   transactionally without changing restored state or migration history.
5. Append the selected migration's version only after its checks pass, then
   apply the remaining checked-in migrations and qualify the current schema's
   history/state/FK checks. Never rewrite a migration version.
6. Recheck network/port/Cron quarantine and independently verify exact owned
   resources were removed. Do not stop unrelated containers or prune images.

Run the original harness case once as affected regression coverage, not new
hosted evidence. Bound each invocation with a 600-second timeout. Run Bash
syntax, ShellCheck, runbook controls, secret scan and diff check; independently
review before integration.

## Local result

Both native modes exited 0 on October 10, 2026 with PostgreSQL 17.6 and
Supabase CLI 2.113.0. The forward case rejected the unrepaired legacy fixture,
passed the selected repair and remaining migrations, and preserved the actual
history/state receipts and protected row/security digest. The original case
still detected the concurrent-write control, rejected expired snapshots, and
matched both bound and unbound restore receipts. Native dump hostname/trust
negative controls passed in both modes. Ownership-scoped cleanup and an
independent readback found no test containers, volumes or networks; the
unrelated `hde-test-db` container was left running.

Bash syntax, ShellCheck, runbook static checks and their four mutation controls,
recovery-state static checks and diff check passed. One read-only independent
review found a swallowed FK-audit exit status; its fix and final migration-role
changes were rereviewed with no remaining confirmed auth/privacy findings.
The harness does not make a failed SQL check succeed by accepting empty output.

## Limits

This is a local synthetic forward-repair component, not Task 18's hosted
restore rehearsal. It does not establish genuine anonymized history, managed
Auth/Vault recovery, post-backup deletion reconciliation, complete global or
non-MVCC state, operational RPO/RTO, signed-release physical behavior, or
production readiness. Paid setup and Apple contact remain held.
