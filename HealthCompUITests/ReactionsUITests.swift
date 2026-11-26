import XCTest

final class ReactionsUITests: XCTestCase {
    private var app: XCUIApplication!
    private let kinds = ["clap", "fire", "huffing", "salute"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.appearance = .light
        app = nil
    }

    func testDayReactionSavesTogglesAndClearsFromHome() {
        launch()
        let jordan = card("active", "Jordan")
        scrollToElement(jordan)
        XCTAssertTrue(
            jordan.label.hasSuffix(". Huffing. Jordan reacted to your Day 2"),
            jordan.label
        )

        jordan.tap()
        XCTAssertTrue(app.navigationBars["Jordan"].waitForExistence(timeout: 3))
        let latest = app.buttons["competition.reaction.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 3))
        XCTAssertEqual(latest.label, "Huffing. Jordan reacted to your Day 2")
        XCTAssertEqual(app.buttons.matching(identifier: "competition.reaction.latest").count, 1)
        XCTAssertGreaterThanOrEqual(latest.frame.height, 44)
        latest.tap()

        XCTAssertTrue(waitFor(app.buttons["competition.strip.day.2"], "isSelected == true", timeout: 3))
        let received = element("competition.reaction.received")
        XCTAssertTrue(received.waitForExistence(timeout: 3))
        scrollToElement(received)
        XCTAssertEqual(received.label, "Huffing. Jordan reacted to your Day 2")
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "competition.reaction.received").count,
            1
        )
        let heading = app.staticTexts["REACT TO JORDAN’S DAY"]
        scrollToElement(heading)
        XCTAssertTrue(heading.exists)
        XCTAssertFalse(app.staticTexts["Jordan sees your reaction on this day."].exists)
        XCTAssertLessThan(received.frame.maxY, heading.frame.minY + 1)
        scrollToElement(chip("clap"))
        assertChips(selected: nil)
        XCTAssertGreaterThan(chip("clap").frame.minY, heading.frame.maxY - 1)
        XCTAssertFalse(element("competition.react.error").exists)

        chip("fire").tap()
        XCTAssertTrue(chip("fire").isSelected)
        for kind in kinds { XCTAssertFalse(chip(kind).isEnabled, "\(kind) while saving") }
        chip("clap").tap()
        XCTAssertTrue(waitFor(chip("fire"), "isEnabled == true", timeout: 6))
        assertChips(selected: "fire")

        chip("fire").tap()
        XCTAssertFalse(chip("fire").isSelected)
        XCTAssertFalse(chip("fire").isEnabled)
        XCTAssertTrue(waitFor(chip("fire"), "isEnabled == true", timeout: 6))
        assertChips(selected: nil)

        chip("clap").tap()
        XCTAssertTrue(waitFor(chip("clap"), "isEnabled == true", timeout: 6))
        chip("salute").tap()
        XCTAssertTrue(waitFor(chip("salute"), "isEnabled == true", timeout: 6))
        assertChips(selected: "salute")

        XCTAssertTrue(latest.exists)

        openDay(3)
        XCTAssertFalse(element("competition.reaction.received").exists)
        scrollToElement(chip("clap"))
        assertChips(selected: nil)
        openDay(2)
        scrollToElement(chip("salute"))
        assertChips(selected: "salute")

        goBack()
        let seen = card("active", "Jordan")
        scrollToElement(seen)
        XCTAssertFalse(seen.label.contains("reacted"), seen.label)
        seen.tap()
        XCTAssertTrue(app.navigationBars["Jordan"].waitForExistence(timeout: 3))
        XCTAssertFalse(latest.waitForExistence(timeout: 1))
        goBack()

        pullToRefresh()
        let again = card("active", "Jordan")
        XCTAssertTrue(
            waitFor(again, "label ENDSWITH '. Fire. Jordan reacted to your Day 3'", timeout: 5),
            again.label
        )
        scrollToElement(again)
        again.tap()
        XCTAssertTrue(latest.waitForExistence(timeout: 3))
        XCTAssertEqual(latest.label, "Fire. Jordan reacted to your Day 3")
        latest.tap()
        XCTAssertTrue(waitFor(app.buttons["competition.strip.day.3"], "isSelected == true", timeout: 3))
        scrollToElement(element("competition.reaction.received"))
        XCTAssertEqual(
            element("competition.reaction.received").label,
            "Fire. Jordan reacted to your Day 3"
        )
    }

    func testFailedReactionRevertsShowsTheErrorAndRetries() {
        launch()
        open("active", "Sam")
        XCTAssertFalse(app.buttons["competition.reaction.latest"].exists)
        openDay(1)
        XCTAssertFalse(element("competition.reaction.received").exists)
        scrollToElement(chip("clap"))
        XCTAssertTrue(app.staticTexts["REACT TO SAM’S DAY"].exists)
        chip("clap").tap()
        XCTAssertTrue(chip("clap").isSelected)
        let error = element("competition.react.error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "Couldn’t send your reaction. Try again.")
        assertChips(selected: nil)
        for kind in kinds { XCTAssertTrue(chip(kind).isEnabled, kind) }

        chip("clap").tap()
        XCTAssertTrue(waitFor(chip("clap"), "isSelected == true", timeout: 5))
        XCTAssertTrue(error.waitForNonExistence(timeout: 3))
        assertChips(selected: "clap")

        goBack()
        open("completed", "Quinn")
        let panel = element("competition.result.react")
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["REACT TO THE RESULT"].exists)
        XCTAssertFalse(element("competition.reaction.received").exists)
        scrollToElement(chip("fire"))
        chip("fire").tap()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "Couldn’t send your reaction. Try again.")
        assertChips(selected: nil)
        chip("fire").tap()
        XCTAssertTrue(waitFor(chip("fire"), "isSelected == true", timeout: 5))
        XCTAssertFalse(error.exists)

        openResultWeek()
        XCTAssertEqual(reactionsList(), ["Fire. You reacted to the result"])
    }

    func testResultPanelAndTheWeeksReactionsList() {
        launch()
        let riley = card("completed", "Riley")
        scrollToElement(riley)
        let label = riley.label
        XCTAssertFalse(label.contains("Moves to History"), label)
        XCTAssertTrue(label.hasSuffix(". Clap. Riley reacted to the result"), label)

        riley.tap()
        XCTAssertTrue(app.navigationBars["Riley"].waitForExistence(timeout: 3))
        let panel = element("competition.result.react")
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "competition.result.react").count, 1)
        let heading = app.staticTexts["REACT TO THE RESULT"]
        let received = element("competition.reaction.received")
        XCTAssertEqual(received.label, "Clap. Riley reacted to the result")
        assertChips(selected: nil)
        XCTAssertLessThan(heading.frame.maxY, chip("clap").frame.minY + 1)
        XCTAssertLessThan(chip("clap").frame.maxY, received.frame.minY + 1)
        let share = app.buttons["competition.result.share"]
        scrollToElement(share)
        XCTAssertLessThanOrEqual(panel.frame.maxY, share.frame.minY)
        XCTAssertTrue(app.buttons["competition.rematch.create"].exists)
        XCTAssertFalse(app.staticTexts["REACT TO RILEY’S DAY"].exists)

        scrollToElement(chip("clap"))
        chip("clap").tap()
        XCTAssertTrue(waitFor(chip("clap"), "isSelected == true", timeout: 3))

        openResultWeek()
        XCTAssertEqual(reactionsList(), [
            "Clap. You reacted to the result",
            "Clap. Riley reacted to the result",
            "Huffing. You reacted to Riley’s Day 3",
            "Fire. Riley reacted to your Day 5",
        ])
        closeDrawer()

        scrollToElement(chip("clap"))
        chip("clap").tap()
        XCTAssertTrue(waitFor(chip("clap"), "isSelected == false", timeout: 3))
        openResultWeek()
        XCTAssertEqual(reactionsList(), [
            "Clap. Riley reacted to the result",
            "Huffing. You reacted to Riley’s Day 3",
            "Fire. Riley reacted to your Day 5",
        ])
        closeDrawer()

        goBack()
        let after = card("completed", "Riley")
        scrollToElement(after)
        XCTAssertFalse(after.label.contains("reacted"), after.label)
        XCTAssertFalse(after.label.contains("Moves to History"), after.label)
    }

    func testTallyingAndTheLastDayStillTakeDayReactions() {
        launch()
        let morgan = card("tallying", "Morgan")
        scrollToElement(morgan)
        XCTAssertTrue(
            morgan.label.hasSuffix(". Fire. Morgan reacted to your Day 6"),
            morgan.label
        )
        morgan.tap()
        XCTAssertTrue(app.navigationBars["Morgan"].waitForExistence(timeout: 3))
        let latest = app.buttons["competition.reaction.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 3))
        let tally = element("competition.tally")
        XCTAssertTrue(tally.exists)
        XCTAssertLessThan(latest.frame.maxY, tally.frame.minY + 1)
        latest.tap()
        XCTAssertTrue(waitFor(app.buttons["competition.strip.day.6"], "isSelected == true", timeout: 3))
        scrollToElement(element("competition.reaction.received"))
        XCTAssertEqual(
            element("competition.reaction.received").label,
            "Fire. Morgan reacted to your Day 6"
        )
        XCTAssertTrue(app.staticTexts["REACT TO MORGAN’S DAY"].exists)
        scrollToElement(chip("salute"))
        chip("salute").tap()
        XCTAssertTrue(waitFor(chip("salute"), "isSelected == true", timeout: 3))
        openDay(7)
        scrollToElement(chip("clap"))
        assertChips(selected: nil)

        goBack()
        open("ends-today", "Casey")
        XCTAssertFalse(app.buttons["competition.reaction.latest"].exists)
        openDay(7)
        scrollToElement(chip("huffing"))
        XCTAssertTrue(app.staticTexts["REACT TO CASEY’S DAY"].exists)
        chip("huffing").tap()
        XCTAssertTrue(waitFor(chip("huffing"), "isSelected == true", timeout: 3))
    }

    func testFormerCompetitorsReactionsShowWithNoPicker() {
        launch()
        let live = card("active", "Former competitor")
        scrollToElement(live)
        XCTAssertTrue(
            live.label.hasSuffix(". Clap. Former competitor reacted to your Day 1"),
            live.label
        )
        live.tap()
        XCTAssertTrue(app.navigationBars["Former competitor"].waitForExistence(timeout: 3))
        let latest = app.buttons["competition.reaction.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 3))
        XCTAssertEqual(latest.label, "Clap. Former competitor reacted to your Day 1")
        latest.tap()
        XCTAssertTrue(waitFor(app.buttons["competition.strip.day.1"], "isSelected == true", timeout: 3))
        scrollToElement(element("competition.reaction.received"))
        XCTAssertEqual(
            element("competition.reaction.received").label,
            "Clap. Former competitor reacted to your Day 1"
        )
        assertNoPicker()
        XCTAssertFalse(app.staticTexts["Former competitor sees your reaction on this day."].exists)
        openDay(2)
        XCTAssertFalse(element("competition.reaction.received").exists)
        assertNoPicker()

        goBack()
        open("completed", "Former competitor")
        let panel = element("competition.result.react")
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        XCTAssertEqual(
            element("competition.reaction.received").label,
            "Salute. Former competitor reacted to the result"
        )
        assertNoPicker()
        XCTAssertFalse(app.staticTexts["REACT TO THE RESULT"].exists)
        openResultWeek()
        XCTAssertEqual(reactionsList(), ["Salute. Former competitor reacted to the result"])
    }

    func testLongNameWrapsAndNoMatchWithoutReactionsShowsALine() throws {
        launch()
        for (state, name) in [("active", "Sam"), ("ends-today", "Casey"), ("completed", "Quinn")] {
            let match = card(state, name)
            scrollToElement(match)
            XCTAssertFalse(match.label.contains("reacted"), "\(name): \(match.label)")
        }
        let name = "Alexandria Montgomery-Featherstonehaugh"
        let long = card("active", "Alexandria")
        scrollToElement(long)
        XCTAssertTrue(long.label.hasSuffix(". Fire. \(name) reacted to your Day 1"), long.label)
        open("active", "Alexandria")
        let latest = app.buttons["competition.reaction.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 3))
        XCTAssertEqual(latest.label, "Fire. \(name) reacted to your Day 1")
        latest.tap()
        XCTAssertTrue(waitFor(app.buttons["competition.strip.day.1"], "isSelected == true", timeout: 3))
        scrollToElement(chip("clap"))
        XCTAssertTrue(app.staticTexts["REACT TO ALEXANDRIA MONTGOMERY-FEATHERSTONEHAUGH’S DAY"].exists)
        XCTAssertFalse(app.staticTexts["\(name) sees your reaction on this day."].exists)
        assertChips(selected: nil)
        try audit("long-name-day")
    }

    func testHomeToolbarDropsLogoAndPullToRefreshLoadsIncomingReaction() {
        launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home.logo"].exists)
        let before = card("active", "Jordan")
        XCTAssertTrue(before.waitForExistence(timeout: 5))
        XCTAssertFalse(before.label.contains("Fire"), before.label)

        let scroll = app.scrollViews.firstMatch
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.05, thenDragTo: end)

        let jordan = card("active", "Jordan")
        XCTAssertTrue(
            waitFor(jordan, "label ENDSWITH '. Fire. Jordan reacted to your Day 3'", timeout: 5),
            jordan.label
        )
    }

    func testDraggingFromAChipSendsNoReaction() {
        launch()
        open("active", "Sam")
        openDay(1)
        scrollToElement(chip("clap"))
        for kind in kinds {
            for dy in [-120.0, 120.0] {
                scrollToElement(chip(kind))
                let start = chip(kind).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                start.press(
                    forDuration: 0.05,
                    thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)),
                    withVelocity: .slow,
                    thenHoldForDuration: 0.2
                )
            }
        }
        scrollToElement(chip("fire"))
        XCTAssertFalse(element("competition.react.error").waitForExistence(timeout: 2))
        assertChips(selected: nil)
        chip("fire").tap()
        XCTAssertTrue(element("competition.react.error").waitForExistence(timeout: 5))
    }

    func testSimulatedFixtureHasNoReactions() {
        launch(.simulated)
        let jordan = card("active", "Jordan")
        scrollToElement(jordan)
        XCTAssertFalse(jordan.label.contains("reacted"), jordan.label)
        jordan.tap()
        XCTAssertTrue(app.navigationBars["Jordan"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["competition.reaction.latest"].exists)
        openDay(2)
        XCTAssertFalse(element("competition.reaction.received").exists)
        assertNoPicker()
        goBack()
        open("completed", "Riley")
        XCTAssertTrue(app.buttons["competition.rematch.create"].waitForExistence(timeout: 3))
        XCTAssertFalse(element("competition.result.react").exists)
        assertNoPicker()
    }

    func testReactionScreensLightDefault() throws {
        try captureScreens(dark: false, largest: false)
    }

    func testReactionScreensDarkDefault() throws {
        try captureScreens(dark: true, largest: false)
    }

    func testReactionScreensLightLargestType() throws {
        try captureScreens(dark: false, largest: true)
    }

    func testReactionScreensDarkLargestType() throws {
        try captureScreens(dark: true, largest: true)
    }

    private func captureScreens(dark: Bool, largest: Bool) throws {
        let suffix = "\(dark ? "dark" : "light")-\(largest ? "ax5" : "default")"
        var arguments: [String] = []
        if dark { arguments += ["-AppleInterfaceStyle", "Dark"] }
        if largest {
            arguments += [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        }
        launch(arguments: arguments)

        let jordan = card("active", "Jordan")
        scrollToElement(jordan)
        revealBottom(of: jordan)
        shot("home-live-\(suffix)")
        try audit(
            "home-live-\(suffix)",
            contrast: false,
            preexistingClippedLabels: [
                "ALEXANDRIA MONTGOMERY-FEATHERSTONEHAUGH", "FORMER COMPETITOR",
            ]
        )
        let riley = card("completed", "Riley")
        scrollToElement(riley)
        revealBottom(of: riley)
        shot("home-result-\(suffix)")

        scrollToElement(jordan)
        jordan.tap()
        let latest = app.buttons["competition.reaction.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 3))
        scrollToElement(latest)
        shot("match-latest-\(suffix)")
        try audit("match-latest-\(suffix)")
        latest.tap()
        XCTAssertTrue(waitFor(app.buttons["competition.strip.day.2"], "isSelected == true", timeout: 3))
        scrollToElement(chip("salute"))
        chip("fire").tap()
        XCTAssertTrue(waitFor(chip("fire"), "isEnabled == true", timeout: 6))
        shot("day-reactions-\(suffix)")
        try audit("day-reactions-\(suffix)")
        goBack()

        open("active", "Sam")
        openDay(1)
        scrollToElement(chip("salute"))
        chip("clap").tap()
        let error = element("competition.react.error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        scrollToElement(error)
        shot("day-reactions-error-\(suffix)")
        try audit("day-reactions-error-\(suffix)")
        goBack()

        open("active", "Former competitor")
        openDay(1)
        let received = element("competition.reaction.received")
        XCTAssertTrue(received.waitForExistence(timeout: 3))
        scrollToElement(received)
        shot("day-reactions-former-\(suffix)")
        try audit("day-reactions-former-\(suffix)")
        goBack()

        open("active", "Alexandria")
        openDay(1)
        scrollToElement(chip("salute"))
        shot("day-reactions-long-name-\(suffix)")
        goBack()

        open("completed", "Riley")
        scrollToElement(chip("clap"))
        chip("clap").tap()
        XCTAssertTrue(waitFor(chip("clap"), "isSelected == true", timeout: 3))
        let panel = element("competition.result.react")
        scrollToElement(panel)
        shot("result-panel-\(suffix)")
        try audit("result-panel-\(suffix)")
        openResultWeek()
        shot("result-week-reactions-\(suffix)")
        try audit("result-week-reactions-\(suffix)")
        closeDrawer()
        XCTAssertTrue(panel.exists)
        goBack()

        open("completed", "Quinn")
        scrollToElement(chip("fire"))
        chip("fire").tap()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        scrollToElement(error)
        shot("result-error-\(suffix)")
        goBack()

        open("completed", "Former competitor")
        let formerPanel = element("competition.result.react")
        XCTAssertTrue(formerPanel.waitForExistence(timeout: 3))
        scrollToElement(formerPanel)
        shot("result-former-\(suffix)")
        try audit("result-former-\(suffix)")
    }

    private enum Scenario: String {
        case remote = "reactions"
        case simulated = "reactions-simulated"
    }

    private func launch(_ scenario: Scenario = .remote, arguments: [String] = []) {
        if app.state != .notRunning { app.terminate() }
        app = XCUIApplication()
        XCUIDevice.shared.appearance = arguments.contains("Dark") ? .dark : .light
        app.launchEnvironment["TZ"] = "America/Los_Angeles"
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", scenario.rawValue,
            "-healthcomp.colorHintSeen", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ] + arguments
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 10))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func chip(_ kind: String) -> XCUIElement {
        app.buttons["competition.react.\(kind)"]
    }

    private func card(_ state: String, _ name: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "competition.sharing.\(state).",
                name
            )
        ).firstMatch
    }

    private func open(_ state: String, _ name: String) {
        let match = card(state, name)
        scrollToElement(match)
        match.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        let title = app.navigationBars.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", String(name.prefix(8)))
        ).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 3), "Opening \(name)")
    }

    private func goBack() {
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
    }

    private func openDay(_ ordinal: Int) {
        let day = app.buttons["competition.strip.day.\(ordinal)"]
        scrollToElement(day)
        day.tap()
        XCTAssertTrue(waitFor(day, "isSelected == true", timeout: 3))
    }

    private func closeDrawer() {
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 3))
    }

    private func openResultWeek() {
        let week = app.buttons["competition.result.week"]
        scrollToElement(week)
        week.tap()
        XCTAssertTrue(app.staticTexts["The Week"].waitForExistence(timeout: 3))
        let list = element("competition.reactions")
        XCTAssertTrue(list.waitForExistence(timeout: 3))
        revealInDrawer(list, title: "The Week")
        XCTAssertTrue(app.staticTexts["REACTIONS"].exists)
    }

    private func reactionsList() -> [String] {
        element("competition.reactions")
            .descendants(matching: .other)
            .matching(NSPredicate(format: "label CONTAINS ' reacted to '"))
            .allElementsBoundByIndex
            .sorted { $0.frame.minY < $1.frame.minY }
            .map(\.label)
    }

    private func assertChips(
        selected: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let names = ["clap": "Clap", "fire": "Fire", "huffing": "Huffing", "salute": "Salute"]
        for kind in kinds {
            let chip = chip(kind)
            XCTAssertTrue(chip.waitForExistence(timeout: 3), kind, file: file, line: line)
            XCTAssertEqual(
                app.buttons.matching(identifier: "competition.react.\(kind)").count,
                1,
                kind,
                file: file,
                line: line
            )
            XCTAssertEqual(chip.label, names[kind], file: file, line: line)
            XCTAssertEqual(chip.isSelected, kind == selected, kind, file: file, line: line)
            XCTAssertGreaterThanOrEqual(chip.frame.width, 44, kind, file: file, line: line)
            XCTAssertGreaterThanOrEqual(chip.frame.height, 44, kind, file: file, line: line)
        }
    }

    private func assertNoPicker(file: StaticString = #filePath, line: UInt = #line) {
        for kind in kinds {
            XCTAssertFalse(chip(kind).exists, kind, file: file, line: line)
        }
        XCTAssertFalse(element("competition.react.error").exists, file: file, line: line)
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'REACT TO'")).firstMatch.exists,
            file: file,
            line: line
        )
    }

    private func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: format),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func pullToRefresh() {
        let jordan = card("active", "Jordan")
        scrollToElement(jordan)
        let surface: XCUIElement = app.scrollViews.firstMatch.exists ? app.scrollViews.firstMatch : app
        surface.swipeDown()
        surface.swipeDown()
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).press(
            forDuration: 0.1,
            thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        )
    }

    private func revealInDrawer(_ target: XCUIElement, title: String) {
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        let drawer = app.scrollViews
            .containing(NSPredicate(format: "identifier == %@", target.identifier)).firstMatch
        func revealed() -> Bool {
            guard target.isHittable else { return false }
            let bottom = min(drawer.frame.maxY, app.frame.maxY - 34)
            if target.frame.height > drawer.frame.height * 0.8 {
                return (target.frame.minY >= drawer.frame.minY
                    && target.frame.minY < drawer.frame.midY)
                    || target.frame.maxY <= bottom
            }
            return target.frame.minY >= drawer.frame.minY && target.frame.maxY <= bottom
        }
        if revealed() { return }
        let heading = app.staticTexts[title].firstMatch
        for _ in 0..<2 where heading.exists && drawer.frame.minY > app.frame.height * 0.3 {
            heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
                forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
            )
        }
        for _ in 0..<30 where !revealed() {
            let up = target.frame.minY >= drawer.frame.minY
            drawer.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: up ? 0.7 : 0.4)).press(
                forDuration: 0.05,
                thenDragTo: drawer.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: up ? 0.5 : 0.6)),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )
        }
        if !revealed() { shot("reveal-failed-\(target.identifier)") }
        XCTAssertTrue(revealed(), "\(target.identifier) in the drawer: \(target.frame) in \(drawer.frame)")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "reactions-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func audit(
        _ name: String,
        contrast: Bool = true,
        preexistingClippedLabels: Set<String> = []
    ) throws {
        let bar = app.navigationBars.firstMatch.frame
        func ignored(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
            guard let element = issue.element else { return issue.auditType == .contrast }
            switch issue.auditType {
            case .contrast:
                return !element.identifier.hasPrefix("competition.react.")
            case .textClipped:
                return bar.contains(element.frame)
                    || preexistingClippedLabels.contains(element.label)
            default:
                return false
            }
        }
        try XCTContext.runActivity(named: "audit \(name)") { _ in
            var types: XCUIAccessibilityAuditType = [
                .textClipped, .hitRegion, .sufficientElementDescription,
            ]
            if contrast { types.insert(.contrast) }
            do {
                try app.performAccessibilityAudit(for: types, ignored)
            } catch let error as NSError where error.code == -56 {
                try app.performAccessibilityAudit(for: types, ignored)
            }
        }
    }

    private func scrollToElement(_ element: XCUIElement) {
        for _ in 0..<24 {
            if element.exists, element.isHittable,
               app.frame.insetBy(dx: 0, dy: 40).contains(element.frame),
               !coveredByRematch(element) { return }
            let collectionView = app.collectionViews.firstMatch
            let scrollView = app.scrollViews.firstMatch
            let surface: XCUIElement = collectionView.exists
                ? collectionView : (scrollView.exists ? scrollView : app)
            let movesTowardEarlierContent = element.exists
                && element.frame != .zero
                && element.frame.midY < surface.frame.midY
            let start = surface.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: movesTowardEarlierContent ? 0.3 : 0.7)
            )
            let end = surface.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: movesTowardEarlierContent ? 0.55 : 0.45)
            )
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
    }

    private func revealBottom(of element: XCUIElement) {
        let surface: XCUIElement = app.scrollViews.firstMatch.exists ? app.scrollViews.firstMatch : app
        for _ in 0..<16 where element.frame.maxY > app.frame.maxY - 60 {
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).press(
                forDuration: 0.05,
                thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            )
        }
    }

    private func coveredByRematch(_ element: XCUIElement) -> Bool {
        let rematch = app.buttons["competition.rematch.create"]
        guard rematch.exists, element.identifier != rematch.identifier else { return false }
        return element.frame.maxY > rematch.frame.minY - 8
    }
}
