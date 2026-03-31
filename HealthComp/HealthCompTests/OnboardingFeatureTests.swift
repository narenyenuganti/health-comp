import ComposableArchitecture
import XCTest
@testable import HealthComp

final class OnboardingFeatureTests: XCTestCase {

    @MainActor
    func testUsernameAvailableAndProfileCreated() async {
        let createdUser = User(
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
            initialState: OnboardingFeature.State(
                userId: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
            )
        ) {
            OnboardingFeature()
        } withDependencies: {
            $0.profileClient.isUsernameAvailable = { _ in true }
            $0.profileClient.createProfile = { _, _, _ in createdUser }
        }

        await store.send(\.usernameChanged, "naren") {
            $0.username = "naren"
        }
        await store.send(\.displayNameChanged, "Naren Y") {
            $0.displayName = "Naren Y"
        }
        await store.send(\.submitTapped) {
            $0.isLoading = true
        }
        await store.receive(\.usernameCheckResponse.success) {
            $0.isUsernameAvailable = true
        }
        await store.receive(\.profileCreateResponse.success) {
            $0.isLoading = false
        }
    }

    @MainActor
    func testUsernameTaken() async {
        let store = TestStore(
            initialState: OnboardingFeature.State(
                userId: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
            )
        ) {
            OnboardingFeature()
        } withDependencies: {
            $0.profileClient.isUsernameAvailable = { _ in false }
        }

        await store.send(\.usernameChanged, "taken_name") {
            $0.username = "taken_name"
        }
        await store.send(\.displayNameChanged, "Test") {
            $0.displayName = "Test"
        }
        await store.send(\.submitTapped) {
            $0.isLoading = true
        }
        await store.receive(\.usernameCheckResponse.success) {
            $0.isUsernameAvailable = false
            $0.isLoading = false
            $0.errorMessage = "Username is taken. Try another."
        }
    }

    @MainActor
    func testSubmitDisabledWhenFieldsEmpty() async {
        let state = OnboardingFeature.State(
            userId: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
        )
        XCTAssertTrue(state.isSubmitDisabled)
    }

    @MainActor
    func testSubmitEnabledWhenFieldsFilled() async {
        var state = OnboardingFeature.State(
            userId: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
        )
        state.username = "naren"
        state.displayName = "Naren"
        XCTAssertFalse(state.isSubmitDisabled)
    }
}
