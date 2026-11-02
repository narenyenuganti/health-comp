import CompetitionCore
import Dependencies
import Foundation

// MARK: - Source-agnostic presentation compatibility

typealias CompetitionAcceptedPresentation = LocalCompetitionAcceptedPresentation
typealias CompetitionLifecyclePresentation = LocalCompetitionLifecyclePresentation
typealias CompetitionOwnerAvailability = LocalCompetitionOwnerAvailability
typealias CompetitionDayPresentation = LocalCompetitionDayPresentation
typealias CompetitionRefreshPresentation = LocalCompetitionRefreshPresentation
typealias CompetitionTallyAttention = LocalCompetitionTallyAttention
typealias CompetitionTallyPresentation = LocalCompetitionTallyPresentation
typealias CompetitionTerminalPresentation = LocalCompetitionTerminalPresentation
typealias CompetitionPresentation = LocalCompetitionPresentation
typealias CompetitionAward = LocalCompetitionAward
typealias CompetitionClientIssue = LocalCompetitionClientIssue
typealias CompetitionDashboard = LocalCompetitionDashboard
typealias CompetitionPublication = LocalCompetitionPublication

private extension CompetitionPublication {
    static let inert = CompetitionPublication(
        publicationRevision: 0,
        dashboard: CompetitionDashboard(
            competitions: [],
            awards: [],
            issues: [],
            hiddenTerminalCompetitionCount: 0
        )
    )
}

struct CompetitionInviteCreationOutcome: Equatable, Sendable {
    let invite: CompetitionInvite
    let expectedPublicationRevision: UInt64
}

struct CompetitionInviteClaimOutcome: Equatable, Sendable {
    let claim: CompetitionInviteClaim
    let expectedPublicationRevision: UInt64
}

/// The source-neutral dependency consumed by competition features.
///
/// Task 6 intentionally preserves the existing local endpoint surface and
/// presentation contract. Remote commands and transport arrive only once they
/// have executable behavior in later tasks.
struct CompetitionClient: Sendable {
    var start: @Sendable () -> AsyncStream<CompetitionPublication>
    var updates: @Sendable () -> AsyncStream<CompetitionPublication>
    var reconcileAll: @Sendable (
        ActivityRefreshTrigger
    ) async -> CompetitionPublication
    var accept: @Sendable (CompetitionID) async -> CompetitionPublication
    var decline: @Sendable (CompetitionID) async -> CompetitionPublication
    var archive: @Sendable (CompetitionID) async -> CompetitionPublication
    var rematch: @Sendable (CompetitionID) async -> CompetitionPublication
    var reinvite: @Sendable () async -> CompetitionPublication
    var delete: @Sendable (CompetitionID) async -> CompetitionPublication
    var reconcileNotifications: @Sendable () async -> Void
    var loadMutedOpponentIdentities: @Sendable () async throws -> Set<String>
    var setNotificationMuted: @Sendable (
        _ opponentIdentity: String,
        _ isMuted: Bool
    ) async throws -> Void
    var loadNotificationAuthorizationState: @Sendable () async ->
        CompetitionNotificationAuthorizationState?
    var requestNotificationAuthorization: @Sendable () async ->
        CompetitionNotificationAuthorizationState
    var waitUntil: @Sendable (Date) async throws -> Void
    var stop: @Sendable () async -> Void
    var prepareForProfileTeardownOperation: @Sendable (
        _ requireRemoteInstallationRemoval: Bool
    ) async throws -> Void
    var mountAuthenticatedProfile: @Sendable (
        AuthenticatedProfile,
        AuthenticatedProfileStoragePaths
    ) async throws -> Void
    var createInvite: @Sendable (
        CompetitionInviteCreationRequest
    ) async throws -> CompetitionInviteCreationOutcome
    var claimInvite: @Sendable (
        CompetitionInviteClaimRequest
    ) async throws -> CompetitionInviteClaimOutcome
    var resolveInviteRecipient: @Sendable (UUID) async throws -> AuthenticatedProfile
    /// A pending challenge's link, when this iPhone can get it back.
    var restoreInvite: @Sendable (
        CompetitionID
    ) async throws -> CompetitionInviteCreationOutcome
    /// Withdraws your pending challenge, or cancels a match before Day 1.
    var cancel: @Sendable (CompetitionID) async -> CompetitionPublication
    /// Declines the pending challenge and blocks its sender.
    var block: @Sendable (CompetitionID) async -> CompetitionPublication
    /// The people you blocked, newest first.
    var loadBlockedProfiles: @Sendable () async throws -> [AuthenticatedProfile]
    /// Takes a profile id.
    var unblock: @Sendable (UUID) async throws -> Void
    var previewInvite: @Sendable (
        CompetitionInviteClaimRequest
    ) async throws -> CompetitionInvitePreview
    var loadChallengeLinkCode: @Sendable () async throws -> CompetitionChallengeLinkCode
    var resetChallengeLinkCode: @Sendable () async throws -> CompetitionChallengeLinkCode
    /// The link owner's display name.
    var resolveChallengeLink: @Sendable (
        CompetitionChallengeLinkCode
    ) async throws -> String
    /// Asks the other person to open HealthComp; returns when the server accepted it.
    var nudge: @Sendable (CompetitionID) async throws -> Date

    init(
        start: @escaping @Sendable () -> AsyncStream<CompetitionPublication>,
        updates: @escaping @Sendable () -> AsyncStream<CompetitionPublication>,
        reconcileAll: @escaping @Sendable (
            ActivityRefreshTrigger
        ) async -> CompetitionPublication,
        accept: @escaping @Sendable (
            CompetitionID
        ) async -> CompetitionPublication,
        decline: @escaping @Sendable (
            CompetitionID
        ) async -> CompetitionPublication,
        archive: @escaping @Sendable (
            CompetitionID
        ) async -> CompetitionPublication,
        rematch: @escaping @Sendable (
            CompetitionID
        ) async -> CompetitionPublication,
        reinvite: @escaping @Sendable () async -> CompetitionPublication,
        delete: @escaping @Sendable (
            CompetitionID
        ) async -> CompetitionPublication = { _ in .inert },
        reconcileNotifications: @escaping @Sendable () async -> Void = {},
        loadMutedOpponentIdentities: @escaping @Sendable () async throws ->
            Set<String> = { [] },
        setNotificationMuted: @escaping @Sendable (
            _ opponentIdentity: String,
            _ isMuted: Bool
        ) async throws -> Void = { _, _ in },
        loadNotificationAuthorizationState: @escaping @Sendable () async ->
            CompetitionNotificationAuthorizationState? = { nil },
        requestNotificationAuthorization: @escaping @Sendable () async ->
            CompetitionNotificationAuthorizationState = { .denied },
        waitUntil: @escaping @Sendable (Date) async throws -> Void,
        stop: @escaping @Sendable () async -> Void,
        prepareForProfileTeardown: @escaping @Sendable (
            _ requireRemoteInstallationRemoval: Bool
        ) async throws -> Void = { _ in },
        mountAuthenticatedProfile: @escaping @Sendable (
            AuthenticatedProfile,
            AuthenticatedProfileStoragePaths
        ) async throws -> Void = { _, _ in },
        createInvite: @escaping @Sendable (
            CompetitionInviteCreationRequest
        ) async throws -> CompetitionInviteCreationOutcome = { _ in
            throw CompetitionRemoteFailure.operationFailed
        },
        claimInvite: @escaping @Sendable (
            CompetitionInviteClaimRequest
        ) async throws -> CompetitionInviteClaimOutcome = { _ in
            throw CompetitionRemoteFailure.operationFailed
        },
        resolveInviteRecipient: @escaping @Sendable (UUID) async throws -> AuthenticatedProfile = { _ in
            throw CompetitionRemoteFailure.operationFailed
        },
        restoreInvite: @escaping @Sendable (
            CompetitionID
        ) async throws -> CompetitionInviteCreationOutcome = { _ in
            throw CompetitionRemoteFailure.notFound
        },
        cancel: @escaping @Sendable (
            CompetitionID
        ) async -> CompetitionPublication = { _ in .inert },
        block: @escaping @Sendable (
            CompetitionID
        ) async -> CompetitionPublication = { _ in .inert },
        loadBlockedProfiles: @escaping @Sendable () async throws ->
            [AuthenticatedProfile] = {
            throw CompetitionRemoteFailure.operationFailed
        },
        unblock: @escaping @Sendable (UUID) async throws -> Void = { _ in
            throw CompetitionRemoteFailure.operationFailed
        },
        previewInvite: @escaping @Sendable (
            CompetitionInviteClaimRequest
        ) async throws -> CompetitionInvitePreview = { _ in
            throw CompetitionRemoteFailure.operationFailed
        },
        loadChallengeLinkCode: @escaping @Sendable () async throws ->
            CompetitionChallengeLinkCode = {
            throw CompetitionRemoteFailure.operationFailed
        },
        resetChallengeLinkCode: @escaping @Sendable () async throws ->
            CompetitionChallengeLinkCode = {
            throw CompetitionRemoteFailure.operationFailed
        },
        resolveChallengeLink: @escaping @Sendable (
            CompetitionChallengeLinkCode
        ) async throws -> String = { _ in
            throw CompetitionRemoteFailure.operationFailed
        },
        nudge: @escaping @Sendable (CompetitionID) async throws -> Date = { _ in
            throw CompetitionRemoteFailure.operationFailed
        }
    ) {
        self.start = start
        self.updates = updates
        self.reconcileAll = reconcileAll
        self.accept = accept
        self.decline = decline
        self.archive = archive
        self.rematch = rematch
        self.reinvite = reinvite
        self.delete = delete
        self.reconcileNotifications = reconcileNotifications
        self.loadMutedOpponentIdentities = loadMutedOpponentIdentities
        self.setNotificationMuted = setNotificationMuted
        self.loadNotificationAuthorizationState =
            loadNotificationAuthorizationState
        self.requestNotificationAuthorization =
            requestNotificationAuthorization
        self.waitUntil = waitUntil
        self.stop = stop
        self.prepareForProfileTeardownOperation = prepareForProfileTeardown
        self.mountAuthenticatedProfile = mountAuthenticatedProfile
        self.createInvite = createInvite
        self.claimInvite = claimInvite
        self.resolveInviteRecipient = resolveInviteRecipient
        self.restoreInvite = restoreInvite
        self.cancel = cancel
        self.block = block
        self.loadBlockedProfiles = loadBlockedProfiles
        self.unblock = unblock
        self.previewInvite = previewInvite
        self.loadChallengeLinkCode = loadChallengeLinkCode
        self.resetChallengeLinkCode = resetChallengeLinkCode
        self.resolveChallengeLink = resolveChallengeLink
        self.nudge = nudge
    }

    func prepareForProfileTeardown(
        requireRemoteInstallationRemoval: Bool
    ) async throws {
        try await prepareForProfileTeardownOperation(
            requireRemoteInstallationRemoval
        )
    }
}

// Existing local-focused helpers and tests stay source-compatible while the
// feature dependency moves to the source-neutral name.
typealias LocalCompetitionClient = CompetitionClient

extension DependencyValues {
    var competitionClient: CompetitionClient {
        get { self[CompetitionClient.self] }
        set { self[CompetitionClient.self] = newValue }
    }

    var localCompetitionClient: LocalCompetitionClient {
        get { competitionClient }
        set { competitionClient = newValue }
    }
}
