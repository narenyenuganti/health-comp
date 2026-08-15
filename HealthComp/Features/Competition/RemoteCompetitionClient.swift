import CompetitionCore
import Dependencies
import Foundation

extension CompetitionClient {
    static func live(
        provider: SupabaseClientProvider,
        installationEnvironment: CompetitionInstallationEnvironment? = try?
            .configured()
    ) -> Self {
        let remoteAPI = SupabaseCompetitionRemoteAPI.live(provider: provider)
        let pushRegistrationClient: CompetitionPushRegistrationClient? =
            installationEnvironment == nil ? nil : .liveValue
        return remote(
            remoteAPI: remoteAPI,
            environment: .production(),
            realtimeClient: .supabase(provider: provider),
            notificationClient: .liveValue,
            pushRegistrationClient: pushRegistrationClient,
            installationEnvironment: installationEnvironment,
            appAttestServiceFactory: { DeviceCheckAppAttestClient() },
            notificationPreferencesFactory: { _ in
                .remote(remoteAPI: remoteAPI)
            }
        )
    }

    static func remote(
        remoteAPI: CompetitionRemoteAPI,
        environment: CompetitionEnvironmentClient,
        realtimeClient: CompetitionRealtimeClient = .inert,
        notificationClient: CompetitionNotificationClient? = nil,
        pushRegistrationClient: CompetitionPushRegistrationClient? = nil,
        installationEnvironment: CompetitionInstallationEnvironment? = nil,
        appAttestServiceFactory: (@Sendable () ->
            any AppAttestServiceProtocol)? = nil,
        notificationPreferencesFactory: @escaping @Sendable (
            AuthenticatedProfileStoragePaths
        ) -> CompetitionNotificationPreferencesClient = { _ in
            .constant(mutedOpponentIdentities: [])
        }
    ) -> Self {
        let router = RemoteCompetitionPublicationRouter()
        let coordinator = RemoteCompetitionClientCoordinator(
            remoteAPI: remoteAPI,
            environment: environment,
            realtimeClient: realtimeClient,
            notificationClient: notificationClient,
            pushRegistrationClient: pushRegistrationClient,
            installationEnvironment: installationEnvironment,
            appAttestServiceFactory: appAttestServiceFactory,
            notificationPreferencesFactory: notificationPreferencesFactory,
            router: router
        )
        return Self(
            start: {
                let stream = router.stream()
                Task { await coordinator.start() }
                return stream
            },
            updates: { router.stream() },
            reconcileAll: { trigger in
                await coordinator.reconcileAll(trigger: trigger)
            },
            accept: { id in await coordinator.unsupported(id) },
            decline: { id in await coordinator.unsupported(id) },
            archive: { id in await coordinator.archive(id) },
            rematch: { id in await coordinator.unsupported(id) },
            reinvite: { await coordinator.unsupported(nil) },
            delete: { id in await coordinator.unsupported(id) },
            reconcileNotifications: {
                await coordinator.reconcileNotifications()
            },
            loadMutedOpponentIdentities: {
                try await coordinator.loadMutedOpponentIdentities()
            },
            setNotificationMuted: { identity, isMuted in
                try await coordinator.setNotificationMuted(
                    identity,
                    isMuted: isMuted
                )
            },
            loadNotificationAuthorizationState: {
                await coordinator.notificationAuthorizationState()
            },
            requestNotificationAuthorization: {
                await coordinator.requestNotificationAuthorization()
            },
            waitUntil: { date in try await environment.wait(until: date) },
            stop: { await coordinator.stop() },
            prepareForProfileTeardown: { requireRemoteRemoval in
                try await coordinator.prepareForProfileTeardown(
                    requireRemoteInstallationRemoval: requireRemoteRemoval
                )
            },
            mountAuthenticatedProfile: { profile, paths in
                try await coordinator.mount(profile: profile, paths: paths)
            },
            createInvite: { request in
                try await coordinator.createInvite(request)
            },
            claimInvite: { request in
                try await coordinator.claimInvite(request)
            }
        )
    }
}

extension CompetitionClient: DependencyKey {
    static let liveValue = CompetitionClient.live(provider: .live())
}

private final class RemoteCompetitionPublicationRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var hub = LocalCompetitionPublicationHub()

    func stream() -> AsyncStream<CompetitionPublication> {
        lock.withLock { hub.stream() }
    }

    func activate(_ replacement: LocalCompetitionPublicationHub) {
        let prior = lock.withLock { () -> LocalCompetitionPublicationHub in
            let prior = hub
            hub = replacement
            return prior
        }
        prior.finish()
    }

    func finishCurrent() {
        lock.withLock { hub }.finish()
    }
}

private struct RemoteCompetitionStoppedTasks {
    let signal: Task<Void, Never>?
    let realtime: Task<Void, Never>?
}

enum ProfileScopedAppAttestRemoteAPI {
    static func make(
        profileID: UUID,
        paths: AuthenticatedProfileStoragePaths,
        installationStore: CompetitionInstallationStateStore,
        remoteAPI: CompetitionRemoteAPI,
        service: any AppAttestServiceProtocol
    ) async throws -> CompetitionRemoteAPI {
        let installationState = try await installationStore.loadOrCreate()
        let appAttest = AppAttestClient.live(
            profileID: profileID,
            installationID: installationState.installationID,
            service: service,
            stateStore: AppAttestStateStore(
                profileID: profileID,
                directory: paths.appAttestDirectory
            ),
            issueChallenge: remoteAPI.issueAppAttestChallenge,
            submit: remoteAPI.submitAttestedScoreRevision
        )
        var wrapped = remoteAPI
        wrapped.appendScoreRevision = appAttest.appendScoreRevision
        return wrapped
    }
}

private actor RemoteCompetitionClientCoordinator {
    private let remoteAPI: CompetitionRemoteAPI
    private let environment: CompetitionEnvironmentClient
    private let realtimeClient: CompetitionRealtimeClient
    private let notificationClient: CompetitionNotificationClient?
    private let pushRegistrationClient: CompetitionPushRegistrationClient?
    private let installationEnvironment: CompetitionInstallationEnvironment?
    private let appAttestServiceFactory: (@Sendable () ->
        any AppAttestServiceProtocol)?
    private let notificationPreferencesFactory: @Sendable (
        AuthenticatedProfileStoragePaths
    ) -> CompetitionNotificationPreferencesClient
    private let router: RemoteCompetitionPublicationRouter

    private var profile: AuthenticatedProfile?
    private var runtime: RemoteCompetitionRuntime?
    private var hub: LocalCompetitionPublicationHub?
    private var publicationRevision: UInt64 = 0
    private var latestPublication: CompetitionPublication?
    private var signalTask: Task<Void, Never>?
    private var realtimeTask: Task<Void, Never>?
    private var notificationCoordinator: CompetitionNotificationCoordinatorClient =
        .noop
    private var notificationPreferences: CompetitionNotificationPreferencesClient =
        .unavailable
    private var installationCoordinator: CompetitionInstallationCoordinator?
    private var mountedCompetitionIDs: Set<CompetitionID> = []
    private var hasStarted = false
    private var isStopped = false
    private var runtimeGeneration: UInt64 = 0
    private var operationIsInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        remoteAPI: CompetitionRemoteAPI,
        environment: CompetitionEnvironmentClient,
        realtimeClient: CompetitionRealtimeClient,
        notificationClient: CompetitionNotificationClient?,
        pushRegistrationClient: CompetitionPushRegistrationClient?,
        installationEnvironment: CompetitionInstallationEnvironment?,
        appAttestServiceFactory: (@Sendable () ->
            any AppAttestServiceProtocol)?,
        notificationPreferencesFactory: @escaping @Sendable (
            AuthenticatedProfileStoragePaths
        ) -> CompetitionNotificationPreferencesClient,
        router: RemoteCompetitionPublicationRouter
    ) {
        self.remoteAPI = remoteAPI
        self.environment = environment
        self.realtimeClient = realtimeClient
        self.notificationClient = notificationClient
        self.pushRegistrationClient = pushRegistrationClient
        self.installationEnvironment = installationEnvironment
        self.appAttestServiceFactory = appAttestServiceFactory
        self.notificationPreferencesFactory = notificationPreferencesFactory
        self.router = router
    }

    func mount(
        profile: AuthenticatedProfile,
        paths: AuthenticatedProfileStoragePaths
    ) async throws {
        guard profile.id == paths.profileID else {
            throw RemoteCompetitionRuntimeFailure.profileMismatch
        }
        if pushRegistrationClient != nil,
           installationEnvironment == nil {
            throw CompetitionPushRegistrationFailure.invalidConfiguration
        }
        signalTask?.cancel()
        realtimeTask?.cancel()
        let stoppedTasks = try await withOperationGate {
            let stoppedTasks = await stopRuntime()
            let replacement = LocalCompetitionPublicationHub()
            router.activate(replacement)
            self.profile = profile
            self.hub = replacement
            self.publicationRevision = 0
            self.latestPublication = nil
            self.hasStarted = false
            self.isStopped = false
            let installationStore = CompetitionInstallationStateStore(
                directory: paths.installationsDirectory
            )
            var mountedRemoteAPI = remoteAPI
            if let appAttestServiceFactory {
                mountedRemoteAPI = try await ProfileScopedAppAttestRemoteAPI
                    .make(
                        profileID: profile.id,
                        paths: paths,
                        installationStore: installationStore,
                        remoteAPI: remoteAPI,
                        service: appAttestServiceFactory()
                    )
            }
            let runtime = RemoteCompetitionRuntime(
                profileID: profile.id,
                store: JSONCompetitionEventStore(
                    rootDirectory: paths.competitionEventsDirectory
                ),
                remoteAPI: mountedRemoteAPI,
                environment: environment,
                outboxStore: JSONCompetitionOutboxStore(
                    rootDirectory: paths.outboxDirectory
                ),
                cacheStore: JSONRemoteCompetitionCacheStore(
                    rootDirectory: paths.serverCursorsDirectory
                )
            )
            self.runtime = runtime
            let preferences = notificationPreferencesFactory(paths)
            self.notificationPreferences = preferences
            if let notificationClient {
                self.notificationCoordinator = .live(
                    decisionCommitter: .remote(runtime: runtime),
                    planner: CompetitionNotificationPlanner(
                        policy: .liveV1
                    ),
                    notifications: notificationClient,
                    preferences: preferences
                )
            } else {
                self.notificationCoordinator = .noop
            }
            if let pushRegistrationClient,
               let installationEnvironment {
                let installationCoordinator =
                    CompetitionInstallationCoordinator(
                        remoteAPI: remoteAPI,
                        registration: pushRegistrationClient,
                        store: installationStore,
                        environment: installationEnvironment
                    )
                self.installationCoordinator = installationCoordinator
                try await installationCoordinator.start()
            }
            return stoppedTasks
        }
        await stoppedTasks.signal?.value
        await stoppedTasks.realtime?.value
    }

    func start() async {
        await withOperationGate {
            guard !hasStarted, !isStopped else { return }
            hasStarted = true
            startSignals()
            startRealtime()
            _ = await performReconciliation()
        }
    }

    func reconcileAll(
        trigger _: ActivityRefreshTrigger
    ) async -> CompetitionPublication {
        await withOperationGate {
            await performReconciliation()
        }
    }

    private func performReconciliation() async -> CompetitionPublication {
        guard let runtime, let profile else {
            return publish(
                materializations: [],
                issues: [.storageUnavailable]
            )
        }
        await installationCoordinator?.reconcile()
        let outcome = await runtime.synchronizeAll()
        var issues: [CompetitionClientIssue] = []
        if outcome.discoveryFailure != nil {
            issues.append(.storageUnavailable)
        }
        let failedIDs = outcome.failures.map(\.competitionID).sorted {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }
        if !failedIDs.isEmpty {
            issues.append(.competitionFailures(failedIDs))
        }
        return await publish(
            materializations: outcome.successfulCompetitions,
            profile: profile,
            issues: issues,
            knownCompetitionIDs: outcome.discoveryFailure == nil
                ? Set(outcome.outcomes.map(\.competitionID))
                : nil
        )
    }

    func reconcileNotifications() async {
        await withOperationGate {
            await notificationCoordinator.reconcileLatest()
        }
    }

    func loadMutedOpponentIdentities() async throws -> Set<String> {
        try await withOperationGate {
            try await notificationPreferences.mutedOpponentIdentities()
        }
    }

    func setNotificationMuted(
        _ identity: String,
        isMuted: Bool
    ) async throws {
        try await withOperationGate {
            try await notificationPreferences.setMuted(identity, isMuted)
            await notificationCoordinator.reconcileLatest()
        }
    }

    func notificationAuthorizationState()
        async -> CompetitionNotificationAuthorizationState?
    {
        guard let notificationClient else { return nil }
        return await notificationClient.authorizationState()
    }

    func requestNotificationAuthorization()
        async -> CompetitionNotificationAuthorizationState
    {
        guard let notificationClient else { return .denied }
        do {
            _ = try await notificationClient.requestAuthorization()
        } catch {
            return await notificationClient.authorizationState()
        }
        let state = await notificationClient.authorizationState()
        await withOperationGate {
            await notificationCoordinator.reconcileLatest()
        }
        return state
    }

    func unsupported(_ id: CompetitionID?) async -> CompetitionPublication {
        await withOperationGate {
            let issue = id.map(CompetitionClientIssue.commandRejected)
                ?? .unimplemented
            return publication(adding: issue)
        }
    }

    func archive(_ id: CompetitionID) async -> CompetitionPublication {
        await withOperationGate {
            guard runtime != nil else {
                return publication(adding: .commandRejected(id))
            }
            do {
                try await remoteAPI.archiveCompetition(id.rawValue)
                return await performReconciliation()
            } catch {
                return publication(adding: .commandRejected(id))
            }
        }
    }

    private func publication(
        adding issue: CompetitionClientIssue
    ) -> CompetitionPublication {
        guard let latestPublication else {
            return publish(materializations: [], issues: [issue])
        }
        return publish(
            dashboard: CompetitionDashboard(
                competitions: latestPublication.dashboard.competitions,
                awards: latestPublication.dashboard.awards,
                issues: Self.deduplicated(
                    latestPublication.dashboard.issues + [issue]
                ),
                hiddenTerminalCompetitionCount: latestPublication.dashboard
                    .hiddenTerminalCompetitionCount
            ),
            evaluatedAt: latestPublication.evaluatedAt,
            timeZoneIdentifier: latestPublication.timeZoneIdentifier
        )
    }

    func createInvite(
        _ request: CompetitionInviteCreationRequest
    ) async throws -> CompetitionInviteCreationOutcome {
        try await withOperationGate {
            guard runtime != nil else {
                throw CompetitionRemoteFailure.unauthenticated
            }
            let invite = try await remoteAPI.createInvite(request)
            let publication = await performReconciliation()
            return CompetitionInviteCreationOutcome(
                invite: invite,
                expectedPublicationRevision: publication.publicationRevision
            )
        }
    }

    func claimInvite(
        _ request: CompetitionInviteClaimRequest
    ) async throws -> CompetitionInviteClaimOutcome {
        try await withOperationGate {
            guard runtime != nil else {
                throw CompetitionRemoteFailure.unauthenticated
            }
            let claim = try await remoteAPI.claimInvite(request)
            let publication = await performReconciliation()
            return CompetitionInviteClaimOutcome(
                claim: claim,
                expectedPublicationRevision: publication.publicationRevision
            )
        }
    }

    func stop() async {
        isStopped = true
        signalTask?.cancel()
        realtimeTask?.cancel()
        let stoppedTasks = await withOperationGate {
            let stoppedTasks = await stopRuntime()
            profile = nil
            hub = nil
            latestPublication = nil
            publicationRevision = 0
            hasStarted = false
            router.finishCurrent()
            return stoppedTasks
        }
        await stoppedTasks.signal?.value
        await stoppedTasks.realtime?.value
    }

    func prepareForProfileTeardown(
        requireRemoteInstallationRemoval: Bool
    ) async throws {
        try await withOperationGate {
            try await installationCoordinator?.prepareForProfileTeardown(
                requireRemoteRemoval: requireRemoteInstallationRemoval
            )
        }
    }

    private func stopRuntime() async -> RemoteCompetitionStoppedTasks {
        runtimeGeneration &+= 1
        let stoppedTasks = RemoteCompetitionStoppedTasks(
            signal: signalTask,
            realtime: realtimeTask
        )
        stoppedTasks.signal?.cancel()
        stoppedTasks.realtime?.cancel()
        signalTask = nil
        realtimeTask = nil
        if stoppedTasks.realtime != nil {
            await realtimeClient.stop()
        }
        for competitionID in mountedCompetitionIDs.sorted(by: {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }) {
            await notificationCoordinator.cancelAll(competitionID)
        }
        mountedCompetitionIDs = []
        notificationCoordinator = .noop
        notificationPreferences = .unavailable
        await installationCoordinator?.stopListening()
        installationCoordinator = nil
        await runtime?.stop()
        runtime = nil
        return stoppedTasks
    }

    private func startSignals() {
        guard signalTask == nil else { return }
        let generation = runtimeGeneration
        signalTask = Task { [weak self, environment] in
            let signals = await environment.signals()
            for await signal in signals {
                guard !Task.isCancelled else { return }
                await self?.consume(signal, generation: generation)
            }
        }
    }

    private func startRealtime() {
        guard realtimeTask == nil, let profile else { return }
        let generation = runtimeGeneration
        realtimeTask = Task { [weak self, realtimeClient] in
            let wakeUps = await realtimeClient.wakeUps(profile.id)
            for await wakeUp in wakeUps {
                guard !Task.isCancelled else { return }
                await self?.consumeRealtime(
                    wakeUp,
                    generation: generation
                )
            }
        }
    }

    private func consume(
        _ signal: EnvironmentSignal,
        generation: UInt64
    ) async {
        await withOperationGate {
            guard generation == runtimeGeneration, !Task.isCancelled else {
                if signal.requiresCompletion {
                    await environment.completeSignal(signal.id)
                }
                return
            }
            _ = await performReconciliation()
            if signal.requiresCompletion {
                await environment.completeSignal(signal.id)
            }
        }
    }

    private func consumeRealtime(
        _ wakeUp: CompetitionRealtimeWakeUp,
        generation: UInt64
    ) async {
        await withOperationGate {
            guard generation == runtimeGeneration, !Task.isCancelled else {
                return
            }
            // The reason and cursor are diagnostic hints only. Durable state is
            // always authoritative, including duplicate and out-of-order hints.
            _ = wakeUp
            _ = await performReconciliation()
        }
    }

    private func withOperationGate<Value>(
        _ operation: () async throws -> Value
    ) async rethrows -> Value {
        await acquireOperationGate()
        do {
            let result = try await operation()
            releaseOperationGate()
            return result
        } catch {
            releaseOperationGate()
            throw error
        }
    }

    private func acquireOperationGate() async {
        guard operationIsInProgress else {
            operationIsInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperationGate() {
        guard !operationWaiters.isEmpty else {
            operationIsInProgress = false
            return
        }
        operationWaiters.removeFirst().resume()
    }

    private func publish(
        materializations: [RemoteCompetitionMaterialization],
        issues: [CompetitionClientIssue]
    ) -> CompetitionPublication {
        publish(
            dashboard: CompetitionDashboard(
                competitions: [],
                awards: [],
                issues: Self.deduplicated(issues),
                hiddenTerminalCompetitionCount: 0
            ),
            evaluatedAt: .distantPast,
            timeZoneIdentifier: "UTC"
        )
    }

    private func publish(
        materializations: [RemoteCompetitionMaterialization],
        profile: AuthenticatedProfile,
        issues: [CompetitionClientIssue],
        knownCompetitionIDs: Set<CompetitionID>?
    ) async -> CompetitionPublication {
        let context = await environment.context()
        let publication = publish(
            dashboard: RemoteCompetitionProjector.dashboard(
                materializations: materializations,
                profile: profile,
                context: context,
                issues: issues
            ),
            evaluatedAt: context.instant.wallDate,
            timeZoneIdentifier: context.timeZoneIdentifier
        )
        let materializedIDs = Set(materializations.map {
            CompetitionID($0.descriptor.competitionID)
        })
        if let knownCompetitionIDs {
            mountedCompetitionIDs = knownCompetitionIDs
        } else {
            mountedCompetitionIDs.formUnion(materializedIDs)
        }
        await notificationCoordinator.submit(
            RemoteCompetitionProjector.notificationSnapshot(
                publication: publication,
                materializations: materializations,
                profile: profile,
                context: context,
                knownCompetitionIDs: knownCompetitionIDs
            )
        )
        return publication
    }

    private func publish(
        dashboard: CompetitionDashboard,
        evaluatedAt: Date,
        timeZoneIdentifier: String
    ) -> CompetitionPublication {
        guard publicationRevision < UInt64.max else {
            return latestPublication ?? CompetitionPublication(
                publicationRevision: UInt64.max,
                dashboard: dashboard,
                evaluatedAt: evaluatedAt,
                timeZoneIdentifier: timeZoneIdentifier,
                source: .remoteParticipants
            )
        }
        publicationRevision += 1
        let publication = CompetitionPublication(
            publicationRevision: publicationRevision,
            dashboard: dashboard,
            evaluatedAt: evaluatedAt,
            timeZoneIdentifier: timeZoneIdentifier,
            source: .remoteParticipants
        )
        latestPublication = publication
        hub?.publish(publication)
        return publication
    }

    private static func deduplicated(
        _ issues: [CompetitionClientIssue]
    ) -> [CompetitionClientIssue] {
        var result: [CompetitionClientIssue] = []
        for issue in issues where !result.contains(issue) {
            result.append(issue)
        }
        return result
    }
}

struct RemoteCompetitionParticipantPresentation: Equatable, Sendable {
    let ownerName: String
    let opponentName: String
    let opponentID: UUID?
}

func remoteCompetitionParticipantPresentation(
    descriptor: CompetitionDescriptor,
    profile: AuthenticatedProfile
) -> RemoteCompetitionParticipantPresentation {
    let ownerName = descriptor.participants
        .first { $0.profileID == profile.id }?.profile.displayName
        ?? profile.displayName
    let opponent = descriptor.participants.first { $0.profileID != profile.id }
    return RemoteCompetitionParticipantPresentation(
        ownerName: ownerName,
        opponentName: opponent?.profile.displayName ?? "Waiting for competitor",
        opponentID: opponent?.profileID
    )
}

enum RemoteCompetitionProjector {
    static func dashboard(
        materializations: [RemoteCompetitionMaterialization],
        profile: AuthenticatedProfile,
        context: CompetitionEnvironmentContext,
        issues: [CompetitionClientIssue]
    ) -> CompetitionDashboard {
        let all = materializations.compactMap {
            presentation(from: $0, profile: profile, context: context)
        }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        let visible = all.filter {
            switch $0.lifecycle {
            case .declined, .expired:
                false
            default:
                true
            }
        }
        return CompetitionDashboard(
            competitions: visible,
            awards: awards(from: visible),
            issues: issues,
            hiddenTerminalCompetitionCount: all.count - visible.count
        )
    }

    static func notificationSnapshot(
        publication: CompetitionPublication,
        materializations: [RemoteCompetitionMaterialization],
        profile: AuthenticatedProfile,
        context: CompetitionEnvironmentContext,
        knownCompetitionIDs: Set<CompetitionID>?
    ) -> CompetitionNotificationPlanningSnapshot {
        let competitions = materializations.compactMap { materialization in
            notificationCompetition(
                from: materialization,
                profile: profile,
                context: context
            )
        }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        return CompetitionNotificationPlanningSnapshot(
            publicationRevision: publication.publicationRevision,
            evaluatedAt: context.instant.wallDate,
            timeZoneIdentifier: context.timeZoneIdentifier,
            competitions: competitions,
            knownCompetitionIDs: knownCompetitionIDs
        )
    }

    static func notificationCompetition(
        from materialization: RemoteCompetitionMaterialization,
        profile: AuthenticatedProfile,
        context: CompetitionEnvironmentContext
    ) -> CompetitionNotificationCompetitionSnapshot? {
        guard let projected = presentation(
            from: materialization,
            profile: profile,
            context: context
        ) else {
            return nil
        }
        return CompetitionNotificationCompetitionSnapshot(
            id: projected.id,
            opponentIdentity: projected.opponentIdentity,
            opponentDisplayName: projected.opponentDisplayName,
            lifecycle: notificationLifecycle(projected.lifecycle),
            schedule: materialization.journal.projection.competition.schedule,
            ownerPoints: projected.userPoints,
            opponentPoints: projected.opponentPoints,
            days: projected.days.map {
                CompetitionNotificationDaySnapshot(
                    ordinal: $0.ordinal,
                    ownerAcceptedPoints: $0.ownerAcceptedPoints,
                    opponentRevealedPoints: $0.opponentRevealedPoints
                )
            },
            currentDayOrdinal: projected.currentDayOrdinal,
            latestRefresh: .completed,
            evaluationFreshness: .freshCompletedRefresh(
                attemptID: "remote-reconciliation-v1:\(materialization.descriptor.serverCursor)",
                readAt: context.instant.wallDate
            ),
            terminalResult: projected.terminalResult.map {
                CompetitionNotificationTerminalSnapshot(
                    ownerPoints: $0.userPoints,
                    opponentPoints: $0.opponentPoints,
                    outcome: $0.outcome
                )
            },
            emissionHistory: materialization.journal.projection
                .notificationEmissions,
            evaluatedAt: context.instant.wallDate,
            timeZoneIdentifier: projected.timeZoneIdentifier
        )
    }

    /// Rebuilds every journal-derived notification field after a commit CAS
    /// conflict. Presentation-only names and evaluation freshness remain bound
    /// to the submitted publication because neither is persisted in the Core
    /// journal.
    static func notificationCompetition(
        reloading loaded: LoadedCompetitionJournal,
        profileID: UUID,
        baseline: CompetitionNotificationCompetitionSnapshot
    ) -> CompetitionNotificationCompetitionSnapshot {
        let projection = loaded.projection
        let competition = projection.competition
        let opponentID = competition.remoteConfiguration?.remote.profileID
        let terminal = terminalPresentation(competition.lifecycle)
        let schedule = competition.schedule
        let days = schedule.map {
            dayPresentations(
                schedule: $0,
                projection: projection,
                ownerID: profileID,
                remoteID: opponentID,
                now: baseline.evaluatedAt,
                terminal: terminal
            )
        } ?? []
        let ownerPoints = projection.remoteScoreLedgers[profileID]
            .map { Double($0.totalAcceptedCentiPoints) / 100 } ?? 0
        let opponentPoints = opponentID.flatMap {
            projection.remoteScoreLedgers[$0]
        }.map { Double($0.totalAcceptedCentiPoints) / 100 } ?? 0
        return CompetitionNotificationCompetitionSnapshot(
            id: competition.id,
            opponentIdentity: opponentID.map {
                RemoteCompetitionOpponentIdentity.identity(for: $0)
            } ?? baseline.opponentIdentity,
            opponentDisplayName: baseline.opponentDisplayName,
            lifecycle: notificationLifecycle(
                lifecyclePresentation(competition.lifecycle)
            ),
            schedule: schedule,
            ownerPoints: terminal?.userPoints ?? ownerPoints,
            opponentPoints: terminal?.opponentPoints ?? opponentPoints,
            days: days.map {
                CompetitionNotificationDaySnapshot(
                    ordinal: $0.ordinal,
                    ownerAcceptedPoints: $0.ownerAcceptedPoints,
                    opponentRevealedPoints: $0.opponentRevealedPoints
                )
            },
            currentDayOrdinal: currentDayOrdinal(
                schedule: schedule,
                now: baseline.evaluatedAt
            ),
            latestRefresh: baseline.latestRefresh,
            evaluationFreshness: baseline.evaluationFreshness,
            terminalResult: terminal.map {
                CompetitionNotificationTerminalSnapshot(
                    ownerPoints: $0.userPoints,
                    opponentPoints: $0.opponentPoints,
                    outcome: $0.outcome
                )
            },
            emissionHistory: projection.notificationEmissions,
            evaluatedAt: baseline.evaluatedAt,
            timeZoneIdentifier: schedule?.calendar.timeZoneIdentifier
                ?? baseline.timeZoneIdentifier
        )
    }

    private static func notificationLifecycle(
        _ lifecycle: CompetitionLifecyclePresentation
    ) -> CompetitionNotificationLifecycle {
        switch lifecycle {
        case let .pending(_, _, expiresAt):
            .pending(expiresAt: expiresAt)
        case .declined:
            .declined
        case .expired:
            .expired
        case .scheduled:
            .scheduled
        case let .active(dayOrdinal):
            .active(dayOrdinal: dayOrdinal)
        case .endsToday:
            .endsToday
        case .tallying:
            .tallying
        case .completed:
            .completed
        case .archived:
            .archived
        }
    }

    private static func presentation(
        from materialization: RemoteCompetitionMaterialization,
        profile: AuthenticatedProfile,
        context: CompetitionEnvironmentContext
    ) -> CompetitionPresentation? {
        let projection = materialization.journal.projection
        let competition = projection.competition
        let participantPresentation = remoteCompetitionParticipantPresentation(
            descriptor: materialization.descriptor,
            profile: profile
        )
        let ownerName = participantPresentation.ownerName
        let opponentName = participantPresentation.opponentName
        let opponentID = participantPresentation.opponentID
        let terminal = terminalPresentation(competition.lifecycle)
        let schedule = competition.schedule
        let days = schedule.map {
            dayPresentations(
                schedule: $0,
                projection: projection,
                ownerID: profile.id,
                remoteID: opponentID,
                now: context.instant.wallDate,
                terminal: terminal
            )
        } ?? []
        let ownerPoints = projection.remoteScoreLedgers[profile.id]
            .map { Double($0.totalAcceptedCentiPoints) / 100 } ?? 0
        let opponentPoints = opponentID.flatMap {
            projection.remoteScoreLedgers[$0]
        }.map { Double($0.totalAcceptedCentiPoints) / 100 } ?? 0
        return CompetitionPresentation(
            id: competition.id,
            ownerDisplayName: ownerName,
            opponentDisplayName: opponentName,
            opponentIdentity: opponentID.map {
                RemoteCompetitionOpponentIdentity.identity(for: $0)
            } ?? "remote-profile:v1:pending",
            lifecycle: lifecyclePresentation(competition.lifecycle),
            acceptedConfiguration: schedule.map {
                CompetitionAcceptedPresentation(
                    schedule: $0,
                    difficulty: .balanced
                )
            },
            userPoints: terminal?.userPoints ?? ownerPoints,
            opponentPoints: terminal?.opponentPoints ?? opponentPoints,
            days: days,
            currentDayOrdinal: currentDayOrdinal(
                schedule: schedule,
                now: context.instant.wallDate
            ),
            lastRefresh: nil,
            tally: tallyPresentation(
                competition: competition,
                projection: projection,
                ownerID: profile.id
            ),
            terminalResult: terminal,
            evaluatedAt: context.instant.wallDate,
            timeZoneIdentifier: schedule?.calendar.timeZoneIdentifier
                ?? context.timeZoneIdentifier,
            lastSuccessfulFullWindowRefreshAt: nil
        )
    }

    private static func dayPresentations(
        schedule: CompetitionSchedule,
        projection: CompetitionReplayProjection,
        ownerID: UUID,
        remoteID: UUID?,
        now: Date,
        terminal: CompetitionTerminalPresentation?
    ) -> [CompetitionDayPresentation] {
        guard let days = try? schedule.calendar.sevenDayWindow(
            startingOn: schedule.startDay
        ) else { return [] }
        return days.enumerated().map { offset, day in
            let ordinal = offset + 1
            let start = try? schedule.calendar.startOfDay(day)
            let future = start.map { now < $0 } ?? true
            let owner = projection.remoteScoreLedgers[ownerID].flatMap {
                try? $0.visibleEntry(forActiveDayOrdinal: ordinal)
            }
            let remote = remoteID.flatMap {
                profileID in
                projection.remoteScoreLedgers[profileID].flatMap {
                    try? $0.visibleEntry(forActiveDayOrdinal: ordinal)
                }
            }
            let availability: CompetitionOwnerAvailability
            if future {
                availability = .notYetOccurred
            } else if owner?.acceptedCentiPoints != nil {
                availability = .observed
            } else if let reason = owner?.availabilityReason {
                availability = .unavailable(
                    reason: ActivityUnavailableReason(rawValue: reason)
                        ?? .invalidSourceData
                )
            } else {
                availability = .missing
            }
            return CompetitionDayPresentation(
                day: day,
                ordinal: ordinal,
                ownerAcceptedPoints: owner?.acceptedCentiPoints.map {
                    Double($0) / 100
                },
                ownerLatestAvailability: availability,
                opponentRevealedPoints: future && terminal == nil
                    ? nil
                    : remote?.acceptedCentiPoints.map { Double($0) / 100 },
                ownerAcceptedSnapshot: nil,
                ownerLatestSnapshot: nil
            )
        }
    }

    private static func lifecyclePresentation(
        _ lifecycle: CompetitionLifecycle
    ) -> CompetitionLifecyclePresentation {
        switch lifecycle {
        case let .pendingInvitation(invitation):
            .pending(
                direction: invitation.direction,
                createdAt: invitation.createdAt,
                expiresAt: invitation.expiresAt
            )
        case let .declined(at): .declined(at: at)
        case let .expired(at): .expired(at: at)
        case .scheduled: .scheduled
        case let .active(day): .active(dayOrdinal: day.ordinal)
        case .endsToday: .endsToday
        case let .tallying(tally): .tallying(startedAt: tally.startedAt)
        case let .completed(completed):
            .completed(
                outcome: completed.outcome,
                basis: completed.basis,
                completedAt: completed.completedAt
            )
        case let .archived(archived):
            .archived(
                outcome: archived.completed.outcome,
                basis: archived.completed.basis,
                completedAt: archived.completed.completedAt,
                archivedAt: archived.archivedAt
            )
        }
    }

    private static func terminalPresentation(
        _ lifecycle: CompetitionLifecycle
    ) -> CompetitionTerminalPresentation? {
        let completed: CompletedCompetition
        switch lifecycle {
        case let .completed(value): completed = value
        case let .archived(value): completed = value.completed
        default: return nil
        }
        return CompetitionTerminalPresentation(
            userPoints: completed.snapshot.userPoints,
            opponentPoints: completed.snapshot.opponentPoints,
            outcome: completed.outcome,
            basis: completed.basis,
            completedAt: completed.completedAt
        )
    }

    private static func currentDayOrdinal(
        schedule: CompetitionSchedule?,
        now: Date
    ) -> Int? {
        guard let schedule,
              let days = try? schedule.calendar.sevenDayWindow(
                  startingOn: schedule.startDay
              )
        else { return nil }
        for (offset, day) in days.enumerated() {
            guard let start = try? schedule.calendar.startOfDay(day),
                  let next = try? schedule.calendar.day(after: day),
                  let end = try? schedule.calendar.startOfDay(next)
            else { continue }
            if now >= start, now < end { return offset + 1 }
        }
        return nil
    }

    private static func tallyPresentation(
        competition: Competition,
        projection: CompetitionReplayProjection,
        ownerID: UUID
    ) -> CompetitionTallyPresentation? {
        guard case .tallying = competition.lifecycle,
              let configuration = competition.remoteConfiguration
        else { return nil }
        let ownerLedger = projection.remoteScoreLedgers[ownerID]
        let missing = Set((1...7).filter {
            guard let ownerLedger else { return true }
            return (try? ownerLedger.visibleEntry(
                forActiveDayOrdinal: $0
            )) == nil
        })
        let unavailable = Set((1...7).filter {
            guard !missing.contains($0), let ownerLedger,
                  let row = try? ownerLedger.visibleEntry(
                      forActiveDayOrdinal: $0
                  )
            else { return false }
            return row.acceptedCentiPoints == nil
        })
        let attention: CompetitionTallyAttention? = missing.isEmpty
            && unavailable.isEmpty
            ? .awaitingStability
            : .incomplete(
                missingOrdinals: missing,
                unavailableOrdinals: unavailable
            )
        return CompetitionTallyPresentation(
            attention: attention,
            consecutiveStableCompleteReads: 0,
            stabilityStart: nil,
            bestAvailableDeadline: configuration.bestAvailableDeadline
        )
    }

    private static func awards(
        from presentations: [CompetitionPresentation]
    ) -> [CompetitionAward] {
        var result: [CompetitionAward] = []
        for presentation in presentations {
            guard let terminal = presentation.terminalResult else { continue }
            let prefix = "remote-competition-award:v1:\(presentation.id.rawValue.uuidString.lowercased())"
            result.append(
                CompetitionAward(
                    id: "\(prefix):completion",
                    competitionID: presentation.id,
                    kind: .completion,
                    awardedAt: terminal.completedAt,
                    friendDisplayName: presentation.opponentDisplayName
                )
            )
            if terminal.outcome == .win {
                result.append(
                    CompetitionAward(
                        id: "\(prefix):victory",
                        competitionID: presentation.id,
                        kind: .victory,
                        awardedAt: terminal.completedAt,
                        friendDisplayName: presentation.opponentDisplayName
                    )
                )
            }
        }
        return result.sorted { $0.id < $1.id }
    }
}
