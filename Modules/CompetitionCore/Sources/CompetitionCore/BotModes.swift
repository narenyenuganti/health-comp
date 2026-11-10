import Foundation

/// Whole-point bot weeks. Practice stores a week as opponent generator version 3.
/// A group match stores the seven totals on the server; the phone only calls `revealed`.
public enum BotMode: String, Codable, CaseIterable, Sendable {
    case pacer
    case chill
    case erratic
    case beast
}

/// Deterministic week and intraday reveal for one bot.
///
/// Totals and reveal are whole points in `0...600`. Scoring elsewhere multiplies
/// by 100 once to get centipoints. A `UInt64` seed is a decimal string on the
/// wire (`BotWeek.decimalEncoding(of:)`): no sign and no leading zeros, except
/// `"0"`. `UInt64.max` is `"18446744073709551615"`. Never a JSON number.
///
/// Both samplers use `SplitMix64` from this module. Its state starts equal to
/// the seed (it is not mixed first). `next` is:
///
/// ```
/// state = (state + 0x9E3779B97F4A7C15) mod 2^64
/// z = state
/// z = ((z xor (z >> 30)) * 0xBF58476D1CE4E5B9) mod 2^64
/// z = ((z xor (z >> 27)) * 0x94D049BB133111EB) mod 2^64
/// result = z xor (z >> 31)
/// ```
///
/// `next(upperBound: u)` with `u > 0` rejects modulo bias. All arithmetic below
/// is unsigned 64-bit, and `>>` is a logical shift:
///
/// ```
/// threshold = ((0 - u) mod 2^64) mod u
/// loop:
///     candidate = next()
///     if candidate >= threshold: return candidate mod u
/// ```
///
/// A port can check seed 0: the first `next` is `0xE220A8397B1DCDAF`, then
/// `next(upperBound: 1)` is 0 and the next `next(upperBound: 601)` is 157.
/// Products in the point formulas fit in a signed 64-bit integer. `/` truncates
/// toward zero. SQL should use the same `bigint` division.
///
/// `dailyTotals` builds one stream from `SplitMix64(seed: seed)` and draws in
/// this order. It does not hash the seed and it does not read the schedule.
///
/// 1. Erratic only: choose the three high days with a partial Fisher-Yates.
///    Start from `slots = [1, 2, 3, 4, 5, 6, 7]`. For `i` in `0, 1, 2`:
///    `j = i + next(upperBound: 7 - i)` and swap `slots[i]` with `slots[j]`.
///    The high ordinals are `slots[0]`, `slots[1]` and `slots[2]`. The other
///    four days are low. Pacer, Chill and Beast skip this step and make no draws.
/// 2. For day ordinals 1 through 7, in that order, draw one inclusive percent
///    and convert it. The closed percent ranges are Pacer `90...110`,
///    Chill `75...90`, Beast `125...150`, Erratic high `130...160`, Erratic low
///    `30...65`. `span = upper - lower + 1`,
///    `percent = lower + next(upperBound: span)`,
///    `points = min(600, max(0, (baseline * percent + 50) / 100))`.
///    `baseline` is an integer in `100...600`. The `+ 50` rounds half away from
///    zero, then the total is clamped to `0...600`.
///
/// `revealed` does not continue that stream. Pacer is linear, Chill builds late,
/// and Beast builds early. Erratic picks one of those three curves per day from
/// a fresh stream: `SplitMix64(seed: (seed + dayOrdinal) mod 2^64)`, then one
/// `next(upperBound: 3)`. `0` is late, `1` is linear, `2` is early. The day
/// ordinal is `1...7`. Pacer, Chill and Beast do not draw.
///
/// The curve is eight steps, index `i` from 0 through 7. Step progress is
/// `i * 10000 / 7` (so 0, 1428, 2857, 4285, 5714, 7142, 8571, 10000). Step
/// points, for progress `p` and the day's `finalPoints`, are:
///
/// - late: `finalPoints * p * p / 100000000`
/// - linear: `finalPoints * p / 10000`
/// - early: `finalPoints * (2 * p * 10000 - p * p) / 100000000`
///
/// `revealed(progress)` is the points of the last step whose progress is `<= progress`.
/// `revealed(0)` is 0 and `revealed(10000)` is `finalPoints`. Values between steps
/// stay flat, so the curve is monotonic.
public enum BotWeek {
    /// Seven whole-point totals, day 1 first.
    public static func dailyTotals(
        seed: UInt64,
        mode: BotMode,
        baselineDailyPoints: Int
    ) -> [Int] {
        precondition((100...600).contains(baselineDailyPoints))
        var generator = SplitMix64(seed: seed)
        let highDays = highDayOrdinals(mode: mode, generator: &generator)
        return (1...7).map { ordinal in
            let bounds = percentBounds(mode: mode, highDay: highDays.contains(ordinal))
            let span = bounds.upperBound - bounds.lowerBound + 1
            let percent = bounds.lowerBound + Int(generator.next(upperBound: UInt64(span)))
            let rounded = (baselineDailyPoints * percent + 50) / 100
            return min(600, max(0, rounded))
        }
    }

    /// Intraday whole points for one already-chosen daily total.
    public static func revealed(
        seed: UInt64,
        mode: BotMode,
        dayOrdinal: Int,
        finalPoints: Int,
        progressBasisPoints: Int
    ) -> Int {
        precondition((0...10_000).contains(progressBasisPoints))
        let steps = revealSteps(
            seed: seed,
            mode: mode,
            dayOrdinal: dayOrdinal,
            finalPoints: finalPoints
        )
        guard let points = steps.last(where: {
            $0.progressBasisPoints <= progressBasisPoints
        })?.cumulativePoints else {
            preconditionFailure("Reveal steps always include progress 0")
        }
        return points
    }

    /// Canonical decimal seed. `"0"` through `"18446744073709551615"`.
    public static func decimalEncoding(of seed: UInt64) -> String {
        String(seed)
    }

    /// Parses `decimalEncoding(of:)`. Rejects signs, whitespace, leading zeros and overflow.
    public static func seed(decimal: String) -> UInt64? {
        guard !decimal.isEmpty else { return nil }
        guard decimal.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        if decimal.count > 1, decimal.first == "0" { return nil }
        return UInt64(decimal)
    }

    static func revealSteps(
        seed: UInt64,
        mode: BotMode,
        dayOrdinal: Int,
        finalPoints: Int
    ) -> [BotRevealStep] {
        precondition((1...7).contains(dayOrdinal))
        precondition((0...600).contains(finalPoints))
        let curve = revealCurve(seed: seed, mode: mode, dayOrdinal: dayOrdinal)
        let steps = (0...7).map { index in
            let progress = index * 10_000 / 7
            return BotRevealStep(
                progressBasisPoints: progress,
                cumulativePoints: curvePoints(curve, finalPoints: finalPoints, progress: progress)
            )
        }
        precondition(steps.first?.cumulativePoints == 0)
        precondition(steps.last?.cumulativePoints == finalPoints)
        for pair in zip(steps, steps.dropFirst()) {
            precondition(pair.0.progressBasisPoints < pair.1.progressBasisPoints)
            precondition(pair.0.cumulativePoints <= pair.1.cumulativePoints)
        }
        return steps
    }

    private static func highDayOrdinals(
        mode: BotMode,
        generator: inout SplitMix64
    ) -> Set<Int> {
        guard mode == .erratic else { return [] }
        var slots = [1, 2, 3, 4, 5, 6, 7]
        for index in 0..<3 {
            let swapIndex = index + Int(generator.next(upperBound: UInt64(7 - index)))
            slots.swapAt(index, swapIndex)
        }
        return Set(slots.prefix(3))
    }

    private static func percentBounds(mode: BotMode, highDay: Bool) -> ClosedRange<Int> {
        switch mode {
        case .pacer:
            return 90...110
        case .chill:
            return 75...90
        case .beast:
            return 125...150
        case .erratic:
            return highDay ? 130...160 : 30...65
        }
    }

    private static func revealCurve(
        seed: UInt64,
        mode: BotMode,
        dayOrdinal: Int
    ) -> BotRevealCurve {
        switch mode {
        case .pacer:
            return .linear
        case .chill:
            return .late
        case .beast:
            return .early
        case .erratic:
            var generator = SplitMix64(seed: seed &+ UInt64(dayOrdinal))
            switch generator.next(upperBound: 3) {
            case 0: return .late
            case 1: return .linear
            default: return .early
            }
        }
    }

    private static func curvePoints(
        _ curve: BotRevealCurve,
        finalPoints: Int,
        progress: Int
    ) -> Int {
        switch curve {
        case .late:
            return finalPoints * progress * progress / 100_000_000
        case .linear:
            return finalPoints * progress / 10_000
        case .early:
            return finalPoints
                * ((2 * progress * 10_000) - (progress * progress))
                / 100_000_000
        }
    }
}

struct BotRevealStep: Equatable, Sendable {
    let progressBasisPoints: Int
    let cumulativePoints: Int
}

private enum BotRevealCurve {
    case late
    case linear
    case early
}
