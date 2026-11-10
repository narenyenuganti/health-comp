import XCTest

/// These are also the recording scripts: actual app navigation and native views.
final class JudgesDecisionUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDownWithError() throws { app.terminate(); app = nil }

    func testWin() { run(byte: 0x75, name: "Sam", decision: "SPLIT DECISION", winner: "YOUR WINNER", belt: "AND NEW") }
    func testDefense() { run(byte: 0x94, name: "Jordan", decision: "UNANIMOUS DECISION", winner: "YOUR WINNER", belt: "AND STILL") }
    func testLoss() { run(byte: 0x85, name: "Riley", decision: "SPLIT DECISION", winner: "THE WINNER, RILEY", belt: "AND NEW") }
    func testDraw() { run(byte: 0xC2, name: "Taylor", decision: "DRAW", winner: "IT’S A DRAW", belt: nil) }

    private func launch(_ arguments: [String] = []) {
        app.launchArguments = [
            "--multi-user-competition-test-lab", "--multi-user-competition-scenario", "belt-ceremony",
            "--belt-ceremonies", "--judges-decision", "-healthcomp.colorHintSeen", "YES",
            "-healthcomp.appearance", "system",
        ] + arguments
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 15))
    }

    private func open(_ byte: UInt8, _ name: String) {
        let history = app.buttons["competition.history.open"]
        scrollTo(history); history.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        let row = element("competition.record.\(uuid(byte))")
        scrollTo(row); row.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5))
        let week = element("competition.sharing.completed.\(uuid(byte))")
        scrollTo(week); week.tap()
        XCTAssertTrue(element("competition.judges.seal").waitForExistence(timeout: 5))
    }

    private func run(byte: UInt8, name: String, decision: String, winner: String, belt: String?) {
        launch(); open(byte, name)
        element("competition.judges.seal").press(forDuration: 1.0)
        for judge in ["Judge Move", "Judge Exercise", "Judge Stand"] {
            XCTAssertTrue(soon(3) { self.app.staticTexts[judge].exists }, judge)
        }
        XCTAssertTrue(soon(3) { self.app.staticTexts[decision].exists }, decision)
        XCTAssertTrue(soon(5) { self.app.staticTexts[winner].exists }, winner)
        XCTAssertTrue(soon(3) { self.element("competition.judges.payoff").exists })
        Thread.sleep(forTimeInterval: 0.8)
        if let belt { XCTAssertTrue(soon(10) { self.app.staticTexts[belt].exists }, belt) }
        XCTAssertTrue(soon(10) {
            !self.element("competition.judges.reveal").exists && !self.element("competition.belt.ceremony").exists
        })
        XCTAssertTrue(element("competition.result").waitForExistence(timeout: 3))
        // Leave a settled Verdict at the end of each recording.
        Thread.sleep(forTimeInterval: 2)
    }

    func testSkipReplayAndSeenOnNextVisit() {
        launch(); open(0x75, "Sam")
        element("competition.judges.skip").tap()
        XCTAssertTrue(element("competition.belt.ceremony").waitForExistence(timeout: 3))
        element("competition.belt.ceremony").tap()
        XCTAssertTrue(element("competition.result").waitForExistence(timeout: 3))
        let banner = element("competition.result.belt")
        scrollTo(banner); banner.tap()
        XCTAssertTrue(element("competition.belt.ceremony").waitForExistence(timeout: 3))
        XCTAssertFalse(element("competition.judges.seal").exists)
        element("competition.belt.ceremony").tap()
        let replay = element("competition.judges.replay")
        scrollTo(replay); replay.tap()
        XCTAssertTrue(element("competition.judges.seal").waitForExistence(timeout: 3))
        element("competition.judges.skip").tap()
        app.navigationBars.buttons.firstMatch.tap()
        let week = element("competition.sharing.completed.\(uuid(0x75))")
        scrollTo(week); week.tap()
        XCTAssertTrue(element("competition.result").waitForExistence(timeout: 3))
        XCTAssertFalse(element("competition.judges.reveal").waitForExistence(timeout: 1))
    }

    func testNotifications() {
        launch(["--judges-notifications"])
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        XCTAssertTrue(app.staticTexts["Notification queued"].waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home)
        print("JUDGES_LOCAL_NOTIFICATION_READY")
        let banner = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "The judges’ scorecards are in")
        ).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 25))
        Thread.sleep(forTimeInterval: 6)
    }

    private func soon(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
            // Leave the display server time to render between accessibility snapshots.
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }
    private func scrollTo(_ target: XCUIElement) {
        for _ in 0..<12 where !(target.exists && target.isHittable) { app.swipeUp() }
        XCTAssertTrue(target.isHittable)
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func uuid(_ byte: UInt8) -> String { String(format: "a3000000-0000-4000-8000-0000000000%02x", byte) }
}
