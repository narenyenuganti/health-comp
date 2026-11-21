# ADR-0006: CI Verification and Release Safety Scripts

- **Status:** Accepted
- **Date:** 2026-11-21
- **Scope:** `scripts/`

## Context

The repository relies on lightweight shell, Python, SQL, and standalone Swift verification scripts under `scripts/` to enforce security, privacy, accessibility, and release-compatibility boundaries in CI without heavy third-party tooling.

## Decisions

### 1. Released-API Compatibility Snapshot (`scripts/save-released-api.sh`)
- Captures every `public` SQL function executable by `authenticated` or `anon` into `supabase/tests/900_released_api.test.sql` so any later migration that breaks an installed app build fails Backend CI.
- Refuses to generate unless `supabase_migrations.schema_migrations` matches the exact checked-in `supabase/migrations/*.sql` list, ensuring snapshots come only from a clean local `supabase db reset`.
- Functions remain listed until explicitly deleted (with the `retire-released-api` PR label once no installed build calls them). The generated pgTAP assertion also checks that exactly one overload matches each released function's parameter-name set, because PostgREST resolves overloads by argument names alone and fails with `PGRST203` when two overloads match.

### 2. Motion Token Guard (`scripts/verify-motion-tokens.sh`)
- Rejects direct `.animation(Motion.settle|grow)` and `withAnimation(Motion.settle|grow)` calls outside `Motion.swift`; callers must route through `View.moving(_:value:)` so iOS Reduce Motion preferences are always respected.

### 3. Watch Bundle Embed Verification (`scripts/verify-watch-embed.sh`)
- Validates the embedded `HealthCompWatch.app` and `HealthCompWatchWidgets.appex` companion bundle identifier, identifier prefix, and marketing/build versions inside a built `HealthComp.app`, catching mismatches that Xcode's local embed check misses until App Store Connect upload.

### 4. Secret Scanner PEM Boundaries (`scripts/verify-no-secrets.sh`)
- Matches complete PEM header lines (including CRLF and indented YAML block scalars) and JSON/env-escaped `\n` PEM strings, avoiding false positives on source code that merely references a PEM-validation regex.

### 5. Static Site & Cloudflare Pages Smoke Test (`scripts/verify-website.sh`)
- Verifies that unknown paths return HTTP `404` (`web/404.html` is required because Cloudflare Pages otherwise serves `index.html` with `200` for every unknown path), invite/challenge routes return `200` with private-link headers, and `/api/waitlist` rejects invalid email addresses with `400` before calling Resend.
- Always uses synthetic all-`A` tokens/codes; never pass real invite or challenge links.

### 6. Privacy-Safe Diagnostic & Auth Contract Harnesses
- `scripts/test-competition-refresh-diagnostics.sh`, `scripts/test-healthkit-delivery-diagnostics.sh`: Support `HEALTHCOMP_DIAGNOSTICS_SIMULATOR` (booted simulator UDID) for local non-admin accounts (such as the Mac mini `agent` account) because the macOS host log store is admin-only; CI leaves it unset to run on the host.
- `scripts/tests/competition-refresh-diagnostics.swift`, `scripts/tests/healthkit-delivery-diagnostics.swift`, `scripts/tests/staging-apple-web-contract.swift`: Emit static failure labels only—never print unexpected log content, system error descriptions, configuration values, or callback URLs.
- `scripts/tests/apple-web-session-lifetime.swift`: Verifies cancellation is observed even when a callback fires synchronously before the cancellation handler's `MainActor` task has a chance to run.

### 7. Staging Adversarial Rollback Script (`scripts/staging-adversarial-rollback.sql`)
- Runs only against an approved staging database as a privileged session using fixed synthetic identities, fail-closed assertions, and a single mutating transaction ending in `ROLLBACK` before switching to read-only mode for residue verification and a privacy-safe receipt (no identifiers, tokens, digests, or health data).
- Uses an internal `ZX001` savepoint exception to discard fresh RPC rows prior to fixed-fixture isolation checks, uses `pg_catalog.statement_timestamp()` to test exact expiry equality boundaries without sleeps, and temporarily shifts `start_day` within the rolled-back transaction to test post-week replay.
