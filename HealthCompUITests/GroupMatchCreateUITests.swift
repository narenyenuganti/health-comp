import XCTest

final class GroupMatchCreateUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFormatPickerOffersEveryFormat() {
        let app = XCUIApplication.launchGroupLab("format-picker")
        XCTAssertTrue(app.groupElement("competition.group.format.doubles").waitForExistence(timeout: 8))
    }
}
