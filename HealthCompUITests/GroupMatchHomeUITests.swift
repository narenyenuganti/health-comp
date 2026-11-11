import XCTest

/// Home's group match cards, in their own block beside the duels: an invite,
/// a lobby waiting on people, live free-for-all and doubles, two results and
/// one that didn't start. Now is Day 4.
final class GroupMatchHomeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func card(_ state: String, _ id: Int) -> String {
        "competition.sharing.\(state).c3000000-0000-4000-8000-0000000000\(String(format: "%02d", id))"
    }

    func testHomeCardsCarryTheirState() {
        let app = XCUIApplication.launchGroupLab("home")
        let live = app.groupElement(card("active", 4))
        XCTAssertTrue(live.waitForExistence(timeout: 8))
        XCTAssertEqual(
            live.label,
            "Four-Way, Live. Day 4 of 7. You're 2nd. 48 behind Sam. 1st, Sam, 1,712 points. "
                + "2nd, You, 1,664 points. 3rd, Priya, 1,498 points. 4th, Leo, 1,203 points."
        )
        XCTAssertEqual(
            app.groupElement(card("active", 5)).label,
            "Doubles, Live. Day 4 of 7. Your team leads by 247. You + Priya, 3,162 points. Sam + Leo, 2,915 points."
        )
        XCTAssertEqual(app.groupElement(card("pending", 3)).label, "Four-Way, Invite. Sam invited you.")
        XCTAssertEqual(app.groupElement(card("pending", 1)).label, "Four-Way, Waiting. Waiting on Priya and Leo.")
        XCTAssertTrue(app.groupElement(card("completed", 8)).label.hasPrefix("Four-Way, Final."))
        XCTAssertTrue(app.groupElement(card("completed", 8)).label.contains("You finished 1st."))
        XCTAssertTrue(app.groupElement(card("completed", 10)).label.contains("Your team won."))
        XCTAssertTrue(app.groupElement(card("declined", 2)).label.hasSuffix("Priya didn’t accept."))
        XCTAssertTrue(app.groupElement(card("declined", 26)).label.hasSuffix("Sam withdrew."))
        XCTAssertFalse(app.groupElement("competition.create.empty").exists)
        shot(app, "Home-1")
        for page in 2...4 {
            app.swipeUp()
            shot(app, "Home-\(page)")
        }
    }

    func testACardOpensItsMatch() {
        let app = XCUIApplication.launchGroupLab("home")
        let live = app.groupElement(card("active", 4))
        XCTAssertTrue(live.waitForExistence(timeout: 8))
        live.tap()
        XCTAssertTrue(app.groupElement("competition.group.standings").waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Four-Way"].exists)
    }

    func testHomeAtTheLargestTextSize() {
        let app = XCUIApplication.launchGroupLab(
            "home", arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        )
        XCTAssertTrue(app.groupElement(card("active", 4)).waitForExistence(timeout: 8))
        shot(app, "Home-ax5")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
