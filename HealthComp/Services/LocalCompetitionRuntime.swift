import CompetitionCore
import Foundation

enum LocalCompetitionRuntimeError: Error, Equatable, Sendable {
    case competitionNotFound
    case scheduleChangedDuringRefresh
    case cursorRetryLimitExceeded
}

struct LocalCompetitionRuntimeConfiguration: Equatable, Sendable {
    static let live = Self(
        minimumStabilityNanoseconds: 15 * 60 * 1_000_000_000,
        bestAvailableGrace: 24 * 60 * 60
    )

    static let testing = Self(
        minimumStabilityNanoseconds: 1,
        bestAvailableGrace: 60
    )

    let minimumStabilityNanoseconds: UInt64
    let bestAvailableGrace: TimeInterval
    let maximumCursorRetries: Int

    init(
        minimumStabilityNanoseconds: UInt64,
        bestAvailableGrace: TimeInterval,
        maximumCursorRetries: Int = 4
    ) {
        precondition(bestAvailableGrace.isFinite && bestAvailableGrace >= 0)
        precondition(maximumCursorRetries > 0)
        self.minimumStabilityNanoseconds = minimumStabilityNanoseconds
        self.bestAvailableGrace = bestAvailableGrace
        self.maximumCursorRetries = maximumCursorRetries
    }

    func finalizationPolicy(
        for competition: CompetitionCore.Competition
    ) -> FinalizationPolicy? {
        guard case let .tallying(tallying) = competition.lifecycle else {
            return nil
        }
        return FinalizationPolicy(
            minimumStabilityNanoseconds: minimumStabilityNanoseconds,
            bestAvailableDeadline: tallying.startedAt.addingTimeInterval(
                bestAvailableGrace
            )
        )
    }
}

enum LocalCompetitionRuntimeFailure: Error, Equatable, Sendable {
    case competitionNotFound
    case cursorRetryLimitExceeded
    case scheduleChangedDuringRefresh
    case invalidTransition
    case storageUnavailable
    case invalidConfiguration
}

struct LocalCompetitionRuntimeIDFailure: Equatable, Sendable {
    let competitionID: CompetitionID
    let failure: LocalCompetitionRuntimeFailure
}

enum LocalCompetitionRuntimeIDOutcome: Equatable, Sendable {
    case success(LoadedCompetitionJournal)
    case failure(LocalCompetitionRuntimeIDFailure)
}

struct LocalCompetitionAggregateOutcome: Equatable, Sendable {
    let outcomes: [LocalCompetitionRuntimeIDOutcome]
    let enumerationFailure: LocalCompetitionRuntimeFailure?

    var successfulJournals: [LoadedCompetitionJournal] {
        outcomes.compactMap { outcome in
            guard case let .success(loaded) = outcome else { return nil }
            return loaded
        }
    }

    var failures: [LocalCompetitionRuntimeIDFailure] {
        outcomes.compactMap { outcome in
            guard case let .failure(failure) = outcome else { return nil }
            return failure
        }
    }
}

actor LocalCompetitionRuntime {
    private enum PolicySource {
        case configuration(LocalCompetitionRuntimeConfiguration)
        case fixed(FinalizationPolicy)
    }

    private struct PendingRefreshRequest {
        let competitionID: CompetitionID
        let trigger: ActivityRefreshTrigger
        let continuation: CheckedContinuation<LoadedCompetitionJournal, Error>
    }

    private let environment: CompetitionEnvironmentClient
    private let store: any CompetitionEventStore
    private let engine: CompetitionEngine
    private let policySource: PolicySource
    private let maximumCursorRetries: Int
    private var pendingRefreshRequests: [PendingRefreshRequest] = []
    private var isDrainingRefreshRequests = false
    private var mutationIsInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        environment: CompetitionEnvironmentClient,
        store: any CompetitionEventStore,
        configuration: LocalCompetitionRuntimeConfiguration = .live
    ) {
        self.environment = environment
        self.store = store
        self.engine = CompetitionEngine()
        self.policySource = .configuration(configuration)
        self.maximumCursorRetries = configuration.maximumCursorRetries
    }

    init(
        environment: CompetitionEnvironmentClient,
        store: any CompetitionEventStore,
        finalizationPolicy: FinalizationPolicy,
        maximumCursorRetries: Int = 4
    ) {
        precondition(maximumCursorRetries > 0)
        self.environment = environment
        self.store = store
        self.engine = CompetitionEngine()
        self.policySource = .fixed(finalizationPolicy)
        self.maximumCursorRetries = maximumCursorRetries
    }

    @discardableResult
    func create(
        _ genesis: CompetitionGenesis
    ) async throws -> LoadedCompetitionJournal {
        try await withMutationGate {
            _ = try await store.create(genesis)
            guard let loaded = try await store.load(genesis.competitionID) else {
                throw LocalCompetitionRuntimeError.competitionNotFound
            }
            return loaded
        }
    }

    func load(
        _ competitionID: CompetitionID
    ) async throws -> LoadedCompetitionJournal {
        guard let loaded = try await store.load(competitionID) else {
            throw LocalCompetitionRuntimeError.competitionNotFound
        }
        return loaded
    }

    func commitNotificationDecisions(
        competitionID: CompetitionID,
        replan: @escaping @Sendable (
            _ loaded: LoadedCompetitionJournal
        ) throws -> [CompetitionNotificationDurableDecision]
    ) async throws -> CompetitionNotificationDecisionCommitResult {
        try await withMutationGate {
            for retry in 0..<maximumCursorRetries {
                guard let loaded = try await store.load(competitionID) else {
                    throw LocalCompetitionRuntimeError.competitionNotFound
                }
                let replanned = try replan(loaded)
                guard !replanned.isEmpty else { return .noDecision }

                let recordedIDs = loaded.projection.notificationEmissions
                    .recordedIDs
                var seenIDs: Set<String> = []
                let novel = replanned.filter { decision in
                    let id = decision.record.semanticEventID
                    return seenIDs.insert(id).inserted
                        && !recordedIDs.contains(id)
                }
                guard !novel.isEmpty else { return .duplicate }

                do {
                    let result = try await store.append(
                        novel.map {
                            .notificationEmissionRecorded($0.record)
                        },
                        to: competitionID,
                        expectedCursor: loaded.journal.cursor
                    )
                    guard result.appendedCount > 0 else { return .duplicate }
                    return .appended(novel)
                } catch let error as CompetitionEventStoreError {
                    guard case .cursorConflict = error else { throw error }
                    guard retry + 1 < maximumCursorRetries else {
                        throw LocalCompetitionRuntimeError
                            .cursorRetryLimitExceeded
                    }
                }
            }
            throw LocalCompetitionRuntimeError.cursorRetryLimitExceeded
        }
    }

    func delete(competitionID: CompetitionID) async throws {
        try await withMutationGate {
            for retry in 0..<maximumCursorRetries {
                let loaded: LoadedCompetitionJournal
                do {
                    guard let value = try await store.load(competitionID) else {
                        return
                    }
                    loaded = value
                } catch let error as CompetitionEventStoreError {
                    switch error {
                    case .identityNotFound, .identityWasDeleted:
                        return
                    default:
                        throw error
                    }
                }
                do {
                    try await store.delete(
                        competitionID,
                        expectedCursor: loaded.journal.cursor
                    )
                    return
                } catch let error as CompetitionEventStoreError {
                    switch error {
                    case .identityNotFound, .identityWasDeleted:
                        return
                    case .cursorConflict:
                        guard retry + 1 < maximumCursorRetries else {
                            throw LocalCompetitionRuntimeError
                                .cursorRetryLimitExceeded
                        }
                    default:
                        throw error
                    }
                }
            }
            throw LocalCompetitionRuntimeError.cursorRetryLimitExceeded
        }
    }

    func loadAll() async -> LocalCompetitionAggregateOutcome {
        do {
            let ids = try await store.ids().sorted(by: Self.sortCompetitionIDs)
            var outcomes: [LocalCompetitionRuntimeIDOutcome] = []
            outcomes.reserveCapacity(ids.count)
            for id in ids {
                do {
                    guard let loaded = try await store.load(id) else {
                        outcomes.append(
                            .failure(
                                LocalCompetitionRuntimeIDFailure(
                                    competitionID: id,
                                    failure: .competitionNotFound
                                )
                            )
                        )
                        continue
                    }
                    outcomes.append(.success(loaded))
                } catch {
                    outcomes.append(
                        .failure(
                            LocalCompetitionRuntimeIDFailure(
                                competitionID: id,
                                failure: failure(from: error)
                            )
                        )
                    )
                }
            }
            return LocalCompetitionAggregateOutcome(
                outcomes: outcomes,
                enumerationFailure: nil
            )
        } catch {
            return LocalCompetitionAggregateOutcome(
                outcomes: [],
                enumerationFailure: failure(from: error)
            )
        }
    }

    func refreshAll(
        trigger: ActivityRefreshTrigger
    ) async -> LocalCompetitionAggregateOutcome {
        await withMutationGate {
            await performRefreshAll(trigger: trigger)
        }
    }

    func reconcileAll(
        trigger: ActivityRefreshTrigger
    ) async -> LocalCompetitionAggregateOutcome {
        await refreshAll(trigger: trigger)
    }

    func handleAll(
        _ signal: EnvironmentSignal
    ) async -> LocalCompetitionAggregateOutcome {
        let outcome = await withMutationGate {
            await performRefreshAll(trigger: signal.trigger)
        }
        await environment.completeSignal(signal.id)
        return outcome
    }

    func desiredActivityWindows(
        in journals: [LoadedCompetitionJournal]
    ) -> Set<CompetitionActivityWindow> {
        Set(
            journals.compactMap { loaded in
                guard !loaded.projection.scoreLedger.isFrozen,
                      let schedule = loaded.projection.competition.schedule
                else {
                    return nil
                }
                switch loaded.projection.competition.lifecycle {
                case .scheduled, .active, .endsToday, .tallying:
                    return try? CompetitionActivityWindow(
                        calendar: schedule.calendar,
                        startDay: schedule.startDay
                    )
                case .pendingInvitation, .declined, .expired, .completed,
                     .archived:
                    return nil
                }
            }
        )
    }

    func nextWake(
        in journals: [LoadedCompetitionJournal],
        context: CompetitionEnvironmentContext
    ) -> Date? {
        let now = context.instant.wallDate
        var candidates: [Date] = []
        for loaded in journals {
            let competition = loaded.projection.competition
            switch competition.lifecycle {
            case let .pendingInvitation(invitation):
                if let expiry = invitation.expiresAt, expiry > now {
                    candidates.append(expiry)
                }

            case .scheduled, .active, .endsToday:
                guard let schedule = competition.schedule,
                      let days = try? schedule.calendar.sevenDayWindow(
                          startingOn: schedule.startDay
                      )
                else {
                    continue
                }
                let boundaries = days.compactMap {
                    try? schedule.calendar.startOfDay($0)
                } + [
                    try? schedule.calendar.startOfDay(
                        schedule.calendar.day(after: days[6])
                    ),
                ].compactMap { $0 }
                if let nextBoundary = boundaries.first(where: { $0 > now }) {
                    candidates.append(nextBoundary)
                }

            case let .tallying(tallying):
                guard let policy = finalizationPolicy(for: competition) else {
                    continue
                }
                if policy.bestAvailableDeadline > now {
                    candidates.append(policy.bestAvailableDeadline)
                }
                if let stabilityStart = tallying.reconciliation.stabilityStart,
                   stabilityStart.epochID
                    == context.instant.monotonic.epochID {
                    let target = stabilityStart.nanoseconds
                        .addingReportingOverflow(
                            policy.minimumStabilityNanoseconds
                        )
                    if !target.overflow {
                        let current = context.instant.monotonic.nanoseconds
                        if target.partialValue > current {
                            let remaining = target.partialValue - current
                            candidates.append(
                                now.addingTimeInterval(
                                    TimeInterval(remaining) / 1_000_000_000
                                )
                            )
                        } else if tallying.reconciliation
                            .consecutiveStableCompleteReads < 2,
                            let latest = tallying.reconciliation.latestAttempt,
                            latest.completeWindowContent != nil,
                            latest.acceptedScoreOrdinals == Set(1...7),
                            latest.opponentPlanIsFinal,
                            latest.monotonicInstant.epochID
                                == stabilityStart.epochID {
                            candidates.append(now)
                        }
                    }
                }

            case .declined, .expired, .completed, .archived:
                break
            }
        }
        return candidates.min()
    }

    @discardableResult
    func accept(
        competitionID: CompetitionID,
        opponent request: OpponentPlanGenerationRequest
    ) async throws -> LoadedCompetitionJournal {
        try await withMutationGate {
            let context = await environment.context()
            let loaded = try await load(competitionID)
            let event = try engine.accept(
                loaded.projection.competition,
                at: context.instant.wallDate,
                timeZoneIdentifier: context.timeZoneIdentifier,
                opponent: request
            )
            return try await appendLifecycleEvent(
                event,
                competitionID: competitionID
            )
        }
    }

    @discardableResult
    func decline(
        competitionID: CompetitionID
    ) async throws -> LoadedCompetitionJournal {
        try await withMutationGate {
            let context = await environment.context()
            let loaded = try await load(competitionID)
            let event = try engine.decline(
                loaded.projection.competition,
                at: context.instant.wallDate
            )
            return try await appendLifecycleEvent(
                event,
                competitionID: competitionID
            )
        }
    }

    @discardableResult
    func archive(
        competitionID: CompetitionID
    ) async throws -> LoadedCompetitionJournal {
        try await withMutationGate {
            let context = await environment.context()
            let loaded = try await load(competitionID)
            let event = try engine.archive(
                loaded.projection.competition,
                at: context.instant.wallDate
            )
            return try await appendLifecycleEvent(
                event,
                competitionID: competitionID
            )
        }
    }

    @discardableResult
    func createRematch(
        from sourceID: CompetitionID,
        newID: CompetitionID,
        expiresAt: Date?
    ) async throws -> LoadedCompetitionJournal {
        try await withMutationGate {
            let context = await environment.context()
            let source = try await load(sourceID)
            _ = try engine.rematch(
                from: source.projection.competition,
                newID: newID,
                createdAt: context.instant.wallDate,
                expiresAt: expiresAt
            )
            if let existing = try await store.load(newID) {
                return try validatedRematch(
                    existing,
                    source: source,
                    newID: newID
                )
            }
            let genesis = try CompetitionGenesis(
                competitionID: newID,
                direction: .outgoing,
                createdAt: context.instant.wallDate,
                expiresAt: expiresAt,
                scoringPolicy: source.journal.genesis.scoringPolicy,
                downwardRevisionPolicy: source.journal.genesis
                    .downwardRevisionPolicy
            )
            do {
                _ = try await store.create(genesis)
            } catch CompetitionEventStoreError.identityAlreadyExists {
                guard let existing = try await store.load(newID) else {
                    throw CompetitionEventStoreError.identityAlreadyExists
                }
                return try validatedRematch(
                    existing,
                    source: source,
                    newID: newID
                )
            }
            guard let rematch = try await store.load(newID) else {
                throw LocalCompetitionRuntimeError.competitionNotFound
            }
            return try validatedRematch(
                rematch,
                source: source,
                newID: newID
            )
        }
    }

    /// Creates the one deterministic successor used to recover after a local
    /// invitation was declined or expired. The source journal is immutable;
    /// retries and cross-process races converge on a compatible existing
    /// genesis, while tombstones and mismatched identities fail closed.
    @discardableResult
    func createReinvite(
        from sourceID: CompetitionID,
        newID: CompetitionID,
        expiresAt: Date?
    ) async throws -> LoadedCompetitionJournal {
        try await withMutationGate {
            let context = await environment.context()
            let source = try await load(sourceID)
            let hiddenAt: Date
            switch source.projection.competition.lifecycle {
            case let .declined(at), let .expired(at):
                hiddenAt = at
            default:
                throw CompetitionEngine.EngineError.invalidTransition
            }
            guard newID != sourceID else {
                throw CompetitionEngine.EngineError.rematchMustUseNewIdentity
            }
            if let existing = try await store.load(newID) {
                return try validatedReinvite(
                    existing,
                    source: source,
                    newID: newID,
                    hiddenAt: hiddenAt
                )
            }
            let genesis = try CompetitionGenesis(
                competitionID: newID,
                direction: .outgoing,
                createdAt: context.instant.wallDate,
                expiresAt: expiresAt,
                scoringPolicy: source.journal.genesis.scoringPolicy,
                downwardRevisionPolicy: source.journal.genesis
                    .downwardRevisionPolicy
            )
            do {
                _ = try await store.create(genesis)
            } catch CompetitionEventStoreError.identityAlreadyExists {
                guard let existing = try await store.load(newID) else {
                    throw CompetitionEventStoreError.identityAlreadyExists
                }
                return try validatedReinvite(
                    existing,
                    source: source,
                    newID: newID,
                    hiddenAt: hiddenAt
                )
            }
            guard let reinvite = try await store.load(newID) else {
                throw LocalCompetitionRuntimeError.competitionNotFound
            }
            return try validatedReinvite(
                reinvite,
                source: source,
                newID: newID,
                hiddenAt: hiddenAt
            )
        }
    }

    private func validatedReinvite(
        _ reinvite: LoadedCompetitionJournal,
        source: LoadedCompetitionJournal,
        newID: CompetitionID,
        hiddenAt: Date
    ) throws -> LoadedCompetitionJournal {
        let genesis = reinvite.journal.genesis
        guard genesis.competitionID == newID,
              genesis.direction == .outgoing,
              genesis.createdAt >= hiddenAt,
              genesis.scoringPolicy == source.journal.genesis.scoringPolicy,
              genesis.downwardRevisionPolicy
                == source.journal.genesis.downwardRevisionPolicy,
              reinvite.projection.competition.id == newID,
              Self.hasCompatibleRematchLifecycle(reinvite)
        else {
            throw CompetitionEventStoreError.identityAlreadyExists
        }
        return reinvite
    }

    private func validatedRematch(
        _ rematch: LoadedCompetitionJournal,
        source: LoadedCompetitionJournal,
        newID: CompetitionID
    ) throws -> LoadedCompetitionJournal {
        let genesis = rematch.journal.genesis
        guard genesis.competitionID == newID,
              genesis.direction == .outgoing,
              genesis.scoringPolicy == source.journal.genesis.scoringPolicy,
              genesis.downwardRevisionPolicy
                == source.journal.genesis.downwardRevisionPolicy,
              rematch.projection.competition.id == newID,
              Self.hasCompatibleRematchLifecycle(rematch)
        else {
            throw CompetitionEventStoreError.identityAlreadyExists
        }
        return rematch
    }

    private static func hasCompatibleRematchLifecycle(
        _ rematch: LoadedCompetitionJournal
    ) -> Bool {
        let genesis = rematch.journal.genesis
        switch rematch.projection.competition.lifecycle {
        case let .pendingInvitation(invitation):
            return invitation.direction == genesis.direction
                && invitation.createdAt == genesis.createdAt
                && invitation.expiresAt == genesis.expiresAt
        case .declined, .expired, .scheduled, .active, .endsToday, .tallying,
             .completed, .archived:
            return true
        }
    }

    @discardableResult
    func refresh(
        competitionID: CompetitionID,
        trigger: ActivityRefreshTrigger
    ) async throws -> LoadedCompetitionJournal {
        try await enqueueRefresh(
            competitionID: competitionID,
            trigger: trigger
        )
    }

    @discardableResult
    func handle(
        _ signal: EnvironmentSignal,
        competitionID: CompetitionID
    ) async throws -> LoadedCompetitionJournal {
        guard let loaded = try await handle(
            signal,
            competitionIDs: [competitionID]
        ).first else {
            throw LocalCompetitionRuntimeError.competitionNotFound
        }
        return loaded
    }

    @discardableResult
    func handle(
        _ signal: EnvironmentSignal,
        competitionIDs: [CompetitionID]
    ) async throws -> [LoadedCompetitionJournal] {
        var seen = Set<CompetitionID>()
        let uniqueIDs = competitionIDs.filter { seen.insert($0).inserted }
        var loadedCompetitions: [LoadedCompetitionJournal] = []
        var firstFailure: Error?

        for competitionID in uniqueIDs {
            do {
                loadedCompetitions.append(
                    try await enqueueRefresh(
                        competitionID: competitionID,
                        trigger: signal.trigger
                    )
                )
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if signal.requiresCompletion {
            await environment.completeSignal(signal.id)
        }
        if let firstFailure { throw firstFailure }
        return loadedCompetitions
    }

    private func enqueueRefresh(
        competitionID: CompetitionID,
        trigger: ActivityRefreshTrigger
    ) async throws -> LoadedCompetitionJournal {
        try await withCheckedThrowingContinuation { continuation in
            pendingRefreshRequests.append(
                PendingRefreshRequest(
                    competitionID: competitionID,
                    trigger: trigger,
                    continuation: continuation
                )
            )
            guard !isDrainingRefreshRequests else { return }
            isDrainingRefreshRequests = true
            Task { await self.drainRefreshRequests() }
        }
    }

    private func drainRefreshRequests() async {
        while !pendingRefreshRequests.isEmpty {
            let wave = pendingRefreshRequests
            pendingRefreshRequests.removeAll()
            var remaining = wave
            while let first = remaining.first {
                let batch = remaining.filter {
                    $0.competitionID == first.competitionID
                }
                remaining.removeAll {
                    $0.competitionID == first.competitionID
                }
                await processRefreshBatch(batch)
            }
        }
        isDrainingRefreshRequests = false
    }

    private func processRefreshBatch(
        _ batch: [PendingRefreshRequest]
    ) async {
        guard let first = batch.first else { return }
        do {
            let loaded = try await withMutationGate {
                try await performRefresh(
                    competitionID: first.competitionID,
                    trigger: first.trigger
                )
            }
            for request in batch {
                request.continuation.resume(returning: loaded)
            }
        } catch {
            for request in batch {
                request.continuation.resume(throwing: error)
            }
        }
    }

    private func performRefreshAll(
        trigger: ActivityRefreshTrigger
    ) async -> LocalCompetitionAggregateOutcome {
        let ids: [CompetitionID]
        do {
            ids = try await store.ids().sorted(by: Self.sortCompetitionIDs)
        } catch {
            return LocalCompetitionAggregateOutcome(
                outcomes: [],
                enumerationFailure: failure(from: error)
            )
        }

        var outcomes: [LocalCompetitionRuntimeIDOutcome] = []
        outcomes.reserveCapacity(ids.count)
        for id in ids {
            do {
                outcomes.append(
                    .success(
                        try await performRefresh(
                            competitionID: id,
                            trigger: trigger
                        )
                    )
                )
            } catch {
                outcomes.append(
                    .failure(
                        LocalCompetitionRuntimeIDFailure(
                            competitionID: id,
                            failure: failure(from: error)
                        )
                    )
                )
            }
        }
        return LocalCompetitionAggregateOutcome(
            outcomes: outcomes,
            enumerationFailure: nil
        )
    }

    private func appendLifecycleEvent(
        _ event: CompetitionEvent,
        competitionID: CompetitionID
    ) async throws -> LoadedCompetitionJournal {
        for retry in 0..<maximumCursorRetries {
            let loaded = try await load(competitionID)
            do {
                _ = try await store.append(
                    [.lifecycle(event)],
                    to: competitionID,
                    expectedCursor: loaded.journal.cursor
                )
                return try await load(competitionID)
            } catch let error as CompetitionEventStoreError {
                guard case .cursorConflict = error else { throw error }
                guard retry + 1 < maximumCursorRetries else {
                    throw LocalCompetitionRuntimeError.cursorRetryLimitExceeded
                }
            }
        }
        throw LocalCompetitionRuntimeError.cursorRetryLimitExceeded
    }

    private func performRefresh(
        competitionID: CompetitionID,
        trigger: ActivityRefreshTrigger
    ) async throws -> LoadedCompetitionJournal {
        let initial = try await load(competitionID)
        let attemptedInstant = await environment.instant()
        let preparedRead = try await prepareRead(
            loaded: initial,
            attemptedInstant: attemptedInstant
        )
        let initialAttemptOrdinal = initial.projection.activityRefresh
            .nextAttemptOrdinal

        for retry in 0..<maximumCursorRetries {
            let loaded = try await load(competitionID)
            if loaded.projection.activityRefresh.nextAttemptOrdinal
                != initialAttemptOrdinal {
                guard let preparedRead else { return loaded }
                // Append order is not read recency: a slower writer can commit
                // an older HealthKit result first. Suppress only when that
                // winning read is at least as recent as our prepared evidence.
                if latestRefreshIsAtLeastAsRecent(
                    in: loaded,
                    as: preparedRead
                ) {
                    return loaded
                }
            }
            let attemptID = mintAttemptID(
                competitionID: competitionID,
                initialAttemptOrdinal: loaded.projection.activityRefresh
                    .nextAttemptOrdinal
            )
            let events = try buildBatch(
                loaded: loaded,
                trigger: trigger,
                attemptID: attemptID,
                attemptedInstant: attemptedInstant,
                preparedRead: preparedRead
            )
            guard !events.isEmpty else { return loaded }
            do {
                _ = try await store.append(
                    events,
                    to: competitionID,
                    expectedCursor: loaded.journal.cursor
                )
                return try await load(competitionID)
            } catch let error as CompetitionEventStoreError {
                guard case .cursorConflict = error else { throw error }
                guard retry + 1 < maximumCursorRetries else {
                    throw LocalCompetitionRuntimeError
                        .cursorRetryLimitExceeded
                }
            }
        }
        throw LocalCompetitionRuntimeError.cursorRetryLimitExceeded
    }

    private func latestRefreshIsAtLeastAsRecent(
        in loaded: LoadedCompetitionJournal,
        as preparedRead: PreparedRead
    ) -> Bool {
        guard let latest = loaded.projection.activityRefresh.latestAttempt
        else {
            return false
        }
        if preparedRead.failureReason == nil,
           case .failed = latest.readStatus {
            // A query failure has no source-day evidence. Compare against the
            // newest durable completed read hidden behind that failure: only
            // completed evidence at least as new may suppress this read.
            return loaded.projection.activityRefresh
                .lastSuccessfulFullWindowRefreshAt
                .map { $0 >= preparedRead.readInstant.wallDate }
                ?? false
        }
        let latestMonotonic = latest.monotonicInstant
        let preparedMonotonic = preparedRead.readInstant.monotonic
        guard latestMonotonic.epochID == preparedMonotonic.epochID else {
            // A reboot/clock-uncertainty boundary makes uptime incomparable;
            // wall time is the only persisted ordering evidence available.
            return latest.readAt >= preparedRead.readInstant.wallDate
        }
        if latestMonotonic.nanoseconds != preparedMonotonic.nanoseconds {
            return latestMonotonic.nanoseconds
                > preparedMonotonic.nanoseconds
        }
        return latest.readAt >= preparedRead.readInstant.wallDate
    }

    private struct PreparedRead: Sendable {
        let window: CompetitionActivityWindow
        let result: ActivityWindowRead?
        let failureReason: ActivityQueryFailureReason?
        let readInstant: EnvironmentInstant
    }

    private func prepareRead(
        loaded: LoadedCompetitionJournal,
        attemptedInstant: EnvironmentInstant
    ) async throws -> PreparedRead? {
        let competition = loaded.projection.competition
        guard let schedule = competition.schedule,
              !loaded.projection.scoreLedger.isFrozen
        else {
            return nil
        }
        switch competition.lifecycle {
        case .scheduled, .active, .endsToday, .tallying:
            break
        case .pendingInvitation, .declined, .expired, .completed, .archived:
            return nil
        }
        let start = try schedule.calendar.startOfDay(schedule.startDay)
        guard attemptedInstant.wallDate >= start else { return nil }
        let window = try CompetitionActivityWindow(
            calendar: schedule.calendar,
            startDay: schedule.startDay
        )

        do {
            let result = try await environment.read(window)
            return PreparedRead(
                window: window,
                result: result,
                failureReason: nil,
                readInstant: await environment.instant()
            )
        } catch {
            return PreparedRead(
                window: window,
                result: nil,
                failureReason: queryFailureReason(from: error),
                readInstant: await environment.instant()
            )
        }
    }

    private func buildBatch(
        loaded: LoadedCompetitionJournal,
        trigger: ActivityRefreshTrigger,
        attemptID: String,
        attemptedInstant: EnvironmentInstant,
        preparedRead: PreparedRead?
    ) throws -> [CompetitionDomainEvent] {
        let clockObservationDate = preparedRead?.readInstant.wallDate
            ?? attemptedInstant.wallDate
        let clockEvents = try engine.observeClock(
            loaded.projection.competition,
            at: clockObservationDate
        )
        var events = clockEvents.map(CompetitionDomainEvent.lifecycle)
        let afterClock = try projection(
            appending: events,
            to: loaded.journal
        )

        guard let preparedRead,
              !afterClock.scoreLedger.isFrozen,
              let schedule = afterClock.competition.schedule
        else {
            return events
        }
        let currentWindow = try CompetitionActivityWindow(
            calendar: schedule.calendar,
            startDay: schedule.startDay
        )
        guard currentWindow == preparedRead.window else {
            throw LocalCompetitionRuntimeError.scheduleChangedDuringRefresh
        }

        let readStatus: ActivityRefreshReadStatus
        if let failureReason = preparedRead.failureReason {
            readStatus = .failed(reason: failureReason)
        } else {
            readStatus = .completed
        }
        let refresh = try ActivityRefreshAttemptRecorded(
            attemptID: attemptID,
            competitionID: afterClock.competition.id,
            attemptOrdinal: afterClock.activityRefresh.nextAttemptOrdinal,
            trigger: trigger,
            attemptedAt: attemptedInstant.wallDate,
            readAt: preparedRead.readInstant.wallDate,
            monotonicInstant: preparedRead.readInstant.monotonic,
            readStatus: readStatus,
            days: try dayObservations(
                preparedRead: preparedRead,
                window: currentWindow
            )
        )
        events.append(.activityRefreshAttemptRecorded(refresh))

        guard case .tallying = afterClock.competition.lifecycle else {
            return events
        }
        let evidence = try afterClock.finalReadEvidence(after: refresh)
        let finalRead = try engine.recordFinalRead(
            afterClock.competition,
            evidence: evidence
        )
        events.append(.lifecycle(finalRead))

        let afterFinalRead = try projection(
            appending: events,
            to: loaded.journal
        )
        guard let finalizationPolicy = finalizationPolicy(
            for: afterFinalRead.competition
        ),
        case let .finalize(authorization) = finalizationPolicy.decision(
            for: afterFinalRead.competition,
            at: preparedRead.readInstant.wallDate
        ) else {
            return events
        }
        let finalized = try engine.finalize(
            afterFinalRead.competition,
            authorization: authorization,
            at: preparedRead.readInstant.wallDate
        )
        events.append(.lifecycle(finalized))
        return events
    }

    private func projection(
        appending events: [CompetitionDomainEvent],
        to journal: CompetitionJournal
    ) throws -> CompetitionReplayProjection {
        guard !events.isEmpty else {
            return try CompetitionReplayer.replay(journal)
        }
        var candidate = journal
        _ = try candidate.append(
            events,
            expectedCursor: journal.cursor
        )
        return try CompetitionReplayer.replay(candidate)
    }

    private func dayObservations(
        preparedRead: PreparedRead,
        window: CompetitionActivityWindow
    ) throws -> [ActivityDayObservation] {
        let resultsByDay = Dictionary(
            uniqueKeysWithValues: (preparedRead.result?.days ?? []).map {
                ($0.day, $0)
            }
        )
        return try window.days.enumerated().map { offset, day in
            let ordinal = offset + 1
            let dayStart = try window.calendar.startOfDay(day)
            let availability: ActivityDayAvailability
            if dayStart > preparedRead.readInstant.wallDate {
                availability = .notYetOccurred
            } else if let failureReason = preparedRead.failureReason {
                availability = .unavailable(
                    reason: failureReason == .invalidResponse
                        ? .invalidSourceData
                        : .sourceDataUnavailable
                )
            } else {
                switch resultsByDay[day] {
                case let .snapshot(_, snapshot):
                    availability = .observed(snapshot)
                case .missing, .none:
                    availability = .missing
                }
            }
            return ActivityDayObservation(
                day: day,
                ordinal: ordinal,
                availability: availability
            )
        }
    }

    private func queryFailureReason(
        from error: Error
    ) -> ActivityQueryFailureReason {
        if error is CancellationError { return .queryCancelled }
        switch error as? CompetitionActivitySourceError {
        case .healthDataUnavailable:
            return .healthDataUnavailable
        case .protectedDataUnavailable:
            return .protectedDataUnavailable
        case .invalidResponse:
            return .invalidResponse
        case .unclassifiedQueryFailure, .none:
            return .unknown
        }
    }

    private func mintAttemptID(
        competitionID: CompetitionID,
        initialAttemptOrdinal: UInt64
    ) -> String {
        // The durable attempt identity represents one logical refresh ordinal.
        // Epoch and uptime remain persisted on `monotonicInstant` as transport
        // evidence, but must not make semantic event identity execution-speed
        // or process-epoch dependent.
        return [
            "runtime",
            competitionID.rawValue.uuidString.lowercased(),
            "attempt",
            String(initialAttemptOrdinal),
        ].joined(separator: "-")
    }

    private func finalizationPolicy(
        for competition: CompetitionCore.Competition
    ) -> FinalizationPolicy? {
        switch policySource {
        case let .configuration(configuration):
            return configuration.finalizationPolicy(for: competition)
        case let .fixed(policy):
            return policy
        }
    }

    private func withMutationGate<Value>(
        _ operation: () async throws -> Value
    ) async rethrows -> Value {
        await acquireMutationGate()
        defer { releaseMutationGate() }
        return try await operation()
    }

    private func acquireMutationGate() async {
        guard mutationIsInProgress else {
            mutationIsInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutationGate() {
        guard !mutationWaiters.isEmpty else {
            mutationIsInProgress = false
            return
        }
        mutationWaiters.removeFirst().resume()
    }

    private func failure(
        from error: Error
    ) -> LocalCompetitionRuntimeFailure {
        switch error as? LocalCompetitionRuntimeError {
        case .competitionNotFound:
            return .competitionNotFound
        case .cursorRetryLimitExceeded:
            return .cursorRetryLimitExceeded
        case .scheduleChangedDuringRefresh:
            return .scheduleChangedDuringRefresh
        case .none:
            break
        }
        if error is CompetitionEngine.EngineError {
            return .invalidTransition
        }
        if error is CompetitionEventStoreError {
            return .storageUnavailable
        }
        return .storageUnavailable
    }

    private static func sortCompetitionIDs(
        _ lhs: CompetitionID,
        _ rhs: CompetitionID
    ) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}
