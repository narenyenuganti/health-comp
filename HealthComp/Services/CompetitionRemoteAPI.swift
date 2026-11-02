import Foundation

enum CompetitionRemoteFailure: Error, Equatable, Sendable {
    case cancelled
    case unauthenticated
    case forbidden
    case notFound
    case inviteUnavailable
    case recipientUnavailable
    case pendingInvitationExists
    /// The two people share a match whose week hasn't ended.
    case activeMatchExists
    /// The chosen person already challenged you.
    case incomingChallengeExists
    /// The challenge link is your own.
    case ownChallengeLink
    case divergentDuplicate
    case staleRevision
    case finalizedCompetition
    case retryableTransport
    case incompatiblePolicy
    case serverContractMismatch
    case accountDeletionUnavailable
    case appAttestUnavailable
    case appAttestRejected
    case appAttestContextUnavailable
    case appAttestProofConflict
    case operationFailed
}

struct CompetitionRemoteAPI: Sendable {
    var bootstrapProfile: @Sendable (
        _ suggestedDisplayName: String?
    ) async throws -> AuthenticatedProfile
    var updateProfile: @Sendable (
        _ displayName: String
    ) async throws -> AuthenticatedProfile
    var listCompetitions: @Sendable () async throws -> [CompetitionDescriptor]
    var fetchCompetition: @Sendable (
        _ competitionID: UUID
    ) async throws -> CompetitionDescriptor
    var createInvite: @Sendable (
        _ request: CompetitionInviteCreationRequest
    ) async throws -> CompetitionInvite
    var claimInvite: @Sendable (
        _ request: CompetitionInviteClaimRequest
    ) async throws -> CompetitionInviteClaim
    var archiveCompetition: @Sendable (
        _ competitionID: UUID
    ) async throws -> Void = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var appendScoreRevision: @Sendable (
        _ request: CompetitionScoreRevisionRequest
    ) async throws -> CompetitionScoreRevisionResponse
    var issueAppAttestChallenge: @Sendable (
        _ request: CompetitionAppAttestChallengeRequest
    ) async throws -> CompetitionAppAttestChallenge = { _ in
        throw CompetitionRemoteFailure.appAttestUnavailable
    }
    var submitAttestedScoreRevision: @Sendable (
        _ request: CompetitionAttestedScoreRevisionRequest
    ) async throws -> CompetitionScoreRevisionResponse = { _ in
        throw CompetitionRemoteFailure.appAttestUnavailable
    }
    var submitAttestation: @Sendable (
        _ request: CompetitionAttestationRequest
    ) async throws -> CompetitionAttestationReceipt
    var fetchChanges: @Sendable (
        _ cursor: CompetitionSynchronizationCursor,
        _ pageSize: Int
    ) async throws -> CompetitionChangePage
    var registerInstallation: @Sendable (
        _ request: CompetitionInstallationRequest
    ) async throws -> CompetitionInstallation
    var removeInstallation: @Sendable (
        _ installationID: UUID
    ) async throws -> CompetitionInstallation
    var loadMutedOpponentProfileIDs: @Sendable () async throws -> Set<UUID> = {
        throw CompetitionRemoteFailure.operationFailed
    }
    var setOpponentMuted: @Sendable (
        _ opponentProfileID: UUID,
        _ isMuted: Bool
    ) async throws -> Void = { _, _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var requestAccountDeletion: @Sendable () async throws -> Void
    var resolveInviteRecipient: @Sendable (UUID) async throws -> AuthenticatedProfile = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var listChallenges: @Sendable () async throws -> CompetitionChallengeList = {
        throw CompetitionRemoteFailure.operationFailed
    }
    var previewInvite: @Sendable (
        CompetitionInviteClaimRequest
    ) async throws -> CompetitionInvitePreview = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var acceptChallenge: @Sendable (UUID) async throws -> Void = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var declineChallenge: @Sendable (UUID) async throws -> Void = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var cancelCompetition: @Sendable (UUID) async throws -> Void = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    /// Asks the other person to open HealthComp; returns the time the server accepted the nudge.
    var nudgeCompetitionParticipant: @Sendable (UUID) async throws -> Date = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var loadChallengeLinkCode: @Sendable () async throws -> CompetitionChallengeLinkCode = {
        throw CompetitionRemoteFailure.operationFailed
    }
    /// Replaces your link's code; the old link stops working.
    var resetChallengeLinkCode: @Sendable () async throws -> CompetitionChallengeLinkCode = {
        throw CompetitionRemoteFailure.operationFailed
    }
    /// The link owner's display name; a link never gives out their account id.
    var resolveChallengeLink: @Sendable (
        CompetitionChallengeLinkCode
    ) async throws -> String = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
}

/// What the person a challenge was sent to may see before accepting it.
struct CompetitionInvitePreview: Equatable, Sendable {
    enum State: String, Equatable, Sendable { case pending, accepted }

    let competitionID: UUID
    let state: State
    let sender: AuthenticatedProfile
    let timeZoneIdentifier: String
    let expiresAt: Date
}

/// Challenges sent to you, and the last day's declines and cancels that the
/// other person did.
struct CompetitionChallengeList: Equatable, Sendable {
    struct Incoming: Equatable, Sendable {
        let competitionID: UUID
        let sender: AuthenticatedProfile
        let timeZoneIdentifier: String
        let createdAt: Date
        let expiresAt: Date
    }

    struct Closed: Equatable, Sendable {
        enum Kind: String, Equatable, Sendable { case declined, cancelled }

        let competitionID: UUID
        let kind: Kind
        /// "Former competitor" once that person deleted their account.
        let other: AuthenticatedProfile
        let closedAt: Date
    }

    var incoming: [Incoming]
    var closed: [Closed]

    static let empty = Self(incoming: [], closed: [])
}

enum CompetitionRemoteTransportRequest: Equatable, Sendable {
    case rpc(name: String, parameters: Data)
    case function(name: String, body: Data)
    case listCompetitions
    case fetchCompetition(UUID)
}

struct CompetitionRemoteTransportResponse: Equatable, Sendable {
    let statusCode: Int
    let data: Data
}

enum CompetitionRemoteTransportFailure: Error, Equatable, Sendable {
    case cancelled
    case network
    case relay
    case server(statusCode: Int?, code: String?, message: String)
    case other
}

struct CompetitionRemoteTransport: Sendable {
    var send: @Sendable (
        _ request: CompetitionRemoteTransportRequest
    ) async throws -> CompetitionRemoteTransportResponse

    init(
        _ send: @escaping @Sendable (
            _ request: CompetitionRemoteTransportRequest
        ) async throws -> CompetitionRemoteTransportResponse
    ) {
        self.send = send
    }
}
