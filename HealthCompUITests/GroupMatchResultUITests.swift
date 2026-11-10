import XCTest

final class GroupMatchResultUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTiedResultSaysNoBelt() {
        let app = XCUIApplication.launchGroupLab("result-ffa-tied")
        XCTAssertTrue(app.groupElement("competition.group.result.no-belt").waitForExistence(timeout: 8))
    }
}
