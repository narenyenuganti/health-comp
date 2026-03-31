import ComposableArchitecture
import Foundation

@Reducer
struct AppFeature {
    @ObservableState
    struct State: Equatable {
        var screen: Screen = .loading
        var currentUser: User?

        enum Screen: Equatable {
            case loading
            case auth(AuthFeature.State)
            case onboarding(OnboardingFeature.State)
            case mainTab(MainTabFeature.State)
        }

        var auth: AuthFeature.State? {
            get {
                guard case .auth(let state) = screen else { return nil }
                return state
            }
            set {
                guard let newValue else { return }
                screen = .auth(newValue)
            }
        }

        var onboarding: OnboardingFeature.State? {
            get {
                guard case .onboarding(let state) = screen else { return nil }
                return state
            }
            set {
                guard let newValue else { return }
                screen = .onboarding(newValue)
            }
        }

        var mainTab: MainTabFeature.State? {
            get {
                guard case .mainTab(let state) = screen else { return nil }
                return state
            }
            set {
                guard let newValue else { return }
                screen = .mainTab(newValue)
            }
        }
    }

    enum Action: Equatable, Sendable {
        case onAppear
        case sessionRestored(Result<AuthResult, AuthError>)
        case navigateToOnboarding(UUID)
        case navigateToMainTab(User)
        case auth(AuthFeature.Action)
        case onboarding(OnboardingFeature.Action)
        case mainTab(MainTabFeature.Action)
    }

    @Dependency(\.authClient) var authClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .run { send in
                    do {
                        let result = try await authClient.restoreSession()
                        await send(.sessionRestored(.success(result)))
                    } catch let error as AuthError {
                        await send(.sessionRestored(.failure(error)))
                    } catch {
                        await send(.sessionRestored(.failure(.sessionExpired)))
                    }
                }

            case .sessionRestored(.success(.existingUser(let user))):
                state.currentUser = user
                state.screen = .mainTab(MainTabFeature.State())
                return .none

            case .sessionRestored(.success(.newUser(let userId))):
                state.screen = .onboarding(OnboardingFeature.State(userId: userId))
                return .none

            case .sessionRestored(.failure):
                state.screen = .auth(AuthFeature.State())
                return .none

            case .auth(.signInResponse(.success(.newUser(let userId)))):
                return .send(.navigateToOnboarding(userId))

            case .auth(.signInResponse(.success(.existingUser(let user)))):
                return .send(.navigateToMainTab(user))

            case .auth:
                return .none

            case .onboarding(.profileCreateResponse(.success(let user))):
                return .send(.navigateToMainTab(user))

            case .onboarding:
                return .none

            case .navigateToOnboarding(let userId):
                state.screen = .onboarding(OnboardingFeature.State(userId: userId))
                return .none

            case .navigateToMainTab(let user):
                state.currentUser = user
                state.screen = .mainTab(MainTabFeature.State())
                return .none

            case .mainTab:
                return .none
            }
        }
        .ifLet(\.auth, action: \.auth) {
            AuthFeature()
        }
        .ifLet(\.onboarding, action: \.onboarding) {
            OnboardingFeature()
        }
        .ifLet(\.mainTab, action: \.mainTab) {
            MainTabFeature()
        }
    }
}
