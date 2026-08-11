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
        stop: @escaping @Sendable () async -> Void
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
