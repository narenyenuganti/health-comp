import ComposableArchitecture
import XCTest
@testable import HealthComp

final class MainTabFeatureTests: XCTestCase {
    private let testUser = User(
        id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
        username: "naren",
        displayName: "Naren Y",
        avatarURL: nil,
        bio: "Competing daily",
        cosmetics: .default,
        cpBalance: 250,
        cpLifetime: 1200,
        privacy: .default,
        createdAt: Date(timeIntervalSince1970: 0)
    )

    @MainActor
    func testDefaultTabIsCompete() {
        let state = MainTabFeature.State(currentUser: testUser)
        XCTAssertEqual(state.selectedTab, .compete)
        XCTAssertEqual(state.currentUser, testUser)
    }

    @MainActor
    func testTabSelection() async {
        let store = TestStore(initialState: MainTabFeature.State(currentUser: testUser)) {
            MainTabFeature()
        }

        await store.send(\.tabSelected, .friends) {
            $0.selectedTab = .friends
        }
        await store.send(\.tabSelected, .awards) {
            $0.selectedTab = .awards
        }
        await store.send(\.tabSelected, .profile) {
            $0.selectedTab = .profile
        }
        await store.send(\.tabSelected, .compete) {
            $0.selectedTab = .compete
        }
    }
}
