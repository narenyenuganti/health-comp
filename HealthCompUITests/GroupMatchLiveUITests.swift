import XCTest

/// Live free-for-all, live with a bot, one day, and Leave Match, in the
/// `group-matches` lab. Now is Day 4 of a week that began on Thursday.
final class GroupMatchLiveUITests: XCTestCase {
    private static let audit = XCUIAccessibilityAuditType.textClipped
        .union(.hitRegion)
        .union(.sufficientElementDescription)
    private static let ax5 = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLiveFreeForAllShowsStandingsAndTheWeek() {
        let app = XCUIApplication.launchGroupLab("live-ffa")
        let first = app.groupElement("competition.group.standing.1")
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertTrue(app.navigationBars["Four-Way"].exists)
        XCTAssertEqual(first.label, "1st, Sam, 1,712 points")
        XCTAssertEqual(app.groupElement("competition.group.standing.2").label, "2nd, You, 1,664 points")
        XCTAssertEqual(app.groupElement("competition.group.standing.4").label, "4th, Leo, 1,203 points")
        XCTAssertEqual(app.groupElement("competition.group.lead").label, "You're 2nd. 48 behind Sam.")
        let takes = app.groupElement("competition.group.what-it-takes")
        XCTAssertTrue(takes.label.contains("Outscore Sam by 49 from here to take 1st."), takes.label)
        XCTAssertTrue(takes.label.contains("Priya is 166 behind you."), takes.label)
        shot(app, "LiveFFA-top")

        app.swipeUp()
        let dayOne = app.groupElement("competition.group.week.1")
        XCTAssertTrue(dayOne.label.contains("Sam 448 points, won the day"), dayOne.label)
        XCTAssertTrue(app.groupElement("competition.group.week.2").label.contains("You 437 points, won the day"))
        // Today isn't won yet, and later days haven't happened.
        XCTAssertFalse(app.groupElement("competition.group.week.4").label.contains("won the day"))
        XCTAssertTrue(app.groupElement("competition.group.week.5").label.hasSuffix("Not played yet."))
        XCTAssertFalse(app.buttons["competition.group.nudge"].exists)
        shot(app, "LiveFFA-week")
    }

    func testOneDayShowsEveryonesRingsAndReactsToOthersOnly() {
        let app = XCUIApplication.launchGroupLab("live-ffa")
        let dayThree = app.groupElement("competition.group.week.3")
        XCTAssertTrue(dayThree.waitForExistence(timeout: 8))
        app.swipeUp()
        dayThree.tap()
        XCTAssertTrue(app.navigationBars["Saturday"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.groupElement("competition.group.day.status").label, "DAY 3 · FINAL")
        let sam = app.buttons["competition.group.day.player.2"]
        XCTAssertEqual(
            sam.label,
            "Sam, won the day, 451 points, Move 180 percent, Exercise 135 percent, Stand 135 percent"
        )
        // Best first: Sam, Priya, you, Leo.
        let order = [2, 3, 1, 4].map { app.groupElement("competition.group.day.player.\($0)").frame.minY }
        XCTAssertEqual(order, order.sorted())
        // Your own day takes no reaction.
        XCTAssertFalse(app.buttons["competition.group.day.player.1"].exists)
        XCTAssertTrue(app.groupElement("competition.group.day.player.1").label.hasPrefix("You, 398 points"))
        shot(app, "DayFFA-final")

        sam.tap()
        let clap = app.buttons["competition.react.clap"]
        XCTAssertTrue(clap.waitForExistence(timeout: 3))
        clap.tap()
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: clap)
        waitForExpectations(timeout: 5)
        shot(app, "DayFFA-reacted")
    }

    func testLiveWithABotShowsPointsOnly() {
        let app = XCUIApplication.launchGroupLab("live-bot")
        let bot = app.groupElement("competition.group.standing.3")
        XCTAssertTrue(bot.waitForExistence(timeout: 8))
        XCTAssertEqual(bot.label, "3rd, Erratic, bot, 1,445 points")
        shot(app, "LiveBot-top")

        app.swipeUp()
        XCTAssertTrue(
            app.staticTexts["Erratic’s week was set before Day 1. Bots can’t be nudged and don’t get reactions."].exists
        )
        XCTAssertTrue(app.groupElement("competition.group.week.1").label.contains("Erratic 520 points, won the day"))
        shot(app, "LiveBot-week")

        app.groupElement("competition.group.week.1").tap()
        let erratic = app.groupElement("competition.group.day.player.3")
        XCTAssertTrue(erratic.waitForExistence(timeout: 5))
        // Points, no rings, and no reaction.
        XCTAssertEqual(erratic.label, "Erratic, bot, won the day, 520 points")
        XCTAssertFalse(app.buttons["competition.group.day.player.3"].exists)
        XCTAssertTrue(app.buttons["competition.group.day.player.2"].exists)
        shot(app, "DayBot-final")
    }

    func testLeaveMatchConfirmsAndShowsYouLeft() {
        let app = XCUIApplication.launchGroupLab("live-ffa")
        // iOS 18 exposes Menu's identified wrapper, not its nested button, as hittable.
        let more = app.groupElement("competition.more")
        XCTAssertTrue(more.waitForExistence(timeout: 8))
        more.tap()
        let leave = app.buttons["competition.group.leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 3))
        shot(app, "LiveFFA-menu")
        leave.tap()
        let dialog = app.sheets["Leave the match?"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 3))
        XCTAssertTrue(dialog.staticTexts["Your synced points stay in. Points not sent yet won’t count."].exists)
        shot(app, "LiveFFA-leave-confirm")
        // Keep Playing changes nothing.
        let keep = dialog.buttons["Keep Playing"].exists ? dialog.buttons["Keep Playing"] : app.buttons["Keep Playing"]
        keep.tap()
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.groupElement("competition.group.standing.2").label, "2nd, You, 1,664 points")
        more.tap()
        leave.tap()
        XCTAssertTrue(dialog.waitForExistence(timeout: 3))
        dialog.buttons["Leave Match"].tap()

        let you = app.groupElement("competition.group.standing.2")
        expectation(
            for: NSPredicate(format: "label == %@", "2nd, You, left the match, 1,664 points"), evaluatedWith: you
        )
        waitForExpectations(timeout: 5)
        XCTAssertFalse(more.exists)
        XCTAssertEqual(app.groupElement("competition.group.lead").label, "You left on Day 4. Your 1,664 stays in.")
        // Nothing left to chase once you've left.
        XCTAssertFalse(app.groupElement("competition.group.what-it-takes").exists)
        shot(app, "LiveFFA-left")
    }

    func testLiveScreensPassTheAuditAtTheLargestTextSize() throws {
        for setup in ["live-ffa", "live-bot"] {
            let app = XCUIApplication.launchGroupLab(setup, arguments: Self.ax5)
            XCTAssertTrue(app.groupElement("competition.group.standing.1").waitForExistence(timeout: 8))
            try app.performAccessibilityAudit(for: Self.audit)
            for _ in 0..<4 {
                app.swipeUp()
                try app.performAccessibilityAudit(for: Self.audit)
            }
        }
        let app = XCUIApplication.launchGroupLab("live-ffa", arguments: Self.ax5 + ["-AppleInterfaceStyle", "Dark"])
        XCTAssertTrue(app.groupElement("competition.group.standing.1").waitForExistence(timeout: 8))
        try app.performAccessibilityAudit(for: Self.audit)
        app.groupElement("competition.group.week.3").tap()
        XCTAssertTrue(app.buttons["competition.group.day.player.2"].waitForExistence(timeout: 5))
        try app.performAccessibilityAudit(for: Self.audit)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
