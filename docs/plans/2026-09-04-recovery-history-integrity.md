# Recovery History Integrity Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement and test Task 18's missing aggregate every-competition sequence and frozen-result integrity checks without executing a hosted recovery or changing application/server contracts.

**Architecture:** One SELECT-only SQL query produces a fixed JSON aggregate receipt. A read-only wrapper supplies repeatable-read isolation, complete-visibility failure, UTC formatting and timeouts. Synthetic PostgreSQL-17 tests execute the same query and the existing canonical hash functions extracted from immutable migrations; they do not emulate PostgreSQL hashing in another language. No RPC, migration, privilege grant, application authentication seam, export runner, or restore authorization is added.

**Tech Stack:** PostgreSQL 17 SQL/pgcrypto, Bash test-stream assembly, isolated OrbStack test container locally, existing Backend CI.

---

## Design and boundaries

Base: exact merged main `ba5d106f709f0325f1c0536a5d407e8a88a1db18`, tree-identical to fully verified PR #88 head. Its normal post-merge CI is watched separately. Preserve every existing worktree and the original dirty main checkout. Do not push another CI batch until preceding main CI is terminal.

Chosen approach: read-only SQL plus synthetic tests on PostgreSQL 17. A separate-language verifier would duplicate database encoding/JSON semantics; a hosted-first probe would couple untested code to credentials and private data. Neither is selected. The locally installed unqualified PostgreSQL command is 14.20; it is not used as target-version proof.

Only one purpose-labeled local PostgreSQL-17 container may run, explicitly in the OrbStack context, with no network, published ports or host data mounts, at most one CPU/512 MiB memory, and bounded ephemeral data storage. No Supabase stack or Docker Desktop. Record image identity and actual server version; remove the exact owned container when the focused batch stops. No existing image/container is removed or modified.

### Receipt contract

The query returns exactly one `receipt` JSONB column, with these exact keys:

- `receipt_version`: integer 1;
- `competitions_checked`, `competitions_invalid_sequence`, `change_rows_total`, `change_rows_orphaned`;
- `results_total`, `results_format2_checked`, `results_format2_invalid`, `results_legacy_unverified`, `results_unsupported`;
- `aggregate_stored_result_hash`, `aggregate_complete_result_fingerprint`: lowercase 64-hex aggregate comparison values.

All count fields are nonnegative integers. Format-2 checked + legacy unverified + unsupported must equal results total; format-2 invalid is a subset of checked. No overall pass or release-ready flag exists. Empty input produces zero counts but cannot substantiate populated/genuine-deletion history. Operators must compare both source/restore aggregates and separately satisfy all other recovery gates.

Sequence checks cover every parent competition including empty logs, count false/null predicates as invalid, and separately count orphan change rows. Require start 1, no duplicates/gaps, and exact next cursor. This is current shape, not historical proof that no rewrite ever occurred.

For format 2, validate canonical participant identity/order/mapping, complete frozen-window shape and nested commitments, total ranges, outcome/winner semantics, finite completion time, positive sequence and the existing outer result hash. Use frozen content, not current memberships/latest revisions. Existing validators returning null are not a pass. Guard decoders behind successful validation.

Format 1 lacks an established stored-content hash derivation: preserve it but report unverified. Missing/unknown/wrong-type versions are unsupported. Never upgrade, re-finalize, rewrite, or omit such rows to obtain green results.

The complete-result comparison fingerprints every stored result column; normalize `completed_at` to its binary timestamp representation so it cannot be omitted or depend on session time-zone rendering. Preserve a deterministic row order and fixed-length inner digests. This complements the established stored hash, which excludes completion time and top-level server sequence. It does not replace schema, foreign-key, grants, deletion, artifact or common-recovery-point validation.

## Task 1: Write executable synthetic tests and observe RED

**Files:** Create `scripts/emit-recovery-history-test-sql.sh`, `scripts/tests/recovery-history-fixtures.sql`, `scripts/tests/recovery-history-assertions.sql`.

1. Assemble a rollback-only test transaction from fixed reviewed paths. Before any fixture mutation, assert PostgreSQL major 17, database name exactly `healthcomp_recovery_fixture`, Unix-socket connection, and no pre-existing public relations or private/Auth schemas. This test program is not an operator/hosted query.
2. Extract only the existing `tlv_v1`, `window_day_content_v1`, `is_valid_frozen_window_v2`, and `result_immutable_hash_v1` definitions from the reviewed immutable migrations. Fail if extraction is missing/ambiguous. Never modify those migrations or substitute mocked hash functions.
3. Create synthetic relation projections with real column types; the complete `competition_results` row shape must match source. Deliberately omit fixture constraints needed to represent malformed restore data; do not claim these fixtures test the actual constraints. Exercise the actual query as a temporary view.
4. Require valid empty/contiguous histories, valid best-available/stable/mixed windows and the existing cross-language golden. Require changed hash/content/commitment/basis/mapping/totals/winner, null/malformed types, legacy/unknown formats, gaps/duplicates/cursor errors/orphans, mixed row populations, and exact output allowlist checks.
5. Assert profile anonymization does not exclude frozen results. Show that changed completion time/top-level sequence leaves the established hash untouched but changes the complete-result fingerprint. Require deterministic receipts under different session time zones.
6. Run the missing-query assertion before implementation; retain expected RED. Then use an empty-receipt query stub to observe database assertions fail for the absent contract before implementing actual checks. Record these separately from later negative-case behavior.

## Task 2: Implement the SELECT-only query and read-only wrapper

**Files:** Create `scripts/recovery-history-integrity-query.sql`, `scripts/recovery-history-integrity.sql`.

1. Aggregate per-competition log shape and orphan rows. Return only the defined counts.
2. Partition every result by supported, legacy-unverified, or unsupported format. Reuse canonical validators/hash functions, plus the established client/row semantic checks. Guard malformed decoding and count null/false as invalid.
3. Produce the stored-hash aggregate and full-row preservation fingerprint. Do not expose per-row identifiers, scores, timestamps, hashes or payloads.
4. The wrapper sets psql error output to SQLSTATE-only with no context, enables stop-on-error, begins repeatable-read/read-only, sets `row_security=off`, UTC and a 30-second timeout, includes the query, then rolls back. This does not bind separate exports to a common snapshot and does not grant/bypass RLS.
5. Execute the complete synthetic test stream on isolated PostgreSQL 17; require expected generic assertion failures before GREEN. Test the real wrapper against the fixture schema without writes and prove its transaction/access/error boundaries.

## Task 3: Verify, review, document and integrate

**Files:** Modify `.github/workflows/backend.yml` and `docs/runbooks/backup-restore.md` only as needed to invoke/document the qualified component.

1. Add the focused test to the existing disposable backend CI environment, with the same guarded separate synthetic database. Also execute the read-only wrapper against the fully migrated empty CI database to catch real-schema/helper mismatches. Never run this against a linked/hosted project.
2. Run shell syntax, positive/negative focused checks, existing runbook checks, layout, exact diff and staged secret checks. Independently review correctness, privacy/error handling, query coverage and test isolation; resolve findings.
3. Keep the runbook's NOT QUALIFIED FOR EXECUTION gate. Precisely credit only the implemented query/runtime checks; complete operational receipt coverage, real anonymization/history, full write freeze/transport/containment, target, export/restore/forward repair and production policy remain required.
4. After preceding main CI is terminal, conventionally commit the logical slice, run exact PR-head CI, merge head-pinned and verify resulting-main CI. No software pass closes hosted or physical gates.

## References and remaining evidence

- `docs/runbooks/backup-restore.md` and `docs/runbooks/competition-support.md`.
- `supabase/migrations/20260811000100_create_multi_user_competitions.sql` and `20260811000400_add_score_and_finalization_functions.sql`; existing finalization/archive test fixtures and Swift result validation.
- [PostgreSQL 17 transaction semantics](https://www.postgresql.org/docs/17/sql-set-transaction.html), [row security](https://www.postgresql.org/docs/17/ddl-rowsecurity.html), [psql error controls](https://www.postgresql.org/docs/17/app-psql.html).
- [Official PostgreSQL container documentation](https://hub.docker.com/_/postgres). Local trust authentication is permitted only within the network-isolated synthetic fixture container; it is never a hosted transport policy.

No hosted result-format distribution, real restore, deletion, phone/account action or production-readiness evidence is implied by this plan.
