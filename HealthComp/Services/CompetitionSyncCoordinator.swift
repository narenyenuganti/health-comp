import CompetitionCore
import Foundation

enum CompetitionSyncCoordinatorFailure: Error, Equatable, Sendable {
    case stopped
}

struct CompetitionAcceptedScorePersistence: Sendable {
    var persist: @Sendable (
        _ profileID: UUID,
        _ request: CompetitionScoreRevisionRequest,
        _ response: CompetitionScoreRevisionResponse,
        _ receivedAt: Date
    ) async throws -> Void

    init(
        _ persist: @escaping @Sendable (
            _ profileID: UUID,
            _ request: CompetitionScoreRevisionRequest,
            _ response: CompetitionScoreRevisionResponse,
            _ receivedAt: Date
        ) async throws -> Void
    ) {
        self.persist = persist
    }

    static func eventStore(_ store: any CompetitionEventStore) -> Self {
        Self { profileID, request, response, receivedAt in
            guard response.disposition == .appended
                    || response.disposition == .duplicate,
                  response.rejectionCode == nil,
                  let wireContentSHA256 = response.wireContentSHA256,
                  wireContentSHA256 == request.wireContentSHA256,
                  let serverSequence = response.acceptedServerSequence,
                  (request.availabilityReason == "available")
                    == (response.acceptedCentiPoints != nil)
            else {
                throw CompetitionRemoteFailure.serverContractMismatch
            }
            let competitionID = CompetitionID(request.competitionID)
            let row = try RemoteAcceptedScoreRow(
                ordinal: request.dayOrdinal,
                acceptedCentiPoints: response.acceptedCentiPoints,
                availabilityReason: request.availabilityReason == "available"
                    ? nil
                    : request.availabilityReason,
                wireContentSHA256: wireContentSHA256,
                scoringPolicyIdentity: request.scoringPolicyIdentity,
                clientRevision: request.clientRevision,
                serverSequence: serverSequence
            )
            let revision = try RemoteScoreRevision(
                competitionID: competitionID,
                participant: RemoteParticipant(profileID: profileID),
                row: row,
                recordedAt: request.evaluatedAt
            )
            let receipt = try SynchronizationReceipt(
                competitionID: competitionID,
                serverCursor: response.competitionCursor,
                acknowledgedEventID: revision.semanticEventID,
                kind: .scoreRevision,
                disposition: response.disposition == .appended
                    ? .appended
                    : .duplicate,
                entityServerSequence: serverSequence,
                receivedAt: receivedAt
            )
            let maximumCursorConflictAttempts = 8
            for attempt in 1...maximumCursorConflictAttempts {
                try Task.checkCancellation()
                guard let loaded = try await store.load(competitionID) else {
                    throw CompetitionEventStoreError.identityNotFound
                }
                do {
                    _ = try await store.append(
                        [
                            .remoteScoreRevisionRecorded(revision),
                            .synchronizationReceiptRecorded(receipt),
                        ],
                        to: competitionID,
                        expectedCursor: loaded.journal.cursor
                    )
                    return
                } catch CompetitionEventStoreError.cursorConflict
                    where attempt < maximumCursorConflictAttempts
                {
                    continue
                }
            }
        }
    }
}

actor CompetitionSyncCoordinator {
    private let profileID: UUID
    private let outboxStore: any CompetitionOutboxStore
    private let remoteAPI: CompetitionRemoteAPI
    private let acceptedScorePersistence: CompetitionAcceptedScorePersistence
    private let isOnline: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let sleepUntil: @Sendable (Date) async throws -> Void

    private var drainRequested = false
    private var drainTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var scheduledRetryAt: Date?
    private var isStopped = false

    init(
        profileID: UUID,
        outboxStore: any CompetitionOutboxStore,
        remoteAPI: CompetitionRemoteAPI,
        acceptedScorePersistence: CompetitionAcceptedScorePersistence,
        isOnline: @escaping @Sendable () -> Bool = { true },
        now: @escaping @Sendable () -> Date,
        sleepUntil: @escaping @Sendable (Date) async throws -> Void = {
            deadline in
            let delay = max(deadline.timeIntervalSinceNow, 0)
            try await Task.sleep(for: .seconds(delay))
        }
    ) {
        self.profileID = profileID
        self.outboxStore = outboxStore
        self.remoteAPI = remoteAPI
        self.acceptedScorePersistence = acceptedScorePersistence
        self.isOnline = isOnline
        self.now = now
        self.sleepUntil = sleepUntil
    }

    @discardableResult
    func enqueue(
        _ payload: CompetitionOutboxPayload,
        enqueuedAt: Date
    ) async throws -> CompetitionOutboxEntry {
        guard !isStopped else {
            throw CompetitionSyncCoordinatorFailure.stopped
        }
        let entry = try await outboxStore.enqueue(
            payload,
            enqueuedAt: enqueuedAt
        )
        requestDrain()
        return entry
    }

    func waitUntilIdle() async {
        while let task = drainTask {
            await task.value
        }
    }

    func wake() {
        requestDrain()
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        drainRequested = false
        let activeDrain = drainTask
        let scheduledRetry = retryTask
        retryTask = nil
        scheduledRetryAt = nil
        activeDrain?.cancel()
        scheduledRetry?.cancel()
        await activeDrain?.value
        drainTask = nil
    }

    private func requestDrain() {
        guard !isStopped else { return }
        drainRequested = true
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            await self?.runDrainTask()
        }
    }

    private func runDrainTask() async {
        defer { drainTask = nil }
        var nextRetryAt: Date?
        while drainRequested, !Task.isCancelled {
            drainRequested = false
            do {
                nextRetryAt = try await drainPass()
            } catch is CancellationError {
                return
            } catch {
                if let durableRetryAt = try? await earliestDurableRetryAt() {
                    replaceRetrySchedule(with: durableRetryAt)
                }
                return
            }
        }
        replaceRetrySchedule(with: nextRetryAt)
    }

    private func drainPass() async throws -> Date? {
        var nextRetryAt: Date?
        for entry in try await outboxStore.entries() {
            try Task.checkCancellation()
            switch (entry.payload, entry.state) {
            case let (
                .scoreRevision(request),
                .pending(attemptCount, retryAt)
            ):
                let requestedAt = now()
                if let retryAt, retryAt > requestedAt {
                    nextRetryAt = earlier(retryAt, than: nextRetryAt)
                    continue
                }
                guard isOnline() else { continue }
                let response: CompetitionScoreRevisionResponse
                do {
                    response = try await remoteAPI.appendScoreRevision(request)
                } catch CompetitionRemoteFailure.retryableTransport {
                    let updated = try await outboxStore.update(
                        entry.semanticEventID,
                        expectedGeneration: entry.generation,
                        state: stateAfterRetryableFailure(
                            attemptCount: attemptCount,
                            failedAt: requestedAt
                        )
                    )
                    if case let .pending(_, retryAt?) = updated.state {
                        nextRetryAt = earlier(retryAt, than: nextRetryAt)
                    }
                    continue
                } catch let failure as CompetitionRemoteFailure {
                    if failure == .cancelled { throw CancellationError() }
                    _ = try await outboxStore.update(
                        entry.semanticEventID,
                        expectedGeneration: entry.generation,
                        state: .permanentFailure(
                            permanentFailure(for: failure),
                            failedAt: requestedAt
                        )
                    )
                    continue
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    _ = try await outboxStore.update(
                        entry.semanticEventID,
                        expectedGeneration: entry.generation,
                        state: .permanentFailure(
                            .operationFailed,
                            failedAt: requestedAt
                        )
                    )
                    continue
                }
                let receivedAt = now()
                if response.disposition == .rejected {
                    guard let rejectionCode = response.rejectionCode else {
                        throw CompetitionRemoteFailure.serverContractMismatch
                    }
                    _ = try await outboxStore.update(
                        entry.semanticEventID,
                        expectedGeneration: entry.generation,
                        state: .permanentFailure(
                            permanentFailure(for: rejectionCode),
                            failedAt: receivedAt
                        )
                    )
                    continue
                }
                let accepted = try await outboxStore.update(
                    entry.semanticEventID,
                    expectedGeneration: entry.generation,
                    state: .scoreAccepted(
                        response,
                        receivedAt: receivedAt
                    )
                )
                try await acceptedScorePersistence.persist(
                    profileID,
                    request,
                    response,
                    receivedAt
                )
                try await outboxStore.remove(
                    accepted.semanticEventID,
                    expectedGeneration: accepted.generation
                )
            case let (
                .scoreRevision(request),
                .scoreAccepted(response, receivedAt)
            ):
                try await acceptedScorePersistence.persist(
                    profileID,
                    request,
                    response,
                    receivedAt
                )
                try await outboxStore.remove(
                    entry.semanticEventID,
                    expectedGeneration: entry.generation
                )
            case let (
                .finalWindowAttestation(request),
                .pending(attemptCount, retryAt)
            ):
                let requestedAt = now()
                if let retryAt, retryAt > requestedAt {
                    nextRetryAt = earlier(retryAt, than: nextRetryAt)
                    continue
                }
                guard isOnline() else { continue }
                let receipt: CompetitionAttestationReceipt
                do {
                    receipt = try await remoteAPI.submitAttestation(request)
                } catch CompetitionRemoteFailure.retryableTransport {
                    let updated = try await outboxStore.update(
                        entry.semanticEventID,
                        expectedGeneration: entry.generation,
                        state: stateAfterRetryableFailure(
                            attemptCount: attemptCount,
                            failedAt: requestedAt
                        )
                    )
                    if case let .pending(_, retryAt?) = updated.state {
                        nextRetryAt = earlier(retryAt, than: nextRetryAt)
                    }
                    continue
                } catch let failure as CompetitionRemoteFailure {
                    if failure == .cancelled { throw CancellationError() }
                    _ = try await outboxStore.update(
                        entry.semanticEventID,
                        expectedGeneration: entry.generation,
                        state: .permanentFailure(
                            permanentFailure(for: failure),
                            failedAt: requestedAt
                        )
                    )
                    continue
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    _ = try await outboxStore.update(
                        entry.semanticEventID,
                        expectedGeneration: entry.generation,
                        state: .permanentFailure(
                            .operationFailed,
                            failedAt: requestedAt
                        )
                    )
                    continue
                }
                _ = try await outboxStore.update(
                    entry.semanticEventID,
                    expectedGeneration: entry.generation,
                    state: .attestationAcknowledged(
                        receipt,
                        receivedAt: now()
                    )
                )
            case (.finalWindowAttestation, .attestationAcknowledged):
                // Task 13 removes this only after the authoritative change
                // feed materializes the server-owned attestation fields.
                continue
            case (.finalWindowAttestation, .permanentFailure),
                 (.scoreRevision, .permanentFailure):
                // Terminal failures intentionally remain support-inspectable.
                continue
            case (.scoreRevision, .attestationAcknowledged),
                 (.finalWindowAttestation, .scoreAccepted):
                throw CompetitionOutboxStoreFailure.invalidDocument
            }
        }
        return nextRetryAt
    }

    private func replaceRetrySchedule(with retryAt: Date?) {
        guard !isStopped else { return }
        guard scheduledRetryAt != retryAt else { return }
        retryTask?.cancel()
        retryTask = nil
        scheduledRetryAt = retryAt
        guard let retryAt else { return }
        let sleepUntil = sleepUntil
        retryTask = Task { [weak self] in
            do {
                try await sleepUntil(retryAt)
            } catch {
                return
            }
            await self?.retryTimerFired(expectedRetryAt: retryAt)
        }
    }

    private func retryTimerFired(expectedRetryAt: Date) {
        guard scheduledRetryAt == expectedRetryAt else { return }
        retryTask = nil
        scheduledRetryAt = nil
        requestDrain()
    }

    private func earlier(_ candidate: Date, than current: Date?) -> Date {
        guard let current else { return candidate }
        return min(candidate, current)
    }

    private func earliestDurableRetryAt() async throws -> Date? {
        let currentDate = now()
        return try await outboxStore.entries().reduce(nil) {
            earliest,
            entry in
            guard case let .pending(_, retryAt?) = entry.state,
                  retryAt > currentDate
            else {
                return earliest
            }
            return earlier(retryAt, than: earliest)
        }
    }

    private func retryDelay(forAttempt attempt: Int) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 10)
        return min(TimeInterval(1 << exponent), 900)
    }

    private func stateAfterRetryableFailure(
        attemptCount: Int,
        failedAt: Date
    ) -> CompetitionOutboxState {
        guard attemptCount < Int.max else {
            return .permanentFailure(
                .operationFailed,
                failedAt: failedAt
            )
        }
        let nextAttempt = attemptCount + 1
        return .pending(
            attemptCount: nextAttempt,
            retryAt: failedAt.addingTimeInterval(
                retryDelay(forAttempt: nextAttempt)
            )
        )
    }

    private func permanentFailure(
        for failure: CompetitionRemoteFailure
    ) -> CompetitionOutboxPermanentFailure {
        switch failure {
        case .unauthenticated:
            .unauthenticated
        case .forbidden:
            .forbidden
        case .notFound:
            .notFound
        case .inviteUnavailable:
            .inviteUnavailable
        case .divergentDuplicate:
            .divergentDuplicate
        case .staleRevision:
            .staleRevision
        case .finalizedCompetition:
            .finalizedCompetition
        case .incompatiblePolicy:
            .incompatiblePolicy
        case .serverContractMismatch:
            .serverContractMismatch
        case .accountDeletionUnavailable:
            .accountDeletionUnavailable
        case .operationFailed:
            .operationFailed
        case .cancelled, .retryableTransport:
            .operationFailed
        }
    }

    private func permanentFailure(
        for rejection: CompetitionScoreRevisionRejectionCode
    ) -> CompetitionOutboxPermanentFailure {
        switch rejection {
        case .divergentDuplicate:
            .divergentDuplicate
        case .revisionRegression:
            .staleRevision
        case .windowStable, .competitionTerminal, .competitionFinalized:
            .finalizedCompetition
        }
    }
}
