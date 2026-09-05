# Recovery Foreign-Key Integrity Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Qualify the existing Task 18 read-only foreign-key audit with real PostgreSQL-17 synthetic fixtures, without performing a hosted restore or changing any application, migration or privilege contract.

**Architecture:** Package the existing runbook audit as a fixed top-level psql file with SQLSTATE-only error handling. Keep the documented SQL byte-identical through a static drift check. A separate local-only harness validates real catalog constraints and rows in a guarded disposable fixture database; compatibility with the migrated schema runs separately as the ordinary `postgres` role.

**Tech Stack:** PostgreSQL 17, psql, Bash, one bounded OrbStack fixture container when runtime gates are available, existing Backend CI.

---

## Design and timing boundary

Preparation worktree: `.worktrees/test-recovery-foreign-key-integrity`, branch `test/recovery-foreign-key-integrity`, starting from PR #89 head `a73b8f7b4a39460cf994325a1b18b3c52b630966`. This dependency is not yet integrated at plan creation. Its existing iOS watcher remains authoritative. Preparation may proceed without another build/database, but no runtime, push, new CI batch or integration for this slice occurs before the preceding PR and resulting-main gates finish. Reconcile the branch with that verified main before integration. Preserve the original dirty checkout and every historical worktree.

The previous next-slice inventory placed all work after PR #89 integration. The narrower timing adjustment here permits isolated design/test preparation during the already-running wait; expensive execution and integration remain serialized. This does not broaden the operational scope.

Chosen approach: one packaged SQL file plus a byte-equality guard for its documented example. Testing by extracting SQL directly from prose would avoid a second copy but couple operator execution to a Markdown parser. Adding a database function would require installing code/privileges on the recovery target. Neither alternative is selected. The file itself performs no CREATE/ALTER/DELETE/GRANT operation.

Scope remains foreign keys whose referencing relation is in `public` or `private`. Preserve MATCH SIMPLE semantics: a row is exempt if any referencing column is null; otherwise a matching referenced tuple must exist. Fail closed for other match modes and incomplete visibility. Follow actual `conkey`/`confkey` ordinality and correctly quote relation/column names. The existing audit's count/query behavior must not be replaced with a catalog `convalidated` shortcut.

Source review found two general-scope defects in the old example, not evidence of current application corruption. Ordinary inheritance scans must use `ONLY` on source and target: a referenced child-only row cannot satisfy the parent's FK, and source-child rows do not inherit the parent's FK. Partitioned relations/action clones require different semantics and must be rejected explicitly in this bounded implementation. Validate catalog shape and supported native noncollatable UUID/UUID and bigint/bigint equality pairs, including `conpfeqop`, before using schema-qualified equality with target/PK on the left. These are every FK pair type currently declared by HealthComp, including composites and `auth.users` references; this is not a generic PostgreSQL verifier. Other types/operators/collations stop qualification for explicit review rather than being silently skipped or treated as valid. No immutable schema is changed to fit this support set.

Use SQLSTATE `0A000` for unsupported match/relation/operator/type shape, `23503` for an orphan, `P0001` for the effective mode/origin guard, and PostgreSQL's `42501` for incomplete visibility. Never include individual relation/constraint/key details in retained output. Tests must cover the unsupported boundaries as well as current application shapes.

Use a fresh top-level `psql -XqAt --file` connection, repeatable-read/read-only, `row_security=off`, 30-second statement timeout, stop-on-error, SQLSTATE-only errors and no context, then rollback. Assert effective transaction modes and `session_replication_role=origin`. These assertions do not prove connection freshness. Existing transactions/outer includes remain unsupported. Success is exit zero and empty output for this component, not a populated-history or overall recovery receipt. Do not print names, constraint names, keys, counts of private rows, or detailed failed-query context.

Do not claim the audit detects missing constraints, validates expected schema/grants, proves completed deletion, or establishes a common recovery point. Those remain independent acceptance checks.

## Task 1: Tests first; no database startup during preceding CI

**Files:** Create `scripts/test-recovery-foreign-key-integrity.sh`, `scripts/test-recovery-foreign-key-static.sh`; fixture SQL may be kept in `scripts/tests/recovery-foreign-key-fixtures.sql` if that simplifies review.

1. A missing packaged SQL file must fail before any connection, scratch directory or fixture write. Run that command and record the expected missing-implementation RED.
2. Add a static-only path which finds exactly one runbook SQL fence containing `do $healthcomp_fk_audit$`, requires a complete fence, and compares the entire SQL content to the packaged file. Track non-SQL code fences too: an SQL-looking fence inside a Bash/text block is not a standalone SQL example. No code from documentation is executed by this static check. Observe missing/mismatch RED before aligning the example. A separate static-only script must exercise positive byte equality and byte-mismatch/duplicate/unterminated/nested-other-fence rejection using synthetic document streams; this tests the parser, not the SQL algorithm.
3. Runtime is permitted only with an explicit absolute Unix-socket directory, fixed database `healthcomp_recovery_fixture`, fixed port 5432, PostgreSQL major 17, no recovery mode, an explicitly supplied local superuser and an initially empty fixture namespace/catalog. Use the existing guarded harness's credential-scrubbing/no-password pattern. Supabase's fixture superuser is `supabase_admin`; ordinary application compatibility remains `postgres`. Do not promote any role or remove guards.
4. Use only predetermined synthetic public/private relations in that initially empty fixture. If persistent fixture setup is needed for separate fresh audit connections, inventory exact objects and perform bounded cleanup; never clear an arbitrary schema/server. Verify emptiness after cleanup. No hosted/shared server is allowed.
5. Exercise actual PostgreSQL FK constraints: empty audit; valid single and composite keys; nullable MATCH SIMPLE combinations; reversed column ordering; public/private source coverage; a synthetic third-schema referenced table for the Auth boundary; unusual quoted names; same-name constraints on distinct tables; a real pre-existing orphan represented by `ADD ... NOT VALID` and a valid NOT VALID control; unsupported MATCH FULL/text-key/partition shapes; referenced inheritance-child-only orphan failure and referencing-child exclusion success; complete-visibility rejection with a proven positive SELECT-permission control, not a missing-grant confounder.
6. Require exact success/failure exit and SQLSTATE-only output. Verify no source/audit continuation sentinel runs after an error. Include appropriate positive controls before negative cases. Use temporary copies for mode/timeout/error-control mutations, never modify the live file to simulate a fault. Record incomplete runtime coverage honestly until a database has run the suite.

## Task 2: Package the existing audit and observe runtime RED/GREEN

**Files:** Create `scripts/recovery-foreign-key-integrity.sql`; modify only the matching SQL block/prose in `docs/runbooks/backup-restore.md`.

1. After the missing-file RED, prepare a read-only/error-control shell which fails explicitly as not implemented; never leave a usable no-op operator audit during the CI wait. Once runtime is available, temporarily use an empty audit body only for the immediate orphan-case RED on the guarded synthetic database, then implement the real audit. Do not credit static availability as algorithm verification, publish the placeholder, or use either stub against a real target.
2. Move the existing catalog-driven audit into the packaged file, retaining its full tuple checks and adding the reviewed supported-shape guards and ordinary-inheritance `ONLY` correction. Qualify the supported native equality operator and verify it matches `conpfeqop`. Add the effective transaction/origin assertions and privacy-safe psql preamble. Replace identifying exception messages with fixed error categories; operators still see only SQLSTATE.
3. Make the runbook SQL example byte-identical, and document the top-level file entry and component-only limits. Keep NOT QUALIFIED FOR EXECUTION in force.
4. Use one exact owned network-isolated PostgreSQL-17 container, explicit OrbStack context, no ports/host-data mounts, at most one CPU/512 MiB memory and 256 MiB ephemeral database storage. Reuse the already verified image when applicable. Preserve unrelated containers/images. After the focused batch, remove only the owned container and verify absence.
5. Resolve any fixture/implementation defects using the smallest real RED-to-GREEN step; do not weaken checks or mutate immutable migrations for passing tests.

## Task 3: CI, independent review and integration

**Files:** Modify `.github/workflows/backend.yml`; update the plan/runbook with actual evidence boundaries only.

1. Run static parser positive/negative controls, actual runbook drift and syntax checks in the existing static step. Run the guarded FK fixture suite in the existing separate empty recovery fixture database, after existing history/wrapper tests and before dropping it. Require exact fixture cleanup before the real-schema check.
2. Run the packaged FK audit through a fresh psql connection as `postgres` against the actual fully migrated empty CI schema. This is schema compatibility, not genuine restored-history proof.
3. Run focused tests, existing runbook positive/four negative checks, workflow YAML/Bash syntax, layout, diff and actual staged secret scan. Obtain independent correctness/spec and privacy/isolation review. Resolve all actionable findings.
4. Only after prior main CI is terminal and focused evidence passes, conventionally commit the slice, push one PR batch, require exact-head backend/iOS gates, integrate head-pinned and verify resulting-main ancestry/tree and CI. Preserve working branches/worktrees.

Remaining operational gates include all other acceptance queries, approved transport/write freeze/quarantine/target, genuine completed deletion and retained history, actual export/restore/forward repair, recovery measurements and production policy/promotion. No local pass closes a physical or hosted gate.

## Source references

- `docs/runbooks/backup-restore.md`, existing FK audit and required recovery invariants.
- `docs/plans/2026-09-04-recovery-history-integrity.md`, explicit FK exclusion.
- `scripts/test-recovery-history-wrapper.sh`, established disposable-fixture guard and privacy-safe psql behavior.
- PostgreSQL 17 documentation: foreign-key constraints, `pg_constraint`, `ALTER TABLE ... NOT VALID`, transaction semantics and psql error controls. Check current primary documentation rather than assuming cross-version behavior.

## Execution evidence and remaining qualification

The dependency merged as `4f96ee430f170aa227a6a52586eecc5a79b5a6b7`; exact-main Backend and iOS tests, all three device configurations and cleanliness passed before database execution. This branch was then fast-forwarded to that verified main, preserving its prepared files and the unrelated dirty main checkout.

The missing-file RED preceded any fixture work. A separate real static-parser RED exposed SQL-looking text nested inside a Bash fence; after the correction, all eleven static positive/negative controls passed independently. These parser tests execute no SQL.

On the isolated PostgreSQL 17.11 fixture, an immediate empty-body candidate passed the empty/valid/valid-NOT-VALID controls but failed `uuid_orphan_exit`: the test correctly rejected its false success on a real pre-existing orphan. The actual catalog audit then passed 35 probes and rejected both stop/verbosity control mutations. An unchanged rerun after independent SQL review repeated that result, including the exact fixture cleanup and empty-catalog check. No Critical or Important findings remain from the independent test-preparation and SQL reviews.

Only one successfully started OrbStack container was used: network none, no published ports or host mounts, one CPU, 512 MiB memory and 256 MiB tmpfs database storage. The initial start failed before process creation because a one-file local log cannot use compression; absence was verified and compression explicitly disabled for the successful start. The exact owned container and its synthetic state were removed after the final tests; the 291,051,895-byte reusable image is retained. No application, hosted database, real account, phone, credential or paid-resource action occurred.

CI must still verify the actual migrated empty schema as ordinary `postgres`, along with the unchanged automated matrix, before this slice is integrated. Local fixtures are component evidence only. The runbook's operational qualification, actual restore/forward repair, genuine completed deletion/history and other physical/hosted release gates remain open.
