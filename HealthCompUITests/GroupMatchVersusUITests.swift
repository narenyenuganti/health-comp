import XCTest

final class GroupMatchVersusUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testVersusIntroShowsTheLineup() {
        let app = XCUIApplication.launchGroupLab("versus-ffa")
        XCTAssertTrue(app.groupElement("competition.group.versus").waitForExistence(timeout: 8))
    }
}
