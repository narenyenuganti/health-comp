---
name: delete-comment
description: Audit, categorize, and remove code comments in a file or directory, filing issues for excuses, moving decision records to ADRs, and tightening the comment ratchet.
---

# /delete-comment

Systematically burn down remaining code comments listed in `scripts/comment-ratchet.json` without losing architectural knowledge or hiding hacky implementations.

## Arguments

Pass an optional path (file or directory) such as `HealthComp/App`, `HealthComp/Services/HealthKitProvider.swift`, or `supabase/tests`. If omitted, inspect `python3 scripts/verify-no-comments.py --report` and pick the next highest-leverage legacy directory.

## Guardrails

- **Never edit historical applied migrations** under `supabase/migrations/*.sql`. Leave already-applied migrations untouched in `scripts/comment-ratchet.json`; only newly created migrations are required to be comment-free.
- **Never delete mandatory machine directives** exempted by `scripts/verify-no-comments.py`:
  - Line-1 shebangs (`#!...`) in `.sh` / `.py`
  - Line-1 `// swift-tools-version:...` in `Package.swift`
  - `// deno-lint-ignore...` in `.ts` / `.js`
  - Line-1 `-- Callable catalogue for build ...` in `supabase/tests/900_released_api.test.sql`
- **Never raise the ratchet.** `--update-ratchet` only lowers existing counts or deletes zeroed entries.

## Workflow

### 1. Inspect every comment in scope

List remaining ratcheted files and extract every comment in the target path with surrounding code context:

```bash
python3 scripts/verify-no-comments.py --report
python3 scripts/verify-no-comments.py --next-smallest
python3 scripts/verify-no-comments.py --list <path>
```

Read every comment block in the target file(s) alongside the surrounding code before deleting anything.

### 2. Categorize each comment

Assign every comment block to exactly one category:

| Category | Definition | Required Action |
| --- | --- | --- |
| **Tautology** | Repeats what is already visible from types, names, or control flow (including `// MARK:` dividers, test narration, and trivial docstrings). | Delete the comment. |
| **Stale** | References removed APIs, completed plan tasks, or behavior that no longer matches the code. | Delete the comment. |
| **Excuse** | Justifies a hack, shortcut, workaround, swallowed error, brittle test, or deferred cleanup (including `ponytail:` comments). | Delete the comment **and** file a GitHub issue (`gh issue create`) describing the hacky implementation and suggested fix. Check `gh issue list --state open` first to avoid duplicates. |
| **Decision Record** | Captures an important, non-obvious architectural, protocol, security, concurrency, privacy, or UX decision. | Move the rationale into `docs/adr/` (append to the relevant domain ADR or create the next `NNNN-short-slug.md` and update `docs/adr/README.md`), then delete the inline comment. |

### 3. Delete comments cleanly

- Remove full-line comments and collapse any redundant blank lines left behind.
- Strip trailing inline comments without leaving trailing whitespace.
- If removing a comment leaves an empty block that a linter rejects (such as Deno `no-empty` on `catch {}`), replace it with explicit idiomatic code (e.g., `return false;` or explicit state reset) rather than re-adding a comment.
- Confirm no code logic was accidentally altered.

### 4. Tighten the ratchet

```bash
python3 scripts/verify-no-comments.py --update-ratchet
python3 scripts/verify-no-comments.py
```

Verify that every cleaned file has been removed from `scripts/comment-ratchet.json` (effective budget `0`).

### 5. Verify

Run the checks matching the files you touched:

```bash
python3 -B -m unittest scripts.tests.test_verify_no_comments
python3 scripts/verify-no-comments.py
git diff --check
```

- For `supabase/functions/` or `scripts/tests/*.ts`: run `deno fmt --config supabase/functions/deno.json --check ...`, `deno lint --config supabase/functions/deno.json ...`, and `deno test`.
- For `scripts/*.sh`: run `bash -n` on every shell script and its paired `scripts/test-*.sh`.
- For Swift targets (when on macOS with Xcode): run `swift test --package-path Modules/CompetitionCore` or the matching `xcodebuild test` scheme.

### 6. Report

Summarize:
- Files cleaned and net lines removed
- Category counts (Tautology, Stale, Excuse, Decision Record)
- Links to any GitHub issues filed for Excuses
- Links to any ADRs added or updated under `docs/adr/`
- Remaining ratcheted files and comment lines from `scripts/verify-no-comments.py --report`
