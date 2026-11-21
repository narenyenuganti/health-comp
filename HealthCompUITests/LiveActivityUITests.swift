import XCTest

final class LiveActivityUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var secondsLeft: TimeInterval = 90
    private var changedTextSize = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.appearance = .light
        if changedTextSize { setLargestText(false) }
        let app = launch()
        sleep(2)
        app.terminate()
    }

    private struct Sample {
        let key: String
        let name: String
        let you: String
        let them: String
        let lead: String
        var timing = "Ends at midnight"
        var timingFits = true
        var freshness: String?

        var youLabel: String { "You \(you) points" }
        var themLabel: String { "\(name) \(them) points" }

        func live(large: Bool = false, timingFits: Bool? = nil) -> String {
            ["Last day · \(name)", large || !(timingFits ?? self.timingFits) ? nil : timing, youLabel, themLabel, lead, large ? nil : freshness]
                .compactMap { $0 }.joined(separator: ", ")
        }

        func pending(large: Bool = false) -> String {
            ["Final score pending · \(name)", youLabel, themLabel, "\(lead) Not final yet.", large ? nil : freshness]
                .compactMap { $0 }.joined(separator: ", ")
        }
    }

    private static let long = "Bartholomew Alexander Christopherson-Montgomery of Westminster"
    private let samples = [
        Sample(key: "lead", name: "Sam", you: "2,190", them: "2,171", lead: "You lead by 19.",
               freshness: "You: updated 5:40 PM · Sam: updated 6:02 PM"),
        Sample(key: "behind", name: "Sam", you: "2,166", them: "2,171", lead: "Sam leads by 5.",
               freshness: "You: updated 5:40 PM · Sam: updated 6:02 PM"),
        Sample(key: "square", name: "Sam", you: "2,190", them: "2,190", lead: "All square."),
        Sample(key: "former", name: "Former competitor", you: "1,980", them: "2,015",
               lead: "Former competitor leads by 35.", timingFits: false, freshness: "Updated 5:40 PM"),
        Sample(key: "long", name: long, you: "4,180", them: "4,195", lead: "\(long) leads by 15.",
               timing: "Ends at midnight EDT", timingFits: false, freshness: "\(long): updated 6:02 PM"),
    ]

    private func sample(_ key: String) -> Sample { samples.first { $0.key == key }! }

    func testPreviewShowsEveryScoreStateInTheAppsWords() throws {
        for sample in samples {
            let app = launch(sample: sample.key, arguments: ["-AppleInterfaceStyle", "Light"])
            let live = previewElement(app, "live")
            XCTAssertTrue(live.waitForExistence(timeout: 10), sample.key)
            XCTAssertEqual(plain(live.label), sample.live(), sample.key)
            XCTAssertEqual(plain(previewElement(app, "pending").label), sample.pending(), sample.key)
            XCTAssertEqual(plain(previewElement(app, "tallying").label), sample.pending(), sample.key)
            for suffix in ["live", "pending", "tallying", "expanded", "compact", "minimal", "start"] {
                XCTAssertEqual(
                    app.descendants(matching: .any).matching(identifier: "liveActivity.preview.\(suffix)").count, 1,
                    "\(sample.key): one \(suffix)"
                )
            }
            let expanded = previewElement(app, "expanded")
            XCTAssertTrue(expanded.label.hasPrefix("Last day, "), expanded.label)
            XCTAssertTrue(plain(expanded.label).contains(" left, \(sample.youLabel), \(sample.themLabel), \(sample.lead)"),
                          expanded.label)
            XCTAssertEqual(previewElement(app, "compact").label, "\(sample.youLabel), \(sample.themLabel)")
            XCTAssertEqual(previewElement(app, "minimal").label, sample.lead)

            let start = app.buttons["liveActivity.preview.start"]
            XCTAssertTrue(start.exists && start.isEnabled, sample.key)
            XCTAssertEqual(start.label, "Start Live Activity")
            XCTAssertGreaterThanOrEqual(start.frame.height, 44)
            app.terminate()
        }
    }

    func testPreviewAtLargestTextKeepsTheScoreAndLead() throws {
        for key in ["lead", "long"] {
            let sample = sample(key)
            let app = launch(sample: key, arguments: ["-AppleInterfaceStyle", "Light",
                                                      "-UIPreferredContentSizeCategoryName",
                                                      "UICTContentSizeCategoryAccessibilityXXXL"])
            let live = previewElement(app, "live")
            XCTAssertTrue(live.waitForExistence(timeout: 10), key)
            XCTAssertEqual(plain(live.label), sample.live(large: true), key)
            XCTAssertEqual(plain(previewElement(app, "pending").label), sample.pending(large: true), key)
            XCTAssertEqual(plain(previewElement(app, "tallying").label), sample.pending(large: true), key)
            XCTAssertLessThanOrEqual(live.frame.height, 160)
            try app.performAccessibilityAudit(for: [.textClipped, .sufficientElementDescription]) { issue in
                !(issue.element?.identifier.hasPrefix("liveActivity.preview") ?? false)
            }
            app.terminate()
        }
    }

    func testLiveActivityShowsInTheIslandAndOnTheLockScreenThenGoesPending() throws {
        let app = launch()
        let start = app.buttons["liveActivity.preview.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        let startedAt = Date()
        start.tap()
        sleep(1)
        start.tap()
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(2)
        allowLiveActivities()

        let you = springboardElement("You 2,190 points")
        let sam = springboardElement("Sam 2,171 points")
        XCTAssertTrue(you.waitForExistence(timeout: 10), springboard.debugDescription)
        XCTAssertTrue(sam.exists, springboard.debugDescription)
        XCTAssertEqual(springboardPlaces("You 2,190 points"), 1, springboard.debugDescription)
        shot("island-compact")

        you.press(forDuration: 1.2)
        sleep(2)
        XCTAssertTrue(springboardElement("You lead by 19.").waitForExistence(timeout: 5), springboard.debugDescription)
        shot("island-expanded")
        XCUIDevice.shared.press(.home)
        sleep(1)

        showLockScreen()
        let card = springboardElement("Last day · Sam")
        XCTAssertTrue(card.waitForExistence(timeout: 10), springboard.debugDescription)
        XCTAssertEqual(plain(card.label), sample("lead").live())
        XCTAssertEqual(springboardPlaces("Last day · Sam, Ends at midnight, You 2,190 points, Sam 2,171 points, You lead by 19."), 1, springboard.debugDescription)
        shot("lock-live-light")
        XCUIDevice.shared.appearance = .dark
        sleep(3)
        shot("lock-live-dark")
        XCUIDevice.shared.appearance = .light
        XCUIDevice.shared.press(.home)
        sleep(2)

        waitUntilStale(startedAt)
        showLockScreen()
        let pending = springboardElement("Final score pending · Sam")
        XCTAssertTrue(pending.waitForExistence(timeout: 40), springboard.debugDescription)
        XCTAssertEqual(plain(pending.label), sample("lead").pending())
        shot("lock-pending")
        XCUIDevice.shared.press(.home)
        sleep(1)
    }

    func testEveryScoreStateOnTheLockScreenAndInTheIsland() throws {
        secondsLeft = 3600
        for key in ["behind", "square", "former", "long"] {
            let sample = sample(key)
            let app = launch(sample: key)
            let start = app.buttons["liveActivity.preview.start"]
            XCTAssertTrue(start.waitForExistence(timeout: 10), key)
            start.tap()
            sleep(2)
            XCUIDevice.shared.press(.home)
            sleep(2)
            allowLiveActivities()

            let you = springboardElement(sample.youLabel)
            XCTAssertTrue(you.waitForExistence(timeout: 10), "\(key)\n\(springboard.debugDescription)")
            XCTAssertTrue(springboardElement(sample.themLabel).exists, "\(key)\n\(springboard.debugDescription)")
            shot("island-compact-\(key)")
            you.press(forDuration: 1.2)
            sleep(2)
            XCTAssertTrue(springboardElement(sample.lead).waitForExistence(timeout: 5),
                          "\(key)\n\(springboard.debugDescription)")
            shot("island-expanded-\(key)")
            XCUIDevice.shared.press(.home)
            sleep(1)

            showLockScreen()
            let card = springboardElement("Last day · \(sample.name)")
            XCTAssertTrue(card.waitForExistence(timeout: 10), "\(key)\n\(springboard.debugDescription)")
            shot("lock-live-\(key)")
            XCTAssertTrue([sample.live(), sample.live(timingFits: true)].contains(plain(card.label)),
                          "\(key): \(card.label)")
            XCUIDevice.shared.press(.home)
            sleep(2)
        }
    }

    func testRunningCardTakesUpdatesInTheIslandAndOnTheLockScreen() throws {
        secondsLeft = 3600
        let app = launch(arguments: ["-liveActivityPreviewUpdateDelay", "9"])
        let start = app.buttons["liveActivity.preview.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        for _ in 0..<6 where !start.isHittable { app.swipeUp() }
        start.tap()
        sleep(2)

        func tapThenLeave(_ button: String, show: () -> Void) {
            app.activate()
            sleep(1)
            let button = app.buttons["liveActivity.preview.\(button)"]
            for _ in 0..<6 where !button.isHittable { app.swipeUp() }
            button.tap()
            XCUIDevice.shared.press(.home)
            sleep(2)
            allowLiveActivities()
            show()
        }

        tapThenLeave("update") {}
        let you = springboardElement("You 2,202 points")
        XCTAssertTrue(you.waitForExistence(timeout: 40), springboard.debugDescription)
        sleep(2)
        tapThenLeave("flip") {}
        sleep(12)

        tapThenLeave("flip") { springboardElement("You 2,202 points").press(forDuration: 1.2) }
        sleep(12)
        XCUIDevice.shared.press(.home)
        sleep(1)

        tapThenLeave("update") { showLockScreen() }
        sleep(12)
        XCUIDevice.shared.press(.home)
        sleep(1)
    }

    func testTappingTheIslandOpensHealthComp() throws {
        secondsLeft = 3600
        let app = launch()
        let start = app.buttons["liveActivity.preview.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(2)
        allowLiveActivities()
        XCTAssertNotEqual(app.state, .runningForeground)
        let you = springboardElement("You 2,190 points")
        XCTAssertTrue(you.waitForExistence(timeout: 10), springboard.debugDescription)
        you.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "the island opens HealthComp")
    }

    func testSystemScreenshotMatrix() throws {
        secondsLeft = 75
        for size in ["default", "ax5"] {
            if size == "ax5" { setLargestText(true) }
            let app = launch()
            let start = app.buttons["liveActivity.preview.start"]
            XCTAssertTrue(start.waitForExistence(timeout: 10))
            let startedAt = Date()
            start.tap()
            sleep(2)
            XCUIDevice.shared.press(.home)
            sleep(2)
            allowLiveActivities()
            let you = springboardElement("You 2,190 points")
            XCTAssertTrue(you.waitForExistence(timeout: 10), springboard.debugDescription)
            for appearance in ["light", "dark"] {
                XCUIDevice.shared.appearance = appearance == "dark" ? .dark : .light
                sleep(2)
                shot("island-compact-\(appearance)-\(size)")
                you.press(forDuration: 1.2)
                sleep(2)
                let expanded = springboardElement("You lead by 19.")
                XCTAssertTrue(expanded.waitForExistence(timeout: 5), springboard.debugDescription)
                XCTAssertEqual(springboardElement("You: updated").exists, size == "default",
                               springboard.debugDescription)
                shot("island-expanded-\(appearance)-\(size)")
                collapseIsland(expanded)
                XCTAssertTrue(you.waitForExistence(timeout: 5), springboard.debugDescription)
            }
            showLockScreen()
            let card = springboardElement("Last day · Sam")
            XCTAssertTrue(card.waitForExistence(timeout: 10), springboard.debugDescription)
            XCTAssertEqual(plain(card.label), sample("lead").live(large: size == "ax5"))
            for appearance in ["dark", "light"] {
                XCUIDevice.shared.appearance = appearance == "dark" ? .dark : .light
                sleep(3)
                shot("lock-live-\(appearance)-\(size)")
            }
            XCUIDevice.shared.press(.home)
            sleep(2)
            waitUntilStale(startedAt)
            showLockScreen()
            let pending = springboardElement("Final score pending · Sam")
            XCTAssertTrue(pending.waitForExistence(timeout: 40), springboard.debugDescription)
            XCTAssertEqual(plain(pending.label), sample("lead").pending(large: size == "ax5"))
            for appearance in ["light", "dark"] {
                XCUIDevice.shared.appearance = appearance == "dark" ? .dark : .light
                sleep(3)
                shot("lock-pending-\(appearance)-\(size)")
            }
            XCUIDevice.shared.appearance = .light
            XCUIDevice.shared.press(.home)
            sleep(2)
        }
    }

    @discardableResult
    private func launch(sample: String = "lead", arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", "live-activity",
            "-liveActivityPreviewSample", sample,
            "-liveActivityPreviewSecondsLeft", "\(Int(secondsLeft))",
            "-healthcomp.colorHintSeen", "YES",
        ] + arguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        return app
    }

    private func previewElement(_ app: XCUIApplication, _ suffix: String) -> XCUIElement {
        app.descendants(matching: .any)["liveActivity.preview.\(suffix)"]
    }

    private func allowLiveActivities() {
        let allow = springboard.buttons
            .matching(NSPredicate(format: "label IN %@", ["Allow", "Always Allow"])).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    private func waitUntilStale(_ startedAt: Date) {
        let remaining = secondsLeft - Date().timeIntervalSince(startedAt)
        if remaining > 0 { sleep(UInt32(remaining.rounded(.up)) + 5) }
    }

    private func showLockScreen() {
        let lock = NSSelectorFromString("pressLockButton")
        XCUIDevice.shared.perform(lock)
        sleep(2)
        XCUIDevice.shared.perform(lock)
        sleep(3)
        allowLiveActivities()
    }

    private func springboardElements(_ text: String) -> XCUIElementQuery {
        springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
    }

    private func springboardPlaces(_ text: String) -> Int {
        Set(springboardElements(text).allElementsBoundByIndex.map { Int($0.frame.midY / 60) }).count
    }

    private func plain(_ label: String) -> String {
        label.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private func collapseIsland(_ expanded: XCUIElement) {
        for _ in 0..<3 where expanded.exists {
            XCUIDevice.shared.press(.home)
            sleep(2)
        }
        if expanded.exists {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
            sleep(2)
        }
        XCTAssertFalse(expanded.exists, "expanded island closed")
    }

    private func springboardElement(_ text: String) -> XCUIElement {
        springboardElements(text).firstMatch
    }

    private func setLargestText(_ on: Bool) {
        changedTextSize = true
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.activate()
        for step in ["Accessibility", "Display & Text Size", "Larger Text"] {
            let row = settings.staticTexts[step]
            for _ in 0..<4 where !(row.exists && row.isHittable) { settings.swipeUp(); sleep(1) }
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Settings has no \(step)")
            row.tap()
            sleep(1)
        }
        let toggle = settings.switches["Larger Accessibility Sizes"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), settings.debugDescription)
        if (toggle.value as? String) != "1" { flip(toggle) }
        sleep(1)
        let expected = on ? "100%" : "27%"
        for _ in 0..<6 {
            let slider = settings.sliders.firstMatch
            if (slider.value as? String) == expected { break }
            slider.adjust(toNormalizedSliderPosition: on ? 1 : 3.0 / 11.0)
            sleep(2)
        }
        XCTAssertEqual(settings.sliders.firstMatch.value as? String, expected, "Larger Text slider")
        if !on {
            flip(toggle)
            sleep(1)
            XCTAssertEqual(toggle.value as? String, "0", "Larger Accessibility Sizes")
        }
        changedTextSize = on
        settings.terminate()
        XCUIDevice.shared.press(.home)
        sleep(3)
    }

    private func flip(_ toggle: XCUIElement) {
        let inner = toggle.switches.firstMatch
        (inner.exists ? inner : toggle).tap()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
