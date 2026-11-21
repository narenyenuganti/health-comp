import XCTest

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
        if app.state != .notRunning { app.terminate() }
        XCUIDevice.shared.appearance = .light
        app = nil
    }

    func testHomeChipsSayWhoHoldsTheBeltGoingIn() {
        launchLab()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "LIVE · 5"))
                .firstMatch.waitForExistence(timeout: 3)
        )

        let sam = card("active", 0x17)
        scrollToElement(sam)
        XCTAssertTrue(sam.label.hasPrefix("Sam. Day 2 of 7"), sam.label)
        XCTAssertTrue(sam.label.hasSuffix(". You hold the belt · 1 defense"), sam.label)

        let long = card("active", 0x24)
        scrollToElement(long)
        XCTAssertTrue(long.label.hasPrefix("\(Self.longName). Day 2 of 7"), long.label)
        XCTAssertTrue(long.label.hasSuffix(". \(Self.longName) holds the belt · 1 defense"), long.label)

        let tallying = card("tallying", 0x32)
        scrollToElement(tallying)
        XCTAssertTrue(tallying.label.hasSuffix(". You hold the belt"), tallying.label)
        let rileyLive = card("active", 0x33)
        scrollToElement(rileyLive)
        XCTAssertFalse(rileyLive.label.contains("belt"), rileyLive.label)

        let former = card("active", 0x52)
        scrollToElement(former)
        XCTAssertTrue(former.label.hasPrefix("Former competitor. Day 2 of 7"), former.label)
        XCTAssertFalse(former.label.contains("belt"), former.label)

        scrollToElement(sam)
        sam.tap()
        XCTAssertTrue(app.navigationBars["Sam"].waitForExistence(timeout: 3))
        XCTAssertEqual(labels(containing: "belt").count, 0)
        goBack(to: "Home")

        let result = card("completed", 0x16)
        scrollToElement(result)
        XCTAssertFalse(result.label.contains("belt"), result.label)
        result.tap()
        XCTAssertTrue(app.navigationBars["Sam"].waitForExistence(timeout: 3))
        assertBanner("1st title defense, 3 weeks in a row.")
    }

    func testHeroCardSaysYouHoldTheBelt() {
        launchLab(scenario: "belt-hero")
        let hero = card("active", 0x17)
        XCTAssertTrue(hero.waitForExistence(timeout: 3))
        XCTAssertTrue(hero.label.hasPrefix("Sam. Day 2 of 7"), hero.label)
        XCTAssertTrue(hero.label.hasSuffix(". You hold the belt · 1 defense"), hero.label)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "LIVE · ")).firstMatch.exists)
        let outside = labels(containing: "belt").allElementsBoundByIndex
            .filter { !hero.frame.contains($0.frame) }
        XCTAssertEqual(outside.map(\.label), [])
    }

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
            XCTAssertEqual(row.elementType, .button)
            XCTAssertEqual(normalized(row.label), label)
        }

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

    func testPersonPageWhereYouHoldTheBeltOpensEachWeeksResult() {
        launchLab()
        openPerson(0x16, title: "Sam")
        XCTAssertEqual(element("competition.person.record").label, "Sam, 3 wins, 2 losses, 1 tie. 6 weeks")
        XCTAssertEqual(
            element("competition.person.belt").label,
            "You hold the belt, Since Jul 31 · 2 weeks, Title reigns: You 2, Sam 1, Title defenses: You 0, Sam 1, Longest reign: You 2 weeks, Sam 2 weeks, Biggest win: You +160, Sam +160"
        )
        XCTAssertTrue(app.staticTexts["WEEKS"].exists)

        let weeks: [(String, UInt8, String)] = [
            ("completed", 0x16, "You won · Aug 8 – 14. You 3,210 points. Sam 3,050 points"),
            ("archived", 0x15, "Tied · Aug 1 – 7. You 3,000 points. Sam 3,000 points"),
            ("archived", 0x14, "You won · Jul 25 – 31. You 3,210 points. Sam 3,050 points. You took the belt"),
            ("archived", 0x13, "Sam won · Jul 18 – 24. You 2,980 points. Sam 3,140 points"),
            ("archived", 0x12, "Sam won · Jul 11 – 17. You 2,980 points. Sam 3,140 points. Sam took the belt"),
            ("archived", 0x11, "You won · Jul 4 – 10. You 3,210 points. Sam 3,050 points. You took the belt"),
        ]
        func listed() -> [String] {
            var ids = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "competition.sharing."))
                .allElementsBoundByIndex.map(\.identifier)
            let live = ids.firstIndex(of: weekID("active", 0x17))
            XCTAssertNotNil(live, "this week's card")
            if let live { ids.remove(at: live) }
            return ids
        }
        XCTAssertTrue(element("competition.person.now").exists)
        XCTAssertEqual(listed(), weeks.prefix(5).map { weekID($0.0, $0.1) })
        let allWeeks = element("competition.person.allWeeks")
        scrollToElement(allWeeks)
        XCTAssertTrue(allWeeks.label.hasPrefix("All 6 weeks"), allWeeks.label)
        allWeeks.tap()
        XCTAssertTrue(element(weekID("archived", 0x11)).waitForExistence(timeout: 3))
        XCTAssertEqual(listed(), weeks.map { weekID($0.0, $0.1) })
        for (state, byte, label) in weeks {
            let row = element(weekID(state, byte))
            scrollToElement(row)
            XCTAssertEqual(normalized(row.label), label)
            XCTAssertGreaterThanOrEqual(row.frame.height, 44)
        }

        let results: [(String, UInt8, String?)] = [
            ("archived", 0x11, "You took the belt"),
            ("archived", 0x12, "Sam took the belt, You held it for 1 week."),
            ("archived", 0x13, "Sam’s 1st title defense, 2 weeks in a row."),
            ("archived", 0x14, "You took the belt, Sam held it for 2 weeks."),
            ("archived", 0x15, nil),
            ("completed", 0x16, "1st title defense, 3 weeks in a row."),
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
        XCTAssertEqual(
            element("competition.person.belt").label,
            "You hold the belt, Since Jul 31 · 3 weeks, 1 defense, Title reigns: You 2, Sam 1, Title defenses: You 1, Sam 1, Longest reign: You 3 weeks, Sam 2 weeks, Biggest win: You +160, Sam +160"
        )
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
            "\(Self.longName) holds the belt, Since Jul 31 · 3 weeks, 1 defense, Title reigns: You 0, \(Self.longName) 1, Title defenses: You 0, \(Self.longName) 1, Longest reign: You –, \(Self.longName) 3 weeks, Biggest win: You –, \(Self.longName) +160"
        )
        let took = element(weekID("archived", 0x21))
        scrollToElement(took)
        XCTAssertTrue(normalized(took.label).hasSuffix(". \(Self.longName) took the belt"), took.label)

        openWeek(weekID("archived", 0x23), title: Self.longName)
        assertBanner("\(Self.longName)’s 1st title defense, 3 weeks in a row.")
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
        XCTAssertEqual(element("competition.person.belt").label, "The belt is retired")
        let week = element(weekID("archived", 0x51))
        XCTAssertEqual(
            normalized(week.label),
            "You won · Aug 8 – 14. You 3,210 points. Former competitor 3,050 points. You took the belt"
        )
        openWeek(weekID("archived", 0x51), title: "Former competitor")
        assertBanner("You took the belt")
    }

    func testPersonPageWhileTheNextWeekIsTallying() {
        launchLab()
        openPerson(0x31, title: "Riley")
        XCTAssertEqual(element("competition.person.belt").label, "You hold the belt, Since Aug 7 · 1 week")
        XCTAssertEqual(
            Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "competition.sharing."))
                .allElementsBoundByIndex.map(\.identifier)),
            [weekID("tallying", 0x32), weekID("archived", 0x31)]
        )
        openWeek(weekID("archived", 0x31), title: "Riley")
        assertBanner("You took the belt")
    }

    func testHistoryRecordsPassTheAuditAtAccessibility5() throws {
        continueAfterFailure = true
        for appearance in ["Light", "Dark"] {
            launchLab(Self.darkAX5.map { $0 == "Dark" ? appearance : $0 })
            openHistory()
            shot("history", "\(appearance.lowercased())-ax5")
            try audit()
        }
    }

    func testBeltScreensPassTheAuditAtAccessibility5() throws {
        continueAfterFailure = true
        launchLab(Self.darkAX5)
        for (state, byte) in [("active", UInt8(0x17)), ("active", 0x24), ("tallying", 0x32), ("active", 0x33)] {
            let card = card(state, byte)
            showAtTop(card)
            XCTAssertTrue(card.isHittable)
        }
        showAtTop(card("active", 0x52))
        try audit(ignoringClipped: ["FORMER COMPETITOR"])

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

    private func audit(
        ignoringClipped ignored: Set<String> = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var issues: [String] = []
        try app.performAccessibilityAudit(
            for: XCUIAccessibilityAuditType.textClipped
                .union(.hitRegion)
                .union(.sufficientElementDescription)
        ) { issue in
            let element = issue.element
            if issue.auditType == .textClipped, let element,
               self.app.navigationBars.firstMatch.frame.contains(element.frame)
                || ignored.contains(element.label) {
                return true
            }
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

    private func labels(containing text: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

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
            let scrollView = app.scrollViews.firstMatch
            let surface: XCUIElement = scrollView.exists ? scrollView : app
            if element.exists, element.isHittable,
               app.frame.contains(element.frame)
                || (element.frame.height > surface.frame.height / 2
                    && surface.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.minY + 1))) {
                return
            }
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
