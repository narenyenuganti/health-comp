import Foundation

// MARK: - Immutable stream origin

public struct CompetitionGenesis: Codable, Equatable, Sendable {
    public static let currentVersion: UInt32 = 1

    public enum ValidationError: Error, Equatable, Sendable {
        case unsupportedVersion(UInt32)
        case invalidDate
        case expiryMustFollowCreation
    }

    public let version: UInt32
    public let competitionID: CompetitionID
    public let direction: InvitationDirection
    public let createdAt: Date
    public let expiresAt: Date?
    public let scoringPolicy: ActivityScoringPolicy
    public let downwardRevisionPolicy: DownwardRevisionPolicy

    public init(
        competitionID: CompetitionID,
        direction: InvitationDirection,
        createdAt: Date,
        expiresAt: Date?,
        scoringPolicy: ActivityScoringPolicy,
        downwardRevisionPolicy: DownwardRevisionPolicy
    ) throws {
        try self.init(
            version: Self.currentVersion,
            competitionID: competitionID,
            direction: direction,
            createdAt: createdAt,
            expiresAt: expiresAt,
            scoringPolicy: scoringPolicy,
            downwardRevisionPolicy: downwardRevisionPolicy
        )
    }

    private init(
        version: UInt32,
        competitionID: CompetitionID,
        direction: InvitationDirection,
        createdAt: Date,
        expiresAt: Date?,
        scoringPolicy: ActivityScoringPolicy,
        downwardRevisionPolicy: DownwardRevisionPolicy
    ) throws {
        guard version == Self.currentVersion else {
            throw ValidationError.unsupportedVersion(version)
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt?.timeIntervalSinceReferenceDate.isFinite ?? true
        else {
            throw ValidationError.invalidDate
        }
        if let expiresAt, expiresAt <= createdAt {
            throw ValidationError.expiryMustFollowCreation
        }
        self.version = version
        self.competitionID = competitionID
        self.direction = direction
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.scoringPolicy = scoringPolicy
        self.downwardRevisionPolicy = downwardRevisionPolicy
    }

    public func makeCompetition() -> Competition {
        .pending(
            id: competitionID,
            direction: direction,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }

    public func makeScoreLedger() -> ScoreLedger {
        ScoreLedger(
            scoringPolicy: scoringPolicy,
            downwardRevisionPolicy: downwardRevisionPolicy
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case competitionID
        case direction
        case createdAt
        case expiresAt
        case scoringPolicy
        case downwardRevisionPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(UInt32.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw CompetitionJournalError.upgradeRequiredGenesisVersion(
                found: version
            )
        }
        do {
            try self.init(
                version: version,
                competitionID: container.decode(
                    CompetitionID.self,
                    forKey: .competitionID
                ),
                direction: container.decode(
                    InvitationDirection.self,
                    forKey: .direction
                ),
                createdAt: container.decode(Date.self, forKey: .createdAt),
                expiresAt: container.decodeIfPresent(Date.self, forKey: .expiresAt),
                scoringPolicy: container.decode(
                    ActivityScoringPolicy.self,
                    forKey: .scoringPolicy
                ),
                downwardRevisionPolicy: container.decode(
                    DownwardRevisionPolicy.self,
                    forKey: .downwardRevisionPolicy
                )
            )
        } catch let error as CompetitionJournalError {
            throw error
        } catch {
            throw CompetitionJournalError.invalidGenesis
        }
    }
}

// MARK: - Typed persisted domain events

/// The immutable server descriptor that changes a journal from the simulated
/// opponent protocol to the remote-participant protocol. It is v4-only.
public struct RemoteCompetitionConfiguration: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case distinctParticipantsRequired, invalidPolicy, invalidRevision, invalidDeadline, invalidSchedule
    }

    public let competitionID: CompetitionID
    public let owner: RemoteParticipant
    public let remote: RemoteParticipant
    public let acceptedSchedule: CompetitionSchedule
    public let scoringPolicyIdentity: String
    /// Downloaded backend cursor (`next_server_seq - 1`) at acceptance.
    public let backendDescriptorRevision: Int64
    public let bestAvailableDeadline: Date

    public init(competitionID: CompetitionID, owner: RemoteParticipant, remote: RemoteParticipant, acceptedSchedule: CompetitionSchedule, scoringPolicyIdentity: String, backendDescriptorRevision: Int64, bestAvailableDeadline: Date) throws {
        guard competitionID.rawValue != UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, owner != remote else { throw ValidationError.distinctParticipantsRequired }
        guard scoringPolicyIdentity == RemoteScoringWireV1.policyIdentity else { throw ValidationError.invalidPolicy }
        guard backendDescriptorRevision > 0 else { throw ValidationError.invalidRevision }
        guard bestAvailableDeadline.timeIntervalSinceReferenceDate.isFinite else { throw ValidationError.invalidDeadline }
        guard let days = try? acceptedSchedule.calendar.sevenDayWindow(startingOn: acceptedSchedule.startDay),
              let finalDay = days.last,
              let dayAfter = try? acceptedSchedule.calendar.day(after: finalDay),
              let endBoundary = try? acceptedSchedule.calendar.startOfDay(dayAfter),
              bestAvailableDeadline > endBoundary
        else { throw ValidationError.invalidSchedule }
        self.competitionID = competitionID; self.owner = owner; self.remote = remote; self.acceptedSchedule = acceptedSchedule
        self.scoringPolicyIdentity = scoringPolicyIdentity; self.backendDescriptorRevision = backendDescriptorRevision; self.bestAvailableDeadline = bestAvailableDeadline
    }

    public var semanticIdentity: String {
        ["remote-configuration", competitionID.rawValue.uuidString.lowercased(), owner.profileID.uuidString.lowercased(), remote.profileID.uuidString.lowercased(), acceptedSchedule.calendar.timeZoneIdentifier, "\(acceptedSchedule.startDay.era)-\(acceptedSchedule.startDay.year)-\(acceptedSchedule.startDay.month)-\(acceptedSchedule.startDay.day)", scoringPolicyIdentity, "\(backendDescriptorRevision)", "\(bestAvailableDeadline.timeIntervalSince1970)"].joined(separator: ":")
    }
    private enum CodingKeys: String, CodingKey { case competitionID, owner, remote, acceptedSchedule, scoringPolicyIdentity, backendDescriptorRevision, bestAvailableDeadline }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); try self.init(competitionID: c.decode(CompetitionID.self, forKey: .competitionID), owner: c.decode(RemoteParticipant.self, forKey: .owner), remote: c.decode(RemoteParticipant.self, forKey: .remote), acceptedSchedule: c.decode(CompetitionSchedule.self, forKey: .acceptedSchedule), scoringPolicyIdentity: c.decode(String.self, forKey: .scoringPolicyIdentity), backendDescriptorRevision: c.decode(Int64.self, forKey: .backendDescriptorRevision), bestAvailableDeadline: c.decode(Date.self, forKey: .bestAvailableDeadline)) }
}

public struct RemoteScoreRevision: Codable, Equatable, Sendable {
    public let competitionID: CompetitionID
    public let participant: RemoteParticipant
    public let row: RemoteAcceptedScoreRow
    public let recordedAt: Date
    public init(competitionID: CompetitionID, participant: RemoteParticipant, row: RemoteAcceptedScoreRow, recordedAt: Date) throws {
        guard recordedAt.timeIntervalSinceReferenceDate.isFinite else { throw CompetitionJournalError.invalidDomainTransition(sequence: 0) }
        self.competitionID = competitionID; self.participant = participant; self.row = row; self.recordedAt = recordedAt
    }
    public var semanticEventID: String {
        let evidence = row.acceptedCentiPoints.map(String.init)
            ?? row.availabilityReason
            ?? "unavailable"
        return ["remote-score-revision", competitionID.rawValue.uuidString.lowercased(), participant.profileID.uuidString.lowercased(), "\(row.ordinal)", evidence, row.wireContentSHA256, "\(row.clientRevision)", "\(row.serverSequence)", "\(recordedAt.timeIntervalSince1970)"].joined(separator: ":")
    }
    private enum CodingKeys: String, CodingKey { case competitionID, participant, row, recordedAt }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); try self.init(competitionID: c.decode(CompetitionID.self, forKey: .competitionID), participant: c.decode(RemoteParticipant.self, forKey: .participant), row: c.decode(RemoteAcceptedScoreRow.self, forKey: .row), recordedAt: c.decode(Date.self, forKey: .recordedAt)) }
}

public enum RemoteFinalizationBasis: String, Codable, Equatable, Sendable { case stable, bestAvailable = "best_available" }

public struct RemoteFinalWindowAttestation: Codable, Equatable, Sendable {
    public let competitionID: CompetitionID
    public let participant: RemoteParticipant
    public let windowCommitment: String
    public let basis: RemoteFinalizationBasis
    public let acceptedRevisions: [Int64]
    public let attestationVersion: Int64
    public let serverSequence: Int64
    public let attestedAt: Date
    public init(competitionID: CompetitionID, participant: RemoteParticipant, windowCommitment: String, basis: RemoteFinalizationBasis, acceptedRevisions: [Int64], attestationVersion: Int64, serverSequence: Int64, attestedAt: Date) throws {
        guard windowCommitment.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              acceptedRevisions.count == 7, acceptedRevisions.allSatisfy({ $0 >= 0 }), attestationVersion > 0, serverSequence > 0, attestedAt.timeIntervalSinceReferenceDate.isFinite
        else { throw CompetitionJournalError.invalidDomainTransition(sequence: 0) }
        self.competitionID = competitionID; self.participant = participant; self.windowCommitment = windowCommitment; self.basis = basis; self.acceptedRevisions = acceptedRevisions; self.attestationVersion = attestationVersion; self.serverSequence = serverSequence; self.attestedAt = attestedAt
    }
    public var semanticEventID: String { (["remote-final-window", competitionID.rawValue.uuidString.lowercased(), participant.profileID.uuidString.lowercased(), basis.rawValue, windowCommitment, "\(attestationVersion)", "\(serverSequence)", "\(attestedAt.timeIntervalSince1970)"] + acceptedRevisions.map(String.init)).joined(separator: ":") }
    private enum CodingKeys: String, CodingKey { case competitionID, participant, windowCommitment, basis, acceptedRevisions, attestationVersion, serverSequence, attestedAt }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); try self.init(competitionID: c.decode(CompetitionID.self, forKey: .competitionID), participant: c.decode(RemoteParticipant.self, forKey: .participant), windowCommitment: c.decode(String.self, forKey: .windowCommitment), basis: c.decode(RemoteFinalizationBasis.self, forKey: .basis), acceptedRevisions: c.decode([Int64].self, forKey: .acceptedRevisions), attestationVersion: c.decode(Int64.self, forKey: .attestationVersion), serverSequence: c.decode(Int64.self, forKey: .serverSequence), attestedAt: c.decode(Date.self, forKey: .attestedAt)) }
}

public enum SharedResultStatus: String, Codable, Equatable, Sendable { case points, unavailable }
public enum SharedResultSource: String, Codable, Equatable, Sendable { case acceptedRevision = "accepted_revision", deadlineMissing = "deadline_missing" }
public struct SharedResultDay: Codable, Equatable, Sendable {
    public let ordinal: Int; public let status: SharedResultStatus; public let source: SharedResultSource; public let centiPoints: Int?; public let reason: String?; public let wireContentSHA256: String?; public let clientRevision: Int64?; public let serverSequence: Int64?; public let scoringPolicyIdentity: String?
    public init(ordinal: Int, status: SharedResultStatus, source: SharedResultSource, centiPoints: Int?, reason: String?, wireContentSHA256: String?, clientRevision: Int64?, serverSequence: Int64?, scoringPolicyIdentity: String?) throws {
        _ = try RemoteFinalizationDayV1(ordinal: ordinal, status: status == .points ? .points : .unavailable, source: source == .acceptedRevision ? .acceptedRevision : .deadlineMissing, points: centiPoints, reason: reason, wireContentSHA256: wireContentSHA256, clientRevision: clientRevision, serverSequence: serverSequence)
        guard source == .deadlineMissing ? scoringPolicyIdentity == nil : scoringPolicyIdentity == RemoteScoringWireV1.policyIdentity else { throw CompetitionJournalError.invalidDomainTransition(sequence: 0) }
        self.ordinal=ordinal; self.status=status; self.source=source; self.centiPoints=centiPoints; self.reason=reason; self.wireContentSHA256=wireContentSHA256; self.clientRevision=clientRevision; self.serverSequence=serverSequence; self.scoringPolicyIdentity=scoringPolicyIdentity
    }
    private enum CodingKeys: String, CodingKey { case ordinal, status, source, centiPoints = "centi_points", reason, wireContentSHA256 = "wire_content_sha256", clientRevision = "client_revision", serverSequence = "server_seq", scoringPolicyIdentity = "scoring_policy_identity" }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); try self.init(ordinal: c.decode(Int.self, forKey: .ordinal), status: c.decode(SharedResultStatus.self, forKey: .status), source: c.decode(SharedResultSource.self, forKey: .source), centiPoints: c.decodeIfPresent(Int.self, forKey: .centiPoints), reason: c.decodeIfPresent(String.self, forKey: .reason), wireContentSHA256: c.decodeIfPresent(String.self, forKey: .wireContentSHA256), clientRevision: c.decodeIfPresent(Int64.self, forKey: .clientRevision), serverSequence: c.decodeIfPresent(Int64.self, forKey: .serverSequence), scoringPolicyIdentity: c.decodeIfPresent(String.self, forKey: .scoringPolicyIdentity)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(ordinal, forKey: .ordinal); try c.encode(status, forKey: .status); try c.encode(source, forKey: .source); if let centiPoints { try c.encode(centiPoints, forKey: .centiPoints) } else { try c.encodeNil(forKey: .centiPoints) }; if let reason { try c.encode(reason, forKey: .reason) } else { try c.encodeNil(forKey: .reason) }; if let wireContentSHA256 { try c.encode(wireContentSHA256, forKey: .wireContentSHA256) } else { try c.encodeNil(forKey: .wireContentSHA256) }; if let clientRevision { try c.encode(clientRevision, forKey: .clientRevision) } else { try c.encodeNil(forKey: .clientRevision) }; if let serverSequence { try c.encode(serverSequence, forKey: .serverSequence) } else { try c.encodeNil(forKey: .serverSequence) }; if let scoringPolicyIdentity { try c.encode(scoringPolicyIdentity, forKey: .scoringPolicyIdentity) } else { try c.encodeNil(forKey: .scoringPolicyIdentity) } }
}

public struct SharedParticipantWindow: Codable, Equatable, Sendable {
    public let participant: RemoteParticipant; public let totalCentiPoints: Int; public let windowCommitment: String; public let days: [SharedResultDay]
    public init(competitionID: CompetitionID, participant: RemoteParticipant, totalCentiPoints: Int, windowCommitment: String, days: [SharedResultDay]) throws {
        guard days.map(\.ordinal) == Array(1...7), (0...420_000).contains(totalCentiPoints), windowCommitment.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw CompetitionJournalError.invalidDomainTransition(sequence: 0) }
        let finalDays = try days.map { try RemoteFinalizationDayV1(ordinal: $0.ordinal, status: $0.status == .points ? .points : .unavailable, source: $0.source == .acceptedRevision ? .acceptedRevision : .deadlineMissing, points: $0.centiPoints, reason: $0.reason, wireContentSHA256: $0.wireContentSHA256, clientRevision: $0.clientRevision, serverSequence: $0.serverSequence) }
        guard totalCentiPoints == finalDays.compactMap(\.points).reduce(0, +), try RemoteFinalizationWireV1.windowCommitment(competitionID: competitionID.rawValue, participantID: participant.profileID, days: finalDays) == windowCommitment else { throw CompetitionJournalError.invalidDomainTransition(sequence: 0) }
        self.participant=participant; self.totalCentiPoints=totalCentiPoints; self.windowCommitment=windowCommitment; self.days=days
    }
    private enum CodingKeys: String, CodingKey { case participant = "profile_id", totalCentiPoints = "total_centi_points", windowCommitment = "window_commitment_sha256", days }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let participant = try RemoteParticipant(profileID: c.decode(UUID.self, forKey: .participant))
        let total = try c.decode(Int.self, forKey: .totalCentiPoints)
        let commitment = try c.decode(String.self, forKey: .windowCommitment)
        let days = try c.decode([SharedResultDay].self, forKey: .days)
        guard days.map(\.ordinal) == Array(1...7), (0...420_000).contains(total), total == days.compactMap(\.centiPoints).reduce(0, +), commitment.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw CompetitionJournalError.invalidDomainTransition(sequence: 0) }
        self.participant=participant; self.totalCentiPoints=total; self.windowCommitment=commitment; self.days=days
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(participant.profileID, forKey: .participant); try c.encode(totalCentiPoints, forKey: .totalCentiPoints); try c.encode(windowCommitment, forKey: .windowCommitment); try c.encode(days, forKey: .days) }
}

public struct SharedCompetitionResult: Codable, Equatable, Sendable {
    public static let frozenWindowVersion = 2
    public let competitionID: CompetitionID
    public let owner: RemoteParticipant
    public let remote: RemoteParticipant
    public let windows: [SharedParticipantWindow]
    public let frozenWindowVersion: Int
    public let scoringPolicyIdentity: String
    public let winner: RemoteParticipant?
    public let basis: RemoteFinalizationBasis
    public let resultHash: String
    public let confirmedAt: Date
    public let serverSequence: Int64

    public init(competitionID: CompetitionID, owner: RemoteParticipant, remote: RemoteParticipant, windows: [SharedParticipantWindow], frozenWindowVersion: Int = SharedCompetitionResult.frozenWindowVersion, scoringPolicyIdentity: String = RemoteScoringWireV1.policyIdentity, winner: RemoteParticipant?, basis: RemoteFinalizationBasis, resultHash: String, confirmedAt: Date, serverSequence: Int64) throws {
        guard frozenWindowVersion == Self.frozenWindowVersion, scoringPolicyIdentity == RemoteScoringWireV1.policyIdentity, owner != remote, windows.count == 2, windows.map(\.participant.profileID) == [owner.profileID, remote.profileID].sorted(by: { $0.uuidString < $1.uuidString }), serverSequence > 0, confirmedAt.timeIntervalSinceReferenceDate.isFinite else { throw CompetitionJournalError.invalidDomainTransition(sequence: 0) }
        guard let ownerWindow = windows.first(where: { $0.participant == owner }),
              let remoteWindow = windows.first(where: { $0.participant == remote })
        else { throw CompetitionJournalError.invalidDomainTransition(sequence: 0) }
        for window in windows {
            _ = try SharedParticipantWindow(competitionID: competitionID, participant: window.participant, totalCentiPoints: window.totalCentiPoints, windowCommitment: window.windowCommitment, days: window.days)
        }
        guard resultHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw CompetitionJournalError.invalidDomainTransition(sequence: 0) }
        if ownerWindow.totalCentiPoints == remoteWindow.totalCentiPoints { guard winner == nil else { throw CompetitionJournalError.invalidDomainTransition(sequence: 0) } }
        else { guard winner == owner || winner == remote else { throw CompetitionJournalError.invalidDomainTransition(sequence: 0) } }
        let first = windows[0], second = windows[1]
        let expected = try RemoteFinalizationWireV1.resultHash(competitionID: competitionID.rawValue, participantA: first.participant.profileID, totalA: first.totalCentiPoints, commitmentA: first.windowCommitment, participantB: second.participant.profileID, totalB: second.totalCentiPoints, commitmentB: second.windowCommitment, outcome: winner == nil ? "tie" : "winner", winner: winner?.profileID, basis: basis.rawValue)
        guard resultHash == expected else { throw CompetitionJournalError.invalidDomainTransition(sequence: 0) }
        self.competitionID = competitionID; self.owner = owner; self.remote = remote; self.windows = windows; self.frozenWindowVersion=frozenWindowVersion; self.scoringPolicyIdentity=scoringPolicyIdentity; self.winner = winner; self.basis = basis; self.resultHash = resultHash; self.confirmedAt = confirmedAt; self.serverSequence=serverSequence
    }
    public var semanticEventID: String {
        [
            "shared-result:v2",
            competitionID.rawValue.uuidString.lowercased(),
            owner.profileID.uuidString.lowercased(),
            remote.profileID.uuidString.lowercased(),
            resultHash,
            "\(serverSequence)",
            "\(confirmedAt.timeIntervalSince1970)",
        ].joined(separator: ":")
    }
    public func window(for participant: RemoteParticipant) throws -> SharedParticipantWindow {
        guard let window = windows.first(where: { $0.participant == participant }) else { throw CompetitionJournalError.invalidDomainTransition(sequence: 0) }
        return window
    }
    private enum CodingKeys: String, CodingKey { case competitionID = "competition_id", owner = "owner_profile_id", remote = "remote_profile_id", frozenWindow = "frozen_window", winner = "winner_profile_id", basis = "finalization_basis", resultHash = "immutable_hash", confirmedAt = "completed_at", serverSequence = "server_seq" }
    private enum FrozenWindowKeys: String, CodingKey { case version, policy, participants }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let competitionID = try c.decode(CompetitionID.self, forKey: .competitionID)
        let owner = try RemoteParticipant(profileID: c.decode(UUID.self, forKey: .owner))
        let remote = try RemoteParticipant(profileID: c.decode(UUID.self, forKey: .remote))
        let nested = try c.nestedContainer(keyedBy: FrozenWindowKeys.self, forKey: .frozenWindow)
        let version = try nested.decode(Int.self, forKey: .version)
        let policy = try nested.decode(String.self, forKey: .policy)
        let windows = try nested.decode([SharedParticipantWindow].self, forKey: .participants)
        let winner = try c.decodeIfPresent(UUID.self, forKey: .winner).map { try RemoteParticipant(profileID: $0) }
        try self.init(competitionID: competitionID, owner: owner, remote: remote, windows: windows, frozenWindowVersion: version, scoringPolicyIdentity: policy, winner: winner, basis: try c.decode(RemoteFinalizationBasis.self, forKey: .basis), resultHash: try c.decode(String.self, forKey: .resultHash), confirmedAt: try c.decode(Date.self, forKey: .confirmedAt), serverSequence: try c.decode(Int64.self, forKey: .serverSequence))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(competitionID, forKey: .competitionID); try c.encode(owner.profileID, forKey: .owner); try c.encode(remote.profileID, forKey: .remote)
        var nested = c.nestedContainer(keyedBy: FrozenWindowKeys.self, forKey: .frozenWindow)
        try nested.encode(frozenWindowVersion, forKey: .version); try nested.encode(scoringPolicyIdentity, forKey: .policy); try nested.encode(windows, forKey: .participants)
        if let winner { try c.encode(winner.profileID, forKey: .winner) } else { try c.encodeNil(forKey: .winner) }; try c.encode(basis, forKey: .basis); try c.encode(resultHash, forKey: .resultHash); try c.encode(confirmedAt, forKey: .confirmedAt); try c.encode(serverSequence, forKey: .serverSequence)
    }
}

public enum SynchronizationReceiptKind: String, Codable, Equatable, Sendable { case scoreRevision = "score_revision", finalWindowAttestation = "final_window_attestation" }
public enum SynchronizationReceiptDisposition: String, Codable, Equatable, Sendable { case appended, duplicate }
public struct SynchronizationReceipt: Codable, Equatable, Sendable {
    public let competitionID: CompetitionID
    public let serverCursor: Int64
    public let acknowledgedEventID: String
    public let kind: SynchronizationReceiptKind
    public let disposition: SynchronizationReceiptDisposition
    public let entityServerSequence: Int64
    public let receivedAt: Date
    public init(competitionID: CompetitionID, serverCursor: Int64, acknowledgedEventID: String, kind: SynchronizationReceiptKind, disposition: SynchronizationReceiptDisposition, entityServerSequence: Int64, receivedAt: Date) throws {
        guard serverCursor > 0, entityServerSequence > 0, entityServerSequence <= serverCursor, !acknowledgedEventID.isEmpty, receivedAt.timeIntervalSinceReferenceDate.isFinite else { throw CompetitionJournalError.invalidDomainTransition(sequence: 0) }
        self.competitionID = competitionID; self.serverCursor = serverCursor; self.acknowledgedEventID = acknowledgedEventID; self.kind = kind; self.disposition = disposition; self.entityServerSequence=entityServerSequence; self.receivedAt = receivedAt
    }
    public var semanticEventID: String { "synchronization-receipt:\(competitionID.rawValue.uuidString.lowercased()):\(acknowledgedEventID):\(kind):\(disposition):\(entityServerSequence):\(serverCursor):\(receivedAt.timeIntervalSince1970)" }
    private enum CodingKeys: String, CodingKey { case competitionID, serverCursor, acknowledgedEventID, kind, disposition, entityServerSequence, receivedAt }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); try self.init(competitionID: c.decode(CompetitionID.self, forKey: .competitionID), serverCursor: c.decode(Int64.self, forKey: .serverCursor), acknowledgedEventID: c.decode(String.self, forKey: .acknowledgedEventID), kind: c.decode(SynchronizationReceiptKind.self, forKey: .kind), disposition: c.decode(SynchronizationReceiptDisposition.self, forKey: .disposition), entityServerSequence: c.decode(Int64.self, forKey: .entityServerSequence), receivedAt: c.decode(Date.self, forKey: .receivedAt)) }
}

public struct ActivitySnapshotRecorded: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidObservationID
        case invalidDayOrdinal(Int)
        case semanticIDMismatch(expected: String, actual: String)
    }

    public let semanticEventID: String
    public let observationID: String
    public let competitionID: CompetitionID
    public let observedAt: Date
    public let dayOrdinal: Int
    public let snapshot: ActivitySnapshot

    public init(
        observationID: String,
        competitionID: CompetitionID,
        observedAt: Date,
        dayOrdinal: Int,
        snapshot: ActivitySnapshot
    ) throws {
        try self.init(
            semanticEventID: Self.semanticID(
                competitionID: competitionID,
                observationID: observationID
            ),
            observationID: observationID,
            competitionID: competitionID,
            observedAt: observedAt,
            dayOrdinal: dayOrdinal,
            snapshot: snapshot
        )
    }

    public static func semanticID(
        competitionID: CompetitionID,
        observationID: String
    ) -> String {
        [
            "activity-snapshot-recorded",
            "v1",
            competitionID.rawValue.uuidString.lowercased(),
            observationID,
        ].joined(separator: ":")
    }

    private init(
        semanticEventID: String,
        observationID: String,
        competitionID: CompetitionID,
        observedAt: Date,
        dayOrdinal: Int,
        snapshot: ActivitySnapshot
    ) throws {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_.")
        )
        guard !observationID.isEmpty,
              observationID.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw ValidationError.invalidObservationID
        }
        guard (1...7).contains(dayOrdinal) else {
            throw ValidationError.invalidDayOrdinal(dayOrdinal)
        }
        let expectedID = Self.semanticID(
            competitionID: competitionID,
            observationID: observationID
        )
        guard semanticEventID == expectedID else {
            throw ValidationError.semanticIDMismatch(
                expected: expectedID,
                actual: semanticEventID
            )
        }
        self.semanticEventID = semanticEventID
        self.observationID = observationID
        self.competitionID = competitionID
        self.observedAt = observedAt
        self.dayOrdinal = dayOrdinal
        self.snapshot = snapshot
    }

    private enum CodingKeys: String, CodingKey {
        case semanticEventID
        case observationID
        case competitionID
        case observedAt
        case dayOrdinal
        case snapshot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            semanticEventID: container.decode(String.self, forKey: .semanticEventID),
            observationID: container.decode(String.self, forKey: .observationID),
            competitionID: container.decode(
                CompetitionID.self,
                forKey: .competitionID
            ),
            observedAt: container.decode(Date.self, forKey: .observedAt),
            dayOrdinal: container.decode(Int.self, forKey: .dayOrdinal),
            snapshot: container.decode(ActivitySnapshot.self, forKey: .snapshot)
        )
    }
}

/// Payload version 1 is decoded through an immutable schema mirror so adding
/// payload-v2 fields or cases cannot silently broaden the old wire contract.
private enum ActivityStandModeV1: String, Decodable {
    case standHours
    case rollHours

    var upgraded: ActivityStandMode {
        switch self {
        case .standHours: .standHours
        case .rollHours: .rollHours
        }
    }
}

private struct ActivitySnapshotV1: Decodable {
    let moveMode: ActivityMoveMode
    let standMode: ActivityStandModeV1
    let move: ActivityRingReading
    let exercise: ActivityRingReading
    let standOrRoll: ActivityRingReading
    let isPaused: Bool

    var upgraded: ActivitySnapshot {
        ActivitySnapshot(
            moveMode: moveMode,
            standMode: standMode.upgraded,
            move: move,
            exercise: exercise,
            standOrRoll: standOrRoll,
            isPaused: isPaused
        )
    }
}

private struct ActivitySnapshotRecordedV1: Decodable {
    let semanticEventID: String
    let observationID: String
    let competitionID: CompetitionID
    let observedAt: Date
    let dayOrdinal: Int
    let snapshot: ActivitySnapshotV1

    func upgraded() throws -> ActivitySnapshotRecorded {
        let event = try ActivitySnapshotRecorded(
            observationID: observationID,
            competitionID: competitionID,
            observedAt: observedAt,
            dayOrdinal: dayOrdinal,
            snapshot: snapshot.upgraded
        )
        guard event.semanticEventID == semanticEventID else {
            throw ActivitySnapshotRecorded.ValidationError.semanticIDMismatch(
                expected: event.semanticEventID,
                actual: semanticEventID
            )
        }
        return event
    }
}

private enum CompetitionEventKindV3: Decodable {
    case invitationAccepted(AcceptedCompetitionConfiguration), invitationDeclined, invitationExpired, competitionStarted, dayClosed(Int), finalDayStarted, tallyStarted, finalReadRecorded(FinalReadRecord), competitionFinalized(FinalizationRecord), competitionArchived
    var upgraded: CompetitionEventKind {
        switch self {
        case let .invitationAccepted(value): .invitationAccepted(value)
        case .invitationDeclined: .invitationDeclined
        case .invitationExpired: .invitationExpired
        case .competitionStarted: .competitionStarted
        case let .dayClosed(value): .dayClosed(value)
        case .finalDayStarted: .finalDayStarted
        case .tallyStarted: .tallyStarted
        case let .finalReadRecorded(value): .finalReadRecorded(value)
        case let .competitionFinalized(value): .competitionFinalized(value)
        case .competitionArchived: .competitionArchived
        }
    }
}

private struct CompetitionEventV3: Decodable {
    let id: String; let competitionID: CompetitionID; let occurredAt: Date; let kind: CompetitionEventKindV3
    func upgraded() throws -> CompetitionEvent {
        let event = CompetitionEvent(competitionID: competitionID, occurredAt: occurredAt, kind: kind.upgraded)
        guard event.id == id else { throw CompetitionEvent.ValidationError.semanticIDMismatch(expected: event.id, actual: id) }
        return event
    }
}

private enum CompetitionDomainEventV1: Decodable {
    case lifecycle(CompetitionEventV3)
    case activitySnapshotRecorded(ActivitySnapshotRecordedV1)

    func upgraded() throws -> CompetitionDomainEvent {
        switch self {
        case let .lifecycle(event):
            return .lifecycle(try event.upgraded())
        case let .activitySnapshotRecorded(event):
            return .activitySnapshotRecorded(try event.upgraded())
        }
    }
}

/// Payload version 2's top-level union is immutable. Its leaf values remain
/// the already-persisted version-2 types; adding a new live union case must not
/// make that case decodable from an older envelope.
private enum CompetitionDomainEventV2: Decodable {
    case lifecycle(CompetitionEventV3)
    case activitySnapshotRecorded(ActivitySnapshotRecorded)
    case activityRefreshAttemptRecorded(ActivityRefreshAttemptRecorded)

    func upgraded() throws -> CompetitionDomainEvent {
        switch self {
        case let .lifecycle(event):
            return .lifecycle(try event.upgraded())
        case let .activitySnapshotRecorded(event):
            return .activitySnapshotRecorded(event)
        case let .activityRefreshAttemptRecorded(event):
            return .activityRefreshAttemptRecorded(event)
        }
    }
}

/// Payload-v3 is frozen independently of the live union. This is important:
/// a future top-level case must be impossible to decode merely because it was
/// added to `CompetitionDomainEvent`.
private enum CompetitionDomainEventV3: Decodable {
    case lifecycle(CompetitionEventV3)
    case activitySnapshotRecorded(ActivitySnapshotRecorded)
    case activityRefreshAttemptRecorded(ActivityRefreshAttemptRecorded)
    case notificationEmissionRecorded(NotificationEmissionRecorded)

    func upgraded() throws -> CompetitionDomainEvent {
        switch self {
        case let .lifecycle(event): .lifecycle(try event.upgraded())
        case let .activitySnapshotRecorded(event): .activitySnapshotRecorded(event)
        case let .activityRefreshAttemptRecorded(event): .activityRefreshAttemptRecorded(event)
        case let .notificationEmissionRecorded(event): .notificationEmissionRecorded(event)
        }
    }
}

/// Payload versions 1 through 3 remain immutable and replayable. New writes use
/// version 4; envelopes preserve exact encoded bytes and semantic duplicate
/// checks compare decoded values.
public enum CompetitionDomainEvent: Codable, Equatable, Sendable {
    case lifecycle(CompetitionEvent)
    case activitySnapshotRecorded(ActivitySnapshotRecorded)
    case activityRefreshAttemptRecorded(ActivityRefreshAttemptRecorded)
    case notificationEmissionRecorded(NotificationEmissionRecorded)
    case remoteConfigurationAccepted(RemoteCompetitionConfiguration)
    case remoteScoreRevisionRecorded(RemoteScoreRevision)
    case remoteFinalWindowAttested(RemoteFinalWindowAttestation)
    case sharedResultConfirmed(SharedCompetitionResult)
    case synchronizationReceiptRecorded(SynchronizationReceipt)

    public var semanticEventID: String {
        switch self {
        case let .lifecycle(event): event.id
        case let .activitySnapshotRecorded(event): event.semanticEventID
        case let .activityRefreshAttemptRecorded(event): event.semanticEventID
        case let .notificationEmissionRecorded(event): event.semanticEventID
        case let .remoteConfigurationAccepted(event): "remote-configuration-accepted:\(event.semanticIdentity)"
        case let .remoteScoreRevisionRecorded(event): event.semanticEventID
        case let .remoteFinalWindowAttested(event): event.semanticEventID
        case let .sharedResultConfirmed(event): event.semanticEventID
        case let .synchronizationReceiptRecorded(event): event.semanticEventID
        }
    }

    public var competitionID: CompetitionID {
        switch self {
        case let .lifecycle(event): event.competitionID
        case let .activitySnapshotRecorded(event): event.competitionID
        case let .activityRefreshAttemptRecorded(event): event.competitionID
        case let .notificationEmissionRecorded(event): event.competitionID
        case let .remoteConfigurationAccepted(event): event.competitionID
        case let .remoteScoreRevisionRecorded(event): event.competitionID
        case let .remoteFinalWindowAttested(event): event.competitionID
        case let .sharedResultConfirmed(event): event.competitionID
        case let .synchronizationReceiptRecorded(event): event.competitionID
        }
    }

    public var occurredAt: Date {
        switch self {
        case let .lifecycle(event): event.occurredAt
        case let .activitySnapshotRecorded(event): event.observedAt
        case let .activityRefreshAttemptRecorded(event): event.readAt
        case let .notificationEmissionRecorded(event): event.decidedAt
        case let .remoteConfigurationAccepted(event): event.bestAvailableDeadline
        case let .remoteScoreRevisionRecorded(event): event.recordedAt
        case let .remoteFinalWindowAttested(event): event.attestedAt
        case let .sharedResultConfirmed(event): event.confirmedAt
        case let .synchronizationReceiptRecorded(event): event.receivedAt
        }
    }
}

// MARK: - Journal values

public struct CompetitionJournalCursor: Codable, Equatable, Sendable {
    public let commitRevision: UInt64
    public let eventCount: UInt64
    public let tailDigest: String

    internal init(
        commitRevision: UInt64,
        eventCount: UInt64,
        tailDigest: String
    ) {
        self.commitRevision = commitRevision
        self.eventCount = eventCount
        self.tailDigest = tailDigest
    }
}

public struct CompetitionJournalEnvelope: Codable, Equatable, Sendable {
    public static let currentEnvelopeVersion: UInt32 = 1
    public static let currentPayloadVersion: UInt32 = 4
    private static let supportedPayloadVersions: ClosedRange<UInt32> = 1...4
    /// Sequences are one-based. Zero means an unsupported future envelope did
    /// not expose a sequence using the version-one field shape.
    public static let unknownSequence: UInt64 = 0

    public let envelopeVersion: UInt32
    public let payloadVersion: UInt32
    public let commitRevision: UInt64
    public let sequence: UInt64
    public let streamID: CompetitionID
    public let semanticEventID: String
    public let payload: Data
    public let payloadSHA256: String
    public let previousEnvelopeSHA256: String
    public let envelopeSHA256: String

    internal init(
        payloadVersion: UInt32 = Self.currentPayloadVersion,
        commitRevision: UInt64,
        sequence: UInt64,
        streamID: CompetitionID,
        semanticEventID: String,
        payload: Data,
        previousEnvelopeSHA256: String
    ) {
        let payloadSHA256 = SHA256Digest.hexDigest(payload)
        self.envelopeVersion = Self.currentEnvelopeVersion
        self.payloadVersion = payloadVersion
        self.commitRevision = commitRevision
        self.sequence = sequence
        self.streamID = streamID
        self.semanticEventID = semanticEventID
        self.payload = payload
        self.payloadSHA256 = payloadSHA256
        self.previousEnvelopeSHA256 = previousEnvelopeSHA256
        self.envelopeSHA256 = Self.digest(
            envelopeVersion: Self.currentEnvelopeVersion,
            payloadVersion: payloadVersion,
            commitRevision: commitRevision,
            sequence: sequence,
            streamID: streamID,
            semanticEventID: semanticEventID,
            payloadSHA256: payloadSHA256,
            previousEnvelopeSHA256: previousEnvelopeSHA256
        )
    }

    private enum CodingKeys: String, CodingKey {
        case envelopeVersion
        case payloadVersion
        case commitRevision
        case sequence
        case streamID
        case semanticEventID
        case payload
        case payloadSHA256
        case previousEnvelopeSHA256
        case envelopeSHA256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let envelopeVersion = try container.decode(
            UInt32.self,
            forKey: .envelopeVersion
        )
        guard envelopeVersion == Self.currentEnvelopeVersion else {
            let diagnosticSequence =
                (try? container.decode(UInt64.self, forKey: .sequence))
                ?? Self.unknownSequence
            throw CompetitionJournalError.upgradeRequiredEnvelopeVersion(
                sequence: diagnosticSequence,
                found: envelopeVersion
            )
        }
        let sequence = try container.decode(UInt64.self, forKey: .sequence)
        let payloadVersion = try container.decode(
            UInt32.self,
            forKey: .payloadVersion
        )
        guard Self.supportedPayloadVersions.contains(payloadVersion) else {
            throw CompetitionJournalError.upgradeRequiredPayloadVersion(
                sequence: sequence,
                found: payloadVersion
            )
        }

        self.envelopeVersion = envelopeVersion
        self.payloadVersion = payloadVersion
        self.commitRevision = try container.decode(
            UInt64.self,
            forKey: .commitRevision
        )
        self.sequence = sequence
        self.streamID = try container.decode(
            CompetitionID.self,
            forKey: .streamID
        )
        self.semanticEventID = try container.decode(
            String.self,
            forKey: .semanticEventID
        )
        self.payload = try container.decode(Data.self, forKey: .payload)
        self.payloadSHA256 = try container.decode(
            String.self,
            forKey: .payloadSHA256
        )
        self.previousEnvelopeSHA256 = try container.decode(
            String.self,
            forKey: .previousEnvelopeSHA256
        )
        self.envelopeSHA256 = try container.decode(
            String.self,
            forKey: .envelopeSHA256
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(envelopeVersion, forKey: .envelopeVersion)
        try container.encode(payloadVersion, forKey: .payloadVersion)
        try container.encode(commitRevision, forKey: .commitRevision)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(streamID, forKey: .streamID)
        try container.encode(semanticEventID, forKey: .semanticEventID)
        try container.encode(payload, forKey: .payload)
        try container.encode(payloadSHA256, forKey: .payloadSHA256)
        try container.encode(
            previousEnvelopeSHA256,
            forKey: .previousEnvelopeSHA256
        )
        try container.encode(envelopeSHA256, forKey: .envelopeSHA256)
    }

    internal func validated(
        expectedSequence: UInt64,
        expectedPreviousDigest: String,
        expectedStreamID: CompetitionID
    ) throws {
        guard envelopeVersion == Self.currentEnvelopeVersion else {
            throw CompetitionJournalError.upgradeRequiredEnvelopeVersion(
                sequence: sequence,
                found: envelopeVersion
            )
        }
        guard Self.supportedPayloadVersions.contains(payloadVersion) else {
            throw CompetitionJournalError.upgradeRequiredPayloadVersion(
                sequence: sequence,
                found: payloadVersion
            )
        }
        try Self.validateDigest(payloadSHA256, field: "payloadSHA256")
        try Self.validateDigest(
            previousEnvelopeSHA256,
            field: "previousEnvelopeSHA256"
        )
        try Self.validateDigest(envelopeSHA256, field: "envelopeSHA256")
        guard sequence == expectedSequence else {
            throw CompetitionJournalError.sequenceViolation(
                expected: expectedSequence,
                found: sequence
            )
        }
        guard streamID == expectedStreamID else {
            throw CompetitionJournalError.streamMismatch(sequence: sequence)
        }
        guard previousEnvelopeSHA256 == expectedPreviousDigest else {
            throw CompetitionJournalError.previousDigestMismatch(sequence: sequence)
        }
        guard SHA256Digest.hexDigest(payload) == payloadSHA256 else {
            throw CompetitionJournalError.payloadDigestMismatch(sequence: sequence)
        }
        let expectedEnvelopeDigest = Self.digest(
            envelopeVersion: envelopeVersion,
            payloadVersion: payloadVersion,
            commitRevision: commitRevision,
            sequence: sequence,
            streamID: streamID,
            semanticEventID: semanticEventID,
            payloadSHA256: payloadSHA256,
            previousEnvelopeSHA256: previousEnvelopeSHA256
        )
        guard envelopeSHA256 == expectedEnvelopeDigest else {
            throw CompetitionJournalError.envelopeDigestMismatch(sequence: sequence)
        }
    }

    private static func digest(
        envelopeVersion: UInt32,
        payloadVersion: UInt32,
        commitRevision: UInt64,
        sequence: UInt64,
        streamID: CompetitionID,
        semanticEventID: String,
        payloadSHA256: String,
        previousEnvelopeSHA256: String
    ) -> String {
        var bytes = JournalCanonicalBytes()
        bytes.append("healthcomp.competition-journal-envelope")
        bytes.append(envelopeVersion)
        bytes.append(payloadVersion)
        bytes.append(commitRevision)
        bytes.append(sequence)
        bytes.append(streamID.rawValue.uuidString.lowercased())
        bytes.append(semanticEventID)
        bytes.append(payloadSHA256)
        bytes.append(previousEnvelopeSHA256)
        return SHA256Digest.hexDigest(bytes.data)
    }

    fileprivate static func validateDigest(
        _ digest: String,
        field: String
    ) throws {
        guard digest.count == 64,
              digest.allSatisfy({ "0123456789abcdef".contains($0) })
        else {
            throw CompetitionJournalError.malformedDigest(field: field)
        }
    }
}

public struct CompetitionJournalAppendResult: Equatable, Sendable {
    public let cursor: CompetitionJournalCursor
    public let appendedCount: Int

    internal init(cursor: CompetitionJournalCursor, appendedCount: Int) {
        self.cursor = cursor
        self.appendedCount = appendedCount
    }
}

public enum CompetitionJournalRelationship: Equatable, Sendable {
    case equal
    /// The receiver is an exact envelope prefix of the argument.
    case prefix
    /// The argument is an exact envelope prefix of the receiver.
    case descendant
    case divergent
}

public struct CompetitionReplayProjection: Equatable, Sendable {
    public let competition: Competition
    public let scoreLedger: ScoreLedger
    public let activityRefresh: ActivityRefreshProjection
    public let notificationEmissions: NotificationEmissionProjection
    public let remoteScoreLedgers: [UUID: RemoteScoreLedger]
    public let remoteWindowAttestations: [UUID: RemoteFinalWindowAttestation]
    public let synchronizationCursor: Int64
    public let sharedResult: SharedCompetitionResult?

    internal init(
        competition: Competition,
        scoreLedger: ScoreLedger,
        activityRefresh: ActivityRefreshProjection = ActivityRefreshProjection(),
        notificationEmissions: NotificationEmissionProjection = NotificationEmissionProjection(),
        remoteScoreLedgers: [UUID: RemoteScoreLedger] = [:],
        remoteWindowAttestations: [UUID: RemoteFinalWindowAttestation] = [:],
        synchronizationCursor: Int64 = 0,
        sharedResult: SharedCompetitionResult? = nil
    ) {
        self.competition = competition
        self.scoreLedger = scoreLedger
        self.activityRefresh = activityRefresh
        self.notificationEmissions = notificationEmissions
        self.remoteScoreLedgers = remoteScoreLedgers
        self.remoteWindowAttestations = remoteWindowAttestations
        self.synchronizationCursor = synchronizationCursor
        self.sharedResult = sharedResult
    }
}

public enum CompetitionJournalError: Error, Equatable, Sendable {
    case upgradeRequiredGenesisVersion(found: UInt32)
    case upgradeRequiredJournalVersion(found: UInt32)
    case upgradeRequiredEnvelopeVersion(sequence: UInt64, found: UInt32)
    case upgradeRequiredPayloadVersion(sequence: UInt64, found: UInt32)
    case payloadVersionDowngrade(sequence: UInt64)
    case invalidGenesis
    case invalidActivityObservation(sequence: UInt64)
    case invalidActivityRefreshAttempt(sequence: UInt64)
    case malformedDigest(field: String)
    case genesisDigestMismatch
    case payloadDigestMismatch(sequence: UInt64)
    case previousDigestMismatch(sequence: UInt64)
    case envelopeDigestMismatch(sequence: UInt64)
    case documentDigestMismatch
    case sequenceViolation(expected: UInt64, found: UInt64)
    case commitRevisionViolation(sequence: UInt64)
    case streamMismatch(sequence: UInt64)
    case envelopeIdentityMismatch(sequence: UInt64)
    case duplicatePersistedSemanticEventID(eventID: String)
    case invalidDomainTransition(sequence: UInt64)
    case ownerWindowMismatch(sequence: UInt64)
    case activityRefreshAttemptOrdinalViolation(
        expected: UInt64,
        found: UInt64
    )
    case duplicateActivityRefreshAttemptID(String)
    case activityRefreshAttemptOrdinalOverflow
    case activityRefreshDayMismatch(ordinal: Int)
    case activityRefreshAvailabilityMismatch(ordinal: Int)
    case standaloneActivitySnapshotRequiresPayloadV1(sequence: UInt64)
    case finalReadSourceBindingMismatch(sequence: UInt64)
    case semanticEventConflict(eventID: String)
    case cursorConflict(
        expected: CompetitionJournalCursor,
        actual: CompetitionJournalCursor
    )
    case cursorMismatch
    case sequenceOverflow
    case commitRevisionOverflow
}

public struct CompetitionJournal: Codable, Equatable, Sendable {
    public static let currentJournalVersion: UInt32 = 1

    public let journalVersion: UInt32
    public let genesis: CompetitionGenesis
    public let genesisDigest: String
    public private(set) var envelopes: [CompetitionJournalEnvelope]
    public private(set) var cursor: CompetitionJournalCursor
    public private(set) var documentDigest: String

    public init(genesis: CompetitionGenesis) throws {
        let genesisDigest = try Self.digest(genesis: genesis)
        let cursor = CompetitionJournalCursor(
            commitRevision: 0,
            eventCount: 0,
            tailDigest: genesisDigest
        )
        self.journalVersion = Self.currentJournalVersion
        self.genesis = genesis
        self.genesisDigest = genesisDigest
        self.envelopes = []
        self.cursor = cursor
        self.documentDigest = Self.digest(
            journalVersion: Self.currentJournalVersion,
            genesisDigest: genesisDigest,
            cursor: cursor
        )
    }

    /// Constructs from already-stored envelopes while deriving every journal
    /// redundancy and replay-validating the candidate. Kept internal so only a
    /// storage adapter's decoded document (or adversarial tests) can exercise
    /// the same validation path; callers cannot publish an unchecked stream.
    internal init(
        validating genesis: CompetitionGenesis,
        envelopes: [CompetitionJournalEnvelope]
    ) throws {
        let genesisDigest = try Self.digest(genesis: genesis)
        let cursor = CompetitionJournalCursor(
            commitRevision: envelopes.last?.commitRevision ?? 0,
            eventCount: UInt64(envelopes.count),
            tailDigest: envelopes.last?.envelopeSHA256 ?? genesisDigest
        )
        let candidate = Self(
            uncheckedJournalVersion: Self.currentJournalVersion,
            genesis: genesis,
            genesisDigest: genesisDigest,
            envelopes: envelopes,
            cursor: cursor,
            documentDigest: Self.digest(
                journalVersion: Self.currentJournalVersion,
                genesisDigest: genesisDigest,
                cursor: cursor
            )
        )
        _ = try CompetitionReplayer.replay(candidate)
        self = candidate
    }

    /// Compares exact persisted ancestry. A nonempty prefix must end between
    /// append commits; sharing bytes only through the middle of a commit is a
    /// divergent transaction history.
    public func relationship(
        to other: CompetitionJournal
    ) -> CompetitionJournalRelationship {
        guard genesis == other.genesis,
              genesisDigest == other.genesisDigest
        else {
            return .divergent
        }
        if self == other {
            return .equal
        }
        if isAppendBoundaryPrefix(of: other) {
            return .prefix
        }
        if other.isAppendBoundaryPrefix(of: self) {
            return .descendant
        }
        return .divergent
    }

    private func isAppendBoundaryPrefix(of other: CompetitionJournal) -> Bool {
        guard envelopes.count < other.envelopes.count,
              Array(other.envelopes.prefix(envelopes.count)) == envelopes
        else {
            return false
        }
        guard !envelopes.isEmpty else {
            return true
        }
        guard cursor.commitRevision < UInt64.max else {
            return false
        }
        return other.envelopes[envelopes.count].commitRevision
            == cursor.commitRevision + 1
    }

    @discardableResult
    public mutating func append(
        _ events: [CompetitionDomainEvent],
        expectedCursor: CompetitionJournalCursor
    ) throws -> CompetitionJournalAppendResult {
        var batchByID: [String: CompetitionDomainEvent] = [:]
        var uniqueEvents: [CompetitionDomainEvent] = []
        uniqueEvents.reserveCapacity(events.count)
        for event in events {
            if let prior = batchByID[event.semanticEventID] {
                guard prior == event else {
                    throw CompetitionJournalError.semanticEventConflict(
                        eventID: event.semanticEventID
                    )
                }
                continue
            }
            batchByID[event.semanticEventID] = event
            uniqueEvents.append(event)
        }

        let persisted = try CompetitionReplayer.decodedEvents(in: self)
        let persistedByID = Dictionary(
            uniqueKeysWithValues: persisted.map { ($0.semanticEventID, $0) }
        )
        var newEvents: [CompetitionDomainEvent] = []
        newEvents.reserveCapacity(uniqueEvents.count)
        for event in uniqueEvents {
            guard let prior = persistedByID[event.semanticEventID] else {
                newEvents.append(event)
                continue
            }
            guard prior == event else {
                throw CompetitionJournalError.semanticEventConflict(
                    eventID: event.semanticEventID
                )
            }
        }

        if newEvents.isEmpty {
            return CompetitionJournalAppendResult(
                cursor: cursor,
                appendedCount: 0
            )
        }
        guard expectedCursor == cursor else {
            throw CompetitionJournalError.cursorConflict(
                expected: expectedCursor,
                actual: cursor
            )
        }

        let appendCoordinates = try Self.validatedAppendCoordinates(
            after: cursor,
            newEventCount: newEvents.count
        )
        var workingProjection = try CompetitionReplayer.replay(self)
        for (offset, event) in newEvents.enumerated() {
            try CompetitionReplayer.apply(
                event,
                to: &workingProjection,
                sequence: appendCoordinates.sequences[offset]
            )
        }

        var candidateEnvelopes = envelopes
        candidateEnvelopes.reserveCapacity(envelopes.count + newEvents.count)
        var previousDigest = cursor.tailDigest
        for (offset, event) in newEvents.enumerated() {
            let sequence = appendCoordinates.sequences[offset]
            let payload = try JournalPinnedCodec.encoder().encode(event)
            let envelope = CompetitionJournalEnvelope(
                commitRevision: appendCoordinates.commitRevision,
                sequence: sequence,
                streamID: genesis.competitionID,
                semanticEventID: event.semanticEventID,
                payload: payload,
                previousEnvelopeSHA256: previousDigest
            )
            candidateEnvelopes.append(envelope)
            previousDigest = envelope.envelopeSHA256
        }
        let candidateCursor = CompetitionJournalCursor(
            commitRevision: appendCoordinates.commitRevision,
            eventCount: UInt64(candidateEnvelopes.count),
            tailDigest: previousDigest
        )
        let candidateDigest = Self.digest(
            journalVersion: journalVersion,
            genesisDigest: genesisDigest,
            cursor: candidateCursor
        )
        let candidate = Self(
            uncheckedJournalVersion: journalVersion,
            genesis: genesis,
            genesisDigest: genesisDigest,
            envelopes: candidateEnvelopes,
            cursor: candidateCursor,
            documentDigest: candidateDigest
        )
        _ = try CompetitionReplayer.replay(candidate)

        envelopes = candidateEnvelopes
        cursor = candidateCursor
        documentDigest = candidateDigest
        return CompetitionJournalAppendResult(
            cursor: candidateCursor,
            appendedCount: newEvents.count
        )
    }

    internal static func validatedAppendCoordinates(
        after cursor: CompetitionJournalCursor,
        newEventCount: Int
    ) throws -> (commitRevision: UInt64, sequences: [UInt64]) {
        precondition(newEventCount >= 0)
        let unsignedCount = UInt64(newEventCount)
        guard cursor.eventCount <= UInt64.max - unsignedCount else {
            throw CompetitionJournalError.sequenceOverflow
        }
        guard cursor.commitRevision < UInt64.max else {
            throw CompetitionJournalError.commitRevisionOverflow
        }
        let firstSequence = cursor.eventCount + 1
        return (
            cursor.commitRevision + 1,
            (0..<newEventCount).map { firstSequence + UInt64($0) }
        )
    }

    private init(
        uncheckedJournalVersion: UInt32,
        genesis: CompetitionGenesis,
        genesisDigest: String,
        envelopes: [CompetitionJournalEnvelope],
        cursor: CompetitionJournalCursor,
        documentDigest: String
    ) {
        self.journalVersion = uncheckedJournalVersion
        self.genesis = genesis
        self.genesisDigest = genesisDigest
        self.envelopes = envelopes
        self.cursor = cursor
        self.documentDigest = documentDigest
    }

    private enum CodingKeys: String, CodingKey {
        case journalVersion
        case genesis
        case genesisDigest
        case envelopes
        case cursor
        case documentDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let journalVersion = try container.decode(
            UInt32.self,
            forKey: .journalVersion
        )
        guard journalVersion == Self.currentJournalVersion else {
            throw CompetitionJournalError.upgradeRequiredJournalVersion(
                found: journalVersion
            )
        }
        let decoded = Self(
            uncheckedJournalVersion: journalVersion,
            genesis: try container.decode(
                CompetitionGenesis.self,
                forKey: .genesis
            ),
            genesisDigest: try container.decode(
                String.self,
                forKey: .genesisDigest
            ),
            envelopes: try container.decode(
                [CompetitionJournalEnvelope].self,
                forKey: .envelopes
            ),
            cursor: try container.decode(
                CompetitionJournalCursor.self,
                forKey: .cursor
            ),
            documentDigest: try container.decode(
                String.self,
                forKey: .documentDigest
            )
        )
        try decoded.validateDocument()
        self = decoded
    }

    private func validateDocument() throws {
        try CompetitionJournalEnvelope.validateDigest(
            genesisDigest,
            field: "genesisDigest"
        )
        try CompetitionJournalEnvelope.validateDigest(
            cursor.tailDigest,
            field: "cursor.tailDigest"
        )
        try CompetitionJournalEnvelope.validateDigest(
            documentDigest,
            field: "documentDigest"
        )
        guard try Self.digest(genesis: genesis) == genesisDigest else {
            throw CompetitionJournalError.genesisDigestMismatch
        }
        guard cursor.eventCount == UInt64(envelopes.count) else {
            throw CompetitionJournalError.cursorMismatch
        }
        let derivedTail = envelopes.last?.envelopeSHA256 ?? genesisDigest
        let derivedRevision = envelopes.last?.commitRevision ?? 0
        guard cursor.tailDigest == derivedTail,
              cursor.commitRevision == derivedRevision
        else {
            throw CompetitionJournalError.cursorMismatch
        }
        guard Self.digest(
            journalVersion: journalVersion,
            genesisDigest: genesisDigest,
            cursor: cursor
        ) == documentDigest else {
            throw CompetitionJournalError.documentDigestMismatch
        }
        _ = try CompetitionReplayer.replay(self)
    }

    private static func digest(genesis: CompetitionGenesis) throws -> String {
        // Genesis commitment v1 is independent of JSON number/date rendering:
        // domain, schema, UUID, direction, reference-date IEEE bits, optional
        // expiry, scoring-policy identity, and downward-revision policy. Strings
        // are UInt64-length-prefixed; integers are fixed-width big-endian.
        var bytes = JournalCanonicalBytes()
        bytes.append("healthcomp.competition-genesis")
        bytes.append(genesis.version)
        bytes.append(genesis.competitionID.rawValue.uuidString.lowercased())
        bytes.append(genesis.direction.rawValue)
        bytes.append(
            normalizedBitPattern(genesis.createdAt.timeIntervalSinceReferenceDate)
        )
        if let expiresAt = genesis.expiresAt {
            bytes.append(UInt32(1))
            bytes.append(
                normalizedBitPattern(expiresAt.timeIntervalSinceReferenceDate)
            )
        } else {
            bytes.append(UInt32(0))
        }
        bytes.append(genesis.scoringPolicy.identity.rawValue)
        bytes.append(genesis.downwardRevisionPolicy.rawValue)
        return SHA256Digest.hexDigest(bytes.data)
    }

    private static func normalizedBitPattern(_ value: Double) -> UInt64 {
        (value == 0 ? 0.0 : value).bitPattern
    }

    private static func digest(
        journalVersion: UInt32,
        genesisDigest: String,
        cursor: CompetitionJournalCursor
    ) -> String {
        var bytes = JournalCanonicalBytes()
        bytes.append("healthcomp.competition-journal-document")
        bytes.append(journalVersion)
        bytes.append(genesisDigest)
        bytes.append(cursor.commitRevision)
        bytes.append(cursor.eventCount)
        bytes.append(cursor.tailDigest)
        return SHA256Digest.hexDigest(bytes.data)
    }
}

// MARK: - Pure replay

public enum CompetitionReplayer {
    public static func replay(
        _ journal: CompetitionJournal
    ) throws -> CompetitionReplayProjection {
        var projection = CompetitionReplayProjection(
            competition: journal.genesis.makeCompetition(),
            scoreLedger: journal.genesis.makeScoreLedger(),
            activityRefresh: ActivityRefreshProjection(),
            notificationEmissions: NotificationEmissionProjection()
        )
        let events = try decodedEvents(in: journal)
        for (offset, event) in events.enumerated() {
            let envelope = journal.envelopes[offset]
            if envelope.payloadVersion >= 2,
               case let .lifecycle(lifecycleEvent) = event,
               case let .finalReadRecorded(record) = lifecycleEvent.kind {
                try validateFinalReadSourceBinding(
                    record.evidence,
                    at: offset,
                    events: events,
                    envelopes: journal.envelopes,
                    projection: projection
                )
            }
            try apply(event, to: &projection, sequence: UInt64(offset + 1))
        }
        return projection
    }

    internal static func decodedEvents(
        in journal: CompetitionJournal
    ) throws -> [CompetitionDomainEvent] {
        var result: [CompetitionDomainEvent] = []
        result.reserveCapacity(journal.envelopes.count)
        var priorDigest = journal.genesisDigest
        var seenIDs = Set<String>()
        var priorCommitRevision: UInt64 = 0
        var priorPayloadVersion: UInt32 = 0

        for (offset, envelope) in journal.envelopes.enumerated() {
            let expectedSequence = UInt64(offset + 1)
            try envelope.validated(
                expectedSequence: expectedSequence,
                expectedPreviousDigest: priorDigest,
                expectedStreamID: journal.genesis.competitionID
            )
            guard envelope.payloadVersion >= priorPayloadVersion else {
                throw CompetitionJournalError.payloadVersionDowngrade(
                    sequence: envelope.sequence
                )
            }
            if offset == 0 {
                guard envelope.commitRevision == 1 else {
                    throw CompetitionJournalError.commitRevisionViolation(
                        sequence: envelope.sequence
                    )
                }
            } else if envelope.commitRevision != priorCommitRevision,
                      envelope.commitRevision != priorCommitRevision + 1 {
                throw CompetitionJournalError.commitRevisionViolation(
                    sequence: envelope.sequence
                )
            }
            guard seenIDs.insert(envelope.semanticEventID).inserted else {
                throw CompetitionJournalError.duplicatePersistedSemanticEventID(
                    eventID: envelope.semanticEventID
                )
            }
            let event: CompetitionDomainEvent
            do {
                switch envelope.payloadVersion {
                case 1:
                    event = try JournalPinnedCodec.decoder().decode(
                        CompetitionDomainEventV1.self,
                        from: envelope.payload
                    ).upgraded()
                case 2:
                    event = try JournalPinnedCodec.decoder().decode(
                        CompetitionDomainEventV2.self,
                        from: envelope.payload
                    ).upgraded()
                case 3:
                    event = try JournalPinnedCodec.decoder().decode(
                        CompetitionDomainEventV3.self,
                        from: envelope.payload
                    ).upgraded()
                case 4:
                    event = try JournalPinnedCodec.decoder().decode(
                        CompetitionDomainEvent.self,
                        from: envelope.payload
                    )
                default:
                    throw CompetitionJournalError
                        .upgradeRequiredPayloadVersion(
                            sequence: envelope.sequence,
                            found: envelope.payloadVersion
                        )
                }
            } catch let error as CompetitionJournalError {
                throw error
            } catch is ActivitySnapshotRecorded.ValidationError {
                throw CompetitionJournalError.invalidActivityObservation(
                    sequence: envelope.sequence
                )
            } catch is ActivityRefreshAttemptRecorded.ValidationError {
                throw CompetitionJournalError.invalidActivityRefreshAttempt(
                    sequence: envelope.sequence
                )
            } catch {
                throw CompetitionJournalError.invalidDomainTransition(
                    sequence: envelope.sequence
                )
            }
            if envelope.payloadVersion < 3,
               case .notificationEmissionRecorded = event {
                throw CompetitionJournalError.invalidDomainTransition(
                    sequence: envelope.sequence
                )
            }
            if envelope.payloadVersion < 4 {
                switch event {
                case .remoteConfigurationAccepted, .remoteScoreRevisionRecorded,
                     .remoteFinalWindowAttested, .sharedResultConfirmed,
                     .synchronizationReceiptRecorded:
                    throw CompetitionJournalError.invalidDomainTransition(sequence: envelope.sequence)
                default:
                    break
                }
            }
            if envelope.payloadVersion >= 2,
               case .activitySnapshotRecorded = event {
                throw CompetitionJournalError
                    .standaloneActivitySnapshotRequiresPayloadV1(
                        sequence: envelope.sequence
                    )
            }
            guard event.competitionID == envelope.streamID,
                  event.semanticEventID == envelope.semanticEventID
            else {
                throw CompetitionJournalError.envelopeIdentityMismatch(
                    sequence: envelope.sequence
                )
            }
            if case let .synchronizationReceiptRecorded(receipt) = event {
                let acknowledged = result.first { $0.semanticEventID == receipt.acknowledgedEventID }
                let kindAndSequenceMatch: Bool
                switch (receipt.kind, acknowledged) {
                case let (.scoreRevision, .some(.remoteScoreRevisionRecorded(revision))):
                    kindAndSequenceMatch = receipt.entityServerSequence == revision.row.serverSequence
                case let (.finalWindowAttestation, .some(.remoteFinalWindowAttested(attestation))):
                    kindAndSequenceMatch = receipt.entityServerSequence == attestation.serverSequence
                default:
                    kindAndSequenceMatch = false
                }
                guard kindAndSequenceMatch else { throw CompetitionJournalError.invalidDomainTransition(sequence: envelope.sequence) }
            }
            result.append(event)
            priorDigest = envelope.envelopeSHA256
            priorCommitRevision = envelope.commitRevision
            priorPayloadVersion = envelope.payloadVersion
        }
        return result
    }

    internal static func apply(
        _ event: CompetitionDomainEvent,
        to projection: inout CompetitionReplayProjection,
        sequence: UInt64
    ) throws {
        var workingCompetition = projection.competition
        var workingLedger = projection.scoreLedger
        var workingActivityRefresh = projection.activityRefresh
        var workingNotificationEmissions = projection.notificationEmissions
        var workingRemoteLedgers = projection.remoteScoreLedgers
        var workingAttestations = projection.remoteWindowAttestations
        var workingSynchronizationCursor = projection.synchronizationCursor
        var workingSharedResult = projection.sharedResult
        do {
            switch event {
            case let .remoteConfigurationAccepted(configuration):
                guard configuration.competitionID == workingCompetition.id,
                      case .pendingInvitation = workingCompetition.lifecycle,
                      workingCompetition.remoteConfiguration == nil
                else { throw CompetitionJournalError.invalidDomainTransition(sequence: sequence) }
                workingCompetition.schedule = configuration.acceptedSchedule
                workingCompetition.remoteConfiguration = configuration
                workingCompetition.lifecycle = .scheduled

            case let .remoteScoreRevisionRecorded(revision):
                guard let configuration = workingCompetition.remoteConfiguration,
                      revision.competitionID == workingCompetition.id,
                      revision.participant == configuration.owner || revision.participant == configuration.remote
                else { throw CompetitionJournalError.invalidDomainTransition(sequence: sequence) }
                switch workingCompetition.lifecycle {
                case .scheduled, .active, .endsToday, .tallying: break
                case .pendingInvitation, .declined, .expired, .completed, .archived:
                    throw CompetitionJournalError.invalidDomainTransition(sequence: sequence)
                }
                var ledger: RemoteScoreLedger
                if let existing = workingRemoteLedgers[revision.participant.profileID] {
                    ledger = existing
                } else {
                    ledger = try RemoteScoreLedger(competitionID: configuration.competitionID, participant: revision.participant, acceptedSchedule: configuration.acceptedSchedule, scoringPolicyIdentity: configuration.scoringPolicyIdentity)
                }
                _ = try ledger.accept(revision.row)
                workingRemoteLedgers[revision.participant.profileID] = ledger

            case let .remoteFinalWindowAttested(attestation):
                guard let configuration = workingCompetition.remoteConfiguration,
                      attestation.competitionID == configuration.competitionID,
                      attestation.participant == configuration.owner,
                      { if case .tallying = workingCompetition.lifecycle { return true }; return false }(),
                      let ledger = workingRemoteLedgers[attestation.participant.profileID]
                else { throw CompetitionJournalError.invalidDomainTransition(sequence: sequence) }
                let vector = try (1...7).map { try ledger.visibleEntry(forActiveDayOrdinal: $0)?.clientRevision ?? 0 }
                guard vector == attestation.acceptedRevisions else { throw CompetitionJournalError.invalidDomainTransition(sequence: sequence) }
                if attestation.basis == .stable {
                    guard vector.allSatisfy({ $0 > 0 }), try remoteWindowCommitment(ledger: ledger, competitionID: configuration.competitionID, participant: configuration.owner, deadlineMissingAllowed: false) == attestation.windowCommitment else { throw CompetitionJournalError.invalidDomainTransition(sequence: sequence) }
                } else {
                    guard attestation.attestedAt >= configuration.bestAvailableDeadline,
                          try remoteWindowCommitment(ledger: ledger, competitionID: configuration.competitionID, participant: configuration.owner, deadlineMissingAllowed: true) == attestation.windowCommitment else { throw CompetitionJournalError.invalidDomainTransition(sequence: sequence) }
                }
                if let prior = workingAttestations[attestation.participant.profileID] {
                    guard attestation.attestationVersion > prior.attestationVersion,
                          attestation.serverSequence > prior.serverSequence,
                          !(prior.basis == .stable && attestation.basis == .bestAvailable)
                    else { throw CompetitionJournalError.invalidDomainTransition(sequence: sequence) }
                    workingAttestations[attestation.participant.profileID] = attestation
                } else {
                    workingAttestations[attestation.participant.profileID] = attestation
                }

            case let .sharedResultConfirmed(result):
                guard let configuration = workingCompetition.remoteConfiguration,
                      result.competitionID == configuration.competitionID,
                      result.owner == configuration.owner,
                      result.remote == configuration.remote,
                      let ownerResultWindow = try? result.window(for: configuration.owner),
                      let ownerLedger = workingRemoteLedgers[configuration.owner.profileID]
                else { throw CompetitionJournalError.invalidDomainTransition(sequence: sequence) }
                if result.basis == .stable {
                    guard result.windows.allSatisfy({ $0.days.allSatisfy { $0.source == .acceptedRevision } }) else { throw CompetitionJournalError.invalidDomainTransition(sequence: sequence) }
                } else {
                    guard result.confirmedAt >= configuration.bestAvailableDeadline else { throw CompetitionJournalError.invalidDomainTransition(sequence: sequence) }
                }
                guard try resultWindowMatchesCachedLedger(ownerResultWindow, ledger: ownerLedger, requireAllRows: result.basis == .stable) else { throw CompetitionJournalError.invalidDomainTransition(sequence: sequence) }
                let remoteResultWindow = try result.window(for: configuration.remote)
                if let remoteLedger = workingRemoteLedgers[configuration.remote.profileID] {
                    guard try resultWindowMatchesCachedLedger(remoteResultWindow, ledger: remoteLedger, requireAllRows: false, allowUncachedAcceptedRows: true)
                    else { throw CompetitionJournalError.invalidDomainTransition(sequence: sequence) }
                }
                guard case .tallying = workingCompetition.lifecycle else { throw CompetitionJournalError.invalidDomainTransition(sequence: sequence) }
                let ownerPoints = Double(ownerResultWindow.totalCentiPoints) / 100
                let remotePoints = Double(remoteResultWindow.totalCentiPoints) / 100
                workingCompetition.lifecycle = .completed(CompletedCompetition(snapshot: try FinalScoreSnapshot(userPoints: ownerPoints, opponentPoints: remotePoints), basis: result.basis == .stable ? .stableAcrossPostBoundaryReads : .bestAvailable, completedAt: result.confirmedAt))
                workingSharedResult = result

            case let .synchronizationReceiptRecorded(receipt):
                guard receipt.competitionID == workingCompetition.id,
                      receipt.serverCursor > workingSynchronizationCursor
                else { throw CompetitionJournalError.invalidDomainTransition(sequence: sequence) }
                workingSynchronizationCursor = receipt.serverCursor

            case let .notificationEmissionRecorded(record):
                workingNotificationEmissions.record(record)

            case let .activityRefreshAttemptRecorded(attempt):
                // Remote journals are fed only by server-accepted remote rows.
                // A local HealthKit refresh is simulated-protocol evidence and
                // must never be allowed to mutate a remote competition.
                guard workingCompetition.remoteConfiguration == nil else {
                    throw CompetitionJournalError.invalidDomainTransition(
                        sequence: sequence
                    )
                }
                try apply(
                    attempt,
                    competition: workingCompetition,
                    scoreLedger: &workingLedger,
                    activityRefresh: &workingActivityRefresh,
                    sequence: sequence
                )

            case let .activitySnapshotRecorded(observation):
                guard workingCompetition.remoteConfiguration == nil else {
                    throw CompetitionJournalError.invalidDomainTransition(sequence: sequence)
                }
                guard workingCompetition.schedule != nil,
                      !workingLedger.isFrozen
                else {
                    throw CompetitionJournalError.invalidDomainTransition(
                        sequence: sequence
                    )
                }
                switch workingCompetition.lifecycle {
                case .scheduled, .active, .endsToday, .tallying:
                    break
                case .pendingInvitation, .declined, .expired, .completed, .archived:
                    throw CompetitionJournalError.invalidDomainTransition(
                        sequence: sequence
                    )
                }
                try workingLedger.record(
                    observation.snapshot,
                    forDayOrdinal: observation.dayOrdinal
                )

            case let .lifecycle(lifecycleEvent):
                if workingCompetition.remoteConfiguration != nil {
                    switch lifecycleEvent.kind {
                    case .finalReadRecorded, .competitionFinalized:
                        throw CompetitionJournalError.invalidDomainTransition(
                            sequence: sequence
                        )
                    default:
                        break
                    }
                }
                if case let .finalReadRecorded(record) = lifecycleEvent.kind,
                   let claimedContent = record.evidence.completeWindowContent {
                    guard let expectedContent = currentCompleteWindowContent(
                            competition: workingCompetition,
                            scoreLedger: workingLedger
                          ),
                          claimedContent == expectedContent
                    else {
                        throw CompetitionJournalError.ownerWindowMismatch(
                            sequence: sequence
                        )
                    }
                }
                if case .competitionFinalized = lifecycleEvent.kind {
                    guard case let .tallying(tally) = workingCompetition.lifecycle,
                          let expectedContent = currentCompleteWindowContent(
                            competition: workingCompetition,
                            scoreLedger: workingLedger
                          ),
                          tally.reconciliation.latestAttempt?
                            .completeWindowContent == expectedContent
                    else {
                        throw CompetitionJournalError.ownerWindowMismatch(
                            sequence: sequence
                        )
                    }
                }
                try CompetitionEngine().apply(
                    lifecycleEvent,
                    to: &workingCompetition
                )
                if case .competitionFinalized = lifecycleEvent.kind {
                    _ = try workingLedger.freeze()
                }
            }
        } catch let error as CompetitionJournalError {
            throw error
        } catch {
            throw CompetitionJournalError.invalidDomainTransition(
                sequence: sequence
            )
        }
        projection = CompetitionReplayProjection(
            competition: workingCompetition,
            scoreLedger: workingLedger,
            activityRefresh: workingActivityRefresh,
            notificationEmissions: workingNotificationEmissions
            , remoteScoreLedgers: workingRemoteLedgers
            , remoteWindowAttestations: workingAttestations
            , synchronizationCursor: workingSynchronizationCursor
            , sharedResult: workingSharedResult
        )
    }

    private static func apply(
        _ attempt: ActivityRefreshAttemptRecorded,
        competition: Competition,
        scoreLedger: inout ScoreLedger,
        activityRefresh: inout ActivityRefreshProjection,
        sequence: UInt64
    ) throws {
        guard competition.remoteConfiguration == nil,
              attempt.competitionID == competition.id,
              let schedule = competition.schedule,
              !scoreLedger.isFrozen
        else {
            throw CompetitionJournalError.invalidDomainTransition(
                sequence: sequence
            )
        }
        switch competition.lifecycle {
        case .scheduled, .active, .endsToday, .tallying:
            break
        case .pendingInvitation, .declined, .expired, .completed, .archived:
            throw CompetitionJournalError.invalidDomainTransition(
                sequence: sequence
            )
        }

        let expectedDays = try schedule.calendar.sevenDayWindow(
            startingOn: schedule.startDay
        )
        for observation in attempt.days {
            guard observation.day == expectedDays[observation.ordinal - 1] else {
                throw CompetitionJournalError.activityRefreshDayMismatch(
                    ordinal: observation.ordinal
                )
            }
            let dayStart = try schedule.calendar.startOfDay(observation.day)
            let isNotYetOccurred: Bool
            if case .notYetOccurred = observation.availability {
                isNotYetOccurred = true
            } else {
                isNotYetOccurred = false
            }
            if isNotYetOccurred != (attempt.readAt < dayStart) {
                throw CompetitionJournalError
                    .activityRefreshAvailabilityMismatch(
                        ordinal: observation.ordinal
                    )
            }
        }

        do {
            try activityRefresh.record(attempt)
        } catch let error as ActivityRefreshProjectionError {
            switch error {
            case let .ordinalViolation(expected, found):
                throw CompetitionJournalError
                    .activityRefreshAttemptOrdinalViolation(
                        expected: expected,
                        found: found
                    )
            case let .duplicateAttemptID(attemptID):
                throw CompetitionJournalError
                    .duplicateActivityRefreshAttemptID(attemptID)
            case .ordinalOverflow:
                throw CompetitionJournalError
                    .activityRefreshAttemptOrdinalOverflow
            }
        }

        for observation in attempt.days {
            guard case let .observed(snapshot) = observation.availability else {
                continue
            }
            try scoreLedger.record(
                snapshot,
                forDayOrdinal: observation.ordinal
            )
        }
    }

    internal static func currentCompleteWindowContent(
        competition: Competition,
        scoreLedger: ScoreLedger
    ) -> CompleteWindowContent? {
        guard let ownerWindow = scoreLedger.completeLiveWindowObservation(),
              let opponentPlan = competition.opponentPlan
        else {
            return nil
        }
        return try? opponentPlan.finalScoreWindow.completeWindowContent(
            ownerWindow: ownerWindow
        )
    }

    private static func remoteWindowCommitment(
        ledger: RemoteScoreLedger,
        competitionID: CompetitionID,
        participant: RemoteParticipant,
        deadlineMissingAllowed: Bool
    ) throws -> String {
        let days = try (1...7).map { ordinal -> RemoteFinalizationDayV1 in
            if let row = try ledger.visibleEntry(forActiveDayOrdinal: ordinal) {
                if let points = row.acceptedCentiPoints {
                    return try RemoteFinalizationDayV1(ordinal: ordinal, status: .points, source: .acceptedRevision, points: points, reason: nil, wireContentSHA256: row.wireContentSHA256, clientRevision: row.clientRevision, serverSequence: row.serverSequence)
                }
                return try RemoteFinalizationDayV1(ordinal: ordinal, status: .unavailable, source: .acceptedRevision, points: nil, reason: row.availabilityReason, wireContentSHA256: row.wireContentSHA256, clientRevision: row.clientRevision, serverSequence: row.serverSequence)
            }
            guard deadlineMissingAllowed else { throw CompetitionJournalError.invalidDomainTransition(sequence: 0) }
            return try RemoteFinalizationDayV1(ordinal: ordinal, status: .unavailable, source: .deadlineMissing, points: nil, reason: "missing", wireContentSHA256: nil, clientRevision: nil, serverSequence: nil)
        }
        return try RemoteFinalizationWireV1.windowCommitment(competitionID: competitionID.rawValue, participantID: participant.profileID, days: days)
    }

    private static func resultWindowMatchesCachedLedger(_ window: SharedParticipantWindow, ledger: RemoteScoreLedger, requireAllRows: Bool, allowUncachedAcceptedRows: Bool = false) throws -> Bool {
        for day in window.days {
            let cached = try ledger.visibleEntry(forActiveDayOrdinal: day.ordinal)
            if let cached {
                guard day.source == .acceptedRevision,
                      day.centiPoints == cached.acceptedCentiPoints,
                      day.reason == cached.availabilityReason,
                      day.wireContentSHA256 == cached.wireContentSHA256,
                      day.clientRevision == cached.clientRevision,
                      day.serverSequence == cached.serverSequence else { return false }
            } else if requireAllRows || (day.source == .acceptedRevision && !allowUncachedAcceptedRows) { return false }
        }
        return true
    }

    private static func validateFinalReadSourceBinding(
        _ evidence: FinalReadEvidence,
        at offset: Int,
        events: [CompetitionDomainEvent],
        envelopes: [CompetitionJournalEnvelope],
        projection: CompetitionReplayProjection
    ) throws {
        let sequence = UInt64(offset + 1)
        guard offset > 0,
              envelopes[offset - 1].payloadVersion >= 2,
              envelopes[offset - 1].commitRevision
                == envelopes[offset].commitRevision,
              case let .activityRefreshAttemptRecorded(refresh) = events[offset - 1],
              evidence.attemptID == refresh.attemptID,
              evidence.readAt == refresh.readAt,
              evidence.monotonicInstant == refresh.monotonicInstant,
              let expected = try? projection.derivedFinalReadEvidence(
                  boundTo: refresh
              ),
              evidence == expected
        else {
            throw CompetitionJournalError.finalReadSourceBindingMismatch(
                sequence: sequence
            )
        }
    }
}

public extension CompetitionReplayProjection {
    /// Builds the evidence that must be appended immediately after `refresh`
    /// in the same journal commit. The receiver remains unchanged.
    func finalReadEvidence(
        after refresh: ActivityRefreshAttemptRecorded
    ) throws -> FinalReadEvidence {
        guard case .tallying = competition.lifecycle else {
            throw ActivityRefreshEvidenceError.competitionNotTallying
        }
        guard refresh.competitionID == competition.id else {
            throw ActivityRefreshEvidenceError.refreshForDifferentCompetition
        }

        var candidate = self
        do {
            try CompetitionReplayer.apply(
                .activityRefreshAttemptRecorded(refresh),
                to: &candidate,
                sequence: 0
            )
        } catch {
            throw ActivityRefreshEvidenceError.invalidRefreshTransition
        }
        return try candidate.derivedFinalReadEvidence(boundTo: refresh)
    }

    fileprivate func derivedFinalReadEvidence(
        boundTo refresh: ActivityRefreshAttemptRecorded
    ) throws -> FinalReadEvidence {
        guard activityRefresh.latestAttempt == refresh else {
            throw ActivityRefreshEvidenceError.refreshProjectionMismatch
        }

        var evaluableOrdinals = Set<Int>()
        var acceptedScoreOrdinals = Set<Int>()
        var missingOrdinals = Set<Int>()
        var unavailableOrdinals = Set<Int>()

        for observation in refresh.days {
            switch observation.availability {
            case .notYetOccurred, .missing:
                missingOrdinals.insert(observation.ordinal)
            case .unavailable:
                unavailableOrdinals.insert(observation.ordinal)
            case let .observed(snapshot):
                guard let entry = scoreLedger.entry(
                    forDayOrdinal: observation.ordinal
                ), entry.latestEvidence.snapshot == snapshot else {
                    throw ActivityRefreshEvidenceError.refreshProjectionMismatch
                }
                guard entry.latestEvidence.result.availableScore != nil else {
                    unavailableOrdinals.insert(observation.ordinal)
                    continue
                }
                evaluableOrdinals.insert(observation.ordinal)
                if entry.acceptedScore != nil {
                    acceptedScoreOrdinals.insert(observation.ordinal)
                }
            }
        }

        let completeContent: CompleteWindowContent?
        if evaluableOrdinals == Set(1...7),
           missingOrdinals.isEmpty,
           unavailableOrdinals.isEmpty {
            completeContent = CompetitionReplayer.currentCompleteWindowContent(
                competition: competition,
                scoreLedger: scoreLedger
            )
        } else {
            completeContent = nil
        }

        return try FinalReadEvidence(
            attemptID: refresh.attemptID,
            readAt: refresh.readAt,
            monotonicInstant: refresh.monotonicInstant,
            evaluableOrdinals: evaluableOrdinals,
            acceptedScoreOrdinals: acceptedScoreOrdinals,
            missingOrdinals: missingOrdinals,
            unavailableOrdinals: unavailableOrdinals,
            completeWindowContent: completeContent,
            opponentPlanIsFinal: competition.opponentPlan != nil
        )
    }
}

// MARK: - Adapter seam

public enum CompetitionJournalLoadSource: Equatable, Sendable {
    case primary
    case recoveredPrevious
}

public struct LoadedCompetitionJournal: Equatable, Sendable {
    public let journal: CompetitionJournal
    public let projection: CompetitionReplayProjection
    public let source: CompetitionJournalLoadSource

    public init(
        journal: CompetitionJournal,
        source: CompetitionJournalLoadSource
    ) throws {
        self.journal = journal
        self.projection = try CompetitionReplayer.replay(journal)
        self.source = source
    }
}

public enum CompetitionEventStoreError: Error, Equatable, Sendable {
    case identityAlreadyExists
    case identityWasDeleted
    case identityNotFound
    case cursorConflict(
        expected: CompetitionJournalCursor,
        actual: CompetitionJournalCursor
    )
    case journal(CompetitionJournalError)
}

public struct CompetitionEventStoreCreateResult: Equatable, Sendable {
    public let cursor: CompetitionJournalCursor
    public let created: Bool

    public init(cursor: CompetitionJournalCursor, created: Bool) {
        self.cursor = cursor
        self.created = created
    }
}

public protocol CompetitionEventStore: Sendable {
    func ids() async throws -> [CompetitionID]
    func load(_ id: CompetitionID) async throws -> LoadedCompetitionJournal?
    func create(
        _ genesis: CompetitionGenesis
    ) async throws -> CompetitionEventStoreCreateResult
    func append(
        _ events: [CompetitionDomainEvent],
        to id: CompetitionID,
        expectedCursor: CompetitionJournalCursor
    ) async throws -> CompetitionJournalAppendResult
    /// A live stream is deleted only when this cursor still matches under the
    /// store's lock. After the durable tombstone commit point, retries are
    /// idempotent regardless of the supplied cursor.
    func delete(
        _ id: CompetitionID,
        expectedCursor: CompetitionJournalCursor
    ) async throws
}

private enum JournalPinnedCodec {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.nonConformingFloatEncodingStrategy = .throw
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        decoder.nonConformingFloatDecodingStrategy = .throw
        return decoder
    }
}

private struct JournalCanonicalBytes {
    private(set) var data = Data()

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

    mutating func append(_ value: String) {
        let valueData = Data(value.utf8)
        append(UInt64(valueData.count))
        data.append(valueData)
    }
}
