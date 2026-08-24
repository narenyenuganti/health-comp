import Foundation
import ComposableArchitecture
import Supabase
import XCTest
@testable import HealthComp

final class SupabaseConfigurationTests: XCTestCase {
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
        let storage = FailClosedAuthLocalStorage(underlying: underlying)
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
        let storage = FailClosedAuthLocalStorage(underlying: underlying)
        try storage.store(key: "session-key", value: Data("session".utf8))

        try storage.remove(key: "session-key")

        XCTAssertNoThrow(try storage.verifyLastRemoval())
        XCTAssertNil(try underlying.retrieve(key: "session-key"))
    }

    func testAuthStorageVerificationRequiresAFreshRemoval() throws {
        let storage = FailClosedAuthLocalStorage(
            underlying: AuthStorageStub()
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
            isRemovalPending: { pending.value },
            setRemovalPending: { pending.set($0) }
        )
        try storage.store(key: "session-key", value: Data("session".utf8))
        storage.prepareForRemovalVerification()

        let relaunchedStorage = FailClosedAuthLocalStorage(
            underlying: underlying,
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
        let storage = FailClosedAuthLocalStorage(underlying: underlying)
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
    private let removeFailure: Bool
    private var values: [String: Data] = [:]

    init(removeFailure: Bool = false) {
        self.removeFailure = removeFailure
    }

    func store(key: String, value: Data) throws {
        lock.withLock { values[key] = value }
    }

    func retrieve(key: String) throws -> Data? {
        lock.withLock { values[key] }
    }

    func remove(key: String) throws {
        if removeFailure {
            throw AuthenticationClientFailure.operationFailed
        }
        _ = lock.withLock { values.removeValue(forKey: key) }
    }
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
