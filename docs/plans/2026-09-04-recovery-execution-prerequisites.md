# Recovery Execution Prerequisites Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Correct Task 18's existing recovery documentation and protect known snippet defects without claiming a qualified export or completed restore.

**Architecture:** Keep the existing restricted logical-recovery approach and its privacy boundaries. Add a decisive readiness gate, accurate export/receipt/quarantine requirements, and a non-executing static snippet check. This is not a backup runner, alternate authentication path, hosted operation, or production policy decision.

**Tech Stack:** Markdown, Bash/awk static checks, PostgreSQL 17 documentation, pinned Supabase CLI 2.113.0 source.

---

## Scope and design decision

Baseline: merged main `baf8a4602d79d2ae10ffdbb220e3e1c7d9675a36`, whose tree equals reviewed UI head `9d45116`. Exact-head Backend/iOS CI passed; exact-main CI is being watched separately. The original main checkout is dirty and must not be changed.

Use a runbook-only correction plus static regression coverage. An independently validated export runner is a later operational batch; a platform/PITR path also needs target containment and a displayed cost decision. Neither alternative is silently selected here. Preserve genuine deletion/history proof and Task 18's real restore/forward-repair requirements.

## Task 1: Reproduce documentation defects without executing snippets

**Files:** Create `scripts/test-backup-runbook.sh`.

1. Check the documented receipt transactions use explicit repeatable-read/read-only and row-visibility guards.
2. Reject the schema-qualified COALESCE expression.
3. Require each data-file import's reset assertion immediately after the import, without a wrapper reset masking it.
4. Extract Bash fences and run only `bash -n`; never evaluate snippets or contact a service.
5. Run `bash scripts/test-backup-runbook.sh` against the unchanged runbook and retain the expected failure categories. This is a documentation regression RED, not an executed SQL failure.

## Task 2: Correct the existing runbook

**Files:** Modify `docs/runbooks/backup-restore.md`.

1. Add an explicit unqualified execution gate and date-bound the older environment inventory.
2. Require a proven common recovery point, all relevant writers covered by an approved freeze, and breach invalidation; receipt isolation alone does not synchronize dump sessions.
3. Require verified TLS for every connection, prohibit credential-bearing dry-run capture, and explain the pinned CLI's unproven propagation. Do not present its example as ready to run.
4. Require pre-import destination containment and validate the managed-history schema/artifact manifest before choosing four versus additional artifacts.
5. Correct COALESCE, transaction isolation/row-visibility guards, and reset-assertion ordering.
6. Specify non-vacuous deletion evidence, complete sequence/version-aware hash validation prerequisites, recovery timing, and a separately reviewed forward-repair rehearsal. Do not invent validators, migration history, an external deletion ledger, or passing evidence.

## Task 3: Verify, review, and integrate the documentation correction

**Files:** Create `scripts/test-backup-runbook-checks.sh`; modify `.github/workflows/backend.yml` to call both static checks.

1. Run `bash scripts/test-backup-runbook.sh`; expect pass limited to snippet structure and Bash parsing.
2. Run the check against the immutable baseline via a process-substitution pipe; require the same known failures. This does not write a fixture or execute old snippets.
   Run `bash scripts/test-backup-runbook-checks.sh` to require rejection of in-memory mutations that remove assertion bodies, move a visibility guard into the other receipt, duplicate the data import in place of history, or balance malformed Bash across separate fences. The helper verifies each mutation occurred before testing rejection.
3. Run `bash scripts/verify-supabase-layout.sh`, `git diff --check`, shell syntax checks, and a scoped staged secret scan. Verify no application, migration, package, credential, or local-environment files changed.
4. Independently review accuracy, privacy, prerequisite ordering, and the static check's limitations. Record and address findings before committing.
5. After the preceding exact-main CI is terminal, conventionally commit the cohesive correction, push once, obtain both exact-head CI results, and integrate with a head-pinned merge. Verify resulting-main CI independently. No hosted or physical readiness is inferred.

## Explicit remaining gates

Runtime qualification of receipt SQL, verified export transport and common recovery point, actual destination containment, genuine deletion/history evidence, a real hosted restore and forward repair, approved ongoing production recovery objectives, physical/two-account gates, and production promotion remain unfinished. The static test must never report these as passing.

## Verification checkpoint

The original runbook produced the expected static RED before correction. The corrected document passes, and the immutable baseline still fails. Independent review then identified four false-passes in the initial checker; the new in-memory negative controls reproduced all four before the checker was corrected. Transaction-scoped visibility, complete reviewed assertion bodies, distinct imports, and individual Bash-fence parsing now reject all four mutations. Root and independent rereview confirmed the corrected positive/negative checks and clean diff; no review findings remain in the scoped documentation/static checks. The timing definition was clarified to measure recovery-point age at restore/import start, while total rehearsal duration begins before provisioning/export.

No SQL, dump, restore, hosted change, local container, physical-device action, or credential access was performed. Source is not yet committed at this checkpoint. Preceding-main Backend CI `33940154654` passed; iOS `33940154661` is still running. Commit/push and the new exact-head/resulting-main gates remain pending; static GREEN is not operational recovery qualification.
