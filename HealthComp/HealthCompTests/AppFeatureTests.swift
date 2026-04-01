import ComposableArchitecture
import XCTest
@testable import HealthComp

final class AppFeatureTests: XCTestCase {

    @MainActor
    func testInitialStateIsLoading() {
        let state = AppFeature.State()
        XCTAssertEqual(state.screen, .loading)
    }

    @MainActor
    func testSessionRestoreExistingUser() async {
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

        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.authClient.restoreSession = { .existingUser(testUser) }
        }

        await store.send(\.onAppear)
        await store.receive(\.sessionRestored.success) {
            $0.screen = .mainTab(MainTabFeature.State())
            $0.currentUser = testUser
        }
    }

    @MainActor
    func testSessionRestoreNoSession() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.authClient.restoreSession = { throw AuthError.sessionExpired }
        }

        await store.send(\.onAppear)
        await store.receive(\.sessionRestored.failure) {
            $0.screen = .auth(AuthFeature.State())
        }
    }

    @MainActor
    func testAuthSuccessNewUserGoesToOnboarding() async {
        let userId = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!

        let store = TestStore(
            initialState: AppFeature.State(screen: .auth(AuthFeature.State()))
        ) {
            AppFeature()
        } withDependencies: {
            $0.authClient.signInWithApple = { .newUser(userId) }
        }

        await store.send(\.auth.signInWithAppleTapped) {
            $0.auth?.isLoading = true
        }
        await store.receive(\.auth.signInResponse.success) {
            $0.auth?.isLoading = false
        }
        await store.receive(\.navigateToOnboarding) {
            $0.screen = .onboarding(OnboardingFeature.State(userId: userId))
        }
    }

    @MainActor
    func testAuthSuccessExistingUserGoesToMainTab() async {
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

        let store = TestStore(
            initialState: AppFeature.State(screen: .auth(AuthFeature.State()))
        ) {
            AppFeature()
        } withDependencies: {
            $0.authClient.signInWithApple = { .existingUser(testUser) }
        }

        await store.send(\.auth.signInWithAppleTapped) {
            $0.auth?.isLoading = true
        }
        await store.receive(\.auth.signInResponse.success) {
            $0.auth?.isLoading = false
        }
        await store.receive(\.navigateToMainTab) {
            $0.screen = .mainTab(MainTabFeature.State())
            $0.currentUser = testUser
        }
    }

    @MainActor
    func testDebugBypassGoesToMainTab() async {
        let demoUser = User(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            username: "demo",
            displayName: "Demo User",
            avatarURL: nil,
            bio: "Local debug bypass user",
            cosmetics: .default,
            cpBalance: 0,
            cpLifetime: 0,
            privacy: .default,
            createdAt: Date(timeIntervalSince1970: 0)
        )

        let store = TestStore(
            initialState: AppFeature.State(screen: .auth(AuthFeature.State()))
        ) {
            AppFeature()
        }

        await store.send(\.auth.continueInDemoModeTapped)
        await store.receive(\.auth.signInResponse.success)
        await store.receive(\.navigateToMainTab) {
            $0.screen = .mainTab(MainTabFeature.State())
            $0.currentUser = demoUser
        }
    }

    @MainActor
    func testOnboardingCompleteGoesToMainTab() async {
        let userId = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
        let createdUser = User(
            id: userId,
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

        let store = TestStore(
            initialState: AppFeature.State(
                screen: .onboarding(OnboardingFeature.State(userId: userId))
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.profileClient.isUsernameAvailable = { _ in true }
            $0.profileClient.createProfile = { _, _, _ in createdUser }
        }

        await store.send(\.onboarding.usernameChanged, "naren") {
            $0.onboarding?.username = "naren"
        }
        await store.send(\.onboarding.displayNameChanged, "Naren Y") {
            $0.onboarding?.displayName = "Naren Y"
        }
        await store.send(\.onboarding.submitTapped) {
            $0.onboarding?.isLoading = true
        }
        await store.receive(\.onboarding.usernameCheckResponse.success) {
            $0.onboarding?.isUsernameAvailable = true
        }
        await store.receive(\.onboarding.profileCreateResponse.success) {
            $0.onboarding?.isLoading = false
        }
        await store.receive(\.navigateToMainTab) {
            $0.screen = .mainTab(MainTabFeature.State())
            $0.currentUser = createdUser
        }
    }
}
