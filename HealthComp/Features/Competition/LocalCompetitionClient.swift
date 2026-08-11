import CompetitionCore
import CryptoKit
import Dependencies
import Foundation

// MARK: - Immutable presentation

struct LocalCompetitionIdentity: Equatable, Sendable {
    static let version: UInt32 = 1
    static let ownerDisplayName = "Naren"
    static let opponentDisplayName = "Alex"
    static let opponentIdentity = "local-opponent:v1:default"
    static let opponentDifficulty = OpponentDifficulty.balanced
    static let bootstrapCompetitionID = CompetitionID(
        UUID(uuidString: "6D33D624-2E0C-4C03-9D41-2A27E0D58E01")!
    )

    /// Version 1 is FNV-1a 64 over a domain separator followed by the UUID's
    /// 16 RFC-4122 bytes. It is stable across processes and Swift releases.
    static func opponentSeed(for id: CompetitionID) -> UInt64 {
        let domain = Array("healthcomp.local-opponent-seed.v1".utf8)
        let identifierBytes = withUnsafeBytes(of: id.rawValue.uuid) {
            Array($0)
        }
        return (domain + identifierBytes).reduce(
            UInt64(14_695_981_039_346_656_037)
        ) { value, byte in
            (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    /// Version 1 hashes a domain separator followed by the source UUID's 16
    /// RFC-4122 bytes, then pins the derived identity to UUID version 5 and
    /// the RFC variant. The domain and byte encoding are persistence format.
    static func rematchID(for sourceID: CompetitionID) -> CompetitionID {
        var input = Data("healthcomp.local-rematch-id.v1".utf8)
        withUnsafeBytes(of: sourceID.rawValue.uuid) {
            input.append(contentsOf: $0)
        }
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return CompetitionID(
            UUID(
                uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3],
                    bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11],
                    bytes[12], bytes[13], bytes[14], bytes[15]
                )
            )
        )
    }
}

struct LocalCompetitionAcceptedPresentation: Equatable, Sendable {
    let schedule: CompetitionSchedule
    let difficulty: OpponentDifficulty
}

enum LocalCompetitionLifecyclePresentation: Equatable, Sendable {
    case pending(
        direction: InvitationDirection,
        createdAt: Date,
        expiresAt: Date?
    )
    case declined(at: Date)
    case expired(at: Date)
    case scheduled
    case active(dayOrdinal: Int)
    case endsToday
    case tallying(startedAt: Date)
    case completed(
        outcome: CompetitionOutcome,
        basis: FinalizationBasis,
        completedAt: Date
    )
    case archived(
        outcome: CompetitionOutcome,
        basis: FinalizationBasis,
        completedAt: Date,
        archivedAt: Date
    )
}

enum LocalCompetitionOwnerAvailability: Equatable, Sendable {
    case notYetOccurred
    case observed
    case missing
    case unavailable(reason: ActivityUnavailableReason)
}

struct LocalCompetitionDayPresentation: Equatable, Sendable {
    let day: CompetitionDay
    let ordinal: Int
    let ownerAcceptedPoints: Double?
    let ownerLatestAvailability: LocalCompetitionOwnerAvailability
    /// `nil` means this checkpoint is in the future. No plan final is exposed.
    let opponentRevealedPoints: Double?
    /// The snapshot that produced the accepted score, never reconstructed from
    /// points. It may differ from the most recent Health source evidence when
    /// downward revisions are preserved by the score ledger.
    let ownerAcceptedSnapshot: ActivitySnapshot?
    /// The snapshot in the latest completed source read for this day. `nil`
    /// remains distinct from missing, unavailable, and future source states.
    let ownerLatestSnapshot: ActivitySnapshot?

    init(
        day: CompetitionDay,
        ordinal: Int,
        ownerAcceptedPoints: Double?,
        ownerLatestAvailability: LocalCompetitionOwnerAvailability,
        opponentRevealedPoints: Double?,
        ownerAcceptedSnapshot: ActivitySnapshot? = nil,
        ownerLatestSnapshot: ActivitySnapshot? = nil
    ) {
        self.day = day
        self.ordinal = ordinal
        self.ownerAcceptedPoints = ownerAcceptedPoints
        self.ownerLatestAvailability = ownerLatestAvailability
        self.opponentRevealedPoints = opponentRevealedPoints
        self.ownerAcceptedSnapshot = ownerAcceptedSnapshot
        self.ownerLatestSnapshot = ownerLatestSnapshot
    }
}

struct LocalCompetitionRefreshPresentation: Equatable, Sendable {
    let trigger: ActivityRefreshTrigger
    let attemptedAt: Date
    let readAt: Date
    let status: ActivityRefreshReadStatus
}

enum LocalCompetitionTallyAttention: Equatable, Sendable {
    case noRead
    case incomplete(
        missingOrdinals: Set<Int>,
        unavailableOrdinals: Set<Int>
    )
    case unacceptedScores(ordinals: Set<Int>)
    case opponentPlanUnavailable
    case awaitingStability
}

struct LocalCompetitionTallyPresentation: Equatable, Sendable {
    let attention: LocalCompetitionTallyAttention?
    let consecutiveStableCompleteReads: Int
    let stabilityStart: MonotonicInstant?
    let bestAvailableDeadline: Date
}

struct LocalCompetitionTerminalPresentation: Equatable, Sendable {
    let userPoints: Double
    let opponentPoints: Double
    let outcome: CompetitionOutcome
    let basis: FinalizationBasis
    let completedAt: Date
}

struct LocalCompetitionPresentation: Equatable, Identifiable, Sendable {
    let id: CompetitionID
    let ownerDisplayName: String
    let opponentDisplayName: String
    let opponentIdentity: String
    let lifecycle: LocalCompetitionLifecyclePresentation
    let acceptedConfiguration: LocalCompetitionAcceptedPresentation?
    let userPoints: Double
    let opponentPoints: Double
    let days: [LocalCompetitionDayPresentation]
    let currentDayOrdinal: Int?
    let lastRefresh: LocalCompetitionRefreshPresentation?
    let tally: LocalCompetitionTallyPresentation?
    let terminalResult: LocalCompetitionTerminalPresentation?
    /// The injected environment time used to build this projection.
    let evaluatedAt: Date
    /// The immutable competition environment time zone used for day labels.
    let timeZoneIdentifier: String
    let lastSuccessfulFullWindowRefreshAt: Date?

    init(
        id: CompetitionID,
        ownerDisplayName: String,
        opponentDisplayName: String,
        opponentIdentity: String = LocalCompetitionIdentity.opponentIdentity,
        lifecycle: LocalCompetitionLifecyclePresentation,
        acceptedConfiguration: LocalCompetitionAcceptedPresentation?,
        userPoints: Double,
        opponentPoints: Double,
        days: [LocalCompetitionDayPresentation],
        currentDayOrdinal: Int?,
        lastRefresh: LocalCompetitionRefreshPresentation?,
        tally: LocalCompetitionTallyPresentation?,
        terminalResult: LocalCompetitionTerminalPresentation?,
        evaluatedAt: Date = .distantPast,
        timeZoneIdentifier: String = "UTC",
        lastSuccessfulFullWindowRefreshAt: Date? = nil
    ) {
        self.id = id
        self.ownerDisplayName = ownerDisplayName
        self.opponentDisplayName = opponentDisplayName
        self.opponentIdentity = opponentIdentity
        self.lifecycle = lifecycle
        self.acceptedConfiguration = acceptedConfiguration
        self.userPoints = userPoints
        self.opponentPoints = opponentPoints
        self.days = days
        self.currentDayOrdinal = currentDayOrdinal
        self.lastRefresh = lastRefresh
        self.tally = tally
        self.terminalResult = terminalResult
        self.evaluatedAt = evaluatedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.lastSuccessfulFullWindowRefreshAt =
            lastSuccessfulFullWindowRefreshAt
    }
}

struct LocalCompetitionAward: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case completion
        case victory
    }

    let id: String
    let competitionID: CompetitionID
    let kind: Kind
    let awardedAt: Date
    let friendDisplayName: String

    static func fold(
        completed presentations: [LocalCompetitionPresentation]
    ) -> [Self] {
        var awardsByID: [String: Self] = [:]
        for presentation in presentations {
            guard let terminal = presentation.terminalResult else { continue }
            let prefix = [
                "local-competition-award",
                "v1",
                presentation.id.rawValue.uuidString.lowercased(),
            ].joined(separator: ":")
            let completion = Self(
                id: "\(prefix):completion",
                competitionID: presentation.id,
                kind: .completion,
                awardedAt: terminal.completedAt,
                friendDisplayName: LocalCompetitionIdentity.opponentDisplayName
            )
            awardsByID[completion.id] = completion
            if terminal.outcome == .win {
                let victory = Self(
                    id: "\(prefix):victory",
                    competitionID: presentation.id,
                    kind: .victory,
                    awardedAt: terminal.completedAt,
                    friendDisplayName: LocalCompetitionIdentity.opponentDisplayName
                )
                awardsByID[victory.id] = victory
            }
        }
        return awardsByID.values.sorted { $0.id < $1.id }
    }
}

enum LocalCompetitionClientIssue: Error, Equatable, Sendable {
    case storageUnavailable
    case authorizationUnavailable
    case competitionFailures([CompetitionID])
    case commandRejected(CompetitionID)
    case bootstrapIdentityRetired
    case publicationRevisionExhausted
    case unimplemented
}

struct LocalCompetitionDashboard: Equatable, Sendable {
    let competitions: [LocalCompetitionPresentation]
    let awards: [LocalCompetitionAward]
    let issues: [LocalCompetitionClientIssue]
    let hiddenTerminalCompetitionCount: Int
}

struct LocalCompetitionPublication: Equatable, Sendable {
    let publicationRevision: UInt64
    let dashboard: LocalCompetitionDashboard
    let evaluatedAt: Date
    let timeZoneIdentifier: String

    init(
        publicationRevision: UInt64,
        dashboard: LocalCompetitionDashboard,
        evaluatedAt: Date = .distantPast,
        timeZoneIdentifier: String = "UTC"
    ) {
        self.publicationRevision = publicationRevision
        self.dashboard = dashboard
        self.evaluatedAt = evaluatedAt
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

// MARK: - Synchronous publication registration

final class LocalCompetitionPublicationHub: @unchecked Sendable {
    private struct State {
        var continuations: [
            UUID: AsyncStream<LocalCompetitionPublication>.Continuation
        ] = [:]
        var latest: LocalCompetitionPublication?
        var isFinished = false
    }

    // Delivery stays inside this recursive lock so accepted publications,
    // initial replay, and finish are observed in the same total order as the
    // protected revision state. Recursion keeps an immediately terminated
    // continuation's cleanup callback safe.
    private let lock = NSRecursiveLock()
    private var state = State()

    var subscriberCount: Int {
        lock.withLock { state.continuations.count }
    }

    func stream() -> AsyncStream<LocalCompetitionPublication> {
        let token = UUID()
        return AsyncStream { continuation in
            lock.withLock {
                continuation.onTermination = { [weak self] _ in
                    self?.remove(token)
                }
                if !state.isFinished {
                    state.continuations[token] = continuation
                }
                if let latest = state.latest {
                    continuation.yield(latest)
                }
                if state.isFinished {
                    continuation.finish()
                }
            }
        }
    }

    func publish(_ publication: LocalCompetitionPublication) {
        lock.withLock {
            guard !state.isFinished,
                  publication.publicationRevision
                    > (state.latest?.publicationRevision ?? 0)
            else {
                return
            }
            state.latest = publication
            for continuation in state.continuations.values {
                continuation.yield(publication)
            }
        }
    }

    func finish() {
        lock.withLock {
            guard !state.isFinished else { return }
            state.isFinished = true
            let continuations = Array(state.continuations.values)
            state.continuations.removeAll()
            for continuation in continuations {
                continuation.finish()
            }
        }
    }

    private func remove(_ token: UUID) {
        lock.withLock {
            state.continuations[token] = nil
        }
    }
}

// MARK: - Dependency client

enum LocalCompetitionStoreAvailability: Sendable {
    case available(any CompetitionEventStore)
    case unavailable
}

struct LocalCompetitionClient: Sendable {
    var start: @Sendable () -> AsyncStream<LocalCompetitionPublication>
    var updates: @Sendable () -> AsyncStream<LocalCompetitionPublication>
    var reconcileAll: @Sendable (
        ActivityRefreshTrigger
    ) async -> LocalCompetitionPublication
    var accept: @Sendable (CompetitionID) async -> LocalCompetitionPublication
    var decline: @Sendable (CompetitionID) async -> LocalCompetitionPublication
    var archive: @Sendable (CompetitionID) async -> LocalCompetitionPublication
    var rematch: @Sendable (CompetitionID) async -> LocalCompetitionPublication
    var reinvite: @Sendable () async -> LocalCompetitionPublication
    var delete: @Sendable (CompetitionID) async -> LocalCompetitionPublication
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
        start: @escaping @Sendable () -> AsyncStream<LocalCompetitionPublication>,
        updates: @escaping @Sendable () -> AsyncStream<LocalCompetitionPublication>,
        reconcileAll: @escaping @Sendable (
            ActivityRefreshTrigger
        ) async -> LocalCompetitionPublication,
        accept: @escaping @Sendable (
            CompetitionID
        ) async -> LocalCompetitionPublication,
        decline: @escaping @Sendable (
            CompetitionID
        ) async -> LocalCompetitionPublication,
        archive: @escaping @Sendable (
            CompetitionID
        ) async -> LocalCompetitionPublication,
        rematch: @escaping @Sendable (
            CompetitionID
        ) async -> LocalCompetitionPublication,
        reinvite: @escaping @Sendable () async -> LocalCompetitionPublication,
        delete: @escaping @Sendable (
            CompetitionID
        ) async -> LocalCompetitionPublication = { _ in .inert },
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

    static func make(
        environment: CompetitionEnvironmentClient,
        storeAvailability: LocalCompetitionStoreAvailability,
        configuration: LocalCompetitionRuntimeConfiguration = .live,
        bootstrapDirection: InvitationDirection = .outgoing,
        opponentRequest: @escaping @Sendable (CompetitionID) ->
            OpponentPlanGenerationRequest = { id in
                OpponentPlanGenerationRequest(
                    seed: LocalCompetitionIdentity.opponentSeed(for: id),
                    generatorVersion: .v1,
                    difficulty: LocalCompetitionIdentity.opponentDifficulty
                )
            },
        idGenerator: @escaping @Sendable (CompetitionID) -> CompetitionID = {
            LocalCompetitionIdentity.rematchID(for: $0)
        },
        notificationCoordinatorFactory: @escaping @Sendable (
            LocalCompetitionRuntime?
        ) -> CompetitionNotificationCoordinatorClient = { _ in .noop },
        notificationPreferences: CompetitionNotificationPreferencesClient =
            .constant(mutedOpponentIdentities: []),
        notificationClient: CompetitionNotificationClient? = nil,
        initialPublicationRevision: UInt64 = 0
    ) -> Self {
        let hub = LocalCompetitionPublicationHub()
        let runtime: LocalCompetitionRuntime?
        switch storeAvailability {
        case let .available(store):
            runtime = LocalCompetitionRuntime(
                environment: environment,
                store: store,
                configuration: configuration
            )
        case .unavailable:
            runtime = nil
        }
        let notificationCoordinator = notificationCoordinatorFactory(runtime)
        let coordinator = LocalCompetitionCoordinator(
            environment: environment,
            runtime: runtime,
            configuration: configuration,
            hub: hub,
            notificationCoordinator: notificationCoordinator,
            bootstrapDirection: bootstrapDirection,
            opponentRequest: opponentRequest,
            idGenerator: idGenerator,
            initialPublicationRevision: initialPublicationRevision
        )
        return Self(
            start: {
                let stream = hub.stream()
                Task { await coordinator.start() }
                return stream
            },
            updates: { hub.stream() },
            reconcileAll: { trigger in
                await coordinator.reconcileAll(trigger: trigger)
            },
            accept: { id in await coordinator.accept(id) },
            decline: { id in await coordinator.decline(id) },
            archive: { id in await coordinator.archive(id) },
            rematch: { id in await coordinator.rematch(id) },
            reinvite: { await coordinator.reinvite() },
            delete: { id in await coordinator.delete(id) },
            reconcileNotifications: {
                await coordinator.reconcileNotifications()
            },
            loadMutedOpponentIdentities: {
                try await notificationPreferences.mutedOpponentIdentities()
            },
            setNotificationMuted: { identity, isMuted in
                try await notificationPreferences.setMuted(identity, isMuted)
                await coordinator.reconcileNotifications()
            },
            loadNotificationAuthorizationState: {
                guard let notificationClient else { return nil }
                return await notificationClient.authorizationState()
            },
            requestNotificationAuthorization: {
                guard let notificationClient else { return .denied }
                do {
                    _ = try await notificationClient.requestAuthorization()
                } catch {
                    return await notificationClient.authorizationState()
                }
                let state = await notificationClient.authorizationState()
                await coordinator.reconcileNotifications()
                return state
            },
            waitUntil: { date in try await environment.wait(until: date) },
            stop: { await coordinator.stop() }
        )
    }

    static func storageUnavailable() -> Self {
        closed(issue: .storageUnavailable)
    }

    private static func closed(issue: LocalCompetitionClientIssue) -> Self {
        let hub = LocalCompetitionPublicationHub()
        let publication = LocalCompetitionPublication(
            publicationRevision: 1,
            dashboard: LocalCompetitionDashboard(
                competitions: [],
                awards: [],
                issues: [issue],
                hiddenTerminalCompetitionCount: 0
            )
        )
        let publishOnce = LocalCompetitionPublishOnce(
            hub: hub,
            publication: publication
        )
        return Self(
            start: {
                let stream = hub.stream()
                publishOnce.publish()
                return stream
            },
            updates: { hub.stream() },
            reconcileAll: { _ in publication },
            accept: { _ in publication },
            decline: { _ in publication },
            archive: { _ in publication },
            rematch: { _ in publication },
            reinvite: { publication },
            delete: { _ in publication },
            reconcileNotifications: {},
            loadMutedOpponentIdentities: { [] },
            setNotificationMuted: { _, _ in },
            loadNotificationAuthorizationState: { nil },
            requestNotificationAuthorization: { .denied },
            waitUntil: { _ in },
            stop: { hub.finish() }
        )
    }
}

private extension LocalCompetitionPublication {
    static let inert = LocalCompetitionPublication(
        publicationRevision: 0,
        dashboard: LocalCompetitionDashboard(
            competitions: [],
            awards: [],
            issues: [],
            hiddenTerminalCompetitionCount: 0
        )
    )
}

private final class LocalCompetitionPublishOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var didPublish = false
    private let hub: LocalCompetitionPublicationHub
    private let publication: LocalCompetitionPublication

    init(
        hub: LocalCompetitionPublicationHub,
        publication: LocalCompetitionPublication
    ) {
        self.hub = hub
        self.publication = publication
    }

    func publish() {
        let shouldPublish = lock.withLock { () -> Bool in
            guard !didPublish else { return false }
            didPublish = true
            return true
        }
        if shouldPublish { hub.publish(publication) }
    }
}

extension LocalCompetitionClient: TestDependencyKey {
    static let testValue = closed(issue: .unimplemented)
    static let previewValue = closed(issue: .unimplemented)
}

extension LocalCompetitionClient: DependencyKey {
    static let liveValue: LocalCompetitionClient = {
        let storeResult = Result { try JSONCompetitionEventStore.live() }
        let availability: LocalCompetitionStoreAvailability
        switch storeResult {
        case let .success(store):
            availability = .available(store)
        case .failure:
            availability = .unavailable
        }
        let preferences: CompetitionNotificationPreferencesClient
        if let applicationSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            preferences = .live(
                fileURL: applicationSupport
                    .appendingPathComponent("HealthComp", isDirectory: true)
                    .appendingPathComponent(
                        "NotificationPreferences",
                        isDirectory: true
                    )
                    .appendingPathComponent("v1", isDirectory: true)
                    .appendingPathComponent("preferences.json")
            )
        } else {
            preferences = .unavailable
        }
        let notifications = CompetitionNotificationClient.liveValue
        return make(
            environment: .production(),
            storeAvailability: availability,
            configuration: .live,
            notificationCoordinatorFactory: { runtime in
                .live(
                    runtime: runtime,
                    planner: CompetitionNotificationPlanner(policy: .liveV1),
                    notifications: notifications,
                    preferences: preferences
                )
            },
            notificationPreferences: preferences,
            notificationClient: notifications
        )
    }()
}

extension DependencyValues {
    var localCompetitionClient: LocalCompetitionClient {
        get { self[LocalCompetitionClient.self] }
        set { self[LocalCompetitionClient.self] = newValue }
    }
}

// MARK: - Serialized coordinator

private actor LocalCompetitionCoordinator {
    private let environment: CompetitionEnvironmentClient
    private let runtime: LocalCompetitionRuntime?
    private let configuration: LocalCompetitionRuntimeConfiguration
    private let hub: LocalCompetitionPublicationHub
    private let notificationCoordinator: CompetitionNotificationCoordinatorClient
    private let bootstrapDirection: InvitationDirection
    private let opponentRequest: @Sendable (CompetitionID) ->
        OpponentPlanGenerationRequest
    private let idGenerator: @Sendable (CompetitionID) -> CompetitionID
    private var publicationRevision: UInt64
    private var latestPublication: LocalCompetitionPublication?
    private var signalTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var hasStarted = false
    private var isStopped = false
    private var operationIsInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        environment: CompetitionEnvironmentClient,
        runtime: LocalCompetitionRuntime?,
        configuration: LocalCompetitionRuntimeConfiguration,
        hub: LocalCompetitionPublicationHub,
        notificationCoordinator: CompetitionNotificationCoordinatorClient,
        bootstrapDirection: InvitationDirection,
        opponentRequest: @escaping @Sendable (CompetitionID) ->
            OpponentPlanGenerationRequest,
        idGenerator: @escaping @Sendable (CompetitionID) -> CompetitionID,
        initialPublicationRevision: UInt64
    ) {
        self.environment = environment
        self.runtime = runtime
        self.configuration = configuration
        self.hub = hub
        self.notificationCoordinator = notificationCoordinator
        self.bootstrapDirection = bootstrapDirection
        self.opponentRequest = opponentRequest
        self.idGenerator = idGenerator
        self.publicationRevision = initialPublicationRevision
    }

    func start() async {
        await withOperationGate {
            guard !hasStarted, !isStopped else { return }
            hasStarted = true
            await startSignalPumpBeforeBootstrap()

            var issues: [LocalCompetitionClientIssue] = []
            do {
                try await environment.requestHealthAuthorization()
            } catch {
                issues.append(.authorizationUnavailable)
            }

            guard let runtime else {
                issues.append(.storageUnavailable)
                _ = await publish(journals: [], issues: issues)
                return
            }

            let initial = await runtime.loadAll()
            issues.append(contentsOf: Self.issues(from: initial))
            if initial.enumerationFailure == nil,
               initial.outcomes.isEmpty {
                do {
                    let context = await environment.context()
                    let genesis = try CompetitionGenesis(
                        competitionID: LocalCompetitionIdentity
                            .bootstrapCompetitionID,
                        direction: bootstrapDirection,
                        createdAt: context.instant.wallDate,
                        expiresAt: context.instant.wallDate.addingTimeInterval(
                            48 * 60 * 60
                        ),
                        scoringPolicy: .healthKitCompatibility,
                        downwardRevisionPolicy: .maximumObserved
                    )
                    _ = try await runtime.create(genesis)
                } catch CompetitionEventStoreError.identityAlreadyExists {
                    // Another process won the deterministic bootstrap race.
                } catch CompetitionEventStoreError.identityWasDeleted {
                    issues.append(.bootstrapIdentityRetired)
                } catch {
                    issues.append(.storageUnavailable)
                }
            }

            let refreshed = await runtime.refreshAll(trigger: .launch)
            issues.append(contentsOf: Self.issues(from: refreshed))
            _ = await publishFromStore(
                additionalIssues: issues,
                freshEvaluationCompetitionIDs:
                    Self.successfullyEvaluatedIDs(from: refreshed)
            )
        }
    }

    func reconcileAll(
        trigger: ActivityRefreshTrigger
    ) async -> LocalCompetitionPublication {
        await withOperationGate {
            guard !isStopped else { return stoppedResponse() }
            guard let runtime else {
                return await publish(
                    journals: [],
                    issues: [.storageUnavailable]
                )
            }
            let outcome = await runtime.reconcileAll(trigger: trigger)
            return await publishFromStore(
                additionalIssues: Self.issues(from: outcome),
                freshEvaluationCompetitionIDs:
                    Self.successfullyEvaluatedIDs(from: outcome)
            )
        }
    }

    func accept(_ id: CompetitionID) async -> LocalCompetitionPublication {
        await command(id: id) { [opponentRequest] runtime in
            _ = try await runtime.accept(
                competitionID: id,
                opponent: opponentRequest(id)
            )
        }
    }

    func decline(_ id: CompetitionID) async -> LocalCompetitionPublication {
        await command(id: id) { runtime in
            _ = try await runtime.decline(competitionID: id)
        }
    }

    func archive(_ id: CompetitionID) async -> LocalCompetitionPublication {
        await command(id: id) { runtime in
            _ = try await runtime.archive(competitionID: id)
        }
    }

    func rematch(_ id: CompetitionID) async -> LocalCompetitionPublication {
        await command(id: id) { [idGenerator, environment] runtime in
            let context = await environment.context()
            _ = try await runtime.createRematch(
                from: id,
                newID: idGenerator(id),
                expiresAt: context.instant.wallDate.addingTimeInterval(
                    48 * 60 * 60
                )
            )
        }
    }

    func reinvite() async -> LocalCompetitionPublication {
        await withOperationGate {
            guard !isStopped else { return stoppedResponse() }
            guard let runtime else {
                return await publish(
                    journals: [],
                    issues: [.storageUnavailable]
                )
            }
            let loaded = await runtime.loadAll()
            var issues = Self.issues(from: loaded)
            guard let source = Self.latestHiddenInvitation(
                in: loaded.successfulJournals
            ) else {
                issues.append(
                    .commandRejected(
                        LocalCompetitionIdentity.bootstrapCompetitionID
                    )
                )
                return await publishFromStore(additionalIssues: issues)
            }
            do {
                let context = await environment.context()
                _ = try await runtime.createReinvite(
                    from: source.projection.competition.id,
                    newID: idGenerator(source.projection.competition.id),
                    expiresAt: context.instant.wallDate.addingTimeInterval(
                        48 * 60 * 60
                    )
                )
            } catch {
                issues.append(
                    .commandRejected(source.projection.competition.id)
                )
            }
            return await publishFromStore(additionalIssues: issues)
        }
    }

    func delete(_ id: CompetitionID) async -> LocalCompetitionPublication {
        await withOperationGate {
            guard !isStopped else { return stoppedResponse() }
            guard let runtime else {
                return await publish(
                    journals: [],
                    issues: [.storageUnavailable]
                )
            }
            await notificationCoordinator.cancelAll(id)
            var issues: [LocalCompetitionClientIssue] = []
            do {
                try await runtime.delete(competitionID: id)
            } catch {
                issues.append(.commandRejected(id))
            }
            return await publishFromStore(additionalIssues: issues)
        }
    }

    func reconcileNotifications() async {
        guard !isStopped else { return }
        await notificationCoordinator.reconcileLatest()
    }

    func stop() async {
        await withOperationGate {
            guard !isStopped else { return }
            isStopped = true
            signalTask?.cancel()
            signalTask = nil
            wakeTask?.cancel()
            wakeTask = nil
            await environment.synchronizeSummarySubscriptions(to: [])
            hub.finish()
        }
    }

    private func command(
        id: CompetitionID,
        operation: @escaping @Sendable (LocalCompetitionRuntime) async throws -> Void
    ) async -> LocalCompetitionPublication {
        await withOperationGate {
            guard !isStopped else { return stoppedResponse() }
            guard let runtime else {
                return await publish(
                    journals: [],
                    issues: [.storageUnavailable]
                )
            }
            var issues: [LocalCompetitionClientIssue] = []
            do {
                try await operation(runtime)
            } catch {
                issues.append(.commandRejected(id))
            }
            return await publishFromStore(additionalIssues: issues)
        }
    }

    private func stoppedResponse() -> LocalCompetitionPublication {
        latestPublication ?? LocalCompetitionPublication(
            publicationRevision: publicationRevision,
            dashboard: LocalCompetitionDashboard(
                competitions: [],
                awards: [],
                issues: [],
                hiddenTerminalCompetitionCount: 0
            )
        )
    }

    private func startSignalPumpBeforeBootstrap() async {
        guard signalTask == nil else { return }
        let signals = await environment.signals()
        signalTask = Task { [weak self] in
            for await signal in signals {
                guard !Task.isCancelled else { break }
                await self?.consume(signal)
            }
        }
    }

    private func consume(_ signal: EnvironmentSignal) async {
        await withOperationGate {
            guard !isStopped else { return }
            guard let runtime else {
                await environment.completeSignal(signal.id)
                _ = await publish(
                    journals: [],
                    issues: [.storageUnavailable]
                )
                return
            }
            let outcome = await runtime.handleAll(signal)
            _ = await publishFromStore(
                additionalIssues: Self.issues(from: outcome),
                freshEvaluationCompetitionIDs:
                    Self.successfullyEvaluatedIDs(from: outcome)
            )
        }
    }

    private func wakeFired() async {
        await withOperationGate {
            guard !isStopped, let runtime else { return }
            let outcome = await runtime.reconcileAll(
                trigger: .reconciliationProbe
            )
            _ = await publishFromStore(
                additionalIssues: Self.issues(from: outcome),
                freshEvaluationCompetitionIDs:
                    Self.successfullyEvaluatedIDs(from: outcome)
            )
        }
    }

    private func publishFromStore(
        additionalIssues: [LocalCompetitionClientIssue],
        freshEvaluationCompetitionIDs: Set<CompetitionID> = []
    ) async -> LocalCompetitionPublication {
        guard let runtime else {
            return await publish(
                journals: [],
                issues: additionalIssues + [.storageUnavailable]
            )
        }
        let loaded = await runtime.loadAll()
        return await publish(
            journals: loaded.successfulJournals,
            issues: additionalIssues + Self.issues(from: loaded),
            knownCompetitionIDs: Self.knownCompetitionIDs(from: loaded),
            freshEvaluationCompetitionIDs: freshEvaluationCompetitionIDs
        )
    }

    private func publish(
        journals: [LoadedCompetitionJournal],
        issues: [LocalCompetitionClientIssue],
        knownCompetitionIDs: Set<CompetitionID>? = nil,
        freshEvaluationCompetitionIDs: Set<CompetitionID> = []
    ) async -> LocalCompetitionPublication {
        guard publicationRevision < UInt64.max else {
            hub.finish()
            return latestPublication ?? LocalCompetitionPublication(
                publicationRevision: UInt64.max,
                dashboard: LocalCompetitionDashboard(
                    competitions: [],
                    awards: [],
                    issues: [.publicationRevisionExhausted],
                    hiddenTerminalCompetitionCount: 0
                )
            )
        }

        let desired = await runtime?.desiredActivityWindows(in: journals) ?? []
        await environment.synchronizeSummarySubscriptions(to: desired)
        let context = await environment.context()
        var publicationIssues = Self.deduplicated(issues)
        publicationRevision += 1
        let exhaustsRevisionSpace = publicationRevision == UInt64.max
        if exhaustsRevisionSpace {
            publicationIssues.append(.publicationRevisionExhausted)
        }
        let dashboard = LocalCompetitionProjector.dashboard(
            journals: journals,
            context: context,
            configuration: configuration,
            issues: Self.deduplicated(publicationIssues)
        )
        let publication = LocalCompetitionPublication(
            publicationRevision: publicationRevision,
            dashboard: dashboard,
            evaluatedAt: context.instant.wallDate,
            timeZoneIdentifier: context.timeZoneIdentifier
        )
        latestPublication = publication
        hub.publish(publication)
        let notificationSnapshot = LocalCompetitionProjector
            .notificationSnapshot(
                publication: publication,
                journals: journals,
                context: context,
                configuration: configuration,
                knownCompetitionIDs: knownCompetitionIDs,
                freshEvaluationCompetitionIDs:
                    freshEvaluationCompetitionIDs
            )
        Task { [notificationCoordinator] in
            await notificationCoordinator.submit(notificationSnapshot)
        }
        if exhaustsRevisionSpace {
            hub.finish()
        } else {
            await scheduleNextWake(journals: journals, context: context)
        }
        return publication
    }

    private func scheduleNextWake(
        journals: [LoadedCompetitionJournal],
        context: CompetitionEnvironmentContext
    ) async {
        wakeTask?.cancel()
        wakeTask = nil
        guard !isStopped,
              let wake = await runtime?.nextWake(
                  in: journals,
                  context: context
              )
        else {
            return
        }
        wakeTask = Task { [weak self, environment] in
            do {
                try await environment.wait(until: wake)
                try Task.checkCancellation()
                await self?.wakeFired()
            } catch {
                // Cancellation and sealed-environment failure do not mutate.
            }
        }
    }

    private func withOperationGate<T>(
        _ operation: () async -> T
    ) async -> T {
        await acquireOperationGate()
        let result = await operation()
        releaseOperationGate()
        return result
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

    private static func issues(
        from outcome: LocalCompetitionAggregateOutcome
    ) -> [LocalCompetitionClientIssue] {
        var result: [LocalCompetitionClientIssue] = []
        if outcome.enumerationFailure != nil {
            result.append(.storageUnavailable)
        }
        let failedIDs = outcome.failures.map(\.competitionID).sorted {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }
        if !failedIDs.isEmpty {
            result.append(.competitionFailures(failedIDs))
        }
        return result
    }

    private static func knownCompetitionIDs(
        from outcome: LocalCompetitionAggregateOutcome
    ) -> Set<CompetitionID>? {
        guard outcome.enumerationFailure == nil else { return nil }
        return Set(outcome.outcomes.map { item in
            switch item {
            case let .success(loaded):
                loaded.projection.competition.id
            case let .failure(failure):
                failure.competitionID
            }
        })
    }

    private static func successfullyEvaluatedIDs(
        from outcome: LocalCompetitionAggregateOutcome
    ) -> Set<CompetitionID> {
        Set(outcome.successfulJournals.compactMap { loaded in
            guard case .completed = loaded.projection.activityRefresh
                .latestAttempt?.readStatus else {
                return nil
            }
            return loaded.projection.competition.id
        })
    }

    private static func latestHiddenInvitation(
        in journals: [LoadedCompetitionJournal]
    ) -> LoadedCompetitionJournal? {
        journals.compactMap { journal -> (LoadedCompetitionJournal, Date)? in
            switch journal.projection.competition.lifecycle {
            case let .declined(at), let .expired(at):
                return (journal, at)
            default:
                return nil
            }
        }.max { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            let lhsCreated = lhs.0.journal.genesis.createdAt
            let rhsCreated = rhs.0.journal.genesis.createdAt
            if lhsCreated != rhsCreated { return lhsCreated < rhsCreated }
            return lhs.0.projection.competition.id.rawValue.uuidString
                < rhs.0.projection.competition.id.rawValue.uuidString
        }?.0
    }

    private static func deduplicated(
        _ issues: [LocalCompetitionClientIssue]
    ) -> [LocalCompetitionClientIssue] {
        var result: [LocalCompetitionClientIssue] = []
        for issue in issues where !result.contains(issue) {
            result.append(issue)
        }
        return result
    }
}

// MARK: - Privacy-preserving projection

enum LocalCompetitionProjector {
    static func dashboard(
        journals: [LoadedCompetitionJournal],
        context: CompetitionEnvironmentContext,
        configuration: LocalCompetitionRuntimeConfiguration,
        issues: [LocalCompetitionClientIssue]
    ) -> LocalCompetitionDashboard {
        let all = journals.map {
            presentation(
                from: $0,
                context: context,
                configuration: configuration
            )
        }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        let visible = all.filter { presentation in
            switch presentation.lifecycle {
            case .declined, .expired:
                return false
            default:
                return true
            }
        }
        return LocalCompetitionDashboard(
            competitions: visible,
            awards: LocalCompetitionAward.fold(completed: visible),
            issues: issues,
            hiddenTerminalCompetitionCount: all.count - visible.count
        )
    }

    static func notificationSnapshot(
        publication: LocalCompetitionPublication,
        journals: [LoadedCompetitionJournal],
        context: CompetitionEnvironmentContext,
        configuration: LocalCompetitionRuntimeConfiguration,
        knownCompetitionIDs: Set<CompetitionID>?,
        freshEvaluationCompetitionIDs: Set<CompetitionID>
    ) -> CompetitionNotificationPlanningSnapshot {
        let competitions = journals.map { loaded in
            notificationCompetition(
                from: loaded,
                context: context,
                configuration: configuration,
                isFreshEvaluation: freshEvaluationCompetitionIDs.contains(
                    loaded.projection.competition.id
                )
            )
        }.sorted { lhs, rhs in
            lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
        }
        return CompetitionNotificationPlanningSnapshot(
            publicationRevision: publication.publicationRevision,
            evaluatedAt: context.instant.wallDate,
            timeZoneIdentifier: context.timeZoneIdentifier,
            competitions: competitions,
            knownCompetitionIDs: knownCompetitionIDs
        )
    }

    static func notificationCompetition(
        from loaded: LoadedCompetitionJournal,
        context: CompetitionEnvironmentContext,
        configuration: LocalCompetitionRuntimeConfiguration,
        isFreshEvaluation: Bool
    ) -> CompetitionNotificationCompetitionSnapshot {
        let projected = presentation(
            from: loaded,
            context: context,
            configuration: configuration
        )
        let latestAttempt = loaded.projection.activityRefresh.latestAttempt
        let latestRefresh: CompetitionNotificationRefreshState
        switch latestAttempt?.readStatus {
        case .completed:
            latestRefresh = .completed
        case .failed:
            latestRefresh = .failed
        case nil:
            latestRefresh = .none
        }
        let freshness: CompetitionNotificationEvaluationFreshness
        if isFreshEvaluation,
           let latestAttempt,
           case .completed = latestAttempt.readStatus {
            freshness = .freshCompletedRefresh(
                attemptID: latestAttempt.attemptID,
                readAt: latestAttempt.readAt
            )
        } else {
            freshness = .notFresh
        }
        return CompetitionNotificationCompetitionSnapshot(
            id: projected.id,
            opponentIdentity: projected.opponentIdentity,
            opponentDisplayName: projected.opponentDisplayName,
            lifecycle: notificationLifecycle(projected.lifecycle),
            schedule: loaded.projection.competition.schedule,
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
            latestRefresh: latestRefresh,
            evaluationFreshness: freshness,
            terminalResult: projected.terminalResult.map {
                CompetitionNotificationTerminalSnapshot(
                    ownerPoints: $0.userPoints,
                    opponentPoints: $0.opponentPoints,
                    outcome: $0.outcome
                )
            },
            emissionHistory: loaded.projection.notificationEmissions,
            evaluatedAt: context.instant.wallDate,
            timeZoneIdentifier: context.timeZoneIdentifier
        )
    }

    private static func notificationLifecycle(
        _ lifecycle: LocalCompetitionLifecyclePresentation
    ) -> CompetitionNotificationLifecycle {
        switch lifecycle {
        case let .pending(_, _, expiresAt):
            return .pending(expiresAt: expiresAt)
        case .declined:
            return .declined
        case .expired:
            return .expired
        case .scheduled:
            return .scheduled
        case let .active(dayOrdinal):
            return .active(dayOrdinal: dayOrdinal)
        case .endsToday:
            return .endsToday
        case .tallying:
            return .tallying
        case .completed:
            return .completed
        case .archived:
            return .archived
        }
    }

    private static func presentation(
        from loaded: LoadedCompetitionJournal,
        context: CompetitionEnvironmentContext,
        configuration: LocalCompetitionRuntimeConfiguration
    ) -> LocalCompetitionPresentation {
        let projection = loaded.projection
        let competition = projection.competition
        let terminal = terminalPresentation(for: competition.lifecycle)
        let lifecycle = lifecyclePresentation(competition.lifecycle)
        let plan = competition.opponentPlan
        let acceptedConfiguration = plan.map {
            LocalCompetitionAcceptedPresentation(
                schedule: $0.schedule,
                difficulty: $0.difficulty
            )
        }
        let currentDayOrdinal = currentDayOrdinal(
            schedule: competition.schedule,
            now: context.instant.wallDate
        )
        let days = dayPresentations(
            projection: projection,
            now: context.instant.wallDate,
            terminal: terminal
        )
        let liveOwnerPoints = min(
            ActivityScore.maximumCompetitionPoints,
            projection.scoreLedger.entries.reduce(0) {
                $0 + ($1.acceptedScore?.points ?? 0)
            }
        )
        let liveOpponentPoints = days.reduce(0) {
            $0 + ($1.opponentRevealedPoints ?? 0)
        }
        let latestRefresh = projection.activityRefresh.latestAttempt.map {
            LocalCompetitionRefreshPresentation(
                trigger: $0.trigger,
                attemptedAt: $0.attemptedAt,
                readAt: $0.readAt,
                status: $0.readStatus
            )
        }
        return LocalCompetitionPresentation(
            id: competition.id,
            ownerDisplayName: LocalCompetitionIdentity.ownerDisplayName,
            opponentDisplayName: LocalCompetitionIdentity.opponentDisplayName,
            opponentIdentity: LocalCompetitionIdentity.opponentIdentity,
            lifecycle: lifecycle,
            acceptedConfiguration: acceptedConfiguration,
            userPoints: terminal?.userPoints ?? liveOwnerPoints,
            opponentPoints: terminal?.opponentPoints ?? liveOpponentPoints,
            days: days,
            currentDayOrdinal: currentDayOrdinal,
            lastRefresh: latestRefresh,
            tally: tallyPresentation(
                lifecycle: competition.lifecycle,
                configuration: configuration
            ),
            terminalResult: terminal,
            evaluatedAt: context.instant.wallDate,
            timeZoneIdentifier: context.timeZoneIdentifier,
            lastSuccessfulFullWindowRefreshAt:
                projection.activityRefresh.lastSuccessfulFullWindowRefreshAt
        )
    }

    private static func lifecyclePresentation(
        _ lifecycle: CompetitionLifecycle
    ) -> LocalCompetitionLifecyclePresentation {
        switch lifecycle {
        case let .pendingInvitation(invitation):
            return .pending(
                direction: invitation.direction,
                createdAt: invitation.createdAt,
                expiresAt: invitation.expiresAt
            )
        case let .declined(at): return .declined(at: at)
        case let .expired(at): return .expired(at: at)
        case .scheduled: return .scheduled
        case let .active(day): return .active(dayOrdinal: day.ordinal)
        case .endsToday: return .endsToday
        case let .tallying(tally): return .tallying(startedAt: tally.startedAt)
        case let .completed(completed):
            return .completed(
                outcome: completed.outcome,
                basis: completed.basis,
                completedAt: completed.completedAt
            )
        case let .archived(archived):
            return .archived(
                outcome: archived.completed.outcome,
                basis: archived.completed.basis,
                completedAt: archived.completed.completedAt,
                archivedAt: archived.archivedAt
            )
        }
    }

    private static func terminalPresentation(
        for lifecycle: CompetitionLifecycle
    ) -> LocalCompetitionTerminalPresentation? {
        let completed: CompletedCompetition
        switch lifecycle {
        case let .completed(value): completed = value
        case let .archived(value): completed = value.completed
        default: return nil
        }
        return LocalCompetitionTerminalPresentation(
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
        else {
            return nil
        }
        for (offset, day) in days.enumerated() {
            guard let start = try? schedule.calendar.startOfDay(day),
                  let nextDay = try? schedule.calendar.day(after: day),
                  let end = try? schedule.calendar.startOfDay(nextDay)
            else {
                continue
            }
            if now >= start, now < end { return offset + 1 }
        }
        return nil
    }

    private static func dayPresentations(
        projection: CompetitionReplayProjection,
        now: Date,
        terminal: LocalCompetitionTerminalPresentation?
    ) -> [LocalCompetitionDayPresentation] {
        guard let schedule = projection.competition.schedule,
              let plan = projection.competition.opponentPlan,
              let days = try? schedule.calendar.sevenDayWindow(
                  startingOn: schedule.startDay
              )
        else {
            return []
        }
        let latestByOrdinal = Dictionary(
            uniqueKeysWithValues: (
                projection.activityRefresh.latestAttempt?.days ?? []
            ).map { ($0.ordinal, $0) }
        )
        return days.enumerated().map { offset, day in
            let ordinal = offset + 1
            let start = try? schedule.calendar.startOfDay(day)
            let end = try? schedule.calendar.startOfDay(
                schedule.calendar.day(after: day)
            )
            let isFuture = start.map { now < $0 } ?? true
            let availability: LocalCompetitionOwnerAvailability
            if isFuture {
                availability = .notYetOccurred
            } else if let latest = latestByOrdinal[ordinal]?.availability {
                switch latest {
                case .notYetOccurred: availability = .notYetOccurred
                case .observed: availability = .observed
                case .missing: availability = .missing
                case let .unavailable(reason):
                    availability = .unavailable(reason: reason)
                }
            } else {
                availability = .missing
            }
            let latestSnapshot: ActivitySnapshot?
            if case let .observed(snapshot) =
                latestByOrdinal[ordinal]?.availability {
                latestSnapshot = snapshot
            } else {
                latestSnapshot = nil
            }
            let ledgerEntry = projection.scoreLedger.entry(
                forDayOrdinal: ordinal
            )
            let opponentPoints: Double?
            if terminal != nil {
                opponentPoints = Double(plan.days[offset].finalPoints)
            } else if isFuture {
                opponentPoints = nil
            } else if let start, let end {
                let progress: Int
                if now >= end {
                    progress = 10_000
                } else {
                    let duration = max(1, end.timeIntervalSince(start))
                    let fraction = max(
                        0,
                        min(1, now.timeIntervalSince(start) / duration)
                    )
                    progress = Int((fraction * 10_000).rounded(.down))
                }
                opponentPoints = Double(
                    (try? plan.revealedPoints(
                        dayOrdinal: ordinal,
                        progressBasisPoints: progress
                    )) ?? 0
                )
            } else {
                opponentPoints = nil
            }
            return LocalCompetitionDayPresentation(
                day: day,
                ordinal: ordinal,
                ownerAcceptedPoints: ledgerEntry?.acceptedScore?.points,
                ownerLatestAvailability: availability,
                opponentRevealedPoints: opponentPoints,
                ownerAcceptedSnapshot: ledgerEntry?.acceptedScore?.snapshot,
                ownerLatestSnapshot: latestSnapshot
            )
        }
    }

    private static func tallyPresentation(
        lifecycle: CompetitionLifecycle,
        configuration: LocalCompetitionRuntimeConfiguration
    ) -> LocalCompetitionTallyPresentation? {
        guard case let .tallying(tally) = lifecycle else { return nil }
        let reconciliation = tally.reconciliation
        let attention: LocalCompetitionTallyAttention?
        guard let latest = reconciliation.latestAttempt else {
            attention = .noRead
            return LocalCompetitionTallyPresentation(
                attention: attention,
                consecutiveStableCompleteReads: 0,
                stabilityStart: nil,
                bestAvailableDeadline: tally.startedAt.addingTimeInterval(
                    configuration.bestAvailableGrace
                )
            )
        }
        if latest.completeWindowContent == nil {
            attention = .incomplete(
                missingOrdinals: latest.missingOrdinals,
                unavailableOrdinals: latest.unavailableOrdinals
            )
        } else {
            let unaccepted = Set(1...7).subtracting(
                latest.acceptedScoreOrdinals
            )
            if !unaccepted.isEmpty {
                attention = .unacceptedScores(ordinals: unaccepted)
            } else if !latest.opponentPlanIsFinal {
                attention = .opponentPlanUnavailable
            } else {
                attention = .awaitingStability
            }
        }
        return LocalCompetitionTallyPresentation(
            attention: attention,
            consecutiveStableCompleteReads:
                reconciliation.consecutiveStableCompleteReads,
            stabilityStart: reconciliation.stabilityStart,
            bestAvailableDeadline: tally.startedAt.addingTimeInterval(
                configuration.bestAvailableGrace
            )
        )
    }
}
