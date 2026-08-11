import Foundation

public enum ActivityMoveMode: String, Codable, Equatable, Sendable {
    case activeEnergyKilocalories
    case moveMinutes
}

public enum ActivityStandMode: String, Codable, Equatable, Sendable {
    case standHours
    case rollHours
    case unknown
}

public enum ActivityPauseState: String, Codable, Equatable, Sendable {
    case running
    case paused
    case unknown
}

public struct ActivityRingReading: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidValue
        case invalidGoal
    }

    public let value: Double?
    public let goal: Double?

    public init(value: Double?, goal: Double?) throws {
        if let value, !value.isFinite || value < 0 {
            throw ValidationError.invalidValue
        }
        if let goal, !goal.isFinite || goal < 0 {
            throw ValidationError.invalidGoal
        }

        self.value = Self.normalized(value)
        self.goal = Self.normalized(goal)
    }

    private enum CodingKeys: String, CodingKey {
        case value
        case goal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            value: container.decodeIfPresent(Double.self, forKey: .value),
            goal: container.decodeIfPresent(Double.self, forKey: .goal)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(goal, forKey: .goal)
    }

    private static func normalized(_ number: Double?) -> Double? {
        guard let number else { return nil }
        return number == 0 ? 0.0 : number
    }
}

public struct ActivitySnapshotFingerprint: Codable, Hashable, Sendable {
    public let rawValue: String

    internal init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ActivitySnapshot: Codable, Equatable, Sendable {
    public let moveMode: ActivityMoveMode
    public let standMode: ActivityStandMode
    public let move: ActivityRingReading
    public let exercise: ActivityRingReading
    public let standOrRoll: ActivityRingReading
    public let pauseState: ActivityPauseState

    /// Compatibility view for callers that can already handle the unknown
    /// state. New source adapters should use `pauseState` directly.
    public var isPaused: Bool? {
        switch pauseState {
        case .running: false
        case .paused: true
        case .unknown: nil
        }
    }

    public var fingerprint: ActivitySnapshotFingerprint {
        let version = pauseState == .unknown || standMode == .unknown
            ? "v2"
            : "v1"
        return ActivitySnapshotFingerprint(
            rawValue: [
                "activity-snapshot",
                version,
                moveMode.rawValue,
                standMode.rawValue,
                pauseState.rawValue,
                Self.fingerprintToken(for: move.value),
                Self.fingerprintToken(for: move.goal),
                Self.fingerprintToken(for: exercise.value),
                Self.fingerprintToken(for: exercise.goal),
                Self.fingerprintToken(for: standOrRoll.value),
                Self.fingerprintToken(for: standOrRoll.goal),
            ].joined(separator: ":")
        )
    }

    public init(
        moveMode: ActivityMoveMode,
        standMode: ActivityStandMode,
        move: ActivityRingReading,
        exercise: ActivityRingReading,
        standOrRoll: ActivityRingReading,
        pauseState: ActivityPauseState
    ) {
        self.moveMode = moveMode
        self.standMode = standMode
        self.move = move
        self.exercise = exercise
        self.standOrRoll = standOrRoll
        self.pauseState = pauseState
    }

    /// Preserves the payload-v1 construction surface while mapping it into the
    /// explicit pause-state model used by payload version 2.
    public init(
        moveMode: ActivityMoveMode,
        standMode: ActivityStandMode,
        move: ActivityRingReading,
        exercise: ActivityRingReading,
        standOrRoll: ActivityRingReading,
        isPaused: Bool
    ) {
        self.init(
            moveMode: moveMode,
            standMode: standMode,
            move: move,
            exercise: exercise,
            standOrRoll: standOrRoll,
            pauseState: isPaused ? .paused : .running
        )
    }

    private enum CodingKeys: String, CodingKey {
        case moveMode
        case standMode
        case move
        case exercise
        case standOrRoll
        case pauseState
        case isPaused
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pauseState = try container.decodeIfPresent(
            ActivityPauseState.self,
            forKey: .pauseState
        )
        let legacyIsPaused = try container.decodeIfPresent(
            Bool.self,
            forKey: .isPaused
        )
        let resolvedPauseState: ActivityPauseState
        switch (pauseState, legacyIsPaused) {
        case let (.some(state), .none):
            resolvedPauseState = state
        case let (.none, .some(isPaused)):
            resolvedPauseState = isPaused ? .paused : .running
        case (.some, .some):
            throw DecodingError.dataCorruptedError(
                forKey: .pauseState,
                in: container,
                debugDescription: "Snapshot contains two pause representations"
            )
        case (.none, .none):
            throw DecodingError.keyNotFound(
                CodingKeys.pauseState,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Snapshot has no pause representation"
                )
            )
        }

        self.init(
            moveMode: try container.decode(
                ActivityMoveMode.self,
                forKey: .moveMode
            ),
            standMode: try container.decode(
                ActivityStandMode.self,
                forKey: .standMode
            ),
            move: try container.decode(ActivityRingReading.self, forKey: .move),
            exercise: try container.decode(
                ActivityRingReading.self,
                forKey: .exercise
            ),
            standOrRoll: try container.decode(
                ActivityRingReading.self,
                forKey: .standOrRoll
            ),
            pauseState: resolvedPauseState
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(moveMode, forKey: .moveMode)
        try container.encode(standMode, forKey: .standMode)
        try container.encode(move, forKey: .move)
        try container.encode(exercise, forKey: .exercise)
        try container.encode(standOrRoll, forKey: .standOrRoll)
        try container.encode(pauseState, forKey: .pauseState)
    }

    private static func fingerprintToken(for number: Double?) -> String {
        guard let number else { return "missing" }
        let normalized = number == 0 ? 0.0 : number
        return String(normalized.bitPattern, radix: 16)
    }
}
