import Foundation

/// One shared active client, with explicit admission after confirmed retirement.
/// The owner supplies retirement work; this registry does not certify its scope.
final class SharedClientLifetime<Client: AnyObject & Sendable>: @unchecked Sendable {
    enum Failure: Error, Equatable { case unavailable }
    private let lock = NSLock()
    private let makeClient: @Sendable () throws -> Client
    private var cachedClient: Client?
    private enum Phase { case active, retiring, retirementFailed, retired }
    private var phase: Phase = .active

    init(makeClient: @escaping @Sendable () throws -> Client) {
        self.makeClient = makeClient
    }

    func client() throws -> Client {
        try lock.withLock {
            guard phase == .active else { throw Failure.unavailable }
            return try activeClient()
        }
    }

    func beginFreshLifetime() throws -> Client {
        try lock.withLock {
            guard phase == .active || phase == .retired else {
                throw Failure.unavailable
            }
            phase = .active
            return try activeClient()
        }
    }

    /// The synchronous operation must not reenter this registry or escape work.
    func withActiveOwner<Result>(
        _ expected: Client,
        operation: () throws -> Result
    ) throws -> Result {
        try lock.withLock {
            guard phase == .active, cachedClient === expected else {
                throw Failure.unavailable
            }
            return try operation()
        }
    }

    func retire(
        _ expected: Client,
        confirming: @Sendable (Client) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try lock.withLock {
            guard cachedClient === expected,
                  phase == .active || phase == .retirementFailed else {
                throw Failure.unavailable
            }
            phase = .retiring
        }
        do {
            try await confirming(expected)
        } catch {
            lock.withLock { phase = .retirementFailed }
            throw error
        }
        // Confirmation owns its cancellation policy. Once it succeeds, do not
        // misreport settled retirement because this caller was later cancelled.
        lock.withLock {
            cachedClient = nil
            phase = .retired
        }
    }

    // Called only while holding lock. Construction must not reenter this owner.
    private func activeClient() throws -> Client {
        if let cachedClient { return cachedClient }
        let client = try makeClient()
        cachedClient = client
        return client
    }
}
