import CompetitionCore
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
        let cases: [(String, AccountFeature.Message)] = [
            ("", .invalidDisplayName),
            ("   ", .invalidDisplayName),
            ("Former competitor", .reservedDisplayName),
            (" Former competitor ", .reservedDisplayName),
            ("A\nB", .invalidDisplayName),
            (String(repeating: "a", count: 65), .invalidDisplayName),
        ]
        for (value, message) in cases {
            var state = AccountFeature.State(mode: .settingUpProfile)
            state.displayName = value
            let store = TestStore(initialState: state) {
                AccountFeature()
            }

            await store.send(.submitDisplayNameButtonTapped) {
                $0.message = message
            }
        }

        var editing = AccountFeature.State(
            mode: .authenticated,
            displayName: "Taylor"
        )
        editing.isEditingDisplayName = true
        editing.displayName = " Former competitor "
        let store = TestStore(initialState: editing) {
            AccountFeature()
        }
        await store.send(.saveDisplayNameButtonTapped) {
            $0.message = .reservedDisplayName
        }
        XCTAssertEqual(
            AccountFeature.Message.reservedDisplayName.text,
            "That name is reserved. Try another."
        )
    }

    @MainActor
    func testDeletionFailuresStayWithDeleteRow() async {
        let cases: [(AuthenticationClientFailure, AccountFeature.Message?)] = [
            (.operationFailed, .deleteFailed),
            (.reauthenticationRequired, .reauthenticationRequired),
            (.cancelled, nil),
        ]
        for (failure, message) in cases {
            var state = AccountFeature.State(mode: .authenticated)
            state.isRequestInFlight = true
            state.isDeletingAccount = true
            let store = TestStore(initialState: state) {
                AccountFeature()
            }
            await store.send(.operationFailed(failure)) {
                $0.isRequestInFlight = false
                $0.isDeletingAccount = false
                $0.message = message
            }
        }
        XCTAssertTrue(AccountFeature.Message.deleteFailed.isDeletionMessage)
        XCTAssertTrue(
            AccountFeature.Message.reauthenticationRequired.isDeletionMessage
        )
        XCTAssertFalse(AccountFeature.Message.tryAgain.isDeletionMessage)
        XCTAssertEqual(
            AccountFeature.Message.deleteFailed.text,
            "Couldn’t delete your account. Check your connection and try again."
        )
    }

    func testFailureTitlesNameTheStepThatFailed() {
        let cases: [(AccountFeature.Message, String?, String)] = [
            (.signOutFailed, "Couldn’t sign out", "Check your connection and try again."),
            (.signOutCleanupFailed, "Couldn’t sign out", "HealthComp couldn’t remove your data from this iPhone. Try again."),
            (.signOutFinishFailed, "Couldn’t finish signing out", "You’re signed out, but HealthComp couldn’t finish clearing this iPhone. Try again."),
            (.deletedCleanupFailed, "Account deleted", "Your account is deleted, but HealthComp couldn’t finish clearing this iPhone. Try again."),
            (.sessionEndedCleanupFailed, "Your session ended", "HealthComp couldn’t finish clearing this iPhone. Try again."),
            (.profileRecoveryFailed, "Couldn’t sign out", "Your saved history is safe. Check your connection and try again."),
            (.tryAgain, "Couldn’t connect", "Check your connection and try again."),
            (.invalidCredential, "Couldn’t sign in", "Apple sign-in could not be verified. Please try again."),
            (.profileConflict, "This iPhone has history for another account", "Sign in with the account you used before to continue."),
            (.accountDeleted, nil, "Account deleted."),
        ]
        for (message, title, text) in cases {
            XCTAssertEqual(message.failureTitle, title, "\(message)")
            XCTAssertEqual(message.text, text, "\(message)")
        }
    }

    func testSignOutMessageCountsLiveMatches() {
        XCTAssertEqual(
            accountSignOutMessage(liveMatchCount: 0),
            "Notifications stop until you sign back in."
        )
        XCTAssertEqual(
            accountSignOutMessage(liveMatchCount: 1),
            "While you’re signed out, your points stop reaching your live match and notifications stop. Sign back in before it ends to catch up."
        )
        XCTAssertEqual(
            accountSignOutMessage(liveMatchCount: 3),
            "While you’re signed out, your points stop reaching your 3 live matches and notifications stop. Sign back in before they end to catch up."
        )
    }

    func testLiveMatchCountCountsActiveEndsTodayAndTallying() {
        let date = Date(timeIntervalSinceReferenceDate: 1)
        let lifecycles: [LocalCompetitionLifecyclePresentation] = [
            .active(dayOrdinal: 2),
            .endsToday,
            .tallying(startedAt: date),
            .scheduled,
            .pending(direction: .incoming, createdAt: date, expiresAt: nil),
            .completed(
                outcome: .win,
                basis: .stableAcrossPostBoundaryReads,
                completedAt: date
            ),
        ]
        XCTAssertEqual(
            accountLiveMatchCount(
                lifecycles.map { competition(identity: "x", name: "X", lifecycle: $0) }
            ),
            3
        )
    }

    func testMutedPeopleResolveNamesFromMatches() {
        let competitions = [
            competition(identity: "remote-opponent:v1:sam", name: "Sam"),
            competition(identity: "remote-opponent:v1:hermes", name: "Hermes"),
            competition(identity: "remote-opponent:v1:hermes", name: "Hermes"),
            competition(identity: "remote-opponent:v1:jordan", name: "Jordan"),
        ]
        XCTAssertEqual(
            AccountMutedPerson.list(
                competitions,
                muted: [
                    "remote-opponent:v1:sam",
                    "remote-opponent:v1:hermes",
                    "remote-opponent:v1:unknown",
                ]
            ),
            [
                AccountMutedPerson(id: "remote-opponent:v1:hermes", name: "Hermes"),
                AccountMutedPerson(id: "remote-opponent:v1:sam", name: "Sam"),
            ]
        )
    }

    func testHealthSettingsState() {
        func state(
            _ access: HealthAccessStatus,
            failing: Bool
        ) -> AccountHealthSettings.State {
            AccountHealthSettings(
                access: access,
                isReadFailing: failing,
                connect: {}
            ).state
        }
        XCTAssertEqual(state(.notRequested, failing: false), .off)
        XCTAssertEqual(state(.requested, failing: false), .asked)
        XCTAssertEqual(state(.unavailable, failing: false), .unavailable)
        XCTAssertEqual(state(.requested, failing: true), .unavailable)
    }

    private func competition(
        identity: String,
        name: String,
        lifecycle: LocalCompetitionLifecyclePresentation = .active(dayOrdinal: 1)
    ) -> LocalCompetitionPresentation {
        LocalCompetitionPresentation(
            id: CompetitionID(UUID()),
            ownerDisplayName: "Naren",
            opponentDisplayName: name,
            opponentIdentity: identity,
            lifecycle: lifecycle,
            acceptedConfiguration: nil,
            userPoints: 0,
            opponentPoints: 0,
            days: [],
            currentDayOrdinal: nil,
            lastRefresh: nil,
            tally: nil,
            terminalResult: nil
        )
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
