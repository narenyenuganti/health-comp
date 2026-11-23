import ComposableArchitecture
import XCTest
@testable import HealthComp

final class HomeTourTests: XCTestCase {
    func testSampleMatchFeedsTheRealRingsSheet() {
        let match = HomeTourSample.match(name: "Taylor")
        XCTAssertEqual(match.days.count, 7)
        XCTAssertEqual(match.userPoints, 1_446)
        let today = competitionTodayRings([match])
        XCTAssertEqual(today?.panel.rows.count, 3)
        XCTAssertEqual(today?.points, 199)
        XCTAssertNil(today?.panel.note)
    }

    @MainActor
    func testFinishingTheTourClearsIt() async {
        var state = MainTabFeature.State()
        state.showsTour = true
        let store = TestStore(initialState: state) { MainTabFeature() }
        await store.send(.tourFinished) { $0.showsTour = false }
    }
}
