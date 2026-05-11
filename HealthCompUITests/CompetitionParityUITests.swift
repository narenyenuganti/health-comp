import XCTest

final class CompetitionParityUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing-apple-parity"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testPendingInviteAcceptDeclineControlsAreVisible() {
        XCTAssertTrue(app.navigationBars["Compete"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Pending Invites"].exists)
        XCTAssertTrue(app.buttons["Accept Apple Activity"].exists)
        XCTAssertTrue(app.buttons["Decline Apple Activity"].exists)
    }

    func testActiveCompetitionDetailShowsScoresAndHistory() {
        XCTAssertTrue(app.staticTexts["Active Competitions"].waitForExistence(timeout: 5))

        let appleActivityRows = app.staticTexts.matching(identifier: "Apple Activity")
        XCTAssertGreaterThan(appleActivityRows.count, 1)
        appleActivityRows.element(boundBy: 1).tap()

        XCTAssertTrue(app.staticTexts["Competition Detail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["You"].exists)
        XCTAssertTrue(app.staticTexts["Opponent"].exists)
        XCTAssertTrue(app.staticTexts["Ahead by 25"].exists)
        XCTAssertTrue(app.staticTexts["Daily Scores"].exists)
    }

    func testFriendChallengeCreatesAppleActivityInvite() {
        XCTAssertTrue(app.tabBars.buttons["Friends"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Friends"].tap()

        XCTAssertTrue(app.navigationBars["Friends"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Alex"].exists)
        app.buttons["Challenge Alex"].tap()

        XCTAssertTrue(app.staticTexts["Challenge sent: Apple Activity"].waitForExistence(timeout: 5))
    }

    func testCompletedCompetitionShowsFinalResult() {
        XCTAssertTrue(app.staticTexts["History"].waitForExistence(timeout: 5))

        let appleActivityRows = app.staticTexts.matching(identifier: "Apple Activity")
        XCTAssertGreaterThan(appleActivityRows.count, 0)
        appleActivityRows.element(boundBy: appleActivityRows.count - 1).tap()

        XCTAssertTrue(app.staticTexts["Final Result: Won"].waitForExistence(timeout: 5))
    }
}
