import ComposableArchitecture
import SwiftUI
import XCTest
@testable import HealthComp

final class AccountFeatureTests: XCTestCase {
    @MainActor
    func testSignedOutRequestsSignInAndMarksRequestInFlight() async {
        let store = TestStore(
            initialState: AccountFeature.State(mode: .signedOut)
        ) {
            AccountFeature()
        }

        await store.send(.signInButtonTapped) {
            $0.isRequestInFlight = true
            $0.message = nil
        }
        await store.receive(.delegate(.signInWithAppleRequested))
    }

    @MainActor
    func testCancellationClearsProgressWithoutShowingAnError() async {
        var state = AccountFeature.State(mode: .signedOut)
        state.isRequestInFlight = true
        let store = TestStore(initialState: state) {
            AccountFeature()
        }

        await store.send(.operationFailed(.cancelled)) {
            $0.isRequestInFlight = false
            $0.message = nil
        }
    }

    @MainActor
    func testFailuresMapToClosedPresentationMessages() async {
        let cases: [(AuthenticationClientFailure, AccountFeature.Message)] = [
            (.invalidCredential, .invalidCredential),
            (.nonceMismatch, .invalidCredential),
            (.refreshRetryable, .tryAgain),
            (.terminalSession, .sessionEnded),
            (.operationFailed, .tryAgain),
        ]

        for (failure, message) in cases {
            var state = AccountFeature.State(mode: .signedOut)
            state.isRequestInFlight = true
            let store = TestStore(initialState: state) {
                AccountFeature()
            }

            await store.send(.operationFailed(failure)) {
                $0.isRequestInFlight = false
                $0.message = message
            }
        }
    }

    @MainActor
    func testDisplayNameValidationStaysLocalAndRejectsReservedOrUnsafeInput() async {
        for value in ["", "   ", "Former competitor", "A\nB", String(repeating: "a", count: 65)] {
            var state = AccountFeature.State(mode: .settingUpProfile)
            state.displayName = value
            let store = TestStore(initialState: state) {
                AccountFeature()
            }

            await store.send(.submitDisplayNameButtonTapped) {
                $0.message = .invalidDisplayName
            }
        }
    }

    @MainActor
    func testValidDisplayNameIsTrimmedBeforeDelegation() async {
        var state = AccountFeature.State(mode: .settingUpProfile)
        state.displayName = "  Taylor  "
        let store = TestStore(initialState: state) {
            AccountFeature()
        }

        await store.send(.submitDisplayNameButtonTapped) {
            $0.displayName = "Taylor"
            $0.isRequestInFlight = true
            $0.message = nil
        }
        await store.receive(.delegate(.displayNameSubmitted("Taylor")))
    }

    @MainActor
    func testAuthenticatedDisplayNameEditValidatesAndDelegatesUpdate() async {
        let store = TestStore(
            initialState: AccountFeature.State(
                mode: .authenticated,
                displayName: "Taylor"
            )
        ) {
            AccountFeature()
        }

        await store.send(.editDisplayNameButtonTapped) {
            $0.isEditingDisplayName = true
        }
        await store.send(.displayNameChanged("  Taylor Prime  ")) {
            $0.displayName = "  Taylor Prime  "
        }
        await store.send(.saveDisplayNameButtonTapped) {
            $0.displayName = "Taylor Prime"
            $0.isRequestInFlight = true
        }
        await store.receive(
            .delegate(.displayNameUpdateRequested("Taylor Prime"))
        )
        await store.send(.profileUpdateFinished("Taylor Prime")) {
            $0.isRequestInFlight = false
            $0.isEditingDisplayName = false
            $0.displayName = "Taylor Prime"
            $0.committedDisplayName = "Taylor Prime"
        }
    }

    @MainActor
    func testRetryAndSignOutAreExplicitDelegates() async {
        let retryStore = TestStore(
            initialState: AccountFeature.State(mode: .launchFailure)
        ) {
            AccountFeature()
        }
        await retryStore.send(.retryButtonTapped) {
            $0.isRequestInFlight = true
            $0.message = nil
        }
        await retryStore.receive(.delegate(.retryRequested))

        let signOutStore = TestStore(
            initialState: AccountFeature.State(mode: .authenticated)
        ) {
            AccountFeature()
        }
        await signOutStore.send(.signOutButtonTapped) {
            $0.isRequestInFlight = true
            $0.message = nil
        }
        await signOutStore.receive(.delegate(.signOutRequested))
    }

    func testAppleSignInButtonContrastsWithCurrentColorScheme() {
        XCTAssertEqual(
            AppleSignInAppearance.buttonStyle(for: .light),
            .black
        )
        XCTAssertEqual(
            AppleSignInAppearance.buttonStyle(for: .dark),
            .white
        )
        XCTAssertEqual(
            AccountProgressAppearance.tint(
                for: .signedOut,
                colorScheme: .light
            ),
            Color.white
        )
        XCTAssertEqual(
            AccountProgressAppearance.tint(
                for: .signedOut,
                colorScheme: .dark
            ),
            Color.black
        )
        XCTAssertEqual(
            AccountProgressAppearance.tint(
                for: .settingUpProfile,
                colorScheme: .dark
            ),
            Color.white
        )
        XCTAssertEqual(
            AccountProgressAppearance.tint(
                for: .launchFailure,
                colorScheme: .light
            ),
            Color.white
        )
        XCTAssertEqual(
            AccountProgressAppearance.tint(
                for: .authenticated,
                colorScheme: .light
            ),
            Color.primary
        )
    }
}
