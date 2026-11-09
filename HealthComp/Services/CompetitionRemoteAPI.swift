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
    case invalidUsername
    /// Taken or reserved; the server doesn't say which.
    case usernameUnavailable
    case searchRateLimited
    case invalidFriendSettings
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
    /// A successful, exact-ID lookup; transport failures are never absence.
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
    /// Both people's reactions in your matches, newest first.
    var listReactions: @Sendable () async throws -> [CompetitionReactionRecord] = {
        throw CompetitionRemoteFailure.operationFailed
    }
    /// A nil kind removes your reaction on that target.
    var setReaction: @Sendable (CompetitionReactionRequest) async throws -> Void = { _ in
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
    /// Declines the challenge (by competition id) and blocks its sender.
    var blockChallenger: @Sendable (UUID) async throws -> Void = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    /// The people you blocked, newest first.
    var listBlockedProfiles: @Sendable () async throws -> [AuthenticatedProfile] = {
        throw CompetitionRemoteFailure.operationFailed
    }
    /// Takes a profile id.
    var unblockProfile: @Sendable (UUID) async throws -> Void = { _ in
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
    /// The current photo of each of these people (at most 200 ids) that you
    /// may see, yours included. A missing id shows initials.
    var listProfilePhotos: @Sendable ([UUID]) async throws -> [ProfilePhotoReference] = { _ in [] }
    /// Uploads the processed JPEG at `reference` (your own id, a new version)
    /// and makes it your photo.
    var setProfilePhoto: @Sendable (ProfilePhotoReference, Data) async throws -> Void = { _, _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    /// Your own photo (`ownerProfileID` is you) and the review notice.
    var ownProfilePhoto: @Sendable (_ ownerProfileID: UUID) async throws -> OwnProfilePhoto = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    /// Shows initials from now on; the objects stay until removed.
    var clearProfilePhoto: @Sendable () async throws -> Void = {
        throw CompetitionRemoteFailure.operationFailed
    }
    /// Deletes every object in your folder except the `keeping` version.
    var removeProfilePhotoObjects: @Sendable (
        _ ownerProfileID: UUID,
        _ keeping: UUID?
    ) async throws -> Void = { _, _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    /// The JPEG, downloaded with your session (no public or signed URL).
    var downloadProfilePhoto: @Sendable (ProfilePhotoReference) async throws -> Data = { _ in
        throw CompetitionRemoteFailure.operationFailed
    }
    /// Reports this person's photo and hides their photos from you for good.
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

struct CompetitionReactionRecord: Equatable, Sendable {
    let competitionID: UUID
    let target: CompetitionReactionTarget
    let authorProfileID: UUID
    let kind: CompetitionReactionKind
    let updatedAt: Date
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
    /// The `profile-photos` bucket, with the caller's session.
    case uploadProfilePhoto(path: String, data: Data)
    case downloadProfilePhoto(path: String)
    /// Answers a JSON array of the object names in that folder.
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
