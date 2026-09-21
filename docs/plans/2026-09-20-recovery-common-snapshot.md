# Local common-snapshot recovery component

## Approved boundary

The user approved testing PostgreSQL's native export/restore commands locally
with synthetic data, proving the exported tables and comparison receipt describe
the same snapshot. No hosted project, credentials, paid service, phone, or
production backup-policy decision is in scope. Base: merged main
`99d37bb30a5d35c316d94ab73be67180a7af601d`; purpose branch
`test/recovery-common-snapshot`. Preserve the dirty root checkout.

Use one test script and native PostgreSQL 17 tools. No export framework, new
dependency, application change, migration, or operator recovery entry point.
Reuse the existing empty `healthcomp_recovery_fixture` Unix-socket test boundary;
require an explicit local superuser and reject nonempty/pre-existing targets.
Use a separate, initially absent `healthcomp_snapshot_restored` target database.
Keep database errors in disposable scratch space; print only fixed test outcomes.

## RED to GREEN

1. Create two related synthetic tables with literal expected rows and real keys.
2. Hold a repeatable-read, read-only exporter open with `pg_export_snapshot()`.
3. Commit a separate update/delete/insert; independently assert the new state.
4. Import the snapshot into a separate receipt transaction before its first query.
5. RED: dump without binding that snapshot, restore natively into an empty target,
   and observe the original receipt mismatch. A missing executable is not this RED.
6. GREEN: pass `pg_dump --snapshot`; require restored rows equal both the receipt
   and independent original literals. Retain the unbound dump as a negative control
   and require that it contains the changed literals and differs from the receipt.
7. Release the exporter, remove only owned fixtures/target/scratch, and verify the
   source is empty again. On uncertain setup, dispose of the exact owned server.

## Execution and review

Serialize expensive Xcode/Supabase gates and wait for preceding main CI before
new integration CI. This small native PostgreSQL-only test may run while the
existing remote iOS job finishes; it starts no Xcode build or Supabase stack. The
earlier blanket wait was unnecessary for this bounded component. Use one
explicit OrbStack PostgreSQL-17 container, no network/ports/host mounts, one CPU,
512 MiB memory, bounded tmpfs storage and an overall test timeout. Record its image
identity and actual server version. Remove that exact container after the batch;
never clean unrelated OrbStack resources or start Docker Desktop.

Run Bash syntax/ShellCheck, actual RED/GREEN and negative controls. After focused
qualification, reuse the existing Backend CI fixture container for this check.
Request approval for one independent read-only reviewer before integration;
earlier reviewer approvals do not cover this new slice. Conventionally commit and
integrate only after review and exact-head CI, then verify resulting-main CI.

## Local evidence (September 21 UTC)

- PostgreSQL `17.11 (Debian 17.11-1.pgdg12+2)` and matching native clients, arm64.
  Official image manifest:
  `postgres@sha256:639ab7ceb90e13123085b741fb31ef493fba25463002f6da665352e7b534b652`.
- Actual RED exited1 with `snapshot_restore_receipt_mismatch` after an unbound
  export/restore. RED script SHA256:
  `08f7646dc12e04eaf31b72aa7f1fc80bf08d9c905f502ae85d85aafc99f89e84`.
- Adding only the snapshot option to the positive case produced GREEN, including
  the retained unbound-export negative control. A second full run also passed.
  Qualified script SHA256:
  `55cb92226b319890eeff3eaebac774a7215608454d2c12d9f1ef36c26a8e9e96`.
- Separate native guard checks rejected a pre-existing restore database and a
  nonempty source while preserving their sentinel rows. Missing/network hosts and
  the locally installed older client were also rejected before connecting.
- After RED and final GREEN: zero fixture schemas, public relations, restore
  targets, or other active source transactions. No test scratch directory remained.
  The exact fixture container was stopped and removed, including its tmpfs data.
- Bash syntax, ShellCheck and workflow Actionlint passed locally. Backend CI wiring
  is added but not yet executed in its Supabase image. Independent review and
  exact-head/resulting-main CI remain pending; no commit or hosted action occurred.

## Limits

This tests MVCC consistency of two synthetic tables only, not sequences, roles,
Auth/Vault, RLS/grants, full schema coverage, TLS, genuine deleted-user history,
artifact completeness, target quarantine, RPO/RTO, or forward repair. The
[backup runbook](../runbooks/backup-restore.md) remains NOT QUALIFIED FOR EXECUTION.
No source/current CI success means a hosted backup or production launch is ready.

Sources: [PostgreSQL 17 exported snapshots](https://www.postgresql.org/docs/17/functions-admin.html#FUNCTIONS-SNAPSHOT-SYNCHRONIZATION),
[transaction snapshot import](https://www.postgresql.org/docs/17/sql-set-transaction.html),
and [pg_dump --snapshot](https://www.postgresql.org/docs/17/app-pgdump.html).
