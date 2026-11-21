# ADR-0001: No Code Comments with a Per-File Ratchet

- **Status:** Accepted
- **Date:** 2026-11-21

## Context

Code comments in an agent-assisted codebase drift rapidly into four failure modes:

1. **Tautologies** that repeat what is already clear from symbols and control flow.
2. **Excuses** (including `ponytail:` markers) that normalize hacks or technical debt instead of tracking real fixes in GitHub issues.
3. **Stale notes** referencing superseded plan tasks, removed APIs, or outdated behavior.
4. **Hidden architectural decisions** buried in implementation files where other subsystems and contributors miss them.

Deleting all ~6,650 comment lines across the repository in a single PR would risk losing subtle architectural context or creating unreviewable diffs.

## Decision

1. **Ban code comments repository-wide** across `.swift`, `.ts`, `.js`, `.sql`, `.sh`, and `.py` files via `scripts/verify-no-comments.py`, enforced in both iOS CI (`.github/workflows/ci.yml`) and Backend CI (`.github/workflows/backend.yml`).
2. **Use a strict per-file ratchet** (`scripts/comment-ratchet.json`):
   - Any file absent from `scripts/comment-ratchet.json`—including every newly created file and every already-cleaned section—has an effective budget of **0** comments.
   - Legacy files listed in `scripts/comment-ratchet.json` cannot exceed their recorded comment-line count.
   - If a listed file's comment count drops below its recorded budget (or reaches 0, or is deleted), CI fails until the baseline is tightened via `python3 scripts/verify-no-comments.py --update-ratchet`. The updater only lowers or removes entries; it never raises a count or adds a file.
3. **Allow only a narrow, explicit set of machine-read directives**:
   - Line-1 shebangs (`#!...`) in `.sh` and `.py` files.
   - Line-1 `// swift-tools-version:...` in `Package.swift`.
   - Deno linter directives (`// deno-lint-ignore...`) in `.ts`/`.js` files.
   - Line-1 `-- Callable catalogue for build ...` in `supabase/tests/900_released_api.test.sql` (checked directly by Backend CI).
4. **Leave already-applied historical SQL migrations immutable**: existing files under `supabase/migrations/` remain untouched in the ratchet baseline so applied migration history is never rewritten; all new migrations start at budget 0.
5. **Standardize burn-down with `/delete-comment`** (`.claude/skills/delete-comment/SKILL.md`), categorizing every comment as Tautology, Stale, Excuse (delete + file GitHub issue), or Decision Record (move into `docs/adr/`).

## Clean Sections (Budget 0)

Every mutable code directory in the repository is at budget `0`:

- `HealthComp/`
- `HealthCompTests/`
- `HealthCompUITests/`
- `HealthCompWatch/`, `HealthCompWatchWidgets/`, `HealthCompWatchUITests/`, `HealthCompWidgets/`
- `Modules/CompetitionCore/`
- `functions/`
- `scripts/`
- `supabase/functions/`, `supabase/tests/`, `supabase/seed.sql`

Only historical already-applied migrations under `supabase/migrations/*.sql` remain frozen in `scripts/comment-ratchet.json`; all newly created migrations start at budget `0`.

## Consequences

- No new comments can enter any code file anywhere in the repository.
- Non-obvious rationale is centralized and reviewable under `docs/adr/`.
- Technical debt is tracked in GitHub issues instead of quiet inline excuses.
- Any future cleanup or new-migration audit follows `/delete-comment`.
