import Foundation

final class AuthenticationLifetimeTasks: @unchecked Sendable {
    enum Failure: Error { case retired }
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var retired = false

    func start(_ operation: @escaping @Sendable () async -> Void) throws -> Task<Void, Never> {
        try lock.withLock {
            guard !retired else { throw Failure.retired }
            let id = UUID()
            let task = Task {
                await operation()
                self.lock.withLock { _ = self.tasks.removeValue(forKey: id) }
            }
            tasks[id] = task
            return task
        }
    }

    func cancelAndDrain() async {
        let pending = lock.withLock {
            retired = true
            return Array(tasks.values)
        }
        pending.forEach { $0.cancel() }
        for task in pending { await task.value }
    }
}
