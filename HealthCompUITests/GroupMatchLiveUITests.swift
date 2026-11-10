import XCTest

final class GroupMatchLiveUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLiveFreeForAllShowsStandingsAndTheWeek() {
        let app = XCUIApplication.launchGroupLab("live-ffa")
        XCTAssertTrue(app.groupElement("competition.group.standing.1").waitForExistence(timeout: 8))
    }
}
