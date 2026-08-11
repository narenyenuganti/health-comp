import Foundation

public enum RemoteScoringWireV1 {
    public static let policyIdentity = "healthcomp.activity-score.v1"

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidPercent
        case invalidIdentity
        case invalidOrdinal
        case invalidMode
        case invalidAvailability
        case invalidBasisPoints
        case invalidPolicy
        case invalidRevision
    }

    /// Trusted client conversion for the remote protocol. This intentionally
    /// does not share the local Apple/simulator score calculator semantics.
    public static func quantizePercent(_ value: Double) throws -> Int {
        guard value.isFinite, value >= 0 else { throw ValidationError.invalidPercent }
        if value >= 200 { return 20_000 }
        guard
              var decimal = Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX"))
        else { throw ValidationError.invalidPercent }
        decimal *= 100
        guard !decimal.isNaN else { throw ValidationError.invalidPercent }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 0, .bankers)
        if rounded >= 20_000 { return 20_000 }
        let result = NSDecimalNumber(decimal: rounded).intValue
        guard result >= 0 else { throw ValidationError.invalidPercent }
        return result
    }
}

public struct RemoteScoreRevisionWireV1: Equatable, Sendable {
    public let competitionID: UUID
    public let participantID: UUID
    public let dayOrdinal: Int
    public let moveMode: String
    public let standMode: String
    public let moveBasisPoints: Int?
    public let exerciseBasisPoints: Int?
    public let standBasisPoints: Int?
    public let acceptedCentiPoints: Int?
    public let availabilityReason: String
    public let scoringPolicyIdentity: String
    public let clientRevision: Int64
    public let wireContentSHA256: String
    public let canonicalContentHex: String

    public init(
        competitionID: UUID,
        participantID: UUID,
        dayOrdinal: Int,
        moveMode: String,
        standMode: String,
        moveBasisPoints: Int?,
        exerciseBasisPoints: Int?,
        standBasisPoints: Int?,
        availabilityReason: String,
        scoringPolicyIdentity: String,
        clientRevision: Int64
    ) throws {
        let nilUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        guard competitionID != nilUUID, participantID != nilUUID else {
            throw RemoteScoringWireV1.ValidationError.invalidIdentity
        }
        guard (1...7).contains(dayOrdinal) else {
            throw RemoteScoringWireV1.ValidationError.invalidOrdinal
        }
        guard ["activeEnergyKilocalories", "moveMinutes"].contains(moveMode),
              ["standHours", "rollHours", "unknown"].contains(standMode)
        else { throw RemoteScoringWireV1.ValidationError.invalidMode }
        guard scoringPolicyIdentity == RemoteScoringWireV1.policyIdentity else {
            throw RemoteScoringWireV1.ValidationError.invalidPolicy
        }
        guard clientRevision > 0 else {
            throw RemoteScoringWireV1.ValidationError.invalidRevision
        }

        let accepted: Int?
        if availabilityReason == "available" {
            guard standMode != "unknown" else { throw RemoteScoringWireV1.ValidationError.invalidMode }
            guard let moveBasisPoints, let exerciseBasisPoints, let standBasisPoints,
                  [moveBasisPoints, exerciseBasisPoints, standBasisPoints].allSatisfy({ (0...20_000).contains($0) })
            else { throw RemoteScoringWireV1.ValidationError.invalidBasisPoints }
            accepted = min(moveBasisPoints + exerciseBasisPoints + standBasisPoints, 60_000)
        } else {
            guard Self.unavailableReasons.contains(availabilityReason),
                  moveBasisPoints == nil, exerciseBasisPoints == nil, standBasisPoints == nil
            else { throw RemoteScoringWireV1.ValidationError.invalidAvailability }
            accepted = nil
        }

        self.competitionID = competitionID
        self.participantID = participantID
        self.dayOrdinal = dayOrdinal
        self.moveMode = moveMode
        self.standMode = standMode
        self.moveBasisPoints = moveBasisPoints
        self.exerciseBasisPoints = exerciseBasisPoints
        self.standBasisPoints = standBasisPoints
        self.acceptedCentiPoints = accepted
        self.availabilityReason = availabilityReason
        self.scoringPolicyIdentity = scoringPolicyIdentity
        self.clientRevision = clientRevision
        let content = Self.content(
            competitionID: competitionID, participantID: participantID,
            dayOrdinal: dayOrdinal, moveMode: moveMode, standMode: standMode,
            moveBasisPoints: moveBasisPoints, exerciseBasisPoints: exerciseBasisPoints,
            standBasisPoints: standBasisPoints, acceptedCentiPoints: accepted,
            availabilityReason: availabilityReason,
            scoringPolicyIdentity: scoringPolicyIdentity, clientRevision: clientRevision
        )
        self.canonicalContentHex = content.map { String(format: "%02x", $0) }.joined()
        self.wireContentSHA256 = SHA256Digest.hexDigest(content)
    }

    private static let unavailableReasons: Set<String> = [
        "sourceDataUnavailable", "unsupportedActivityConfiguration",
        "invalidSourceData", "missingMoveValue", "missingMoveGoal",
        "nonPositiveMoveGoal", "missingExerciseValue", "missingExerciseGoal",
        "nonPositiveExerciseGoal", "missingStandOrRollValue", "missingStandOrRollGoal",
        "nonPositiveStandOrRollGoal", "summaryPaused", "summaryPauseStateUnknown",
        "invalidNumericCalculation",
    ]

    private static func content(
        competitionID: UUID, participantID: UUID, dayOrdinal: Int,
        moveMode: String, standMode: String, moveBasisPoints: Int?,
        exerciseBasisPoints: Int?, standBasisPoints: Int?, acceptedCentiPoints: Int?,
        availabilityReason: String, scoringPolicyIdentity: String, clientRevision: Int64
    ) -> Data {
        var data = Data("healthcomp-wire-score-v1\0".utf8)
        data.appendTLV(1, Self.uuidBytes(competitionID))
        data.appendTLV(2, Self.uuidBytes(participantID))
        data.appendTLV(3, Self.int32Bytes(dayOrdinal))
        data.appendTLV(4, Data(moveMode.utf8))
        data.appendTLV(5, Data(standMode.utf8))
        data.appendTLV(6, moveBasisPoints.map(Self.int32Bytes))
        data.appendTLV(7, exerciseBasisPoints.map(Self.int32Bytes))
        data.appendTLV(8, standBasisPoints.map(Self.int32Bytes))
        data.appendTLV(9, acceptedCentiPoints.map(Self.int32Bytes))
        data.appendTLV(10, Data(availabilityReason.utf8))
        data.appendTLV(11, Data(scoringPolicyIdentity.utf8))
        data.appendTLV(12, Self.int64Bytes(clientRevision))
        return data
    }

    static func uuidBytes(_ value: UUID) -> Data {
        var uuid = value.uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }

    static func int32Bytes(_ value: Int) -> Data {
        var bigEndian = Int32(value).bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    static func int64Bytes(_ value: Int64) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
}

private extension Data {
    mutating func appendTLV(_ tag: UInt8, _ payload: Data?) {
        append(tag)
        if let payload {
            var length = UInt32(payload.count).bigEndian
            append(Swift.withUnsafeBytes(of: &length) { Data($0) })
            append(payload)
        } else {
            append(Data(repeating: 0xff, count: 4))
        }
    }
}
