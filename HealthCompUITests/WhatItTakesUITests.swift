import XCTest

/// The Today page's what-it-takes panel (spec §9.3, PR 3): every state the
/// local and remote Test Labs can reach, plus the light/dark × default/AX5
/// screenshot matrix.
final class WhatItTakesUITests: XCTestCase {
    private var app: XCUIApplication!

    private static let lightDefault = ["-AppleInterfaceStyle", "Light",
                                       "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.appearance = .light
        app = nil
    }

    // MARK: Remote matches (200% per ring)

    func testWhatItTakesPanelForEveryRemoteState() {
        launchRemote(Self.lightDefault)
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        // One job per screen: never on Home.
        XCTAssertFalse(takes.exists)

        let shown: [(name: String, status: String, label: String)] = [
            ("Sam", "Day 5 of 7",
             "39 points to take the lead. About 240 kilocalories of Move or 12 minutes of Exercise. Sam can still add points today."),
            ("Bartholomew", "Day 3 of 7",
             "50 points to take the lead. About 180 kilocalories of Move and 6 minutes of Exercise. Bartholomew Alexander Christopherson-Montgomery of Westminster can still add points today."),
            ("Morgan", "Day 4 of 7",
             "39 points to take the lead. About 12 minutes of Move Time or 12 minutes of Exercise. Morgan can still add points today."),
            // Level by a fraction; Move is at 200%; they're at today's 600.
            ("Devon", "Day 6 of 7", "1 point to take the lead. About 1 minute of Exercise."),
            ("Priya", "Last day",
             "Out of reach today. Priya is 380 points ahead and you have 110 points left in Move and Exercise today."),
            ("Quinn", "Day 6 of 7", "Out of reach today. All square, and you’ve reached today’s cap."),
        ]
        for match in shown {
            open(match.name)
            XCTAssertTrue(waitForStatus(match.status), match.name)
            XCTAssertTrue(takes.waitForExistence(timeout: 3), match.name)
            XCTAssertEqual(takes.label, match.label)
            XCTAssertEqual(allTakes.count, 1, "\(match.name): one panel")
            let rings = app.otherElements["competition.ownerRings"]
            XCTAssertTrue(rings.exists, match.name)
            XCTAssertLessThan(takes.frame.maxY, rings.frame.minY, "\(match.name): above the rings")
            XCTAssertNotEqual(takes.elementType, .button, "not tappable")
            // The Week page and the day drawer never show it.
            showWeek()
            XCTAssertFalse(takes.exists, match.name)
            app.buttons["Today"].tap()
            XCTAssertTrue(takes.waitForExistence(timeout: 3), match.name)
            goHome()
        }

        let hidden: [(name: String, why: String)] = [
            ("Harper", "Points use an earlier reading. Your rings have changed since."),
            ("Avery", "These points haven’t synced yet."),
            ("Jordan", "You lead by"),
        ]
        for match in hidden {
            open(match.name)
            let rings = app.otherElements["competition.ownerRings"]
            XCTAssertTrue(rings.waitForExistence(timeout: 3), match.name)
            if match.name == "Jordan" {
                XCTAssertTrue(staticText(beginningWith: "You lead by").exists)
            } else {
                XCTAssertTrue(rings.label.contains(String(match.why.dropLast())), rings.label)
                XCTAssertTrue(staticText(beginningWith: "\(match.name) leads by").exists)
            }
            XCTAssertFalse(takes.exists, "\(match.name): \(match.why)")
            goHome()
        }
    }

    func testDayDrawerNeverShowsThePanel() {
        launchRemote(Self.lightDefault)
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        open("Sam")
        XCTAssertTrue(takes.waitForExistence(timeout: 3))
        showWeek()
        let today = app.descendants(matching: .any)["competition.day.5"]
        scrollToElement(today)
        today.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.otherElements["competition.ownerRings"].waitForExistence(timeout: 3))
        XCTAssertFalse(takes.exists)
        app.buttons["Close"].tap()
        app.buttons["Today"].tap()
        XCTAssertTrue(takes.waitForExistence(timeout: 3))
        XCTAssertEqual(allTakes.count, 1)
    }

    // MARK: Local fixture (no per-ring cap)

    /// You score 0 all week, so you're behind from Day 2: the panel must
    /// always agree with the lead line, then go away once the week ends.
    func testLossFixtureFollowsTheScoreThroughTheWeekAndHidesOnceItEnds() {
        launchLocal(fixture: "loss", Self.lightDefault)
        startLocalMatch()
        nextCheckpoint()
        XCTAssertTrue(waitForStatus("Day 1 of 7"))
        XCTAssertTrue(app.staticTexts["All square."].exists)
        XCTAssertTrue(takes.waitForExistence(timeout: 3))
        XCTAssertEqual(
            takes.label,
            "1 point to take the lead. About 10 kilocalories of Move or 1 minute of Exercise. Alex can still add points today."
        )
        XCTAssertEqual(allTakes.count, 1)

        for day in 2...7 {
            nextCheckpoint()
            XCTAssertTrue(waitForStatus(day == 7 ? "Last day" : "Day \(day) of 7"))
            if !app.buttons["Today"].isSelected { app.buttons["Today"].tap() }
            let lead = staticText(beginningWith: "Alex leads by ")
            XCTAssertTrue(lead.waitForExistence(timeout: 3), "Day \(day)")
            let gap = Int(lead.label.filter(\.isNumber))!
            XCTAssertTrue(takes.waitForExistence(timeout: 3), "Day \(day)")
            XCTAssertEqual(takes.label, expectedLocalLabel(gap: gap), "Day \(day)")
            XCTAssertEqual(allTakes.count, 1)
        }

        nextCheckpoint()
        XCTAssertTrue(waitForStatus("Final score pending"))
        XCTAssertFalse(app.buttons["Today"].exists)
        XCTAssertFalse(takes.exists)
    }

    func testTieFixtureHidesThePanelWhileYouLead() {
        launchLocal(fixture: "tie", Self.lightDefault)
        startLocalMatch()
        nextCheckpoint()
        XCTAssertTrue(waitForStatus("Day 1 of 7"))
        XCTAssertTrue(app.otherElements["competition.ownerRings"].waitForExistence(timeout: 3))
        XCTAssertTrue(staticText(beginningWith: "You lead by").exists)
        XCTAssertFalse(takes.exists)
    }

    func testMissingActivityShowsNoPanelEvenWhenBehind() {
        launchLocal(fixture: "missing", Self.lightDefault)
        startLocalMatch()
        nextCheckpoint()
        XCTAssertTrue(waitForStatus("Day 1 of 7"))
        nextCheckpoint()
        XCTAssertTrue(waitForStatus("Day 2 of 7"))
        XCTAssertTrue(staticText(beginningWith: "Alex leads by ").waitForExistence(timeout: 3))
        XCTAssertFalse(app.otherElements["competition.ownerRings"].exists)
        XCTAssertFalse(takes.exists)
    }

    // MARK: Screenshot matrix

    func testWhatItTakesScreenshotMatrix() throws {
        for appearance in ["Light", "Dark"] {
            for (size, category) in [("default", "UICTContentSizeCategoryL"),
                                     ("ax5", "UICTContentSizeCategoryAccessibilityXXXL")] {
                let suffix = "\(appearance.lowercased())-\(size)"
                let arguments = ["-AppleInterfaceStyle", appearance,
                                 "-UIPreferredContentSizeCategoryName", category]
                launchRemote(arguments)
                XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
                for (name, screen) in [("Sam", "takes-reachable"),
                                       ("Bartholomew", "takes-split-long-name"),
                                       ("Morgan", "takes-move-time"),
                                       ("Priya", "takes-out-of-reach")] {
                    open(name)
                    XCTAssertTrue(takes.waitForExistence(timeout: 3), name)
                    XCTAssertTrue(bringIntoView(takes), "\(name) \(suffix): panel on screen under the bar")
                    capture("\(screen)-\(suffix)")
                    try app.performAccessibilityAudit(for: [.textClipped, .contrast]) { issue in
                        // Only this feature's panel; the rest of the screen has its own audits.
                        issue.element?.identifier != "competition.takes"
                    }
                    goHome()
                }

                launchLocal(fixture: "loss", arguments)
                startLocalMatch()
                nextCheckpoint()
                XCTAssertTrue(waitForStatus("Day 1 of 7"))
                XCTAssertTrue(takes.waitForExistence(timeout: 3))
                XCTAssertTrue(bringIntoView(takes), "local \(suffix): panel on screen under the bar")
                capture("takes-local-day1-\(suffix)")
            }
        }
    }

    // MARK: Helpers

    private var takes: XCUIElement { app.descendants(matching: .any)["competition.takes"] }
    private var allTakes: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "competition.takes")
    }

    /// Local fixture: you have 0 today, no per-ring cap, goals of 100.
    private func expectedLocalLabel(gap: Int) -> String {
        let need = gap + 1
        guard need <= 600 else {
            return "Out of reach today. Alex is \(spokenPoints(gap)) ahead and you have 600 points left in Move and Exercise today."
        }
        let kcal = (need + 9) / 10 * 10
        return "\(spokenPoints(need)) to take the lead. About \(kcal) kilocalories of Move or \(need) \(need == 1 ? "minute" : "minutes") of Exercise. Alex can still add points today."
    }

    private func spokenPoints(_ value: Int) -> String {
        let number = value.formatted(.number.locale(Locale(identifier: "en_US")))
        return "\(number) \(value == 1 ? "point" : "points")"
    }

    private func launchRemote(_ appearanceArguments: [String]) {
        relaunch(arguments: [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", "what-it-takes",
        ], appearanceArguments)
    }

    private func launchLocal(fixture: String, _ appearanceArguments: [String]) {
        relaunch(arguments: [
            "--local-competition-test-lab",
            "--local-competition-fixture", fixture,
            "--local-competition-direction", "outgoing",
            "--local-competition-seed", "424242",
            "--local-competition-difficulty", "balanced",
            "--local-competition-run-id", "ui-\(UUID().uuidString.lowercased())",
        ], appearanceArguments)
    }

    private func relaunch(arguments: [String], _ appearanceArguments: [String]) {
        if app.state != .notRunning { app.terminate() }
        app = XCUIApplication()
        XCUIDevice.shared.appearance = appearanceArguments.contains("Dark") ? .dark : .light
        // The one-time color hint would shift scoreboards by test order.
        app.launchArguments = arguments + ["-healthcomp.colorHintSeen", "YES"] + appearanceArguments
        app.launch()
    }

    private func startLocalMatch() {
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        let pending = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "competition.sharing.pending.")
        ).firstMatch
        scrollToElement(pending)
        pending.tap()
        let start = app.buttons["Start with Alex"]
        scrollToElement(start)
        start.tap()
        XCTAssertTrue(waitForStatus("Scheduled"))
    }

    private func open(_ name: String) {
        let card = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "competition.sharing.", name)
        ).firstMatch
        scrollToElement(card)
        card.tap()
        XCTAssertTrue(app.buttons["Week"].waitForExistence(timeout: 3), name)
    }

    private func goHome() {
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
    }

    private func waitForStatus(_ prefix: String, timeout: TimeInterval = 5) -> Bool {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "competition.status", prefix)
        ).firstMatch.waitForExistence(timeout: timeout)
    }

    private func nextCheckpoint() {
        let button = app.buttons["competition.testLab.nextCheckpoint"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: button)], timeout: 8)
        button.tap()
    }

    private func showWeek() {
        let week = app.buttons["Week"]
        XCTAssertTrue(week.waitForExistence(timeout: 3))
        week.tap()
    }

    private func staticText(beginningWith prefix: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// Slow drags until the element's top sits under the navigation bar and,
    /// when it fits, its bottom clears the home indicator. AX5 panels can be
    /// taller than the space left, so then the top wins.
    @discardableResult
    private func bringIntoView(_ element: XCUIElement) -> Bool {
        let window = app.windows.firstMatch
        let navigationBar = app.navigationBars.firstMatch
        func placed() -> (done: Bool, down: Bool) {
            let top = navigationBar.frame.maxY + 8
            let bottom = window.frame.maxY - 40
            let frame = element.frame
            if frame.minY < top { return (false, true) }
            let fits = frame.height <= bottom - top
            return (fits ? frame.maxY <= bottom : frame.minY <= top + 60, false)
        }
        for _ in 0..<40 {
            let state = placed()
            if state.done { return true }
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                .press(
                    forDuration: 0.05,
                    thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: state.down ? 0.9 : 0.8)),
                    withVelocity: .slow,
                    thenHoldForDuration: 0.1
                )
        }
        return placed().done
    }

    private func scrollToElement(_ element: XCUIElement) {
        for _ in 0..<24 {
            if element.exists, element.isHittable, app.frame.contains(element.frame) { return }
            let collectionView = app.collectionViews.firstMatch
            let scrollView = app.scrollViews.firstMatch
            let surface: XCUIElement = collectionView.exists
                ? collectionView : (scrollView.exists ? scrollView : app)
            let earlier = element.exists && element.frame != .zero && element.frame.midY < surface.frame.midY
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: earlier ? 0.3 : 0.7))
                .press(forDuration: 0.05,
                       thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: earlier ? 0.55 : 0.45)))
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
