import XCTest

final class GroupMatchHistoryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRecordShowsEachKindOfMatch() {
        let app = XCUIApplication.launchGroupLab("history")
        XCTAssertTrue(app.groupElement("competition.group.record.doubles").waitForExistence(timeout: 8))
    }

    func testGroupMatchesSitBelowTheDuelRecordOnlyWhenThereAreSome() {
        var app = XCUIApplication.launchGroupLab("history")
        let record = app.groupElement("competition.group.record.free-for-all")
        XCTAssertTrue(record.waitForExistence(timeout: 8))
        XCTAssertEqual(record.label, "Free-for-all, first in 2 of 3. 1st twice, 2nd once")
        XCTAssertEqual(
            app.groupElement("competition.group.record.doubles").label,
            "Doubles, 1 won, 1 lost. 1–0 with Priya, 0–1 with Sam"
        )
        XCTAssertTrue(app.groupElement("competition.rivalry").exists)
        XCTAssertLessThan(
            app.groupElement("competition.rivalry").frame.minY,
            app.groupElement("competition.group.record").frame.minY
        )

        app.terminate()
        app = XCUIApplication.launchGroupLab("history-duels")
        XCTAssertTrue(app.groupElement("competition.rivalry").waitForExistence(timeout: 8))
        XCTAssertFalse(app.groupElement("competition.group.record").exists)
    }
}
