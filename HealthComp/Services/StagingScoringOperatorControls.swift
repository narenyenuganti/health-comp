#if HEALTHCOMP_STAGING
import Foundation

final class StagingScoringCaptureOwner: Sendable {}

@objc(HealthCompStagingScoringOperator)
final class StagingScoringOperatorControls: NSObject, @unchecked Sendable {
    enum DisplayState: Equatable, Sendable {
        case unavailable, off, waiting, captured(String), closed
    }

    enum ActivityEvent: String, CaseIterable, Sendable {
        case missingDependency, skippedLifecycle, readStarted, readCompleted
        case snapshotDays, missingDays, futureDays, unchangedOutbox
        case unchangedTerminal, unchangedAccepted, queuedRevisions, readFailed
        case reconciliationFailed
    }

    struct ActivitySummary: Equatable, Sendable {
        let counts: [ActivityEvent: Int]
        subscript(_ event: ActivityEvent) -> Int { counts[event, default: 0] }
    }

    enum ActivityDisplayState: Equatable, Sendable {
        case unavailable, off, waiting, running, complete(ActivitySummary), closed
    }

    private final class ActivityToken: Sendable {}
    private struct ActivityContext: Sendable {
        let controls: StagingScoringOperatorControls
        let token: ActivityToken
    }
    @TaskLocal private static var activityContext: ActivityContext?
    private enum ActivityState {
        case off, waiting, running(ActivityToken), complete(ActivitySummary), closed
    }

    static let shared = StagingScoringOperatorControls()
    private let lock = NSLock()
    private let now: @Sendable () -> ContinuousClock.Instant
    private var owner: StagingScoringCaptureOwner?
    private enum State { case idle, requested, armed, captured(NSString), closed }
    private var state: State = .idle
    private var deadline: ContinuousClock.Instant?
    private var activityState: ActivityState = .off
    private var activityDeadline: ContinuousClock.Instant?
    private var activityCounts: [ActivityEvent: Int] = [:]

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    func displayState() -> DisplayState {
        guard lock.try() else { return .unavailable }
        defer { lock.unlock() }
        guard owner != nil else { return .unavailable }
        switch state {
        case .idle: return .off
        case .closed: return .closed
        case .requested, .armed: return isOpen ? .waiting : .closed
        case let .captured(value):
            return isOpen ? .captured(value as String) : .closed
        }
    }

    func cancelStartedCapture() {
        lock.withLock {
            if case .idle = state {} else { close() }
        }
    }

    func cancelStartedActivityObservation() {
        lock.withLock {
            if case .off = activityState {} else { closeActivity() }
        }
    }

    func bind(_ owner: StagingScoringCaptureOwner) {
        lock.withLock {
            guard self.owner !== owner else { return }
            self.owner = owner
            state = .idle
            deadline = nil
            activityState = .off
            activityDeadline = nil
            activityCounts = [:]
        }
    }
    func requestArm() -> Bool {
        guard lock.try() else { return false }
        defer { lock.unlock() }
        guard owner != nil, case .idle = state else { return false }
        state = .requested
        deadline = now() + .seconds(60)
        return true
    }

    // Debugger entry points never wait on a stopped thread's lock or enter the provider.
    @objc static func arm() -> Bool { shared.requestArm() }
    @objc static func take() -> NSString? { shared.takeResponse() }

    @objc static func cancel() -> Bool { shared.cancelCapture() }

    // Confirms operator-slot clearance without entering or retiring the shared client.
    func cancelCapture() -> Bool {
        guard lock.try() else { return false }
        defer { lock.unlock() }
        close()
        return true
    }

    func takeResponse() -> NSString? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        guard isOpen, case let .captured(value) = state else { return nil }
        close()
        return value
    }

    // Called by normal app execution, never by a stopped-process expression.
    func consumeArmRequest(for owner: StagingScoringCaptureOwner) -> Duration? {
        lock.withLock {
            guard self.owner === owner, isOpen else { return nil }
            // Only destructive retrieval, not display, ends ambiguity.
            if case .captured = state { close(); return nil }
            guard case .requested = state,
                  let deadline else { return nil }
            let remaining = now().duration(to: deadline)
            guard remaining > .zero else { close(); return nil }
            state = .armed
            return remaining
        }
    }

    func recordResponse(_ value: String, for owner: StagingScoringCaptureOwner) {
        lock.withLock {
            guard self.owner === owner, isOpen, case .armed = state else { return }
            state = .captured(value as NSString)
        }
    }

    func isArmed(for owner: StagingScoringCaptureOwner) -> Bool {
        lock.withLock {
            guard self.owner === owner, isOpen, case .armed = state else { return false }
            return true
        }
    }

    func cancel(for owner: StagingScoringCaptureOwner) {
        lock.withLock {
            if self.owner === owner { close() }
        }
    }

    func cancelActivityObservation(for owner: StagingScoringCaptureOwner) {
        lock.withLock {
            if self.owner === owner { closeActivity() }
        }
    }

    func requestActivityObservation() -> Bool {
        guard lock.try() else { return false }
        defer { lock.unlock() }
        guard owner != nil, case .off = activityState else { return false }
        activityState = .waiting
        activityDeadline = now() + .seconds(600)
        return true
    }

    func activityDisplayState() -> ActivityDisplayState {
        guard lock.try() else { return .unavailable }
        defer { lock.unlock() }
        guard owner != nil else { return .unavailable }
        if case .off = activityState { return .off }
        guard activityIsOpen else { return .closed }
        switch activityState {
        case .off: return .off
        case .waiting: return .waiting
        case .running: return .running
        case let .complete(summary): return .complete(summary)
        case .closed: return .closed
        }
    }

    func cancelActivityObservation() {
        lock.withLock { closeActivity() }
    }

    // Only the armed manual refresh's task tree can contribute fixed counters.
    func observeActivity<Value>(
        _ operation: () async throws -> Value
    ) async rethrows -> Value {
        let context: ActivityContext? = lock.withLock {
            guard owner != nil, activityIsOpen,
                  case .waiting = activityState else { return nil }
            let token = ActivityToken()
            activityState = .running(token)
            return ActivityContext(controls: self, token: token)
        }
        return try await Self.$activityContext.withValue(context) {
            defer {
                if let context { finishActivity(context.token) }
            }
            return try await operation()
        }
    }

    static func recordActivity(_ event: ActivityEvent, count: Int = 1) {
        guard let context = activityContext, count > 0 else { return }
        context.controls.lock.withLock {
            guard context.controls.activityIsOpen,
                  case let .running(token) = context.controls.activityState,
                  token === context.token else { return }
            let previous = context.controls.activityCounts[event, default: 0]
            context.controls.activityCounts[event] = min(10_000, previous + min(count, 10_000))
        }
    }

    private func finishActivity(_ expected: ActivityToken) {
        lock.withLock {
            guard activityIsOpen, case let .running(token) = activityState,
                  token === expected else { return }
            guard !Task.isCancelled else { closeActivity(); return }
            activityState = .complete(ActivitySummary(counts: activityCounts))
            activityCounts = [:]
        }
    }

    private var activityIsOpen: Bool {
        guard let activityDeadline, now() < activityDeadline else {
            if case .off = activityState {} else { closeActivity() }
            return false
        }
        return true
    }

    private func closeActivity() {
        activityState = .closed
        activityDeadline = nil
        activityCounts = [:]
    }

    private var isOpen: Bool {
        switch state {
        case .idle, .closed: return false
        case .requested, .armed, .captured:
            guard let deadline, now() < deadline else { close(); return false }
            return true
        }
    }

    private func close() {
        state = .closed
        deadline = nil
    }
}
#endif
