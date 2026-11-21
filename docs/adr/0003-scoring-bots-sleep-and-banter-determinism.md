# ADR-0003: Scoring Policies, Deterministic Bots, Sleep, and Banter

- **Status:** Accepted
- **Date:** 2026-11-21
- **Scope:** `Modules/CompetitionCore/`

## Context

Scoring, bot weeks, sleep points, and match banter must remain deterministic across devices, Swift toolchains, and historical replays while matching server wire rules where applicable.

## Decisions

### 1. Activity Scoring Policy Separation and Overflow Saturation
- `ActivityScore.swift`: `ActivityScoringPolicy.remoteWireV1` mirrors what the server scores for `healthcomp.activity-score.v1` (200% per ring cap, 600 points/day cap) for display only. Remote genesis and `remoteEvidence` remain on `.healthKitCompatibility`, while wire clamping happens separately in `RemoteScoringWireV1.quantizePercent`.
- `RemoteScoringWireV1.swift`: `quantizePercent` is the trusted client wire conversion and intentionally does not share local Apple/simulator calculator semantics. `unavailableReasons` is the single closed set shared across Core and app checks, matching the server's `submit_score_revision`.
- `ActivityScore.swift`: Unrepresentable ring percentages saturate numerically during division to prevent finite overflow without imposing an Apple per-ring cap (an overflow-sized ring already guarantees the 600-point daily cap).

### 2. Pinned PRNG (`SplitMix64`) and Pure-Swift `SHA256Digest`
- `SeededRandomNumberGenerator.swift`: `SplitMix64` (state initialized directly to `seed` without pre-mixing) and its rejection-sampling `next(upperBound:)` are pinned in-module rather than delegating to Swift's standard library so opponent generator v1–v4 replays never drift across toolchains.
- `SHA256Digest` is a pure-Swift SHA-256 implementation for deterministic integrity commitments (detecting accidental or untrusted local file tampering); it is not a MAC and does not establish provenance.

### 3. Deterministic Bot Weeks (`BotWeek`) and `OpponentPlan` Versions
- `BotModes.swift`:
  - `BotWeek.dailyTotals` is the practice (opponent plan v3) generator only. Group-match bot totals come from the server's `private.group_bot_week`, which is deliberately different; neither generator may be changed to match the other because doing so would alter already-stored weeks.
  - Totals and reveals are whole points in `0...600` (scoring elsewhere multiplies by 100 once for centipoints).
  - `UInt64` seeds travel on the wire as canonical decimal strings (`BotWeek.decimalEncoding(of:)`: `"0"` through `"18446744073709551615"`, no sign, no whitespace, no leading zeros)—never JSON numbers. Legacy stored opponent plans still encode seeds as JSON numbers.
  - `dailyTotals` runs a single `SplitMix64(seed: seed)` stream (no seed hashing, no schedule reads): Erratic draws three high days via partial Fisher-Yates over `[1...7]`; then ordinals 1..7 draw inclusive percents (Pacer `90...110`, Chill `75...90`, Beast `125...150`, Erratic high `130...160`, Erratic low `30...65`), rounded half away from zero `(baseline * percent + 50) / 100` and clamped to `0...600`.
  - `revealed` uses a separate curve schedule: Pacer linear, Chill late, Beast early; Erratic picks a curve per day from `SplitMix64(seed: (seed + dayOrdinal) mod 2^64)` (`0` late, `1` linear, `2` early). Each curve has 8 steps at progress `i * 10000 / 7` (`late: final * p^2 / 10^8`, `linear: final * p / 10^4`, `early: final * (20000*p - p^2) / 10^8`), holding flat between steps so the reveal is monotonic (`0` at 0, `finalPoints` at 10000).
- `OpponentPlan.swift`:
  - Generator versions: `v1` legacy checkpoint sampler (kept defined for all raw difficulty strings so case sweeps remain valid), `v2` v1 curves scaled to owner `baselineDailyPoints` (`45–60%`, `90–110%`, `110–130%`, capped at 600), `v3` `BotWeek` totals/reveals, `v4` Shadow preset sampling from a past rival's `OpponentShadowProfile`.
  - `baselineDailyPoints` is required by `.v2`/`.v3` and rejected by `.v1`/`.v4` (never persisted; the plan commits every day's points). `shadowProfile` is required by `.v4` and rejected by `.v1`–`.v3`.
  - Shadow anti-memorization rule: generated Shadow weeks must never reproduce any contiguous 7-day slice or exact weekday tuple from the rival's historical samples 100%.

### 4. Group Match Scoring and Banter Determinism
- `MatchScoring.swift`: `leaveCutoffs` records each departed seat's inclusive last banked day; leaving seals the bank so no later upload can fill a missing score (missing banked scores and post-leave days resolve to zero). `MatchScoreProjection` is live-only (finished matches use the server's frozen result), `teamShare` uses accepted week-to-date totals without rounding, and stable tie ordering is display-only—never a tie-breaker.
- `MatchBanter.swift`:
  - Produces at most one banter line per match day in strict priority order: team imbalance (lower team number wins if both doubles teams qualify; bots are never subjects; both humans on the team must have an accepted score today because templates name the partner) → far off lead (FFA only; last place is a human strictly > 400 points / 40,000 centipoints behind first; bot may be the named leader; ties break by ascending seat ID) → bot ahead (≥ 100 centipoints / 1 whole point ahead on week-to-date totals so gaps never render as 0; ties break by bot seat ID then human seat ID).
  - Selection hash is deterministic FNV-1a 64 over the match UUID's RFC 4122 bytes followed by the day ordinal byte—explicitly not `Swift.Hasher` (which is process-salted). Bit 0 selects phrasing (`hardCarry` vs `deadweight`); `(hash >> 1) % count` selects the template.
  - Rendering uses second person when the viewer is the subject, template-specific `namedViewer` wording for the named partner/leader (so viewers never see their own name), and third person for everyone else including bot seats.

### 5. Sleep Beta Scoring
- `SleepScore.swift`:
  - A night is worth up to 100 points (total daily max 700 with 600 ring points), weighted to mirror Apple's Sleep Score split—time asleep 50 (linear up to 8 h), bedtime consistency 30 (30 within 30 min of usual bedtime, 0 at 2 h off; 30 when fewer than 3 prior nights exist out of the 13-night history window), interruptions 20 (20 at ≤ 10 min awake after sleep onset, 0 at ≥ 70 min)—using HealthComp's own curves since Apple does not publish theirs. Only basis points leave the phone.
  - Trusted sources are restricted to `SleepSource` (`watch`, `oura`); third-party apps and hand-entered sleep are ignored. One source counts per night to prevent double-counting when wearing both devices (`automatic` prefers Oura on nights it has data, else Apple Watch).
  - Overlapping asleep intervals are unioned once. Asleep spans less than 2 hours apart merge into sessions; the session with the most total asleep time is the main session, so afternoon naps contribute to duration without distorting bedtime onset or wake-ups.
