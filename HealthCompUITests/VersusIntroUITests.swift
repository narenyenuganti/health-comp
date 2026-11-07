import XCTest

/// The versus intro through Home's own reducer. The `versus` Test Lab scenario
/// holds Alex's challenge to you, yours to Sam (who accepts 6 s after launch),
/// Riley's scheduled first fight, Morgan and Jordan's Day 1 rematches with the
/// belt on either side, a long name, Casey on Day 2 and a practice.
final class VersusIntroUITests: XCTestCase {
    private var app: XCUIApplication!

    private static let longName = "Maximiliana Featherstonehaugh-Worthington"
    /// Past the intro's 2.72 s, with room for a slow simulator.
    private static let played: TimeInterval = 6

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        if app.state != .notRunning { app.terminate() }
        XCUIDevice.shared.appearance = .light
        app = nil
    }

    func testPlaysForTheAccepterOverTheMatchThenNeverAgain() {
        launch()
        open("pending", 0x01)
        let accept = app.buttons["competition.invite.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 3))
        accept.tap()

        XCTAssertTrue(intro.waitForExistence(timeout: 3))
        XCTAssertEqual(intro.label, "You versus Alex. Day 1 is Monday.")
        assertEnds()
        // The match was already there underneath.
        XCTAssertTrue(app.navigationBars["Alex"].exists)
        XCTAssertTrue(app.staticTexts["competition.schedule.dates"].exists)

        goHome()
        open("scheduled", 0x01)
        assertDoesNotPlay(title: "Alex")
    }

    func testPlaysForTheSenderInPlaceWhenAcceptedWhileWatching() {
        launch()
        open("pending", 0x02)
        XCTAssertFalse(intro.exists)
        // Sam accepts 6 s after launch, with the screen open.
        XCTAssertTrue(intro.waitForExistence(timeout: 10))
        XCTAssertEqual(intro.label, "You versus Sam. Day 1 is Monday.")
        assertEnds()
        XCTAssertTrue(app.staticTexts["competition.schedule.dates"].exists)
    }

    func testPlaysForTheSenderOnTheNextOpen() {
        launch()
        let scheduled = card("scheduled", 0x02)
        XCTAssertTrue(scheduled.waitForExistence(timeout: 10))
        XCTAssertFalse(intro.exists)
        scrollToElement(scheduled)
        scheduled.tap()
        XCTAssertTrue(intro.waitForExistence(timeout: 3))
        assertEnds()
    }

    func testTapSkipsToTheSplit() {
        launch()
        open("active", 0x04)
        XCTAssertTrue(intro.waitForExistence(timeout: 3))
        let tapped = Date()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertEnds()
        XCTAssertLessThan(Date().timeIntervalSince(tapped), 2.4)
        XCTAssertTrue(app.navigationBars["Morgan"].exists)
    }

    func testNeverPlaysForAPracticeOrAMatchPastDayOne() {
        launch()
        open(app.buttons["competition.sharing.scheduled.a1000000-0000-4000-8000-00000000000c"])
        assertDoesNotPlay(title: "Pacer")
        goHome()
        open("active", 0x07)
        assertDoesNotPlay(title: "Casey")
    }

    func testOffInTheTestLabWithoutItsLaunchArgument() {
        launch(enabled: false)
        open("active", 0x04)
        assertDoesNotPlay(title: "Morgan")
    }

    func testEveryMatchupPlaysToTheEnd() {
        launch()
        for (state, byte, title) in [
            ("scheduled", UInt8(0x03), "Riley"),
            ("active", 0x04, "Morgan"),
            ("active", 0x05, "Jordan"),
            ("active", 0x06, Self.longName),
        ] {
            open(state, byte)
            XCTAssertTrue(intro.waitForExistence(timeout: 3), title)
            capture(title)
            assertEnds()
            goHome()
        }
    }

    func testLongNameAndBeltAtAccessibilitySizesInDark() {
        launch([
            "-AppleInterfaceStyle", "Dark",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        for (byte, title) in [(UInt8(0x06), "Long AX5"), (0x04, "Theirs AX5"), (0x05, "Yours AX5")] {
            open("active", byte)
            XCTAssertTrue(intro.waitForExistence(timeout: 3), title)
            capture(title)
            assertEnds()
            goHome()
        }
    }

    func testReduceMotionFadesAndAnyTapStillEndsIt() {
        launch(["-UIAccessibilityReduceMotionEnabled", "YES"])
        open("active", 0x04)
        XCTAssertTrue(intro.waitForExistence(timeout: 3))
        capture("Reduce Motion")
        assertEnds()
        goHome()

        open("active", 0x05)
        XCTAssertTrue(intro.waitForExistence(timeout: 3))
        let tapped = Date()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertEnds()
        XCTAssertLessThan(Date().timeIntervalSince(tapped), 1.4)
    }

    func testVoiceOverSkipsTheScreenAndAnnouncesIt() {
        launch(["--versus-voiceover"])
        open("scheduled", 0x03)
        let announced = app.staticTexts["versus.lab.announced"]
        XCTAssertTrue(announced.waitForExistence(timeout: 3))
        XCTAssertEqual(announced.label, "You versus Riley. Day 1 is Monday.")
        XCTAssertFalse(intro.exists)
    }

    // MARK: Helpers

    private var intro: XCUIElement { app.buttons["competition.versus"] }

    private func launch(_ arguments: [String] = [], enabled: Bool = true) {
        XCUIDevice.shared.appearance = arguments.contains("Dark") ? .dark : .light
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", "versus",
            "-healthcomp.colorHintSeen", "YES",
        ] + (enabled ? ["--versus-intro"] : []) + arguments
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
    }

    private func card(_ state: String, _ byte: UInt8) -> XCUIElement {
        app.buttons[
            "competition.sharing.\(state)." + String(format: "a4000000-0000-4000-8000-0000000000%02x", byte)
        ]
    }

    private func open(_ state: String, _ byte: UInt8) {
        open(card(state, byte))
    }

    private func open(_ element: XCUIElement) {
        scrollToElement(element)
        element.tap()
    }

    private func assertEnds(file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: intro
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [gone], timeout: Self.played), .completed,
            file: file, line: line
        )
    }

    private func assertDoesNotPlay(title: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            app.navigationBars.element(boundBy: 0).waitForExistence(timeout: 3),
            file: file, line: line
        )
        XCTAssertFalse(intro.waitForExistence(timeout: 2), title, file: file, line: line)
    }

    private func goHome() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
    }

    /// A still from the hold, for judging by eye.
    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 0.7)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func scrollToElement(_ element: XCUIElement) {
        for _ in 0..<24 {
            if element.exists, element.isHittable, app.frame.contains(element.frame) { return }
            let surface = app.collectionViews.firstMatch.exists
                ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
            let up = element.exists && element.frame != .zero && element.frame.midY < surface.frame.midY
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.3 : 0.7)).press(
                forDuration: 0.05,
                thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.7 : 0.3))
            )
        }
    }
}
