import Foundation

public struct OpponentGeneratorVersion: Codable, Hashable, Sendable {
    public static let v1 = Self(rawValue: 1)
    public static let v2 = Self(rawValue: 2)
    public static let v3 = Self(rawValue: 3)
    public static let v4 = Self(rawValue: 4)

    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public enum OpponentDifficulty: String, Codable, CaseIterable, Sendable {
    case relaxed
    case balanced
    case challenging
    case pacer
    case chill
    case erratic
    case beast
    case shadow
}

public enum OpponentPlanError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(UInt32)
    case unsupportedGeneratorVersion(UInt32)
    case invalidSchedule
    case invalidCheckpointProgress(Int)
    case invalidCheckpointPoints(Int)
    case invalidDayOrdinal(Int)
    case invalidFinalPoints(Int)
    case invalidCheckpointSequence
    case invalidDaySet
    case invalidDifficultyPolicy(dayOrdinal: Int)
    case invalidCommitment
    case invalidRevealDayOrdinal(Int)
    case invalidRevealProgress(Int)
    case invalidBaseline(Int?)
    case insufficientRivalHistory(Int)
}

public struct OpponentRivalSample: Codable, Equatable, Sendable {
    public let weekday: Int
    public let points: Int

    public init(weekday: Int, points: Int) throws {
        guard (1...7).contains(weekday) else {
            throw OpponentPlanError.invalidDayOrdinal(weekday)
        }
        guard (0...600).contains(points) else {
            throw OpponentPlanError.invalidFinalPoints(points)
        }
        self.weekday = weekday
        self.points = points
    }
}

public struct OpponentShadowProfile: Codable, Equatable, Sendable {
    public static let minimumSampleCount = 3

    public let samples: [OpponentRivalSample]
    public let opponentName: String?
    public let mean: Int
    public let spread: Int
    public let minPoints: Int
    public let maxPoints: Int

    public var bounds: ClosedRange<Int> {
        if maxPoints - minPoints >= 36 {
            return minPoints...maxPoints
        }
        let low = max(0, min(minPoints, mean - 24))
        let high = min(600, max(maxPoints, mean + 24))
        return low...high
    }

    public init(samples: [OpponentRivalSample], opponentName: String? = nil) throws {
        guard samples.count >= Self.minimumSampleCount else {
            throw OpponentPlanError.insufficientRivalHistory(samples.count)
        }
        self.samples = samples
        let trimmed = opponentName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.opponentName = (trimmed?.isEmpty == false) ? trimmed : nil

        let n = samples.count
        let sum = samples.reduce(0) { $0 + $1.points }
        let mu = (sum + n / 2) / n
        self.mean = min(600, max(0, mu))

        let sqSum = samples.reduce(0) { acc, sample in
            let diff = sample.points - mu
            return acc + diff * diff
        }
        let rawSigma = Self.integerSqrt(sqSum / n)
        let floorSigma = max(20, (mu * 7 + 50) / 100)
        self.spread = min(160, max(floorSigma, rawSigma))
        self.minPoints = samples.map(\.points).min() ?? mu
        self.maxPoints = samples.map(\.points).max() ?? mu
    }

    public func weekdayTarget(for weekday: Int) -> (mean: Int, spread: Int) {
        let matching = samples.filter { $0.weekday == weekday }
        let count = matching.count
        guard count > 0 else { return (mean, spread) }

        let groupSum = matching.reduce(0) { $0 + $1.points }
        let groupMean = (groupSum + count / 2) / count
        let groupSq = matching.reduce(0) { acc, sample in
            let diff = sample.points - groupMean
            return acc + diff * diff
        }
        let groupSpread = max(16, Self.integerSqrt(groupSq / count))
        let denom = count + 1
        let blendedMean = (count * groupMean + mean + denom / 2) / denom
        let blendedSpread = max(16, (count * groupSpread + spread + denom / 2) / denom)
        return (blendedMean, blendedSpread)
    }

    public func weekdayBarHeights(maxHeight: Int = 28) -> [Int] {
        [2, 3, 4, 5, 6, 7, 1].map { weekday in
            let expected = weekdayTarget(for: weekday).mean
            let scaled = (expected * maxHeight + 300) / 600
            return min(maxHeight, max(6, scaled))
        }
    }

    private static func integerSqrt(_ value: Int) -> Int {
        guard value > 0 else { return 0 }
        var x = value
        var y = (x + 1) / 2
        while y < x {
            x = y
            y = (x + value / x) / 2
        }
        return x
    }
}

public struct OpponentCheckpoint: Codable, Equatable, Sendable {
    public let progressBasisPoints: Int
    public let cumulativePoints: Int

    public init(progressBasisPoints: Int, cumulativePoints: Int) throws {
        guard (0...10_000).contains(progressBasisPoints) else {
            throw OpponentPlanError.invalidCheckpointProgress(progressBasisPoints)
        }
        guard (0...600).contains(cumulativePoints) else {
            throw OpponentPlanError.invalidCheckpointPoints(cumulativePoints)
        }
        self.progressBasisPoints = progressBasisPoints
        self.cumulativePoints = cumulativePoints
    }

    private enum CodingKeys: String, CodingKey {
        case progressBasisPoints
        case cumulativePoints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                progressBasisPoints: container.decode(
                    Int.self,
                    forKey: .progressBasisPoints
                ),
                cumulativePoints: container.decode(
                    Int.self,
                    forKey: .cumulativePoints
                )
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .progressBasisPoints,
                in: container,
                debugDescription: "Invalid opponent checkpoint: \(error)"
            )
        }
    }
}

public struct OpponentDayPlan: Codable, Equatable, Sendable {
    public let ordinal: Int
    public let finalPoints: Int
    public let checkpoints: [OpponentCheckpoint]

    public init(
        ordinal: Int,
        finalPoints: Int,
        checkpoints: [OpponentCheckpoint]
    ) throws {
        guard (1...7).contains(ordinal) else {
            throw OpponentPlanError.invalidDayOrdinal(ordinal)
        }
        guard (0...600).contains(finalPoints) else {
            throw OpponentPlanError.invalidFinalPoints(finalPoints)
        }
        guard checkpoints.count >= 2,
              checkpoints.first?.progressBasisPoints == 0,
              checkpoints.first?.cumulativePoints == 0,
              checkpoints.last?.progressBasisPoints == 10_000,
              checkpoints.last?.cumulativePoints == finalPoints
        else {
            throw OpponentPlanError.invalidCheckpointSequence
        }
        for pair in zip(checkpoints, checkpoints.dropFirst()) {
            guard pair.0.progressBasisPoints < pair.1.progressBasisPoints,
                  pair.0.cumulativePoints <= pair.1.cumulativePoints
            else {
                throw OpponentPlanError.invalidCheckpointSequence
            }
        }

        self.ordinal = ordinal
        self.finalPoints = finalPoints
        self.checkpoints = checkpoints
    }

    private enum CodingKeys: String, CodingKey {
        case ordinal
        case finalPoints
        case checkpoints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                ordinal: container.decode(Int.self, forKey: .ordinal),
                finalPoints: container.decode(Int.self, forKey: .finalPoints),
                checkpoints: container.decode(
                    [OpponentCheckpoint].self,
                    forKey: .checkpoints
                )
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .checkpoints,
                in: container,
                debugDescription: "Invalid opponent day plan: \(error)"
            )
        }
    }
}

public struct OpponentFinalDayScore: Equatable, Sendable {
    public let ordinal: Int
    public let points: Int

    internal init(ordinal: Int, points: Int) {
        self.ordinal = ordinal
        self.points = points
    }
}

public struct OpponentFinalScoreWindow: Equatable, Sendable {
    public let days: [OpponentFinalDayScore]
    public let opponentPlanIdentity: String

    public var totalPoints: Int {
        days.reduce(0) { $0 + $1.points }
    }

    internal init(days: [OpponentFinalDayScore], opponentPlanIdentity: String) {
        self.days = days
        self.opponentPlanIdentity = opponentPlanIdentity
    }

    public func completeWindowContent(
        ownerWindow: LiveScoreWindowObservation
    ) throws -> CompleteWindowContent {
        let ownerOrdinals = ownerWindow.days.map(\.ordinal)
        let opponentOrdinals = days.map(\.ordinal)
        guard ownerOrdinals == Array(1...7),
              opponentOrdinals == Array(1...7)
        else {
            throw ScoreLedgerError.invalidOpponentDayOrdinals(
                Set(ownerOrdinals).symmetricDifference(Set(opponentOrdinals))
            )
        }

        return try CompleteWindowContent(
            days: zip(ownerWindow.days, days).map { ownerDay, opponentDay in
                WindowDayContent(
                    ordinal: ownerDay.ordinal,
                    userPoints: ownerDay.acceptedPoints,
                    opponentPoints: Double(opponentDay.points),
                    activityContentFingerprint:
                        ownerDay.activityContentFingerprint.rawValue
                )
            },
            opponentPlanVersion: opponentPlanIdentity
        )
    }
}

public struct OpponentPlan: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let generatorVersion: OpponentGeneratorVersion
    public let seed: UInt64
    public let difficulty: OpponentDifficulty
    public let schedule: CompetitionSchedule
    public let days: [OpponentDayPlan]
    public let opponentName: String?
    public let commitmentHex: String

    public var canonicalBytes: Data {
        Self.canonicalBytes(
            schemaVersion: schemaVersion,
            generatorVersion: generatorVersion,
            seed: seed,
            difficulty: difficulty,
            schedule: schedule,
            days: days,
            opponentName: opponentName
        )
    }

    public var contentIdentity: String {
        "opponent-plan:v\(schemaVersion):g\(generatorVersion.rawValue):sha256:\(commitmentHex)"
    }

    public var finalScoreWindow: OpponentFinalScoreWindow {
        OpponentFinalScoreWindow(
            days: days.map {
                OpponentFinalDayScore(ordinal: $0.ordinal, points: $0.finalPoints)
            },
            opponentPlanIdentity: contentIdentity
        )
    }

    public func matches(_ content: CompleteWindowContent) -> Bool {
        guard content.opponentPlanVersion == contentIdentity,
              content.days.map(\.ordinal) == Array(1...7),
              days.map(\.ordinal) == Array(1...7)
        else {
            return false
        }
        return zip(content.days, days).allSatisfy { contentDay, planDay in
            contentDay.ordinal == planDay.ordinal
                && contentDay.opponentPoints == Double(planDay.finalPoints)
        }
    }

    internal init(
        schemaVersion: UInt32 = Self.currentSchemaVersion,
        generatorVersion: OpponentGeneratorVersion,
        seed: UInt64,
        difficulty: OpponentDifficulty,
        schedule: CompetitionSchedule,
        days: [OpponentDayPlan],
        opponentName: String? = nil
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw OpponentPlanError.unsupportedSchemaVersion(schemaVersion)
        }
        guard (try? schedule.calendar.sevenDayWindow(
            startingOn: schedule.startDay
        ))?.count == 7 else {
            throw OpponentPlanError.invalidSchedule
        }
        guard days.map(\.ordinal) == Array(1...7) else {
            throw OpponentPlanError.invalidDaySet
        }
        if generatorVersion == .v1 {
            let policy = difficulty.versionOnePolicy
            for day in days {
                guard policy.finalPoints.contains(day.finalPoints),
                      policy.checkpointCount.contains(day.checkpoints.count)
                else {
                    throw OpponentPlanError.invalidDifficultyPolicy(
                        dayOrdinal: day.ordinal
                    )
                }
            }
        }

        let trimmedName = opponentName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = (trimmedName?.isEmpty == false) ? trimmedName : nil

        self.schemaVersion = schemaVersion
        self.generatorVersion = generatorVersion
        self.seed = seed
        self.difficulty = difficulty
        self.schedule = schedule
        self.days = days
        self.opponentName = normalizedName
        self.commitmentHex = SHA256Digest.hexDigest(
            Self.canonicalBytes(
                schemaVersion: schemaVersion,
                generatorVersion: generatorVersion,
                seed: seed,
                difficulty: difficulty,
                schedule: schedule,
                days: days,
                opponentName: normalizedName
            )
        )
    }

    public func revealedPoints(
        dayOrdinal: Int,
        progressBasisPoints: Int
    ) throws -> Int {
        guard let day = days.first(where: { $0.ordinal == dayOrdinal }) else {
            throw OpponentPlanError.invalidRevealDayOrdinal(dayOrdinal)
        }
        guard (0...10_000).contains(progressBasisPoints) else {
            throw OpponentPlanError.invalidRevealProgress(progressBasisPoints)
        }
        return day.checkpoints.last {
            $0.progressBasisPoints <= progressBasisPoints
        }?.cumulativePoints ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generatorVersion
        case seed
        case difficulty
        case schedule
        case days
        case opponentName
        case commitmentHex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(UInt32.self, forKey: .schemaVersion)
        let generatorVersion = try container.decode(
            OpponentGeneratorVersion.self,
            forKey: .generatorVersion
        )
        let seed = try container.decode(UInt64.self, forKey: .seed)
        let difficulty = try container.decode(
            OpponentDifficulty.self,
            forKey: .difficulty
        )
        let schedule = try container.decode(
            CompetitionSchedule.self,
            forKey: .schedule
        )
        let days = try container.decode([OpponentDayPlan].self, forKey: .days)
        let opponentName = try container.decodeIfPresent(String.self, forKey: .opponentName)
        let persistedCommitment = try container.decode(
            String.self,
            forKey: .commitmentHex
        )

        guard persistedCommitment.count == 64,
              persistedCommitment.allSatisfy({
                  "0123456789abcdef".contains($0)
              })
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .commitmentHex,
                in: container,
                debugDescription: "Opponent plan commitment must be lowercase SHA-256 hex"
            )
        }

        let validated: Self
        do {
            validated = try Self(
                schemaVersion: schemaVersion,
                generatorVersion: generatorVersion,
                seed: seed,
                difficulty: difficulty,
                schedule: schedule,
                days: days,
                opponentName: opponentName
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .days,
                in: container,
                debugDescription: "Invalid opponent plan: \(error)"
            )
        }
        guard validated.commitmentHex == persistedCommitment else {
            throw DecodingError.dataCorruptedError(
                forKey: .commitmentHex,
                in: container,
                debugDescription: "Opponent plan commitment does not match content"
            )
        }
        self = validated
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generatorVersion, forKey: .generatorVersion)
        try container.encode(seed, forKey: .seed)
        try container.encode(difficulty, forKey: .difficulty)
        try container.encode(schedule, forKey: .schedule)
        try container.encode(days, forKey: .days)
        try container.encodeIfPresent(opponentName, forKey: .opponentName)
        try container.encode(commitmentHex, forKey: .commitmentHex)
    }

    private static func canonicalBytes(
        schemaVersion: UInt32,
        generatorVersion: OpponentGeneratorVersion,
        seed: UInt64,
        difficulty: OpponentDifficulty,
        schedule: CompetitionSchedule,
        days: [OpponentDayPlan],
        opponentName: String? = nil
    ) -> Data {
        var encoder = CanonicalBinaryEncoder()
        encoder.append(string: "healthcomp.opponent-plan")
        encoder.append(schemaVersion)
        encoder.append(generatorVersion.rawValue)
        encoder.append(seed)
        encoder.append(string: difficulty.rawValue)
        encoder.append(schedule: schedule)
        encoder.append(UInt8(days.count))
        for day in days {
            encoder.append(UInt8(day.ordinal))
            encoder.append(UInt16(day.finalPoints))
            encoder.append(UInt16(day.checkpoints.count))
            for checkpoint in day.checkpoints {
                encoder.append(UInt16(checkpoint.progressBasisPoints))
                encoder.append(UInt16(checkpoint.cumulativePoints))
            }
        }
        if let opponentName {
            encoder.append(string: opponentName)
        }
        return encoder.data
    }
}

public struct OpponentPlanGenerationRequest: Codable, Equatable, Sendable {
    public let seed: UInt64
    public let generatorVersion: OpponentGeneratorVersion
    public let difficulty: OpponentDifficulty
    public let baselineDailyPoints: Int?
    public let shadowProfile: OpponentShadowProfile?

    public init(
        seed: UInt64,
        generatorVersion: OpponentGeneratorVersion,
        difficulty: OpponentDifficulty,
        baselineDailyPoints: Int? = nil,
        shadowProfile: OpponentShadowProfile? = nil
    ) {
        self.seed = seed
        self.generatorVersion = generatorVersion
        self.difficulty = difficulty
        self.baselineDailyPoints = baselineDailyPoints
        self.shadowProfile = shadowProfile
    }
}

public enum OpponentPlanGenerator {
    public static func generate(
        seed: UInt64,
        generatorVersion: OpponentGeneratorVersion,
        difficulty: OpponentDifficulty,
        schedule: CompetitionSchedule,
        baselineDailyPoints: Int? = nil,
        shadowProfile: OpponentShadowProfile? = nil
    ) throws -> OpponentPlan {
        let policy: OpponentDifficultyV1Policy
        switch generatorVersion {
        case .v1:
            guard baselineDailyPoints == nil, shadowProfile == nil else {
                throw OpponentPlanError.invalidBaseline(baselineDailyPoints)
            }
            policy = difficulty.versionOnePolicy
        case .v2:
            guard shadowProfile == nil else {
                throw OpponentPlanError.invalidDifficultyPolicy(dayOrdinal: 1)
            }
            guard let baseline = baselineDailyPoints,
                  (100...600).contains(baseline)
            else {
                throw OpponentPlanError.invalidBaseline(baselineDailyPoints)
            }
            guard difficulty.botMode == nil && difficulty != .shadow else {
                throw OpponentPlanError.invalidDifficultyPolicy(dayOrdinal: 1)
            }
            policy = difficulty.versionTwoPolicy(baseline: baseline)
        case .v3:
            guard shadowProfile == nil else {
                throw OpponentPlanError.invalidDifficultyPolicy(dayOrdinal: 1)
            }
            return try botWeekPlan(
                seed: seed,
                difficulty: difficulty,
                schedule: schedule,
                baselineDailyPoints: baselineDailyPoints
            )
        case .v4:
            return try shadowWeekPlan(
                seed: seed,
                difficulty: difficulty,
                schedule: schedule,
                baselineDailyPoints: baselineDailyPoints,
                shadowProfile: shadowProfile
            )
        default:
            throw OpponentPlanError.unsupportedGeneratorVersion(
                generatorVersion.rawValue
            )
        }
        guard (try? schedule.calendar.sevenDayWindow(
            startingOn: schedule.startDay
        ))?.count == 7 else {
            throw OpponentPlanError.invalidSchedule
        }

        var days: [OpponentDayPlan] = []
        days.reserveCapacity(7)
        for ordinal in 1...7 {
            var random = SplitMix64(
                seed: streamSeed(
                    seed: seed,
                    generatorVersion: generatorVersion,
                    difficulty: difficulty,
                    schedule: schedule,
                    ordinal: ordinal
                )
            )
            let finalPoints = policy.finalPoints.lowerBound + Int(
                random.next(
                    upperBound: UInt64(policy.finalPoints.count)
                )
            )
            let checkpointCount = policy.checkpointCount.lowerBound + Int(
                random.next(
                    upperBound: UInt64(policy.checkpointCount.count)
                )
            )
            var checkpoints: [OpponentCheckpoint] = [
                try OpponentCheckpoint(
                    progressBasisPoints: 0,
                    cumulativePoints: 0
                ),
            ]
            checkpoints.reserveCapacity(checkpointCount)
            for index in 1..<(checkpointCount - 1) {
                let spacing = 10_000 / (checkpointCount - 1)
                let jitterLimit = min(250, max(1, spacing / 5))
                let jitter = Int(
                    random.next(upperBound: UInt64((jitterLimit * 2) + 1))
                ) - jitterLimit
                let progress = (index * 10_000 / (checkpointCount - 1)) + jitter
                checkpoints.append(
                    try OpponentCheckpoint(
                        progressBasisPoints: progress,
                        cumulativePoints: policy.points(
                            finalPoints: finalPoints,
                            progressBasisPoints: progress
                        )
                    )
                )
            }
            checkpoints.append(
                try OpponentCheckpoint(
                    progressBasisPoints: 10_000,
                    cumulativePoints: finalPoints
                )
            )
            days.append(
                try OpponentDayPlan(
                    ordinal: ordinal,
                    finalPoints: finalPoints,
                    checkpoints: checkpoints
                )
            )
        }

        return try OpponentPlan(
            generatorVersion: generatorVersion,
            seed: seed,
            difficulty: difficulty,
            schedule: schedule,
            days: days
        )
    }

    private static func botWeekPlan(
        seed: UInt64,
        difficulty: OpponentDifficulty,
        schedule: CompetitionSchedule,
        baselineDailyPoints: Int?
    ) throws -> OpponentPlan {
        guard let mode = difficulty.botMode else {
            throw OpponentPlanError.invalidDifficultyPolicy(dayOrdinal: 1)
        }
        guard let baseline = baselineDailyPoints,
              (100...600).contains(baseline)
        else {
            throw OpponentPlanError.invalidBaseline(baselineDailyPoints)
        }
        guard (try? schedule.calendar.sevenDayWindow(
            startingOn: schedule.startDay
        ))?.count == 7 else {
            throw OpponentPlanError.invalidSchedule
        }

        let totals = BotWeek.dailyTotals(
            seed: seed,
            mode: mode,
            baselineDailyPoints: baseline
        )
        var days: [OpponentDayPlan] = []
        days.reserveCapacity(7)
        for (offset, finalPoints) in totals.enumerated() {
            let ordinal = offset + 1
            let checkpoints = try BotWeek.revealSteps(
                seed: seed,
                mode: mode,
                dayOrdinal: ordinal,
                finalPoints: finalPoints
            ).map { step in
                try OpponentCheckpoint(
                    progressBasisPoints: step.progressBasisPoints,
                    cumulativePoints: step.cumulativePoints
                )
            }
            days.append(
                try OpponentDayPlan(
                    ordinal: ordinal,
                    finalPoints: finalPoints,
                    checkpoints: checkpoints
                )
            )
        }
        return try OpponentPlan(
            generatorVersion: .v3,
            seed: seed,
            difficulty: difficulty,
            schedule: schedule,
            days: days
        )
    }

    private static func shadowWeekPlan(
        seed: UInt64,
        difficulty: OpponentDifficulty,
        schedule: CompetitionSchedule,
        baselineDailyPoints: Int?,
        shadowProfile: OpponentShadowProfile?
    ) throws -> OpponentPlan {
        guard difficulty == .shadow else {
            throw OpponentPlanError.invalidDifficultyPolicy(dayOrdinal: 1)
        }
        guard baselineDailyPoints == nil else {
            throw OpponentPlanError.invalidBaseline(baselineDailyPoints)
        }
        guard let profile = shadowProfile else {
            throw OpponentPlanError.insufficientRivalHistory(0)
        }
        guard let windowDays = try? schedule.calendar.sevenDayWindow(
            startingOn: schedule.startDay
        ), windowDays.count == 7 else {
            throw OpponentPlanError.invalidSchedule
        }

        let bounds = profile.bounds
        let weekdays = windowDays.map {
            gregorianWeekday(year: $0.year, month: $0.month, day: $0.day)
        }
        var rng = SplitMix64(seed: seed)
        let driftSpan = max(1, profile.spread / 3)
        let weekDrift = Int(rng.next(upperBound: UInt64(driftSpan * 2 + 1))) - driftSpan

        var totals: [Int] = []
        totals.reserveCapacity(7)
        for weekday in weekdays {
            let target = profile.weekdayTarget(for: weekday)
            let u1 = Int(rng.next(upperBound: 2_001)) - 1_000
            let u2 = Int(rng.next(upperBound: 2_001)) - 1_000
            let u3 = Int(rng.next(upperBound: 2_001)) - 1_000
            let bell = (u1 + u2 + u3) / 2
            let raw = target.mean + (weekDrift / 2) + (bell * target.spread) / 600
            totals.append(min(bounds.upperBound, max(bounds.lowerBound, raw)))
        }

        let samplePoints = profile.samples.map(\.points)
        var forbiddenSlices: [[Int]] = []
        if samplePoints.count >= 7 {
            for start in 0...(samplePoints.count - 7) {
                forbiddenSlices.append(Array(samplePoints[start..<(start + 7)]))
            }
        }
        let weekdayLatest = weekdays.map { w in
            profile.samples.last(where: { $0.weekday == w })?.points ?? -1
        }
        if !weekdayLatest.contains(-1) {
            forbiddenSlices.append(weekdayLatest)
        }
        if forbiddenSlices.contains(totals) || (Set(totals).count < 2 && bounds.count >= 20) {
            for idx in [0, 3] {
                let step = min(13, max(4, bounds.count / 4))
                if totals[idx] + step <= bounds.upperBound {
                    totals[idx] += step
                } else if totals[idx] - step >= bounds.lowerBound {
                    totals[idx] -= step
                }
            }
        }

        var days: [OpponentDayPlan] = []
        days.reserveCapacity(7)
        for (offset, finalPoints) in totals.enumerated() {
            let ordinal = offset + 1
            let checkpoints = try shadowCheckpoints(
                seed: seed,
                ordinal: ordinal,
                finalPoints: finalPoints
            )
            days.append(
                try OpponentDayPlan(
                    ordinal: ordinal,
                    finalPoints: finalPoints,
                    checkpoints: checkpoints
                )
            )
        }
        return try OpponentPlan(
            generatorVersion: .v4,
            seed: seed,
            difficulty: .shadow,
            schedule: schedule,
            days: days,
            opponentName: profile.opponentName
        )
    }

    private static func shadowCheckpoints(
        seed: UInt64,
        ordinal: Int,
        finalPoints: Int
    ) throws -> [OpponentCheckpoint] {
        var dayRng = SplitMix64(seed: seed &+ (UInt64(ordinal) &* 0x9E3779B97F4A7C15))
        let workoutSlot = 2 + Int(dayRng.next(upperBound: 5))
        let workoutPermille = 350 + Int(dayRng.next(upperBound: 251))
        let steadyPermille = 1_000 - workoutPermille

        var checkpoints: [OpponentCheckpoint] = []
        checkpoints.reserveCapacity(8)
        var previous = 0
        for step in 0...7 {
            let progress = step * 10_000 / 7
            let cumulative: Int
            if step == 0 {
                cumulative = 0
            } else if step == 7 {
                cumulative = finalPoints
            } else {
                let steady = (finalPoints * steadyPermille * step) / (1_000 * 7)
                let burstFull = (finalPoints * workoutPermille) / 1_000
                let burst: Int
                if step < workoutSlot - 1 {
                    burst = 0
                } else if step == workoutSlot - 1 {
                    burst = burstFull / 3
                } else {
                    burst = burstFull
                }
                cumulative = min(finalPoints, max(previous, steady + burst))
            }
            previous = cumulative
            checkpoints.append(
                try OpponentCheckpoint(
                    progressBasisPoints: progress,
                    cumulativePoints: cumulative
                )
            )
        }
        return checkpoints
    }

    private static func gregorianWeekday(year y0: Int, month m: Int, day d: Int) -> Int {
        let offsets = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
        let y = m < 3 ? y0 - 1 : y0
        let zeroBased = (y + y / 4 - y / 100 + y / 400 + offsets[m - 1] + d) % 7
        return ((zeroBased + 7) % 7) + 1
    }

    private static func streamSeed(
        seed: UInt64,
        generatorVersion: OpponentGeneratorVersion,
        difficulty: OpponentDifficulty,
        schedule: CompetitionSchedule,
        ordinal: Int
    ) -> UInt64 {
        var encoder = CanonicalBinaryEncoder()
        encoder.append(string: "healthcomp.opponent-plan.generator-stream")
        encoder.append(generatorVersion.rawValue)
        encoder.append(seed)
        encoder.append(string: difficulty.rawValue)
        encoder.append(schedule: schedule)
        encoder.append(UInt8(ordinal))
        let digest = SHA256Digest.digest(encoder.data)
        return digest.prefix(8).reduce(0) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
    }
}

private struct OpponentDifficultyV1Policy {
    enum Curve {
        case lateBuild
        case linear
        case earlyBuild
    }

    let finalPoints: ClosedRange<Int>
    let checkpointCount: ClosedRange<Int>
    let curve: Curve

    func points(finalPoints: Int, progressBasisPoints: Int) -> Int {
        switch curve {
        case .lateBuild:
            return finalPoints
                * progressBasisPoints
                * progressBasisPoints
                / 100_000_000
        case .linear:
            return finalPoints * progressBasisPoints / 10_000
        case .earlyBuild:
            return finalPoints
                * (
                    (2 * progressBasisPoints * 10_000)
                        - (progressBasisPoints * progressBasisPoints)
                )
                / 100_000_000
        }
    }
}

private extension OpponentDifficulty {
    var botMode: BotMode? {
        BotMode(rawValue: rawValue)
    }

    var versionOnePolicy: OpponentDifficultyV1Policy {
        switch self {
        case .relaxed:
            return OpponentDifficultyV1Policy(
                finalPoints: 180...360,
                checkpointCount: 6...8,
                curve: .lateBuild
            )
        case .balanced:
            return OpponentDifficultyV1Policy(
                finalPoints: 260...480,
                checkpointCount: 7...9,
                curve: .linear
            )
        case .challenging:
            return OpponentDifficultyV1Policy(
                finalPoints: 360...600,
                checkpointCount: 8...10,
                curve: .earlyBuild
            )
        case .chill:
            return OpponentDifficultyV1Policy(
                finalPoints: 180...360,
                checkpointCount: 6...8,
                curve: .lateBuild
            )
        case .pacer:
            return OpponentDifficultyV1Policy(
                finalPoints: 260...480,
                checkpointCount: 7...9,
                curve: .linear
            )
        case .beast:
            return OpponentDifficultyV1Policy(
                finalPoints: 360...600,
                checkpointCount: 8...10,
                curve: .earlyBuild
            )
        case .erratic:
            return OpponentDifficultyV1Policy(
                finalPoints: 30...600,
                checkpointCount: 6...10,
                curve: .linear
            )
        case .shadow:
            return OpponentDifficultyV1Policy(
                finalPoints: 200...520,
                checkpointCount: 7...9,
                curve: .linear
            )
        }
    }

    func versionTwoPolicy(baseline: Int) -> OpponentDifficultyV1Policy {
        let percents: ClosedRange<Int>
        switch self {
        case .relaxed: percents = 45...60
        case .balanced: percents = 90...110
        case .challenging: percents = 110...130
        case .pacer, .chill, .erratic, .beast, .shadow:
            preconditionFailure("Bot and shadow modes use generator v3/v4")
        }
        func scaled(_ percent: Int) -> Int {
            min(600, (baseline * percent + 50) / 100)
        }
        let versionOne = versionOnePolicy
        return OpponentDifficultyV1Policy(
            finalPoints: scaled(percents.lowerBound)...scaled(percents.upperBound),
            checkpointCount: versionOne.checkpointCount,
            curve: versionOne.curve
        )
    }
}

private struct CanonicalBinaryEncoder {
    private(set) var data = Data()

    mutating func append(_ value: UInt8) {
        data.append(value)
    }

    mutating func append(_ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func append(_ value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func append(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func append(_ value: Int32) {
        append(UInt32(bitPattern: value))
    }

    mutating func append(string: String) {
        let bytes = Data(string.utf8)
        append(UInt32(bytes.count))
        data.append(bytes)
    }

    mutating func append(schedule: CompetitionSchedule) {
        append(string: schedule.calendar.timeZoneIdentifier)
        append(Int32(schedule.startDay.era))
        append(Int32(schedule.startDay.year))
        append(Int32(schedule.startDay.month))
        append(Int32(schedule.startDay.day))
        append(string: schedule.startDay.timeZoneIdentifier)
    }
}
