import XCTest

/// Account → Notifications: six switches in two sections. `account` is the
/// standalone Account fixture (iOS notifications and Live Activities off).
/// `notification-choices` is the real app root with notifications on, the
/// long-named challenger muted, and the real installation coordinator
/// registering against a stand-in server whose state shows under Home
/// ("Muted push kinds: …"): each
/// registration takes 2.5 s, and the first that turns Reactions off fails.
final class NotificationChoicesUITests: XCTestCase {
    private var app: XCUIApplication!

    private static let rows: [(id: String, label: String)] = [
        ("lead-change", "Lead changes"), ("close-score", "Close scores"),
        ("final-day", "Last day"), ("live-activity", "Live Activity"),
        ("reaction", "Reactions"), ("nudge", "Nudges"),
    ]
    private static let footer = "HealthComp only sends match moments, like lead changes and results. To mute someone, open your match with them."
    private static let liveActivitiesOff = "Live Activities are off for HealthComp in iOS Settings."
    private static let longName = "Alexandria Montgomery-Featherstonehaugh"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        if app.state != .notRunning { app.terminate() }
        XCUIDevice.shared.appearance = .light
        app = nil
    }

    // MARK: Page

    func testPageListsSixSwitchesInOrderWithLiveActivitiesOffInIOS() {
        launch(.account)
        openNotificationsFromAccount()
        XCTAssertTrue(app.staticTexts["Turned off in iOS Settings"].exists)
        XCTAssertTrue(text(Self.footer).exists)
        XCTAssertFalse(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Turn them off in iOS Settings")
        ).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["DURING A MATCH"].exists)
        // PR 14 adds it; it isn't listed yet.
        XCTAssertFalse(app.switches["account.notifications.choice.what-it-takes"].exists)
        XCTAssertFalse(app.staticTexts["What it takes"].exists)

        // Read both frames after the scroll: a scroll between rows moves both.
        var previous: XCUIElement = app.staticTexts["DURING A MATCH"]
        for row in Self.rows {
            if row.id == "reaction" {
                let header = app.staticTexts["FROM THE OTHER PERSON"]
                scrollToElement(header)
                XCTAssertGreaterThan(header.frame.minY, liveActivityCaption().frame.minY)
            }
            let toggle = choice(row.id)
            scrollToElement(toggle)
            XCTAssertEqual(toggle.label, row.label)
            XCTAssertEqual(
                app.switches.matching(identifier: "account.notifications.choice.\(row.id)").count, 1, row.id
            )
            XCTAssertGreaterThanOrEqual(toggle.frame.height, 43.5, row.id)
            XCTAssertEqual(toggle.isEnabled, row.id != "live-activity", row.id)
            if row.id == "reaction" { previous = app.staticTexts["FROM THE OTHER PERSON"] }
            XCTAssertTrue(previous.exists, row.id)
            XCTAssertGreaterThan(toggle.frame.minY, previous.frame.minY, "\(row.id) is out of order")
            previous = toggle
            if row.id == "live-activity" {
                // iOS-off: caption and Open Settings directly under the row.
                let caption = liveActivityCaption()
                XCTAssertTrue(caption.exists)
                XCTAssertGreaterThan(caption.frame.minY, toggle.frame.maxY - 1)
                let settings = app.buttons["account.notifications.live-activity.settings"]
                scrollToElement(settings)
                XCTAssertEqual(settings.label, "Open Settings")
                XCTAssertGreaterThanOrEqual(settings.frame.height, 43.5)
                XCTAssertGreaterThan(settings.frame.minY, caption.frame.minY)
            }
        }

        // A disabled switch doesn't move.
        let liveActivity = choice("live-activity")
        scrollToElement(liveActivity)
        let before = liveActivity.value as? String
        flip(liveActivity)
        XCTAssertEqual(liveActivity.value as? String, before)

        // MUTED stays last.
        let muted = app.staticTexts["MUTED"]
        scrollToElement(muted)
        XCTAssertGreaterThan(muted.frame.minY, choice("nudge").frame.maxY)
        XCTAssertTrue(text("Muting someone silences all your matches with them.").exists)

        // The Live Activity Open Settings opens this app's settings page.
        let settings = app.buttons["account.notifications.live-activity.settings"]
        scrollToElement(settings)
        settings.tap()
        XCTAssertTrue(app.staticTexts[UIApplication.openSettingsURLString].waitForExistence(timeout: 3))
    }

    func testEachSwitchTurnsOffSurvivesBackAndRelaunchAndTurnsBackOn() {
        let switchable = Self.rows.filter { $0.id != "live-activity" }
        launch(.account)
        openNotificationsFromAccount()
        // Earlier interrupted runs may have left some off.
        setAll(switchable, on: true)

        for row in switchable {
            let toggle = choice(row.id)
            scrollToElement(toggle)
            flip(toggle)
            XCTAssertEqual(toggle.value as? String, "0", row.id)
        }

        // Back to Account and in again.
        app.navigationBars["Notifications"].buttons["Account"].tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 3))
        openNotifications()
        assertAll(switchable, on: false)

        // Stored on this iPhone: a relaunch keeps them.
        launch(.account)
        openNotificationsFromAccount()
        assertAll(switchable, on: false)

        setAll(switchable, on: true)
        launch(.account)
        openNotificationsFromAccount()
        assertAll(switchable, on: true)
    }

    // MARK: Server-held kinds

    func testSwitchesRegisterServerHeldKindsAndRetryAfterAFailure() {
        launch(.notificationChoices)
        XCTAssertTrue(waitForServer("none", registrations: 1, failures: 0))

        openAccount()
        openNotifications()
        // Notifications are on here, and so are Live Activities.
        XCTAssertFalse(app.staticTexts["Turned off in iOS Settings"].exists)
        XCTAssertTrue(app.buttons["account.notifications.settings"].exists)
        XCTAssertTrue(text(Self.footer).exists)
        for row in Self.rows {
            let toggle = choice(row.id)
            scrollToElement(toggle)
            XCTAssertEqual(toggle.label, row.label)
            XCTAssertEqual(toggle.value as? String, "1", row.id)
            XCTAssertTrue(toggle.isEnabled, row.id)
        }
        XCTAssertFalse(liveActivityCaption().exists)
        XCTAssertFalse(app.buttons["account.notifications.live-activity.settings"].exists)
        let unmute = app.buttons["Unmute \(Self.longName)"]
        scrollToElement(unmute)
        XCTAssertEqual(unmute.identifier, "account.notifications.unmute")
        XCTAssertTrue(app.staticTexts[Self.longName].exists)

        // An on-iPhone switch never goes to the server.
        flip(choice("lead-change"))
        XCTAssertEqual(choice("lead-change").value as? String, "0")
        flip(choice("nudge"))
        XCTAssertEqual(choice("nudge").value as? String, "0")
        closeNotificationsAndAccount()
        XCTAssertTrue(waitForServer("nudge", registrations: 2, failures: 0))

        // Offline: the Reactions registration fails and the server keeps nudge only.
        openAccount()
        openNotifications()
        XCTAssertEqual(choice("lead-change").value as? String, "0")
        XCTAssertEqual(choice("nudge").value as? String, "0")
        flip(choice("reaction"))
        XCTAssertEqual(choice("reaction").value as? String, "0")
        closeNotificationsAndAccount()
        XCTAssertTrue(waitForServer("nudge", registrations: 3, failures: 1))

        // Coming back to the app retries.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForServer("nudge, reaction", registrations: 4, failures: 1))

        // Back on, one at a time.
        openAccount()
        openNotifications()
        flip(choice("lead-change"))
        flip(choice("nudge"))
        closeNotificationsAndAccount()
        XCTAssertTrue(waitForServer("reaction", registrations: 5, failures: 1))
        openAccount()
        openNotifications()
        flip(choice("reaction"))
        for row in Self.rows {
            XCTAssertEqual(choice(row.id).value as? String, "1", row.id)
        }
        closeNotificationsAndAccount()
        XCTAssertTrue(waitForServer("none", registrations: 6, failures: 1))
        // And nothing more follows.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(serverLabel(), summary("none", registrations: 6, failures: 1))
    }

    func testQuickOffAndOnLeavesNudgesOnAtTheServer() {
        launch(.notificationChoices)
        XCTAssertTrue(waitForServer("none", registrations: 1, failures: 0))
        openAccount()
        openNotifications()
        let nudges = choice("nudge")
        scrollToElement(nudges)
        // The second tap lands while the first registration is in flight.
        flip(nudges)
        flip(nudges)
        XCTAssertEqual(nudges.value as? String, "1")
        closeNotificationsAndAccount()
        XCTAssertTrue(waitForServer("none", registrations: 3, failures: 0, timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(serverLabel(), summary("none", registrations: 3, failures: 0))
    }

    // MARK: Captures

    /// Not in CI: Account → Notifications light and dark, default and AX5,
    /// top and bottom, from both fixtures. Close scores is off in each.
    func testNotificationChoicesScreenshotMatrix() throws {
        let configs: [(String, String, String)] = [
            ("light-default", "Light", "UICTContentSizeCategoryL"),
            ("dark-default", "Dark", "UICTContentSizeCategoryL"),
            ("light-ax5", "Light", "UICTContentSizeCategoryAccessibilityXXXL"),
            ("dark-ax5", "Dark", "UICTContentSizeCategoryAccessibilityXXXL"),
        ]
        for (suffix, appearance, size) in configs {
            let arguments = ["-AppleInterfaceStyle", appearance, "-UIPreferredContentSizeCategoryName", size]
            for scenario in [Scenario.account, .notificationChoices] {
                let screen = scenario == .account ? "notifications-ios-off" : "notifications"
                launch(scenario, arguments: arguments)
                if scenario == .account {
                    openNotificationsFromAccount()
                } else {
                    XCTAssertTrue(waitForServer("none", registrations: 1, failures: 0))
                    openAccount()
                    openNotifications()
                }
                let closeScores = choice("close-score")
                scrollToElement(closeScores)
                if closeScores.value as? String != "0" { flip(closeScores) }
                XCTAssertEqual(closeScores.value as? String, "0")
                // A status bar tap scrolls to the top; a swipe could close the sheet.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
                XCTAssertTrue(app.buttons["account.notifications.settings"].waitForExistence(timeout: 3))
                shot("\(screen)-top-\(suffix)")
                try audit("\(screen)-top-\(suffix)")
                // iOS-off: the caption and its Open Settings, under Live Activity.
                let middle = scenario == .account
                    ? app.buttons["account.notifications.live-activity.settings"]
                    : choice("live-activity")
                scrollToElement(middle)
                shot("\(screen)-middle-\(suffix)")
                try audit("\(screen)-middle-\(suffix)")
                let unmute = app.buttons["account.notifications.unmute"].firstMatch
                scrollToElement(unmute)
                shot("\(screen)-bottom-\(suffix)")
                try audit("\(screen)-bottom-\(suffix)")
                scrollToElement(closeScores)
                flip(closeScores)
                XCTAssertEqual(closeScores.value as? String, "1")
            }
        }
    }

    // MARK: Helpers

    private enum Scenario: String {
        case account
        case notificationChoices = "notification-choices"
    }

    private func launch(_ scenario: Scenario, arguments: [String] = []) {
        if app.state != .notRunning { app.terminate() }
        app = XCUIApplication()
        XCUIDevice.shared.appearance = arguments.contains("Dark") ? .dark : .light
        app.launchEnvironment["TZ"] = "America/Los_Angeles"
        // Never pin `-healthcomp.notifications.*`: the argument domain
        // would override the switches' own writes.
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", scenario.rawValue,
            "-healthcomp.colorHintSeen", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ] + arguments
        app.launch()
        switch scenario {
        case .account:
            XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 10))
        case .notificationChoices:
            XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 10))
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func text(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func choice(_ id: String) -> XCUIElement {
        app.switches["account.notifications.choice.\(id)"].firstMatch
    }

    private func liveActivityCaption() -> XCUIElement {
        text(Self.liveActivitiesOff)
    }

    private func openAccount() {
        let account = app.buttons["app.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 3))
        account.tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 3))
    }

    private func openNotificationsFromAccount() {
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 8))
        openNotifications()
    }

    private func openNotifications() {
        let notifications = element("account.notifications")
        scrollToElement(notifications)
        notifications.tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 3))
    }

    private func closeNotificationsAndAccount() {
        app.navigationBars["Notifications"].buttons["Account"].tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 3))
        app.navigationBars["Account"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
    }

    private func setAll(_ rows: [(id: String, label: String)], on: Bool) {
        for row in rows {
            let toggle = choice(row.id)
            scrollToElement(toggle)
            if (toggle.value as? String == "1") != on { flip(toggle) }
            XCTAssertEqual(toggle.value as? String, on ? "1" : "0", row.id)
        }
    }

    private func assertAll(
        _ rows: [(id: String, label: String)],
        on: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for row in rows {
            let toggle = choice(row.id)
            scrollToElement(toggle)
            XCTAssertEqual(toggle.value as? String, on ? "1" : "0", row.id, file: file, line: line)
        }
    }

    /// A `Toggle` in a `List` exposes a row-wide switch; a tap at its center
    /// can land on the label, so tap the inner switch or the trailing edge.
    private func flip(_ toggle: XCUIElement) {
        scrollToElement(toggle)
        let knob = toggle.switches.firstMatch
        if knob.exists {
            knob.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
    }

    private func summary(_ kinds: String, registrations: Int, failures: Int) -> String {
        "Muted push kinds: \(kinds). Registrations: \(registrations). Failed: \(failures)."
    }

    private func serverLabel() -> String {
        // The Test Lab root's identifier covers this text's own.
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Muted push kinds:"))
            .firstMatch.label
    }

    private func waitForServer(
        _ kinds: String,
        registrations: Int,
        failures: Int,
        timeout: TimeInterval = 8
    ) -> Bool {
        let expected = summary(kinds, registrations: registrations, failures: failures)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if serverLabel() == expected { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        XCTFail("Server shows \"\(serverLabel())\", expected \"\(expected)\"")
        return false
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Layout and labelling audits on elements fully on screen; an issue
    /// XCTest can't tie to an element (iOS 18 reports one per enabled
    /// `Toggle`) is attached and the screenshots are checked by eye.
    private func audit(_ name: String) throws {
        try XCTContext.runActivity(named: "audit \(name)") { activity in
            let screen = app.windows.firstMatch.frame
            var skipped: [String] = []
            try app.performAccessibilityAudit(
                for: [.textClipped, .hitRegion, .sufficientElementDescription]
            ) { issue in
                guard let element = issue.element else {
                    skipped.append("\(issue.compactDescription): no element. \(issue.detailedDescription)")
                    return true
                }
                if screen.contains(element.frame) {
                    activity.add(XCTAttachment(string: "\(issue.compactDescription): \(element.debugDescription)"))
                    return false
                }
                skipped.append("\(issue.compactDescription): \(element.debugDescription)")
                return true
            }
            if !skipped.isEmpty {
                activity.add(XCTAttachment(string: skipped.joined(separator: "\n\n")))
            }
        }
    }

    private func scrollToElement(_ element: XCUIElement) {
        for _ in 0..<24 {
            if element.exists, element.isHittable,
               app.frame.contains(element.frame) { return }
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
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(element.exists, "\(element)")
        XCTAssertTrue(element.isHittable, "\(element)")
    }
}
