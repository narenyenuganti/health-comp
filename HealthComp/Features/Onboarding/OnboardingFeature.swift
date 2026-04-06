import ComposableArchitecture
import Foundation

@Reducer
struct OnboardingFeature {
    @ObservableState
    struct State: Equatable {
        let userId: UUID
        var username = ""
        var displayName = ""
        var isLoading = false
        var isUsernameAvailable: Bool?
        var errorMessage: String?

        var isSubmitDisabled: Bool {
            username.trimmingCharacters(in: .whitespaces).isEmpty
            || displayName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    enum Action: Equatable, Sendable {
        case usernameChanged(String)
        case displayNameChanged(String)
        case submitTapped
        case usernameCheckResponse(Result<Bool, ProfileError>)
        case profileCreateResponse(Result<User, ProfileError>)
    }

    @Dependency(\.profileClient) var profileClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .usernameChanged(let value):
                state.username = value
                state.isUsernameAvailable = nil
                state.errorMessage = nil
                return .none

            case .displayNameChanged(let value):
                state.displayName = value
                state.errorMessage = nil
                return .none

            case .submitTapped:
                state.isLoading = true
                state.errorMessage = nil
                let username = state.username.trimmingCharacters(in: .whitespaces).lowercased()
                let displayName = state.displayName.trimmingCharacters(in: .whitespaces)
                let userId = state.userId
                return .run { send in
                    do {
                        let available = try await profileClient.isUsernameAvailable(username)
                        await send(.usernameCheckResponse(.success(available)))
                        if available {
                            let user = try await profileClient.createProfile(userId, username, displayName)
                            await send(.profileCreateResponse(.success(user)))
                        }
                    } catch let error as ProfileError {
                        await send(.usernameCheckResponse(.failure(error)))
                    } catch {
                        await send(.usernameCheckResponse(.failure(.unknown(error.localizedDescription))))
                    }
                }

            case .usernameCheckResponse(.success(let available)):
                state.isUsernameAvailable = available
                if !available {
                    state.isLoading = false
                    state.errorMessage = "Username is taken. Try another."
                }
                return .none

            case .usernameCheckResponse(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                return .none

            case .profileCreateResponse(.success):
                state.isLoading = false
                return .none

            case .profileCreateResponse(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                return .none
            }
        }
    }
}

enum ProfileError: Error, Equatable, LocalizedError {
    case usernameTaken
    case networkError(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .usernameTaken: return "Username is already taken."
        case .networkError(let msg): return msg
        case .unknown(let msg): return msg
        }
    }
}
