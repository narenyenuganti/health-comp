import ComposableArchitecture
import XCTest
@testable import HealthComp

final class AuthFeatureTests: XCTestCase {

    @MainActor
    func testSignInWithAppleSuccess() async {
        let testUser = User(
            id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
            username: "naren",
            displayName: "Naren Y",
            avatarURL: nil,
            bio: nil,
            cosmetics: .default,
            cpBalance: 0,
            cpLifetime: 0,
            privacy: .default,
            createdAt: Date()
        )

        let store = TestStore(initialState: AuthFeature.State()) {
            AuthFeature()
        } withDependencies: {
            $0.authClient.signInWithApple = { .existingUser(testUser) }
        }

        await store.send(\.signInWithAppleTapped) {
            $0.isLoading = true
        }
        await store.receive(\.signInResponse.success) {
            $0.isLoading = false
        }
    }

    @MainActor
    func testSignInWithAppleNewUser() async {
        let userId = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!

        let store = TestStore(initialState: AuthFeature.State()) {
            AuthFeature()
        } withDependencies: {
            $0.authClient.signInWithApple = { .newUser(userId) }
        }

        await store.send(\.signInWithAppleTapped) {
            $0.isLoading = true
        }
        await store.receive(\.signInResponse.success) {
            $0.isLoading = false
        }
    }

    @MainActor
    func testSignInWithAppleFailure() async {
        let store = TestStore(initialState: AuthFeature.State()) {
            AuthFeature()
        } withDependencies: {
            $0.authClient.signInWithApple = {
                throw AuthError.signInFailed("User cancelled")
            }
        }

        await store.send(\.signInWithAppleTapped) {
            $0.isLoading = true
        }
        await store.receive(\.signInResponse.failure) {
            $0.isLoading = false
            $0.errorMessage = "User cancelled"
        }
    }

    @MainActor
    func testDismissError() async {
        var state = AuthFeature.State()
        state.errorMessage = "Something went wrong"

        let store = TestStore(initialState: state) {
            AuthFeature()
        }

        await store.send(\.dismissErrorTapped) {
            $0.errorMessage = nil
        }
    }
}
