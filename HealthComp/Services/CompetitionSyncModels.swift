import Foundation
import CoreFoundation
import CompetitionCore

enum CompetitionWireContractError: Error, Equatable, Sendable {
    case serverContractMismatch
}

enum CompetitionWireContract: Sendable {
    case profile
    case competitionDescriptor
    case inviteCreationRequest
    case inviteCreationResponse
    case inviteClaimRequest
    case inviteClaimResponse
    case scoreRevisionRequest
    case scoreRevisionResponse
    case attestationRequest
    case attestationResponse
    case changePage
    case installationRequest
    case installationResponse
    case synchronizationCursor
}

enum CompetitionWireCodec {
    static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        contract: CompetitionWireContract
    ) throws -> Value {
        let object = try rawJSONObject(from: data)
        try CompetitionWireValidator.validate(object, contract: contract)
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    static func decodeArray<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        elementContract: CompetitionWireContract
    ) throws -> [Value] {
        let object = try rawJSONObject(from: data)
        guard let values = object as? [Any] else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        for value in values {
            try CompetitionWireValidator.validate(
                value,
                contract: elementContract
            )
        }
        do {
            return try decoder.decode([Value].self, from: data)
        } catch {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    static func encode<Value: Encodable>(
        _ value: Value,
        contract: CompetitionWireContract
    ) throws -> Data {
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw CompetitionWireContractError.serverContractMismatch
        }
        let object = try rawJSONObject(from: data)
        try CompetitionWireValidator.validate(object, contract: contract)
        return data
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder = JSONDecoder()

    static func timestamp(_ date: Date) throws -> String {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        return timestampFormatter.string(from: date)
    }

    static func date(_ value: String) throws -> Date {
        guard CompetitionWireValidator.isTimestamp(value),
              let date = timestampParsers.lazy
                  .compactMap({ $0.date(from: value) })
                  .first,
              date.timeIntervalSinceReferenceDate.isFinite
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        return date
    }

    private static func rawJSONObject(from data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let timestampParserOptions: [ISO8601DateFormatter.Options] = [
        [.withInternetDateTime],
        [.withInternetDateTime, .withFractionalSeconds],
    ]

    private static let timestampParsers: [ISO8601DateFormatter] =
        timestampParserOptions.map { options in
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}

struct CompetitionScoreRevisionRequest: Codable, Equatable, Sendable {
    static let version = 1

    let competitionID: UUID
    let semanticEventID: UUID
    let dayOrdinal: Int
    let clientRevision: Int64
    let evaluatedAt: Date
    let moveMode: String
    let standMode: String
    let moveBasisPoints: Int?
    let exerciseBasisPoints: Int?
    let standBasisPoints: Int?
    let availabilityReason: String
    let scoringPolicyIdentity: String
    let wireContentSHA256: String

    init(
        competitionID: UUID,
        semanticEventID: UUID,
        dayOrdinal: Int,
        clientRevision: Int64,
        evaluatedAt: Date,
        moveMode: String,
        standMode: String,
        moveBasisPoints: Int?,
        exerciseBasisPoints: Int?,
        standBasisPoints: Int?,
        availabilityReason: String,
        scoringPolicyIdentity: String,
        wireContentSHA256: String
    ) throws {
        guard competitionID != Self.nilUUID,
              semanticEventID != Self.nilUUID,
              (1...7).contains(dayOrdinal),
              clientRevision > 0,
              evaluatedAt.timeIntervalSinceReferenceDate.isFinite,
              Self.moveModes.contains(moveMode),
              Self.standModes.contains(standMode),
              scoringPolicyIdentity == "healthcomp.activity-score.v1",
              Self.isDigest(wireContentSHA256)
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }

        let basisPoints = [
            moveBasisPoints,
            exerciseBasisPoints,
            standBasisPoints,
        ]
        if availabilityReason == "available" {
            guard standMode != "unknown",
                  basisPoints.allSatisfy({ value in
                      value.map { (0...20_000).contains($0) } == true
                  })
            else {
                throw CompetitionWireContractError.serverContractMismatch
            }
        } else {
            guard Self.unavailableReasons.contains(availabilityReason),
                  basisPoints.allSatisfy({ $0 == nil })
            else {
                throw CompetitionWireContractError.serverContractMismatch
            }
        }

        self.competitionID = competitionID
        self.semanticEventID = semanticEventID
        self.dayOrdinal = dayOrdinal
        self.clientRevision = clientRevision
        self.evaluatedAt = evaluatedAt
        self.moveMode = moveMode
        self.standMode = standMode
        self.moveBasisPoints = moveBasisPoints
        self.exerciseBasisPoints = exerciseBasisPoints
        self.standBasisPoints = standBasisPoints
        self.availabilityReason = availabilityReason
        self.scoringPolicyIdentity = scoringPolicyIdentity
        self.wireContentSHA256 = wireContentSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case competitionID = "competitionId"
        case semanticEventID = "semanticEventId"
        case dayOrdinal
        case clientRevision
        case evaluatedAt
        case moveMode
        case standMode
        case moveBasisPoints
        case exerciseBasisPoints
        case standBasisPoints
        case availabilityReason
        case scoringPolicyIdentity
        case wireContentSHA256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == Self.version,
              let competitionID = UUID(
                  uuidString: try container.decode(
                      String.self,
                      forKey: .competitionID
                  )
              ),
              let semanticEventID = UUID(
                  uuidString: try container.decode(
                      String.self,
                      forKey: .semanticEventID
                  )
              ),
              let clientRevision = Int64(
                  try container.decode(String.self, forKey: .clientRevision)
              )
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        try self.init(
            competitionID: competitionID,
            semanticEventID: semanticEventID,
            dayOrdinal: try container.decode(Int.self, forKey: .dayOrdinal),
            clientRevision: clientRevision,
            evaluatedAt: CompetitionWireCodec.date(
                try container.decode(String.self, forKey: .evaluatedAt)
            ),
            moveMode: try container.decode(String.self, forKey: .moveMode),
            standMode: try container.decode(String.self, forKey: .standMode),
            moveBasisPoints: try container.decodeIfPresent(
                Int.self,
                forKey: .moveBasisPoints
            ),
            exerciseBasisPoints: try container.decodeIfPresent(
                Int.self,
                forKey: .exerciseBasisPoints
            ),
            standBasisPoints: try container.decodeIfPresent(
                Int.self,
                forKey: .standBasisPoints
            ),
            availabilityReason: try container.decode(
                String.self,
                forKey: .availabilityReason
            ),
            scoringPolicyIdentity: try container.decode(
                String.self,
                forKey: .scoringPolicyIdentity
            ),
            wireContentSHA256: try container.decode(
                String.self,
                forKey: .wireContentSHA256
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .version)
        try container.encode(
            competitionID.uuidString.lowercased(),
            forKey: .competitionID
        )
        try container.encode(
            semanticEventID.uuidString.lowercased(),
            forKey: .semanticEventID
        )
        try container.encode(dayOrdinal, forKey: .dayOrdinal)
        try container.encode(String(clientRevision), forKey: .clientRevision)
        try container.encode(
            CompetitionWireCodec.timestamp(evaluatedAt),
            forKey: .evaluatedAt
        )
        try container.encode(moveMode, forKey: .moveMode)
        try container.encode(standMode, forKey: .standMode)
        try container.encode(moveBasisPoints, forKey: .moveBasisPoints)
        try container.encode(
            exerciseBasisPoints,
            forKey: .exerciseBasisPoints
        )
        try container.encode(standBasisPoints, forKey: .standBasisPoints)
        try container.encode(
            availabilityReason,
            forKey: .availabilityReason
        )
        try container.encode(
            scoringPolicyIdentity,
            forKey: .scoringPolicyIdentity
        )
        try container.encode(
            wireContentSHA256,
            forKey: .wireContentSHA256
        )
    }

    fileprivate static let moveModes: Set<String> = [
        "activeEnergyKilocalories",
        "moveMinutes",
    ]
    fileprivate static let standModes: Set<String> = [
        "standHours",
        "rollHours",
        "unknown",
    ]
    fileprivate static let unavailableReasons: Set<String> = [
        "sourceDataUnavailable",
        "unsupportedActivityConfiguration",
        "invalidSourceData",
        "missingMoveValue",
        "missingMoveGoal",
        "nonPositiveMoveGoal",
        "missingExerciseValue",
        "missingExerciseGoal",
        "nonPositiveExerciseGoal",
        "missingStandOrRollValue",
        "missingStandOrRollGoal",
        "nonPositiveStandOrRollGoal",
        "summaryPaused",
        "summaryPauseStateUnknown",
        "invalidNumericCalculation",
    ]
    fileprivate static let nilUUID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    fileprivate static func isDigest(_ value: String) -> Bool {
        value.range(
            of: "^[0-9a-f]{64}$",
            options: .regularExpression
        ) != nil
    }
}

enum CompetitionRemoteLifecycle: String, Codable, Equatable, Sendable {
    case pending
    case scheduled
    case active
    case endsToday = "ends_today"
    case tallying
    case completed
    case archived
    case declined
    case expired
    case cancelled
}

enum CompetitionParticipantRole: String, Codable, Equatable, Sendable {
    case creator
    case invitee
}

enum CompetitionParticipantState: String, Codable, Equatable, Sendable {
    case pending
    case accepted
    case declined
    case anonymized
}

struct CompetitionProfilePresentation: Codable, Equatable, Sendable {
    let id: UUID
    let displayName: String

    init(id: UUID, displayName: String) throws {
        guard CompetitionWireValue.validUUID(id),
              CompetitionWireValue.validPresentationName(displayName)
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.id = id
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try container.wireUUID(forKey: .id),
            displayName: try container.decode(
                String.self,
                forKey: .displayName
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeWireUUID(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
    }
}

struct CompetitionParticipantDescriptor: Codable, Equatable, Sendable {
    let profileID: UUID
    let role: CompetitionParticipantRole
    let state: CompetitionParticipantState
    let profile: CompetitionProfilePresentation

    init(
        profileID: UUID,
        role: CompetitionParticipantRole,
        state: CompetitionParticipantState,
        profile: CompetitionProfilePresentation
    ) throws {
        guard CompetitionWireValue.validUUID(profileID),
              profileID == profile.id,
              state == .anonymized
                  ? profile.displayName == "Former competitor"
                  : profile.displayName != "Former competitor"
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.profileID = profileID
        self.role = role
        self.state = state
        self.profile = profile
    }

    private enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case role
        case state
        case profile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            profileID: try container.wireUUID(forKey: .profileID),
            role: try container.decode(
                CompetitionParticipantRole.self,
                forKey: .role
            ),
            state: try container.decode(
                CompetitionParticipantState.self,
                forKey: .state
            ),
            profile: try container.decode(
                CompetitionProfilePresentation.self,
                forKey: .profile
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeWireUUID(profileID, forKey: .profileID)
        try container.encode(role, forKey: .role)
        try container.encode(state, forKey: .state)
        try container.encode(profile, forKey: .profile)
    }
}

struct CompetitionDescriptor: Codable, Equatable, Sendable {
    let competitionID: UUID
    let creatorProfileID: UUID
    let timeZoneIdentifier: String?
    let startDay: String?
    let scoringPolicyIdentity: String
    let lifecycle: CompetitionRemoteLifecycle
    let invitationExpiresAt: Date
    let bestAvailableDeadline: Date?
    let rematchParentID: UUID?
    let nextServerSequence: Int64
    let participants: [CompetitionParticipantDescriptor]

    var serverCursor: Int64 { nextServerSequence - 1 }

    init(
        competitionID: UUID,
        creatorProfileID: UUID,
        timeZoneIdentifier: String?,
        startDay: String?,
        scoringPolicyIdentity: String,
        lifecycle: CompetitionRemoteLifecycle,
        invitationExpiresAt: Date,
        bestAvailableDeadline: Date?,
        rematchParentID: UUID?,
        nextServerSequence: Int64,
        participants: [CompetitionParticipantDescriptor]
    ) throws {
        guard CompetitionWireValue.validUUID(competitionID),
              CompetitionWireValue.validUUID(creatorProfileID),
              rematchParentID != competitionID,
              nextServerSequence > 0,
              invitationExpiresAt.timeIntervalSinceReferenceDate.isFinite,
              bestAvailableDeadline?.timeIntervalSinceReferenceDate.isFinite
                  ?? true,
              scoringPolicyIdentity == RemoteScoringWireV1.policyIdentity,
              participants.count == Set(participants.map(\.profileID)).count,
              participants.count == Set(participants.map(\.role)).count,
              let creator = participants.first(where: { $0.role == .creator }),
              creator.profileID == creatorProfileID,
              (1...2).contains(participants.count),
              Self.validSchedule(
                  lifecycle: lifecycle,
                  timeZoneIdentifier: timeZoneIdentifier,
                  startDay: startDay,
                  bestAvailableDeadline: bestAvailableDeadline
              )
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.competitionID = competitionID
        self.creatorProfileID = creatorProfileID
        self.timeZoneIdentifier = timeZoneIdentifier
        self.startDay = startDay
        self.scoringPolicyIdentity = scoringPolicyIdentity
        self.lifecycle = lifecycle
        self.invitationExpiresAt = invitationExpiresAt
        self.bestAvailableDeadline = bestAvailableDeadline
        self.rematchParentID = rematchParentID
        self.nextServerSequence = nextServerSequence
        self.participants = participants.sorted { lhs, _ in
            lhs.role == .creator
        }
    }

    private enum CodingKeys: String, CodingKey {
        case competitionID = "id"
        case creatorProfileID = "creator_profile_id"
        case timeZoneIdentifier = "time_zone_identifier"
        case startDay = "start_day"
        case scoringPolicyIdentity = "scoring_policy_identity"
        case lifecycle
        case invitationExpiresAt = "invitation_expires_at"
        case bestAvailableDeadline = "best_available_deadline"
        case rematchParentID = "rematch_parent_id"
        case nextServerSequence = "next_server_seq"
        case participants
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            competitionID: try container.wireUUID(forKey: .competitionID),
            creatorProfileID: try container.wireUUID(
                forKey: .creatorProfileID
            ),
            timeZoneIdentifier: try container.decodeIfPresent(
                String.self,
                forKey: .timeZoneIdentifier
            ),
            startDay: try container.decodeIfPresent(
                String.self,
                forKey: .startDay
            ),
            scoringPolicyIdentity: try container.decode(
                String.self,
                forKey: .scoringPolicyIdentity
            ),
            lifecycle: try container.decode(
                CompetitionRemoteLifecycle.self,
                forKey: .lifecycle
            ),
            invitationExpiresAt: try container.wireDate(
                forKey: .invitationExpiresAt
            ),
            bestAvailableDeadline: try container.wireDateIfPresent(
                forKey: .bestAvailableDeadline
            ),
            rematchParentID: try container.wireUUIDIfPresent(
                forKey: .rematchParentID
            ),
            nextServerSequence: try container.decode(
                Int64.self,
                forKey: .nextServerSequence
            ),
            participants: try container.decode(
                [CompetitionParticipantDescriptor].self,
                forKey: .participants
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeWireUUID(competitionID, forKey: .competitionID)
        try container.encodeWireUUID(
            creatorProfileID,
            forKey: .creatorProfileID
        )
        try container.encode(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try container.encode(startDay, forKey: .startDay)
        try container.encode(
            scoringPolicyIdentity,
            forKey: .scoringPolicyIdentity
        )
        try container.encode(lifecycle, forKey: .lifecycle)
        try container.encodeWireDate(
            invitationExpiresAt,
            forKey: .invitationExpiresAt
        )
        try container.encodeWireDateIfPresent(
            bestAvailableDeadline,
            forKey: .bestAvailableDeadline
        )
        try container.encodeWireUUIDIfPresent(
            rematchParentID,
            forKey: .rematchParentID
        )
        try container.encode(nextServerSequence, forKey: .nextServerSequence)
        try container.encode(participants, forKey: .participants)
    }

    fileprivate static func validSchedule(
        lifecycle: CompetitionRemoteLifecycle,
        timeZoneIdentifier: String?,
        startDay: String?,
        bestAvailableDeadline: Date?
    ) -> Bool {
        if let timeZoneIdentifier,
           timeZoneIdentifier.isEmpty || timeZoneIdentifier.count > 255 {
            return false
        }
        if let startDay, !CompetitionWireValue.validDay(startDay) {
            return false
        }
        switch lifecycle {
        case .scheduled, .active, .endsToday, .tallying, .completed, .archived:
            return timeZoneIdentifier != nil
                && startDay != nil
                && bestAvailableDeadline != nil
        case .pending, .declined, .expired, .cancelled:
            return startDay == nil && bestAvailableDeadline == nil
        }
    }
}

struct CompetitionInviteCreationRequest: Codable, Equatable, Sendable {
    let timeZoneIdentifier: String
    let rematchParentID: UUID?
    let idempotencyKey: UUID

    init(
        timeZoneIdentifier: String,
        rematchParentID: UUID?,
        idempotencyKey: UUID
    ) throws {
        guard !timeZoneIdentifier.isEmpty,
              timeZoneIdentifier.count <= 255,
              rematchParentID.map(CompetitionWireValue.validUUID) ?? true,
              CompetitionWireValue.validUUID(idempotencyKey)
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.timeZoneIdentifier = timeZoneIdentifier
        self.rematchParentID = rematchParentID
        self.idempotencyKey = idempotencyKey
    }

    private enum CodingKeys: String, CodingKey {
        case timeZoneIdentifier
        case rematchParentID = "rematchParentId"
        case idempotencyKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            timeZoneIdentifier: try container.decode(
                String.self,
                forKey: .timeZoneIdentifier
            ),
            rematchParentID: try container.wireUUIDIfPresent(
                forKey: .rematchParentID
            ),
            idempotencyKey: try container.wireUUID(forKey: .idempotencyKey)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            timeZoneIdentifier,
            forKey: .timeZoneIdentifier
        )
        try container.encodeWireUUIDIfPresent(
            rematchParentID,
            forKey: .rematchParentID
        )
        try container.encodeWireUUID(idempotencyKey, forKey: .idempotencyKey)
    }
}

struct CompetitionInvite: Codable, Equatable, Sendable {
    let competitionID: UUID
    let token: String

    init(competitionID: UUID, token: String) throws {
        guard CompetitionWireValue.validUUID(competitionID),
              CompetitionWireValue.validInviteToken(token)
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.competitionID = competitionID
        self.token = token
    }

    private enum CodingKeys: String, CodingKey {
        case competitionID = "competitionId"
        case token
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            competitionID: try container.wireUUID(forKey: .competitionID),
            token: try container.decode(String.self, forKey: .token)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeWireUUID(competitionID, forKey: .competitionID)
        try container.encode(token, forKey: .token)
    }
}

struct CompetitionInviteClaimRequest: Codable, Equatable, Sendable {
    let token: String

    init(token: String) throws {
        guard CompetitionWireValue.validInviteToken(token) else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.token = token
    }

    private enum CodingKeys: String, CodingKey {
        case token
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(token: try container.decode(String.self, forKey: .token))
    }
}

struct CompetitionInviteClaim: Codable, Equatable, Sendable {
    let competitionID: UUID

    init(competitionID: UUID) throws {
        guard CompetitionWireValue.validUUID(competitionID) else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.competitionID = competitionID
    }

    private enum CodingKeys: String, CodingKey {
        case competitionID = "competitionId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            competitionID: try container.wireUUID(forKey: .competitionID)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeWireUUID(competitionID, forKey: .competitionID)
    }
}

enum CompetitionScoreRevisionDisposition: String, Codable, Equatable, Sendable {
    case appended
    case duplicate
    case rejected
}

enum CompetitionScoreRevisionRejectionCode:
    String,
    Codable,
    Equatable,
    Sendable
{
    case divergentDuplicate = "divergent_duplicate"
    case revisionRegression = "revision_regression"
    case windowStable = "window_stable"
    case competitionTerminal = "competition_terminal"
    case competitionFinalized = "competition_finalized"
}

struct CompetitionScoreRevisionResponse: Codable, Equatable, Sendable {
    let disposition: CompetitionScoreRevisionDisposition
    let rejectionCode: CompetitionScoreRevisionRejectionCode?
    let acceptedCentiPoints: Int?
    let wireContentSHA256: String?
    let acceptedServerSequence: Int64?
    let competitionCursor: Int64

    init(
        disposition: CompetitionScoreRevisionDisposition,
        rejectionCode: CompetitionScoreRevisionRejectionCode?,
        acceptedCentiPoints: Int?,
        wireContentSHA256: String?,
        acceptedServerSequence: Int64?,
        competitionCursor: Int64
    ) throws {
        guard competitionCursor >= 0,
              acceptedCentiPoints.map({ (0...60_000).contains($0) }) ?? true
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        switch disposition {
        case .appended, .duplicate:
            guard rejectionCode == nil,
                  let wireContentSHA256,
                  CompetitionWireValue.validDigest(wireContentSHA256),
                  let acceptedServerSequence,
                  acceptedServerSequence > 0,
                  acceptedServerSequence <= competitionCursor
            else {
                throw CompetitionWireContractError.serverContractMismatch
            }
        case .rejected:
            guard rejectionCode != nil,
                  (wireContentSHA256 == nil)
                      == (acceptedServerSequence == nil),
                  wireContentSHA256.map(CompetitionWireValue.validDigest)
                      ?? true,
                  acceptedServerSequence.map({
                      $0 > 0 && $0 <= competitionCursor
                  }) ?? true,
                  acceptedServerSequence != nil || acceptedCentiPoints == nil
            else {
                throw CompetitionWireContractError.serverContractMismatch
            }
        }
        self.disposition = disposition
        self.rejectionCode = rejectionCode
        self.acceptedCentiPoints = acceptedCentiPoints
        self.wireContentSHA256 = wireContentSHA256
        self.acceptedServerSequence = acceptedServerSequence
        self.competitionCursor = competitionCursor
    }

    private enum CodingKeys: String, CodingKey {
        case disposition
        case rejectionCode = "code"
        case acceptedCentiPoints
        case wireContentSHA256
        case acceptedServerSequence = "acceptedServerSeq"
        case competitionCursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            disposition: try container.decode(
                CompetitionScoreRevisionDisposition.self,
                forKey: .disposition
            ),
            rejectionCode: try container.decodeIfPresent(
                CompetitionScoreRevisionRejectionCode.self,
                forKey: .rejectionCode
            ),
            acceptedCentiPoints: try container.decodeIfPresent(
                Int.self,
                forKey: .acceptedCentiPoints
            ),
            wireContentSHA256: try container.decodeIfPresent(
                String.self,
                forKey: .wireContentSHA256
            ),
            acceptedServerSequence: try container.wireInt64IfPresent(
                forKey: .acceptedServerSequence
            ),
            competitionCursor: try container.wireInt64(
                forKey: .competitionCursor,
                allowZero: true
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(disposition, forKey: .disposition)
        if let rejectionCode {
            try container.encode(rejectionCode, forKey: .rejectionCode)
        }
        try container.encode(
            acceptedCentiPoints,
            forKey: .acceptedCentiPoints
        )
        try container.encode(
            wireContentSHA256,
            forKey: .wireContentSHA256
        )
        try container.encodeWireInt64IfPresent(
            acceptedServerSequence,
            forKey: .acceptedServerSequence
        )
        try container.encodeWireInt64(
            competitionCursor,
            forKey: .competitionCursor
        )
    }
}

enum CompetitionAttestationBasis: String, Codable, Equatable, Sendable {
    case stable
    case bestAvailable = "best_available"
}

struct CompetitionAttestationRequest: Codable, Equatable, Sendable {
    static let version = 1

    let competitionID: UUID
    let semanticEventID: UUID
    let attestationVersion: Int64
    let basis: CompetitionAttestationBasis
    let acceptedRevisions: [Int64]
    let windowCommitmentSHA256: String

    init(
        competitionID: UUID,
        semanticEventID: UUID,
        attestationVersion: Int64,
        basis: CompetitionAttestationBasis,
        acceptedRevisions: [Int64],
        windowCommitmentSHA256: String
    ) throws {
        guard CompetitionWireValue.validUUID(competitionID),
              CompetitionWireValue.validUUID(semanticEventID),
              attestationVersion > 0,
              acceptedRevisions.count == 7,
              acceptedRevisions.allSatisfy({ $0 >= 0 }),
              basis != .stable
                  || acceptedRevisions.allSatisfy({ $0 > 0 }),
              CompetitionWireValue.validDigest(windowCommitmentSHA256)
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.competitionID = competitionID
        self.semanticEventID = semanticEventID
        self.attestationVersion = attestationVersion
        self.basis = basis
        self.acceptedRevisions = acceptedRevisions
        self.windowCommitmentSHA256 = windowCommitmentSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case competitionID = "competitionId"
        case semanticEventID = "semanticEventId"
        case attestationVersion
        case basis
        case acceptedRevisions
        case windowCommitmentSHA256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == Self.version
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        try self.init(
            competitionID: try container.wireUUID(forKey: .competitionID),
            semanticEventID: try container.wireUUID(forKey: .semanticEventID),
            attestationVersion: try container.wireInt64(
                forKey: .attestationVersion
            ),
            basis: try container.decode(
                CompetitionAttestationBasis.self,
                forKey: .basis
            ),
            acceptedRevisions: try container.wireInt64Array(
                forKey: .acceptedRevisions,
                allowZero: true
            ),
            windowCommitmentSHA256: try container.decode(
                String.self,
                forKey: .windowCommitmentSHA256
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .version)
        try container.encodeWireUUID(competitionID, forKey: .competitionID)
        try container.encodeWireUUID(semanticEventID, forKey: .semanticEventID)
        try container.encodeWireInt64(
            attestationVersion,
            forKey: .attestationVersion
        )
        try container.encode(basis, forKey: .basis)
        try container.encode(
            acceptedRevisions.map(String.init),
            forKey: .acceptedRevisions
        )
        try container.encode(
            windowCommitmentSHA256,
            forKey: .windowCommitmentSHA256
        )
    }
}

enum CompetitionMutationDisposition: String, Codable, Equatable, Sendable {
    case appended
    case duplicate
}

struct CompetitionAttestationReceipt: Codable, Equatable, Sendable {
    let disposition: CompetitionMutationDisposition
    let windowCommitmentSHA256: String
    let entityServerSequence: Int64

    init(
        disposition: CompetitionMutationDisposition,
        windowCommitmentSHA256: String,
        entityServerSequence: Int64
    ) throws {
        guard CompetitionWireValue.validDigest(windowCommitmentSHA256),
              entityServerSequence > 0
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.disposition = disposition
        self.windowCommitmentSHA256 = windowCommitmentSHA256
        self.entityServerSequence = entityServerSequence
    }

    private enum CodingKeys: String, CodingKey {
        case disposition
        case windowCommitmentSHA256
        case entityServerSequence = "serverCursor"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            disposition: try container.decode(
                CompetitionMutationDisposition.self,
                forKey: .disposition
            ),
            windowCommitmentSHA256: try container.decode(
                String.self,
                forKey: .windowCommitmentSHA256
            ),
            entityServerSequence: try container.wireInt64(
                forKey: .entityServerSequence
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(disposition, forKey: .disposition)
        try container.encode(
            windowCommitmentSHA256,
            forKey: .windowCommitmentSHA256
        )
        try container.encodeWireInt64(
            entityServerSequence,
            forKey: .entityServerSequence
        )
    }
}

enum CompetitionInstallationEnvironment:
    String,
    Codable,
    Equatable,
    Sendable
{
    case sandbox
    case production
}

enum CompetitionInstallationState: String, Codable, Equatable, Sendable {
    case active
    case revoked
}

struct CompetitionInstallationRequest: Codable, Equatable, Sendable {
    let installationID: UUID
    let apnsToken: String
    let environment: CompetitionInstallationEnvironment

    init(
        installationID: UUID,
        apnsToken: String,
        environment: CompetitionInstallationEnvironment
    ) throws {
        guard CompetitionWireValue.validUUID(installationID),
              apnsToken.range(
                  of: "^[0-9a-f]{64,200}$",
                  options: .regularExpression
              ) != nil
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.installationID = installationID
        self.apnsToken = apnsToken
        self.environment = environment
    }

    private enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
        case apnsToken = "apns_token"
        case environment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            installationID: try container.wireUUID(forKey: .installationID),
            apnsToken: try container.decode(String.self, forKey: .apnsToken),
            environment: try container.decode(
                CompetitionInstallationEnvironment.self,
                forKey: .environment
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeWireUUID(installationID, forKey: .installationID)
        try container.encode(apnsToken, forKey: .apnsToken)
        try container.encode(environment, forKey: .environment)
    }
}

struct CompetitionInstallation: Codable, Equatable, Sendable {
    let installationID: UUID
    let environment: CompetitionInstallationEnvironment
    let state: CompetitionInstallationState

    init(
        installationID: UUID,
        environment: CompetitionInstallationEnvironment,
        state: CompetitionInstallationState
    ) throws {
        guard CompetitionWireValue.validUUID(installationID) else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.installationID = installationID
        self.environment = environment
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
        case environment
        case state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            installationID: try container.wireUUID(forKey: .installationID),
            environment: try container.decode(
                CompetitionInstallationEnvironment.self,
                forKey: .environment
            ),
            state: try container.decode(
                CompetitionInstallationState.self,
                forKey: .state
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeWireUUID(installationID, forKey: .installationID)
        try container.encode(environment, forKey: .environment)
        try container.encode(state, forKey: .state)
    }
}

struct CompetitionSynchronizationCursor: Codable, Equatable, Sendable {
    let competitionID: UUID
    let lastSeenServerSequence: Int64

    init(competitionID: UUID, lastSeenServerSequence: Int64) throws {
        guard CompetitionWireValue.validUUID(competitionID),
              lastSeenServerSequence >= 0
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.competitionID = competitionID
        self.lastSeenServerSequence = lastSeenServerSequence
    }

    private enum CodingKeys: String, CodingKey {
        case competitionID = "competition_id"
        case lastSeenServerSequence = "last_seen_server_seq"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            competitionID: try container.wireUUID(forKey: .competitionID),
            lastSeenServerSequence: try container.wireInt64(
                forKey: .lastSeenServerSequence,
                allowZero: true
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeWireUUID(competitionID, forKey: .competitionID)
        try container.encodeWireInt64(
            lastSeenServerSequence,
            forKey: .lastSeenServerSequence
        )
    }
}

enum CompetitionChangeKind: String, Codable, Equatable, Sendable {
    case participantAdded = "participant_added"
    case participantStateChanged = "participant_state_changed"
    case competitionLifecycleChanged = "competition_lifecycle_changed"
    case profilePresentationChanged = "profile_presentation_changed"
    case profileAnonymized = "profile_anonymized"
    case scoreRevisionRecorded = "score_revision_recorded"
    case participantAttested = "participant_attested"
    case competitionResultConfirmed = "competition_result_confirmed"
    case competitionAwardEarned = "competition_award_earned"
}

struct CompetitionParticipantChange: Codable, Equatable, Sendable {
    let profileID: UUID
    let role: CompetitionParticipantRole
    let state: CompetitionParticipantState

    init(
        profileID: UUID,
        role: CompetitionParticipantRole,
        state: CompetitionParticipantState
    ) throws {
        guard CompetitionWireValue.validUUID(profileID) else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.profileID = profileID
        self.role = role
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case role
        case state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            profileID: try container.wireUUID(forKey: .profileID),
            role: try container.decode(
                CompetitionParticipantRole.self,
                forKey: .role
            ),
            state: try container.decode(
                CompetitionParticipantState.self,
                forKey: .state
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeWireUUID(profileID, forKey: .profileID)
        try container.encode(role, forKey: .role)
        try container.encode(state, forKey: .state)
    }
}

struct CompetitionLifecycleChange: Codable, Equatable, Sendable {
    let lifecycle: CompetitionRemoteLifecycle
    let timeZoneIdentifier: String?
    let startDay: String?
    let bestAvailableDeadline: Date?
    let scoringPolicyIdentity: String

    init(
        lifecycle: CompetitionRemoteLifecycle,
        timeZoneIdentifier: String?,
        startDay: String?,
        bestAvailableDeadline: Date?,
        scoringPolicyIdentity: String
    ) throws {
        guard scoringPolicyIdentity == RemoteScoringWireV1.policyIdentity,
              CompetitionDescriptor.validSchedule(
                  lifecycle: lifecycle,
                  timeZoneIdentifier: timeZoneIdentifier,
                  startDay: startDay,
                  bestAvailableDeadline: bestAvailableDeadline
              )
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.lifecycle = lifecycle
        self.timeZoneIdentifier = timeZoneIdentifier
        self.startDay = startDay
        self.bestAvailableDeadline = bestAvailableDeadline
        self.scoringPolicyIdentity = scoringPolicyIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case lifecycle
        case timeZoneIdentifier = "time_zone_identifier"
        case startDay = "start_day"
        case bestAvailableDeadline = "best_available_deadline"
        case scoringPolicyIdentity = "scoring_policy_identity"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            lifecycle: try container.decode(
                CompetitionRemoteLifecycle.self,
                forKey: .lifecycle
            ),
            timeZoneIdentifier: try container.decodeIfPresent(
                String.self,
                forKey: .timeZoneIdentifier
            ),
            startDay: try container.decodeIfPresent(
                String.self,
                forKey: .startDay
            ),
            bestAvailableDeadline: try container.wireDateIfPresent(
                forKey: .bestAvailableDeadline
            ),
            scoringPolicyIdentity: try container.decode(
                String.self,
                forKey: .scoringPolicyIdentity
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lifecycle, forKey: .lifecycle)
        try container.encode(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try container.encode(startDay, forKey: .startDay)
        try container.encodeWireDateIfPresent(
            bestAvailableDeadline,
            forKey: .bestAvailableDeadline
        )
        try container.encode(
            scoringPolicyIdentity,
            forKey: .scoringPolicyIdentity
        )
    }
}

struct CompetitionProfilePresentationChange: Codable, Equatable, Sendable {
    let profileID: UUID
    let displayName: String

    init(profileID: UUID, displayName: String) throws {
        guard CompetitionWireValue.validUUID(profileID),
              CompetitionWireValue.validPresentationName(displayName)
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.profileID = profileID
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case displayName = "display_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            profileID: try container.wireUUID(forKey: .profileID),
            displayName: try container.decode(
                String.self,
                forKey: .displayName
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeWireUUID(profileID, forKey: .profileID)
        try container.encode(displayName, forKey: .displayName)
    }
}

struct CompetitionScoreChange: Codable, Equatable, Sendable {
    let participantProfileID: UUID
    let dayOrdinal: Int
    let clientRevision: Int64
    let moveMode: String
    let standMode: String
    let moveBasisPoints: Int?
    let exerciseBasisPoints: Int?
    let standBasisPoints: Int?
    let acceptedCentiPoints: Int?
    let availabilityReason: String
    let scoringPolicyIdentity: String
    let wireDigestVersion: Int
    let wireContentSHA256: String
    let serverSequence: Int64
    let evaluatedAt: Date

    init(
        participantProfileID: UUID,
        dayOrdinal: Int,
        clientRevision: Int64,
        moveMode: String,
        standMode: String,
        moveBasisPoints: Int?,
        exerciseBasisPoints: Int?,
        standBasisPoints: Int?,
        acceptedCentiPoints: Int?,
        availabilityReason: String,
        scoringPolicyIdentity: String,
        wireDigestVersion: Int,
        wireContentSHA256: String,
        serverSequence: Int64,
        evaluatedAt: Date
    ) throws {
        guard CompetitionWireValue.validUUID(participantProfileID),
              (1...7).contains(dayOrdinal),
              clientRevision > 0,
              CompetitionScoreRevisionRequest.moveModes.contains(moveMode),
              CompetitionScoreRevisionRequest.standModes.contains(standMode),
              scoringPolicyIdentity == RemoteScoringWireV1.policyIdentity,
              wireDigestVersion == 1,
              CompetitionWireValue.validDigest(wireContentSHA256),
              serverSequence > 0,
              evaluatedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        let values = [
            moveBasisPoints,
            exerciseBasisPoints,
            standBasisPoints,
        ]
        if availabilityReason == "available" {
            guard standMode != "unknown",
                  values.allSatisfy({ value in
                      value.map { (0...20_000).contains($0) } == true
                  }),
                  acceptedCentiPoints == min(
                      moveBasisPoints! + exerciseBasisPoints!
                          + standBasisPoints!,
                      60_000
                  )
            else {
                throw CompetitionWireContractError.serverContractMismatch
            }
        } else {
            guard CompetitionWireValue.unavailableReasons
                .contains(availabilityReason),
                values.allSatisfy({ $0 == nil }),
                acceptedCentiPoints == nil
            else {
                throw CompetitionWireContractError.serverContractMismatch
            }
        }
        self.participantProfileID = participantProfileID
        self.dayOrdinal = dayOrdinal
        self.clientRevision = clientRevision
        self.moveMode = moveMode
        self.standMode = standMode
        self.moveBasisPoints = moveBasisPoints
        self.exerciseBasisPoints = exerciseBasisPoints
        self.standBasisPoints = standBasisPoints
        self.acceptedCentiPoints = acceptedCentiPoints
        self.availabilityReason = availabilityReason
        self.scoringPolicyIdentity = scoringPolicyIdentity
        self.wireDigestVersion = wireDigestVersion
        self.wireContentSHA256 = wireContentSHA256
        self.serverSequence = serverSequence
        self.evaluatedAt = evaluatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case participantProfileID = "participant_profile_id"
        case dayOrdinal = "day_ordinal"
        case clientRevision = "client_revision"
        case moveMode = "move_mode"
        case standMode = "stand_mode"
        case moveBasisPoints = "move_basis_points"
        case exerciseBasisPoints = "exercise_basis_points"
        case standBasisPoints = "stand_basis_points"
        case acceptedCentiPoints = "accepted_centi_points"
        case availabilityReason = "availability_reason"
        case scoringPolicyIdentity = "scoring_policy_identity"
        case wireDigestVersion = "wire_digest_version"
        case wireContentSHA256 = "wire_content_sha256"
        case serverSequence = "server_seq"
        case evaluatedAt = "evaluated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            participantProfileID: try container.wireUUID(
                forKey: .participantProfileID
            ),
            dayOrdinal: try container.decode(Int.self, forKey: .dayOrdinal),
            clientRevision: try container.wireInt64(forKey: .clientRevision),
            moveMode: try container.decode(String.self, forKey: .moveMode),
            standMode: try container.decode(String.self, forKey: .standMode),
            moveBasisPoints: try container.decodeIfPresent(
                Int.self,
                forKey: .moveBasisPoints
            ),
            exerciseBasisPoints: try container.decodeIfPresent(
                Int.self,
                forKey: .exerciseBasisPoints
            ),
            standBasisPoints: try container.decodeIfPresent(
                Int.self,
                forKey: .standBasisPoints
            ),
            acceptedCentiPoints: try container.decodeIfPresent(
                Int.self,
                forKey: .acceptedCentiPoints
            ),
            availabilityReason: try container.decode(
                String.self,
                forKey: .availabilityReason
            ),
            scoringPolicyIdentity: try container.decode(
                String.self,
                forKey: .scoringPolicyIdentity
            ),
            wireDigestVersion: try container.decode(
                Int.self,
                forKey: .wireDigestVersion
            ),
            wireContentSHA256: try container.decode(
                String.self,
                forKey: .wireContentSHA256
            ),
            serverSequence: try container.wireInt64(
                forKey: .serverSequence
            ),
            evaluatedAt: try container.wireDate(forKey: .evaluatedAt)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeWireUUID(
            participantProfileID,
            forKey: .participantProfileID
        )
        try container.encode(dayOrdinal, forKey: .dayOrdinal)
        try container.encodeWireInt64(clientRevision, forKey: .clientRevision)
        try container.encode(moveMode, forKey: .moveMode)
        try container.encode(standMode, forKey: .standMode)
        try container.encode(moveBasisPoints, forKey: .moveBasisPoints)
        try container.encode(
            exerciseBasisPoints,
            forKey: .exerciseBasisPoints
        )
        try container.encode(standBasisPoints, forKey: .standBasisPoints)
        try container.encode(
            acceptedCentiPoints,
            forKey: .acceptedCentiPoints
        )
        try container.encode(
            availabilityReason,
            forKey: .availabilityReason
        )
        try container.encode(
            scoringPolicyIdentity,
            forKey: .scoringPolicyIdentity
        )
        try container.encode(wireDigestVersion, forKey: .wireDigestVersion)
        try container.encode(
            wireContentSHA256,
            forKey: .wireContentSHA256
        )
        try container.encodeWireInt64(serverSequence, forKey: .serverSequence)
        try container.encodeWireDate(evaluatedAt, forKey: .evaluatedAt)
    }
}

struct CompetitionParticipantAttestationChange:
    Codable,
    Equatable,
    Sendable
{
    let participantProfileID: UUID
    let basis: CompetitionAttestationBasis
    let windowCommitmentSHA256: String
    let acceptedRevisions: [Int64]
    let attestationVersion: Int64
    let serverSequence: Int64
    let attestedAt: Date

    init(
        participantProfileID: UUID,
        basis: CompetitionAttestationBasis,
        windowCommitmentSHA256: String,
        acceptedRevisions: [Int64],
        attestationVersion: Int64,
        serverSequence: Int64,
        attestedAt: Date
    ) throws {
        guard CompetitionWireValue.validUUID(participantProfileID),
              CompetitionWireValue.validDigest(windowCommitmentSHA256),
              acceptedRevisions.count == 7,
              acceptedRevisions.allSatisfy({ $0 >= 0 }),
              basis != .stable
                  || acceptedRevisions.allSatisfy({ $0 > 0 }),
              attestationVersion > 0,
              serverSequence > 0,
              attestedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.participantProfileID = participantProfileID
        self.basis = basis
        self.windowCommitmentSHA256 = windowCommitmentSHA256
        self.acceptedRevisions = acceptedRevisions
        self.attestationVersion = attestationVersion
        self.serverSequence = serverSequence
        self.attestedAt = attestedAt
    }

    private enum CodingKeys: String, CodingKey {
        case participantProfileID = "participant_profile_id"
        case basis
        case windowCommitmentSHA256 = "window_commitment_sha256"
        case acceptedRevisions = "accepted_revisions"
        case attestationVersion = "attestation_version"
        case serverSequence = "server_seq"
        case attestedAt = "attested_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            participantProfileID: try container.wireUUID(
                forKey: .participantProfileID
            ),
            basis: try container.decode(
                CompetitionAttestationBasis.self,
                forKey: .basis
            ),
            windowCommitmentSHA256: try container.decode(
                String.self,
                forKey: .windowCommitmentSHA256
            ),
            acceptedRevisions: try container.wireInt64Array(
                forKey: .acceptedRevisions,
                allowZero: true
            ),
            attestationVersion: try container.wireInt64(
                forKey: .attestationVersion
            ),
            serverSequence: try container.wireInt64(
                forKey: .serverSequence
            ),
            attestedAt: try container.wireDate(forKey: .attestedAt)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeWireUUID(
            participantProfileID,
            forKey: .participantProfileID
        )
        try container.encode(basis, forKey: .basis)
        try container.encode(
            windowCommitmentSHA256,
            forKey: .windowCommitmentSHA256
        )
        try container.encode(
            acceptedRevisions.map(String.init),
            forKey: .acceptedRevisions
        )
        try container.encodeWireInt64(
            attestationVersion,
            forKey: .attestationVersion
        )
        try container.encodeWireInt64(serverSequence, forKey: .serverSequence)
        try container.encodeWireDate(attestedAt, forKey: .attestedAt)
    }
}

enum CompetitionFrozenDayStatus: String, Codable, Equatable, Sendable {
    case points
    case unavailable
}

enum CompetitionFrozenDaySource: String, Codable, Equatable, Sendable {
    case acceptedRevision = "accepted_revision"
    case deadlineMissing = "deadline_missing"
}

struct CompetitionFrozenDay: Codable, Equatable, Sendable {
    let ordinal: Int
    let status: CompetitionFrozenDayStatus
    let source: CompetitionFrozenDaySource
    let centiPoints: Int?
    let reason: String?
    let wireContentSHA256: String?
    let clientRevision: Int64?
    let serverSequence: Int64?
    let scoringPolicyIdentity: String?

    init(
        ordinal: Int,
        status: CompetitionFrozenDayStatus,
        source: CompetitionFrozenDaySource,
        centiPoints: Int?,
        reason: String?,
        wireContentSHA256: String?,
        clientRevision: Int64?,
        serverSequence: Int64?,
        scoringPolicyIdentity: String?
    ) throws {
        guard (1...7).contains(ordinal) else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        switch (source, status) {
        case (.deadlineMissing, .unavailable):
            guard centiPoints == nil,
                  reason == "missing",
                  wireContentSHA256 == nil,
                  clientRevision == nil,
                  serverSequence == nil,
                  scoringPolicyIdentity == nil
            else {
                throw CompetitionWireContractError.serverContractMismatch
            }
        case (.acceptedRevision, .points):
            guard let centiPoints,
                  (0...60_000).contains(centiPoints),
                  reason == nil,
                  wireContentSHA256.map(CompetitionWireValue.validDigest)
                      == true,
                  clientRevision.map({ $0 > 0 }) == true,
                  serverSequence.map({ $0 > 0 }) == true,
                  scoringPolicyIdentity == RemoteScoringWireV1.policyIdentity
            else {
                throw CompetitionWireContractError.serverContractMismatch
            }
        case (.acceptedRevision, .unavailable):
            guard centiPoints == nil,
                  reason.map(CompetitionWireValue.unavailableReasons.contains)
                      == true,
                  wireContentSHA256.map(CompetitionWireValue.validDigest)
                      == true,
                  clientRevision.map({ $0 > 0 }) == true,
                  serverSequence.map({ $0 > 0 }) == true,
                  scoringPolicyIdentity == RemoteScoringWireV1.policyIdentity
            else {
                throw CompetitionWireContractError.serverContractMismatch
            }
        case (.deadlineMissing, .points):
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.ordinal = ordinal
        self.status = status
        self.source = source
        self.centiPoints = centiPoints
        self.reason = reason
        self.wireContentSHA256 = wireContentSHA256
        self.clientRevision = clientRevision
        self.serverSequence = serverSequence
        self.scoringPolicyIdentity = scoringPolicyIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case ordinal
        case status
        case source
        case centiPoints = "centi_points"
        case reason
        case wireContentSHA256 = "wire_content_sha256"
        case clientRevision = "client_revision"
        case serverSequence = "server_seq"
        case scoringPolicyIdentity = "scoring_policy_identity"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            ordinal: try container.decode(Int.self, forKey: .ordinal),
            status: try container.decode(
                CompetitionFrozenDayStatus.self,
                forKey: .status
            ),
            source: try container.decode(
                CompetitionFrozenDaySource.self,
                forKey: .source
            ),
            centiPoints: try container.decodeIfPresent(
                Int.self,
                forKey: .centiPoints
            ),
            reason: try container.decodeIfPresent(
                String.self,
                forKey: .reason
            ),
            wireContentSHA256: try container.decodeIfPresent(
                String.self,
                forKey: .wireContentSHA256
            ),
            clientRevision: try container.wireInt64IfPresent(
                forKey: .clientRevision
            ),
            serverSequence: try container.wireInt64IfPresent(
                forKey: .serverSequence
            ),
            scoringPolicyIdentity: try container.decodeIfPresent(
                String.self,
                forKey: .scoringPolicyIdentity
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ordinal, forKey: .ordinal)
        try container.encode(status, forKey: .status)
        try container.encode(source, forKey: .source)
        try container.encode(centiPoints, forKey: .centiPoints)
        try container.encode(reason, forKey: .reason)
        try container.encode(
            wireContentSHA256,
            forKey: .wireContentSHA256
        )
        try container.encodeWireInt64IfPresent(
            clientRevision,
            forKey: .clientRevision
        )
        try container.encodeWireInt64IfPresent(
            serverSequence,
            forKey: .serverSequence
        )
        try container.encode(
            scoringPolicyIdentity,
            forKey: .scoringPolicyIdentity
        )
    }

    fileprivate func domainValue() throws -> RemoteFinalizationDayV1 {
        try RemoteFinalizationDayV1(
            ordinal: ordinal,
            status: status == .points ? .points : .unavailable,
            source: source == .acceptedRevision
                ? .acceptedRevision
                : .deadlineMissing,
            points: centiPoints,
            reason: reason,
            wireContentSHA256: wireContentSHA256,
            clientRevision: clientRevision,
            serverSequence: serverSequence
        )
    }
}

struct CompetitionFrozenParticipantWindow: Codable, Equatable, Sendable {
    let profileID: UUID
    let totalCentiPoints: Int
    let windowCommitmentSHA256: String
    let days: [CompetitionFrozenDay]

    init(
        profileID: UUID,
        totalCentiPoints: Int,
        windowCommitmentSHA256: String,
        days: [CompetitionFrozenDay]
    ) throws {
        guard CompetitionWireValue.validUUID(profileID),
              (0...420_000).contains(totalCentiPoints),
              CompetitionWireValue.validDigest(windowCommitmentSHA256),
              days.map(\.ordinal) == Array(1...7),
              days.compactMap(\.centiPoints).reduce(0, +)
                  == totalCentiPoints
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.profileID = profileID
        self.totalCentiPoints = totalCentiPoints
        self.windowCommitmentSHA256 = windowCommitmentSHA256
        self.days = days
    }

    private enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case totalCentiPoints = "total_centi_points"
        case windowCommitmentSHA256 = "window_commitment_sha256"
        case days
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            profileID: try container.wireUUID(forKey: .profileID),
            totalCentiPoints: try container.decode(
                Int.self,
                forKey: .totalCentiPoints
            ),
            windowCommitmentSHA256: try container.decode(
                String.self,
                forKey: .windowCommitmentSHA256
            ),
            days: try container.decode(
                [CompetitionFrozenDay].self,
                forKey: .days
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeWireUUID(profileID, forKey: .profileID)
        try container.encode(totalCentiPoints, forKey: .totalCentiPoints)
        try container.encode(
            windowCommitmentSHA256,
            forKey: .windowCommitmentSHA256
        )
        try container.encode(days, forKey: .days)
    }

    fileprivate func validateCommitment(competitionID: UUID) throws {
        let expected = try RemoteFinalizationWireV1.windowCommitment(
            competitionID: competitionID,
            participantID: profileID,
            days: try days.map { try $0.domainValue() }
        )
        guard expected == windowCommitmentSHA256 else {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }
}

struct CompetitionFrozenWindow: Codable, Equatable, Sendable {
    static let version = 2

    let policy: String
    let participants: [CompetitionFrozenParticipantWindow]

    init(
        version: Int = Self.version,
        policy: String,
        participants: [CompetitionFrozenParticipantWindow]
    ) throws {
        guard version == Self.version,
              policy == RemoteScoringWireV1.policyIdentity,
              participants.count == 2,
              participants[0].profileID.uuidString.lowercased()
                  < participants[1].profileID.uuidString.lowercased()
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.policy = policy
        self.participants = participants
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case policy
        case participants
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: try container.decode(Int.self, forKey: .version),
            policy: try container.decode(String.self, forKey: .policy),
            participants: try container.decode(
                [CompetitionFrozenParticipantWindow].self,
                forKey: .participants
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .version)
        try container.encode(policy, forKey: .policy)
        try container.encode(participants, forKey: .participants)
    }
}

enum CompetitionResultOutcome: String, Codable, Equatable, Sendable {
    case winner
    case tie
}

struct CompetitionResultChange: Codable, Equatable, Sendable {
    let participantAProfileID: UUID
    let participantBProfileID: UUID
    let participantATotalCentiPoints: Int
    let participantBTotalCentiPoints: Int
    let winnerProfileID: UUID?
    let outcome: CompetitionResultOutcome
    let finalizationBasis: CompetitionAttestationBasis
    let completedAt: Date
    let frozenWindow: CompetitionFrozenWindow
    let immutableHash: String
    let serverSequence: Int64

    init(
        participantAProfileID: UUID,
        participantBProfileID: UUID,
        participantATotalCentiPoints: Int,
        participantBTotalCentiPoints: Int,
        winnerProfileID: UUID?,
        outcome: CompetitionResultOutcome,
        finalizationBasis: CompetitionAttestationBasis,
        completedAt: Date,
        frozenWindow: CompetitionFrozenWindow,
        immutableHash: String,
        serverSequence: Int64
    ) throws {
        guard CompetitionWireValue.validUUID(participantAProfileID),
              CompetitionWireValue.validUUID(participantBProfileID),
              participantAProfileID.uuidString.lowercased()
                  < participantBProfileID.uuidString.lowercased(),
              (0...420_000).contains(participantATotalCentiPoints),
              (0...420_000).contains(participantBTotalCentiPoints),
              CompetitionWireValue.validDigest(immutableHash),
              serverSequence > 0,
              completedAt.timeIntervalSinceReferenceDate.isFinite,
              frozenWindow.participants.map(\.profileID)
                  == [participantAProfileID, participantBProfileID],
              frozenWindow.participants.map(\.totalCentiPoints)
                  == [
                      participantATotalCentiPoints,
                      participantBTotalCentiPoints,
                  ],
              Self.validOutcome(
                  outcome,
                  winnerProfileID: winnerProfileID,
                  participantAProfileID: participantAProfileID,
                  participantBProfileID: participantBProfileID,
                  totalA: participantATotalCentiPoints,
                  totalB: participantBTotalCentiPoints
              )
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.participantAProfileID = participantAProfileID
        self.participantBProfileID = participantBProfileID
        self.participantATotalCentiPoints = participantATotalCentiPoints
        self.participantBTotalCentiPoints = participantBTotalCentiPoints
        self.winnerProfileID = winnerProfileID
        self.outcome = outcome
        self.finalizationBasis = finalizationBasis
        self.completedAt = completedAt
        self.frozenWindow = frozenWindow
        self.immutableHash = immutableHash
        self.serverSequence = serverSequence
    }

    private enum CodingKeys: String, CodingKey {
        case participantAProfileID = "participant_a_profile_id"
        case participantBProfileID = "participant_b_profile_id"
        case participantATotalCentiPoints =
            "participant_a_total_centi_points"
        case participantBTotalCentiPoints =
            "participant_b_total_centi_points"
        case winnerProfileID = "winner_profile_id"
        case outcome
        case finalizationBasis = "finalization_basis"
        case completedAt = "completed_at"
        case frozenWindow = "frozen_window"
        case immutableHash = "immutable_hash"
        case serverSequence = "server_seq"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            participantAProfileID: try container.wireUUID(
                forKey: .participantAProfileID
            ),
            participantBProfileID: try container.wireUUID(
                forKey: .participantBProfileID
            ),
            participantATotalCentiPoints: try container.decode(
                Int.self,
                forKey: .participantATotalCentiPoints
            ),
            participantBTotalCentiPoints: try container.decode(
                Int.self,
                forKey: .participantBTotalCentiPoints
            ),
            winnerProfileID: try container.wireUUIDIfPresent(
                forKey: .winnerProfileID
            ),
            outcome: try container.decode(
                CompetitionResultOutcome.self,
                forKey: .outcome
            ),
            finalizationBasis: try container.decode(
                CompetitionAttestationBasis.self,
                forKey: .finalizationBasis
            ),
            completedAt: try container.wireDate(forKey: .completedAt),
            frozenWindow: try container.decode(
                CompetitionFrozenWindow.self,
                forKey: .frozenWindow
            ),
            immutableHash: try container.decode(
                String.self,
                forKey: .immutableHash
            ),
            serverSequence: try container.wireInt64(
                forKey: .serverSequence
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeWireUUID(
            participantAProfileID,
            forKey: .participantAProfileID
        )
        try container.encodeWireUUID(
            participantBProfileID,
            forKey: .participantBProfileID
        )
        try container.encode(
            participantATotalCentiPoints,
            forKey: .participantATotalCentiPoints
        )
        try container.encode(
            participantBTotalCentiPoints,
            forKey: .participantBTotalCentiPoints
        )
        try container.encodeWireUUIDIfPresent(
            winnerProfileID,
            forKey: .winnerProfileID
        )
        try container.encode(outcome, forKey: .outcome)
        try container.encode(finalizationBasis, forKey: .finalizationBasis)
        try container.encodeWireDate(completedAt, forKey: .completedAt)
        try container.encode(frozenWindow, forKey: .frozenWindow)
        try container.encode(immutableHash, forKey: .immutableHash)
        try container.encodeWireInt64(serverSequence, forKey: .serverSequence)
    }

    fileprivate func validate(competitionID: UUID) throws {
        for participant in frozenWindow.participants {
            try participant.validateCommitment(competitionID: competitionID)
        }
        let expected = try RemoteFinalizationWireV1.resultHash(
            competitionID: competitionID,
            participantA: participantAProfileID,
            totalA: participantATotalCentiPoints,
            commitmentA: frozenWindow.participants[0]
                .windowCommitmentSHA256,
            participantB: participantBProfileID,
            totalB: participantBTotalCentiPoints,
            commitmentB: frozenWindow.participants[1]
                .windowCommitmentSHA256,
            outcome: outcome.rawValue,
            winner: winnerProfileID,
            basis: finalizationBasis.rawValue
        )
        guard expected == immutableHash else {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    private static func validOutcome(
        _ outcome: CompetitionResultOutcome,
        winnerProfileID: UUID?,
        participantAProfileID: UUID,
        participantBProfileID: UUID,
        totalA: Int,
        totalB: Int
    ) -> Bool {
        switch outcome {
        case .tie:
            return totalA == totalB && winnerProfileID == nil
        case .winner:
            guard totalA != totalB else { return false }
            return winnerProfileID
                == (totalA > totalB
                    ? participantAProfileID
                    : participantBProfileID)
        }
    }
}

enum CompetitionAwardType: String, Codable, Equatable, Sendable {
    case competitionWin = "competition_win"
    case sevenDayFinisher = "seven_day_finisher"
}

struct CompetitionAwardChange: Codable, Equatable, Sendable {
    let profileID: UUID
    let type: CompetitionAwardType
    let serverSequence: Int64
    let earnedAt: Date

    init(
        profileID: UUID,
        type: CompetitionAwardType,
        serverSequence: Int64,
        earnedAt: Date
    ) throws {
        guard CompetitionWireValue.validUUID(profileID),
              serverSequence > 0,
              earnedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.profileID = profileID
        self.type = type
        self.serverSequence = serverSequence
        self.earnedAt = earnedAt
    }

    private enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case type = "award_type"
        case serverSequence = "server_seq"
        case earnedAt = "earned_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            profileID: try container.wireUUID(forKey: .profileID),
            type: try container.decode(
                CompetitionAwardType.self,
                forKey: .type
            ),
            serverSequence: try container.wireInt64(
                forKey: .serverSequence
            ),
            earnedAt: try container.wireDate(forKey: .earnedAt)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeWireUUID(profileID, forKey: .profileID)
        try container.encode(type, forKey: .type)
        try container.encodeWireInt64(serverSequence, forKey: .serverSequence)
        try container.encodeWireDate(earnedAt, forKey: .earnedAt)
    }
}

enum CompetitionChangePayload: Equatable, Sendable {
    case participant(CompetitionParticipantChange)
    case lifecycle(CompetitionLifecycleChange)
    case profilePresentation(CompetitionProfilePresentationChange)
    case score(CompetitionScoreChange)
    case participantAttestation(CompetitionParticipantAttestationChange)
    case result(CompetitionResultChange)
    case award(CompetitionAwardChange)
}

struct CompetitionChange: Codable, Equatable, Sendable {
    let serverSequence: Int64
    let kind: CompetitionChangeKind
    let entityID: UUID
    let occurredAt: Date
    let payload: CompetitionChangePayload

    init(
        serverSequence: Int64,
        kind: CompetitionChangeKind,
        entityID: UUID,
        occurredAt: Date,
        payload: CompetitionChangePayload
    ) throws {
        guard serverSequence > 0,
              CompetitionWireValue.validUUID(entityID),
              occurredAt.timeIntervalSinceReferenceDate.isFinite,
              Self.payloadMatches(kind: kind, payload: payload)
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        self.serverSequence = serverSequence
        self.kind = kind
        self.entityID = entityID
        self.occurredAt = occurredAt
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case serverSequence = "server_seq"
        case kind
        case entityID = "entity_id"
        case occurredAt = "occurred_at"
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(CompetitionChangeKind.self, forKey: .kind)
        let payload: CompetitionChangePayload
        switch kind {
        case .participantAdded, .participantStateChanged:
            payload = .participant(
                try container.decode(
                    CompetitionParticipantChange.self,
                    forKey: .payload
                )
            )
        case .competitionLifecycleChanged:
            payload = .lifecycle(
                try container.decode(
                    CompetitionLifecycleChange.self,
                    forKey: .payload
                )
            )
        case .profilePresentationChanged, .profileAnonymized:
            payload = .profilePresentation(
                try container.decode(
                    CompetitionProfilePresentationChange.self,
                    forKey: .payload
                )
            )
        case .scoreRevisionRecorded:
            payload = .score(
                try container.decode(
                    CompetitionScoreChange.self,
                    forKey: .payload
                )
            )
        case .participantAttested:
            payload = .participantAttestation(
                try container.decode(
                    CompetitionParticipantAttestationChange.self,
                    forKey: .payload
                )
            )
        case .competitionResultConfirmed:
            payload = .result(
                try container.decode(
                    CompetitionResultChange.self,
                    forKey: .payload
                )
            )
        case .competitionAwardEarned:
            payload = .award(
                try container.decode(
                    CompetitionAwardChange.self,
                    forKey: .payload
                )
            )
        }
        try self.init(
            serverSequence: try container.wireInt64(forKey: .serverSequence),
            kind: kind,
            entityID: try container.wireUUID(forKey: .entityID),
            occurredAt: try container.wireDate(forKey: .occurredAt),
            payload: payload
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeWireInt64(serverSequence, forKey: .serverSequence)
        try container.encode(kind, forKey: .kind)
        try container.encodeWireUUID(entityID, forKey: .entityID)
        try container.encodeWireDate(occurredAt, forKey: .occurredAt)
        switch payload {
        case let .participant(value):
            try container.encode(value, forKey: .payload)
        case let .lifecycle(value):
            try container.encode(value, forKey: .payload)
        case let .profilePresentation(value):
            try container.encode(value, forKey: .payload)
        case let .score(value):
            try container.encode(value, forKey: .payload)
        case let .participantAttestation(value):
            try container.encode(value, forKey: .payload)
        case let .result(value):
            try container.encode(value, forKey: .payload)
        case let .award(value):
            try container.encode(value, forKey: .payload)
        }
    }

    private static func payloadMatches(
        kind: CompetitionChangeKind,
        payload: CompetitionChangePayload
    ) -> Bool {
        switch (kind, payload) {
        case (.participantAdded, .participant),
             (.participantStateChanged, .participant),
             (.competitionLifecycleChanged, .lifecycle),
             (.profilePresentationChanged, .profilePresentation),
             (.profileAnonymized, .profilePresentation),
             (.scoreRevisionRecorded, .score),
             (.participantAttested, .participantAttestation),
             (.competitionResultConfirmed, .result),
             (.competitionAwardEarned, .award):
            true
        default:
            false
        }
    }
}

struct CompetitionChangePage: Codable, Equatable, Sendable {
    let competitionID: UUID
    let afterServerSequence: Int64
    let snapshotServerSequence: Int64
    let nextServerSequence: Int64
    let hasMore: Bool
    let changes: [CompetitionChange]

    init(
        competitionID: UUID,
        afterServerSequence: Int64,
        snapshotServerSequence: Int64,
        nextServerSequence: Int64,
        hasMore: Bool,
        changes: [CompetitionChange]
    ) throws {
        guard CompetitionWireValue.validUUID(competitionID),
              afterServerSequence >= 0,
              snapshotServerSequence >= afterServerSequence,
              nextServerSequence >= afterServerSequence,
              nextServerSequence <= snapshotServerSequence,
              hasMore == (nextServerSequence < snapshotServerSequence),
              changes.count <= 200,
              !changes.isEmpty
                  || nextServerSequence == snapshotServerSequence
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        let sequenceSpan = nextServerSequence - afterServerSequence
        guard sequenceSpan == Int64(changes.count),
              changes.enumerated().allSatisfy({ offset, change in
                  change.serverSequence
                      == afterServerSequence + Int64(offset) + 1
              }),
              nextServerSequence
                  == (changes.last?.serverSequence ?? afterServerSequence)
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }

        for change in changes {
            try Self.validate(change, competitionID: competitionID)
        }
        self.competitionID = competitionID
        self.afterServerSequence = afterServerSequence
        self.snapshotServerSequence = snapshotServerSequence
        self.nextServerSequence = nextServerSequence
        self.hasMore = hasMore
        self.changes = changes
    }

    private enum CodingKeys: String, CodingKey {
        case competitionID = "competition_id"
        case afterServerSequence = "after_server_seq"
        case snapshotServerSequence = "snapshot_server_seq"
        case nextServerSequence = "next_server_seq"
        case hasMore = "has_more"
        case changes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            competitionID: try container.wireUUID(forKey: .competitionID),
            afterServerSequence: try container.wireInt64(
                forKey: .afterServerSequence,
                allowZero: true
            ),
            snapshotServerSequence: try container.wireInt64(
                forKey: .snapshotServerSequence,
                allowZero: true
            ),
            nextServerSequence: try container.wireInt64(
                forKey: .nextServerSequence,
                allowZero: true
            ),
            hasMore: try container.decode(Bool.self, forKey: .hasMore),
            changes: try container.decode(
                [CompetitionChange].self,
                forKey: .changes
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeWireUUID(competitionID, forKey: .competitionID)
        try container.encodeWireInt64(
            afterServerSequence,
            forKey: .afterServerSequence
        )
        try container.encodeWireInt64(
            snapshotServerSequence,
            forKey: .snapshotServerSequence
        )
        try container.encodeWireInt64(
            nextServerSequence,
            forKey: .nextServerSequence
        )
        try container.encode(hasMore, forKey: .hasMore)
        try container.encode(changes, forKey: .changes)
    }

    private static func validate(
        _ change: CompetitionChange,
        competitionID: UUID
    ) throws {
        switch change.payload {
        case let .participant(value):
            guard change.entityID == value.profileID else {
                throw CompetitionWireContractError.serverContractMismatch
            }
        case .lifecycle:
            guard change.entityID == competitionID else {
                throw CompetitionWireContractError.serverContractMismatch
            }
        case let .profilePresentation(value):
            guard change.entityID == value.profileID,
                  change.kind != .profileAnonymized
                      || value.displayName == "Former competitor",
                  change.kind != .profilePresentationChanged
                      || value.displayName != "Former competitor"
            else {
                throw CompetitionWireContractError.serverContractMismatch
            }
        case let .score(value):
            guard value.serverSequence == change.serverSequence else {
                throw CompetitionWireContractError.serverContractMismatch
            }
            let wire = try RemoteScoreRevisionWireV1(
                competitionID: competitionID,
                participantID: value.participantProfileID,
                dayOrdinal: value.dayOrdinal,
                moveMode: value.moveMode,
                standMode: value.standMode,
                moveBasisPoints: value.moveBasisPoints,
                exerciseBasisPoints: value.exerciseBasisPoints,
                standBasisPoints: value.standBasisPoints,
                availabilityReason: value.availabilityReason,
                scoringPolicyIdentity: value.scoringPolicyIdentity,
                clientRevision: value.clientRevision
            )
            guard wire.acceptedCentiPoints == value.acceptedCentiPoints,
                  wire.wireContentSHA256 == value.wireContentSHA256
            else {
                throw CompetitionWireContractError.serverContractMismatch
            }
        case let .participantAttestation(value):
            guard value.serverSequence == change.serverSequence else {
                throw CompetitionWireContractError.serverContractMismatch
            }
        case let .result(value):
            guard change.entityID == competitionID,
                  value.serverSequence == change.serverSequence
            else {
                throw CompetitionWireContractError.serverContractMismatch
            }
            try value.validate(competitionID: competitionID)
        case let .award(value):
            guard value.serverSequence == change.serverSequence else {
                throw CompetitionWireContractError.serverContractMismatch
            }
        }
    }
}

private enum CompetitionWireValue {
    static let nilUUID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!
    static let unavailableReasons: Set<String> = [
        "sourceDataUnavailable",
        "unsupportedActivityConfiguration",
        "invalidSourceData",
        "missingMoveValue",
        "missingMoveGoal",
        "nonPositiveMoveGoal",
        "missingExerciseValue",
        "missingExerciseGoal",
        "nonPositiveExerciseGoal",
        "missingStandOrRollValue",
        "missingStandOrRollGoal",
        "nonPositiveStandOrRollGoal",
        "summaryPaused",
        "summaryPauseStateUnknown",
        "invalidNumericCalculation",
    ]

    static func validUUID(_ value: UUID) -> Bool {
        value != nilUUID
    }

    static func uuid(_ value: String) throws -> UUID {
        guard value == value.lowercased(),
              let uuid = UUID(uuidString: value),
              validUUID(uuid)
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        return uuid
    }

    static func validDigest(_ value: String) -> Bool {
        value.range(
            of: "^[0-9a-f]{64}$",
            options: .regularExpression
        ) != nil
    }

    static func validPresentationName(_ value: String) -> Bool {
        value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && (1...64).contains(value.count)
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    static func validDay(_ value: String) -> Bool {
        guard value.range(
            of: #"^\d{4}-\d{2}-\d{2}$"#,
            options: .regularExpression
        ) != nil else { return false }
        return dayFormatter.date(from: value) != nil
    }

    static func validInviteToken(_ value: String) -> Bool {
        guard value.range(
            of: "^[A-Za-z0-9_-]{43}$",
            options: .regularExpression
        ) != nil else { return false }
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += "="
        return Data(base64Encoded: normalized)?.count == 32
    }

    static func int64(_ value: String, allowZero: Bool) throws -> Int64 {
        let pattern = allowZero
            ? "^(0|[1-9][0-9]{0,18})$"
            : "^[1-9][0-9]{0,18}$"
        guard value.range(of: pattern, options: .regularExpression) != nil,
              let number = Int64(value),
              allowZero ? number >= 0 : number > 0
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        return number
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()
}

private extension KeyedDecodingContainer {
    func wireUUID(forKey key: Key) throws -> UUID {
        try CompetitionWireValue.uuid(
            decode(String.self, forKey: key)
        )
    }

    func wireUUIDIfPresent(forKey key: Key) throws -> UUID? {
        guard let value = try decodeIfPresent(String.self, forKey: key)
        else { return nil }
        return try CompetitionWireValue.uuid(value)
    }

    func wireInt64(forKey key: Key, allowZero: Bool = false) throws -> Int64 {
        try CompetitionWireValue.int64(
            decode(String.self, forKey: key),
            allowZero: allowZero
        )
    }

    func wireInt64IfPresent(
        forKey key: Key,
        allowZero: Bool = false
    ) throws -> Int64? {
        guard let value = try decodeIfPresent(String.self, forKey: key)
        else { return nil }
        return try CompetitionWireValue.int64(value, allowZero: allowZero)
    }

    func wireInt64Array(
        forKey key: Key,
        allowZero: Bool = false
    ) throws -> [Int64] {
        try decode([String].self, forKey: key).map {
            try CompetitionWireValue.int64($0, allowZero: allowZero)
        }
    }

    func wireDate(forKey key: Key) throws -> Date {
        try CompetitionWireCodec.date(decode(String.self, forKey: key))
    }

    func wireDateIfPresent(forKey key: Key) throws -> Date? {
        guard let value = try decodeIfPresent(String.self, forKey: key)
        else { return nil }
        return try CompetitionWireCodec.date(value)
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeWireUUID(_ value: UUID, forKey key: Key) throws {
        try encode(value.uuidString.lowercased(), forKey: key)
    }

    mutating func encodeWireUUIDIfPresent(
        _ value: UUID?,
        forKey key: Key
    ) throws {
        if let value {
            try encodeWireUUID(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }

    mutating func encodeWireInt64(_ value: Int64, forKey key: Key) throws {
        try encode(String(value), forKey: key)
    }

    mutating func encodeWireInt64IfPresent(
        _ value: Int64?,
        forKey key: Key
    ) throws {
        if let value {
            try encodeWireInt64(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }

    mutating func encodeWireDate(_ value: Date, forKey key: Key) throws {
        try encode(CompetitionWireCodec.timestamp(value), forKey: key)
    }

    mutating func encodeWireDateIfPresent(
        _ value: Date?,
        forKey key: Key
    ) throws {
        if let value {
            try encodeWireDate(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}

private enum CompetitionWireValidator {
    private static let forbiddenFingerprintPrefixes = [
        "activity-snapshot:",
        "accepted-activity-score:",
        "live-day-score:",
    ]

    static func validate(
        _ value: Any,
        contract: CompetitionWireContract
    ) throws {
        guard !containsForbiddenPrivacyValue(value) else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        switch contract {
        case .profile:
            try validateProfile(value)
        case .competitionDescriptor:
            try validateCompetitionDescriptor(value)
        case .inviteCreationRequest:
            try validateInviteCreationRequest(value)
        case .inviteCreationResponse:
            try validateInviteCreationResponse(value)
        case .inviteClaimRequest:
            try validateInviteClaimRequest(value)
        case .inviteClaimResponse:
            try validateInviteClaimResponse(value)
        case .scoreRevisionRequest:
            try validateScoreRequest(value)
        case .scoreRevisionResponse:
            try validateScoreResponse(value)
        case .attestationRequest:
            try validateAttestationRequest(value)
        case .attestationResponse:
            try validateAttestationResponse(value)
        case .changePage:
            try validateChangePage(value)
        case .installationRequest:
            try validateInstallationRequest(value)
        case .installationResponse:
            try validateInstallationResponse(value)
        case .synchronizationCursor:
            try validateSynchronizationCursor(value)
        }
    }

    static func isTimestamp(_ value: String) -> Bool {
        value.range(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$"#,
            options: .regularExpression
        ) != nil
    }

    private static func validateProfile(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: ["display_name", "id"]
        )
        guard let id = object["id"] as? String,
              validUUID(id),
              let displayName = object["display_name"] as? String,
              validDisplayName(displayName)
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    private static func validateCompetitionDescriptor(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: [
                "best_available_deadline",
                "creator_profile_id",
                "id",
                "invitation_expires_at",
                "lifecycle",
                "next_server_seq",
                "participants",
                "rematch_parent_id",
                "scoring_policy_identity",
                "start_day",
                "time_zone_identifier",
            ]
        )
        guard uuid(object["id"]),
              uuid(object["creator_profile_id"]),
              stringOrNull(object["time_zone_identifier"]),
              dayOrNull(object["start_day"]),
              object["scoring_policy_identity"] as? String
                  == RemoteScoringWireV1.policyIdentity,
              enumValue(object["lifecycle"], CompetitionRemoteLifecycle.self),
              timestamp(object["invitation_expires_at"]),
              timestampOrNull(object["best_available_deadline"]),
              uuidOrNull(object["rematch_parent_id"]),
              let nextServerSequence = integer(object["next_server_seq"]),
              nextServerSequence > 0,
              let participants = object["participants"] as? [Any],
              (1...2).contains(participants.count)
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }

        for participantValue in participants {
            let participant = try exactObject(
                participantValue,
                keys: ["profile", "profile_id", "role", "state"]
            )
            guard uuid(participant["profile_id"]),
                  enumValue(
                      participant["role"],
                      CompetitionParticipantRole.self
                  ),
                  let stateValue = participant["state"] as? String,
                  let state = CompetitionParticipantState(
                      rawValue: stateValue
                  )
            else {
                throw CompetitionWireContractError.serverContractMismatch
            }
            let profile = try exactObject(
                participant["profile"] as Any,
                keys: ["display_name", "id"]
            )
            guard uuid(profile["id"]),
                  profile["id"] as? String
                      == participant["profile_id"] as? String,
                  let displayName = profile["display_name"] as? String,
                  CompetitionWireValue.validPresentationName(displayName),
                  state == .anonymized
                      ? displayName == "Former competitor"
                      : displayName != "Former competitor"
            else {
                throw CompetitionWireContractError.serverContractMismatch
            }
        }
    }

    private static func validateInviteCreationRequest(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: ["idempotencyKey", "rematchParentId", "timeZoneIdentifier"]
        )
        guard let timeZone = object["timeZoneIdentifier"] as? String,
              !timeZone.isEmpty,
              timeZone.count <= 255,
              uuidOrNull(object["rematchParentId"]),
              uuid(object["idempotencyKey"])
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    private static func validateInviteCreationResponse(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: ["competitionId", "token"]
        )
        guard uuid(object["competitionId"]),
              let token = object["token"] as? String,
              CompetitionWireValue.validInviteToken(token)
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    private static func validateInviteClaimRequest(_ value: Any) throws {
        let object = try exactObject(value, keys: ["token"])
        guard let token = object["token"] as? String,
              CompetitionWireValue.validInviteToken(token)
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    private static func validateInviteClaimResponse(_ value: Any) throws {
        let object = try exactObject(value, keys: ["competitionId"])
        guard uuid(object["competitionId"]) else {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    private static func validateScoreRequest(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: [
                "availabilityReason",
                "clientRevision",
                "competitionId",
                "dayOrdinal",
                "evaluatedAt",
                "exerciseBasisPoints",
                "moveBasisPoints",
                "moveMode",
                "scoringPolicyIdentity",
                "semanticEventId",
                "standBasisPoints",
                "standMode",
                "version",
                "wireContentSHA256",
            ]
        )
        guard integer(object["version"]) == 1,
              let competitionID = object["competitionId"] as? String,
              validUUID(competitionID),
              let semanticEventID = object["semanticEventId"] as? String,
              validUUID(semanticEventID),
              let ordinal = integer(object["dayOrdinal"]),
              (1...7).contains(ordinal),
              let revision = object["clientRevision"] as? String,
              positiveInt64(revision),
              let evaluatedAt = object["evaluatedAt"] as? String,
              isTimestamp(evaluatedAt),
              let moveMode = object["moveMode"] as? String,
              CompetitionScoreRevisionRequest.moveModes.contains(moveMode),
              let standMode = object["standMode"] as? String,
              CompetitionScoreRevisionRequest.standModes.contains(standMode),
              let reason = object["availabilityReason"] as? String,
              object["scoringPolicyIdentity"] as? String
                  == "healthcomp.activity-score.v1",
              let digest = object["wireContentSHA256"] as? String,
              CompetitionScoreRevisionRequest.isDigest(digest)
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }

        let values = [
            object["moveBasisPoints"],
            object["exerciseBasisPoints"],
            object["standBasisPoints"],
        ]
        if reason == "available" {
            guard standMode != "unknown",
                  values.allSatisfy({ value in
                      guard let points = integer(value) else { return false }
                      return (0...20_000).contains(points)
                  })
            else {
                throw CompetitionWireContractError.serverContractMismatch
            }
        } else {
            guard CompetitionScoreRevisionRequest.unavailableReasons
                .contains(reason),
                values.allSatisfy({ $0 is NSNull })
            else {
                throw CompetitionWireContractError.serverContractMismatch
            }
        }
    }

    private static func validateScoreResponse(_ value: Any) throws {
        guard let preliminary = value as? [String: Any],
              let dispositionValue = preliminary["disposition"] as? String,
              let disposition = CompetitionScoreRevisionDisposition(
                  rawValue: dispositionValue
              )
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        let object: [String: Any]
        switch disposition {
        case .appended, .duplicate:
            object = try exactObject(
                value,
                keys: [
                    "acceptedCentiPoints",
                    "acceptedServerSeq",
                    "competitionCursor",
                    "disposition",
                    "wireContentSHA256",
                ]
            )
        case .rejected:
            object = try exactObject(
                value,
                keys: [
                    "acceptedCentiPoints",
                    "acceptedServerSeq",
                    "code",
                    "competitionCursor",
                    "disposition",
                    "wireContentSHA256",
                ]
            )
            guard enumValue(
                object["code"],
                CompetitionScoreRevisionRejectionCode.self
            ) else {
                throw CompetitionWireContractError.serverContractMismatch
            }
        }
        guard integerOrNull(object["acceptedCentiPoints"]),
              digestOrNull(object["wireContentSHA256"]),
              wireInt64OrNull(object["acceptedServerSeq"]),
              wireInt64(object["competitionCursor"], allowZero: true)
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    private static func validateAttestationRequest(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: [
                "acceptedRevisions",
                "attestationVersion",
                "basis",
                "competitionId",
                "semanticEventId",
                "version",
                "windowCommitmentSHA256",
            ]
        )
        guard integer(object["version"]) == 1,
              uuid(object["competitionId"]),
              uuid(object["semanticEventId"]),
              wireInt64(object["attestationVersion"]),
              enumValue(object["basis"], CompetitionAttestationBasis.self),
              let revisions = object["acceptedRevisions"] as? [Any],
              revisions.count == 7,
              revisions.allSatisfy({ wireInt64($0, allowZero: true) }),
              digest(object["windowCommitmentSHA256"])
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    private static func validateAttestationResponse(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: ["disposition", "serverCursor", "windowCommitmentSHA256"]
        )
        guard enumValue(
                  object["disposition"],
                  CompetitionMutationDisposition.self
              ),
              digest(object["windowCommitmentSHA256"]),
              wireInt64(object["serverCursor"])
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    private static func validateInstallationRequest(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: ["apns_token", "environment", "installation_id"]
        )
        guard uuid(object["installation_id"]),
              let token = object["apns_token"] as? String,
              token.range(
                  of: "^[0-9a-f]{64,200}$",
                  options: .regularExpression
              ) != nil,
              enumValue(
                  object["environment"],
                  CompetitionInstallationEnvironment.self
              )
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    private static func validateInstallationResponse(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: ["environment", "installation_id", "state"]
        )
        guard uuid(object["installation_id"]),
              enumValue(
                  object["environment"],
                  CompetitionInstallationEnvironment.self
              ),
              enumValue(object["state"], CompetitionInstallationState.self)
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    private static func validateSynchronizationCursor(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: ["competition_id", "last_seen_server_seq"]
        )
        guard uuid(object["competition_id"]),
              wireInt64(object["last_seen_server_seq"], allowZero: true)
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    private static func validateChangePage(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: [
                "after_server_seq",
                "changes",
                "competition_id",
                "has_more",
                "next_server_seq",
                "snapshot_server_seq",
            ]
        )
        guard uuid(object["competition_id"]),
              wireInt64(object["after_server_seq"], allowZero: true),
              wireInt64(object["snapshot_server_seq"], allowZero: true),
              wireInt64(object["next_server_seq"], allowZero: true),
              boolean(object["has_more"]),
              let changes = object["changes"] as? [Any],
              changes.count <= 200
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        for value in changes {
            try validateChange(value)
        }
    }

    private static func validateChange(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: ["entity_id", "kind", "occurred_at", "payload", "server_seq"]
        )
        guard wireInt64(object["server_seq"]),
              uuid(object["entity_id"]),
              timestamp(object["occurred_at"]),
              let kindValue = object["kind"] as? String,
              let kind = CompetitionChangeKind(rawValue: kindValue)
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        switch kind {
        case .participantAdded, .participantStateChanged:
            try validateParticipantPayload(object["payload"] as Any)
        case .competitionLifecycleChanged:
            try validateLifecyclePayload(object["payload"] as Any)
        case .profilePresentationChanged, .profileAnonymized:
            try validateProfilePayload(object["payload"] as Any)
        case .scoreRevisionRecorded:
            try validateScorePayload(object["payload"] as Any)
        case .participantAttested:
            try validateAttestationPayload(object["payload"] as Any)
        case .competitionResultConfirmed:
            try validateResultPayload(object["payload"] as Any)
        case .competitionAwardEarned:
            try validateAwardPayload(object["payload"] as Any)
        }
    }

    private static func validateParticipantPayload(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: ["profile_id", "role", "state"]
        )
        guard uuid(object["profile_id"]),
              enumValue(object["role"], CompetitionParticipantRole.self),
              enumValue(object["state"], CompetitionParticipantState.self)
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    private static func validateLifecyclePayload(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: [
                "best_available_deadline",
                "lifecycle",
                "scoring_policy_identity",
                "start_day",
                "time_zone_identifier",
            ]
        )
        guard enumValue(
                  object["lifecycle"],
                  CompetitionRemoteLifecycle.self
              ),
              stringOrNull(object["time_zone_identifier"]),
              dayOrNull(object["start_day"]),
              timestampOrNull(object["best_available_deadline"]),
              object["scoring_policy_identity"] as? String
                  == RemoteScoringWireV1.policyIdentity
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    private static func validateProfilePayload(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: ["display_name", "profile_id"]
        )
        guard uuid(object["profile_id"]),
              let displayName = object["display_name"] as? String,
              CompetitionWireValue.validPresentationName(displayName)
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    private static func validateScorePayload(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: [
                "accepted_centi_points",
                "availability_reason",
                "client_revision",
                "day_ordinal",
                "evaluated_at",
                "exercise_basis_points",
                "move_basis_points",
                "move_mode",
                "participant_profile_id",
                "scoring_policy_identity",
                "server_seq",
                "stand_basis_points",
                "stand_mode",
                "wire_content_sha256",
                "wire_digest_version",
            ]
        )
        guard uuid(object["participant_profile_id"]),
              let ordinal = integer(object["day_ordinal"]),
              (1...7).contains(ordinal),
              wireInt64(object["client_revision"]),
              let moveMode = object["move_mode"] as? String,
              CompetitionScoreRevisionRequest.moveModes.contains(moveMode),
              let standMode = object["stand_mode"] as? String,
              CompetitionScoreRevisionRequest.standModes.contains(standMode),
              integerOrNull(object["move_basis_points"]),
              integerOrNull(object["exercise_basis_points"]),
              integerOrNull(object["stand_basis_points"]),
              integerOrNull(object["accepted_centi_points"]),
              object["availability_reason"] is String,
              object["scoring_policy_identity"] as? String
                  == RemoteScoringWireV1.policyIdentity,
              integer(object["wire_digest_version"]) == 1,
              digest(object["wire_content_sha256"]),
              wireInt64(object["server_seq"]),
              timestamp(object["evaluated_at"])
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    private static func validateAttestationPayload(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: [
                "accepted_revisions",
                "attestation_version",
                "attested_at",
                "basis",
                "participant_profile_id",
                "server_seq",
                "window_commitment_sha256",
            ]
        )
        guard uuid(object["participant_profile_id"]),
              enumValue(object["basis"], CompetitionAttestationBasis.self),
              digest(object["window_commitment_sha256"]),
              let revisions = object["accepted_revisions"] as? [Any],
              revisions.count == 7,
              revisions.allSatisfy({ wireInt64($0, allowZero: true) }),
              wireInt64(object["attestation_version"]),
              wireInt64(object["server_seq"]),
              timestamp(object["attested_at"])
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    private static func validateResultPayload(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: [
                "completed_at",
                "finalization_basis",
                "frozen_window",
                "immutable_hash",
                "outcome",
                "participant_a_profile_id",
                "participant_a_total_centi_points",
                "participant_b_profile_id",
                "participant_b_total_centi_points",
                "server_seq",
                "winner_profile_id",
            ]
        )
        guard uuid(object["participant_a_profile_id"]),
              uuid(object["participant_b_profile_id"]),
              integer(object["participant_a_total_centi_points"]) != nil,
              integer(object["participant_b_total_centi_points"]) != nil,
              uuidOrNull(object["winner_profile_id"]),
              enumValue(object["outcome"], CompetitionResultOutcome.self),
              enumValue(
                  object["finalization_basis"],
                  CompetitionAttestationBasis.self
              ),
              timestamp(object["completed_at"]),
              digest(object["immutable_hash"]),
              wireInt64(object["server_seq"])
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        try validateFrozenWindow(object["frozen_window"] as Any)
    }

    private static func validateFrozenWindow(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: ["participants", "policy", "version"]
        )
        guard integer(object["version"]) == 2,
              object["policy"] as? String
                  == RemoteScoringWireV1.policyIdentity,
              let participants = object["participants"] as? [Any],
              participants.count == 2
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        for participantValue in participants {
            let participant = try exactObject(
                participantValue,
                keys: [
                    "days",
                    "profile_id",
                    "total_centi_points",
                    "window_commitment_sha256",
                ]
            )
            guard uuid(participant["profile_id"]),
                  integer(participant["total_centi_points"]) != nil,
                  digest(participant["window_commitment_sha256"]),
                  let days = participant["days"] as? [Any],
                  days.count == 7
            else {
                throw CompetitionWireContractError.serverContractMismatch
            }
            for day in days {
                try validateFrozenDay(day)
            }
        }
    }

    private static func validateFrozenDay(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: [
                "centi_points",
                "client_revision",
                "ordinal",
                "reason",
                "scoring_policy_identity",
                "server_seq",
                "source",
                "status",
                "wire_content_sha256",
            ]
        )
        guard let ordinal = integer(object["ordinal"]),
              (1...7).contains(ordinal),
              enumValue(object["status"], CompetitionFrozenDayStatus.self),
              enumValue(object["source"], CompetitionFrozenDaySource.self),
              integerOrNull(object["centi_points"]),
              stringOrNull(object["reason"]),
              digestOrNull(object["wire_content_sha256"]),
              wireInt64OrNull(object["client_revision"]),
              wireInt64OrNull(object["server_seq"]),
              policyOrNull(object["scoring_policy_identity"])
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    private static func validateAwardPayload(_ value: Any) throws {
        let object = try exactObject(
            value,
            keys: ["award_type", "earned_at", "profile_id", "server_seq"]
        )
        guard uuid(object["profile_id"]),
              enumValue(object["award_type"], CompetitionAwardType.self),
              wireInt64(object["server_seq"]),
              timestamp(object["earned_at"])
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
    }

    private static func enumValue<Value: RawRepresentable>(
        _ value: Any?,
        _ type: Value.Type
    ) -> Bool where Value.RawValue == String {
        guard let value = value as? String else { return false }
        return Value(rawValue: value) != nil
    }

    private static func uuid(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return validUUID(value)
    }

    private static func uuidOrNull(_ value: Any?) -> Bool {
        value is NSNull || uuid(value)
    }

    private static func wireInt64(
        _ value: Any?,
        allowZero: Bool = false
    ) -> Bool {
        guard let value = value as? String else { return false }
        return (try? CompetitionWireValue.int64(
            value,
            allowZero: allowZero
        )) != nil
    }

    private static func wireInt64OrNull(_ value: Any?) -> Bool {
        value is NSNull || wireInt64(value)
    }

    private static func digest(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return CompetitionWireValue.validDigest(value)
    }

    private static func digestOrNull(_ value: Any?) -> Bool {
        value is NSNull || digest(value)
    }

    private static func boolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func integerOrNull(_ value: Any?) -> Bool {
        value is NSNull || integer(value) != nil
    }

    private static func stringOrNull(_ value: Any?) -> Bool {
        value is NSNull || value is String
    }

    private static func dayOrNull(_ value: Any?) -> Bool {
        guard !(value is NSNull) else { return true }
        guard let value = value as? String else { return false }
        return CompetitionWireValue.validDay(value)
    }

    private static func timestamp(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return (try? CompetitionWireCodec.date(value)) != nil
    }

    private static func timestampOrNull(_ value: Any?) -> Bool {
        value is NSNull || timestamp(value)
    }

    private static func policyOrNull(_ value: Any?) -> Bool {
        value is NSNull
            || value as? String == RemoteScoringWireV1.policyIdentity
    }

    private static func exactObject(
        _ value: Any,
        keys: Set<String>
    ) throws -> [String: Any] {
        guard let object = value as? [String: Any],
              Set(object.keys) == keys
        else {
            throw CompetitionWireContractError.serverContractMismatch
        }
        return object
    }

    private static func validUUID(_ value: String) -> Bool {
        guard value == value.lowercased(),
              let uuid = UUID(uuidString: value)
        else { return false }
        return uuid != CompetitionScoreRevisionRequest.nilUUID
    }

    private static func validDisplayName(_ value: String) -> Bool {
        value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && (1...64).contains(value.count)
            && value != "Former competitor"
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int.min),
              double <= Double(Int.max)
        else { return nil }
        return number.intValue
    }

    private static func positiveInt64(_ value: String) -> Bool {
        guard value.range(
            of: "^[1-9][0-9]{0,18}$",
            options: .regularExpression
        ) != nil,
              let integer = Int64(value)
        else { return false }
        return integer > 0
    }

    private static func containsForbiddenPrivacyValue(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            return object.contains { key, nested in
                forbiddenKey(key) || containsForbiddenPrivacyValue(nested)
            }
        }
        if let array = value as? [Any] {
            return array.contains(where: containsForbiddenPrivacyValue)
        }
        guard let string = value as? String else { return false }
        if forbiddenFingerprintPrefixes.contains(where: string.hasPrefix) {
            return true
        }
        guard let decoded = base64DecodedString(string) else { return false }
        return forbiddenFingerprintPrefixes.contains(where: decoded.hasPrefix)
    }

    private static func forbiddenKey(_ value: String) -> Bool {
        let words = value
            .replacingOccurrences(
                of: "([a-z0-9])([A-Z])",
                with: "$1_$2",
                options: .regularExpression
            )
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.contains("fingerprint")
            || words.contains("raw")
            || words.contains("goal")
            || words.contains("blob")
            || words.contains("opaque")
    }

    private static func base64DecodedString(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: normalized),
              let decoded = String(data: data, encoding: .utf8)
        else { return nil }
        return decoded
    }
}
