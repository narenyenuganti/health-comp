import Foundation
import Supabase

/// One immutable client lifetime's access to storage; never reopened or reused.
/// Explicit session removal is separate from closure-only retirement. Neither
/// operation claims to settle SDK background tasks.
/// Underlying storage and cleanup callbacks must not reenter this adapter.
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

    func verifyRemovalAndRetire() throws {
        try lock.withLock {
            // Repeated retirement must not inspect the next owner's storage.
            guard !isRetired else { return }
            writesClosed = true
            try verifyRemoval()
            // No old callback can write between verification and closure.
            isRetired = true
        }
    }

    func removeSessionAndRetire(removing: () throws -> Void) throws {
        try lock.withLock {
            // A repeated old-owner request cannot touch a replacement's state.
            guard !isRetired else { return }
            // Intent closes writes permanently, including failed removal. A
            // delayed old callback cannot revive the cancelled session or clear
            // its pending-removal marker while cleanup awaits retry.
            writesClosed = true
            prepareRemoval()
            try removing()
            try verifyRemoval()
            // Removal, verification and closure exclude every old callback.
            isRetired = true
        }
    }
}
