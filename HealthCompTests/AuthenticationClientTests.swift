import Foundation
import XCTest
@testable import HealthComp

final class AuthenticationClientTests: XCTestCase {
    @MainActor
    func testAdapterRestoresNoSessionWithoutRefreshing() async throws {
        let recorder = AuthenticationOperationRecorder()
        let client = SupabaseAuthenticationClient.make(
            operations: .test(recorder: recorder, currentSession: nil),
            appleAuthorization: .unimplemented,
            now: { Date(timeIntervalSince1970: 100) }
        )

        let restored = try await client.restoreSession()

        XCTAssertNil(restored)
        let operations = await recorder.operations
        XCTAssertEqual(operations, ["currentSession"])
    }

    @MainActor
    func testAdapterRefreshesExpiredSessionBeforeRestoring() async throws {
        let recorder = AuthenticationOperationRecorder()
        let expired = SupabaseAuthenticationSession(
            userID: UUID(uuidString: "91000000-0000-4000-8000-000000000001")!,
            expiresAt: Date(timeIntervalSince1970: 99)
        )
        let refreshed = SupabaseAuthenticationSession(
            userID: expired.userID,
            expiresAt: Date(timeIntervalSince1970: 200)
        )
        let client = SupabaseAuthenticationClient.make(
            operations: .test(
                recorder: recorder,
                currentSession: expired,
                refreshResult: .success(refreshed)
            ),
            appleAuthorization: .unimplemented,
            now: { Date(timeIntervalSince1970: 100) }
        )

        let restored = try await client.restoreSession()
        XCTAssertEqual(
            restored,
            AuthenticationSession(
                userID: refreshed.userID,
                expiresAt: refreshed.expiresAt
            )
        )
        let operations = await recorder.operations
        XCTAssertEqual(
            operations,
            ["currentSession", "refreshSession"]
        )
    }

    @MainActor
    func testAdapterRefreshesSessionInsideSDKExpiryMargin() async throws {
        let recorder = AuthenticationOperationRecorder()
        let expiring = SupabaseAuthenticationSession(
            userID: UUID(uuidString: "91000000-0000-4000-8000-000000000001")!,
            expiresAt: Date(timeIntervalSince1970: 129)
        )
        let refreshed = SupabaseAuthenticationSession(
            userID: expiring.userID,
            expiresAt: Date(timeIntervalSince1970: 200)
        )
        let client = SupabaseAuthenticationClient.make(
            operations: .test(
                recorder: recorder,
                currentSession: expiring,
                refreshResult: .success(refreshed)
            ),
            appleAuthorization: .unimplemented,
            now: { Date(timeIntervalSince1970: 100) }
        )

        let restored = try await client.restoreSession()

        XCTAssertEqual(restored?.expiresAt, refreshed.expiresAt)
        let operations = await recorder.operations
        XCTAssertEqual(operations, ["currentSession", "refreshSession"])
    }

    @MainActor
    func testInvalidProviderFailsClosedWithoutFabricatingSignedOutEvent() async {
        let provider = SupabaseClientProvider.live(infoDictionary: { [:] })
        let client = SupabaseAuthenticationClient.live(
            provider: provider,
            appleAuthorization: .unimplemented
        )

        do {
            _ = try await client.restoreSession()
            XCTFail("Invalid configuration must not look like no session")
        } catch {
            XCTAssertEqual(
                error as? AuthenticationClientFailure,
                .operationFailed
            )
        }

        var events: [AuthenticationEvent] = []
        for await event in client.events() {
            events.append(event)
        }
        XCTAssertEqual(events, [])
    }

    @MainActor
    func testTerminalRefreshFailureClearsLocalSessionButRetryableDoesNot() async {
        let expired = SupabaseAuthenticationSession(
            userID: UUID(uuidString: "91000000-0000-4000-8000-000000000001")!,
            expiresAt: Date(timeIntervalSince1970: 99)
        )
        for expectedFailure in [
            AuthenticationClientFailure.terminalSession,
            .refreshRetryable,
        ] {
            let recorder = AuthenticationOperationRecorder()
            let client = SupabaseAuthenticationClient.make(
                operations: .test(
                    recorder: recorder,
                    currentSession: expired,
                    refreshResult: .failure(expectedFailure)
                ),
                appleAuthorization: .unimplemented,
                now: { Date(timeIntervalSince1970: 100) }
            )

            do {
                _ = try await client.restoreSession()
                XCTFail("Expected refresh failure")
            } catch {
                XCTAssertEqual(error as? AuthenticationClientFailure, expectedFailure)
            }
            let operations = await recorder.operations
            XCTAssertEqual(
                operations,
                expectedFailure == .terminalSession
                    ? ["currentSession", "refreshSession", "clearLocalSession"]
                    : ["currentSession", "refreshSession"]
            )
        }
    }

    @MainActor
    func testAppleExchangeUsesChallengeForAppleAndOriginalRawNonceForSupabase() async throws {
        let recorder = AuthenticationOperationRecorder()
        let token = identityToken(payload: ["nonce": "challenge"])
        let client = SupabaseAuthenticationClient.make(
            operations: .test(recorder: recorder),
            appleAuthorization: AppleAuthorizationClient { challenge in
                await recorder.record("apple:\(challenge)")
                return token
            },
            nonce: {
                AppleSignInNonce(rawValue: "raw-nonce", challenge: "challenge")
            },
            now: { Date(timeIntervalSince1970: 100) }
        )

        let session = try await client.signInWithApple()

        XCTAssertEqual(session.userID.uuidString, "91000000-0000-4000-8000-000000000002")
        let operations = await recorder.operations
        XCTAssertEqual(
            operations,
            ["apple:challenge", "exchange:\(String(decoding: token, as: UTF8.self)):raw-nonce"]
        )
    }

    func testAppleCancellationStatePersistsUntilAuthorizationStarts() {
        var state = AppleAuthorizationCancellationState()

        state.cancel()

        XCTAssertTrue(state.isCancelled)
    }

    @MainActor
    func testBootstrapForwardsNilThenExplicitDisplayName() async throws {
        let recorder = AuthenticationOperationRecorder()
        let client = SupabaseAuthenticationClient.make(
            operations: .test(recorder: recorder),
            appleAuthorization: .unimplemented
        )

        _ = try await client.bootstrapProfile(nil)
        _ = try await client.bootstrapProfile("Taylor")

        let operations = await recorder.operations
        XCTAssertEqual(
            operations,
            ["bootstrap:nil", "bootstrap:Taylor"]
        )
    }

    @MainActor
    func testProfileUpdateForwardsDisplayNameAndReturnsCanonicalProfile()
        async throws
    {
        let recorder = AuthenticationOperationRecorder()
        let client = SupabaseAuthenticationClient.make(
            operations: .test(
                recorder: recorder,
                canonicalUpdatedDisplayName: "Taylor Prime Canonical"
            ),
            appleAuthorization: .unimplemented
        )

        let profile = try await client.updateProfile("Taylor Prime")

        XCTAssertEqual(profile.displayName, "Taylor Prime Canonical")
        let operations = await recorder.operations
        XCTAssertEqual(operations, ["update:Taylor Prime"])
    }

    @MainActor
    func testSignOutIsBestEffortWhenSDKLogoutFailsAfterItsLocalRemoval() async {
        let recorder = AuthenticationOperationRecorder()
        let client = SupabaseAuthenticationClient.make(
            operations: .test(
                recorder: recorder,
                remoteSignOutFailure: AuthenticationClientFailure.operationFailed
            ),
            appleAuthorization: .unimplemented
        )

        await client.signOut()

        let operations = await recorder.operations
        XCTAssertEqual(
            operations,
            ["remoteSignOut"]
        )
    }

    func testNonceUsesThirtyTwoRandomBytesAndBase64URLWithoutPadding() throws {
        let nonce = try AppleSignInNonce.generate { byteCount in
            XCTAssertEqual(byteCount, 32)
            return Data(repeating: 0, count: byteCount)
        }

        XCTAssertEqual(nonce.rawValue, String(repeating: "A", count: 43))
        XCTAssertEqual(nonce.challenge.count, 64)
        XCTAssertTrue(nonce.challenge.allSatisfy {
            $0.isNumber || ("a"..."f").contains(String($0))
        })
    }

    func testNonceChallengeIsLowercaseSHA256Hex() {
        XCTAssertEqual(
            AppleSignInNonce.challenge(for: "raw-nonce"),
            "2c5d107938053a2275f022c153c9a71f65ee07754b8bca543ee97a0c3cc66990"
        )
    }

    func testIdentityTokenRejectsMissingInvalidAndMismatchedNonce() throws {
        XCTAssertThrowsError(
            try AppleIdentityTokenNonceValidator.validate(
                identityToken: nil,
                expectedChallenge: "expected"
            )
        ) { error in
            XCTAssertEqual(error as? AuthenticationClientFailure, .invalidCredential)
        }
        XCTAssertThrowsError(
            try AppleIdentityTokenNonceValidator.validate(
                identityToken: Data([0xff]),
                expectedChallenge: "expected"
            )
        ) { error in
            XCTAssertEqual(error as? AuthenticationClientFailure, .invalidCredential)
        }
        XCTAssertThrowsError(
            try AppleIdentityTokenNonceValidator.validate(
                identityToken: identityToken(payload: [:]),
                expectedChallenge: "expected"
            )
        ) { error in
            XCTAssertEqual(error as? AuthenticationClientFailure, .nonceMismatch)
        }
        XCTAssertThrowsError(
            try AppleIdentityTokenNonceValidator.validate(
                identityToken: identityToken(payload: ["nonce": "different"]),
                expectedChallenge: "expected"
            )
        ) { error in
            XCTAssertEqual(error as? AuthenticationClientFailure, .nonceMismatch)
        }
    }

    func testIdentityTokenReturnsUTF8TokenWhenNonceMatches() throws {
        let token = identityToken(payload: ["nonce": "expected"])

        XCTAssertEqual(
            try AppleIdentityTokenNonceValidator.validate(
                identityToken: token,
                expectedChallenge: "expected"
            ),
            String(decoding: token, as: UTF8.self)
        )
    }

    func testPublicAuthValuesEncodeOnlySafeIdentityAndPresentationFields() throws {
        let session = AuthenticationSession(
            userID: UUID(uuidString: "91000000-0000-4000-8000-000000000001")!,
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let profile = AuthenticatedProfile(
            id: UUID(uuidString: "92000000-0000-4000-8000-000000000001")!,
            displayName: "Taylor"
        )

        XCTAssertEqual(
            try jsonKeys(session),
            ["expires_at", "user_id"]
        )
        XCTAssertEqual(
            try jsonKeys(profile),
            ["display_name", "id"]
        )
        XCTAssertFalse(session.isExpired(at: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertTrue(session.isExpired(at: session.expiresAt))
    }

    func testProfileBootstrapErrorsMapToClosedAppOwnedFailures() {
        XCTAssertEqual(
            SupabaseAuthenticationClient.classifyBootstrapFailure(
                code: "P0001",
                message: "display_name_required"
            ),
            .displayNameRequired
        )
        XCTAssertEqual(
            SupabaseAuthenticationClient.classifyBootstrapFailure(
                code: "22023",
                message: "invalid_display_name"
            ),
            .invalidDisplayName
        )
        XCTAssertEqual(
            SupabaseAuthenticationClient.classifyBootstrapFailure(
                code: "42501",
                message: "authentication_required"
            ),
            .terminalSession
        )
        XCTAssertEqual(
            SupabaseAuthenticationClient.classifyBootstrapFailure(
                code: "XX000",
                message: "internal details must stay closed"
            ),
            .operationFailed
        )
    }

    private func identityToken(payload: [String: String]) -> Data {
        let header = Data(#"{"alg":"none"}"#.utf8).base64URLString
        let payload = try! JSONSerialization.data(withJSONObject: payload)
            .base64URLString
        return Data("\(header).\(payload).signature".utf8)
    }

    private func jsonKeys<Value: Encodable>(_ value: Value) throws -> [String] {
        let data = try JSONEncoder.healthCompAuth.encode(value)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return object.keys.sorted()
    }
}

private actor AuthenticationOperationRecorder {
    private(set) var operations: [String] = []

    func record(_ operation: String) {
        operations.append(operation)
    }
}

private extension SupabaseAuthenticationOperations {
    static func test(
        recorder: AuthenticationOperationRecorder,
        currentSession: SupabaseAuthenticationSession? = SupabaseAuthenticationSession(
            userID: UUID(uuidString: "91000000-0000-4000-8000-000000000001")!,
            expiresAt: Date(timeIntervalSince1970: 200)
        ),
        refreshResult: Result<SupabaseAuthenticationSession, AuthenticationClientFailure> = .success(
            SupabaseAuthenticationSession(
                userID: UUID(uuidString: "91000000-0000-4000-8000-000000000001")!,
                expiresAt: Date(timeIntervalSince1970: 200)
            )
        ),
        canonicalUpdatedDisplayName: String? = nil,
        remoteSignOutFailure: AuthenticationClientFailure? = nil
    ) -> Self {
        Self(
            currentSession: {
                await recorder.record("currentSession")
                return currentSession
            },
            refreshSession: {
                await recorder.record("refreshSession")
                return try refreshResult.get()
            },
            exchangeAppleIDToken: { token, rawNonce in
                await recorder.record("exchange:\(token):\(rawNonce)")
                return SupabaseAuthenticationSession(
                    userID: UUID(uuidString: "91000000-0000-4000-8000-000000000002")!,
                    expiresAt: Date(timeIntervalSince1970: 200)
                )
            },
            bootstrapProfile: { displayName in
                await recorder.record("bootstrap:\(displayName ?? "nil")")
                return AuthenticatedProfile(
                    id: UUID(uuidString: "92000000-0000-4000-8000-000000000001")!,
                    displayName: displayName ?? "Existing"
                )
            },
            updateProfile: { displayName in
                await recorder.record("update:\(displayName)")
                return AuthenticatedProfile(
                    id: UUID(uuidString: "92000000-0000-4000-8000-000000000001")!,
                    displayName: canonicalUpdatedDisplayName ?? displayName
                )
            },
            events: { AsyncStream { $0.finish() } },
            clearLocalSession: {
                await recorder.record("clearLocalSession")
            },
            remoteSignOut: {
                await recorder.record("remoteSignOut")
                if let remoteSignOutFailure { throw remoteSignOutFailure }
            },
            classifyRefreshFailure: { error in
                error as? AuthenticationClientFailure ?? .refreshRetryable
            }
        )
    }
}

private extension AppleAuthorizationClient {
    static let unimplemented = Self { _ in
        throw AuthenticationClientFailure.operationFailed
    }
}

private extension Data {
    var base64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
