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
            },
            observerDeliveryReceiptFactory: { paths in
                .live(directory: paths.observerDeliveryDirectory)
            },
            widgetSnapshots: .liveValue
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
        },
        observerDeliveryReceiptFactory: @escaping @Sendable (
            AuthenticatedProfileStoragePaths
        ) -> HealthKitObserverDeliveryReceiptClient = { _ in
            .discarding
        },
        widgetSnapshots: CompetitionWidgetSnapshotClient = .noop,
        lifecycleInvalidationObserver: @escaping @Sendable () -> Void = {}
    ) -> Self {
        let router = RemoteCompetitionPublicationRouter()
        let lifecycle = RemoteCompetitionClientLifecycle(
            didInvalidateMounts: lifecycleInvalidationObserver
        )
        let coordinator = RemoteCompetitionClientCoordinator(
            remoteAPI: remoteAPI,
            environment: environment,
            realtimeClient: realtimeClient,
            notificationClient: notificationClient,
            pushRegistrationClient: pushRegistrationClient,
            installationEnvironment: installationEnvironment,
            appAttestServiceFactory: appAttestServiceFactory,
            notificationPreferencesFactory: notificationPreferencesFactory,
            observerDeliveryReceiptFactory: observerDeliveryReceiptFactory,
            router: router,
            widgetSnapshots: widgetSnapshots
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
            accept: { id in
                await coordinator.respond(id) { try await $0.acceptChallenge($1) }
            },
            decline: { id in
                await coordinator.respond(id, inviteUnavailableIsDone: true) {
                    try await $0.declineChallenge($1)
                }
            },
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
            stop: {
                lifecycle.invalidateMounts()
                await coordinator.stop()
            },
            prepareForProfileTeardown: { requireRemoteRemoval in
                lifecycle.invalidateMounts()
                try await coordinator.prepareForProfileTeardown(
                    requireRemoteInstallationRemoval: requireRemoteRemoval
                )
            },
            mountAuthenticatedProfile: { profile, paths in
                let lease = lifecycle.issueMountLease()
                try await coordinator.mount(
                    profile: profile,
                    paths: paths,
                    lease: lease,
                    lifecycle: lifecycle
                )
            },
            createInvite: { request in
                try await coordinator.createInvite(request)
            },
            claimInvite: { request in
                try await coordinator.claimInvite(request)
            },
            resolveInviteRecipient: { profileID in
                try await coordinator.resolveInviteRecipient(profileID)
            },
            restoreInvite: { id in try await coordinator.restoreInvite(id) },
            cancel: { id in
                await coordinator.respond(id) { try await $0.cancelCompetition($1) }
            },
            previewInvite: { request in
                try await coordinator.remote { try await $0.previewInvite(request) }
            },
            loadChallengeLinkCode: {
                try await coordinator.remote { try await $0.loadChallengeLinkCode() }
            },
            resetChallengeLinkCode: {
                try await coordinator.remote { try await $0.resetChallengeLinkCode() }
            },
            resolveChallengeLink: { code in
                try await coordinator.remote { try await $0.resolveChallengeLink(code) }
            }
        )
    }
}

private struct RemoteCompetitionMountLease: Equatable, Sendable {
    let generation: UInt64
}

private final class RemoteCompetitionClientLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private let didInvalidateMounts: @Sendable () -> Void
    private var generation: UInt64 = 0

    init(didInvalidateMounts: @escaping @Sendable () -> Void) {
        self.didInvalidateMounts = didInvalidateMounts
    }

    func issueMountLease() -> RemoteCompetitionMountLease {
        lock.withLock {
            generation &+= 1
            return RemoteCompetitionMountLease(generation: generation)
        }
    }

    func invalidateMounts() {
        lock.withLock { generation &+= 1 }
        didInvalidateMounts()
    }

    func isCurrent(_ lease: RemoteCompetitionMountLease) -> Bool {
        lock.withLock { lease.generation == generation }
    }
}

extension CompetitionClient: DependencyKey {
    static let liveValue = CompetitionClient.live(provider: .live())
}

extension RemoteCompetitionRuntimeFailure {
    var competitionClientIssue: LocalCompetitionClientIssue? {
        switch self {
        case .cancelled:
            nil
        case .storageUnavailable:
            .storageUnavailable
        case .discoveryUnavailable:
            .remoteUnavailable
        case .unauthenticated,
             .forbidden,
             .profileMismatch,
             .competitionNotMaterialized,
             .serverContractMismatch,
             .cursorRetryLimitExceeded:
            .remoteFailure
        }
    }
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

private struct RemoteCompetitionCompletedMount {
    let stoppedTasks: RemoteCompetitionStoppedTasks
    let profileID: UUID
    let ownershipLease: EnvironmentSignalOwnershipLease
    let ownershipScope: EnvironmentSignalOwnershipScope
    let runtimeGeneration: UInt64
    let ownsNewSignalScope: Bool
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

/// The create requests of this profile's recent challenges, so a pending
/// challenge's link survives relaunch. Holds no secret: a key is useless
/// without the sender's session and the server's secret.
actor RemoteInviteRequestStore {
    private struct Entry: Codable {
        let request: CompetitionInviteCreationRequest
        let createdAt: Date
    }

    private struct Document: Codable {
        var version = 1
        var entries: [String: Entry]
    }

    /// A challenge expires after 24 hours; an hour of slack covers clock skew.
    static let retention: TimeInterval = 25 * 3_600

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func save(
        _ request: CompetitionInviteCreationRequest,
        for id: CompetitionID,
        now: Date
    ) {
        var entries = load().filter {
            now.timeIntervalSince($0.value.createdAt) < Self.retention
        }
        let key = id.rawValue.uuidString.lowercased()
        entries[key] = Entry(
            request: request,
            createdAt: entries[key]?.createdAt ?? now
        )
        guard let data = try? JSONEncoder().encode(Document(entries: entries))
        else { return }
        // ponytail: errors are swallowed; losing the file only shows "isn't on this iPhone"
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    func request(
        for id: CompetitionID,
        now: Date
    ) -> CompetitionInviteCreationRequest? {
        guard let entry = load()[id.rawValue.uuidString.lowercased()],
              now.timeIntervalSince(entry.createdAt) < Self.retention
        else { return nil }
        return entry.request
    }

    // An unreadable or corrupt file counts as empty.
    private func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == 1
        else { return [:] }
        return document.entries
    }
}

private actor RemoteCompetitionClientCoordinator {
    private struct OperationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct PendingObserverDelivery {
        let signal: EnvironmentSignal
        let ownershipScope: EnvironmentSignalOwnershipScope
        var observedGeneration: UInt64?
        var receipt: HealthKitObserverDeliveryReceipt?
    }

    private struct TerminalTeardown {
        enum Stage {
            case quiescing
            case retired
        }

        let profileID: UUID
        let ownershipLease: EnvironmentSignalOwnershipLease
        let ownershipScope: EnvironmentSignalOwnershipScope
        let runtimeGeneration: UInt64
        var requiresRemoteInstallationRemoval: Bool
        var installationPreparationCompleted: Bool
        var remoteRemovalRequirementSatisfied: Bool
        var stage: Stage
    }

    private struct TerminalPreparationWork {
        let id: UUID
        let task: Task<Void, Error>
    }

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
    private let observerDeliveryReceiptFactory: @Sendable (
        AuthenticatedProfileStoragePaths
    ) -> HealthKitObserverDeliveryReceiptClient
    private let router: RemoteCompetitionPublicationRouter
    private let widgetSnapshots: CompetitionWidgetSnapshotClient

    private var profile: AuthenticatedProfile?
    private var runtime: RemoteCompetitionRuntime?
    private var hub: LocalCompetitionPublicationHub?
    private var publicationRevision: UInt64 = 0
    private var latestPublication: CompetitionPublication?
    private var signalTask: Task<Void, Never>?
    private var realtimeTask: Task<Void, Never>?
    /// Republishes the last inputs when Home's grouping changes on its own.
    private var boundaryTask: Task<Void, Never>?
    private var lastPublishInputs: (
        materializations: [RemoteCompetitionMaterialization],
        issues: [CompetitionClientIssue],
        knownCompetitionIDs: Set<CompetitionID>?
    )?
    private var notificationCoordinator: CompetitionNotificationCoordinatorClient =
        .noop
    private var notificationPreferences: CompetitionNotificationPreferencesClient =
        .unavailable
    private var observerDeliveryReceipts: HealthKitObserverDeliveryReceiptClient =
        .discarding
    private var pendingObserverDeliveries: [
        String: PendingObserverDelivery
    ] = [:]
    private var activeSignalOwnershipScope: EnvironmentSignalOwnershipScope?
    private var activeSignalOwnershipLease: EnvironmentSignalOwnershipLease?
    private var recoverableSignalOwnershipActivation:
        EnvironmentSignalOwnershipActivation?
    private var terminalTeardown: TerminalTeardown?
    private var terminalPreparationWork: TerminalPreparationWork?
    private var installationCoordinator: CompetitionInstallationCoordinator?
    private var inviteRequests: RemoteInviteRequestStore?
    private var mountedCompetitionIDs: Set<CompetitionID> = []
    /// The last good materialization of each match, shown again when its
    /// next sync is only cancelled.
    private var lastMaterializations: [CompetitionID: RemoteCompetitionMaterialization] = [:]
    /// The last challenge list; kept when a refresh can't load it.
    private var latestChallenges = CompetitionChallengeList.empty
    private var hasStarted = false
    private var isStopped = false
    private var healthAuthorizationIssue: CompetitionClientIssue?
    private var runtimeGeneration: UInt64 = 0
    private var operationIsInProgress = false
    private var operationWaiters: [OperationWaiter] = []

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
        observerDeliveryReceiptFactory: @escaping @Sendable (
            AuthenticatedProfileStoragePaths
        ) -> HealthKitObserverDeliveryReceiptClient,
        router: RemoteCompetitionPublicationRouter,
        widgetSnapshots: CompetitionWidgetSnapshotClient
    ) {
        self.widgetSnapshots = widgetSnapshots
        self.remoteAPI = remoteAPI
        self.environment = environment
        self.realtimeClient = realtimeClient
        self.notificationClient = notificationClient
        self.pushRegistrationClient = pushRegistrationClient
        self.installationEnvironment = installationEnvironment
        self.appAttestServiceFactory = appAttestServiceFactory
        self.notificationPreferencesFactory = notificationPreferencesFactory
        self.observerDeliveryReceiptFactory = observerDeliveryReceiptFactory
        self.router = router
    }

    func mount(
        profile: AuthenticatedProfile,
        paths: AuthenticatedProfileStoragePaths,
        lease: RemoteCompetitionMountLease,
        lifecycle: RemoteCompetitionClientLifecycle
    ) async throws {
        try Self.validateMountLease(lease, lifecycle: lifecycle)
        guard profile.id == paths.profileID else {
            throw RemoteCompetitionRuntimeFailure.profileMismatch
        }
        if pushRegistrationClient != nil,
           installationEnvironment == nil {
            throw CompetitionPushRegistrationFailure.invalidConfiguration
        }
        let completedMount = try await withCancellableOperationGate {
            try Self.validateMountLease(lease, lifecycle: lifecycle)
            guard terminalTeardown == nil else {
                throw EnvironmentSignalOwnershipError.activeOwnerNotRetired
            }
            // Source activation is the atomic ownership reservation. It must
            // succeed before the mounted runtime is disturbed, so a rejected
            // cross-profile mount leaves the origin profile retryable.
            let signalOwnershipActivation = try await environment
                .activateSignalOwnership(for: profile.id)
            var stoppedPriorRuntime = false
            var committedSignalOwnership = false
            do {
                try Self.validateMountLease(lease, lifecycle: lifecycle)
                let stoppedTasks = await stopRuntime()
                stoppedPriorRuntime = true
                try Self.validateMountLease(lease, lifecycle: lifecycle)
                let replacement = LocalCompetitionPublicationHub()
                router.activate(replacement)
                self.profile = profile
                self.hub = replacement
                self.publicationRevision = 0
                self.latestPublication = nil
                self.latestChallenges = .empty
                self.hasStarted = false
                self.isStopped = false
                let installationStore = CompetitionInstallationStateStore(
                    directory: paths.installationsDirectory
                )
                self.inviteRequests = RemoteInviteRequestStore(
                    fileURL: paths.rootDirectory
                        .appendingPathComponent("InviteRequests.json")
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
                    try Self.validateMountLease(lease, lifecycle: lifecycle)
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
                self.lastMaterializations = [:]
                let preferences = notificationPreferencesFactory(paths)
                self.notificationPreferences = preferences
                self.observerDeliveryReceipts =
                    observerDeliveryReceiptFactory(paths)
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
                    try Self.validateMountLease(lease, lifecycle: lifecycle)
                }
                try Self.validateMountLease(lease, lifecycle: lifecycle)
                try await environment.commitSignalOwnershipActivation(
                    signalOwnershipActivation
                )
                committedSignalOwnership = true
                try Self.validateMountLease(lease, lifecycle: lifecycle)
                activeSignalOwnershipLease = signalOwnershipActivation.lease
                activeSignalOwnershipScope = signalOwnershipActivation.scope
                recoverableSignalOwnershipActivation = nil
                return RemoteCompetitionCompletedMount(
                    stoppedTasks: stoppedTasks,
                    profileID: profile.id,
                    ownershipLease: signalOwnershipActivation.lease,
                    ownershipScope: signalOwnershipActivation.scope,
                    runtimeGeneration: runtimeGeneration,
                    ownsNewSignalScope:
                        signalOwnershipActivation.reservationID != nil
                )
            } catch {
                if committedSignalOwnership,
                   signalOwnershipActivation.reservationID != nil {
                    _ = try? await environment.quiesceSignalOwnership(
                        signalOwnershipActivation.lease
                    )
                    try? await environment.retireSignalOwnership(
                        signalOwnershipActivation.lease
                    )
                } else if !committedSignalOwnership {
                    await environment.rollbackSignalOwnershipActivation(
                        signalOwnershipActivation
                    )
                }
                if stoppedPriorRuntime {
                    _ = await stopRuntime()
                    self.profile = nil
                    hub = nil
                    latestPublication = nil
                    latestChallenges = .empty
                    publicationRevision = 0
                    hasStarted = false
                    isStopped = true
                    router.finishCurrent()
                    if signalOwnershipActivation.reservationID == nil {
                        // The source still belongs to the same profile. Keep
                        // a takeover token so an explicit terminal teardown
                        // can atomically claim and retire it, including when
                        // cancellation arrived just after the new lease was
                        // committed.
                        self.profile = profile
                        recoverableSignalOwnershipActivation =
                            committedSignalOwnership
                            ? EnvironmentSignalOwnershipActivation(
                                lease: signalOwnershipActivation.lease,
                                reservationID: nil,
                                expectedOwnerID:
                                    signalOwnershipActivation.lease.ownerID
                            )
                            : signalOwnershipActivation
                    }
                }
                throw error
            }
        }
        await completedMount.stoppedTasks.signal?.value
        await completedMount.stoppedTasks.realtime?.value
        do {
            try Self.validateMountLease(lease, lifecycle: lifecycle)
        } catch {
            try await abortCompletedMountIfNeeded(completedMount)
            throw error
        }
    }

    private static func validateMountLease(
        _ lease: RemoteCompetitionMountLease,
        lifecycle: RemoteCompetitionClientLifecycle
    ) throws {
        try Task.checkCancellation()
        guard lifecycle.isCurrent(lease) else { throw CancellationError() }
    }

    private func abortCompletedMountIfNeeded(
        _ completedMount: RemoteCompetitionCompletedMount
    ) async throws {
        try await withCancellableOperationGate {
            guard terminalTeardown == nil,
                  profile?.id == completedMount.profileID,
                  activeSignalOwnershipScope
                    == completedMount.ownershipScope,
                  activeSignalOwnershipLease
                    == completedMount.ownershipLease,
                  runtimeGeneration == completedMount.runtimeGeneration
            else { return }
            if completedMount.ownsNewSignalScope {
                let drained = try await environment.quiesceSignalOwnership(
                    completedMount.ownershipLease
                )
                guard drained.isEmpty else {
                    throw CompetitionRemoteFailure.retryableTransport
                }
                try await environment.retireSignalOwnership(
                    completedMount.ownershipLease
                )
                activeSignalOwnershipLease = nil
                activeSignalOwnershipScope = nil
            }
            let recoverableProfile = profile
            _ = await stopRuntime()
            if completedMount.ownsNewSignalScope {
                profile = nil
            } else {
                profile = recoverableProfile
                recoverableSignalOwnershipActivation =
                    EnvironmentSignalOwnershipActivation(
                        lease: completedMount.ownershipLease,
                        reservationID: nil,
                        expectedOwnerID:
                            completedMount.ownershipLease.ownerID
                    )
            }
            hub = nil
            latestPublication = nil
            latestChallenges = .empty
            publicationRevision = 0
            hasStarted = false
            isStopped = true
            router.finishCurrent()
        }
    }

    func start() async {
        let generation: UInt64? = await withOperationGate {
            guard terminalTeardown == nil,
                  !hasStarted,
                  !isStopped else { return nil }
            hasStarted = true
            return runtimeGeneration
        }
        guard let generation else { return }

        let authorizationIssue: CompetitionClientIssue?
        do {
            try await environment.requestHealthAuthorization()
            authorizationIssue = nil
        } catch {
            authorizationIssue = .authorizationUnavailable
        }

        await withOperationGate {
            guard generation == runtimeGeneration,
                  terminalTeardown == nil,
                  hasStarted,
                  !isStopped else {
                return
            }
            healthAuthorizationIssue = authorizationIssue
            startSignals()
            startRealtime()
            _ = await performReconciliation()
        }
    }

    func reconcileAll(
        trigger: ActivityRefreshTrigger
    ) async -> CompetitionPublication {
        await withOperationGate {
            guard terminalTeardown == nil else {
                return terminalBlockedPublication()
            }
#if HEALTHCOMP_STAGING
            if trigger == .pullToRefresh {
                return await StagingScoringOperatorControls.shared.observeActivity {
                    await self.performReconciliation()
                }
            }
#endif
            return await performReconciliation()
        }
    }

    private func performReconciliation() async -> CompetitionPublication {
        var issues = healthAuthorizationIssue.map { [$0] } ?? []
        guard let runtime, let profile else {
#if HEALTHCOMP_STAGING
            StagingScoringOperatorControls.recordActivity(.missingDependency)
#endif
            let publication = publish(
                materializations: [],
                issues: issues + [.storageUnavailable]
            )
            await completePendingObserverDeliveries(using: publication)
            return publication
        }
        await installationCoordinator?.reconcile()
        let outcome = await runtime.synchronizeAll()
        if let challenges = try? await remoteAPI.listChallenges() {
            latestChallenges = challenges
        }
        for failure in outcome.failures {
            failure.failure.recordRefreshDiagnostic()
        }
        if let issue = outcome.discoveryFailure?.competitionClientIssue {
            issues.append(issue)
        }
        let reconciled = outcome.reconciled(previous: lastMaterializations)
        lastMaterializations = reconciled.lastGood
        let failedIDs = reconciled.failedIDs
        if !failedIDs.isEmpty {
            issues.append(.competitionFailures(failedIDs))
        }
        let activityFailedIDs = outcome.activityFailures.map(\.competitionID)
            .sorted {
                $0.rawValue.uuidString < $1.rawValue.uuidString
            }
        if !activityFailedIDs.isEmpty {
            issues.append(.activityFailures(activityFailedIDs))
        }
        let publication = await publish(
            materializations: reconciled.materializations,
            profile: profile,
            issues: issues,
            knownCompetitionIDs: outcome.discoveryFailure == nil
                ? Set(outcome.outcomes.map(\.competitionID))
                : nil
        )
        await completePendingObserverDeliveries(using: publication)
        return publication
    }

    func reconcileNotifications() async {
        await withOperationGate {
            guard terminalTeardown == nil else { return }
            await notificationCoordinator.reconcileLatest()
        }
    }

    func loadMutedOpponentIdentities() async throws -> Set<String> {
        try await withCancellableOperationGate {
            guard terminalTeardown == nil else {
                throw EnvironmentSignalOwnershipError.activeOwnerNotRetired
            }
            return try await notificationPreferences.mutedOpponentIdentities()
        }
    }

    func setNotificationMuted(
        _ identity: String,
        isMuted: Bool
    ) async throws {
        try await withCancellableOperationGate {
            guard terminalTeardown == nil else {
                throw EnvironmentSignalOwnershipError.activeOwnerNotRetired
            }
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
        return await withOperationGate {
            guard terminalTeardown == nil else {
                return await notificationClient.authorizationState()
            }
            do {
                _ = try await notificationClient.requestAuthorization()
            } catch {
                return await notificationClient.authorizationState()
            }
            let state = await notificationClient.authorizationState()
            await notificationCoordinator.reconcileLatest()
            return state
        }
    }

    func unsupported(_ id: CompetitionID?) async -> CompetitionPublication {
        await withOperationGate {
            guard terminalTeardown == nil else {
                return terminalBlockedPublication()
            }
            let issue = id.map(CompetitionClientIssue.commandRejected)
                ?? .unimplemented
            return publication(adding: issue)
        }
    }

    func archive(_ id: CompetitionID) async -> CompetitionPublication {
        guard let publication = await withCancellableOperationGateIfActive({
            guard terminalTeardown == nil else {
                return terminalBlockedPublication()
            }
            guard runtime != nil else {
                return publication(adding: .commandRejected(id))
            }
            do {
                try await remoteAPI.archiveCompetition(id.rawValue)
                return await performReconciliation()
            } catch {
                return publication(adding: .commandRejected(id))
            }
        }) else {
            return publication(adding: .commandRejected(id))
        }
        return publication
    }

    /// Accept, decline or cancel: the server command, then a refresh. A
    /// failure marks the match `commandRejected`.
    func respond(
        _ id: CompetitionID,
        inviteUnavailableIsDone: Bool = false,
        _ command: @escaping @Sendable (CompetitionRemoteAPI, UUID) async throws -> Void
    ) async -> CompetitionPublication {
        guard let publication = await withCancellableOperationGateIfActive({
            guard terminalTeardown == nil else {
                return terminalBlockedPublication()
            }
            guard runtime != nil else { return rejection(id) }
            do {
                try await command(remoteAPI, id.rawValue)
            } catch CompetitionRemoteFailure.inviteUnavailable where inviteUnavailableIsDone {
                // No longer pending (cancelled or expired): nothing to decline.
            } catch {
                return rejection(id)
            }
            // A challenge link's Decline can run before Health is set up.
            // Nothing is refreshed (a refresh reads Health) or published
            // until it starts.
            guard hasStarted else { return unpublishedPublication(issues: []) }
            return await performReconciliation()
        }) else {
            return rejection(id)
        }
        return publication
    }

    /// A rejected command; before start it isn't published.
    private func rejection(_ id: CompetitionID) -> CompetitionPublication {
        hasStarted
            ? publication(adding: .commandRejected(id))
            : unpublishedPublication(issues: [.commandRejected(id)])
    }

    /// A read-only server call that needs a signed-in, running profile.
    func remote<Value: Sendable>(
        _ operation: @escaping @Sendable (CompetitionRemoteAPI) async throws -> Value
    ) async throws -> Value {
        try await withCancellableOperationGate {
            guard terminalTeardown == nil else {
                throw EnvironmentSignalOwnershipError.activeOwnerNotRetired
            }
            guard runtime != nil else { throw CompetitionRemoteFailure.unauthenticated }
            return try await operation(remoteAPI)
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

    func resolveInviteRecipient(_ profileID: UUID) async throws -> AuthenticatedProfile {
        try await withCancellableOperationGate {
            guard terminalTeardown == nil else {
                throw EnvironmentSignalOwnershipError.activeOwnerNotRetired
            }
            guard runtime != nil else { throw CompetitionRemoteFailure.unauthenticated }
            return try await remoteAPI.resolveInviteRecipient(profileID)
        }
    }

    func createInvite(
        _ request: CompetitionInviteCreationRequest
    ) async throws -> CompetitionInviteCreationOutcome {
        try await withCancellableOperationGate {
            guard terminalTeardown == nil else {
                throw EnvironmentSignalOwnershipError.activeOwnerNotRetired
            }
            guard runtime != nil else {
                throw CompetitionRemoteFailure.unauthenticated
            }
            let invite = try await remoteAPI.createInvite(request)
            // Replaying this request later returns the same link.
            await inviteRequests?.save(
                request,
                for: CompetitionID(invite.competitionID),
                now: await environment.context().instant.wallDate
            )
            let publication = await performReconciliation()
            return CompetitionInviteCreationOutcome(
                invite: invite,
                expectedPublicationRevision: publication.publicationRevision
            )
        }
    }

    /// Gets a pending challenge's link back by replaying its create request:
    /// the server answers the same key with the same challenge and token.
    func restoreInvite(
        _ id: CompetitionID
    ) async throws -> CompetitionInviteCreationOutcome {
        guard let request = await inviteRequests?.request(
            for: id,
            now: await environment.context().instant.wallDate
        ) else {
            throw CompetitionRemoteFailure.notFound
        }
        let outcome = try await createInvite(request)
        guard outcome.invite.competitionID == id.rawValue else {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
        return outcome
    }

    func claimInvite(
        _ request: CompetitionInviteClaimRequest
    ) async throws -> CompetitionInviteClaimOutcome {
        try await withCancellableOperationGate {
            guard terminalTeardown == nil else {
                throw EnvironmentSignalOwnershipError.activeOwnerNotRetired
            }
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
        if terminalTeardown == nil,
           recoverableSignalOwnershipActivation == nil {
            // A signal reconciliation can be suspended in profile-scoped
            // receipt persistence while holding the operation gate. Cancel
            // the runtime tasks before joining that gate so their cancellation
            // handlers can release external work and make stop bounded.
            signalTask?.cancel()
            realtimeTask?.cancel()
        }
        let stoppedTasks: RemoteCompetitionStoppedTasks? =
            await withOperationGate {
            if let terminalTeardown,
               case .quiescing = terminalTeardown.stage {
                // A failed terminal drain must remain mounted and retryable.
                // App lifecycle stop is not allowed to erase that context.
                return nil
            }
            if recoverableSignalOwnershipActivation != nil {
                // A failed same-profile takeover still carries the only
                // authenticated path to terminally retire the process-rooted
                // source. Ordinary stop must not discard that capability.
                return nil
            }
            isStopped = true
            let stoppedTasks = await stopRuntime()
            profile = nil
            hub = nil
            latestPublication = nil
            latestChallenges = .empty
            publicationRevision = 0
            hasStarted = false
            router.finishCurrent()
            if let terminalTeardown,
               case .retired = terminalTeardown.stage {
                self.terminalTeardown = nil
            }
            return stoppedTasks
        }
        await stoppedTasks?.signal?.value
        await stoppedTasks?.realtime?.value
    }

    func prepareForProfileTeardown(
        requireRemoteInstallationRemoval: Bool
    ) async throws {
        try Task.checkCancellation()
        if terminalTeardown == nil {
            // Terminal preparation must be able to join the operation gate
            // even when signal or realtime work is suspended in an external
            // dependency. Cancellation preserves completion-bearing signals
            // in the process-rooted source for the quiesce/drain phase below.
            signalTask?.cancel()
            realtimeTask?.cancel()
        }
        let work = try await withCancellableOperationGate {
            () -> TerminalPreparationWork? in
            try Task.checkCancellation()
            guard let profile else {
                guard runtime == nil,
                      activeSignalOwnershipScope == nil,
                      activeSignalOwnershipLease == nil,
                      recoverableSignalOwnershipActivation == nil,
                      terminalTeardown == nil
                else {
                    throw CompetitionRemoteFailure.unauthenticated
                }
                // A cancelled bootstrap may have been invalidated before it
                // committed any profile-owned runtime. That is already a
                // terminally clean state, so teardown remains idempotent.
                return nil
            }
            if let activation = recoverableSignalOwnershipActivation {
                guard activation.lease.profileID == profile.id else {
                    throw EnvironmentSignalOwnershipError.inactiveOwner
                }
                try await environment.commitSignalOwnershipActivation(
                    activation
                )
                activeSignalOwnershipLease = activation.lease
                activeSignalOwnershipScope = activation.scope
                recoverableSignalOwnershipActivation = nil
                isStopped = false
            }
            if var terminal = terminalTeardown {
                guard terminal.profileID == profile.id,
                      terminal.runtimeGeneration == runtimeGeneration
                else {
                    throw EnvironmentSignalOwnershipError
                        .activeOwnerNotRetired
                }
                terminal.requiresRemoteInstallationRemoval =
                    terminal.requiresRemoteInstallationRemoval
                    || requireRemoteInstallationRemoval
                terminalTeardown = terminal
                if case .retired = terminal.stage {
                    try await satisfyRetiredInstallationRequirementIfNeeded()
                    return nil
                }
                guard activeSignalOwnershipLease == terminal.ownershipLease,
                      activeSignalOwnershipScope == terminal.ownershipScope
                else {
                    throw EnvironmentSignalOwnershipError.inactiveOwner
                }
                if let terminalPreparationWork {
                    return terminalPreparationWork
                }
            } else {
                guard let activeSignalOwnershipLease,
                      let activeSignalOwnershipScope else {
                    throw CompetitionRemoteFailure.unauthenticated
                }
                terminalTeardown = TerminalTeardown(
                    profileID: profile.id,
                    ownershipLease: activeSignalOwnershipLease,
                    ownershipScope: activeSignalOwnershipScope,
                    runtimeGeneration: runtimeGeneration,
                    requiresRemoteInstallationRemoval:
                        requireRemoteInstallationRemoval,
                    installationPreparationCompleted: false,
                    remoteRemovalRequirementSatisfied: false,
                    stage: .quiescing
                )
            }

            let workID = UUID()
            let task = Task { [weak self] in
                guard let self else {
                    throw CompetitionRemoteFailure.unauthenticated
                }
                try await self.performTerminalPreparation()
            }
            let work = TerminalPreparationWork(id: workID, task: task)
            terminalPreparationWork = work
            return work
        }
        guard let work else { return }
        do {
            try await work.task.value
        } catch {
            if terminalPreparationWork?.id == work.id {
                terminalPreparationWork = nil
            }
            throw error
        }
        if terminalPreparationWork?.id == work.id {
            terminalPreparationWork = nil
        }
        try await withCancellableOperationGate {
            try await satisfyRetiredInstallationRequirementIfNeeded()
        }
    }

    private func performTerminalPreparation() async throws {
        let quiescing = try await withCancellableOperationGate { () -> (
            profileID: UUID,
            ownershipLease: EnvironmentSignalOwnershipLease,
            ownershipScope: EnvironmentSignalOwnershipScope,
            runtimeGeneration: UInt64,
            signalTask: Task<Void, Never>?
        ) in
            guard let profile,
                  let activeSignalOwnershipLease,
                  let activeSignalOwnershipScope,
                  var terminal = terminalTeardown,
                  case .quiescing = terminal.stage
            else {
                throw CompetitionRemoteFailure.unauthenticated
            }
            guard terminal.profileID == profile.id,
                  terminal.ownershipLease == activeSignalOwnershipLease,
                  terminal.ownershipScope == activeSignalOwnershipScope,
                  terminal.runtimeGeneration == runtimeGeneration,
                  !isStopped
            else {
                throw CompetitionRemoteFailure.unauthenticated
            }
            if !terminal.installationPreparationCompleted
                || (terminal.requiresRemoteInstallationRemoval
                    && !terminal.remoteRemovalRequirementSatisfied) {
                let requiresRemoteRemoval =
                    terminal.requiresRemoteInstallationRemoval
                try await installationCoordinator?.prepareForProfileTeardown(
                    requireRemoteRemoval: requiresRemoteRemoval
                )
                guard profile.id == terminal.profileID,
                      activeSignalOwnershipLease == terminal.ownershipLease,
                      activeSignalOwnershipScope == terminal.ownershipScope,
                      runtimeGeneration == terminal.runtimeGeneration,
                      self.terminalTeardown?.profileID == terminal.profileID,
                      !isStopped
                else {
                    throw CompetitionRemoteFailure.unauthenticated
                }
                terminal.installationPreparationCompleted = true
                terminal.remoteRemovalRequirementSatisfied =
                    terminal.remoteRemovalRequirementSatisfied
                    || requiresRemoteRemoval
                terminalTeardown = terminal
            }
            let drainedSignals = try await environment
                .quiesceSignalOwnership(terminal.ownershipLease)
            guard profile.id == terminal.profileID,
                  activeSignalOwnershipLease == terminal.ownershipLease,
                  activeSignalOwnershipScope == terminal.ownershipScope,
                  runtimeGeneration == terminal.runtimeGeneration,
                  !isStopped
            else {
                throw CompetitionRemoteFailure.unauthenticated
            }
            try mergeDrainedObserverDeliveries(
                drainedSignals,
                ownershipScope: terminal.ownershipScope,
                generation: terminal.runtimeGeneration
            )
            let task = signalTask
            task?.cancel()
            signalTask = nil
            return (
                terminal.profileID,
                terminal.ownershipLease,
                terminal.ownershipScope,
                terminal.runtimeGeneration,
                task
            )
        }
        await quiescing.signalTask?.value

        try await withCancellableOperationGate {
            guard profile?.id == quiescing.profileID,
                  activeSignalOwnershipLease == quiescing.ownershipLease,
                  activeSignalOwnershipScope == quiescing.ownershipScope,
                  runtimeGeneration == quiescing.runtimeGeneration,
                  terminalTeardown?.profileID == quiescing.profileID,
                  terminalTeardown?.ownershipLease
                    == quiescing.ownershipLease,
                  terminalTeardown?.ownershipScope == quiescing.ownershipScope,
                  terminalTeardown?.runtimeGeneration
                    == quiescing.runtimeGeneration,
                  !isStopped
            else {
                throw CompetitionRemoteFailure.unauthenticated
            }
            guard let terminalTeardown,
                  case .quiescing = terminalTeardown.stage
            else {
                throw EnvironmentSignalOwnershipError.inactiveOwner
            }

            _ = await performReconciliation()
            guard !pendingObserverDeliveries.values.contains(where: {
                $0.ownershipScope == quiescing.ownershipScope
            }) else {
                throw CompetitionRemoteFailure.retryableTransport
            }
            try await environment.retireSignalOwnership(
                quiescing.ownershipLease
            )
            activeSignalOwnershipLease = nil
            activeSignalOwnershipScope = nil
            self.terminalTeardown?.stage = .retired
        }
    }

    private func satisfyRetiredInstallationRequirementIfNeeded()
        async throws
    {
        guard let profile,
              var terminal = terminalTeardown,
              case .retired = terminal.stage,
              terminal.profileID == profile.id,
              terminal.runtimeGeneration == runtimeGeneration,
              !isStopped
        else {
            throw CompetitionRemoteFailure.unauthenticated
        }
        guard terminal.requiresRemoteInstallationRemoval,
              !terminal.remoteRemovalRequirementSatisfied
        else { return }
        try await installationCoordinator?.prepareForProfileTeardown(
            requireRemoteRemoval: true
        )
        guard self.profile?.id == terminal.profileID,
              self.terminalTeardown?.profileID == terminal.profileID,
              self.terminalTeardown?.runtimeGeneration
                == terminal.runtimeGeneration,
              !isStopped
        else {
            throw CompetitionRemoteFailure.unauthenticated
        }
        terminal.installationPreparationCompleted = true
        terminal.remoteRemovalRequirementSatisfied = true
        terminalTeardown = terminal
    }

    private func mergeDrainedObserverDeliveries(
        _ signals: [EnvironmentSignal],
        ownershipScope: EnvironmentSignalOwnershipScope,
        generation: UInt64
    ) throws {
        for signal in signals {
            guard signal.requiresCompletion,
                  signal.ownershipScope == ownershipScope
            else {
                throw EnvironmentSignalOwnershipError.inactiveOwner
            }
            if var existing = pendingObserverDeliveries[signal.id] {
                guard existing.ownershipScope == ownershipScope else {
                    throw EnvironmentSignalOwnershipError.inactiveOwner
                }
                existing.observedGeneration = generation
                pendingObserverDeliveries[signal.id] = existing
            } else {
                pendingObserverDeliveries[signal.id] =
                    PendingObserverDelivery(
                        signal: signal,
                        ownershipScope: ownershipScope,
                        observedGeneration: generation,
                        receipt: nil
                    )
            }
        }
    }

    private func terminalBlockedPublication() -> CompetitionPublication {
        latestPublication ?? unpublishedPublication(issues: [.storageUnavailable])
    }

    /// An empty answer that isn't sent to subscribers.
    private func unpublishedPublication(
        issues: [CompetitionClientIssue]
    ) -> CompetitionPublication {
        CompetitionPublication(
            publicationRevision: publicationRevision,
            dashboard: CompetitionDashboard(
                competitions: [],
                awards: [],
                issues: issues,
                hiddenTerminalCompetitionCount: 0
            ),
            evaluatedAt: .distantPast,
            timeZoneIdentifier: "UTC",
            source: .remoteParticipants
        )
    }

    private func stopRuntime() async -> RemoteCompetitionStoppedTasks {
        runtimeGeneration &+= 1
        healthAuthorizationIssue = nil
        let stoppedTasks = RemoteCompetitionStoppedTasks(
            signal: signalTask,
            realtime: realtimeTask
        )
        stoppedTasks.signal?.cancel()
        stoppedTasks.realtime?.cancel()
        signalTask = nil
        realtimeTask = nil
        boundaryTask?.cancel()
        boundaryTask = nil
        lastPublishInputs = nil
        latestChallenges = .empty
        if stoppedTasks.realtime != nil {
            await realtimeClient.stop()
        }
        for competitionID in mountedCompetitionIDs.sorted(by: {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }) {
            await notificationCoordinator.cancelAll(competitionID)
        }
        mountedCompetitionIDs = []
        inviteRequests = nil
        notificationCoordinator = .noop
        notificationPreferences = .unavailable
        observerDeliveryReceipts = .discarding
        activeSignalOwnershipLease = nil
        activeSignalOwnershipScope = nil
        await installationCoordinator?.stopListening()
        installationCoordinator = nil
        await runtime?.stop()
        runtime = nil
        lastMaterializations = [:]
        return stoppedTasks
    }

    private func startSignals() {
        guard terminalTeardown == nil, signalTask == nil else { return }
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
        guard terminalTeardown == nil,
              realtimeTask == nil,
              let profile else { return }
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
            guard terminalTeardown == nil,
                  generation == runtimeGeneration,
                  !Task.isCancelled else {
                return
            }
            guard let activeSignalOwnershipScope else { return }
            if let signalOwnershipScope = signal.ownershipScope,
               signalOwnershipScope != activeSignalOwnershipScope {
                if signal.requiresCompletion,
                   pendingObserverDeliveries[signal.id] == nil {
                    pendingObserverDeliveries[signal.id] =
                        PendingObserverDelivery(
                            signal: signal,
                            ownershipScope: signalOwnershipScope,
                            observedGeneration: nil,
                            receipt: nil
                        )
                }
                return
            }
            if signal.requiresCompletion {
                guard let signalOwnershipScope = signal.ownershipScope else {
                    return
                }
                let existing = pendingObserverDeliveries[signal.id]
                guard existing?.ownershipScope == nil
                    || existing?.ownershipScope == signalOwnershipScope
                else {
                    return
                }
                guard signalOwnershipScope == activeSignalOwnershipScope else {
                    return
                }
                if var existing {
                    existing.observedGeneration = runtimeGeneration
                    pendingObserverDeliveries[signal.id] = existing
                } else {
                    pendingObserverDeliveries[signal.id] =
                        PendingObserverDelivery(
                            signal: signal,
                            ownershipScope: signalOwnershipScope,
                            observedGeneration: runtimeGeneration,
                            receipt: nil
                        )
                }
            }
            _ = await performReconciliation()
        }
    }

    private func completePendingObserverDeliveries(
        using publication: CompetitionPublication
    ) async {
        guard let activeSignalOwnershipScope else { return }
        for signalID in pendingObserverDeliveries.keys.sorted() {
            guard var pending = pendingObserverDeliveries[signalID]
            else { continue }
            guard pending.ownershipScope == activeSignalOwnershipScope,
                  pending.observedGeneration == runtimeGeneration
            else { continue }
            do {
                if try await observerDeliveryReceipts.contains(signalID) {
                    HealthKitDeliveryDiagnostic.receiptAlreadyStored.record()
                    guard canCompleteObserverDelivery(
                        signalID,
                        ownershipScope: pending.ownershipScope
                    ) else { continue }
                    if await environment.completeSignal(signalID) {
                        pendingObserverDeliveries[signalID] = nil
                    }
                    continue
                }
                if pending.receipt == nil {
                    pending.receipt = HealthKitObserverDeliveryReceipt(
                        signalID: pending.signal.id,
                        trigger: pending.signal.trigger,
                        processedAt: publication.evaluatedAt,
                        publicationRevision: publication.publicationRevision,
                        hadIssues: !publication.dashboard.issues.isEmpty
                    )
                    pendingObserverDeliveries[signalID] = pending
                }
                guard let receipt = pending.receipt else { continue }
                try await observerDeliveryReceipts.commit(receipt)
                HealthKitDeliveryDiagnostic.receiptStored.record()
                guard canCompleteObserverDelivery(
                    signalID,
                    ownershipScope: pending.ownershipScope
                ) else { continue }
                if await environment.completeSignal(signalID) {
                    pendingObserverDeliveries[signalID] = nil
                }
            } catch {
                HealthKitDeliveryDiagnostic.receiptPersistenceFailed.record()
                // HealthKit retains the callback until a later canonical
                // reconciliation commits the same privacy-safe receipt.
            }
        }
    }

    private func canCompleteObserverDelivery(
        _ signalID: String,
        ownershipScope: EnvironmentSignalOwnershipScope
    ) -> Bool {
        guard !Task.isCancelled,
              !isStopped,
              activeSignalOwnershipScope == ownershipScope,
              let pending = pendingObserverDeliveries[signalID],
              pending.ownershipScope == ownershipScope,
              pending.observedGeneration == runtimeGeneration
        else {
            return false
        }
        return true
    }

    private func consumeRealtime(
        _ wakeUp: CompetitionRealtimeWakeUp,
        generation: UInt64
    ) async {
        await withOperationGate {
            guard terminalTeardown == nil,
                  generation == runtimeGeneration,
                  !Task.isCancelled else {
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

    private func withCancellableOperationGate<Value>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        guard await acquireCancellableOperationGate() else {
            throw CancellationError()
        }
        do {
            try Task.checkCancellation()
            let result = try await operation()
            releaseOperationGate()
            return result
        } catch {
            releaseOperationGate()
            throw error
        }
    }

    private func withCancellableOperationGateIfActive<Value>(
        _ operation: () async -> Value
    ) async -> Value? {
        guard await acquireCancellableOperationGate() else { return nil }
        guard !Task.isCancelled else {
            releaseOperationGate()
            return nil
        }
        let result = await operation()
        releaseOperationGate()
        return result
    }

    private func acquireOperationGate() async {
        guard operationIsInProgress else {
            operationIsInProgress = true
            return
        }
        _ = await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            operationWaiters.append(
                OperationWaiter(id: UUID(), continuation: continuation)
            )
        }
    }

    private func acquireCancellableOperationGate() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard operationIsInProgress else {
            operationIsInProgress = true
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                operationWaiters.append(
                    OperationWaiter(
                        id: waiterID,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { await self.cancelOperationWaiter(waiterID) }
        }
    }

    private func cancelOperationWaiter(_ waiterID: UUID) {
        guard let index = operationWaiters.firstIndex(where: {
            $0.id == waiterID
        }) else { return }
        operationWaiters.remove(at: index).continuation.resume(
            returning: false
        )
    }

    private func releaseOperationGate() {
        guard !operationWaiters.isEmpty else {
            operationIsInProgress = false
            return
        }
        operationWaiters.removeFirst().continuation.resume(returning: true)
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
                issues: issues,
                challenges: latestChallenges
            ).keepingFailedCompetitions(
                from: latestPublication?.dashboard,
                now: context.instant.wallDate
            ),
            evaluatedAt: context.instant.wallDate,
            timeZoneIdentifier: context.timeZoneIdentifier
        )
        lastPublishInputs = (materializations, issues, knownCompetitionIDs)
        scheduleBoundaryRepublish(
            at: publication.dashboard.nextHomeBoundary(
                after: context.instant.wallDate
            )
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
        // Without discovery the full set of matches is unknown: keep the
        // last good file. Matches that didn't sync this round carry forward.
        if let knownCompetitionIDs {
            let unsynced = Set(knownCompetitionIDs.subtracting(materializedIDs).map(\.rawValue))
            await widgetSnapshots.write(
                CompetitionWidgetSnapshot(dashboard: publication.dashboard), unsynced
            )
        }
        return publication
    }

    // ponytail: one republish at the next boundary, rescheduled by every publish; no network.
    private func scheduleBoundaryRepublish(at wake: Date?) {
        boundaryTask?.cancel()
        boundaryTask = nil
        guard let wake else { return }
        let generation = runtimeGeneration
        boundaryTask = Task { [weak self, environment] in
            do {
                try await environment.wait(until: wake)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.republishAtBoundary(generation: generation)
        }
    }

    private func republishAtBoundary(generation: UInt64) async {
        await withOperationGate {
            guard generation == runtimeGeneration,
                  terminalTeardown == nil,
                  !isStopped,
                  let profile,
                  let inputs = lastPublishInputs
            else {
                return
            }
            _ = await publish(
                materializations: inputs.materializations,
                profile: profile,
                issues: inputs.issues,
                knownCompetitionIDs: inputs.knownCompetitionIDs
            )
        }
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

extension RemoteCompetitionRuntimeOutcome {
    /// A match whose sync was only cancelled (the person left the screen
    /// mid-refresh) is not a failure: it keeps its last good materialization
    /// and raises no issue. A failed match stays on screen with its last
    /// presentation, so it keeps its last good materialization for a later
    /// cancelled sync too.
    func reconciled(
        previous: [CompetitionID: RemoteCompetitionMaterialization]
    ) -> (
        materializations: [RemoteCompetitionMaterialization],
        failedIDs: [CompetitionID],
        lastGood: [CompetitionID: RemoteCompetitionMaterialization]
    ) {
        let cancelled = failures.filter { $0.failure == .cancelled }
        let failedIDs = failures.filter { $0.failure != .cancelled }
            .map(\.competitionID)
            .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        let materializations = successfulCompetitions
            + cancelled.compactMap { previous[$0.competitionID] }
        let lastGood = previous.filter { failedIDs.contains($0.key) }.merging(
            materializations.map { (CompetitionID($0.descriptor.competitionID), $0) }
        ) { _, new in new }
        return (materializations, failedIDs, lastGood)
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
        opponentName: opponent?.profile.displayName ?? "Someone",
        opponentID: opponent?.profileID
    )
}

enum RemoteCompetitionProjector {
    static func dashboard(
        materializations: [RemoteCompetitionMaterialization],
        profile: AuthenticatedProfile,
        context: CompetitionEnvironmentContext,
        issues: [CompetitionClientIssue],
        challenges: CompetitionChallengeList = .empty
    ) -> CompetitionDashboard {
        let materialized = materializations.compactMap {
            presentation(
                from: $0,
                profile: profile,
                context: context,
                closesLapsedChallenges: true
            )
        }
        let all = (materialized + challengePresentations(
            challenges,
            excluding: Set(materialized.map(\.id)),
            profile: profile,
            context: context
        )).sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        let visible = all.filter {
            competitionIsRetainedOnDashboard($0.lifecycle, now: context.instant.wallDate)
        }
        return CompetitionDashboard(
            competitions: visible,
            awards: awards(from: visible),
            issues: issues,
            hiddenTerminalCompetitionCount: all.count - visible.count
        )
    }

    /// Incoming challenges and the last day's declines and cancels. They have
    /// no local journal, so they never schedule notifications.
    static func challengePresentations(
        _ challenges: CompetitionChallengeList,
        excluding materializedIDs: Set<CompetitionID>,
        profile: AuthenticatedProfile,
        context: CompetitionEnvironmentContext
    ) -> [CompetitionPresentation] {
        let now = context.instant.wallDate
        func presentation(
            _ id: UUID,
            other: AuthenticatedProfile,
            lifecycle: CompetitionLifecyclePresentation,
            timeZoneIdentifier: String
        ) -> CompetitionPresentation? {
            guard !materializedIDs.contains(CompetitionID(id)) else { return nil }
            return CompetitionPresentation(
                id: CompetitionID(id),
                ownerDisplayName: profile.displayName,
                opponentDisplayName: other.displayName,
                opponentIdentity: RemoteCompetitionOpponentIdentity.identity(for: other.id),
                lifecycle: lifecycle,
                acceptedConfiguration: nil,
                userPoints: 0,
                opponentPoints: 0,
                days: [],
                currentDayOrdinal: nil,
                lastRefresh: nil,
                tally: nil,
                terminalResult: nil,
                evaluatedAt: now,
                timeZoneIdentifier: timeZoneIdentifier
            )
        }
        let incoming = challenges.incoming.filter { $0.expiresAt > now }.compactMap {
            presentation(
                $0.competitionID,
                other: $0.sender,
                lifecycle: .pending(direction: .incoming, createdAt: $0.createdAt, expiresAt: $0.expiresAt),
                timeZoneIdentifier: $0.timeZoneIdentifier
            )
        }
        let closed = challenges.closed
            .filter { $0.closedAt > now.addingTimeInterval(-competitionClosedChallengeRetention) }
            .compactMap { row -> CompetitionPresentation? in
                presentation(
                    row.competitionID,
                    other: row.other,
                    lifecycle: row.kind == .declined
                        ? .declined(at: row.closedAt, direction: .outgoing)
                        : .cancelled(at: row.closedAt),
                    timeZoneIdentifier: context.timeZoneIdentifier
                )
            }
        return incoming + closed
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
                lifecyclePresentation(
                    competition.lifecycle,
                    direction: loaded.journal.genesis.direction
                )
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
        case let .pending(direction, _, expiresAt):
            .pending(direction: direction, expiresAt: expiresAt)
        case .declined, .cancelled:
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

    /// `closesLapsedChallenges` shows a pending challenge past its expiry as
    /// expired. The server only flips it lazily, so the dashboard does it;
    /// notifications keep the stored lifecycle.
    private static func presentation(
        from materialization: RemoteCompetitionMaterialization,
        profile: AuthenticatedProfile,
        context: CompetitionEnvironmentContext,
        closesLapsedChallenges: Bool = false
    ) -> CompetitionPresentation? {
        let projection = materialization.journal.projection
        let competition = projection.competition
        var lifecycle = lifecyclePresentation(
            competition.lifecycle,
            direction: materialization.journal.journal.genesis.direction
        )
        if closesLapsedChallenges,
           case let .pending(direction, _, expiresAt?) = lifecycle,
           expiresAt <= context.instant.wallDate {
            lifecycle = .expired(at: expiresAt, direction: direction)
        }
        let participantPresentation = remoteCompetitionParticipantPresentation(
            descriptor: materialization.descriptor,
            profile: profile
        )
        let ownerName = participantPresentation.ownerName
        let opponentName = participantPresentation.opponentName
        let opponentID = participantPresentation.opponentID
        let terminal = terminalPresentation(competition.lifecycle)
        let schedule = competition.schedule
        let activity = materialization.ownerActivity
        let days = schedule.map {
            dayPresentations(
                schedule: $0,
                projection: projection,
                ownerID: profile.id,
                remoteID: opponentID,
                now: context.instant.wallDate,
                terminal: terminal,
                ownerActivity: activity
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
            lifecycle: lifecycle,
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
            // Remote reads don't record a trigger and no screen shows one.
            lastRefresh: activity.map {
                CompetitionRefreshPresentation(
                    trigger: .reconciliationProbe,
                    attemptedAt: $0.checkedAt,
                    readAt: $0.checkedAt,
                    status: $0.checkFailure.map { .failed(reason: $0) } ?? .completed
                )
            },
            tally: tallyPresentation(
                competition: competition,
                projection: projection,
                ownerID: profile.id,
                opponentID: opponentID
            ),
            terminalResult: terminal,
            evaluatedAt: context.instant.wallDate,
            timeZoneIdentifier: schedule?.calendar.timeZoneIdentifier
                ?? context.timeZoneIdentifier,
            lastSuccessfulFullWindowRefreshAt: activity?.readAt,
            opponentUpdatedAt: opponentID.flatMap {
                projection.remoteLatestRecordedAt[$0]
            },
            rematchParentID: materialization.descriptor.rematchParentID
                .map(CompetitionID.init)
        )
    }

    private static func dayPresentations(
        schedule: CompetitionSchedule,
        projection: CompetitionReplayProjection,
        ownerID: UUID,
        remoteID: UUID?,
        now: Date,
        terminal: CompetitionTerminalPresentation?,
        ownerActivity: RemoteOwnerActivity? = nil
    ) -> [CompetitionDayPresentation] {
        guard let days = try? schedule.calendar.sevenDayWindow(
            startingOn: schedule.startDay
        ) else { return [] }
        return days.enumerated().map { offset, day in
            let ordinal = offset + 1
            let start = try? schedule.calendar.startOfDay(day)
            let end = try? schedule.calendar.startOfDay(
                schedule.calendar.day(after: day)
            )
            let future = start.map { now < $0 } ?? true
            let isToday = !future && end.map { now < $0 } == true
            let activityDay = ownerActivity?.days.first { $0.ordinal == ordinal }
            let owner = projection.remoteScoreLedgers[ownerID].flatMap {
                try? $0.visibleEntry(forActiveDayOrdinal: ordinal)
            }
            let remote = remoteID.flatMap {
                profileID in
                projection.remoteScoreLedgers[profileID].flatMap {
                    try? $0.visibleEntry(forActiveDayOrdinal: ordinal)
                }
            }
            // "sourceDataUnavailable" is the runtime's row for a day Health
            // had no summary for, so it reads as missing (or not synced yet).
            let availability: CompetitionOwnerAvailability
            if future {
                availability = .notYetOccurred
            } else if activityDay?.latestSnapshot != nil
                        || owner?.acceptedCentiPoints != nil {
                availability = .observed
            } else if let reason = owner?.availabilityReason,
                      reason != "sourceDataUnavailable" {
                availability = .unavailable(
                    reason: ActivityUnavailableReason(rawValue: reason)
                        ?? .invalidSourceData
                )
            } else if isToday {
                availability = .notSyncedYet
            } else {
                availability = .missing
            }
            // An older reading never labels a newer row.
            let acceptedSnapshot = activityDay?.acceptedClientRevision != nil
                && activityDay?.acceptedClientRevision == owner?.clientRevision
                ? activityDay?.acceptedSnapshot : nil
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
                opponentReportedNoData: !(future && terminal == nil)
                    && remote != nil && remote?.acceptedCentiPoints == nil,
                ownerAcceptedSnapshot: acceptedSnapshot,
                ownerLatestSnapshot: activityDay?.latestSnapshot,
                scoringPolicy: .remoteWireV1
            )
        }
    }

    private static func lifecyclePresentation(
        _ lifecycle: CompetitionLifecycle,
        direction: InvitationDirection
    ) -> CompetitionLifecyclePresentation {
        switch lifecycle {
        case let .pendingInvitation(invitation):
            .pending(
                direction: invitation.direction,
                createdAt: invitation.createdAt,
                expiresAt: invitation.expiresAt
            )
        case let .declined(at): .declined(at: at, direction: direction)
        case let .expired(at): .expired(at: at, direction: direction)
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
        ownerID: UUID,
        opponentID: UUID?
    ) -> CompetitionTallyPresentation? {
        guard case .tallying = competition.lifecycle,
              let configuration = competition.remoteConfiguration
        else { return nil }
        // A row that carries an unavailable reason is in: the iPhone attests
        // stable once all seven rows exist, so it never blocks the result.
        // Your "sourceDataUnavailable" row means Health had no summary, so
        // it reads as missing, like the day states.
        func missingDays(_ id: UUID?) -> Set<Int> {
            let ledger = id.flatMap { projection.remoteScoreLedgers[$0] }
            return Set((1...7).filter { day in
                guard let row = ledger.flatMap({
                    try? $0.visibleEntry(forActiveDayOrdinal: day)
                }) else { return true }
                return id == ownerID
                    && row.availabilityReason == "sourceDataUnavailable"
            })
        }
        return CompetitionTallyPresentation(
            attention: remoteTallyAttention(
                ownerMissing: missingDays(ownerID),
                opponentMissing: missingDays(opponentID),
                ownerAttestedStable: projection
                    .remoteWindowAttestations[ownerID]?.basis == .stable
            ),
            consecutiveStableCompleteReads: 0,
            stabilityStart: nil,
            bestAvailableDeadline: configuration.bestAvailableDeadline
        )
    }

    /// Waits on whoever has missing day rows: you first, then them. Your
    /// stable check locks your window (later rows get `window_stable`), so
    /// your missing days stop counting and the wait is theirs: the server
    /// finalizes in the same transaction as the second stable check
    /// (`attest_final_window`), so a still-tallying match hasn't got it.
    static func remoteTallyAttention(
        ownerMissing: Set<Int>,
        opponentMissing: Set<Int>,
        ownerAttestedStable: Bool
    ) -> CompetitionTallyAttention {
        if !ownerAttestedStable, !ownerMissing.isEmpty {
            return .incomplete(missingOrdinals: ownerMissing, unavailableOrdinals: [])
        }
        if !opponentMissing.isEmpty { return .opponentPlanUnavailable }
        return ownerAttestedStable ? .awaitingOpponentCheck : .awaitingStability
    }

    static func awards(
        from presentations: [CompetitionPresentation]
    ) -> [CompetitionAward] {
        presentations.compactMap { presentation -> CompetitionAward? in
            guard let terminal = presentation.terminalResult,
                  terminal.outcome == .win else { return nil }
            return CompetitionAward(
                id: "remote-competition-award:v1:\(presentation.id.rawValue.uuidString.lowercased()):victory",
                competitionID: presentation.id,
                awardedAt: terminal.completedAt,
                friendDisplayName: presentation.opponentDisplayName,
                opponentIdentity: presentation.opponentIdentity
            )
        }.sortedNewestFirst()
    }
}
