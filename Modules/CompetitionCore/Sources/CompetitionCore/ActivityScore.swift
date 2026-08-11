import Foundation

public enum ScoreQuantizationStage: String, Codable, Equatable, Sendable {
    case perRing
    case aggregate
}

public enum ScoreQuantizationMode: String, Codable, Equatable, Sendable {
    case none
    case down
    case nearest
    case up
}

public struct ScoreQuantizationPolicy: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidIncrement
    }

    public static let exactAggregate = ScoreQuantizationPolicy(
        uncheckedStage: .aggregate,
        mode: .none,
        increment: 1
    )

    public let stage: ScoreQuantizationStage
    public let mode: ScoreQuantizationMode
    public let increment: Double

    public init(
        stage: ScoreQuantizationStage,
        mode: ScoreQuantizationMode,
        increment: Double
    ) throws {
        guard increment.isFinite, increment > 0 else {
            throw ValidationError.invalidIncrement
        }
        self.init(uncheckedStage: stage, mode: mode, increment: increment)
    }

    private init(
        uncheckedStage stage: ScoreQuantizationStage,
        mode: ScoreQuantizationMode,
        increment: Double
    ) {
        self.stage = stage
        self.mode = mode
        self.increment = increment == 0 ? 0.0 : increment
    }

    private enum CodingKeys: String, CodingKey {
        case stage
        case mode
        case increment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            stage: container.decode(
                ScoreQuantizationStage.self,
                forKey: .stage
            ),
            mode: container.decode(
                ScoreQuantizationMode.self,
                forKey: .mode
            ),
            increment: container.decode(Double.self, forKey: .increment)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stage, forKey: .stage)
        try container.encode(mode, forKey: .mode)
        try container.encode(increment, forKey: .increment)
    }
}

public enum PausedSummaryPolicy: String, Codable, Equatable, Sendable {
    case unavailable
    case scoreReportedValues
    case scoreReportedValuesWhenUnknown
}

public struct ActivityScoringPolicyIdentity: Codable, Hashable, Sendable {
    public let rawValue: String

    internal init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ActivityScoringPolicy: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidPerRingCap
    }

    public static let appleCompatibility = ActivityScoringPolicy(
        uncheckedQuantization: .exactAggregate,
        perRingCap: nil,
        pausedSummaryPolicy: .unavailable
    )

    public static let healthKitCompatibility = ActivityScoringPolicy(
        uncheckedQuantization: .exactAggregate,
        perRingCap: nil,
        pausedSummaryPolicy: .scoreReportedValuesWhenUnknown
    )

    public let quantization: ScoreQuantizationPolicy
    public let perRingCap: Double?
    public let pausedSummaryPolicy: PausedSummaryPolicy

    public var identity: ActivityScoringPolicyIdentity {
        let capToken: String
        if let perRingCap {
            let normalized = perRingCap == 0 ? 0.0 : perRingCap
            capToken = String(normalized.bitPattern, radix: 16)
        } else {
            capToken = "none"
        }
        return ActivityScoringPolicyIdentity(
            rawValue: [
                "activity-scoring-policy",
                "v1",
                quantization.stage.rawValue,
                quantization.mode.rawValue,
                String(quantization.increment.bitPattern, radix: 16),
                capToken,
                pausedSummaryPolicy.rawValue,
            ].joined(separator: ":")
        )
    }

    public init(
        quantization: ScoreQuantizationPolicy = .exactAggregate,
        perRingCap: Double? = nil,
        pausedSummaryPolicy: PausedSummaryPolicy = .unavailable
    ) throws {
        if let perRingCap,
           !perRingCap.isFinite || perRingCap <= 0 {
            throw ValidationError.invalidPerRingCap
        }
        self.init(
            uncheckedQuantization: quantization,
            perRingCap: perRingCap,
            pausedSummaryPolicy: pausedSummaryPolicy
        )
    }

    private init(
        uncheckedQuantization quantization: ScoreQuantizationPolicy,
        perRingCap: Double?,
        pausedSummaryPolicy: PausedSummaryPolicy
    ) {
        self.quantization = quantization
        self.perRingCap = perRingCap.map { $0 == 0 ? 0.0 : $0 }
        self.pausedSummaryPolicy = pausedSummaryPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case quantization
        case perRingCap
        case pausedSummaryPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            quantization: container.decode(
                ScoreQuantizationPolicy.self,
                forKey: .quantization
            ),
            perRingCap: container.decodeIfPresent(
                Double.self,
                forKey: .perRingCap
            ),
            pausedSummaryPolicy: container.decode(
                PausedSummaryPolicy.self,
                forKey: .pausedSummaryPolicy
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(quantization, forKey: .quantization)
        try container.encodeIfPresent(perRingCap, forKey: .perRingCap)
        try container.encode(pausedSummaryPolicy, forKey: .pausedSummaryPolicy)
    }
}

public enum ActivityScoreUnavailableReason: String, Codable, Hashable, Sendable {
    case missingMoveValue
    case missingMoveGoal
    case nonPositiveMoveGoal
    case missingExerciseValue
    case missingExerciseGoal
    case nonPositiveExerciseGoal
    case missingStandOrRollValue
    case missingStandOrRollGoal
    case nonPositiveStandOrRollGoal
    case summaryPaused
    case summaryPauseStateUnknown
    case invalidNumericCalculation
}

public struct ActivityScore: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidPercentage
        case invalidPoints
    }

    public static let maximumDailyPoints = 600.0
    public static let maximumCompetitionPoints = maximumDailyPoints * 7

    public let movePercentage: Double
    public let exercisePercentage: Double
    public let standOrRollPercentage: Double
    public let points: Double

    public init(
        movePercentage: Double,
        exercisePercentage: Double,
        standOrRollPercentage: Double,
        points: Double
    ) throws {
        let percentages = [
            movePercentage,
            exercisePercentage,
            standOrRollPercentage,
        ]
        guard percentages.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw ValidationError.invalidPercentage
        }
        guard points.isFinite,
              (0...Self.maximumDailyPoints).contains(points)
        else {
            throw ValidationError.invalidPoints
        }

        self.movePercentage = Self.normalized(movePercentage)
        self.exercisePercentage = Self.normalized(exercisePercentage)
        self.standOrRollPercentage = Self.normalized(standOrRollPercentage)
        self.points = Self.normalized(points)
    }

    private enum CodingKeys: String, CodingKey {
        case movePercentage
        case exercisePercentage
        case standOrRollPercentage
        case points
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            movePercentage: container.decode(
                Double.self,
                forKey: .movePercentage
            ),
            exercisePercentage: container.decode(
                Double.self,
                forKey: .exercisePercentage
            ),
            standOrRollPercentage: container.decode(
                Double.self,
                forKey: .standOrRollPercentage
            ),
            points: container.decode(Double.self, forKey: .points)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(movePercentage, forKey: .movePercentage)
        try container.encode(exercisePercentage, forKey: .exercisePercentage)
        try container.encode(
            standOrRollPercentage,
            forKey: .standOrRollPercentage
        )
        try container.encode(points, forKey: .points)
    }

    private static func normalized(_ number: Double) -> Double {
        number == 0 ? 0.0 : number
    }
}

public enum ActivityScoreResult: Codable, Equatable, Sendable {
    case available(ActivityScore)
    case unavailable(Set<ActivityScoreUnavailableReason>)

    public var availableScore: ActivityScore? {
        guard case let .available(score) = self else { return nil }
        return score
    }

    public var unavailableReasons: Set<ActivityScoreUnavailableReason> {
        guard case let .unavailable(reasons) = self else { return [] }
        return reasons
    }
}

public enum ActivityScoreCalculator {
    public static func score(
        _ snapshot: ActivitySnapshot,
        policy: ActivityScoringPolicy = .appleCompatibility
    ) -> ActivityScoreResult {
        switch policy.pausedSummaryPolicy {
        case .unavailable:
            switch snapshot.pauseState {
            case .running:
                break
            case .paused:
                return .unavailable([.summaryPaused])
            case .unknown:
                return .unavailable([.summaryPauseStateUnknown])
            }
        case .scoreReportedValues:
            break
        case .scoreReportedValuesWhenUnknown:
            if snapshot.pauseState == .paused {
                return .unavailable([.summaryPaused])
            }
        }

        let readings: [(
            ActivityRingReading,
            ActivityScoreUnavailableReason,
            ActivityScoreUnavailableReason,
            ActivityScoreUnavailableReason
        )] = [
            (
                snapshot.move,
                .missingMoveValue,
                .missingMoveGoal,
                .nonPositiveMoveGoal
            ),
            (
                snapshot.exercise,
                .missingExerciseValue,
                .missingExerciseGoal,
                .nonPositiveExerciseGoal
            ),
            (
                snapshot.standOrRoll,
                .missingStandOrRollValue,
                .missingStandOrRollGoal,
                .nonPositiveStandOrRollGoal
            ),
        ]

        var unavailableReasons: Set<ActivityScoreUnavailableReason> = []
        for (reading, missingValue, missingGoal, nonPositiveGoal) in readings {
            if reading.value == nil {
                unavailableReasons.insert(missingValue)
            }
            if let goal = reading.goal {
                if goal <= 0 {
                    unavailableReasons.insert(nonPositiveGoal)
                }
            } else {
                unavailableReasons.insert(missingGoal)
            }
        }
        guard unavailableReasons.isEmpty else {
            return .unavailable(unavailableReasons)
        }

        // An unrepresentable percentage is numerically saturated here. This
        // prevents finite division overflow without asserting an Apple per-ring
        // policy: an overflow-sized ring already guarantees the 600-point day cap.
        var percentages: [Double] = []
        percentages.reserveCapacity(3)
        for (reading, _, _, _) in readings {
            guard let value = reading.value,
                  let goal = reading.goal
            else {
                return .unavailable([.invalidNumericCalculation])
            }
            percentages.append(boundedPercentage(value: value, goal: goal))
        }
        if let perRingCap = policy.perRingCap {
            percentages = percentages.map { min(perRingCap, $0) }
        }
        if policy.quantization.stage == .perRing {
            percentages = percentages.map {
                quantize($0, with: policy.quantization)
            }
            if let perRingCap = policy.perRingCap {
                percentages = percentages.map { min(perRingCap, $0) }
            }
        }

        var points = percentages.reduce(0, +)
        if policy.quantization.stage == .aggregate {
            points = quantize(points, with: policy.quantization)
        }
        points = min(ActivityScore.maximumDailyPoints, points)

        guard let score = try? ActivityScore(
                movePercentage: percentages[0],
                exercisePercentage: percentages[1],
                standOrRollPercentage: percentages[2],
                points: points
        ) else {
            return .unavailable([.invalidNumericCalculation])
        }
        return .available(score)
    }

    private static func boundedPercentage(value: Double, goal: Double) -> Double {
        let ratio = value / goal
        guard ratio.isFinite else { return .greatestFiniteMagnitude }
        let percentage = ratio * 100
        guard percentage.isFinite else {
            return .greatestFiniteMagnitude
        }
        return percentage
    }

    private static func quantize(
        _ points: Double,
        with policy: ScoreQuantizationPolicy
    ) -> Double {
        let quantized: Double
        switch policy.mode {
        case .none:
            quantized = points
        case .down:
            let scaled = points / policy.increment
            guard scaled.isFinite else { return points }
            quantized = scaled.rounded(.down) * policy.increment
        case .nearest:
            let scaled = points / policy.increment
            guard scaled.isFinite else { return points }
            quantized = scaled.rounded(.toNearestOrAwayFromZero)
                * policy.increment
        case .up:
            let scaled = points / policy.increment
            guard scaled.isFinite else { return points }
            quantized = scaled.rounded(.up) * policy.increment
        }
        guard quantized.isFinite else {
            return ActivityScore.maximumDailyPoints
        }
        return quantized == 0 ? 0.0 : quantized
    }
}
