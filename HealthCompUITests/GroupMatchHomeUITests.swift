import XCTest

final class GroupMatchHomeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHomeCardsCarryTheirState() {
        let app = XCUIApplication.launchGroupLab("home")
        XCTAssertTrue(app.groupElement("competition.sharing.active.c3000000-0000-4000-8000-000000000004").waitForExistence(timeout: 8))
    }
}
