import Foundation

public enum BotMode: String, Codable, CaseIterable, Sendable {
    case pacer
    case chill
    case erratic
    case beast
}

public enum BotWeek {
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

    public static func decimalEncoding(of seed: UInt64) -> String {
        String(seed)
    }

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
