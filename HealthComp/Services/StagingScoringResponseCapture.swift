#if HEALTHCOMP_STAGING
import Foundation

/// Default-off, RAM-only diagnostic. It does not attribute a response to a UI action.
final class StagingScoringResponseCapture: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let scoringURL: URL
    private let now: @Sendable () -> ContinuousClock.Instant
    private enum State { case idle, armed, captured(String), closed }
    private var state: State = .idle
    private var deadline: ContinuousClock.Instant?
    private var matchingTask: Int?
    private var willObserveTask: (@Sendable () -> Void)?
    private var didObserveResponse: (@Sendable () -> Void)?
    private var didClose: (@Sendable () -> Void)?

    func connectOperator(
        willObserveTask: @escaping @Sendable () -> Void,
        didObserveResponse: @escaping @Sendable () -> Void,
        didClose: @escaping @Sendable () -> Void
    ) {
        lock.withLock {
            self.willObserveTask = willObserveTask
            self.didObserveResponse = didObserveResponse
            self.didClose = didClose
        }
    }

    init(
        scoringURL: URL,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.scoringURL = scoringURL
        self.now = now
    }

    func arm(timeout: Duration = .seconds(60)) -> Bool {
        lock.withLock {
            guard case .idle = state,
                  timeout > .zero, timeout <= .seconds(60),
                  scoringURL.scheme == "https", scoringURL.user == nil,
                  scoringURL.password == nil, scoringURL.port == nil,
                  scoringURL.query == nil, scoringURL.fragment == nil,
                  scoringURL.path == "/functions/v1/submit-score-revision" else { return false }
            state = .armed
            deadline = now() + timeout
            return true
        }
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        guard task.originalRequest?.httpMethod == "POST",
              task.originalRequest?.url == scoringURL else { return }
        lock.withLock { willObserveTask }?()
        let ambiguous = lock.withLock {
            guard isOpen else { return false }
            guard matchingTask == nil else {
                // Multiple matching tasks before retrieval are ambiguous, not failed requests.
                close()
                return true
            }
            matchingTask = task.taskIdentifier
            return false
        }
        if ambiguous { lock.withLock { didClose }?() }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard metrics.redirectCount == 0, task.error == nil,
              task.originalRequest?.httpMethod == "POST",
              task.originalRequest?.url == scoringURL,
              task.currentRequest?.url == scoringURL,
              let response = task.response as? HTTPURLResponse,
              response.url == scoringURL, response.statusCode == 401,
              let value = response.value(forHTTPHeaderField: "sb-request-id"),
              value.utf8.count == 36, let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value else { return }
        let captured = lock.withLock {
            guard isOpen, case .armed = state,
                  matchingTask == task.taskIdentifier else { return false }
            state = .captured(value)
            return true
        }
        if captured { lock.withLock { didObserveResponse }?() }
    }

    func take() -> String? {
        lock.withLock {
            if case .idle = state { return nil }
            defer { close() }
            guard isOpen, case let .captured(value) = state else { return nil }
            return value
        }
    }

    func cancel() {
        let callback = lock.withLock { close(); return didClose }
        callback?()
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        cancel()
    }

    var hasCapturedResponse: Bool {
        lock.withLock { if case .captured = state { return true }; return false }
    }

    // Called only under lock. The owner timer clears idle RAM; access also checks expiry.
    private var isOpen: Bool {
        switch state {
        case .idle, .closed: return false
        case .armed, .captured:
            guard let deadline, now() < deadline else { close(); return false }
            return true
        }
    }

    private func close() {
        state = .closed
        matchingTask = nil
        deadline = nil
    }
}
#endif
