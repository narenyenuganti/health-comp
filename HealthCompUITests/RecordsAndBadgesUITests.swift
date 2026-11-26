import XCTest

final class RecordsAndBadgesUITests: XCTestCase {
    private var app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    func testProfileOpensBadgesAndRecordsAndEachOpensItsWeek() {
        launch(["--own-profile"])
        XCTAssertTrue(element("competition.ownProfile.badges").waitForExistence(timeout: 8))
        XCTAssertEqual(element("competition.ownProfile.badges").label, "Badges, 4 of 9 earned")
        shot("profile")

        element("competition.ownProfile.badges").tap()
        XCTAssertTrue(app.navigationBars["Badges"].waitForExistence(timeout: 3))
        XCTAssertEqual(element("competition.badges.count").label, "4 OF 9")
        XCTAssertEqual(
            element("competition.badge.comeback").label,
            "Comeback, earned twice. Win a week you trailed going into the last day."
        )
        XCTAssertEqual(
            element("competition.badge.hotStreak").label, "Hot streak, not yet, best 4. Win five weeks in a row."
        )
        shot("badges")

        element("competition.badge.rival").tap()
        XCTAssertTrue(element("competition.badge.earned").waitForExistence(timeout: 3))
        XCTAssertEqual(element("competition.badge.earned").label, "EARNED ONCE")
        shot("badge-sheet")
        element("competition.badge.latest").tap()
        XCTAssertTrue(element("competition.result").waitForExistence(timeout: 5))
        back(to: "competition.badges.count")
        back(to: "competition.ownProfile.badges")

        let records = element("competition.ownProfile.records")
        scrollTo(records)
        records.tap()
        XCTAssertTrue(app.navigationBars["Records"].waitForExistence(timeout: 3))
        XCTAssertEqual(
            normalized(element("competition.ownRecords.best-week").label),
            "Best week: 2,223. Sep 7 – 13 · beat Sam"
        )
        XCTAssertTrue(element("competition.ownRecords.weeks-won-in-a-row").label.hasPrefix("Weeks won in a row: 4."))
        shot("records")
        element("competition.ownRecords.best-week").tap()
        XCTAssertTrue(element("competition.result").waitForExistence(timeout: 5))
        back(to: "competition.ownRecords.best-week")
    }

    func testHistoryFiltersWeeksAndThePersonPageCountsEachRing() {
        launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        let history = app.buttons["competition.history.open"]
        scrollTo(history)
        history.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))

        let sam = app.buttons["competition.record.a5000000-0000-4000-8000-00000000000a"]
        XCTAssertTrue(sam.waitForExistence(timeout: 5))
        sam.tap()
        XCTAssertTrue(app.navigationBars["Sam"].waitForExistence(timeout: 5))
        let daysWon = element("competition.person.rings.unit").buttons["Days won"]
        scrollTo(daysWon, within: 0.6)
        let move = element("competition.person.rings.move")
        XCTAssertTrue(move.label.hasPrefix("Move: you won 0 weeks, Sam 10."), move.label)
        shot("rings-weeks")
        daysWon.tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH 'Move: you won 19 days, Sam 50.'"), evaluatedWith: move)
        waitForExpectations(timeout: 3)
        XCTAssertFalse(element("competition.person.rings.edge").exists)
        shot("rings-days")
        back(to: "competition.record.a5000000-0000-4000-8000-00000000000a")

        let filter = element("competition.history.filter")
        scrollTo(filter)
        XCTAssertFalse(element("competition.history.person").exists, "One opponent: nobody to pick")
        shot("history")
        filter.buttons["Lost"].tap()
        XCTAssertTrue(element("competition.history.shown").waitForExistence(timeout: 3))
        XCTAssertEqual(element("competition.history.shown").label, "3 OF 10")
        filter.buttons["Won"].tap()
        XCTAssertEqual(element("competition.history.shown").label, "6 OF 10")
        let comeback = element("competition.sharing.archived.a5000000-0000-4000-8000-000000000009")
        scrollTo(comeback)
        XCTAssertTrue(comeback.label.hasSuffix(". You won 4 of 7 days. Comeback badge"), comeback.label)
        shot("history-won")
    }

    func testHistoryCalendarShowsRingsAndOpensMatchOnTap() {
        launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        let history = app.buttons["competition.history.open"]
        scrollTo(history)
        history.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))

        let calendarButton = app.buttons["competition.history.calendar"]
        XCTAssertTrue(calendarButton.waitForExistence(timeout: 5))
        calendarButton.tap()

        let sheet = element("competition.calendar.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["competition.calendar.done"].exists)
        XCTAssertFalse(element("competition.calendar.selected").exists)

        let nonMatchDay = app.buttons["competition.calendar.day.2026-10-1"]
        XCTAssertTrue(nonMatchDay.waitForExistence(timeout: 3))
        XCTAssertFalse(nonMatchDay.isEnabled)

        let matchDay = app.buttons["competition.calendar.day.2026-10-26"]
        XCTAssertTrue(matchDay.waitForExistence(timeout: 3))
        XCTAssertTrue(matchDay.isEnabled)
        matchDay.tap()

        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("competition.result").waitForExistence(timeout: 5))
    }

    private func launch(_ arguments: [String] = []) {
        app.launchEnvironment["TZ"] = "America/Los_Angeles"
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", "rivalry",
            "-healthcomp.colorHintSeen", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ] + arguments
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func back(to identifier: String) {
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(identifier).waitForExistence(timeout: 3))
    }

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2009}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func scrollTo(_ element: XCUIElement, within fraction: CGFloat = 1) {
        let scroll = app.scrollViews.firstMatch
        var lastMinY: CGFloat?
        for _ in 0..<40 {
            if element.exists, element.isHittable {
                let frame = element.frame
                if frame.minY >= scroll.frame.minY, frame.maxY <= app.frame.height * fraction {
                    return
                }
                if let lastMinY, abs(frame.minY - lastMinY) < 1 {
                    return
                }
                lastMinY = frame.minY
                let pastTop = frame.minY < scroll.frame.minY + 12
                scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: pastTop ? 0.35 : 0.7))
                    .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: pastTop ? 0.55 : 0.45)))
            } else {
                lastMinY = nil
                scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                    .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
            }
        }
        XCTAssertTrue(element.isHittable)
    }
}
