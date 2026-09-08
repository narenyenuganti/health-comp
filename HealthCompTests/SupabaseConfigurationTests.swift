import Foundation
import ComposableArchitecture
import Supabase
import Security
import XCTest
@testable import HealthComp

private actor ProviderListenerSettlementBarrier {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait(entered: XCTestExpectation) async {
        await withCheckedContinuation {
            continuation = $0
            entered.fulfill()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class ProviderSessionFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [URLSession] = []

    func make() -> URLSession {
        let session = SupabaseTransport.makeSession()
        lock.withLock { sessions.append(session) }
        return session
    }

    var created: [URLSession] { lock.withLock { sessions } }
}

final class SupabaseConfigurationTests: XCTestCase {
    @MainActor
    func testLiveSignedOutAppStopAndRestartDoesNotAdmitAnotherLifetime() async {
        let session = SupabaseTransport.makeSession()
        defer { session.invalidateAndCancel() }
        let constructions = LockedCounter()
        let backing = FailClosedAuthLocalStorage(
            underlying: AuthStorageStub(), sessionKey: { "synthetic-session" }
        )
        let provider = SupabaseClientProvider.live(
            infoDictionary: { constructions.increment(); return self.dictionary() },
            urlSession: session, authStorage: backing
        )
        let authentication = SupabaseAuthenticationClient.live(provider: provider, infoDictionary: [:])
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() } withDependencies: {
            $0.authenticationClient = authentication
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.task)
        await store.finish()
        await store.skipReceivedActions(strict: false)
        XCTAssertEqual(store.state.phase, .signedOut)
        XCTAssertNil(store.state.pendingTeardown)
        XCTAssertEqual(constructions.value, 1)
        XCTAssertThrowsError(try provider.client())
        await store.send(.stop)
        await store.send(.task)
        await store.finish()
        await store.skipReceivedActions(strict: false)
        XCTAssertEqual(store.state.phase, .signedOut)
        XCTAssertNil(store.state.pendingTeardown)
        XCTAssertNil(store.state.account.message)
        XCTAssertEqual(constructions.value, 1)
        XCTAssertThrowsError(try provider.client())
        await store.send(.stop)
    }

    func testAuthenticationAdmissionRejectsAnAlreadyPopulatedLifetime() async throws {
        let session = SupabaseTransport.makeSession()
        defer { session.invalidateAndCancel() }
        let key = try SupabaseConfiguration.parse(dictionary()).authStorageKey
        let backing = FailClosedAuthLocalStorage(underlying: AuthStorageStub(), sessionKey: { key })
        let stored = try JSONSerialization.data(withJSONObject: [
            "access_token": "synthetic-existing-token", "refresh_token": "synthetic-refresh",
            "token_type": "bearer", "expires_in": 3600,
            "expires_at": Date().addingTimeInterval(3600).timeIntervalSince1970,
            "user": [
                "id": "12000000-0000-4000-8000-000000000001",
                "app_metadata": [:], "user_metadata": [:], "aud": "authenticated",
                "created_at": "2026-09-01T00:00:00Z", "updated_at": "2026-09-01T00:00:00Z",
            ] as [String: Any],
        ])
        try backing.store(key: key, value: stored)
        let provider = SupabaseClientProvider.live(
            infoDictionary: { self.dictionary() }, urlSession: session, authStorage: backing
        )
        let original = try provider.client()
        let initialSession = try XCTUnwrap(original.auth.currentSession)
        let coordinator = SupabaseAuthenticationClientBox(provider: provider)
        do {
            _ = try await coordinator.beginAuthentication()
            XCTFail("New authentication must not reuse an authenticated lifetime.")
        } catch { XCTAssertEqual(error as? AuthenticationClientFailure, .operationFailed) }
        XCTAssertTrue(try provider.client() === original)
        // Compare session semantics; SDK loading may normalize JSON encoding.
        XCTAssertEqual(original.auth.currentSession, initialSession)
        let restored = try await coordinator.currentSession()
        XCTAssertNotNil(restored)
    }

    @MainActor
    func testLiveAuthenticationRetiresThenRestoresWithoutAllocationAndAdmitsNativeSignIn() async throws {
        let recorder = SupabaseTransportStubURLProtocol.recorder
        recorder.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SupabaseTransportStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); recorder.reset() }
        let backing = FailClosedAuthLocalStorage(
            underlying: AuthStorageStub(), sessionKey: { "synthetic-session" }
        )
        let provider = SupabaseClientProvider.live(
            infoDictionary: { self.dictionary() }, urlSession: session, authStorage: backing
        )
        let authentication = SupabaseAuthenticationClient.live(
            provider: provider,
            appleAuthorization: .init(authorize: { challenge in
                let payload = try self.base64URL(["nonce": challenge])
                return Data("synthetic.\(payload).signature".utf8)
            }), infoDictionary: [:]
        )
        let original = try provider.client()
        let finish = try XCTUnwrap(authentication.finishRetirement)
        try await finish()
        XCTAssertThrowsError(try provider.client())
        let restored = try await authentication.restoreSession()
        XCTAssertNil(restored)
        XCTAssertThrowsError(try provider.client())
        XCTAssertTrue(recorder.requests.isEmpty)
        do {
            _ = try await authentication.signInWithApple()
            XCTFail("The local HTTP fixture rejects synthetic credentials.")
        } catch {}
        let fresh = try provider.client()
        XCTAssertFalse(fresh === original)
        XCTAssertEqual(recorder.requests, [.init(method: "POST", path: "/auth/v1/token")])
    }

    @MainActor
    func testLiveSignOutConfirmsServerOnceBeforeRetryableStorageRetirement() async throws {
        let recorder = SupabaseSignOutStubURLProtocol.recorder
        recorder.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SupabaseSignOutStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); recorder.reset() }
        let key = try SupabaseConfiguration.parse(dictionary()).authStorageKey
        let underlying = AuthStorageStub(removeFailure: true)
        let backing = FailClosedAuthLocalStorage(underlying: underlying, sessionKey: { key })
        let encodedSession = try JSONSerialization.data(withJSONObject: [
            "access_token": "synthetic-signout-token", "refresh_token": "synthetic-refresh",
            "token_type": "bearer", "expires_in": 3600,
            "expires_at": Date().addingTimeInterval(3600).timeIntervalSince1970,
            "user": [
                "id": "12000000-0000-4000-8000-000000000001",
                "app_metadata": [:], "user_metadata": [:], "aud": "authenticated",
                "created_at": "2026-09-01T00:00:00Z", "updated_at": "2026-09-01T00:00:00Z",
            ] as [String: Any],
        ])
        try backing.store(key: key, value: encodedSession)
        let provider = SupabaseClientProvider.live(
            infoDictionary: { self.dictionary() }, urlSession: session, authStorage: backing
        )
        let authentication = SupabaseAuthenticationClient.live(provider: provider, infoDictionary: [:])
        XCTAssertNotNil(try provider.client().auth.currentSession)
        try await authentication.signOut()
        XCTAssertEqual(recorder.requests, [.init(method: "POST", path: "/auth/v1/logout")])
        XCTAssertEqual(recorder.lastSecurityReceipt?.scope, "global")
        let finish = try XCTUnwrap(authentication.finishRetirement)
        do {
            try await finish()
            XCTFail("Failed storage removal must prevent retirement.")
        } catch {}
        XCTAssertThrowsError(try provider.client())
        underlying.setRemovalFailure(false)
        try await finish()
        XCTAssertNil(try underlying.retrieve(key: key))
        XCTAssertThrowsError(try provider.client())
        XCTAssertEqual(recorder.requests, [.init(method: "POST", path: "/auth/v1/logout")])
    }

    func testProviderRetiresAnEmptySessionWithoutAnSDKSignOutOrNetworkRequest() async throws {
        SupabaseTransportStubURLProtocol.recorder.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SupabaseTransportStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); SupabaseTransportStubURLProtocol.recorder.reset() }
        let backing = FailClosedAuthLocalStorage(
            underlying: AuthStorageStub(), sessionKey: { "synthetic-session" }
        )
        let provider = SupabaseClientProvider.live(
            infoDictionary: { self.dictionary() }, urlSession: session, authStorage: backing
        )
        let owner = try provider.authenticationLifetime()
        XCTAssertNil(owner.client.auth.currentSession)
        XCTAssertThrowsError(try backing.verifyLastRemoval())
        try await provider.retireAuthenticationLifetime(owner)
        XCTAssertNoThrow(try backing.verifyLastRemoval())
        XCTAssertThrowsError(try provider.client())
        XCTAssertTrue(SupabaseTransportStubURLProtocol.recorder.requests.isEmpty)
    }

    func testExplicitStorageRetirementPreservesFailedLegacyRemovalTombstoneUntilRetry() throws {
        let underlying = AuthStorageStub(removeFailureKeys: ["supabase.session"])
        let key = "synthetic-session"
        let pending = LockedFlag()
        let backing = FailClosedAuthLocalStorage(
            underlying: underlying, sessionKey: { key },
            isRemovalPending: { pending.value }, setRemovalPending: { pending.set($0) }
        )
        let storage = SupabaseAuthStorageLifetime(
            underlying: backing,
            prepareRemoval: { backing.prepareForRemovalVerification() },
            verifyRemoval: { try backing.verifyLastRemoval() }
        )
        let value = Data("synthetic-session-value".utf8)
        try storage.store(key: key, value: value)
        try storage.store(key: "supabase.session", value: value)
        XCTAssertThrowsError(try storage.removeSessionAndRetire { try backing.removeCurrentSession() })
        XCTAssertTrue(pending.value)
        XCTAssertEqual(try underlying.retrieve(key: "supabase.session"), value)
        let reconstructed = FailClosedAuthLocalStorage(
            underlying: underlying, sessionKey: { key },
            isRemovalPending: { pending.value }, setRemovalPending: { pending.set($0) }
        )
        XCTAssertNil(try reconstructed.retrieve(key: key))
        XCTAssertNil(try reconstructed.retrieve(key: "supabase.session"))
        XCTAssertTrue(pending.value)
        underlying.setRemovalFailureKeys([])
        try storage.removeSessionAndRetire { try backing.removeCurrentSession() }
        XCTAssertFalse(pending.value)
        XCTAssertNil(try underlying.retrieve(key: key))
        XCTAssertNil(try underlying.retrieve(key: "supabase.session"))
        XCTAssertThrowsError(try storage.store(key: key, value: value))
    }

    func testAuthenticationCoordinatorWaitsForListenerSettlementBeforeReplacement() async throws {
        let session = SupabaseTransport.makeSession()
        defer { session.invalidateAndCancel() }
        let backing = FailClosedAuthLocalStorage(
            underlying: AuthStorageStub(), sessionKey: { "synthetic-session" }
        )
        let provider = SupabaseClientProvider.live(
            infoDictionary: { self.dictionary() }, urlSession: session, authStorage: backing
        )
        let coordinator = SupabaseAuthenticationClientBox(provider: provider)
        let first = try await coordinator.beginAuthentication()
        let owner = try provider.authenticationLifetime()
        let started = expectation(description: "listener started")
        let held = expectation(description: "listener cancelled but unsettled")
        let returned = expectation(description: "retirement returned before settlement")
        returned.isInverted = true
        let barrier = ProviderListenerSettlementBarrier()
        let (events, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        _ = try owner.eventTasks.start {
            started.fulfill()
            for await _ in events {}
            await barrier.wait(entered: held)
        }
        await fulfillment(of: [started], timeout: 1)
        try owner.prepareAuthSessionRemovalVerification()
        try backing.remove(key: "synthetic-session")
        let retiring = Task {
            try await coordinator.finishRetirement()
            returned.fulfill()
        }
        await fulfillment(of: [held], timeout: 1)
        do {
            _ = try await coordinator.client()
            XCTFail("Ordinary access must remain closed while retiring.")
        } catch {}
        do {
            _ = try await coordinator.beginAuthentication()
            XCTFail("Authentication must wait for listener settlement.")
        } catch {}
        do {
            try await coordinator.finishRetirement()
            XCTFail("Concurrent retirement must not claim completion.")
        } catch {}
        retiring.cancel()
        await fulfillment(of: [returned], timeout: 0.2)
        await barrier.release()
        try await retiring.value
        let fresh = try await coordinator.beginAuthentication()
        XCTAssertFalse(fresh === first)
        let shared = try await coordinator.client()
        XCTAssertTrue(shared === fresh)
    }

    func testAuthenticationCoordinatorRetainsFailedOwnerUntilSuccessfulRetry() async throws {
        let session = SupabaseTransport.makeSession()
        defer { session.invalidateAndCancel() }
        let underlying = AuthStorageStub(removeFailure: true)
        let backing = FailClosedAuthLocalStorage(
            underlying: underlying, sessionKey: { "synthetic-session" }
        )
        let provider = SupabaseClientProvider.live(
            infoDictionary: { self.dictionary() }, urlSession: session, authStorage: backing
        )
        let coordinator = SupabaseAuthenticationClientBox(provider: provider)
        let first = try await coordinator.beginAuthentication()
        let owner = try provider.authenticationLifetime()
        XCTAssertTrue(first === owner.client)
        do {
            try await coordinator.finishRetirement()
            XCTFail("Failed removal must not complete retirement.")
        } catch {}
        XCTAssertThrowsError(try provider.client())
        do {
            _ = try await coordinator.beginAuthentication()
            XCTFail("Failed retirement must not admit authentication.")
        } catch {}

        // The retry must retain this owner; ordinary provider access is closed.
        underlying.setRemovalFailure(false)
        do {
            try await coordinator.finishRetirement()
        } catch {
            XCTFail("Retirement retry lost its original owner: \(type(of: error))")
            return
        }
        XCTAssertThrowsError(try provider.client())
        try await coordinator.finishRetirement()
        XCTAssertThrowsError(try provider.client())
        let fresh = try await coordinator.beginAuthentication()
        XCTAssertFalse(fresh === first)
        XCTAssertTrue(try provider.client() === fresh)
        let repeated = try await coordinator.beginAuthentication()
        XCTAssertTrue(repeated === fresh)
        XCTAssertThrowsError(try owner.prepareAuthSessionRemovalVerification())
    }

    func testHTTPTransportIsLazyAndAllocatedOncePerAdmittedOwner() async throws {
        let factory = ProviderSessionFactoryProbe()
        defer { factory.created.forEach { $0.invalidateAndCancel() } }
        let backing = FailClosedAuthLocalStorage(
            underlying: AuthStorageStub(), sessionKey: { "synthetic-session" }
        )
        let provider = SupabaseClientProvider.live(
            infoDictionary: { self.dictionary() }, authStorage: backing,
            makeURLSession: { factory.make() }
        )
        XCTAssertEqual(factory.created.count, 0)
        let first = try provider.authenticationLifetime()
        XCTAssertEqual(factory.created.count, 1)
        XCTAssertTrue(try provider.client() === first.client)
        XCTAssertEqual(factory.created.count, 1)
        try first.prepareAuthSessionRemovalVerification()
        try backing.remove(key: "synthetic-session")
        try await provider.retireAuthenticationLifetime(first)
        XCTAssertEqual(factory.created.count, 1)
        let second = try provider.beginFreshAuthenticationLifetime()
        XCTAssertFalse(second === first)
        let sessions = factory.created
        XCTAssertEqual(sessions.count, 2)
        if sessions.count == 2 { XCTAssertFalse(sessions[0] === sessions[1]) }
        XCTAssertTrue(try provider.client() === second.client)
        XCTAssertEqual(factory.created.count, 2)
    }

    func testProviderKeepsAdmissionClosedUntilCancelledListenerActuallySettles() async throws {
        let session = SupabaseTransport.makeSession()
        defer { session.invalidateAndCancel() }
        let backing = FailClosedAuthLocalStorage(
            underlying: AuthStorageStub(), sessionKey: { "synthetic-session" }
        )
        let provider = SupabaseClientProvider.live(
            infoDictionary: { self.dictionary() }, urlSession: session, authStorage: backing
        )
        let owner = try provider.authenticationLifetime()
        let started = expectation(description: "listener running")
        let held = expectation(description: "cancelled listener still settling")
        let returned = expectation(description: "retirement returned before listener settlement")
        returned.isInverted = true
        let barrier = ProviderListenerSettlementBarrier()
        let (events, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        _ = try owner.eventTasks.start {
            started.fulfill()
            for await _ in events {}
            await barrier.wait(entered: held)
        }
        await fulfillment(of: [started], timeout: 1)
        try owner.prepareAuthSessionRemovalVerification()
        try backing.remove(key: "synthetic-session")
        let retiring = Task {
            try await provider.retireAuthenticationLifetime(owner)
            returned.fulfill()
        }
        await fulfillment(of: [held], timeout: 1)
        XCTAssertThrowsError(try provider.client())
        XCTAssertThrowsError(try provider.beginFreshAuthenticationLifetime())
        retiring.cancel()
        await fulfillment(of: [returned], timeout: 0.2)
        await barrier.release()
        try await retiring.value
        XCTAssertFalse(try provider.beginFreshAuthenticationLifetime() === owner)
        XCTAssertThrowsError(try owner.prepareAuthSessionRemovalVerification())
    }

    func testProviderRetirementClosesStorageAndDrainsListenersBeforeFreshAdmission() async throws {
        let session = SupabaseTransport.makeSession()
        defer { session.invalidateAndCancel() }
        let backing = FailClosedAuthLocalStorage(
            underlying: AuthStorageStub(), sessionKey: { "synthetic-session" }
        )
        let provider = SupabaseClientProvider.live(
            infoDictionary: { self.dictionary() }, urlSession: session, authStorage: backing
        )
        let owner = try provider.authenticationLifetime()
        let started = expectation(description: "owned listener started")
        let cancelled = expectation(description: "owned listener cancelled")
        let (events, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let listener = try owner.eventTasks.start {
            await withTaskCancellationHandler {
                started.fulfill()
                for await _ in events {}
            } onCancel: { cancelled.fulfill() }
        }
        await fulfillment(of: [started], timeout: 1)
        try owner.prepareAuthSessionRemovalVerification()
        try backing.remove(key: "synthetic-session")
        try await provider.retireAuthenticationLifetime(owner)
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertThrowsError(try provider.client())
        XCTAssertThrowsError(try owner.prepareAuthSessionRemovalVerification())
        XCTAssertThrowsError(try owner.eventTasks.start {})
        let fresh = try provider.beginFreshAuthenticationLifetime()
        XCTAssertFalse(fresh === owner)
        XCTAssertFalse(fresh.client === owner.client)
        XCTAssertTrue(try provider.client() === fresh.client)
        listener.cancel()
        continuation.finish()
        await listener.value
    }

    func testProviderFailedRetirementBlocksAccessAndFreshAdmissionUntilRetry() async throws {
        let session = SupabaseTransport.makeSession()
        defer { session.invalidateAndCancel() }
        let underlying = AuthStorageStub(removeFailure: true)
        let backing = FailClosedAuthLocalStorage(
            underlying: underlying, sessionKey: { "synthetic-session" }
        )
        let provider = SupabaseClientProvider.live(
            infoDictionary: { self.dictionary() }, urlSession: session, authStorage: backing
        )
        let owner = try provider.authenticationLifetime()
        do {
            try await provider.retireAuthenticationLifetime(owner)
            XCTFail("Failed removal must not retire the owner.")
        } catch {}
        XCTAssertThrowsError(try provider.client())
        XCTAssertThrowsError(try provider.beginFreshAuthenticationLifetime())
        underlying.setRemovalFailure(false)
        try await provider.retireAuthenticationLifetime(owner)
        XCTAssertFalse(try provider.beginFreshAuthenticationLifetime() === owner)
    }

    func testProviderSharesOneAuthenticationOwnerWithItsClient() throws {
        let session = SupabaseTransport.makeSession()
        defer { session.invalidateAndCancel() }
        let storage = FailClosedAuthLocalStorage(
            underlying: AuthStorageStub(), sessionKey: { "synthetic-session" }
        )
        let provider = SupabaseClientProvider.live(
            infoDictionary: { self.dictionary() },
            urlSession: session,
            authStorage: storage
        )
        let owner = try provider.authenticationLifetime()
        XCTAssertTrue(try provider.authenticationLifetime() === owner)
        XCTAssertTrue(try provider.client() === owner.client)
    }

    func testActualKeychainMissingReadAndRemovalAreAbsence() throws {
        let service = "healthcomp.unit.auth-storage.\(UUID().uuidString)"
        // Diagnose the test host's Keychain availability using only an OSStatus,
        // never the value or attributes of any existing Keychain item.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "missing-session",
        ]
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecItemNotFound)
        let storage = SupabaseAuthKeychainStorage(service: service)
        XCTAssertNil(try storage.retrieve(key: "missing-session"))
        XCTAssertNoThrow(try storage.remove(key: "missing-session"))
    }

    func testKeychainAbsenceNormalizationPreservesOtherFailures() throws {
        XCTAssertNil(try SupabaseAuthKeychainStorage.readResult(
            status: errSecItemNotFound, data: nil
        ))
        XCTAssertNoThrow(try SupabaseAuthKeychainStorage.verifyRemovalStatus(errSecItemNotFound))
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecDecode, errSecParam] {
            XCTAssertThrowsError(try SupabaseAuthKeychainStorage.readResult(status: status, data: nil))
            XCTAssertThrowsError(try SupabaseAuthKeychainStorage.verifyRemovalStatus(status))
        }
        XCTAssertThrowsError(try SupabaseAuthKeychainStorage.readResult(status: errSecSuccess, data: nil))
        XCTAssertEqual(try SupabaseAuthKeychainStorage.readResult(
            status: errSecSuccess, data: Data("synthetic".utf8)
        ), Data("synthetic".utf8))
    }

    func testActualKeychainCanReplaceAndRetireSessionWithNoLegacyItem() throws {
        let underlying = SupabaseAuthKeychainStorage(
            service: "healthcomp.unit.auth-storage.\(UUID().uuidString)"
        )
        defer { try? underlying.remove(key: "session-key") }
        let pending = LockedFlag()
        let storage = FailClosedAuthLocalStorage(
            underlying: underlying,
            sessionKey: { "session-key" },
            isRemovalPending: { pending.value },
            setRemovalPending: { pending.set($0) }
        )
        storage.prepareForRemovalVerification()
        try storage.store(key: "session-key", value: Data("synthetic".utf8))
        XCTAssertFalse(pending.value)
        XCTAssertEqual(try storage.retrieve(key: "session-key"), Data("synthetic".utf8))
        storage.prepareForRemovalVerification()
        try storage.remove(key: "session-key")
        try storage.verifyLastRemoval()
        XCTAssertFalse(pending.value)
        XCTAssertNil(try underlying.retrieve(key: "session-key"))
    }

    func testLiveSupabaseTransportIsEphemeralAndNonPersistent() {
        let session = SupabaseTransport.makeSession()
        defer { session.invalidateAndCancel() }

        let configuration = session.configuration
        XCTAssertEqual(
            configuration.requestCachePolicy,
            .reloadIgnoringLocalCacheData
        )
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
    }

    func testLiveProviderUsesInjectedTransportSession() async throws {
        let recorder = SupabaseTransportStubURLProtocol.recorder
        recorder.reset()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            SupabaseTransportStubURLProtocol.self,
        ]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            recorder.reset()
        }
        let provider = SupabaseClientProvider.live(
            infoDictionary: { self.dictionary() },
            urlSession: session
        )
        let client = try provider.client()

        do {
            _ = try await client.auth.refreshSession(
                refreshToken: "synthetic-refresh-value"
            )
            XCTFail("The stubbed HTTP 400 response must fail refresh.")
        } catch {
            // The request receipt below is the behavior under test.
        }

        XCTAssertEqual(
            recorder.requests,
            [
                RecordedTransportRequest(
                    method: "POST",
                    path: "/auth/v1/token"
                ),
            ]
        )
    }

    func testLiveProviderSharesOneClientAcrossConsumers() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let provider = SupabaseClientProvider.live(
            infoDictionary: { self.dictionary() },
            urlSession: session
        )
        let authenticationProvider = provider
        let competitionProvider = provider

        let authenticationClient = try authenticationProvider.client()
        let competitionClient = try competitionProvider.client()

        XCTAssertTrue(authenticationClient === competitionClient)
    }

    func testAuthStorageVerificationRejectsADeletionFailure() throws {
        let underlying = AuthStorageStub(removeFailure: true)
        let storage = FailClosedAuthLocalStorage(underlying: underlying, sessionKey: { "session-key" })
        try storage.store(key: "session-key", value: Data("session".utf8))

        XCTAssertThrowsError(try storage.remove(key: "session-key"))
        XCTAssertThrowsError(try storage.verifyLastRemoval()) { error in
            XCTAssertEqual(
                error as? AuthenticationClientFailure,
                .operationFailed
            )
        }
    }

    func testAuthStorageVerificationConfirmsDurableDeletion() throws {
        let underlying = AuthStorageStub()
        let storage = FailClosedAuthLocalStorage(underlying: underlying, sessionKey: { "session-key" })
        try storage.store(key: "session-key", value: Data("session".utf8))

        try storage.remove(key: "session-key")

        XCTAssertNoThrow(try storage.verifyLastRemoval())
        XCTAssertNil(try underlying.retrieve(key: "session-key"))
    }

    func testAuthStorageVerificationRequiresAFreshRemoval() throws {
        let storage = FailClosedAuthLocalStorage(
            underlying: AuthStorageStub(),
            sessionKey: { "session-key" }
        )
        try storage.store(key: "session-key", value: Data("session".utf8))
        try storage.remove(key: "session-key")
        try storage.verifyLastRemoval()

        storage.prepareForRemovalVerification()

        XCTAssertThrowsError(try storage.verifyLastRemoval())
    }

    func testPendingAuthRemovalSuppressesStaleSessionAcrossRelaunch() throws {
        let underlying = AuthStorageStub(removeFailure: true)
        let pending = LockedFlag()
        let storage = FailClosedAuthLocalStorage(
            underlying: underlying,
            sessionKey: { "session-key" },
            isRemovalPending: { pending.value },
            setRemovalPending: { pending.set($0) }
        )
        try storage.store(key: "session-key", value: Data("session".utf8))
        storage.prepareForRemovalVerification()

        let relaunchedStorage = FailClosedAuthLocalStorage(
            underlying: underlying,
            sessionKey: { "session-key" },
            isRemovalPending: { pending.value },
            setRemovalPending: { pending.set($0) }
        )

        XCTAssertNil(try relaunchedStorage.retrieve(key: "session-key"))
        XCTAssertTrue(pending.value)
        XCTAssertNotNil(try underlying.retrieve(key: "session-key"))
    }

    func testVerifiedAuthRemovalClearsPendingTombstone() throws {
        let pending = LockedFlag()
        let storage = FailClosedAuthLocalStorage(
            underlying: AuthStorageStub(),
            sessionKey: { "session-key" },
            isRemovalPending: { pending.value },
            setRemovalPending: { pending.set($0) }
        )
        try storage.store(key: "session-key", value: Data("session".utf8))
        storage.prepareForRemovalVerification()
        try storage.remove(key: "session-key")

        try storage.verifyLastRemoval()

        XCTAssertFalse(pending.value)
    }

    func testLiveProviderExposesItsAuthRemovalVerification() throws {
        let underlying = AuthStorageStub()
        let storage = FailClosedAuthLocalStorage(underlying: underlying, sessionKey: { "session-key" })
        let provider = SupabaseClientProvider.live(
            infoDictionary: { self.dictionary() },
            urlSession: URLSession(configuration: .ephemeral),
            authStorage: storage
        )
        _ = try provider.client()
        try storage.store(key: "session-key", value: Data("session".utf8))
        try storage.remove(key: "session-key")

        XCTAssertNoThrow(try provider.verifyAuthSessionRemoved())
    }

    func testPKCEVerifierWriteCannotClearPendingSessionRemoval() throws {
        let underlying = AuthStorageStub(removeFailure: true)
        let pending = LockedFlag()
        let storage = FailClosedAuthLocalStorage(
            underlying: underlying,
            sessionKey: { "session-key" },
            isRemovalPending: { pending.value },
            setRemovalPending: { pending.set($0) }
        )
        try storage.store(key: "session-key", value: Data("session".utf8))
        storage.prepareForRemovalVerification()

        try storage.store(
            key: "session-key-code-verifier",
            value: Data("synthetic-verifier".utf8)
        )

        XCTAssertTrue(pending.value)
        XCTAssertNil(try storage.retrieve(key: "session-key"))
        XCTAssertNotNil(try underlying.retrieve(key: "session-key"))
        XCTAssertThrowsError(try storage.verifyLastRemoval())
    }

    func testMissingPKCEVerifierReadCannotClearPendingSessionRemoval() throws {
        let underlying = AuthStorageStub(removeFailureKeys: ["session-key"])
        let pending = LockedFlag()
        let storage = FailClosedAuthLocalStorage(
            underlying: underlying,
            sessionKey: { "session-key" },
            isRemovalPending: { pending.value },
            setRemovalPending: { pending.set($0) }
        )
        try storage.store(key: "session-key", value: Data("session".utf8))
        storage.prepareForRemovalVerification()

        XCTAssertNil(try storage.retrieve(key: "session-key-code-verifier"))

        XCTAssertTrue(pending.value)
        XCTAssertNil(try storage.retrieve(key: "session-key"))
        XCTAssertNotNil(try underlying.retrieve(key: "session-key"))
    }

    func testPKCEVerifierRemovalCannotReplaceFailedSessionRemovalEvidence() throws {
        let underlying = AuthStorageStub(removeFailureKeys: ["session-key"])
        let storage = FailClosedAuthLocalStorage(underlying: underlying, sessionKey: { "session-key" })
        try storage.store(key: "session-key", value: Data("session".utf8))
        XCTAssertThrowsError(try storage.remove(key: "session-key"))

        try storage.remove(key: "session-key-code-verifier")

        XCTAssertThrowsError(try storage.verifyLastRemoval())
        XCTAssertNotNil(try underlying.retrieve(key: "session-key"))
    }

    func testActualSDKPKCEPreparationCannotClearPendingSessionRemoval() throws {
        let underlying = AuthStorageStub(removeFailureKeys: ["session-key"])
        let pending = LockedFlag()
        let storage = FailClosedAuthLocalStorage(
            underlying: underlying,
            sessionKey: { "session-key" },
            isRemovalPending: { pending.value },
            setRemovalPending: { pending.set($0) }
        )
        try storage.store(key: "session-key", value: Data("session".utf8))
        storage.prepareForRemovalVerification()
        let auth = AuthClient(configuration: .init(
            url: URL(string: "https://fixture.invalid/auth/v1")!,
            flowType: .pkce,
            storageKey: "session-key",
            localStorage: storage,
            fetch: { _ in throw AuthenticationClientFailure.operationFailed },
            autoRefreshToken: false
        ))

        _ = try auth.getOAuthSignInURL(
            provider: .apple,
            redirectTo: URL(string: "healthcomp-staging-auth://apple/callback")!
        )

        XCTAssertTrue(pending.value)
        XCTAssertNotNil(try underlying.retrieve(key: "session-key-code-verifier"))
        XCTAssertNil(try storage.retrieve(key: "session-key"))
        XCTAssertNotNil(try underlying.retrieve(key: "session-key"))
    }

    func testLegacySessionCannotBypassPendingRemovalDuringSDKMigration() throws {
        let underlying = AuthStorageStub(removeFailure: true)
        let pending = LockedFlag()
        let storage = FailClosedAuthLocalStorage(
            underlying: underlying,
            sessionKey: { "session-key" },
            isRemovalPending: { pending.value },
            setRemovalPending: { pending.set($0) }
        )
        try underlying.store(key: "supabase.session", value: Data("legacy".utf8))
        storage.prepareForRemovalVerification()

        XCTAssertNil(try storage.retrieve(key: "supabase.session"))
        XCTAssertTrue(pending.value)
        XCTAssertNotNil(try underlying.retrieve(key: "supabase.session"))
    }

    func testSessionRemovalAlsoRetiresLegacySessionMigrationSource() throws {
        let underlying = AuthStorageStub()
        let storage = FailClosedAuthLocalStorage(
            underlying: underlying,
            sessionKey: { "session-key" }
        )
        try storage.store(key: "session-key", value: Data("session".utf8))
        try underlying.store(key: "supabase.session", value: Data("legacy".utf8))

        try storage.remove(key: "session-key")

        XCTAssertNoThrow(try storage.verifyLastRemoval())
        XCTAssertNil(try underlying.retrieve(key: "supabase.session"))
    }

    func testFreshSessionCannotReactivateLegacyAfterFailedRemoval() throws {
        let underlying = AuthStorageStub(removeFailureKeys: ["supabase.session"])
        let pending = LockedFlag()
        let storage = FailClosedAuthLocalStorage(
            underlying: underlying,
            sessionKey: { "session-key" },
            isRemovalPending: { pending.value },
            setRemovalPending: { pending.set($0) }
        )
        try underlying.store(key: "supabase.session", value: Data("retired".utf8))
        storage.prepareForRemovalVerification()
        XCTAssertNil(try storage.retrieve(key: "supabase.session"))

        XCTAssertThrowsError(try storage.store(key: "session-key", value: Data("new".utf8)))

        XCTAssertTrue(pending.value)
        XCTAssertNil(try storage.retrieve(key: "supabase.session"))
        XCTAssertNil(try storage.retrieve(key: "session-key"))
    }

    func testFreshSessionRetiresLegacyBeforeClearingPendingRemoval() throws {
        let underlying = AuthStorageStub()
        let pending = LockedFlag()
        let storage = FailClosedAuthLocalStorage(
            underlying: underlying,
            sessionKey: { "session-key" },
            isRemovalPending: { pending.value },
            setRemovalPending: { pending.set($0) }
        )
        try underlying.store(key: "supabase.session", value: Data("retired".utf8))
        storage.prepareForRemovalVerification()

        try storage.store(key: "session-key", value: Data("new".utf8))

        XCTAssertFalse(pending.value)
        XCTAssertNil(try underlying.retrieve(key: "supabase.session"))
        XCTAssertEqual(try storage.retrieve(key: "session-key"), Data("new".utf8))
    }

    func testLiveProviderConfirmsGlobalSignOutBeforeLocalRemoval() async throws {
        let recorder = SupabaseSignOutStubURLProtocol.recorder
        recorder.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            SupabaseSignOutStubURLProtocol.self,
        ]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            recorder.reset()
        }
        let provider = SupabaseClientProvider.live(
            infoDictionary: { self.dictionary() },
            urlSession: session
        )

        try await provider.confirmGlobalSignOut(
            accessToken: "synthetic-access-token"
        )

        XCTAssertEqual(
            recorder.requests,
            [
                RecordedTransportRequest(
                    method: "POST",
                    path: "/auth/v1/logout"
                ),
            ]
        )
        XCTAssertEqual(
            recorder.lastSecurityReceipt,
            TransportSecurityReceipt(
                scope: "global",
                hasAuthorization: true,
                hasAPIKey: true
            )
        )
    }

    func testParsesValidPublishableConfiguration() throws {
        let configuration = try SupabaseConfiguration.parse([
            "SUPABASE_URL": "  https://project-ref.supabase.co  ",
            "SUPABASE_PUBLISHABLE_KEY": "  sb_publishable_test-fixture  ",
        ])

        XCTAssertEqual(
            configuration.url,
            URL(string: "https://project-ref.supabase.co")
        )
        XCTAssertEqual(
            configuration.publishableKey,
            "sb_publishable_test-fixture"
        )
    }

    func testRejectsMissingOrWhitespaceURL() {
        for value in [nil, "", "   "] {
            XCTAssertThrowsError(
                try SupabaseConfiguration.parse(dictionary(url: value))
            ) { error in
                XCTAssertEqual(error as? SupabaseConfigurationError, .missingURL)
            }
        }
    }

    func testRejectsMalformedOrHostlessURL() {
        for value in ["not a url", "https:", "https:///rest/v1"] {
            XCTAssertThrowsError(
                try SupabaseConfiguration.parse(dictionary(url: value))
            ) { error in
                XCTAssertEqual(error as? SupabaseConfigurationError, .invalidURL)
            }
        }
    }

    func testRejectsNonHTTPSURL() {
        XCTAssertThrowsError(
            try SupabaseConfiguration.parse(
                dictionary(url: "http://project-ref.supabase.co")
            )
        ) { error in
            XCTAssertEqual(error as? SupabaseConfigurationError, .insecureURL)
        }
    }

    func testRejectsPlaceholderURL() {
        for value in [
            "https://example.com",
            "https://your-project.supabase.co",
            "$(SUPABASE_URL)",
        ] {
            XCTAssertThrowsError(
                try SupabaseConfiguration.parse(dictionary(url: value))
            ) { error in
                XCTAssertEqual(error as? SupabaseConfigurationError, .placeholderURL)
            }
        }
    }

    func testRejectsMissingOrWhitespacePublishableKey() {
        for value in [nil, "", "   "] {
            XCTAssertThrowsError(
                try SupabaseConfiguration.parse(dictionary(key: value))
            ) { error in
                XCTAssertEqual(
                    error as? SupabaseConfigurationError,
                    .missingPublishableKey
                )
            }
        }
    }

    func testRejectsPlaceholderPublishableKey() {
        for value in [
            "your-publishable-key",
            "replace-me",
            "$(SUPABASE_PUBLISHABLE_KEY)",
        ] {
            XCTAssertThrowsError(
                try SupabaseConfiguration.parse(dictionary(key: value))
            ) { error in
                XCTAssertEqual(
                    error as? SupabaseConfigurationError,
                    .placeholderPublishableKey
                )
            }
        }
    }

    func testRejectsSecretKeyPrefix() {
        let secretPrefix = "sb_" + "secret_"
        XCTAssertThrowsError(
            try SupabaseConfiguration.parse(
                dictionary(key: secretPrefix + "private-test-value")
            )
        ) { error in
            XCTAssertEqual(
                error as? SupabaseConfigurationError,
                .serviceRolePublishableKey
            )
        }
    }

    func testRejectsJWTWithServiceRolePayload() throws {
        let header = try base64URL(["alg": "HS256", "typ": "JWT"])
        let payload = try base64URL(["role": "service" + "_role"])
        let key = "\(header).\(payload).signature"

        XCTAssertThrowsError(
            try SupabaseConfiguration.parse(dictionary(key: key))
        ) { error in
            XCTAssertEqual(
                error as? SupabaseConfigurationError,
                .serviceRolePublishableKey
            )
        }
    }

    func testConfigurationErrorsNeverExposeSecretInput() {
        let secret = "sb_" + "secret_" + "never-print-this-value"

        XCTAssertThrowsError(
            try SupabaseConfiguration.parse(dictionary(key: secret))
        ) { error in
            XCTAssertFalse(String(describing: error).contains(secret))
        }
    }

#if DEBUG
    @MainActor
    func testTestLabCreatesNoAuthGraphAndOrdinaryLaunchInjectsOneLazyAdapter()
        async
    {
        let clientCreationCount = LockedCounter()
        let adapterCreationCount = LockedCounter()
        let competitionAdapterCreationCount = LockedCounter()
        let restoreCount = LockedCounter()
        let poisonedProvider = SupabaseClientProvider {
            clientCreationCount.increment()
            fatalError("Supabase client must be lazy")
        }
        let authenticationClientFactory = AuthenticationClientFactory {
            _ in
            adapterCreationCount.increment()
            return AuthenticationClient(
                restoreSession: {
                    restoreCount.increment()
                    return nil
                },
                signInWithApple: {
                    throw AuthenticationClientFailure.operationFailed
                },
                bootstrapProfile: { _ in
                    throw AuthenticationClientFailure.operationFailed
                },
                events: { AsyncStream { $0.finish() } },
                signOut: {}
            )
        }
        let competitionClientFactory = CompetitionClientFactory { _ in
            competitionAdapterCreationCount.increment()
            return .testValue
        }

        var labLaunchCount = 0
        for fixture in CompetitionTestLabFixtureKind.allCases {
            for direction in ["incoming", "outgoing"] {
                for journalMode in ["unique", "persistent"] {
                    var arguments = [
                        "HealthComp",
                        "--local-competition-test-lab",
                        "--local-competition-fixture", fixture.rawValue,
                        "--local-competition-direction", direction,
                    ]
                    if journalMode == "persistent" {
                        arguments += [
                            "--local-competition-run-id",
                            "supabase-poison-\(labLaunchCount)",
                        ]
                    }
                    _ = HealthCompApp(
                        arguments: arguments,
                        supabaseClientProvider: poisonedProvider,
                        authenticationClientFactory:
                            authenticationClientFactory,
                        competitionClientFactory: competitionClientFactory
                    )
                    labLaunchCount += 1
                }
            }
        }
        _ = HealthCompApp(
            arguments: [
                "HealthComp",
                "--local-competition-test-lab",
                "--local-competition-fixture",
                "not-a-fixture",
            ],
            supabaseClientProvider: poisonedProvider,
            authenticationClientFactory: authenticationClientFactory,
            competitionClientFactory: competitionClientFactory
        )

        XCTAssertEqual(labLaunchCount, 28)
        XCTAssertEqual(adapterCreationCount.value, 0)
        XCTAssertEqual(competitionAdapterCreationCount.value, 0)
        XCTAssertEqual(clientCreationCount.value, 0)

        _ = HealthCompApp(
            arguments: ["HealthComp"],
            supabaseClientProvider: poisonedProvider,
            authenticationClientFactory: authenticationClientFactory,
            competitionClientFactory: competitionClientFactory
        )

        XCTAssertEqual(adapterCreationCount.value, 1)
        XCTAssertEqual(competitionAdapterCreationCount.value, 1)
        XCTAssertEqual(clientCreationCount.value, 0)

        let store = HealthCompLiveComposition.store(
            supabaseClientProvider: poisonedProvider,
            authenticationClientFactory: authenticationClientFactory,
            competitionClientFactory: competitionClientFactory
        )
        await store.send(.task).finish()
        XCTAssertEqual(adapterCreationCount.value, 2)
        XCTAssertEqual(competitionAdapterCreationCount.value, 2)
        XCTAssertEqual(restoreCount.value, 1)
        XCTAssertEqual(clientCreationCount.value, 0)
        XCTAssertEqual(store.phase, .signedOut)
    }
#endif

    private func dictionary(
        url: String? = "https://project-ref.supabase.co",
        key: String? = "sb_publishable_test-fixture"
    ) -> [String: Any] {
        var result: [String: Any] = [:]
        result["SUPABASE_URL"] = url
        result["SUPABASE_PUBLISHABLE_KEY"] = key
        return result
    }

    private func base64URL(_ object: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class AuthStorageStub: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var removeFailure: Bool
    private var removeFailureKeys: Set<String>
    private var values: [String: Data] = [:]

    init(removeFailure: Bool = false, removeFailureKeys: Set<String> = []) {
        self.removeFailure = removeFailure
        self.removeFailureKeys = removeFailureKeys
    }

    func store(key: String, value: Data) throws {
        lock.withLock { values[key] = value }
    }

    func retrieve(key: String) throws -> Data? {
        lock.withLock { values[key] }
    }

    func remove(key: String) throws {
        try lock.withLock {
            if removeFailure || removeFailureKeys.contains(key) {
                throw AuthenticationClientFailure.operationFailed
            }
            values.removeValue(forKey: key)
        }
    }

    func setRemovalFailure(_ fails: Bool) { lock.withLock { removeFailure = fails } }
    func setRemovalFailureKeys(_ keys: Set<String>) { lock.withLock { removeFailureKeys = keys } }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set(_ value: Bool) {
        lock.withLock { storage = value }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private struct RecordedTransportRequest: Equatable, Sendable {
    let method: String?
    let path: String?
}

private struct TransportSecurityReceipt: Equatable, Sendable {
    let scope: String?
    let hasAuthorization: Bool
    let hasAPIKey: Bool
}

private final class LockedTransportRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [RecordedTransportRequest] = []
    private var securityReceipt: TransportSecurityReceipt?

    var requests: [RecordedTransportRequest] {
        lock.withLock { recordedRequests }
    }

    var lastSecurityReceipt: TransportSecurityReceipt? {
        lock.withLock { securityReceipt }
    }

    func record(_ request: URLRequest) {
        lock.withLock {
            recordedRequests.append(
                RecordedTransportRequest(
                    method: request.httpMethod,
                    path: request.url?.path
                )
            )
            let scope = URLComponents(
                url: request.url!,
                resolvingAgainstBaseURL: false
            )?.queryItems?.first(where: { $0.name == "scope" })?.value
            securityReceipt = TransportSecurityReceipt(
                scope: scope,
                hasAuthorization:
                    request.value(forHTTPHeaderField: "Authorization") != nil,
                hasAPIKey: request.value(forHTTPHeaderField: "apikey") != nil
            )
        }
    }

    func reset() {
        lock.withLock {
            recordedRequests.removeAll()
            securityReceipt = nil
        }
    }
}

private final class SupabaseTransportStubURLProtocol: URLProtocol {
    static let recorder = LockedTransportRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.recorder.record(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 400,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(
            self,
            didLoad: Data(#"{"error":"invalid_grant"}"#.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class SupabaseSignOutStubURLProtocol: URLProtocol {
    static let recorder = LockedTransportRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.recorder.record(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 204,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
