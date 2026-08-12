import CompetitionCore
import Dependencies
import Foundation

extension CompetitionClient {
    static func live(provider: SupabaseClientProvider) -> Self {
        remote(
            remoteAPI: SupabaseCompetitionRemoteAPI.live(provider: provider),
            environment: .production()
        )
    }

    static func remote(
        remoteAPI: CompetitionRemoteAPI,
        environment: CompetitionEnvironmentClient
    ) -> Self {
        let router = RemoteCompetitionPublicationRouter()
        let coordinator = RemoteCompetitionClientCoordinator(
            remoteAPI: remoteAPI,
            environment: environment,
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
            archive: { id in await coordinator.unsupported(id) },
            rematch: { id in await coordinator.unsupported(id) },
            reinvite: { await coordinator.unsupported(nil) },
            delete: { id in await coordinator.unsupported(id) },
            waitUntil: { date in try await environment.wait(until: date) },
            stop: { await coordinator.stop() },
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

private actor RemoteCompetitionClientCoordinator {
    private let remoteAPI: CompetitionRemoteAPI
    private let environment: CompetitionEnvironmentClient
    private let router: RemoteCompetitionPublicationRouter

    private var profile: AuthenticatedProfile?
    private var runtime: RemoteCompetitionRuntime?
    private var hub: LocalCompetitionPublicationHub?
    private var publicationRevision: UInt64 = 0
    private var latestPublication: CompetitionPublication?
    private var signalTask: Task<Void, Never>?
    private var hasStarted = false
    private var isStopped = false
    private var runtimeGeneration: UInt64 = 0
    private var operationIsInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        remoteAPI: CompetitionRemoteAPI,
        environment: CompetitionEnvironmentClient,
        router: RemoteCompetitionPublicationRouter
    ) {
        self.remoteAPI = remoteAPI
        self.environment = environment
        self.router = router
    }

    func mount(
        profile: AuthenticatedProfile,
        paths: AuthenticatedProfileStoragePaths
    ) async throws {
        try await withOperationGate {
            guard profile.id == paths.profileID else {
                throw RemoteCompetitionRuntimeFailure.profileMismatch
            }
            await stopRuntime()
            let replacement = LocalCompetitionPublicationHub()
            router.activate(replacement)
            self.profile = profile
            self.hub = replacement
            self.publicationRevision = 0
            self.latestPublication = nil
            self.hasStarted = false
            self.isStopped = false
            self.runtime = RemoteCompetitionRuntime(
                profileID: profile.id,
                store: JSONCompetitionEventStore(
                    rootDirectory: paths.competitionEventsDirectory
                ),
                remoteAPI: remoteAPI,
                environment: environment,
                outboxStore: JSONCompetitionOutboxStore(
                    rootDirectory: paths.outboxDirectory
                ),
                cacheStore: JSONRemoteCompetitionCacheStore(
                    rootDirectory: paths.serverCursorsDirectory
                )
            )
        }
    }

    func start() async {
        await withOperationGate {
            guard !hasStarted, !isStopped else { return }
            hasStarted = true
            startSignals()
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
            issues: issues
        )
    }

    func unsupported(_ id: CompetitionID?) async -> CompetitionPublication {
        await withOperationGate {
            let issue = id.map(CompetitionClientIssue.commandRejected)
                ?? .unimplemented
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
                    hiddenTerminalCompetitionCount: latestPublication
                        .dashboard.hiddenTerminalCompetitionCount
                ),
                evaluatedAt: latestPublication.evaluatedAt,
                timeZoneIdentifier: latestPublication.timeZoneIdentifier
            )
        }
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
        let task = signalTask
        task?.cancel()
        await withOperationGate {
            await stopRuntime()
            profile = nil
            hub = nil
            latestPublication = nil
            publicationRevision = 0
            hasStarted = false
            router.finishCurrent()
        }
        await task?.value
    }

    private func stopRuntime() async {
        runtimeGeneration &+= 1
        signalTask?.cancel()
        signalTask = nil
        await runtime?.stop()
        runtime = nil
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
        issues: [CompetitionClientIssue]
    ) async -> CompetitionPublication {
        let context = await environment.context()
        return publish(
            dashboard: RemoteCompetitionProjector.dashboard(
                materializations: materializations,
                profile: profile,
                context: context,
                issues: issues
            ),
            evaluatedAt: context.instant.wallDate,
            timeZoneIdentifier: context.timeZoneIdentifier
        )
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
                timeZoneIdentifier: timeZoneIdentifier
            )
        }
        publicationRevision += 1
        let publication = CompetitionPublication(
            publicationRevision: publicationRevision,
            dashboard: dashboard,
            evaluatedAt: evaluatedAt,
            timeZoneIdentifier: timeZoneIdentifier
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

private enum RemoteCompetitionProjector {
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

    private static func presentation(
        from materialization: RemoteCompetitionMaterialization,
        profile: AuthenticatedProfile,
        context: CompetitionEnvironmentContext
    ) -> CompetitionPresentation? {
        let projection = materialization.journal.projection
        let competition = projection.competition
        let opponentDescriptor = materialization.descriptor.participants
            .first { $0.profileID != profile.id }
        let opponentName = opponentDescriptor?.profile.displayName
            ?? "Waiting for competitor"
        let opponentID = opponentDescriptor?.profileID
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
            ownerDisplayName: profile.displayName,
            opponentDisplayName: opponentName,
            opponentIdentity: opponentID.map {
                "remote-profile:v1:\($0.uuidString.lowercased())"
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
