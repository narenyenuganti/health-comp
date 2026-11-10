import XCTest

final class GroupMatchHistoryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRecordShowsEachKindOfMatch() {
        let app = XCUIApplication.launchGroupLab("history")
        XCTAssertTrue(app.groupElement("competition.group.record.doubles").waitForExistence(timeout: 8))
    }
}
