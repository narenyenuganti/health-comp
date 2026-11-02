import XCTest

/// Nudge, end to end through Home's own reducer and match screens. The
/// `nudge` Test Lab scenario scripts each person's answer: Riley accepts
/// after 4 s, Sam fails once then accepts, Casey is refused, the rest accept.
/// Now is Sun Aug 16, 1:00 AM in Los Angeles.
final class NudgeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.appearance = .light
        app = nil
    }

    func testLiveNudgeDisablesWhileSendingThenConfirmsUntilTomorrow() {
        launch()
        open("active", "Riley")
        XCTAssertTrue(
            element("competition.updated").label.hasPrefix("Riley: updated Sat "),
            element("competition.updated").label
        )
        let nudge = app.buttons["competition.nudge"]
        XCTAssertTrue(nudge.waitForExistence(timeout: 3))
        XCTAssertEqual(nudge.label, "Nudge Riley")
        XCTAssertTrue(nudge.isEnabled)
        XCTAssertEqual(app.buttons.matching(identifier: "competition.nudge").count, 1)
        XCTAssertFalse(element("competition.nudge.sent").exists)
        XCTAssertFalse(element("competition.nudge.error").exists)

        nudge.tap()
        // Sending: the same button, disabled, so a second tap does nothing.
        XCTAssertTrue(nudge.exists)
        XCTAssertFalse(nudge.isEnabled)
        nudge.tap()
        let sent = element("competition.nudge.sent")
        XCTAssertTrue(sent.waitForExistence(timeout: 8))
        XCTAssertEqual(spaced(sent.label), "Nudged at 1:00 AM. You can nudge again tomorrow.")
        XCTAssertFalse(nudge.exists)
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "competition.nudge.sent").count,
            1
        )

        // The confirmation outlives leaving the screen.
        goBack()
        open("active", "Riley")
        XCTAssertTrue(element("competition.nudge.sent").waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["competition.nudge"].exists)

        // It belongs to Riley's match only: the long-name match still offers one.
        goBack()
        open("active", "Alexandria")
        let other = app.buttons["competition.nudge"]
        XCTAssertTrue(other.waitForExistence(timeout: 3))
        XCTAssertEqual(other.label, "Nudge Alexandria Montgomery-Featherstonehaugh")
        XCTAssertFalse(element("competition.nudge.sent").exists)
    }

    func testFailedNudgeRetriesAndARefusalExplains() {
        launch()
        // Sam has never uploaded: no freshness line, the button alone.
        open("active", "Sam")
        XCTAssertFalse(element("competition.updated").exists)
        let nudge = app.buttons["competition.nudge"]
        XCTAssertTrue(nudge.waitForExistence(timeout: 3))
        XCTAssertEqual(nudge.label, "Nudge Sam")
        nudge.tap()
        let error = element("competition.nudge.error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "Couldn’t send the nudge. Try again.")
        XCTAssertTrue(nudge.exists)
        XCTAssertTrue(nudge.isEnabled)
        XCTAssertFalse(element("competition.nudge.sent").exists)

        nudge.tap()
        let sent = element("competition.nudge.sent")
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        XCTAssertEqual(spaced(sent.label), "Nudged at 1:00 AM. You can nudge again tomorrow.")
        XCTAssertFalse(error.exists)
        XCTAssertFalse(nudge.exists)

        // Casey's last day: the server says no.
        goBack()
        open("ends-today", "Casey")
        let casey = app.buttons["competition.nudge"]
        XCTAssertTrue(casey.waitForExistence(timeout: 3))
        casey.tap()
        let refused = element("competition.nudge.error")
        XCTAssertTrue(refused.waitForExistence(timeout: 5))
        XCTAssertEqual(refused.label, "Casey doesn’t need a nudge right now.")
        XCTAssertFalse(app.buttons["competition.nudge"].exists)
        XCTAssertFalse(element("competition.nudge.sent").exists)
        // The refusal's refresh publishes the same match; the note stays.
        XCTAssertFalse(app.buttons["competition.nudge"].waitForExistence(timeout: 2))
        XCTAssertTrue(refused.exists)
    }

    func testTallyPanelOffersANudgeOnlyWhenTheResultWaitsOnThem() {
        launch()
        open("tallying", "Morgan")
        let tally = element("competition.tally")
        XCTAssertTrue(tally.waitForExistence(timeout: 3))
        XCTAssertTrue(tally.label.contains("Waiting for Morgan’s last check"), tally.label)
        XCTAssertTrue(tally.label.contains("If Morgan doesn’t open HealthComp by "), tally.label)
        XCTAssertTrue(tally.label.hasSuffix(", the result uses what’s in."), tally.label)
        XCTAssertFalse(tally.label.contains("Nothing for you to do"), tally.label)
        let nudge = app.buttons["competition.nudge"]
        XCTAssertTrue(nudge.waitForExistence(timeout: 3))
        XCTAssertEqual(nudge.label, "Nudge Morgan")
        // Once, inside the panel under its text, never also under the scoreboard.
        XCTAssertEqual(app.buttons.matching(identifier: "competition.nudge").count, 1)
        XCTAssertGreaterThanOrEqual(nudge.frame.minY, tally.frame.maxY)
        XCTAssertLessThan(nudge.frame.minY - tally.frame.maxY, 40)
        scrollToElement(nudge)
        nudge.tap()
        let sent = element("competition.nudge.sent")
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        XCTAssertEqual(spaced(sent.label), "Nudged at 1:00 AM. You can nudge again tomorrow.")
        XCTAssertGreaterThanOrEqual(sent.frame.minY, tally.frame.maxY)
        XCTAssertTrue(tally.exists)

        goBack()
        open("tallying", "Avery")
        let avery = element("competition.tally")
        XCTAssertTrue(avery.waitForExistence(timeout: 3))
        XCTAssertTrue(avery.label.contains("Waiting for Avery to sync"), avery.label)
        XCTAssertTrue(avery.label.contains("If Avery doesn’t sync by "), avery.label)
        XCTAssertFalse(avery.label.contains("Nothing for you to do"), avery.label)
        XCTAssertEqual(app.buttons["competition.nudge"].label, "Nudge Avery")

        // Waiting on the stability check, not on Quinn: no nudge.
        goBack()
        open("tallying", "Quinn")
        let quinn = element("competition.tally")
        XCTAssertTrue(quinn.waitForExistence(timeout: 3))
        XCTAssertTrue(quinn.label.contains("Checking the last scores"), quinn.label)
        XCTAssertTrue(quinn.label.contains("Nothing for you to do."), quinn.label)
        assertNoNudgeControl()
    }

    func testNoNudgeOnFreshScheduledOrSimulatedMatches() {
        launch()
        // Jordan updated an hour ago.
        open("active", "Jordan")
        XCTAssertTrue(element("competition.updated").waitForExistence(timeout: 3))
        assertNoNudgeControl()
        goBack()
        open("scheduled", "Priya")
        XCTAssertTrue(app.navigationBars["Priya"].exists)
        assertNoNudgeControl()

        // The same stale match on the simulated fixture.
        launch(.simulated)
        open("active", "Riley")
        XCTAssertTrue(element("competition.updated").waitForExistence(timeout: 3))
        assertNoNudgeControl()
    }

    func testTodayIsTheMatchTimeZonesDay() {
        launch()
        // Sent Sat 8:00 PM here, which is Sun noon in Tokyo: still today there.
        open("active", "Kenji")
        let sent = element("competition.nudge.sent")
        XCTAssertTrue(sent.waitForExistence(timeout: 3))
        XCTAssertEqual(spaced(sent.label), "Nudged at Sat 8:00 PM. You can nudge again tomorrow.")
        XCTAssertFalse(app.buttons["competition.nudge"].exists)

        // The server's time is already Monday: the tap still confirms, and
        // the button doesn't come straight back.
        goBack()
        open("active", "Alexandria")
        let nudge = app.buttons["competition.nudge"]
        XCTAssertTrue(nudge.waitForExistence(timeout: 3))
        scrollToElement(nudge)
        nudge.tap()
        let late = element("competition.nudge.sent")
        XCTAssertTrue(late.waitForExistence(timeout: 5))
        XCTAssertEqual(spaced(late.label), "Nudged at 12:01 AM. You can nudge again tomorrow.")
        XCTAssertFalse(nudge.exists)
    }

    // Light and dark at the default size and at AX5, every nudge state.
    // Screenshots are attached as nudge-<screen>-<light|dark>-<default|ax5>.
    func testNudgeScreensLightDefault() throws {
        try captureNudgeScreens(dark: false, largest: false)
    }

    func testNudgeScreensDarkDefault() throws {
        try captureNudgeScreens(dark: true, largest: false)
    }

    func testNudgeScreensLightLargestType() throws {
        try captureNudgeScreens(dark: false, largest: true)
    }

    func testNudgeScreensDarkLargestType() throws {
        try captureNudgeScreens(dark: true, largest: true)
    }

    private func captureNudgeScreens(dark: Bool, largest: Bool) throws {
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
        let nudge = app.buttons["competition.nudge"]

        open("active", "Riley")
        XCTAssertTrue(nudge.waitForExistence(timeout: 3))
        scrollToElement(nudge)
        shot("live-button-\(suffix)")
        try audit("live-button-\(suffix)")
        nudge.tap()
        XCTAssertFalse(nudge.isEnabled)
        shot("live-sending-\(suffix)")
        let sent = element("competition.nudge.sent")
        XCTAssertTrue(sent.waitForExistence(timeout: 8))
        scrollToElement(sent)
        shot("live-sent-\(suffix)")
        try audit("live-sent-\(suffix)")

        goBack()
        open("active", "Sam")
        XCTAssertTrue(nudge.waitForExistence(timeout: 3))
        scrollToElement(nudge)
        nudge.tap()
        let error = element("competition.nudge.error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        scrollToElement(error)
        shot("live-error-\(suffix)")
        try audit("live-error-\(suffix)")

        goBack()
        open("ends-today", "Casey")
        XCTAssertTrue(nudge.waitForExistence(timeout: 3))
        scrollToElement(nudge)
        nudge.tap()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        scrollToElement(error)
        shot("live-not-needed-\(suffix)")
        try audit("live-not-needed-\(suffix)")

        goBack()
        open("tallying", "Morgan")
        XCTAssertTrue(nudge.waitForExistence(timeout: 3))
        scrollToElement(nudge)
        shot("tally-button-\(suffix)")
        try audit("tally-button-\(suffix)")
        nudge.tap()
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        scrollToElement(sent)
        shot("tally-sent-\(suffix)")
        try audit("tally-sent-\(suffix)")

        goBack()
        open("active", "Alexandria")
        XCTAssertTrue(nudge.waitForExistence(timeout: 3))
        scrollToElement(nudge)
        // The scoreboard's name header predates the nudge; the audit flags it
        // for any long name.
        shot("live-long-name-\(suffix)")
        try audit(
            "live-long-name-\(suffix)",
            preexistingClippedLabels: ["ALEXANDRIA MONTGOMERY-FEATHERSTONEHAUGH"]
        )
    }

    // MARK: Helpers

    private enum Scenario: String {
        case remote = "nudge"
        case simulated = "nudge-simulated"
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
        match.tap()
        let title = app.navigationBars.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", String(name.prefix(8)))
        ).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 3), "Opening \(name)")
    }

    private func goBack() {
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
    }

    private func assertNoNudgeControl(file: StaticString = #filePath, line: UInt = #line) {
        for id in ["competition.nudge", "competition.nudge.sent", "competition.nudge.error"] {
            XCTAssertFalse(element(id).exists, "\(id) should not show", file: file, line: line)
        }
    }

    /// Times use a narrow no-break space before AM/PM.
    private func spaced(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "nudge-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Audits scroll the screen, so they run after the screenshot. Layout
    /// audits for the whole screen; contrast for the nudge only, since
    /// the rest of the screen predates it.
    private func audit(_ name: String, preexistingClippedLabels: Set<String> = []) throws {
        let bar = app.navigationBars.firstMatch.frame
        func ignored(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
            guard let element = issue.element else { return false }
            switch issue.auditType {
            case .contrast:
                return !element.identifier.hasPrefix("competition.nudge")
            case .textClipped:
                // iOS truncates a long name in the navigation bar title.
                return bar.contains(element.frame)
                    || preexistingClippedLabels.contains(element.label)
            default:
                return false
            }
        }
        try XCTContext.runActivity(named: "audit \(name)") { _ in
            let types: XCUIAccessibilityAuditType = [
                .textClipped, .hitRegion, .sufficientElementDescription, .contrast,
            ]
            do {
                try app.performAccessibilityAudit(for: types, ignored)
            } catch let error as NSError where error.code == -56 {
                // "Audit failed to complete in time": a loaded Mac, not a
                // finding. One retry.
                try app.performAccessibilityAudit(for: types, ignored)
            }
        }
    }

    private func scrollToElement(_ element: XCUIElement) {
        for _ in 0..<24 {
            // Clear of the home indicator, so screenshots show it whole.
            if element.exists, element.isHittable,
               app.frame.insetBy(dx: 0, dy: 40).contains(element.frame) { return }
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
}
