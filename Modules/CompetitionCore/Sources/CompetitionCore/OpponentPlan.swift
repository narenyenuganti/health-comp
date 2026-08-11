import Foundation

public struct OpponentGeneratorVersion: Codable, Hashable, Sendable {
    public static let v1 = Self(rawValue: 1)

    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public enum OpponentDifficulty: String, Codable, CaseIterable, Sendable {
    case relaxed
    case balanced
    case challenging
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
    public let commitmentHex: String

    public var canonicalBytes: Data {
        Self.canonicalBytes(
            schemaVersion: schemaVersion,
            generatorVersion: generatorVersion,
            seed: seed,
            difficulty: difficulty,
            schedule: schedule,
            days: days
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

    /// Verifies that complete tally content is bound to this exact immutable
    /// plan, including its commitment identity and every per-day final point.
    /// Totals alone are deliberately insufficient.
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
        days: [OpponentDayPlan]
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

        self.schemaVersion = schemaVersion
        self.generatorVersion = generatorVersion
        self.seed = seed
        self.difficulty = difficulty
        self.schedule = schedule
        self.days = days
        self.commitmentHex = SHA256Digest.hexDigest(
            Self.canonicalBytes(
                schemaVersion: schemaVersion,
                generatorVersion: generatorVersion,
                seed: seed,
                difficulty: difficulty,
                schedule: schedule,
                days: days
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
                days: days
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
        try container.encode(commitmentHex, forKey: .commitmentHex)
    }

    private static func canonicalBytes(
        schemaVersion: UInt32,
        generatorVersion: OpponentGeneratorVersion,
        seed: UInt64,
        difficulty: OpponentDifficulty,
        schedule: CompetitionSchedule,
        days: [OpponentDayPlan]
    ) -> Data {
        // Commitment format v1, in order: domain, schema, generator, seed,
        // difficulty, explicit schedule, then all days/checkpoints. Every
        // integer is fixed-width big-endian, strings are UInt32-length-prefixed,
        // and the commitment itself is deliberately excluded.
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
        return encoder.data
    }
}

public struct OpponentPlanGenerationRequest: Codable, Equatable, Sendable {
    public let seed: UInt64
    public let generatorVersion: OpponentGeneratorVersion
    public let difficulty: OpponentDifficulty

    public init(
        seed: UInt64,
        generatorVersion: OpponentGeneratorVersion,
        difficulty: OpponentDifficulty
    ) {
        self.seed = seed
        self.generatorVersion = generatorVersion
        self.difficulty = difficulty
    }
}

public enum OpponentPlanGenerator {
    public static func generate(
        seed: UInt64,
        generatorVersion: OpponentGeneratorVersion,
        difficulty: OpponentDifficulty,
        schedule: CompetitionSchedule
    ) throws -> OpponentPlan {
        guard generatorVersion == .v1 else {
            throw OpponentPlanError.unsupportedGeneratorVersion(
                generatorVersion.rawValue
            )
        }
        guard (try? schedule.calendar.sevenDayWindow(
            startingOn: schedule.startDay
        ))?.count == 7 else {
            throw OpponentPlanError.invalidSchedule
        }

        let policy = difficulty.versionOnePolicy
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
        }
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
