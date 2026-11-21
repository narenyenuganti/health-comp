import XCTest

final class VersusIntroUITests: XCTestCase {
    private var app: XCUIApplication!

    private static let longName = "Maximiliana Featherstonehaugh-Worthington"
    private static let played: TimeInterval = 8

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
        skip()
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
        XCTAssertTrue(intro.waitForExistence(timeout: 16))
        XCTAssertEqual(intro.label, "You versus Sam. Day 1 is Monday.")
        skip()
        XCTAssertTrue(app.staticTexts["competition.schedule.dates"].exists)
    }

    func testPlaysForTheSenderOnTheNextOpen() {
        launch()
        let scheduled = card("scheduled", 0x02)
        XCTAssertTrue(scheduled.waitForExistence(timeout: 16))
        XCTAssertFalse(intro.exists)
        scrollToElement(scheduled)
        scheduled.tap()
        XCTAssertTrue(intro.waitForExistence(timeout: 3))
        skip()
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

    private static let matchups: [(String, UInt8, String)] = [
        ("scheduled", 0x03, "Riley"),
        ("active", 0x04, "Morgan"),
        ("active", 0x05, "Jordan"),
        ("active", 0x06, longName),
    ]

    func testEveryMatchupEndsByItself() {
        launch(holds: false)
        for (state, byte, title) in Self.matchups {
            open(state, byte)
            assertEnds()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3), title)
            goHome()
        }
    }

    func testMenuReplaysRepeatedlyWithoutReenablingAutoplay() {
        launch()
        open("scheduled", 0x03)
        XCTAssertTrue(intro.waitForExistence(timeout: 3))
        let announcement = intro.label
        skip()

        for _ in 0..<2 {
            replay()
            XCTAssertTrue(intro.waitForExistence(timeout: 3))
            XCTAssertEqual(intro.label, announcement)
            skip()
        }
        goHome()
        open("scheduled", 0x03)
        assertDoesNotPlay(title: "Riley")
    }

    func testMenuReplaysAfterDayOne() {
        launch()
        open("active", 0x07)
        assertDoesNotPlay(title: "Casey")
        replay()
        XCTAssertTrue(intro.waitForExistence(timeout: 3))
        XCTAssertEqual(intro.label, "You versus Casey. Day 2 of 7.")
        skip()
    }

    func testReduceMotionShowsTheComposedScreenAndATapEndsIt() {
        launch(["--versus-reduce-motion"])
        open("active", 0x04)
        XCTAssertTrue(intro.waitForExistence(timeout: 3))
        capture("Reduce Motion")
        skip()
        replay()
        XCTAssertTrue(intro.waitForExistence(timeout: 3))
        skip()
    }

    func testReduceMotionEndsByItself() {
        launch(["--versus-reduce-motion"], holds: false)
        for (state, byte, title) in Self.matchups.prefix(2) {
            open(state, byte)
            assertEnds()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3), title)
            goHome()
        }
    }

    func testVoiceOverSkipsTheScreenAndAnnouncesIt() {
        launch(["--versus-voiceover"])
        open("scheduled", 0x03)
        XCTAssertTrue(app.staticTexts["You versus Riley. Day 1 is Monday."].waitForExistence(timeout: 3))
        XCTAssertFalse(intro.exists)
    }

    private var intro: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "You versus ")).firstMatch
    }

    private func launch(_ arguments: [String] = [], enabled: Bool = true, holds: Bool = true) {
        XCUIDevice.shared.appearance = arguments.contains("Dark") ? .dark : .light
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", "versus",
            "-healthcomp.colorHintSeen", "YES",
        ] + (enabled ? ["--versus-intro"] : []) + (holds ? ["--versus-hold"] : []) + arguments
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
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
    }

    private func skip(file: StaticString = #filePath, line: UInt = #line) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertEnds(file: file, line: line)
    }

    private func replay(file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["competition.more"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let replay = app.buttons["competition.versus.replay"]
        XCTAssertTrue(replay.waitForExistence(timeout: 3), file: file, line: line)
        replay.tap()
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

    private func capture(_ name: String) {
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
