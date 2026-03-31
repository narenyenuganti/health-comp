import ComposableArchitecture
import XCTest
@testable import HealthComp

final class MainTabFeatureTests: XCTestCase {

    @MainActor
    func testDefaultTabIsCompete() {
        let state = MainTabFeature.State()
        XCTAssertEqual(state.selectedTab, .compete)
    }

    @MainActor
    func testTabSelection() async {
        let store = TestStore(initialState: MainTabFeature.State()) {
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
