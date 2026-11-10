import XCTest

/// Live doubles in the `group-matches` lab: you and Priya against Sam and
/// Leo, Day 4.
final class GroupMatchLiveDoublesUITests: XCTestCase {
    private static let audit = XCUIAccessibilityAuditType.textClipped
        .union(.hitRegion)
        .union(.sufficientElementDescription)
    private static let ax5 = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLiveDoublesShowsBothTeams() {
        let app = XCUIApplication.launchGroupLab("live-doubles")
        let yours = app.groupElement("competition.group.team.you")
        XCTAssertTrue(yours.waitForExistence(timeout: 8))
        XCTAssertTrue(app.navigationBars["Doubles"].exists)
        XCTAssertEqual(yours.label, "You + Priya, 3,162 points")
        XCTAssertEqual(app.groupElement("competition.group.team.them").label, "Sam + Leo, 2,915 points")
        XCTAssertEqual(app.groupElement("competition.group.lead").label, "Your team leads by 247.")
        XCTAssertTrue(labeled("You, 1,664 points, 53 percent. Priya, 1,498 points, 47 percent", in: app).exists)
        XCTAssertTrue(labeled("Sam, 1,712 points, 59 percent. Leo, 1,203 points, 41 percent", in: app).exists)
        shot(app, "LiveDoubles-top")

        app.swipeUp()
        XCTAssertTrue(
            app.groupElement("competition.group.week.1").label.contains("You + Priya 801 points, won the day")
        )
        let nudge = app.buttons["competition.group.nudge"]
        XCTAssertEqual(nudge.label, "Nudge Priya")
        shot(app, "LiveDoubles-bottom")
        nudge.tap()
        XCTAssertTrue(app.groupElement("competition.group.nudge.sent").waitForExistence(timeout: 5))
        shot(app, "LiveDoubles-nudged")
    }

    func testOneDayIsGroupedByTeam() {
        let app = XCUIApplication.launchGroupLab("live-doubles")
        XCTAssertTrue(app.groupElement("competition.group.team.you").waitForExistence(timeout: 8))
        app.swipeUp()
        app.groupElement("competition.group.week.3").tap()
        XCTAssertTrue(app.navigationBars["Saturday"].waitForExistence(timeout: 5))
        let yours = labeled("You + Priya, won the day, 800 points", in: app)
        let theirs = labeled("Sam + Leo, 739 points", in: app)
        XCTAssertTrue(yours.exists)
        XCTAssertTrue(theirs.exists)
        // Each team's players sit under its own header.
        let you = app.groupElement("competition.group.day.player.1")
        let priya = app.buttons["competition.group.day.player.3"]
        let sam = app.buttons["competition.group.day.player.2"]
        XCTAssertLessThan(yours.frame.minY, you.frame.minY)
        XCTAssertLessThan(you.frame.minY, priya.frame.minY)
        XCTAssertLessThan(priya.frame.minY, theirs.frame.minY)
        XCTAssertLessThan(theirs.frame.minY, sam.frame.minY)
        shot(app, "DayDoubles-final")
    }

    func testLeaveMatchLeavesYourPartnerPlaying() {
        let app = XCUIApplication.launchGroupLab("live-doubles")
        let more = app.buttons["competition.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 8))
        more.tap()
        app.buttons["competition.group.leave"].tap()
        let dialog = app.sheets["Leave the match?"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 3))
        XCTAssertTrue(
            dialog.staticTexts["Your synced points stay in. Points not sent yet won’t count. Priya plays on."].exists
        )
        dialog.buttons["Leave Match"].tap()

        let left = labeled("You, 1,664 points, 53 percent, left the match. Priya, 1,498 points, 47 percent", in: app)
        XCTAssertTrue(left.waitForExistence(timeout: 5))
        XCTAssertFalse(more.exists)
        XCTAssertEqual(
            app.groupElement("competition.group.lead").label, "You left on Day 4. Your 1,664 stays with your team."
        )
        app.swipeUp()
        XCTAssertFalse(app.buttons["competition.group.nudge"].exists)
        app.swipeDown()
        shot(app, "LiveDoubles-left")
    }

    func testLiveDoublesPassesTheAuditAtTheLargestTextSize() throws {
        for arguments in [Self.ax5, Self.ax5 + ["-AppleInterfaceStyle", "Dark"]] {
            let app = XCUIApplication.launchGroupLab("live-doubles", arguments: arguments)
            XCTAssertTrue(app.groupElement("competition.group.team.you").waitForExistence(timeout: 8))
            try app.performAccessibilityAudit(for: Self.audit)
            for _ in 0..<4 {
                app.swipeUp()
                try app.performAccessibilityAudit(for: Self.audit)
            }
        }
    }

    private func labeled(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
