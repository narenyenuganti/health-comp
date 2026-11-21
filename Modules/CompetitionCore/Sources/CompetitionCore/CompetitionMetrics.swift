import Foundation

public enum CompetitionMetric: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case move
    case exercise
    case stand
    case sleep

    public var id: Self { self }

    public var title: String {
        switch self {
        case .move: "Move"
        case .exercise: "Exercise"
        case .stand: "Stand"
        case .sleep: "Sleep"
        }
    }

    public var shortTitle: String {
        switch self {
        case .move: "MOVE"
        case .exercise: "EXERCISE"
        case .stand: "STAND"
        case .sleep: "SLEEP"
        }
    }

    public var maximumDailyPoints: Double {
        self == .sleep ? 100 : 200
    }

    public var maximumDailyCentipoints: Int {
        self == .sleep ? 10_000 : 20_000
    }

    public var isActivityRing: Bool {
        self != .sleep
    }

    public var isBeta: Bool {
        self == .sleep
    }
}

public struct CompetitionMetrics: OptionSet, Codable, Hashable, Sendable {
    private static let validMask = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3)

    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue & Self.validMask
    }

    public static let move = Self(rawValue: 1 << 0)
    public static let exercise = Self(rawValue: 1 << 1)
    public static let stand = Self(rawValue: 1 << 2)
    public static let sleep = Self(rawValue: 1 << 3)

    public static let threeRings: Self = [.move, .exercise, .stand]
    public static let all: Self = [.move, .exercise, .stand, .sleep]

    public init(move: Bool, exercise: Bool, stand: Bool, sleep: Bool) {
        var mask: CompetitionMetrics = []
        if move { mask.insert(.move) }
        if exercise { mask.insert(.exercise) }
        if stand { mask.insert(.stand) }
        if sleep { mask.insert(.sleep) }
        self = mask.isEmpty ? .threeRings : mask
    }

    public init?(validatingMove move: Bool, exercise: Bool, stand: Bool, sleep: Bool) {
        var mask: CompetitionMetrics = []
        if move { mask.insert(.move) }
        if exercise { mask.insert(.exercise) }
        if stand { mask.insert(.stand) }
        if sleep { mask.insert(.sleep) }
        guard !mask.isEmpty else { return nil }
        self = mask
    }

    public init(_ metric: CompetitionMetric) {
        switch metric {
        case .move: self = .move
        case .exercise: self = .exercise
        case .stand: self = .stand
        case .sleep: self = .sleep
        }
    }

    public var orderedMetrics: [CompetitionMetric] {
        CompetitionMetric.allCases.filter { contains($0) }
    }

    public var activeActivityIndices: [Int] {
        var indices: [Int] = []
        if contains(.move) { indices.append(0) }
        if contains(.exercise) { indices.append(1) }
        if contains(.stand) { indices.append(2) }
        return indices
    }

    public var count: Int {
        orderedMetrics.count
    }

    public var includesActivityRings: Bool {
        !intersection(.threeRings).isEmpty
    }

    public var includesSleep: Bool {
        contains(.sleep)
    }

    public var isDefaultRings: Bool {
        self == .threeRings
    }

    public var activityDailyMaximum: Double {
        Double(activeActivityIndices.count) * 200
    }

    public var sleepDailyMaximum: Double {
        contains(.sleep) ? 100 : 0
    }

    public var dailyMaximum: Double {
        activityDailyMaximum + sleepDailyMaximum
    }

    public var dailyMaximumCentipoints: Int {
        Int(dailyMaximum * 100)
    }

    public func contains(_ metric: CompetitionMetric) -> Bool {
        contains(Self(metric))
    }

    public func toggling(_ metric: CompetitionMetric) -> CompetitionMetrics? {
        let bit = Self(metric)
        if contains(bit) {
            let next = subtracting(bit)
            return next.isEmpty ? nil : next
        }
        return union(bit)
    }

    public func scoreActivity(
        movePercentage: Double,
        exercisePercentage: Double,
        standOrRollPercentage: Double,
        perRingCap: Double? = 200
    ) -> Double {
        let raw = [movePercentage, exercisePercentage, standOrRollPercentage]
        var sum = 0.0
        for index in activeActivityIndices {
            let value = max(0, raw[index])
            sum += perRingCap.map { min($0, value) } ?? value
        }
        return min(activityDailyMaximum, sum)
    }

    public func scoreActivityCentipoints(ringCentipoints: [Int]) -> Int {
        guard ringCentipoints.count == 3 else { return 0 }
        let sum = activeActivityIndices.reduce(0) { acc, index in
            acc + min(20_000, max(0, ringCentipoints[index]))
        }
        return min(Int(activityDailyMaximum * 100), sum)
    }

    public func scaleBotActivityPoints(_ rawPoints: Int) -> Int {
        let activeCount = activeActivityIndices.count
        guard activeCount > 0 else { return 0 }
        if activeCount == 3 { return min(600, max(0, rawPoints)) }
        let cap = activeCount * 200
        return min(cap, max(0, (max(0, rawPoints) * activeCount + 1) / 3))
    }

    public func scaleBotActivityCentipoints(_ rawCentipoints: Int) -> Int {
        let activeCount = activeActivityIndices.count
        guard activeCount > 0 else { return 0 }
        if activeCount == 3 { return min(60_000, max(0, rawCentipoints)) }
        let cap = activeCount * 20_000
        return min(cap, max(0, (max(0, rawCentipoints) * activeCount + 1) / 3))
    }

    public static func botSleepWeekBasisPoints(
        seed: UInt64,
        mode: BotMode,
        baselineBasisPoints: Int = 7_500
    ) -> [Int] {
        let clampedBaseline = min(10_000, max(2_000, baselineBasisPoints))
        var generator = SplitMix64(seed: seed ^ 0x51EE_9000_0000_0001)
        let highNights: Set<Int>
        if mode == .erratic {
            var slots = [1, 2, 3, 4, 5, 6, 7]
            for index in 0..<3 {
                let swapIndex = index + Int(generator.next(upperBound: UInt64(7 - index)))
                slots.swapAt(index, swapIndex)
            }
            highNights = Set(slots.prefix(3))
        } else {
            highNights = []
        }
        return (1...7).map { ordinal in
            let bounds: ClosedRange<Int> = switch mode {
            case .pacer: 90...110
            case .chill: 75...90
            case .beast: 112...132
            case .erratic: highNights.contains(ordinal) ? 115...135 : 45...75
            }
            let span = bounds.upperBound - bounds.lowerBound + 1
            let percent = bounds.lowerBound + Int(generator.next(upperBound: UInt64(span)))
            let scaled = (clampedBaseline * percent + 50) / 100
            return min(SleepScore.maximumBasisPoints, max(0, scaled))
        }
    }

    public static func groupBotSleepBasisPoints(
        competitionID: UUID,
        seatID: UUID,
        mode: BotMode
    ) -> [Int] {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func mix(_ uuid: UUID) {
            withUnsafeBytes(of: uuid.uuid) { bytes in
                for byte in bytes {
                    hash ^= UInt64(byte)
                    hash &*= 1_099_511_628_211
                }
            }
        }
        mix(competitionID)
        mix(seatID)
        return botSleepWeekBasisPoints(seed: hash, mode: mode, baselineBasisPoints: 7_800)
    }
}
