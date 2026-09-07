import ComposableArchitecture
import Foundation
import XCTest
@testable import HealthComp

final class AccountDeletionTests: XCTestCase {
    @MainActor
    func testSessionRestoreOwnsOperationGateUntilItSettles() async throws {
        let entered = DeletionBarrier()
        let release = DeletionBarrier()
        let calls = DeletionCallRecorder()
        var operations = deletionOperations()
        operations.currentSession = {
            await entered.release()
            await release.wait()
            return nil
        }
        operations.remoteSignOut = { await calls.record("sign-out") }
        let profile = AuthenticatedProfile(
            id: UUID(uuidString: "92000000-0000-4000-8000-000000000001")!,
            displayName: "Synthetic"
        )
        operations.bootstrapProfile = { _ in
            await calls.record("bootstrap")
            return profile
        }
        operations.updateProfile = { _ in
            await calls.record("update")
            return profile
        }
        let client = SupabaseAuthenticationClient.make(
            operations: operations,
            appleAuthorization: .init(authorize: { _ in nil })
        )
        let pending = Task { try await client.restoreSession() }
        await entered.wait()
        do {
            try await client.signOut()
            XCTFail("Sign-out started before restoration settled")
        } catch {
            XCTAssertEqual(error as? AuthenticationClientFailure, .operationFailed)
        }
        do {
            _ = try await client.bootstrapProfile(nil)
            XCTFail("Bootstrap started before restoration settled")
        } catch {
            XCTAssertEqual(error as? AuthenticationClientFailure, .operationFailed)
        }
        do {
            _ = try await client.updateProfile("Synthetic")
            XCTFail("Profile update started before restoration settled")
        } catch {
            XCTAssertEqual(error as? AuthenticationClientFailure, .operationFailed)
        }
        let duringRestore = await calls.values()
        XCTAssertTrue(duringRestore.isEmpty)
        await release.release()
        let restored = try await pending.value
        XCTAssertNil(restored)
        let bootstrapped = try await client.bootstrapProfile(nil)
        let updated = try await client.updateProfile("Synthetic")
        XCTAssertEqual(bootstrapped, profile)
        XCTAssertEqual(updated, profile)
        try await client.signOut()
        let afterRestore = await calls.values()
        XCTAssertEqual(afterRestore, ["bootstrap", "update", "sign-out"])
    }

    @MainActor
    func testBrowserAccountActionsAreUnavailableWithoutOperations() async {
        let authentication = SupabaseAuthenticationClient.make(
            operations: deletionOperations(), appleAuthorization: .init(authorize: { _ in nil })
        )
        let store = TestStore(initialState: AccountFeature.State(mode: .signedOut)) {
            AccountFeature()
        } withDependencies: { $0.authenticationClient = authentication }
        await store.send(.appeared)
        await store.send(.browserSignInButtonTapped)
        await store.send(.browserDeleteConfirmationAccepted)
    }

    @MainActor
    func testBrowserAccountSignInRequiresAvailabilityAndExcludesRepeatedTap() async {
        var authentication = SupabaseAuthenticationClient.make(
            operations: deletionOperations(), appleAuthorization: .init(authorize: { _ in nil })
        )
        authentication.signInWithAppleInBrowser = { throw AuthenticationClientFailure.cancelled }
        let store = TestStore(initialState: AccountFeature.State(mode: .signedOut)) {
            AccountFeature()
        } withDependencies: { $0.authenticationClient = authentication }
        await store.send(.appeared) { $0.isBrowserSignInAvailable = true }
        await store.send(.browserSignInButtonTapped) { $0.isRequestInFlight = true }
        await store.receive(.delegate(.signInWithAppleInBrowserRequested))
        await store.send(.browserSignInButtonTapped)
    }

    @MainActor
    func testBrowserDeletionRequiresExplicitConfirmation() async {
        var authentication = SupabaseAuthenticationClient.make(
            operations: deletionOperations(), appleAuthorization: .init(authorize: { _ in nil })
        )
        authentication.deleteAccountInBrowser = {}
        let store = TestStore(initialState: AccountFeature.State(mode: .authenticated)) {
            AccountFeature()
        } withDependencies: { $0.authenticationClient = authentication }
        await store.send(.appeared) { $0.isBrowserDeletionAvailable = true }
        await store.send(.browserDeleteConfirmationAccepted)
        await store.send(.deleteAccountButtonTapped) { $0.isDeleteConfirmationPresented = true }
        await store.send(.deleteAccountConfirmationCancelled) { $0.isDeleteConfirmationPresented = false }
        await store.send(.browserDeleteConfirmationAccepted)
        await store.send(.deleteAccountButtonTapped) { $0.isDeleteConfirmationPresented = true }
        await store.send(.browserDeleteConfirmationAccepted) {
            $0.isDeleteConfirmationPresented = false
            $0.isDeletingAccount = true
            $0.isRequestInFlight = true
        }
        await store.receive(.delegate(.deleteAccountInBrowserRequested))
        await store.send(.browserDeleteConfirmationAccepted)
    }

    @MainActor
    func testBrowserSignInOwnsAuthenticationGateThroughCancellationSettlement() async throws {
        let entered = DeletionBarrier()
        let release = DeletionBarrier()
        let calls = DeletionCallRecorder()
        var operations = deletionOperations(clearLocalSession: { await calls.record("unexpected-clear") })
        operations.remoteSignOut = { await calls.record("sign-out") }
        let client = SupabaseAuthenticationClient.make(
            operations: operations,
            appleAuthorization: .init(authorize: { _ in
                await calls.record("unexpected-native-sign-in")
                return nil
            }),
            browserDeletion: { await calls.record("unexpected-browser-delete") },
            browserSignIn: {
                await entered.release()
                await release.wait()
                throw AppleWebAuthenticationSessionFailure.cancelled
            }
        )
        let signIn = try XCTUnwrap(client.signInWithAppleInBrowser)
        let deletion = try XCTUnwrap(client.deleteAccountInBrowser)
        let pending = Task { try await signIn() }
        await entered.wait()
        pending.cancel()
        // Cancellation alone must not release an operation still settling.
        do { _ = try await signIn(); XCTFail("Concurrent browser sign-in accepted") }
        catch { XCTAssertEqual(error as? AuthenticationClientFailure, .operationFailed) }
        do { _ = try await client.signInWithApple(); XCTFail("Concurrent native sign-in accepted") }
        catch { XCTAssertEqual(error as? AuthenticationClientFailure, .operationFailed) }
        do { try await deletion(); XCTFail("Concurrent browser deletion accepted") }
        catch { XCTAssertEqual(error as? AuthenticationClientFailure, .operationFailed) }
        do { try await client.deleteAccount(); XCTFail("Concurrent native deletion accepted") }
        catch { XCTAssertEqual(error as? AuthenticationClientFailure, .operationFailed) }
        do { try await client.signOut(); XCTFail("Concurrent sign-out accepted") }
        catch { XCTAssertEqual(error as? AuthenticationClientFailure, .operationFailed) }
        do { _ = try await client.restoreSession(); XCTFail("Concurrent session restoration accepted") }
        catch { XCTAssertEqual(error as? AuthenticationClientFailure, .operationFailed) }
        let before = await calls.values()
        XCTAssertTrue(before.isEmpty)
        await release.release()
        do { _ = try await pending.value; XCTFail("Cancelled browser sign-in succeeded") }
        catch { XCTAssertEqual(error as? AuthenticationClientFailure, .cancelled) }
        try await client.signOut()
        let after = await calls.values()
        XCTAssertEqual(after, ["sign-out"])
    }

    @MainActor
    func testBrowserSignInReturnsItsSessionAndIsUnavailableByDefault() async throws {
        let expected = AuthenticationSession(userID: UUID(), expiresAt: Date().addingTimeInterval(3600))
        let disabled = SupabaseAuthenticationClient.make(
            operations: deletionOperations(), appleAuthorization: .init(authorize: { _ in nil })
        )
        XCTAssertNil(disabled.signInWithAppleInBrowser)
        let enabled = SupabaseAuthenticationClient.make(
            operations: deletionOperations(clearLocalSession: { XCTFail("Successful sign-in must not clear session") }),
            appleAuthorization: .init(authorize: { _ in XCTFail("Browser route must not call native"); return nil }),
            browserSignIn: { expected }
        )
        let result = try await XCTUnwrap(enabled.signInWithAppleInBrowser)()
        XCTAssertEqual(result, expected)
    }

    @MainActor
    func testConfirmedDeletionDefersCleanupToConfiguredRetirement() async throws {
        for browser in [false, true] {
            let calls = DeletionCallRecorder()
            let client = SupabaseAuthenticationClient.make(
                operations: deletionOperations(
                    requestAccountDeletion: { _ in
                        await calls.record("confirmed")
                        return .init(status: .deleted)
                    },
                    clearLocalSession: {
                        await calls.record("premature-cleanup")
                        throw AuthenticationClientFailure.operationFailed
                    }
                ),
                appleAuthorization: .init(
                    authorize: { _ in nil },
                    reauthorizeForDeletion: { _ in Data("synthetic-apple-deletion-code".utf8) }
                ),
                browserDeletion: { await calls.record("confirmed") },
                finishRetirement: {
                    await calls.record("retire")
                    throw AuthenticationClientFailure.operationFailed
                }
            )
            if browser { try await XCTUnwrap(client.deleteAccountInBrowser)() }
            else { try await client.deleteAccount() }
            let confirmed = await calls.values()
            XCTAssertEqual(confirmed, ["confirmed"])
            do {
                try await XCTUnwrap(client.finishRetirement)()
                XCTFail("Retirement failure must remain visible after confirmation.")
            } catch { XCTAssertEqual(error as? AuthenticationClientFailure, .operationFailed) }
            let retired = await calls.values()
            XCTAssertEqual(retired, ["confirmed", "retire"])
        }
    }

    @MainActor
    func testConfirmedNativeAndBrowserDeletionCannotHideLocalRemovalFailure() async throws {
        for browser in [false, true] {
            let client = SupabaseAuthenticationClient.make(
                operations: deletionOperations(
                    requestAccountDeletion: { _ in .init(status: .deleted) },
                    clearLocalSession: { throw AuthenticationClientFailure.operationFailed }
                ),
                appleAuthorization: .init(
                    authorize: { _ in nil },
                    reauthorizeForDeletion: { _ in Data("synthetic-apple-authorization-code".utf8) }
                ),
                browserDeletion: {}
            )
            do {
                if browser { try await XCTUnwrap(client.deleteAccountInBrowser)() }
                else { try await client.deleteAccount() }
                XCTFail("Local removal failure must not report full deletion success")
            } catch { XCTAssertEqual(error as? AuthenticationClientFailure, .operationFailed) }
        }
    }

    @MainActor
    func testBrowserDeletionExcludesNativeSignInDeletionAndSignOutUntilSettlement() async throws {
        let entered = DeletionBarrier()
        let release = DeletionBarrier()
        let calls = DeletionCallRecorder()
        var operations = deletionOperations(clearLocalSession: { await calls.record("clear") })
        operations.remoteSignOut = { await calls.record("sign-out") }
        let client = SupabaseAuthenticationClient.make(
            operations: operations,
            appleAuthorization: .init(
                authorize: { _ in await calls.record("native-sign-in"); throw AuthenticationClientFailure.cancelled },
                reauthorizeForDeletion: { _ in await calls.record("native-delete"); throw AuthenticationClientFailure.cancelled }
            ),
            browserDeletion: { await entered.release(); await release.wait() }
        )
        let delete = try XCTUnwrap(client.deleteAccountInBrowser)
        let pending = Task { try await delete() }
        await entered.wait()
        do { _ = try await client.signInWithApple(); XCTFail("Concurrent native sign-in accepted") }
        catch { XCTAssertEqual(error as? AuthenticationClientFailure, .operationFailed) }
        do { try await client.deleteAccount(); XCTFail("Concurrent native deletion accepted") }
        catch { XCTAssertEqual(error as? AuthenticationClientFailure, .operationFailed) }
        do { try await client.signOut(); XCTFail("Concurrent sign-out accepted") }
        catch { XCTAssertEqual(error as? AuthenticationClientFailure, .operationFailed) }
        let before = await calls.values()
        XCTAssertTrue(before.isEmpty)
        await release.release()
        try await pending.value
        try await client.signOut()
        let after = await calls.values()
        XCTAssertEqual(after, ["clear", "sign-out"])
    }

    @MainActor
    func testBrowserDeletionIsUnavailableByDefault() {
        let client = SupabaseAuthenticationClient.make(
            operations: deletionOperations(),
            appleAuthorization: .init(authorize: { _ in nil })
        )
        XCTAssertNil(client.deleteAccountInBrowser)
    }

    @MainActor
    func testBrowserDeletionClearsOnlyAfterConfirmedOperation() async throws {
        let calls = DeletionCallRecorder()
        let client = SupabaseAuthenticationClient.make(
            operations: deletionOperations(clearLocalSession: { await calls.record("clear") }),
            appleAuthorization: .init(authorize: { _ in XCTFail("Native login must not run"); return nil }),
            browserDeletion: { await calls.record("confirmed-browser-deletion") }
        )
        let delete = try XCTUnwrap(client.deleteAccountInBrowser)
        try await delete()
        let recorded = await calls.values()
        XCTAssertEqual(recorded, ["confirmed-browser-deletion", "clear"])
    }

    @MainActor
    func testBrowserCancellationDoesNotClearLocalSession() async throws {
        let calls = DeletionCallRecorder()
        let client = SupabaseAuthenticationClient.make(
            operations: deletionOperations(clearLocalSession: { await calls.record("unexpected-clear") }),
            appleAuthorization: .init(authorize: { _ in nil }),
            browserDeletion: { throw AppleWebAuthenticationSessionFailure.cancelled }
        )
        let delete = try XCTUnwrap(client.deleteAccountInBrowser)
        do { try await delete(); XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? AuthenticationClientFailure, .cancelled) }
        let recorded = await calls.values()
        XCTAssertTrue(recorded.isEmpty)
    }

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

private actor DeletionBarrier {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private func deletionOperations(
    requestAccountDeletion: @escaping @Sendable (
        AccountDeletionRequest
    ) async throws -> AccountDeletionReceipt = { _ in
        throw AuthenticationClientFailure.operationFailed
    },
    clearLocalSession: @escaping @Sendable () async throws -> Void = {}
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
