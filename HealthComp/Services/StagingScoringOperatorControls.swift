#if HEALTHCOMP_STAGING
import Foundation

final class StagingScoringCaptureOwner: Sendable {}

@objc(HealthCompStagingScoringOperator)
final class StagingScoringOperatorControls: NSObject, @unchecked Sendable {
    static let shared = StagingScoringOperatorControls()
    private let lock = NSLock()
    private let now: @Sendable () -> ContinuousClock.Instant
    private var owner: StagingScoringCaptureOwner?
    private enum State { case idle, requested, armed, captured(NSString), closed }
    private var state: State = .idle
    private var deadline: ContinuousClock.Instant?

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    func bind(_ owner: StagingScoringCaptureOwner) {
        lock.withLock {
            guard self.owner !== owner else { return }
            self.owner = owner
            state = .idle
            deadline = nil
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
            // Retrieval by the debugger, not transfer into this slot, ends ambiguity.
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
        lock.withLock { if self.owner === owner { close() } }
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
