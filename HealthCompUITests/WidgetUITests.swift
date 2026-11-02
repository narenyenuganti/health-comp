import XCTest

/// The match widget on the real Home Screen and Lock Screen. Widgets render
/// in SpringBoard, so these drive SpringBoard's and PosterBoard's own editing
/// screens against the Test Lab's sample snapshot (`--widget-sample`).
final class WidgetUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let posterboard = XCUIApplication(bundleIdentifier: "com.apple.PosterBoard")
    private let sampleLabel = "Sam, Day 5 of 7. You 1,204 points. Sam 1,150 points. You lead by 54. Updated"

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.appearance = .light
        removeOurWidgets()
    }

    func testMatchWidgetShowsTheSampleScoreAndPicksAPerson() throws {
        let app = XCUIApplication()
        launchWithSample()
        XCUIDevice.shared.press(.home)
        removeOurWidgets()  // a reused simulator may still hold widgets from an earlier run

        addWidget(sizeSwipes: 1)  // medium
        addWidget(sizeSwipes: 0)  // small

        // One VoiceOver element per widget, with the whole score read out.
        let widgets = widgetElements()
        XCTAssertTrue(widgets.firstMatch.waitForExistence(timeout: 15), springboard.debugDescription)
        XCTAssertEqual(widgets.count, 2)
        shot("home-light")

        XCUIDevice.shared.appearance = .dark
        sleep(4)
        XCTAssertEqual(widgetElements().count, 2)
        shot("home-dark")
        XCUIDevice.shared.appearance = .light
        sleep(3)

        // Edit Widget offers the people in the snapshot and nobody else.
        let widget = widgetElements().firstMatch
        widget.press(forDuration: 1.3)
        tap([springboard.buttons["Edit Widget"]], "Edit Widget")
        sleep(2)
        shot("edit-widget")
        // The value side of the Person row reads "Person" until someone is picked.
        tap([springboard.buttons["Person"], springboard.buttons["Choose"]], "Person value")
        let sam = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Sam'")).firstMatch
        XCTAssertTrue(sam.waitForExistence(timeout: 5), springboard.debugDescription)
        shot("edit-widget-people")
        sam.tap()
        sleep(1)
        // Back on the Home Screen, the picked widget still shows Sam's match.
        XCUIDevice.shared.press(.home)
        sleep(2)
        if springboard.buttons["Done"].exists { springboard.buttons["Done"].tap() }
        XCTAssertTrue(widgetElements().firstMatch.waitForExistence(timeout: 10))

        // A tap opens the app.
        app.terminate()
        widgetElements().firstMatch.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    func testLockScreenWidgetsShowTheLeadAndBothTotals() throws {
        launchWithSample()
        XCUIDevice.shared.press(.home)
        showLockScreen()
        let circular = lockScreenElement("You lead Sam by 54 points")
        let rectangular = lockScreenElement(sampleLabel)
        if !circular.waitForExistence(timeout: 3) {
            addLockScreenWidgets()
            showLockScreen()
        }
        sleep(3)
        shot("lock-light")
        XCTAssertTrue(circular.waitForExistence(timeout: 15), springboard.debugDescription)
        XCTAssertTrue(rectangular.exists, springboard.debugDescription)
        XCUIDevice.shared.appearance = .dark
        sleep(3)
        shot("lock-dark")
        XCUIDevice.shared.press(.home)  // unlocks: the simulator has no passcode
        sleep(1)
    }

    private func launchWithSample() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", "sharing",
            "--widget-sample",
            "-healthcomp.colorHintSeen", "YES",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(2)  // the sample write is a detached task
    }

    private func showLockScreen() {
        let lock = NSSelectorFromString("pressLockButton")
        XCUIDevice.shared.perform(lock)
        sleep(2)
        XCUIDevice.shared.perform(lock)
        sleep(3)
    }

    private func lockScreenElement(_ prefix: String) -> XCUIElement {
        springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// Lock Screen editing lives in PosterBoard: Customize, the Lock Screen
    /// poster, the widget row, then both of our sizes.
    private func addLockScreenWidgets() {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 1.8)
        sleep(2)
        tap([springboard.buttons["Customize"], springboard.staticTexts["Customize"]], "Customize")
        sleep(2)
        tap([springboard.cells.matching(NSPredicate(format: "label BEGINSWITH 'Customize Lock'")).firstMatch],
            "Customize Lock Screen")
        sleep(3)
        // The widget row under the clock; PosterBoard doesn't expose it until the editor settles.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.29)).tap()
        sleep(2)
        tap([posterboard.buttons["Continue"]], "keyboard intro", timeout: 3, required: false)
        let result = posterboard.cells["HealthComp"]
        XCTAssertTrue(result.waitForExistence(timeout: 5), posterboard.debugDescription)
        for _ in 0..<8 where !result.isHittable {
            posterboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                .press(forDuration: 0.05, thenDragTo: posterboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)))
            sleep(1)
        }
        tap([result], "HealthComp in the Lock Screen gallery")
        sleep(2)
        for size in ["Circular", "Rectangular"] {
            let widget = posterboard.buttons
                .matching(NSPredicate(format: "label == 'HealthComp, Match' AND value CONTAINS %@", size)).firstMatch
            tap([widget], "\(size) widget")
            sleep(1)
        }
        shot("lock-editor")
        if !tap([posterboard.buttons["close"]], "close gallery", timeout: 3, required: false) {
            // The sheet's close button, when PosterBoard doesn't expose it.
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.91, dy: 0.475)).tap()
        }
        sleep(2)  // let the sheet finish closing, or Done ignores the tap
        let done = posterboard.buttons["editing-done"]
        for _ in 0..<3 {
            if done.exists, done.isHittable { done.tap() } else {
                springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.037)).tap()
            }
            sleep(2)
            if !done.exists { break }
        }
        shot("lock-after-done")
        // Back on the poster switcher: pick the edited poster to leave it.
        tap([springboard.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'posterboard-posteruuid'")).firstMatch],
            "poster", timeout: 3, required: false)
        sleep(2)
    }

    // MARK: SpringBoard

    private func widgetElements() -> XCUIElementQuery {
        springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", sampleLabel))
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @discardableResult
    private func tap(
        _ candidates: [XCUIElement],
        _ step: String,
        timeout: TimeInterval = 6,
        required: Bool = true
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = candidates.first(where: { $0.exists && $0.isHittable }) {
                hit.tap()
                return true
            }
            usleep(250_000)
        }
        if required {
            shot("missing-\(step)")
            XCTFail("SpringBoard has no \(step)\n\(springboard.debugDescription)")
        }
        return false
    }

    private func enterEditMode() {
        // Blank wallpaper below the icon rows, above the dock.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            .press(forDuration: 1.6)
        sleep(1)
        tap([springboard.buttons["Edit Home Screen"]], "Edit Home Screen", timeout: 2, required: false)
    }

    private func addWidget(sizeSwipes: Int) {
        enterEditMode()
        tap([springboard.buttons["Edit"]], "Edit")
        tap([springboard.buttons["Add Widget"]], "Add Widget")
        sleep(2)
        // A fresh simulator explains slide-to-type over the focused search
        // field. SpringBoard's typeText goes to the App Library field, so
        // scroll the gallery's app list instead of searching.
        tap([springboard.buttons["Continue"]], "keyboard intro", timeout: 3, required: false)
        let result = springboard.cells["HealthComp"]
        if !result.waitForExistence(timeout: 2) {
            // The gallery opened on its suggestions: focusing search lists the apps.
            tap([springboard.searchFields["Search Widgets"]], "Search Widgets")
            tap([springboard.buttons["Continue"]], "keyboard intro", timeout: 3, required: false)
        }
        XCTAssertTrue(result.waitForExistence(timeout: 5), springboard.debugDescription)
        for _ in 0..<8 where !result.isHittable {
            let list = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            list.press(
                forDuration: 0.05,
                thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
            )
            sleep(1)
        }
        shot("gallery-list")
        tap([result], "HealthComp in the widget gallery")
        sleep(2)
        for _ in 0..<sizeSwipes {
            springboard.swipeLeft()
            sleep(1)
        }
        tap([springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Add Widget'")).firstMatch], "Add Widget (size)")
        sleep(2)
        tap([springboard.buttons["Done"]], "Done", timeout: 3, required: false)
        sleep(1)
    }

    private func removeOurWidgets() {
        XCUIDevice.shared.press(.home)
        sleep(1)
        let remove = springboard.alerts.buttons["Remove"]
        for _ in 0..<4 {
            let widget = widgetElements().firstMatch
            guard widget.exists, widget.isHittable else { break }
            widget.press(forDuration: 1.3)
            guard tap([springboard.buttons["Remove Widget"]], "Remove Widget", timeout: 3, required: false)
            else { break }
            if remove.waitForExistence(timeout: 5) { remove.tap() }
            sleep(1)
        }
        // Never leave an alert or edit mode in front of the next step.
        let cancel = springboard.alerts.buttons["Cancel"]
        if cancel.exists { cancel.tap() }
        if springboard.buttons["Done"].exists { springboard.buttons["Done"].tap() }
    }
}
