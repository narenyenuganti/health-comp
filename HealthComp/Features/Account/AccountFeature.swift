import ComposableArchitecture
import Foundation

@Reducer
struct AccountFeature {
    @ObservableState
    struct State: Equatable {
        enum Mode: Equatable, Sendable {
            case signedOut
            case settingUpProfile
            case launchFailure
            case profileConflict
            case authenticated
        }

        var mode: Mode
        var displayName: String
        var committedDisplayName: String
        var isEditingDisplayName = false
        var isRequestInFlight = false
        var isDeleteConfirmationPresented = false
        var isDeletingAccount = false
        var isBrowserSignInAvailable = false
        var isBrowserDeletionAvailable = false
        var message: Message?

        init(mode: Mode, displayName: String = "") {
            self.mode = mode
            self.displayName = displayName
            self.committedDisplayName = displayName
        }
    }

    enum Message: Equatable, Sendable {
        case invalidCredential
        case invalidDisplayName
        case reservedDisplayName
        case reauthenticationRequired
        case deleteFailed
        case accountDeleted
        case sessionEnded
        case profileConflict
        case profileRecoveryFailed
        case signOutFailed
        case signOutCleanupFailed
        case signOutFinishFailed
        case deletedCleanupFailed
        case sessionEndedCleanupFailed
        case tryAgain

        var text: String {
            switch self {
            case .invalidCredential:
                "Apple sign-in could not be verified. Please try again."
            case .invalidDisplayName:
                "Choose a name from 1 to 64 characters without line breaks."
            case .reservedDisplayName:
                "That name is reserved. Try another."
            case .reauthenticationRequired:
                "Confirm with Sign in with Apple to delete your account."
            case .deleteFailed:
                "Couldn’t delete your account. Check your connection and try again."
            case .accountDeleted:
                "Account deleted."
            case .sessionEnded:
                "Your session ended. Sign in again to continue."
            case .profileConflict:
                "Sign in with the account you used before to continue."
            case .profileRecoveryFailed:
                "Your saved history is safe. Check your connection and try again."
            case .signOutCleanupFailed:
                "HealthComp couldn’t remove your data from this iPhone. Try again."
            case .signOutFinishFailed:
                "You’re signed out, but HealthComp couldn’t finish clearing this iPhone. Try again."
            case .deletedCleanupFailed:
                "Your account is deleted, but HealthComp couldn’t finish clearing this iPhone. Try again."
            case .sessionEndedCleanupFailed:
                "HealthComp couldn’t finish clearing this iPhone. Try again."
            case .signOutFailed, .tryAgain:
                "Check your connection and try again."
            }
        }

        /// The launch-failure title, naming the step that failed.
        var failureTitle: String? {
            switch self {
            case .tryAgain: "Couldn’t connect"
            case .invalidCredential: "Couldn’t sign in"
            case .profileConflict: "This iPhone has history for another account"
            case .signOutFailed, .signOutCleanupFailed, .profileRecoveryFailed:
                "Couldn’t sign out"
            case .signOutFinishFailed: "Couldn’t finish signing out"
            case .deletedCleanupFailed: "Account deleted"
            case .sessionEndedCleanupFailed: "Your session ended"
            case .invalidDisplayName, .reservedDisplayName,
                 .reauthenticationRequired, .deleteFailed, .accountDeleted,
                 .sessionEnded:
                nil
            }
        }

        /// Shown under Delete Account instead of in the profile section.
        var isDeletionMessage: Bool {
            self == .deleteFailed || self == .reauthenticationRequired
        }
    }

    enum Action: Equatable, Sendable {
        enum Delegate: Equatable, Sendable {
            case signInWithAppleRequested
            case signInWithAppleInBrowserRequested
            case displayNameSubmitted(String)
            case displayNameUpdateRequested(String)
            case retryRequested
            case signOutRequested
            case deleteAccountRequested
            case deleteAccountInBrowserRequested
        }

        case displayNameChanged(String)
        case appeared
        case browserSignInButtonTapped
        case browserDeleteConfirmationAccepted
        case signInButtonTapped
        case submitDisplayNameButtonTapped
        case editDisplayNameButtonTapped
        case cancelDisplayNameButtonTapped
        case saveDisplayNameButtonTapped
        case profileUpdateFinished(String)
        case retryButtonTapped
        case signOutButtonTapped
        case deleteAccountButtonTapped
        case deleteAccountConfirmationCancelled
        case deleteAccountConfirmationAccepted
        case operationFailed(AuthenticationClientFailure)
        case operationFinished
        case dismissMessage
        case delegate(Delegate)
    }

    @Dependency(\.authenticationClient) var authenticationClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .appeared:
                state.isBrowserSignInAvailable = authenticationClient.signInWithAppleInBrowser != nil
                state.isBrowserDeletionAvailable = authenticationClient.deleteAccountInBrowser != nil
                return .none

            case .browserSignInButtonTapped:
                guard state.mode == .signedOut,
                      state.isBrowserSignInAvailable,
                      authenticationClient.signInWithAppleInBrowser != nil,
                      !state.isRequestInFlight else { return .none }
                beginRequest(state: &state)
                return .send(.delegate(.signInWithAppleInBrowserRequested))

            case .browserDeleteConfirmationAccepted:
                guard state.mode == .authenticated,
                      state.isBrowserDeletionAvailable,
                      authenticationClient.deleteAccountInBrowser != nil,
                      state.isDeleteConfirmationPresented,
                      !state.isRequestInFlight else { return .none }
                beginDeletion(state: &state)
                return .send(.delegate(.deleteAccountInBrowserRequested))
            case let .displayNameChanged(value):
                state.displayName = value
                state.message = nil
                return .none

            case .signInButtonTapped:
                guard !state.isRequestInFlight else { return .none }
                beginRequest(state: &state)
                return .send(.delegate(.signInWithAppleRequested))

            case .submitDisplayNameButtonTapped:
                guard !state.isRequestInFlight else { return .none }
                if let problem = displayNameProblem(state.displayName) {
                    state.message = problem
                    return .none
                }
                let displayName = trimmedDisplayName(state.displayName)
                state.displayName = displayName
                beginRequest(state: &state)
                return .send(.delegate(.displayNameSubmitted(displayName)))

            case .editDisplayNameButtonTapped:
                guard state.mode == .authenticated,
                      !state.isRequestInFlight
                else {
                    return .none
                }
                state.isEditingDisplayName = true
                state.message = nil
                return .none

            case .cancelDisplayNameButtonTapped:
                guard state.mode == .authenticated,
                      !state.isRequestInFlight
                else {
                    return .none
                }
                state.displayName = state.committedDisplayName
                state.isEditingDisplayName = false
                state.message = nil
                return .none

            case .saveDisplayNameButtonTapped:
                guard state.mode == .authenticated,
                      state.isEditingDisplayName,
                      !state.isRequestInFlight
                else {
                    return .none
                }
                if let problem = displayNameProblem(state.displayName) {
                    state.message = problem
                    return .none
                }
                let displayName = trimmedDisplayName(state.displayName)
                state.displayName = displayName
                beginRequest(state: &state)
                return .send(
                    .delegate(.displayNameUpdateRequested(displayName))
                )

            case let .profileUpdateFinished(displayName):
                state.displayName = displayName
                state.committedDisplayName = displayName
                state.isEditingDisplayName = false
                state.isRequestInFlight = false
                state.message = nil
                return .none

            case .retryButtonTapped:
                guard !state.isRequestInFlight else { return .none }
                beginRequest(state: &state)
                return .send(.delegate(.retryRequested))

            case .signOutButtonTapped:
                guard !state.isRequestInFlight else { return .none }
                beginRequest(state: &state)
                return .send(.delegate(.signOutRequested))

            case .deleteAccountButtonTapped:
                guard state.mode == .authenticated,
                      !state.isRequestInFlight
                else {
                    return .none
                }
                state.isDeleteConfirmationPresented = true
                state.message = nil
                return .none

            case .deleteAccountConfirmationCancelled:
                guard state.isDeleteConfirmationPresented else {
                    return .none
                }
                state.isDeleteConfirmationPresented = false
                return .none

            case .deleteAccountConfirmationAccepted:
                guard state.mode == .authenticated,
                      state.isDeleteConfirmationPresented,
                      !state.isRequestInFlight
                else {
                    return .none
                }
                beginDeletion(state: &state)
                return .send(.delegate(.deleteAccountRequested))

            case let .operationFailed(failure):
                let wasDeleting = state.isDeletingAccount
                state.isRequestInFlight = false
                state.isDeletingAccount = false
                state.message = wasDeleting
                    ? deletionMessage(for: failure)
                    : message(for: failure)
                return .none

            case .operationFinished:
                state.isRequestInFlight = false
                state.isDeletingAccount = false
                state.message = nil
                return .none

            case .dismissMessage:
                state.message = nil
                return .none

            case .delegate:
                return .none
            }
        }
    }

    private func beginRequest(state: inout State) {
        state.isRequestInFlight = true
        state.message = nil
    }

    /// Deleting abandons an open name edit so the overlay, not the Save
    /// button, shows the wait.
    private func beginDeletion(state: inout State) {
        state.isDeleteConfirmationPresented = false
        state.displayName = state.committedDisplayName
        state.isEditingDisplayName = false
        state.isDeletingAccount = true
        beginRequest(state: &state)
    }

    private func trimmedDisplayName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The server rejects the same names; checking here keeps the message
    /// specific.
    private func displayNameProblem(_ value: String) -> Message? {
        let value = trimmedDisplayName(value)
        if value == "Former competitor" { return .reservedDisplayName }
        // Code points, as the server's char_length counts them.
        guard (1...64).contains(value.unicodeScalars.count),
              !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
              })
        else {
            return .invalidDisplayName
        }
        return nil
    }

    private func deletionMessage(
        for failure: AuthenticationClientFailure
    ) -> Message? {
        switch failure {
        case .cancelled: nil
        case .reauthenticationRequired: .reauthenticationRequired
        default: .deleteFailed
        }
    }

    private func message(for failure: AuthenticationClientFailure) -> Message? {
        switch failure {
        case .cancelled:
            nil
        case .invalidCredential, .nonceMismatch:
            .invalidCredential
        case .terminalSession, .sessionExpired:
            .sessionEnded
        case .invalidDisplayName:
            .invalidDisplayName
        case .reauthenticationRequired:
            .reauthenticationRequired
        case .refreshRetryable, .nonceGenerationFailed,
             .displayNameRequired, .operationFailed, .retirementRequired:
            .tryAgain
        }
    }
}
