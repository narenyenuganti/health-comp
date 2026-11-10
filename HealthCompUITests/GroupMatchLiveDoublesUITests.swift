import XCTest

final class GroupMatchLiveDoublesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLiveDoublesShowsBothTeams() {
        let app = XCUIApplication.launchGroupLab("live-doubles")
        XCTAssertTrue(app.groupElement("competition.group.team.you").waitForExistence(timeout: 8))
    }
}
