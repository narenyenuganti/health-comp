import Foundation
import XCTest
@testable import HealthComp

final class SupabaseAuthStorageLifetimeTests: XCTestCase {
    func testRetirementIntentRejectsLateWritesWhileRemovalCanStillBeRetried() throws {
        for prepareOnly in [true, false] {
            let underlying = SupabaseAuthKeychainStorage(service: "HealthCompTests.Lifetime.\(UUID())")
            let key = "synthetic-session"
            defer { try? underlying.remove(key: key); try? underlying.remove(key: "supabase.session") }
            let backing = FailClosedAuthLocalStorage(underlying: underlying, sessionKey: { key })
            let storage = SupabaseAuthStorageLifetime(
                underlying: backing,
                prepareRemoval: { backing.prepareForRemovalVerification() },
                verifyRemoval: { try backing.verifyLastRemoval() }
            )
            let original = Data("synthetic-original".utf8)
            try storage.store(key: key, value: original)
            if prepareOnly {
                try storage.prepareForRemovalVerification()
            } else {
                XCTAssertThrowsError(try storage.removeSessionAndRetire {
                    throw AuthenticationClientFailure.operationFailed
                })
            }
            XCTAssertThrowsError(try storage.store(key: key, value: Data("synthetic-late-write".utf8)))
            XCTAssertEqual(try underlying.retrieve(key: key), original)
            try storage.removeSessionAndRetire { try backing.removeCurrentSession() }
            XCTAssertNil(try underlying.retrieve(key: key))
            XCTAssertThrowsError(try storage.store(key: key, value: original))
        }
    }

    func testExplicitRetirementRemovesOnlySessionKeysAndCannotTouchReplacement() throws {
        let underlying = SupabaseAuthKeychainStorage(service: "HealthCompTests.Lifetime.\(UUID())")
        let key = "synthetic-session"
        let unrelated = "synthetic-unrelated-key"
        defer {
            try? underlying.remove(key: key)
            try? underlying.remove(key: "supabase.session")
            try? underlying.remove(key: unrelated)
        }
        let backing = FailClosedAuthLocalStorage(underlying: underlying, sessionKey: { key })
        let old = SupabaseAuthStorageLifetime(
            underlying: backing,
            prepareRemoval: { backing.prepareForRemovalVerification() },
            verifyRemoval: { try backing.verifyLastRemoval() }
        )
        let value = Data("synthetic-retiring-value".utf8)
        try old.store(key: key, value: value)
        try old.store(key: "supabase.session", value: value)
        try old.store(key: unrelated, value: value)
        try old.removeSessionAndRetire { try backing.removeCurrentSession() }
        XCTAssertNil(try underlying.retrieve(key: key))
        XCTAssertNil(try underlying.retrieve(key: "supabase.session"))
        XCTAssertEqual(try underlying.retrieve(key: unrelated), value)
        XCTAssertThrowsError(try old.store(key: key, value: value))
        XCTAssertThrowsError(try old.retrieve(key: key))
        XCTAssertThrowsError(try old.remove(key: key))

        let fresh = SupabaseAuthStorageLifetime(underlying: underlying)
        let replacement = Data("synthetic-replacement".utf8)
        try fresh.store(key: key, value: replacement)
        try old.removeSessionAndRetire {
            XCTFail("Repeated old-owner retirement must not run removal.")
            try backing.removeCurrentSession()
        }
        XCTAssertEqual(try fresh.retrieve(key: key), replacement)
    }

    func testExplicitRetirementVerifiesAnAlreadyEmptySessionWithoutSDKSignOut() throws {
        let underlying = SupabaseAuthKeychainStorage(service: "HealthCompTests.Lifetime.\(UUID())")
        let key = "synthetic-session"
        defer { try? underlying.remove(key: key); try? underlying.remove(key: "supabase.session") }
        let backing = FailClosedAuthLocalStorage(underlying: underlying, sessionKey: { key })
        let storage = SupabaseAuthStorageLifetime(
            underlying: backing,
            prepareRemoval: { backing.prepareForRemovalVerification() },
            verifyRemoval: { try backing.verifyLastRemoval() }
        )
        XCTAssertThrowsError(try backing.verifyLastRemoval())
        try storage.removeSessionAndRetire { try backing.removeCurrentSession() }
        XCTAssertNoThrow(try backing.verifyLastRemoval())
        XCTAssertThrowsError(try storage.retrieve(key: key))
    }

    func testMissingVerifierCannotConfirmStorageRetirement() throws {
        let underlying = SupabaseAuthKeychainStorage(service: "HealthCompTests.Lifetime.\(UUID())")
        let key = "synthetic-session"
        defer { try? underlying.remove(key: key) }
        let storage = SupabaseAuthStorageLifetime(underlying: underlying)
        let value = Data("synthetic-existing-value".utf8)
        try storage.store(key: key, value: value)
        XCTAssertThrowsError(try storage.verifyRemovalAndRetire())
        XCTAssertEqual(try storage.retrieve(key: key), value)
        XCTAssertEqual(try underlying.retrieve(key: key), value)
    }

    func testVerifiedRetirementClosesOldStorageWithoutTouchingNewOwner() throws {
        let underlying = SupabaseAuthKeychainStorage(service: "HealthCompTests.Lifetime.\(UUID())")
        let key = "synthetic-session"
        defer { try? underlying.remove(key: key) }
        let backing = FailClosedAuthLocalStorage(underlying: underlying, sessionKey: { key })
        let old = SupabaseAuthStorageLifetime(
            underlying: backing,
            prepareRemoval: { backing.prepareForRemovalVerification() },
            verifyRemoval: { try backing.verifyLastRemoval() }
        )
        try old.prepareForRemovalVerification()
        try old.remove(key: key)
        try old.verifyRemovalAndRetire()
        let fresh = SupabaseAuthStorageLifetime(underlying: underlying)
        let value = Data("synthetic-new-owner".utf8)
        try fresh.store(key: key, value: value)
        XCTAssertThrowsError(try old.store(key: key, value: Data()))
        XCTAssertThrowsError(try old.remove(key: key))
        XCTAssertThrowsError(try old.retrieve(key: key))
        XCTAssertNoThrow(try old.verifyRemovalAndRetire())
        XCTAssertEqual(try fresh.retrieve(key: key), value)
    }

    func testFailedVerificationAllowsCleanupRetryButDoesNotConfirmRetirement() throws {
        let underlying = SupabaseAuthKeychainStorage(service: "HealthCompTests.Lifetime.\(UUID())")
        let key = "synthetic-session"
        defer { try? underlying.remove(key: key) }
        let backing = FailClosedAuthLocalStorage(underlying: underlying, sessionKey: { key })
        let storage = SupabaseAuthStorageLifetime(
            underlying: backing,
            prepareRemoval: { backing.prepareForRemovalVerification() },
            verifyRemoval: { try backing.verifyLastRemoval() }
        )
        XCTAssertThrowsError(try storage.verifyRemovalAndRetire())
        try storage.prepareForRemovalVerification()
        try storage.remove(key: key)
        XCTAssertNoThrow(try storage.verifyRemovalAndRetire())
        XCTAssertThrowsError(try storage.store(key: key, value: Data()))
    }

    func testRetiredCleanupCannotResetOrVerifyBackingRemovalState() throws {
        let underlying = SupabaseAuthKeychainStorage(service: "HealthCompTests.Lifetime.\(UUID())")
        let key = "synthetic-session"
        defer { try? underlying.remove(key: key) }
        let backing = FailClosedAuthLocalStorage(underlying: underlying, sessionKey: { key })
        let storage = SupabaseAuthStorageLifetime(
            underlying: backing,
            prepareRemoval: { backing.prepareForRemovalVerification() },
            verifyRemoval: { try backing.verifyLastRemoval() }
        )
        XCTAssertThrowsError(try storage.verifyLastRemoval())
        try storage.store(key: key, value: Data("synthetic-value".utf8))
        try storage.prepareForRemovalVerification()
        try storage.remove(key: key)
        XCTAssertNoThrow(try storage.verifyLastRemoval())
        storage.retire()

        XCTAssertThrowsError(try storage.verifyLastRemoval()) {
            XCTAssertEqual($0 as? SupabaseAuthStorageLifetime.Failure, .retired)
        }
        XCTAssertThrowsError(try storage.prepareForRemovalVerification()) {
            XCTAssertEqual($0 as? SupabaseAuthStorageLifetime.Failure, .retired)
        }
        XCTAssertNoThrow(try backing.verifyLastRemoval())
    }

    func testRetirementIsScopedToItsOwnStorageAdapter() throws {
        let underlying = SupabaseAuthKeychainStorage(service: "HealthCompTests.Lifetime.\(UUID())")
        let key = "synthetic-session"
        defer { try? underlying.remove(key: key) }
        let first = SupabaseAuthStorageLifetime(underlying: underlying)
        let second = SupabaseAuthStorageLifetime(underlying: underlying)
        first.retire()
        let value = Data("synthetic-current-value".utf8)
        try second.store(key: key, value: value)

        first.retire()
        XCTAssertThrowsError(try first.remove(key: key))
        XCTAssertEqual(try second.retrieve(key: key), value)
        try second.remove(key: key)
        XCTAssertNil(try underlying.retrieve(key: key))
    }

    func testActiveLifetimePreservesStorageBehavior() throws {
        let underlying = SupabaseAuthKeychainStorage(service: "HealthCompTests.Lifetime.\(UUID())")
        let key = "synthetic-session"
        defer { try? underlying.remove(key: key) }
        let storage = SupabaseAuthStorageLifetime(underlying: underlying)
        let value = Data("synthetic-value".utf8)

        try storage.store(key: key, value: value)
        XCTAssertEqual(try storage.retrieve(key: key), value)
        try storage.remove(key: key)
        XCTAssertNil(try underlying.retrieve(key: key))
    }

    func testRetiredLifetimeRejectsEveryAccessWithoutChangingSharedStorage() throws {
        let underlying = SupabaseAuthKeychainStorage(service: "HealthCompTests.Lifetime.\(UUID())")
        let key = "synthetic-session"
        defer { try? underlying.remove(key: key) }
        let storage = SupabaseAuthStorageLifetime(underlying: underlying)
        let value = Data("synthetic-value".utf8)
        try underlying.store(key: key, value: value)

        storage.retire()
        storage.retire()
        XCTAssertThrowsError(try storage.retrieve(key: key)) {
            XCTAssertEqual($0 as? SupabaseAuthStorageLifetime.Failure, .retired)
        }
        XCTAssertThrowsError(try storage.store(key: key, value: Data())) {
            XCTAssertEqual($0 as? SupabaseAuthStorageLifetime.Failure, .retired)
        }
        XCTAssertThrowsError(try storage.remove(key: key)) {
            XCTAssertEqual($0 as? SupabaseAuthStorageLifetime.Failure, .retired)
        }
        XCTAssertEqual(try underlying.retrieve(key: key), value)
    }
}
