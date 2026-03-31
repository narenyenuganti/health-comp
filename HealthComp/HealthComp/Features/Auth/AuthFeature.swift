import ComposableArchitecture
import Foundation

@Reducer
struct AuthFeature {
    @ObservableState
    struct State: Equatable {
        var isLoading = false
        var errorMessage: String?
    }

    enum Action: Equatable, Sendable {
        case signInWithAppleTapped
        case signInResponse(Result<AuthResult, AuthError>)
        case dismissErrorTapped
    }

    @Dependency(\.authClient) var authClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .signInWithAppleTapped:
                state.isLoading = true
                state.errorMessage = nil
                return .run { send in
                    do {
                        let result = try await authClient.signInWithApple()
                        await send(.signInResponse(.success(result)))
                    } catch let error as AuthError {
                        await send(.signInResponse(.failure(error)))
                    } catch {
                        await send(.signInResponse(.failure(.signInFailed(error.localizedDescription))))
                    }
                }

            case .signInResponse(.success):
                state.isLoading = false
                return .none

            case .signInResponse(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                return .none

            case .dismissErrorTapped:
                state.errorMessage = nil
                return .none
            }
        }
    }
}
