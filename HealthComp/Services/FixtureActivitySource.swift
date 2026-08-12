import CompetitionCore
import Foundation

#if DEBUG

enum FixtureActivitySourceError: Error, Equatable, Sendable {
    case invalidInitialDay
    case duplicateInitialDay(CompetitionDay)
    case duplicateChangeDate(Date)
    case duplicateUpdateDay(CompetitionDay)
    case nonFiniteDate
    case cannotMoveBackward
    case mustAdvanceThroughCheckpoint(Date)
}

enum FixtureActivityValue: Equatable, Sendable {
    case snapshot(day: CompetitionDay, snapshot: ActivitySnapshot)
    case missing(day: CompetitionDay)

    var day: CompetitionDay {
        switch self {
        case let .snapshot(day, _), let .missing(day):
            return day
        }
    }
}

enum FixtureActivityReadState: Equatable, Sendable {
    case available
    case failure(CompetitionActivitySourceError)
}

enum FixtureSummarySubscriptionSynchronization: Equatable, Sendable {
    case changed(to: Set<CompetitionActivityWindow>)
    case noOp(desired: Set<CompetitionActivityWindow>)
}

struct FixtureActivityChange: Equatable, Sendable {
    let at: Date
    let updates: [FixtureActivityValue]
    let triggers: [ActivityRefreshTrigger]
    let epochID: String?
    let resetMonotonicNanoseconds: UInt64?
    let readState: FixtureActivityReadState?

    init(
        at: Date,
        updates: [FixtureActivityValue],
        triggers: [ActivityRefreshTrigger],
        epochID: String? = nil,
        resetMonotonicNanoseconds: UInt64? = nil,
        readState: FixtureActivityReadState? = nil
    ) throws {
        guard at.timeIntervalSinceReferenceDate.isFinite else {
            throw FixtureActivitySourceError.nonFiniteDate
        }
        var seen = Set<CompetitionDay>()
        for update in updates where !seen.insert(update.day).inserted {
            throw FixtureActivitySourceError.duplicateUpdateDay(update.day)
        }
        self.at = at
        self.updates = updates
        self.triggers = triggers
        self.epochID = epochID
        self.resetMonotonicNanoseconds = resetMonotonicNanoseconds
        self.readState = readState
    }
}

struct ActivityFixture: Equatable, Sendable {
    let initialInstant: EnvironmentInstant
    let timeZoneIdentifier: String
    let initialDays: [FixtureActivityValue]
    let initialReadState: FixtureActivityReadState
    let changes: [FixtureActivityChange]

    init(
        initialInstant: EnvironmentInstant,
        timeZoneIdentifier: String = "UTC",
        initialDays: [FixtureActivityValue],
        initialReadState: FixtureActivityReadState = .available,
        changes: [FixtureActivityChange]
    ) throws {
        guard initialInstant.wallDate.timeIntervalSinceReferenceDate.isFinite else {
            throw FixtureActivitySourceError.nonFiniteDate
        }
        var seenDays = Set<CompetitionDay>()
        for value in initialDays where !seenDays.insert(value.day).inserted {
            throw FixtureActivitySourceError.duplicateInitialDay(value.day)
        }
        let orderedChanges = changes.sorted { $0.at < $1.at }
        guard orderedChanges.allSatisfy({ $0.at >= initialInstant.wallDate }) else {
            throw FixtureActivitySourceError.invalidInitialDay
        }
        for pair in zip(orderedChanges, orderedChanges.dropFirst())
        where pair.0.at == pair.1.at {
            throw FixtureActivitySourceError.duplicateChangeDate(pair.0.at)
        }
        self.initialInstant = initialInstant
        self.timeZoneIdentifier = timeZoneIdentifier
        self.initialDays = initialDays
        self.initialReadState = initialReadState
        self.changes = orderedChanges
    }
}

actor FixtureActivitySource: CompetitionActivitySource {
    private struct Waiter {
        let date: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private var instantValue: EnvironmentInstant
    private let fixtureTimeZoneIdentifier: String
    private var valuesByDay: [CompetitionDay: FixtureActivityValue]
    private var readState: FixtureActivityReadState
    private let changes: [FixtureActivityChange]
    private var nextChangeIndex = 0
    private var nextSignalOrdinal: UInt64 = 1
    private var signalContinuations: [UUID: AsyncStream<EnvironmentSignal>.Continuation] = [:]
    private var signalCompletionCounts: [String: Int] = [:]
    private var waiters: [UUID: Waiter] = [:]
    private var shouldBlockNextRead = false
    private var readIsBlocked = false
    private var blockedReadContinuation: CheckedContinuation<Void, Never>?
    private var readBlockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldBlockNextWaitRegistration = false
    private var waitRegistrationIsBlocked = false
    private var blockedWaitRegistrationContinuation:
        CheckedContinuation<Void, Never>?
    private var waitRegistrationBlockedWaiters: [
        CheckedContinuation<Void, Never>
    ] = []
    private var desiredSummaryWindows = Set<CompetitionActivityWindow>()
    private var summarySubscriptionSyncs: [
        FixtureSummarySubscriptionSynchronization
    ] = []

    init(fixture: ActivityFixture) {
        self.instantValue = fixture.initialInstant
        self.fixtureTimeZoneIdentifier = fixture.timeZoneIdentifier
        self.valuesByDay = Dictionary(
            uniqueKeysWithValues: fixture.initialDays.map { ($0.day, $0) }
        )
        self.readState = fixture.initialReadState
        self.changes = fixture.changes
    }

    init(fixture: ActivityFixture, restoringAt restoreDate: Date) throws {
        guard restoreDate.timeIntervalSinceReferenceDate.isFinite else {
            throw FixtureActivitySourceError.nonFiniteDate
        }
        guard restoreDate >= fixture.initialInstant.wallDate else {
            throw FixtureActivitySourceError.cannotMoveBackward
        }
        var valuesByDay = Dictionary(
            uniqueKeysWithValues: fixture.initialDays.map { ($0.day, $0) }
        )
        var readState = fixture.initialReadState
        var elapsedCursor = fixture.initialInstant.wallDate
        var epochID = fixture.initialInstant.monotonic.epochID
        var monotonicNanoseconds = fixture.initialInstant.monotonic.nanoseconds
        var restoredChangeCount = 0
        for change in fixture.changes where change.at <= restoreDate {
            Self.applyElapsedTime(
                from: elapsedCursor,
                to: change.at,
                nanoseconds: &monotonicNanoseconds
            )
            if let changedEpoch = change.epochID {
                epochID = changedEpoch
                monotonicNanoseconds = change.resetMonotonicNanoseconds ?? 0
            }
            for update in change.updates {
                valuesByDay[update.day] = update
            }
            if let changedReadState = change.readState {
                readState = changedReadState
            }
            elapsedCursor = change.at
            restoredChangeCount += 1
        }
        Self.applyElapsedTime(
            from: elapsedCursor,
            to: restoreDate,
            nanoseconds: &monotonicNanoseconds
        )
        self.instantValue = EnvironmentInstant(
            wallDate: restoreDate,
            monotonic: MonotonicInstant(
                epochID: epochID,
                nanoseconds: monotonicNanoseconds
            )
        )
        self.fixtureTimeZoneIdentifier = fixture.timeZoneIdentifier
        self.valuesByDay = valuesByDay
        self.readState = readState
        self.changes = fixture.changes
        self.nextChangeIndex = restoredChangeCount
    }

    func instant() -> EnvironmentInstant {
        instantValue
    }

    func context() -> CompetitionEnvironmentContext {
        CompetitionEnvironmentContext(
            instant: instantValue,
            timeZoneIdentifier: fixtureTimeZoneIdentifier
        )
    }

    func timeZoneIdentifier() -> String {
        fixtureTimeZoneIdentifier
    }

    func requestReadAuthorization() async throws {
        // Accelerated data is local deterministic fixture state and requires no
        // HealthKit authorization.
    }

    func read(_ window: CompetitionActivityWindow) async throws -> ActivityWindowRead {
        if shouldBlockNextRead {
            shouldBlockNextRead = false
            readIsBlocked = true
            for waiter in readBlockedWaiters { waiter.resume() }
            readBlockedWaiters.removeAll()
            await withCheckedContinuation { continuation in
                blockedReadContinuation = continuation
            }
            readIsBlocked = false
        }
        if case let .failure(error) = readState {
            throw error
        }
        return try ActivityWindowRead(
            window: window,
            days: window.days.map { day in
                switch valuesByDay[day] {
                case let .snapshot(_, snapshot):
                    return .snapshot(day: day, snapshot: snapshot)
                case .missing, .none:
                    return .missing(day: day)
                }
            }
        )
    }

    func synchronizeSummarySubscriptions(
        to desiredWindows: Set<CompetitionActivityWindow>
    ) {
        guard desiredWindows != self.desiredSummaryWindows else {
            summarySubscriptionSyncs.append(.noOp(desired: desiredWindows))
            return
        }
        self.desiredSummaryWindows = desiredWindows
        summarySubscriptionSyncs.append(.changed(to: desiredWindows))
    }

    func desiredSummarySubscriptionWindows() -> Set<CompetitionActivityWindow> {
        desiredSummaryWindows
    }

    func summarySubscriptionSynchronizations() -> [
        FixtureSummarySubscriptionSynchronization
    ] {
        summarySubscriptionSyncs
    }

    func signals() -> AsyncStream<EnvironmentSignal> {
        let token = UUID()
        return AsyncStream { continuation in
            signalContinuations[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSignalContinuation(token) }
            }
        }
    }

    func signalSubscriberCount() -> Int {
        signalContinuations.count
    }

    func completeSignal(_ id: String) async {
        signalCompletionCounts[id, default: 0] += 1
    }

    func wait(until date: Date) async throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw FixtureActivitySourceError.nonFiniteDate
        }
        guard instantValue.wallDate < date else { return }
        try Task.checkCancellation()
        if shouldBlockNextWaitRegistration {
            shouldBlockNextWaitRegistration = false
            waitRegistrationIsBlocked = true
            for waiter in waitRegistrationBlockedWaiters { waiter.resume() }
            waitRegistrationBlockedWaiters.removeAll()
            await withCheckedContinuation { continuation in
                blockedWaitRegistrationContinuation = continuation
            }
            waitRegistrationIsBlocked = false
            try Task.checkCancellation()
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = Waiter(
                        date: date,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func advance(to targetDate: Date) throws {
        guard targetDate.timeIntervalSinceReferenceDate.isFinite else {
            throw FixtureActivitySourceError.nonFiniteDate
        }
        guard targetDate >= instantValue.wallDate else {
            throw FixtureActivitySourceError.cannotMoveBackward
        }
        if nextChangeIndex + 1 < changes.count,
           changes[nextChangeIndex + 1].at <= targetDate {
            throw FixtureActivitySourceError.mustAdvanceThroughCheckpoint(
                changes[nextChangeIndex].at
            )
        }

        let priorDate = instantValue.wallDate
        var elapsedCursor = priorDate
        var epochID = instantValue.monotonic.epochID
        var monotonicNanoseconds = instantValue.monotonic.nanoseconds
        while nextChangeIndex < changes.count,
              changes[nextChangeIndex].at <= targetDate {
            let change = changes[nextChangeIndex]
            Self.applyElapsedTime(
                from: elapsedCursor,
                to: change.at,
                nanoseconds: &monotonicNanoseconds
            )
            if let changedEpoch = change.epochID {
                epochID = changedEpoch
                monotonicNanoseconds = change.resetMonotonicNanoseconds ?? 0
            }
            for update in change.updates {
                valuesByDay[update.day] = update
            }
            if let changedReadState = change.readState {
                readState = changedReadState
            }
            for trigger in change.triggers {
                emit(trigger)
            }
            elapsedCursor = change.at
            nextChangeIndex += 1
        }

        Self.applyElapsedTime(
            from: elapsedCursor,
            to: targetDate,
            nanoseconds: &monotonicNanoseconds
        )
        instantValue = EnvironmentInstant(
            wallDate: targetDate,
            monotonic: MonotonicInstant(
                epochID: epochID,
                nanoseconds: monotonicNanoseconds
            )
        )
        resumeReadyWaiters()
    }

    func didCompleteSignal(_ id: String) -> Bool {
        signalCompletionCounts[id, default: 0] > 0
    }

    func signalCompletionCount(_ id: String) -> Int {
        signalCompletionCounts[id, default: 0]
    }

    func blockNextRead() {
        shouldBlockNextRead = true
    }

    func waitUntilReadIsBlocked() async {
        guard !readIsBlocked else { return }
        await withCheckedContinuation { continuation in
            readBlockedWaiters.append(continuation)
        }
    }

    func releaseBlockedRead() {
        blockedReadContinuation?.resume()
        blockedReadContinuation = nil
    }

    func pendingWaiterCount() -> Int {
        waiters.count
    }

    func pendingWaiterDates() -> [Date] {
        waiters.values.map(\.date).sorted()
    }

    func blockNextWaitRegistration() {
        shouldBlockNextWaitRegistration = true
    }

    func waitUntilWaitRegistrationIsBlocked() async {
        guard !waitRegistrationIsBlocked else { return }
        await withCheckedContinuation { continuation in
            waitRegistrationBlockedWaiters.append(continuation)
        }
    }

    func releaseBlockedWaitRegistration() {
        blockedWaitRegistrationContinuation?.resume()
        blockedWaitRegistrationContinuation = nil
    }

    private static func applyElapsedTime(
        from start: Date,
        to end: Date,
        nanoseconds: inout UInt64
    ) {
        let elapsed = max(0, end.timeIntervalSince(start))
        let increment = CompetitionEnvironmentClient.nanosecondsForDelay(
            elapsed
        )
        nanoseconds = nanoseconds.addingReportingOverflow(increment).overflow
            ? UInt64.max
            : nanoseconds + increment
    }

    private func emit(_ trigger: ActivityRefreshTrigger) {
        let id = "fixture-signal-\(nextSignalOrdinal)"
        nextSignalOrdinal += 1
        let signal = EnvironmentSignal(
            id: id,
            trigger: trigger,
            requiresCompletion: trigger == .observerWakeupBackground
        )
        for continuation in signalContinuations.values {
            continuation.yield(signal)
        }
    }

    private func removeSignalContinuation(_ token: UUID) {
        signalContinuations[token] = nil
    }

    private func resumeReadyWaiters() {
        let readyIDs = waiters.compactMap { id, waiter in
            waiter.date <= instantValue.wallDate ? id : nil
        }
        for id in readyIDs {
            waiters.removeValue(forKey: id)?.continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }
}
#endif
