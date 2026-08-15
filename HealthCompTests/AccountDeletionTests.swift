import ComposableArchitecture
import Foundation
import XCTest
@testable import HealthComp

final class AccountDeletionTests: XCTestCase {
    @MainActor
    func testDeleteCancellationLeavesAuthenticatedAccountUntouched() async {
        let store = TestStore(
            initialState: AccountFeature.State(
                mode: .authenticated,
                displayName: "Taylor"
            )
        ) {
            AccountFeature()
        }

        await store.send(.deleteAccountButtonTapped) {
            $0.isDeleteConfirmationPresented = true
        }
        await store.send(.deleteAccountConfirmationCancelled) {
            $0.isDeleteConfirmationPresented = false
        }
        XCTAssertFalse(store.state.isRequestInFlight)
        XCTAssertFalse(store.state.isDeletingAccount)
    }

    @MainActor
    func testDeleteConfirmationRequiresReauthenticationDelegate() async {
        let store = TestStore(
            initialState: AccountFeature.State(
                mode: .authenticated,
                displayName: "Taylor"
            )
        ) {
            AccountFeature()
        }

        await store.send(.deleteAccountConfirmationAccepted)
        await store.send(.deleteAccountButtonTapped) {
            $0.isDeleteConfirmationPresented = true
        }
        await store.send(.deleteAccountConfirmationAccepted) {
            $0.isDeleteConfirmationPresented = false
            $0.isRequestInFlight = true
            $0.isDeletingAccount = true
            $0.message = nil
        }
        await store.receive(.delegate(.deleteAccountRequested))
    }

    @MainActor
    func testDeletionFailureClearsProgressWithSpecificMessage() async {
        var state = AccountFeature.State(
            mode: .authenticated,
            displayName: "Taylor"
        )
        state.isRequestInFlight = true
        state.isDeletingAccount = true
        let store = TestStore(initialState: state) {
            AccountFeature()
        }

        await store.send(.operationFailed(.reauthenticationRequired)) {
            $0.isRequestInFlight = false
            $0.isDeletingAccount = false
            $0.message = .reauthenticationRequired
        }
    }

    @MainActor
    func testDeletionUsesFreshAppleCodeAndClearsSessionAfterReceipt() async throws {
        let calls = DeletionCallRecorder()
        let expectedRequest = AccountDeletionRequest(
            authorizationCode: "fresh-apple-authorization-code",
            nonce: String(repeating: "a", count: 64)
        )
        let operations = deletionOperations(
            requestAccountDeletion: { request in
                await calls.record("function")
                XCTAssertEqual(request, expectedRequest)
                return AccountDeletionReceipt(status: .deleted)
            },
            clearLocalSession: {
                await calls.record("clear-local-session")
            }
        )
        let client = SupabaseAuthenticationClient.make(
            operations: operations,
            appleAuthorization: AppleAuthorizationClient(
                authorize: { _ in
                    XCTFail("ordinary sign-in must not run during deletion")
                    return nil
                },
                reauthorizeForDeletion: { challenge in
                    await calls.record("apple-prompt")
                    XCTAssertEqual(challenge, String(repeating: "a", count: 64))
                    return Data("fresh-apple-authorization-code".utf8)
                }
            ),
            nonce: {
                AppleSignInNonce(
                    rawValue: "unused-raw-nonce",
                    challenge: String(repeating: "a", count: 64)
                )
            }
        )

        try await client.deleteAccount()

        let recordedCalls = await calls.values()
        XCTAssertEqual(
            recordedCalls,
            ["apple-prompt", "function", "clear-local-session"]
        )
    }

    @MainActor
    func testDeletionNeverClearsLocalSessionWithoutServerReceipt() async {
        let calls = DeletionCallRecorder()
        let client = SupabaseAuthenticationClient.make(
            operations: deletionOperations(
                requestAccountDeletion: { _ in
                    await calls.record("function-failed")
                    throw AuthenticationClientFailure.operationFailed
                },
                clearLocalSession: {
                    await calls.record("unexpected-clear")
                }
            ),
            appleAuthorization: AppleAuthorizationClient(
                authorize: { _ in nil },
                reauthorizeForDeletion: { _ in
                    Data("fresh-apple-authorization-code".utf8)
                }
            ),
            nonce: {
                AppleSignInNonce(
                    rawValue: "unused-raw-nonce",
                    challenge: String(repeating: "a", count: 64)
                )
            }
        )

        do {
            try await client.deleteAccount()
            XCTFail("Expected deletion to fail")
        } catch {
            XCTAssertEqual(
                error as? AuthenticationClientFailure,
                .operationFailed
            )
        }
        let recordedCalls = await calls.values()
        XCTAssertEqual(recordedCalls, ["function-failed"])
    }

    @MainActor
    func testDeletionRejectsMissingAuthorizationCodeBeforeNetwork() async {
        let calls = DeletionCallRecorder()
        let client = SupabaseAuthenticationClient.make(
            operations: deletionOperations(
                requestAccountDeletion: { _ in
                    await calls.record("unexpected-function")
                    return AccountDeletionReceipt(status: .deleted)
                }
            ),
            appleAuthorization: AppleAuthorizationClient(
                authorize: { _ in nil },
                reauthorizeForDeletion: { _ in nil }
            ),
            nonce: {
                AppleSignInNonce(
                    rawValue: "unused-raw-nonce",
                    challenge: String(repeating: "a", count: 64)
                )
            }
        )

        do {
            try await client.deleteAccount()
            XCTFail("Expected fresh Apple authorization to be required")
        } catch {
            XCTAssertEqual(
                error as? AuthenticationClientFailure,
                .reauthenticationRequired
            )
        }
        let recordedCalls = await calls.values()
        XCTAssertEqual(recordedCalls, [])
    }
}

private actor DeletionCallRecorder {
    private var recorded: [String] = []

    func record(_ value: String) {
        recorded.append(value)
    }

    func values() -> [String] {
        recorded
    }
}

private func deletionOperations(
    requestAccountDeletion: @escaping @Sendable (
        AccountDeletionRequest
    ) async throws -> AccountDeletionReceipt,
    clearLocalSession: @escaping @Sendable () async -> Void = {}
) -> SupabaseAuthenticationOperations {
    SupabaseAuthenticationOperations(
        currentSession: { nil },
        refreshSession: {
            throw AuthenticationClientFailure.operationFailed
        },
        exchangeAppleIDToken: { _, _ in
            throw AuthenticationClientFailure.operationFailed
        },
        bootstrapProfile: { _ in
            throw AuthenticationClientFailure.operationFailed
        },
        updateProfile: { _ in
            throw AuthenticationClientFailure.operationFailed
        },
        requestAccountDeletion: requestAccountDeletion,
        events: { AsyncStream { $0.finish() } },
        clearLocalSession: clearLocalSession,
        remoteSignOut: {},
        classifyRefreshFailure: { _ in .refreshRetryable }
    )
}
