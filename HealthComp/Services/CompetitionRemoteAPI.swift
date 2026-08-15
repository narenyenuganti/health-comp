import Foundation

enum CompetitionRemoteFailure: Error, Equatable, Sendable {
    case cancelled
    case unauthenticated
    case forbidden
    case notFound
    case inviteUnavailable
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
