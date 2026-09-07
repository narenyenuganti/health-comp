import Foundation
import CryptoKit
import Supabase
import XCTest
@testable import HealthComp

final class SupabaseAppleWebDeletionTransportTests: XCTestCase {
#if HEALTHCOMP_STAGING
    @MainActor
    func testCancelledBrowserPersistenceUsesLiveStorageAndConfirmsOnlyItsSessionLogout() async throws {
        try await assertCancelledPersistence(inBrowser: true, failure: .none)
    }

    @MainActor
    func testCancelledBrowserPersistenceRetriesFailedLogoutBeforeFreshAdmission() async throws {
        try await assertCancelledPersistence(inBrowser: true, failure: .remote)
    }

    @MainActor
    func testCancelledBrowserPersistenceRetriesStorageWithoutRepeatingConfirmedLogout() async throws {
        try await assertCancelledPersistence(inBrowser: true, failure: .storage)
    }

    @MainActor
    func testCancelledNativePersistenceUsesTheSameRetirementAndRetryBoundary() async throws {
        for failure in [CancellationFailure.none, .remote, .storage] {
            try await assertCancelledPersistence(inBrowser: false, failure: failure)
        }
    }

    private enum CancellationFailure { case none, remote, storage }

    @MainActor
    private func assertCancelledPersistence(inBrowser: Bool, failure: CancellationFailure) async throws {
        let session = try JSONSerialization.data(withJSONObject: [
            "access_token": "synthetic-cancelled-token", "refresh_token": "synthetic-refresh",
            "token_type": "bearer", "expires_in": 3600,
            "expires_at": Date().addingTimeInterval(3600).timeIntervalSince1970,
            "user": [
                "id": "12000000-0000-4000-8000-000000000001",
                "app_metadata": [:], "user_metadata": [:], "aud": "authenticated",
                "created_at": "2026-09-01T00:00:00Z", "updated_at": "2026-09-01T00:00:00Z",
            ] as [String: Any],
        ])
        let responses: [(Int, Data)] = failure == .remote
            ? [(200, session), (500, Data()), (204, Data())]
            : [(200, session), (204, Data())]
        let fixture = WebDeletionHTTPFixture(responses: responses)
        defer { fixture.close() }
        let pending = WebDeletionPendingFlag()
        let storage = WebDeletionMemoryStorage(onStore: { value in
            guard (try? JSONDecoder().decode(Session.self, from: value)) != nil else { return }
            withUnsafeCurrentTask { $0?.cancel() }
        })
        storage.setSessionRemovalFailure(failure == .storage)
        let guarded = FailClosedAuthLocalStorage(
            underlying: storage, sessionKey: { "sb-fixture-auth-token" },
            isRemovalPending: { pending.value }, setRemovalPending: { pending.set($0) }
        )
        let provider = fixture.liveProvider(storage: guarded)
        let owner = try provider.authenticationLifetime()
        var presentations = 0
        let authentication = SupabaseAuthenticationClient.live(
            provider: provider,
            appleAuthorization: .init(authorize: { nonce in
                presentations += 1
                if presentations > 1 { throw AuthenticationClientFailure.cancelled }
                let payload = try JSONSerialization.data(withJSONObject: ["nonce": nonce])
                    .base64EncodedString().replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
                return Data("e30.\(payload).synthetic-signature".utf8)
            }),
            infoDictionary: [
                "CFBundleIdentifier": "com.narenyenuganti.HealthComp.staging",
                "SUPABASE_URL": "https://xhfdfdrtxwptrwhvvlhg.supabase.co",
                "HEALTHCOMP_ENABLE_APPLE_WEB_SIGN_IN": "YES",
                "HEALTHCOMP_APPLE_WEB_CLIENT_ID": "com.example.staging.web",
            ], browser: .init(authenticate: { _, _ in
                presentations += 1
                if presentations > 1 { throw AppleWebAuthenticationSessionFailure.cancelled }
                return URL(string: "healthcomp-staging-auth://apple/callback?code=synthetic-owned-pkce-code")!
            })
        )
        let signIn = inBrowser
            ? try XCTUnwrap(authentication.signInWithAppleInBrowser)
            : authentication.signInWithApple
        do {
            _ = try await Task { try await signIn() }.value
            XCTFail("Cancelled persisted authentication must not return a session")
        } catch {
            XCTAssertEqual(error as? AuthenticationClientFailure, failure == .none ? .cancelled : .retirementRequired)
        }
        XCTAssertEqual(fixture.requests.map { $0.url?.path }, ["/auth/v1/token", "/auth/v1/logout"])
        XCTAssertEqual(fixture.requests.last?.url?.query, "scope=local")
        if failure != .none {
            XCTAssertTrue(pending.value)
            XCTAssertThrowsError(try provider.client())
            XCTAssertThrowsError(try provider.beginFreshAuthenticationLifetime())
            do {
                _ = try await authentication.restoreSession()
                XCTFail("A cancelled session with unfinished cleanup cannot be restored")
            } catch { XCTAssertEqual(error as? AuthenticationClientFailure, .retirementRequired) }
            do {
                _ = try await signIn()
                XCTFail("Fresh sign-in cannot bypass pending cleanup")
            } catch { XCTAssertEqual(error as? AuthenticationClientFailure, .retirementRequired) }
            XCTAssertEqual(presentations, 1)
            XCTAssertEqual(fixture.requests.count, 2)
            storage.setSessionRemovalFailure(false)
            try await XCTUnwrap(authentication.finishRetirement)()
        }
        XCTAssertNil(try storage.retrieve(key: "sb-fixture-auth-token"))
        XCTAssertNil(try storage.retrieve(key: "supabase.session"))
        XCTAssertFalse(pending.value)
        XCTAssertThrowsError(try owner.prepareAuthSessionRemovalVerification())
        let restored = try await authentication.restoreSession()
        XCTAssertNil(restored)
        do {
            _ = try await signIn()
            XCTFail("Fixture cancels the new browser presentation before any exchange")
        } catch { XCTAssertEqual(error as? AuthenticationClientFailure, .cancelled) }
        XCTAssertEqual(presentations, 2)
        XCTAssertFalse(try provider.client() === owner.client)
        let logouts = fixture.requests.filter { $0.url?.path == "/auth/v1/logout" }
        XCTAssertEqual(logouts.count, failure == .remote ? 2 : 1)
        XCTAssertTrue(logouts.allSatisfy {
            $0.url?.query == "scope=local"
                && $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-cancelled-token"
        })
    }

    @MainActor
    func testLiveBrowserSignInOwnsPKCECallbackAndNeverReplacesAnActiveSession() async throws {
        enum Outcome: CaseIterable { case success, wrongCallback, cancelled, activeSession, sessionAppears }
        for outcome in Outcome.allCases {
            let userID = UUID(uuidString: "12000000-0000-4000-8000-000000000001")!
            let session = try JSONSerialization.data(withJSONObject: [
                "access_token": "synthetic-browser-sign-in-token", "refresh_token": "synthetic-refresh",
                "token_type": "bearer", "expires_in": 3600,
                "expires_at": Date().addingTimeInterval(3600).timeIntervalSince1970,
                "user": [
                    "id": userID.uuidString,
                    "app_metadata": [:], "user_metadata": [:], "aud": "authenticated",
                    "created_at": "2026-09-01T00:00:00Z", "updated_at": "2026-09-01T00:00:00Z",
                ] as [String: Any],
            ])
            let fixture = WebDeletionHTTPFixture(responses: [(200, session)])
            defer { fixture.close() }
            let provider = fixture.provider()
            var challenge = ""
            var presentations = 0
            let client = SupabaseAuthenticationClient.live(
                provider: provider,
                infoDictionary: [
                    "CFBundleIdentifier": "com.narenyenuganti.HealthComp.staging",
                    "SUPABASE_URL": "https://xhfdfdrtxwptrwhvvlhg.supabase.co",
                    "HEALTHCOMP_ENABLE_APPLE_WEB_SIGN_IN": "YES",
                    "HEALTHCOMP_APPLE_WEB_CLIENT_ID": "com.example.staging.web",
                ], browser: .init(authenticate: { url, scheme in
                    presentations += 1
                    let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
                    let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                    XCTAssertEqual(url.path, "/auth/v1/authorize")
                    XCTAssertEqual(values["provider"], "apple")
                    XCTAssertEqual(values["redirect_to"], "healthcomp-staging-auth://apple/callback")
                    XCTAssertEqual(values["code_challenge_method"], "s256")
                    challenge = try XCTUnwrap(values["code_challenge"])
                    XCTAssertEqual(scheme, "healthcomp-staging-auth")
                    if outcome == .cancelled { throw AppleWebAuthenticationSessionFailure.cancelled }
                    if outcome == .sessionAppears {
                        _ = try await provider.client().auth.signInWithIdToken(
                            credentials: .init(provider: .apple, idToken: "synthetic-id-token")
                        )
                    }
                    let path = outcome == .wrongCallback ? "unowned" : "callback"
                    return URL(string: "healthcomp-staging-auth://apple/\(path)?code=synthetic-owned-pkce-code")!
                })
            )
            let signIn = try XCTUnwrap(client.signInWithAppleInBrowser)
            XCTAssertEqual(fixture.constructions, 0)
            if outcome == .activeSession {
                _ = try await provider.client().auth.signInWithIdToken(
                    credentials: .init(provider: .apple, idToken: "synthetic-id-token")
                )
            }
            do {
                let result = try await Task { try await signIn() }.value
                XCTAssertEqual(outcome, .success)
                XCTAssertEqual(result.userID, userID)
            } catch {
                XCTAssertNotEqual(outcome, .success)
                XCTAssertEqual(error as? AuthenticationClientFailure, outcome == .cancelled ? .cancelled : .operationFailed)
            }
            XCTAssertEqual(presentations, outcome == .activeSession ? 0 : 1)
            XCTAssertEqual(fixture.requests.count, outcome == .wrongCallback || outcome == .cancelled ? 0 : 1)
            XCTAssertEqual(fixture.preparationCount, 0)
            XCTAssertEqual(fixture.verificationCount, 0)
            let stored = try provider.client().auth.currentSession
            XCTAssertEqual(stored == nil, outcome == .wrongCallback || outcome == .cancelled)
            if outcome == .success {
                let body = try XCTUnwrap(try fixture.body(at: 0) as? [String: String])
                XCTAssertEqual(body["auth_code"], "synthetic-owned-pkce-code")
                let verifier = try XCTUnwrap(body["code_verifier"])
                let digest = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
                XCTAssertTrue(challenge == digest)
                XCTAssertEqual(fixture.requests.first?.url?.query, "grant_type=pkce")
            }
        }
    }

    @MainActor
    func testLiveFreshBrowserDeletionRequiresOwnedCallbackAndConfirmedReceipt() async throws {
        for outcome in 0..<4 {
            let id = String(repeating: "a", count: 64)
            let token = "synthetic-fresh-deletion-token"
            let session = try JSONSerialization.data(withJSONObject: [
                "access_token": token, "refresh_token": "synthetic-refresh",
                "token_type": "bearer", "expires_in": 3600,
                "expires_at": Date().addingTimeInterval(3600).timeIntervalSince1970,
                "user": [
                    "id": "12000000-0000-4000-8000-000000000001",
                    "app_metadata": [:], "user_metadata": [:], "aud": "authenticated",
                    "created_at": "2026-09-01T00:00:00Z", "updated_at": "2026-09-01T00:00:00Z",
                ] as [String: Any],
            ])
            let fixture = WebDeletionHTTPFixture(responses: [
                (200, session),
                (401, Data(#"{"error":"reauthentication_required"}"#.utf8)),
                (200, Data()),
                (outcome == 3 ? 202 : 200, Data(#"{"status":"deleted"}"#.utf8)),
            ], beginResponse: { data in
                let body = try JSONDecoder().decode([String: String].self, from: data)
                var url = URLComponents(string: "https://appleid.apple.com/auth/authorize")!
                url.queryItems = [
                    .init(name: "client_id", value: "com.example.staging.web"),
                    .init(name: "redirect_uri", value: "https://xhfdfdrtxwptrwhvvlhg.supabase.co/functions/v1/apple-deletion-callback"),
                    .init(name: "response_type", value: "code"),
                    .init(name: "response_mode", value: "form_post"),
                    .init(name: "state", value: String(repeating: "b", count: 64)),
                    .init(name: "nonce", value: body["nonce"]),
                ]
                return try JSONSerialization.data(withJSONObject: [
                    "request_id": id, "authorization_url": url.url!.absoluteString,
                ])
            })
            defer { fixture.close() }
            let provider = fixture.provider()
            let client = SupabaseAuthenticationClient.live(
                provider: provider,
                infoDictionary: [
                    "CFBundleIdentifier": "com.narenyenuganti.HealthComp.staging",
                    "SUPABASE_URL": "https://xhfdfdrtxwptrwhvvlhg.supabase.co",
                    "HEALTHCOMP_ENABLE_APPLE_WEB_SIGN_IN": "YES",
                    "HEALTHCOMP_APPLE_WEB_CLIENT_ID": "com.example.staging.web",
                ],
                browser: .init(authenticate: { url, scheme in
                    XCTAssertEqual(url.host, "appleid.apple.com")
                    XCTAssertEqual(scheme, "healthcomp-staging-auth")
                    if outcome == 1 { throw AppleWebAuthenticationSessionFailure.cancelled }
                    let callbackID = outcome == 2 ? String(repeating: "c", count: 64) : id
                    return URL(string: "healthcomp-staging-auth://apple/deletion-callback?request_id=\(callbackID)")!
                })
            )
            _ = try await provider.client().auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: "synthetic-id-token", nonce: "synthetic-nonce")
            )
            do {
                try await XCTUnwrap(client.deleteAccountInBrowser)()
                XCTAssertEqual(outcome, 0, "Unconfirmed deletion reported success")
            } catch {
                XCTAssertNotEqual(outcome, 0, "Confirmed deletion failed")
                XCTAssertEqual(error as? AuthenticationClientFailure, outcome == 1 ? .cancelled : .operationFailed)
            }
            XCTAssertEqual(fixture.constructions, 1)
            // This adapter returns a server receipt. Post-runtime retirement
            // belongs to AppFeature and must not happen inside this operation.
            XCTAssertEqual(fixture.preparationCount, 0)
            XCTAssertEqual(fixture.verificationCount, 0)
            XCTAssertNotNil(try provider.client().auth.currentSession)
            let begins = try XCTUnwrap(try fixture.body(at: 2) as? [String: String])
            XCTAssertEqual(Set(begins.keys), Set(["claim_verifier", "nonce"]))
            XCTAssertTrue(begins.values.allSatisfy {
                $0.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil
            })
            XCTAssertTrue(begins["claim_verifier"] != begins["nonce"])
            let count = outcome == 0 || outcome == 3 ? 4 : 3
            XCTAssertEqual(fixture.requests.count, count)
            XCTAssertTrue(fixture.requests.dropFirst().allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)"
            })
            if outcome == 0 || outcome == 3 {
                let claim = try XCTUnwrap(try fixture.body(at: 3) as? [String: String])
                XCTAssertTrue(claim == ["request_id": id, "claim_verifier": begins["claim_verifier"]!])
            }
        }
    }
#endif

    @MainActor
    func testLiveBrowserDeletionAvailabilityAndConfirmedResume() async throws {
        let token = "synthetic-live-deletion-access-token"
        let session = try JSONSerialization.data(withJSONObject: [
            "access_token": token, "refresh_token": "synthetic-refresh-token",
            "token_type": "bearer", "expires_in": 3600,
            "expires_at": Date().addingTimeInterval(3600).timeIntervalSince1970,
            "user": [
                "id": "12000000-0000-4000-8000-000000000001",
                "app_metadata": [:], "user_metadata": [:], "aud": "authenticated",
                "created_at": "2026-09-01T00:00:00Z", "updated_at": "2026-09-01T00:00:00Z",
            ] as [String: Any],
        ])
        let fixture = WebDeletionHTTPFixture(responses: [
            (200, session), (200, Data(#"{"status":"deleted"}"#.utf8)),
        ])
        defer { fixture.close() }
        let provider = fixture.provider()
        let browser = AppleWebAuthenticationSessionClient(authenticate: { _, _ in
            XCTFail("Confirmed resume must not open a browser")
            throw AppleWebAuthenticationSessionFailure.failed
        })
        let disabled = SupabaseAuthenticationClient.live(
            provider: provider, infoDictionary: [:], browser: browser
        )
        XCTAssertNil(disabled.deleteAccountInBrowser)
        XCTAssertNil(disabled.signInWithAppleInBrowser)
        XCTAssertEqual(fixture.constructions, 0)
        let client = SupabaseAuthenticationClient.live(
            provider: provider,
            infoDictionary: [
                "CFBundleIdentifier": "com.narenyenuganti.HealthComp.staging",
                "SUPABASE_URL": "https://xhfdfdrtxwptrwhvvlhg.supabase.co",
                "HEALTHCOMP_ENABLE_APPLE_WEB_SIGN_IN": "YES",
                "HEALTHCOMP_APPLE_WEB_CLIENT_ID": "com.example.staging.web",
            ], browser: browser
        )
        XCTAssertEqual(fixture.constructions, 0)
#if HEALTHCOMP_STAGING
        let deletion = try XCTUnwrap(client.deleteAccountInBrowser)
        _ = try await provider.client().auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: "synthetic-id-token", nonce: "synthetic-nonce")
        )
        try await deletion()
        XCTAssertNotNil(try provider.client().auth.currentSession)
        XCTAssertEqual(fixture.constructions, 1)
        XCTAssertEqual(fixture.preparationCount, 0)
        XCTAssertEqual(fixture.verificationCount, 0)
        XCTAssertEqual(fixture.requests.map { $0.url?.path }, [
            "/auth/v1/token", "/functions/v1/apple-deletion-complete",
        ])
        XCTAssertEqual(try fixture.body(at: 1) as? [String: Bool], ["resume": true])
        XCTAssertTrue(fixture.requests.dropFirst().allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)"
        })
#else
        XCTAssertNil(client.deleteAccountInBrowser)
        XCTAssertEqual(fixture.requests.count, 0)
#endif
    }

    @MainActor
    func testLiveDeletionPreservesConfirmationWhenRetirementIsUnavailable() async throws {
        let fixture = WebDeletionHTTPFixture(responses: [(200, Data(#"{"status":"deleted"}"#.utf8))])
        defer { fixture.close() }
        let client = SupabaseAuthenticationClient.live(
            provider: fixture.provider(),
            appleAuthorization: .init(
                authorize: { _ in nil },
                reauthorizeForDeletion: { _ in Data("synthetic-apple-deletion-code".utf8) }
            )
        )
        try await client.deleteAccount()
        do { try await XCTUnwrap(client.finishRetirement)(); XCTFail("Unconfigured storage retirement reported success") }
        catch { XCTAssertEqual(error as? AuthenticationClientFailure, .operationFailed) }
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(fixture.verificationCount, 0)
        XCTAssertEqual(fixture.preparationCount, 0)
    }

    func testExactEndpointBodiesUseOneSharedClient() async throws {
        let id = String(repeating: "a", count: 64)
        let verifier = String(repeating: "b", count: 64)
        let nonce = String(repeating: "c", count: 64)
        let accessToken = "synthetic-transport-access-token"
        let sessionBody = try JSONSerialization.data(withJSONObject: [
            "access_token": accessToken,
            "refresh_token": "synthetic-transport-refresh-token",
            "token_type": "bearer",
            "expires_in": 3600,
            "expires_at": Date().addingTimeInterval(3600).timeIntervalSince1970,
            "user": [
                "id": "12000000-0000-4000-8000-000000000001",
                "app_metadata": [:], "user_metadata": [:], "aud": "authenticated",
                "created_at": "2026-09-01T00:00:00Z", "updated_at": "2026-09-01T00:00:00Z",
            ] as [String: Any],
        ])
        let fixture = WebDeletionHTTPFixture(responses: [
            (200, sessionBody),
            (200, Data("{\"request_id\":\"\(id)\",\"authorization_url\":\"https://appleid.apple.com/auth/authorize\"}".utf8)),
            (200, Data(#"{"status":"deleted"}"#.utf8)),
            (200, Data(#"{"status":"deleted"}"#.utf8)),
        ])
        defer { fixture.close() }
        let provider = fixture.provider()
        _ = try await provider.client().auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: "synthetic-id-token", nonce: "synthetic-nonce")
        )
        let transport = SupabaseAppleWebDeletionTransport(provider: provider)
        let response = try await transport.begin(.init(claimVerifier: verifier, nonce: nonce))
        XCTAssertEqual(response.requestID, id)
        _ = try await transport.complete(.claim(requestID: id, verifier: verifier))
        _ = try await transport.complete(.resume)
        XCTAssertTrue(try provider.client() === provider.client())
        XCTAssertEqual(fixture.constructions, 1)
        let requests = fixture.requests
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/auth/v1/token",
            "/functions/v1/apple-deletion-begin", "/functions/v1/apple-deletion-complete",
            "/functions/v1/apple-deletion-complete",
        ])
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "POST" })
        XCTAssertTrue(requests.dropFirst().allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(accessToken)"
        })
        XCTAssertEqual(try fixture.body(at: 1) as? [String: String], ["claim_verifier": verifier, "nonce": nonce])
        XCTAssertEqual(try fixture.body(at: 2) as? [String: String], ["claim_verifier": verifier, "request_id": id])
        XCTAssertEqual(try fixture.body(at: 3) as? [String: Bool], ["resume": true])
    }

    func testOnlyExact401ReauthorizationMapsToFreshGrantSignal() async throws {
        for (status, body, expected) in [
            (401, #"{"error":"reauthentication_required"}"#, AppleWebAccountDeletionFailure.reauthenticationRequired),
            (403, #"{"error":"reauthentication_required"}"#, .invalidResponse),
            (401, #"{"error":"authentication_required"}"#, .invalidResponse),
            (202, #"{"status":"deleted"}"#, .invalidResponse),
        ] {
            let fixture = WebDeletionHTTPFixture(responses: [(status, Data(body.utf8))])
            defer { fixture.close() }
            let transport = SupabaseAppleWebDeletionTransport(provider: fixture.provider())
            do {
                _ = try await transport.complete(.resume)
                XCTFail("Unconfirmed deletion returned success")
            } catch let failure as AppleWebAccountDeletionFailure {
                XCTAssertEqual(failure, expected)
            }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }
}

private final class WebDeletionHTTPFixture: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registry: [String: WebDeletionHTTPFixture] = [:]
    private let lock = NSLock()
    private let id = UUID().uuidString
    private var responses: [(Int, Data)]
    private var captured: [URLRequest] = []
    private var bodies: [Data] = []
    private var count = 0
    private var verifications = 0
    private var preparations = 0
    private let session: URLSession
    private let beginResponse: (@Sendable (Data) throws -> Data)?

    init(responses: [(Int, Data)], beginResponse: (@Sendable (Data) throws -> Data)? = nil) {
        self.responses = responses
        self.beginResponse = beginResponse
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WebDeletionURLProtocol.self]
        session = URLSession(configuration: config)
        Self.registryLock.withLock { Self.registry[id] = self }
    }
    func close() {
        session.invalidateAndCancel()
        _ = Self.registryLock.withLock { Self.registry.removeValue(forKey: id) }
    }
    var constructions: Int { lock.withLock { count } }
    var verificationCount: Int { lock.withLock { verifications } }
    var preparationCount: Int { lock.withLock { preparations } }
    var requests: [URLRequest] { lock.withLock { captured } }
    func body(at index: Int) throws -> Any {
        try JSONSerialization.jsonObject(with: lock.withLock { bodies[index] })
    }
    func liveProvider(storage: FailClosedAuthLocalStorage) -> SupabaseClientProvider {
        .live(infoDictionary: {
            ["SUPABASE_URL": "https://fixture.\(self.id).invalid", "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_unit_fixture"]
        }, urlSession: session, authStorage: storage)
    }
    func provider() -> SupabaseClientProvider {
        SupabaseClientProvider(makeClient: {
            self.lock.withLock { self.count += 1 }
            return SupabaseClient(
                supabaseURL: URL(string: "https://fixture.invalid")!,
                supabaseKey: "sb_publishable_unit_fixture",
                options: .init(
                    auth: .init(storage: WebDeletionMemoryStorage(), autoRefreshToken: false),
                    global: .init(headers: ["x-healthcomp-unit-fixture": self.id], session: self.session)
                )
            )
        }, prepareAuthSessionRemovalVerification: {
            self.lock.withLock { self.preparations += 1 }
        }, verifyAuthSessionRemoved: {
            self.lock.withLock { self.verifications += 1 }
        })
    }
    static func respond(to request: URLRequest) throws -> (Int, Data) {
        let hostParts = request.url?.host?.split(separator: ".") ?? []
        let hostFixture = hostParts.count == 3 && hostParts.first == "fixture" && hostParts.last == "invalid"
            ? String(hostParts[1]) : ""
        let key = request.value(forHTTPHeaderField: "x-healthcomp-unit-fixture") ?? hostFixture
        guard let fixture = registryLock.withLock({ registry[key] }) else { throw URLError(.unsupportedURL) }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read >= 0, body.count + read <= 4096 else { throw URLError(.dataLengthExceedsMaximum) }
                if read == 0 { break }
                body.append(contentsOf: buffer.prefix(read))
            }
        }
        return try fixture.lock.withLock {
            fixture.captured.append(request)
            fixture.bodies.append(body)
            guard !fixture.responses.isEmpty else { throw URLError(.badServerResponse) }
            let response = fixture.responses.removeFirst()
            if request.url?.path == "/functions/v1/apple-deletion-begin",
               let beginResponse = fixture.beginResponse {
                return (response.0, try beginResponse(body))
            }
            return response
        }
    }
}

private final class WebDeletionURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, body) = try WebDeletionHTTPFixture.respond(to: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class WebDeletionMemoryStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var sessionRemovalFailure = false
    private let onStore: @Sendable (Data) -> Void
    init(onStore: @escaping @Sendable (Data) -> Void = { _ in }) { self.onStore = onStore }
    func store(key: String, value: Data) throws {
        lock.withLock { values[key] = value }
        onStore(value)
    }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func setSessionRemovalFailure(_ value: Bool) { lock.withLock { sessionRemovalFailure = value } }
    func remove(key: String) throws {
        try lock.withLock {
            if sessionRemovalFailure, key == "sb-fixture-auth-token" || key == "supabase.session" {
                throw AuthenticationClientFailure.operationFailed
            }
            values.removeValue(forKey: key)
        }
    }
}

private final class WebDeletionPendingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    var value: Bool { lock.withLock { pending } }
    func set(_ value: Bool) { lock.withLock { pending = value } }
}
