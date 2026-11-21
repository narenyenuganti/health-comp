import Foundation
import Supabase

final class SupabaseAuthStorageLifetime: AuthLocalStorage, @unchecked Sendable {
    enum Failure: Error, Equatable { case retiring, retired, unverifiedRemoval }
    private let underlying: any AuthLocalStorage
    private let lock = NSLock()
    private var isRetired = false
    private var writesClosed = false
    private let prepareRemoval: @Sendable () -> Void
    private let verifyRemoval: @Sendable () throws -> Void

    init(
        underlying: any AuthLocalStorage,
        prepareRemoval: @escaping @Sendable () -> Void = {},
        verifyRemoval: @escaping @Sendable () throws -> Void = {
            throw Failure.unverifiedRemoval
        }
    ) {
        self.underlying = underlying
        self.prepareRemoval = prepareRemoval
        self.verifyRemoval = verifyRemoval
    }

    func prepareForRemovalVerification() throws {
        try lock.withLock {
            guard !isRetired else { throw Failure.retired }
            writesClosed = true
            prepareRemoval()
        }
    }

    func verifyLastRemoval() throws {
        try lock.withLock {
            guard !isRetired else { throw Failure.retired }
            try verifyRemoval()
        }
    }

    func store(key: String, value: Data) throws {
        try lock.withLock {
            guard !isRetired else { throw Failure.retired }
            guard !writesClosed else { throw Failure.retiring }
            try underlying.store(key: key, value: value)
        }
    }

    func retrieve(key: String) throws -> Data? {
        try lock.withLock {
            guard !isRetired else { throw Failure.retired }
            return try underlying.retrieve(key: key)
        }
    }

    func remove(key: String) throws {
        try lock.withLock {
            guard !isRetired else { throw Failure.retired }
            try underlying.remove(key: key)
        }
    }

    func retire() {
        lock.withLock { isRetired = true }
    }

    func removeSessionAndRetire(removing: () throws -> Void) throws {
        try lock.withLock {
            guard !isRetired else { return }
            writesClosed = true
            prepareRemoval()
            try removing()
            try verifyRemoval()
            isRetired = true
        }
    }
}
