import XCTest

/// The final-day Live Activity in the real Dynamic Island and on the Lock
/// Screen. The Test Lab's "Start Live Activity" starts a sample for Sam,
/// 2,190 vs 2,171, ending `secondsLeft` after launch, so the test also sees
/// the card turn into "Final score pending" without the app running.
final class LiveActivityUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let secondsLeft: TimeInterval = 90

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.appearance = .light
        // Opening the preview ends the sample, so nothing stays on the Lock Screen.
        let app = launch()
        sleep(2)
        app.terminate()
    }

    func testLiveActivityShowsInTheIslandAndOnTheLockScreenThenGoesPending() throws {
        let app = launch()
        let start = app.buttons["liveActivity.preview.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        let startedAt = Date()
        start.tap()
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(2)

        // iOS asks once whether HealthComp may show Live Activities.
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }

        // Compact island: one score on each side of the camera.
        let you = springboardElement("You 2,190 points")
        let sam = springboardElement("Sam 2,171 points")
        XCTAssertTrue(you.waitForExistence(timeout: 10), springboard.debugDescription)
        XCTAssertTrue(sam.exists, springboard.debugDescription)
        shot("island-compact")

        // Expanded island after a long press.
        you.press(forDuration: 1.2)
        sleep(2)
        XCTAssertTrue(springboardElement("You lead by 19.").waitForExistence(timeout: 5), springboard.debugDescription)
        shot("island-expanded")
        XCUIDevice.shared.press(.home)
        sleep(1)

        // Lock Screen card, live.
        showLockScreen()
        let card = springboardElement("Last day · Sam")
        XCTAssertTrue(card.waitForExistence(timeout: 10), springboard.debugDescription)
        XCTAssertTrue(card.label.contains("You lead by 19."), card.label)
        shot("lock-live-light")
        XCUIDevice.shared.appearance = .dark
        sleep(3)
        shot("lock-live-dark")
        XCUIDevice.shared.appearance = .light
        // Unlock while waiting, or the display sleeps and the next lock
        // presses leave it off.
        XCUIDevice.shared.press(.home)
        sleep(2)

        // Past its stale date the card reads pending, with no app run.
        let remaining = secondsLeft - Date().timeIntervalSince(startedAt)
        if remaining > 0 { sleep(UInt32(remaining.rounded(.up)) + 5) }
        showLockScreen()
        let pending = springboardElement("Final score pending · Sam")
        XCTAssertTrue(pending.waitForExistence(timeout: 20), springboard.debugDescription)
        XCTAssertTrue(pending.label.contains("Not final yet."), pending.label)
        XCTAssertFalse(pending.label.contains("Ends at midnight"), pending.label)
        shot("lock-pending")
        XCUIDevice.shared.press(.home)  // unlocks: the simulator has no passcode
        sleep(1)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", "live-activity",
            "-liveActivityPreviewSecondsLeft", "\(Int(secondsLeft))",
            "-healthcomp.colorHintSeen", "YES",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        return app
    }

    private func showLockScreen() {
        let lock = NSSelectorFromString("pressLockButton")
        XCUIDevice.shared.perform(lock)
        sleep(2)
        XCUIDevice.shared.perform(lock)
        sleep(3)
    }

    private func springboardElement(_ text: String) -> XCUIElement {
        springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
