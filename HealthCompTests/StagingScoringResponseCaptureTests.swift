#if HEALTHCOMP_STAGING
import Foundation
import Supabase
import XCTest
@testable import HealthComp

final class StagingScoringResponseCaptureTests: XCTestCase {
    func testActualSharedClientCapturesOnceWithoutChangingSDKRejection() async throws {
        let fixture = ScoringCaptureFixture()
        defer { fixture.close() }
        let provider = fixture.provider()
        let client = try provider.client()
        try await fixture.reject(client)
        XCTAssertNil(try provider.takeStagingScoringResponseCapture())
        XCTAssertTrue(try provider.armStagingScoringResponseCapture())
        XCTAssertFalse(try provider.armStagingScoringResponseCapture())
        try await fixture.reject(client)
        XCTAssertTrue(try provider.takeStagingScoringResponseCapture() == ScoringCaptureProtocol.responseID)
        XCTAssertNil(try provider.takeStagingScoringResponseCapture())
        XCTAssertTrue(try provider.client() === client)
        try await provider.retireAuthenticationLifetime(provider.authenticationLifetime())
    }

    func testDefaultLiveTransportOffersAnExplicitDisabledCapture() async throws {
        let fixture = ScoringCaptureFixture()
        let provider = SupabaseClientProvider.live(infoDictionary: {
            ["SUPABASE_URL": "https://staging.invalid", "SUPABASE_PUBLISHABLE_KEY": "synthetic-public-key"]
        }, authStorage: FailClosedAuthLocalStorage(
            underlying: fixture.storage, sessionKey: { "sb-staging-auth-token" }
        ))
        let owner = try provider.authenticationLifetime()
        XCTAssertNil(try provider.takeStagingScoringResponseCapture())
        XCTAssertTrue(try provider.armStagingScoringResponseCapture())
        try await provider.retireAuthenticationLifetime(owner)
        XCTAssertThrowsError(try provider.armStagingScoringResponseCapture())
    }

    func testExpiryClearsIdleResponseWithoutRetiringTheClient() async throws {
        let fixture = ScoringCaptureFixture()
        defer { fixture.close() }
        let provider = fixture.provider()
        let owner = try provider.authenticationLifetime()
        XCTAssertTrue(try provider.armStagingScoringResponseCapture(timeout: .milliseconds(200)))
        try await fixture.reject(owner.client)
        XCTAssertTrue(fixture.observers[0].hasCapturedResponse)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(fixture.observers[0].hasCapturedResponse)
        XCTAssertNil(try provider.takeStagingScoringResponseCapture())
        XCTAssertFalse(try provider.armStagingScoringResponseCapture())
        XCTAssertTrue(try provider.client() === owner.client)
        try await provider.retireAuthenticationLifetime(owner)
    }

    func testCoordinatorRetiresCaptureAndAdmitsOnlyAnEmptyReplacement() async throws {
        let fixture = ScoringCaptureFixture()
        defer { fixture.close() }
        let provider = fixture.provider()
        let coordinator = SupabaseAuthenticationClientBox(provider: provider)
        let old = try await coordinator.client()
        XCTAssertTrue(try provider.armStagingScoringResponseCapture())
        try await fixture.reject(old)
        XCTAssertTrue(fixture.observers[0].hasCapturedResponse)
        try await coordinator.finishRetirement()
        XCTAssertFalse(fixture.observers[0].hasCapturedResponse)
        XCTAssertThrowsError(try provider.takeStagingScoringResponseCapture())
        let stoppedSession = try await coordinator.currentSession()
        XCTAssertNil(stoppedSession)
        try await coordinator.finishRetirement()
        XCTAssertEqual(fixture.observers.count, 1)
        let fresh = try await coordinator.beginAuthentication()
        XCTAssertFalse(fresh === old)
        XCTAssertNil(try provider.takeStagingScoringResponseCapture())
        XCTAssertTrue(try provider.armStagingScoringResponseCapture())
        try await fixture.reject(old)
        XCTAssertFalse(fixture.observers[0].hasCapturedResponse)
        XCTAssertFalse(fixture.observers[1].hasCapturedResponse)
        try await fixture.reject(fresh)
        XCTAssertTrue(try provider.takeStagingScoringResponseCapture() == ScoringCaptureProtocol.responseID)
        try await coordinator.finishRetirement()
    }

    func testFailedStorageRetirementClearsCaptureAndBlocksReplacementUntilRetry() async throws {
        let fixture = ScoringCaptureFixture()
        defer { fixture.close() }
        let provider = fixture.provider()
        let coordinator = SupabaseAuthenticationClientBox(provider: provider)
        let old = try await coordinator.client()
        XCTAssertTrue(try provider.armStagingScoringResponseCapture())
        try await fixture.reject(old)
        fixture.storage.setRemovalFailure(true)
        do {
            try await coordinator.finishRetirement()
            XCTFail("synthetic_storage_failure_must_block_retirement")
        } catch ScoringCaptureMemoryStorage.Failure.removal {}
        XCTAssertFalse(fixture.observers[0].hasCapturedResponse)
        XCTAssertThrowsError(try provider.armStagingScoringResponseCapture())
        do {
            _ = try await coordinator.beginAuthentication()
            XCTFail("failed_retirement_must_block_admission")
        } catch AuthenticationClientFailure.operationFailed {}
        XCTAssertEqual(fixture.observers.count, 1)
        fixture.storage.setRemovalFailure(false)
        try await coordinator.finishRetirement()
        let fresh = try await coordinator.beginAuthentication()
        XCTAssertFalse(fresh === old)
        XCTAssertEqual(fixture.observers.count, 2)
        XCTAssertNil(try provider.takeStagingScoringResponseCapture())
        try await coordinator.finishRetirement()
    }

    func testFailedRemoteConfirmationDoesNotAdmitCaptureOrAnotherOwner() async throws {
        let fixture = ScoringCaptureFixture()
        defer { fixture.close() }
        let provider = fixture.provider()
        let owner = try provider.authenticationLifetime()
        XCTAssertTrue(try provider.armStagingScoringResponseCapture())
        try await fixture.reject(owner.client)
        do {
            try await provider.retireAuthenticationLifetime(owner, beforeStorage: {
                throw AuthenticationClientFailure.operationFailed
            })
            XCTFail("synthetic_confirmation_failure_must_block_retirement")
        } catch AuthenticationClientFailure.operationFailed {}
        XCTAssertThrowsError(try provider.beginFreshAuthenticationLifetime())
        XCTAssertThrowsError(try provider.takeStagingScoringResponseCapture())
        XCTAssertThrowsError(try provider.armStagingScoringResponseCapture())
        XCTAssertEqual(fixture.observers.count, 1)
        try await provider.retireAuthenticationLifetime(owner)
        XCTAssertFalse(fixture.observers[0].hasCapturedResponse)
    }

    func testTwoMatchingSDKTasksDiscardAmbiguousCaptureWithoutChangingRequests() async throws {
        let fixture = ScoringCaptureFixture()
        defer { fixture.close() }
        let provider = fixture.provider()
        let owner = try provider.authenticationLifetime()
        XCTAssertTrue(try provider.armStagingScoringResponseCapture())
        try await fixture.reject(owner.client)
        try await fixture.reject(owner.client)
        XCTAssertNil(try provider.takeStagingScoringResponseCapture())
        XCTAssertFalse(fixture.observers[0].hasCapturedResponse)
        try await provider.retireAuthenticationLifetime(owner)
    }
}

private final class ScoringCaptureFixture: @unchecked Sendable {
    static let url = URL(string: "https://staging.invalid/functions/v1/submit-score-revision")!
    private let lock = NSLock()
    private var sessions: [URLSession] = []
    let storage = ScoringCaptureMemoryStorage()

    func provider() -> SupabaseClientProvider {
        .live(infoDictionary: {
            ["SUPABASE_URL": "https://staging.invalid", "SUPABASE_PUBLISHABLE_KEY": "synthetic-public-key"]
        }, authStorage: FailClosedAuthLocalStorage(
            underlying: storage, sessionKey: { "sb-staging-auth-token" }
        ), makeURLSession: { self.makeSession() })
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.protocolClasses = [ScoringCaptureProtocol.self]
        let session = URLSession(configuration: configuration,
            delegate: StagingScoringResponseCapture(scoringURL: Self.url), delegateQueue: nil)
        lock.withLock { sessions.append(session) }
        return session
    }

    func close() { lock.withLock { sessions }.forEach { $0.invalidateAndCancel() } }

    var observers: [StagingScoringResponseCapture] {
        lock.withLock { sessions.compactMap { $0.delegate as? StagingScoringResponseCapture } }
    }

    func reject(_ client: SupabaseClient, headers: [String: String] = [:]) async throws {
        do {
            try await client.functions.invoke("submit-score-revision",
                options: .init(headers: headers, body: Data("{}".utf8)))
            XCTFail("synthetic_unauthorized_request_must_throw")
        } catch FunctionsError.httpError(let code, let data) {
            XCTAssertEqual(code, 401)
            XCTAssertTrue(data == ScoringCaptureProtocol.body)
        }
    }
}

private final class ScoringCaptureMemoryStorage: AuthLocalStorage, @unchecked Sendable {
    enum Failure: Error { case removal }
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var removalFails = false
    func store(key: String, value: Data) { lock.withLock { values[key] = value } }
    func retrieve(key: String) -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws {
        try lock.withLock {
            guard !removalFails else { throw Failure.removal }
            _ = values.removeValue(forKey: key)
        }
    }
    func setRemovalFailure(_ fails: Bool) { lock.withLock { removalFails = fails } }
}

private final class ScoringCaptureProtocol: URLProtocol, @unchecked Sendable {
    static let responseID = "00000000-0000-4000-8000-000000000001"
    static let body = Data(#"{"code":"app_attest_proof_rejected"}"#.utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host?.hasSuffix(".invalid") == true else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: "HTTP/1.1",
            headerFields: ["sb-request-id": Self.responseID])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
