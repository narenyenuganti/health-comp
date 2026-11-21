import CompetitionCore
import Foundation

enum CompetitionRemoteFailure: Error, Equatable, Sendable {
    case cancelled
    case unauthenticated
    case forbidden
    case notFound
    case inviteUnavailable
    case recipientUnavailable
    case pendingInvitationExists
    case activeMatchExists
    case incomingChallengeExists
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
    case groupUpdateRequired(profileID: UUID?, displayName: String? = nil)
    case groupCreationLimit
    case invalidUsername
    case usernameUnavailable
    case searchRateLimited
    case invalidFriendSettings
    case invalidQuery
    case invalidProfileID
    case invalidFriendRequestResponse
    case friendRequestLimit
    case requestUnavailable
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
    var competitionExists: @Sendable (UUID) async throws -> Bool = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
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
    var listReactions: @Sendable () async throws -> [CompetitionReactionRecord] = {
        throw CompetitionRemoteFailure.operationFailed
    }
    var setReaction: @Sendable (CompetitionReactionRequest) async throws -> Void = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var listSleepScoring: @Sendable () async throws -> [CompetitionSleepMatch] = {
        throw CompetitionRemoteFailure.operationFailed
    }
    var enableSleepScoring: @Sendable (UUID) async throws -> Void = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var listCompetitionMetrics: @Sendable () async throws -> [CompetitionMetricsRecord] = {
        []
    }
    var setCompetitionMetrics: @Sendable (UUID, CompetitionMetrics) async throws -> Void = { _, _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var submitSleepNight: @Sendable (CompetitionSleepNight, _ competitionID: UUID) async throws -> Void = { _, _ in
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
    var blockChallenger: @Sendable (UUID) async throws -> Void = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var listBlockedProfiles: @Sendable () async throws -> [AuthenticatedProfile] = {
        throw CompetitionRemoteFailure.operationFailed
    }
    var unblockProfile: @Sendable (UUID) async throws -> Void = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var nudgeCompetitionParticipant: @Sendable (UUID) async throws -> Date = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var loadChallengeLinkCode: @Sendable () async throws -> CompetitionChallengeLinkCode = {
        throw CompetitionRemoteFailure.operationFailed
    }
    var resetChallengeLinkCode: @Sendable () async throws -> CompetitionChallengeLinkCode = {
        throw CompetitionRemoteFailure.operationFailed
    }
    var resolveChallengeLink: @Sendable (
        CompetitionChallengeLinkCode
    ) async throws -> String = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var listProfilePhotos: @Sendable ([UUID]) async throws -> [ProfilePhotoReference] = { _ in [] }
    var setProfilePhoto: @Sendable (ProfilePhotoReference, Data) async throws -> Void = { _, _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var ownProfilePhoto: @Sendable (_ ownerProfileID: UUID) async throws -> OwnProfilePhoto = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var clearProfilePhoto: @Sendable () async throws -> Void = {
        throw CompetitionRemoteFailure.operationFailed
    }
    var removeProfilePhotoObjects: @Sendable (
        _ ownerProfileID: UUID,
        _ keeping: UUID?
    ) async throws -> Void = { _, _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var downloadProfilePhoto: @Sendable (ProfilePhotoReference) async throws -> Data = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var reportProfilePhoto: @Sendable (UUID) async throws -> Void = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var getFriendSettings: @Sendable () async throws -> FriendSettings = {
        throw CompetitionRemoteFailure.operationFailed
    }
    var setUsername: @Sendable (String) async throws -> FriendSettings = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var usernameAvailable: @Sendable (String) async throws -> Bool = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var updateFriendSettings: @Sendable (
        _ showInSearch: Bool,
        _ challengePolicy: FriendChallengePolicy
    ) async throws -> FriendSettings = { _, _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var getCareerSummary: @Sendable (UUID) async throws -> CompetitionCareer? = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var getCareerSharing: @Sendable () async throws -> Bool = {
        throw CompetitionRemoteFailure.operationFailed
    }
    var setCareerSharing: @Sendable (Bool) async throws -> Bool = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var listFriends: @Sendable () async throws -> FriendsList = {
        throw CompetitionRemoteFailure.operationFailed
    }
    var searchPeople: @Sendable (String) async throws -> [FriendPerson] = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var sendFriendRequest: @Sendable (UUID) async throws -> FriendRelationship = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var respondToFriendRequest: @Sendable (
        _ profileID: UUID,
        _ accept: Bool
    ) async throws -> FriendRelationship = { _, _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var removeFriend: @Sendable (UUID) async throws -> FriendRelationship = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var blockProfile: @Sendable (UUID) async throws -> AuthenticatedProfile = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var reportProfile: @Sendable (UUID) async throws -> Void = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    var listGroupMatches: @Sendable () async throws -> Data = {
        throw CompetitionRemoteFailure.operationFailed
    }
    var sendGroupMatchCommand: @Sendable (GroupMatchRemoteCommand) async throws -> UUID = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
}

struct CompetitionInvitePreview: Equatable, Sendable {
    enum State: String, Equatable, Sendable { case pending, accepted }

    let competitionID: UUID
    let state: State
    let sender: AuthenticatedProfile
    let timeZoneIdentifier: String
    let expiresAt: Date
}

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
        let other: AuthenticatedProfile
        let closedAt: Date
    }

    var incoming: [Incoming]
    var closed: [Closed]

    static let empty = Self(incoming: [], closed: [])
}

struct CompetitionReactionRecord: Equatable, Sendable {
    let competitionID: UUID
    let target: CompetitionReactionTarget
    let authorProfileID: UUID
    let kind: CompetitionReactionKind
    let updatedAt: Date
}

struct CompetitionSleepNight: Equatable, Sendable {
    let profileID: UUID
    let dayOrdinal: Int
    let basisPoints: Int
}

struct CompetitionSleepMatch: Equatable, Sendable {
    let competitionID: UUID
    let nights: [CompetitionSleepNight]
}

struct CompetitionMetricsRecord: Equatable, Sendable {
    let competitionID: UUID
    let metrics: CompetitionMetrics
}

struct CompetitionReactionRequest: Equatable, Sendable {
    let competitionID: UUID
    let target: CompetitionReactionTarget
    let kind: CompetitionReactionKind?
}

enum CompetitionRemoteTransportRequest: Equatable, Sendable {
    case rpc(name: String, parameters: Data)
    case function(name: String, body: Data)
    case listCompetitions
    case fetchCompetition(UUID)
    case competitionPresence(UUID)
    case uploadProfilePhoto(path: String, data: Data)
    case downloadProfilePhoto(path: String)
    case listProfilePhotoFolder(UUID)
    case removeProfilePhotos(paths: [String])
}

struct CompetitionRemoteTransportResponse: Equatable, Sendable {
    let statusCode: Int
    let data: Data
}

enum CompetitionRemoteTransportFailure: Error, Equatable, Sendable {
    case cancelled
    case network
    case relay
    case server(statusCode: Int?, code: String?, message: String, detail: String? = nil, hint: String? = nil)
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
