import XCTest

/// The belt and the page per person (spec §9.1), driven through the remote
/// Test Lab's `belt` history: Sam (taken, retaken, kept 3 weeks), a
/// 64-character name holding it, Riley waiting on a tallying week, Morgan's
/// ties and a Former competitor.
final class BeltUITests: XCTestCase {
    private var app: XCUIApplication!

    private static let longName = "Maximiliana Alexandrovna Featherstonehaugh-Montgomery Wellington"
    private static let darkAX5 = [
        "-AppleInterfaceStyle", "Dark",
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        "-UIAccessibilityReduceMotionEnabled", "YES",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.appearance = .light
        app = nil
    }

    // MARK: Home

    func testHomeChipsSayWhoHoldsTheBeltGoingIn() {
        launchLab()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "LIVE · 5"))
                .firstMatch.waitForExistence(timeout: 3)
        )

        let sam = card("active", 0x17)
        scrollToElement(sam)
        XCTAssertTrue(sam.label.hasPrefix("Sam. Day 2 of 7"), sam.label)
        XCTAssertTrue(sam.label.hasSuffix(". You hold the belt"), sam.label)

        let long = card("active", 0x24)
        scrollToElement(long)
        XCTAssertTrue(long.label.hasPrefix("\(Self.longName). Day 2 of 7"), long.label)
        XCTAssertTrue(long.label.hasSuffix(". \(Self.longName) holds the belt"), long.label)

        // Riley's earlier week is still tallying: that card says who holds
        // it, and the match after it waits.
        let tallying = card("tallying", 0x32)
        scrollToElement(tallying)
        XCTAssertTrue(tallying.label.hasSuffix(". You hold the belt"), tallying.label)
        let rileyLive = card("active", 0x33)
        scrollToElement(rileyLive)
        XCTAssertFalse(rileyLive.label.contains("belt"), rileyLive.label)

        // A deleted account's belt is retired: no chip.
        let former = card("active", 0x52)
        scrollToElement(former)
        XCTAssertTrue(former.label.hasPrefix("Former competitor. Day 2 of 7"), former.label)
        XCTAssertFalse(former.label.contains("belt"), former.label)

        // The match screen has no belt.
        scrollToElement(sam)
        sam.tap()
        XCTAssertTrue(app.navigationBars["Sam"].waitForExistence(timeout: 3))
        XCTAssertEqual(labels(containing: "belt").count, 0)
        goBack(to: "Home")

        // Sam's last week is still on Home: a 3-week reign shows the banner.
        let result = card("completed", 0x16)
        scrollToElement(result)
        XCTAssertFalse(result.label.contains("belt"), result.label)
        result.tap()
        XCTAssertTrue(app.navigationBars["Sam"].waitForExistence(timeout: 3))
        assertBanner("You kept the belt, 3 weeks in a row.")
    }

    func testHeroCardSaysYouHoldTheBelt() {
        launchLab(scenario: "belt-hero")
        let hero = card("active", 0x17)
        XCTAssertTrue(hero.waitForExistence(timeout: 3))
        XCTAssertTrue(hero.label.hasPrefix("Sam. Day 2 of 7"), hero.label)
        XCTAssertTrue(hero.label.hasSuffix(". You hold the belt"), hero.label)
        // The hero says LIVE on the card; there is no "LIVE · n" section.
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "LIVE · ")).firstMatch.exists)
        // Only the hero card speaks of the belt: its button, and the chip's
        // text that XCUITest also sees inside it.
        let outside = labels(containing: "belt").allElementsBoundByIndex
            .filter { !hero.frame.contains($0.frame) }
        XCTAssertEqual(outside.map(\.label), [])
    }

    // MARK: History

    func testHistoryRecordRowsCarryTheBeltAndOpenThePersonPage() {
        launchLab()
        openHistory()

        let expected: [(UInt8, String)] = [
            (0x16, "Sam, 3 wins, 2 losses, 1 tie. You hold the belt, 3 weeks. Latest: You won · Aug 8 – 14"),
            (0x23, "\(Self.longName), 0 wins, 2 losses, 1 tie. \(Self.longName) holds the belt, 3 weeks. Latest: \(Self.longName) won · Aug 8 – 14"),
            (0x42, "Morgan, 0 wins, 0 losses, 2 ties. Latest: Tied · Aug 8 – 14"),
            (0x51, "Former competitor, 1 win, 0 losses. Latest: You won · Aug 8 – 14"),
            (0x31, "Riley, 1 win, 0 losses. You hold the belt, 1 week. Latest: You won · Aug 1 – 7"),
        ]
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "competition.record.")).count,
            expected.count
        )
        for (byte, label) in expected {
            let row = record(byte)
            scrollToElement(row)
            // A button now, with the same id as before.
            XCTAssertEqual(row.elementType, .button)
            XCTAssertEqual(normalized(row.label), label)
        }

        // The week rows below never carry the belt.
        let week = element(weekID("archived", 0x14))
        scrollToElement(week)
        XCTAssertFalse(week.label.contains("belt"), week.label)

        let sam = record(0x16)
        scrollToElement(sam)
        sam.tap()
        XCTAssertTrue(app.navigationBars["Sam"].waitForExistence(timeout: 3))
        XCTAssertTrue(element("competition.person").exists)
        goBack(to: "History")
        XCTAssertTrue(record(0x16).exists)
    }

    // MARK: Person page

    func testPersonPageWhereYouHoldTheBeltOpensEachWeeksResult() {
        launchLab()
        openPerson(0x16, title: "Sam")
        XCTAssertEqual(element("competition.person.record").label, "Sam, 3 wins, 2 losses, 1 tie. 6 weeks")
        XCTAssertEqual(
            element("competition.person.belt").label,
            "You hold the belt, Since Jul 31 · 3 weeks, Longest reign, You · 3 weeks, Title changes, 3"
        )
        XCTAssertTrue(app.staticTexts["WEEKS"].exists)

        // Newest first; only the three takes carry the belt.
        let weeks: [(String, UInt8, String)] = [
            ("completed", 0x16, "You won · Aug 8 – 14. You 3,210 points. Sam 3,050 points"),
            ("archived", 0x15, "Tied · Aug 1 – 7. You 3,000 points. Sam 3,000 points"),
            ("archived", 0x14, "You won · Jul 25 – 31. You 3,210 points. Sam 3,050 points. You took the belt"),
            ("archived", 0x13, "Sam won · Jul 18 – 24. You 2,980 points. Sam 3,140 points"),
            ("archived", 0x12, "Sam won · Jul 11 – 17. You 2,980 points. Sam 3,140 points. Sam took the belt"),
            ("archived", 0x11, "You won · Jul 4 – 10. You 3,210 points. Sam 3,050 points. You took the belt"),
        ]
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "competition.sharing."))
                .allElementsBoundByIndex.map(\.identifier),
            weeks.map { weekID($0.0, $0.1) }
        )
        for (state, byte, label) in weeks {
            let row = element(weekID(state, byte))
            scrollToElement(row)
            XCTAssertEqual(normalized(row.label), label)
            XCTAssertGreaterThanOrEqual(row.frame.height, 44)
        }

        let results: [(String, UInt8, String?)] = [
            ("archived", 0x11, "You took the belt"),
            ("archived", 0x12, "Sam took the belt, You held it for 1 week."),
            // Sam's second week: a 2-week reign shows nothing.
            ("archived", 0x13, nil),
            ("archived", 0x14, "You took the belt, Sam held it for 2 weeks."),
            // A tie keeps your reign at 2 weeks: nothing.
            ("archived", 0x15, nil),
            ("completed", 0x16, "You kept the belt, 3 weeks in a row."),
        ]
        for (state, byte, banner) in results {
            openWeek(weekID(state, byte), title: "Sam")
            if let banner {
                assertBanner(banner)
            } else {
                XCTAssertTrue(element("competition.result").waitForExistence(timeout: 3))
                XCTAssertFalse(element("competition.result.belt").exists)
            }
            goBack(to: "Sam")
            XCTAssertTrue(element("competition.person.belt").exists)
        }
        goBack(to: "History")
        goBack(to: "Home")
    }

    func testPersonPageWithALongNameHoldingTheBelt() {
        launchLab()
        openPerson(0x23, title: Self.longName)
        XCTAssertEqual(
            element("competition.person.record").label,
            "\(Self.longName), 0 wins, 2 losses, 1 tie. 3 weeks"
        )
        XCTAssertEqual(
            element("competition.person.belt").label,
            "\(Self.longName) holds the belt, Since Jul 31 · 3 weeks, Longest reign, \(Self.longName) · 3 weeks, Title changes, 1"
        )
        let took = element(weekID("archived", 0x21))
        scrollToElement(took)
        XCTAssertTrue(normalized(took.label).hasSuffix(". \(Self.longName) took the belt"), took.label)

        openWeek(weekID("archived", 0x23), title: Self.longName)
        assertBanner("\(Self.longName) kept the belt, 3 weeks in a row.")
        goBack(to: Self.longName)
        openWeek(weekID("archived", 0x22), title: Self.longName)
        XCTAssertTrue(element("competition.result").waitForExistence(timeout: 3))
        XCTAssertFalse(element("competition.result.belt").exists)
        goBack(to: Self.longName)
        openWeek(weekID("archived", 0x21), title: Self.longName)
        assertBanner("\(Self.longName) took the belt")
    }

    func testPersonPageWithOnlyTiesHasNoHolder() {
        launchLab()
        openPerson(0x42, title: "Morgan")
        XCTAssertEqual(element("competition.person.record").label, "Morgan, 0 wins, 0 losses, 2 ties. 2 weeks")
        XCTAssertEqual(element("competition.person.belt").label, "No one holds the belt yet")
        for byte: UInt8 in [0x42, 0x41] {
            let row = element(weekID("archived", byte))
            scrollToElement(row)
            XCTAssertFalse(row.label.contains("belt"), row.label)
            openWeek(weekID("archived", byte), title: "Morgan")
            XCTAssertTrue(element("competition.result").waitForExistence(timeout: 3))
            XCTAssertFalse(element("competition.result.belt").exists)
            goBack(to: "Morgan")
        }
    }

    func testFormerCompetitorRetiresTheBeltButKeepsItsHistory() {
        launchLab()
        openPerson(0x51, title: "Former competitor")
        XCTAssertEqual(
            element("competition.person.record").label,
            "Former competitor, 1 win, 0 losses. 1 week"
        )
        XCTAssertEqual(
            element("competition.person.belt").label,
            "The belt is retired, Longest reign, You · 1 week, Title changes, 1"
        )
        let week = element(weekID("archived", 0x51))
        XCTAssertEqual(
            normalized(week.label),
            "You won · Aug 8 – 14. You 3,210 points. Former competitor 3,050 points. You took the belt"
        )
        // A past result keeps what that week did.
        openWeek(weekID("archived", 0x51), title: "Former competitor")
        assertBanner("You took the belt")
    }

    func testPersonPageWhileTheNextWeekIsTallying() {
        launchLab()
        openPerson(0x31, title: "Riley")
        XCTAssertEqual(
            element("competition.person.belt").label,
            "You hold the belt, Since Aug 7 · 1 week, Longest reign, You · 1 week, Title changes, 1"
        )
        // Only the finished week is listed.
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "competition.sharing.")).count,
            1
        )
        openWeek(weekID("archived", 0x31), title: "Riley")
        assertBanner("You took the belt")
    }

    // MARK: Accessibility 5

    func testBeltScreensPassTheAuditAtAccessibility5() throws {
        // Report every screen's issues, not only the first.
        continueAfterFailure = true
        launchLab(Self.darkAX5)
        // Every Home card, each brought to the top before its audit.
        for (state, byte) in [("active", UInt8(0x17)), ("active", 0x24), ("tallying", 0x32), ("active", 0x33), ("active", 0x52)] {
            let card = card(state, byte)
            showAtTop(card)
            XCTAssertTrue(card.isHittable)
            try audit()
        }

        openPerson(0x23, title: Self.longName)
        try audit()
        let belt = element("competition.person.belt")
        scrollToElement(belt)
        try audit()
        openWeek(weekID("archived", 0x23), title: Self.longName)
        scrollToElement(element("competition.result.belt"))
        try audit()
        goBack(to: Self.longName)
        goBack(to: "History")
        try audit()

        openPerson(0x16, title: "Sam")
        scrollToElement(element("competition.person.belt"))
        try audit()
    }

    // MARK: Screenshot matrix (not in CI)

    func testScreenshotMatrix() {
        let configurations: [(appearance: String, size: String, arguments: [String])] = [
            ("light", "default", []),
            ("dark", "default", ["-AppleInterfaceStyle", "Dark"]),
            ("light", "ax5", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]),
            ("dark", "ax5", Self.darkAX5),
        ]
        for config in configurations {
            let suffix = "\(config.appearance)-\(config.size)"
            let arguments = config.arguments + ["-UIAccessibilityReduceMotionEnabled", "YES"]

            launchLab(arguments, scenario: "belt-hero")
            shot("home-hero", suffix)

            launchLab(arguments)
            showAtTop(card("active", 0x17))
            shot("home-live", suffix)
            showAtTop(card("active", 0x24))
            shot("home-long-name", suffix)
            showAtTop(card("tallying", 0x32))
            shot("home-waiting", suffix)
            showAtTop(card("active", 0x52))
            shot("home-former", suffix)

            openHistory()
            shot("history", suffix)
            showAtTop(record(0x51))
            shot("history-more", suffix)

            for (byte, title, screen) in [
                (UInt8(0x16), "Sam", "person-you"),
                (0x23, Self.longName, "person-long-name"),
                (0x42, "Morgan", "person-vacant"),
                (0x51, "Former competitor", "person-retired"),
            ] {
                openPerson(byte, title: title)
                shot(screen, suffix)
                if config.size == "ax5" {
                    showAtTop(element("competition.person.belt"))
                    shot("\(screen)-belt", suffix)
                }
                if byte == 0x16 {
                    scrollToElement(element(weekID("archived", 0x11)))
                    shot("person-you-weeks", suffix)
                    for (state, week, name) in [
                        ("archived", UInt8(0x11), "result-first-take"),
                        ("archived", 0x14, "result-took-back"),
                        ("archived", 0x12, "result-they-took"),
                        ("completed", 0x16, "result-kept"),
                    ] {
                        openWeek(weekID(state, week), title: title)
                        showBanner()
                        shot(name, suffix)
                        goBack(to: title)
                    }
                }
                if byte == 0x23 {
                    openWeek(weekID("archived", 0x23), title: title)
                    showBanner()
                    shot("result-long-name-kept", suffix)
                    goBack(to: title)
                }
                if byte == 0x51 {
                    openWeek(weekID("archived", 0x51), title: title)
                    showBanner()
                    shot("result-retired", suffix)
                    goBack(to: title)
                }
                goBack(to: "History")
            }
        }
    }

    // MARK: Helpers

    private func launchLab(_ arguments: [String] = [], scenario: String = "belt") {
        if app.state != .notRunning { app.terminate() }
        app = XCUIApplication()
        XCUIDevice.shared.appearance = arguments.contains("Dark") ? .dark : .light
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", scenario,
            "-healthcomp.colorHintSeen", "YES",
        ] + arguments
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
    }

    private func audit(file: StaticString = #filePath, line: UInt = #line) throws {
        // No .dynamicType audit: the reused rows swap layouts with ViewThatFits.
        var issues: [String] = []
        try app.performAccessibilityAudit(
            for: XCUIAccessibilityAuditType.textClipped
                .union(.hitRegion)
                .union(.sufficientElementDescription)
        ) { issue in
            // Name the element, so a failure says what clipped.
            let element = issue.element
            issues.append("\(issue.compactDescription): \(element?.identifier ?? "") \"\(element?.label ?? "")\" \(element?.frame ?? .zero)")
            return true
        }
        if !issues.isEmpty {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "audit-failure"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(issues, [], file: file, line: line)
    }

    private static func uuid(_ byte: UInt8) -> String {
        String(format: "a3000000-0000-4000-8000-0000000000%02x", byte)
    }

    private func card(_ state: String, _ byte: UInt8) -> XCUIElement {
        app.buttons[weekID(state, byte)]
    }

    private func weekID(_ state: String, _ byte: UInt8) -> String {
        "competition.sharing.\(state).\(Self.uuid(byte))"
    }

    /// History's record row, by the id of the person's latest week.
    private func record(_ latest: UInt8) -> XCUIElement {
        element("competition.record.\(Self.uuid(latest))")
    }

    private func openHistory() {
        let history = app.buttons["competition.history.open"]
        scrollToElement(history)
        history.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 3))
    }

    private func openPerson(_ latest: UInt8, title: String) {
        if !app.navigationBars["History"].exists { openHistory() }
        let row = record(latest)
        scrollToElement(row)
        row.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3))
        XCTAssertTrue(element("competition.person.belt").waitForExistence(timeout: 3))
    }

    private func openWeek(_ identifier: String, title: String) {
        let week = element(identifier)
        scrollToElement(week)
        week.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3))
        XCTAssertTrue(element("competition.result").waitForExistence(timeout: 3))
    }

    private func goBack(to title: String) {
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3))
    }

    private func assertBanner(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let banner = element("competition.result.belt")
        XCTAssertTrue(banner.waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertEqual(banner.label, label, file: file, line: line)
    }

    private func showBanner() {
        let banner = element("competition.result.belt")
        XCTAssertTrue(banner.waitForExistence(timeout: 3))
        showAtTop(banner)
    }

    private func labels(containing text: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Date intervals use thin spaces around the dash.
    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2009}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private func shot(_ screen: String, _ suffix: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(screen)-\(suffix)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Scrolls until the element is on screen, then nudges it toward the top.
    private func showAtTop(_ element: XCUIElement) {
        scrollToElement(element)
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<6 where element.frame.minY > scroll.frame.minY + 140 {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    private func scrollToElement(_ element: XCUIElement) {
        for _ in 0..<30 {
            if element.exists, element.isHittable, app.frame.contains(element.frame) { return }
            let scrollView = app.scrollViews.firstMatch
            let surface: XCUIElement = scrollView.exists ? scrollView : app
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
}
