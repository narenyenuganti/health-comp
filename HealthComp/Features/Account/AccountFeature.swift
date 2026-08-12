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
            case authenticated
        }

        var mode: Mode
        var displayName = ""
        var isRequestInFlight = false
        var message: Message?

        init(mode: Mode) {
            self.mode = mode
        }
    }

    enum Message: Equatable, Sendable {
        case invalidCredential
        case invalidDisplayName
        case sessionEnded
        case tryAgain

        var text: String {
            switch self {
            case .invalidCredential:
                "Apple sign-in could not be verified. Please try again."
            case .invalidDisplayName:
                "Choose a name from 1 to 64 characters without line breaks."
            case .sessionEnded:
                "Your session ended. Sign in again to continue."
            case .tryAgain:
                "HealthComp could not connect. Please try again."
            }
        }
    }

    enum Action: Equatable, Sendable {
        enum Delegate: Equatable, Sendable {
            case signInWithAppleRequested
            case displayNameSubmitted(String)
            case retryRequested
            case signOutRequested
        }

        case displayNameChanged(String)
        case signInButtonTapped
        case submitDisplayNameButtonTapped
        case retryButtonTapped
        case signOutButtonTapped
        case operationFailed(AuthenticationClientFailure)
        case operationFinished
        case dismissMessage
        case delegate(Delegate)
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
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
                guard let displayName = validDisplayName(state.displayName) else {
                    state.message = .invalidDisplayName
                    return .none
                }
                state.displayName = displayName
                beginRequest(state: &state)
                return .send(.delegate(.displayNameSubmitted(displayName)))

            case .retryButtonTapped:
                guard !state.isRequestInFlight else { return .none }
                beginRequest(state: &state)
                return .send(.delegate(.retryRequested))

            case .signOutButtonTapped:
                guard !state.isRequestInFlight else { return .none }
                beginRequest(state: &state)
                return .send(.delegate(.signOutRequested))

            case let .operationFailed(failure):
                state.isRequestInFlight = false
                state.message = message(for: failure)
                return .none

            case .operationFinished:
                state.isRequestInFlight = false
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

    private func validDisplayName(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(value.count),
              value != "Former competitor",
              !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
              })
        else {
            return nil
        }
        return value
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
        case .refreshRetryable, .nonceGenerationFailed,
             .displayNameRequired, .operationFailed:
            .tryAgain
        }
    }
}
