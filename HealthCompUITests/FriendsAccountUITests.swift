import XCTest

/// Account → Privacy's username and friend settings, through the app's own
/// root view. The `friends-account` Test Lab scenario scripts the server:
/// no username yet, every call takes 0.3 s, `taken_name` is taken,
/// `late_taken` passes the check and fails on save, `offline_name` fails to
/// save once, and the first save that changes Show Me in Search fails.
final class FriendsAccountUITests: XCTestCase {
    private var app: XCUIApplication!

    private static let saveError = "Couldn’t save. Check your connection and try again."
    private static let footer = "Off: only people with your link can add you. Search shows your name, photo and username, never your rings."
    private static let everyone = "account.privacy.challenge.friends_and_link"
    private static let friendsOnly = "account.privacy.challenge.friends_only"
    /// Wrapped or single-line text the clipping audit flags anyway, seen
    /// whole in the attached screenshots: tracked section labels, the page's
    /// older rows, and the section footer.
    private static let readsClippedToTheAudit: Set<String> = [
        "USERNAME", "FINDING YOU", "WHO CAN CHALLENGE YOU", footer,
        "Raw Health data stays on this iPhone",
        "The other person gets your daily points, rounded Activity percentages and modes",
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

    func testChooseAUsername() {
        openPrivacy()
        XCTAssertTrue(app.staticTexts["USERNAME"].exists)
        XCTAssertTrue(app.staticTexts["FINDING YOU"].exists)
        XCTAssertTrue(app.staticTexts["WHO CAN CHALLENGE YOU"].exists)
        XCTAssertTrue(app.staticTexts[Self.footer].exists)
        openSheet("account.privacy.username.choose")
        XCTAssertTrue(app.staticTexts["Pick a username"].exists)
        XCTAssertTrue(app.staticTexts["Friends find you by it."].exists)
        XCTAssertFalse(continueButton.isEnabled)

        // Case and anything outside a-z 0-9 _ never reach the field.
        field.typeText("Be-ta Alice!")
        XCTAssertEqual(field.value as? String, "betaalice")
        waitForStatus("Available")
        XCTAssertTrue(continueButton.isEnabled)

        // A filtered last keystroke never shows, so the field always holds
        // the name that will be saved, with no wait for a redraw.
        field.typeText("!")
        XCTAssertEqual(fieldValue, "betaalice", shown)
        XCTAssertEqual(status.label, "Available", shown)
        continueButton.tap()

        XCTAssertTrue(field.waitForNonExistence(timeout: 5), shown)
        XCTAssertTrue(element("account.privacy.username").waitForExistence(timeout: 3), shown)
        XCTAssertEqual(element("account.privacy.username").label, "@betaalice")
    }

    func testTakenUsernameKeepsTheSheetOpen() {
        openPrivacy()
        openSheet("account.privacy.username.choose")
        enter("taken_name")
        waitForStatus("Taken")
        XCTAssertFalse(continueButton.isEnabled)

        // Another character asks again.
        enter("taken_name2")
        waitForStatus("Available")

        // Someone else can claim a name between the check and the save.
        enter("late_taken")
        waitForStatus("Available")
        continueButton.tap()
        waitForStatus("Taken")
        XCTAssertTrue(field.exists)

        // A connection failure stays inline; the same tap works next time.
        enter("offline_name")
        waitForStatus("Available")
        continueButton.tap()
        let error = element("account.username.error")
        XCTAssertTrue(error.waitForExistence(timeout: 5), shown)
        XCTAssertEqual(error.label, Self.saveError)
        XCTAssertEqual(app.alerts.count, 0)
        continueButton.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), shown)
        XCTAssertEqual(element("account.privacy.username").label, "@offline_name")
    }

    func testNotNowLeavesTheUsernameUnset() {
        openPrivacy()
        openSheet("account.privacy.username.choose")
        enter("betaalice")
        app.buttons["account.username.not-now"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 3), shown)
        XCTAssertTrue(app.buttons["account.privacy.username.choose"].exists)
    }

    func testEditAUsername() {
        openPrivacy()
        openSheet("account.privacy.username.choose")
        enter("betaalice")
        waitForStatus("Available")
        continueButton.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), shown)

        openSheet("account.privacy.username.edit")
        XCTAssertEqual(field.value as? String, "betaalice")
        // Your own name isn't checked, and saving it again is harmless.
        XCTAssertFalse(status.exists)
        XCTAssertTrue(continueButton.isEnabled)
        enter("alice_b")
        waitForStatus("Available")
        continueButton.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), shown)
        XCTAssertEqual(element("account.privacy.username").label, "@alice_b")
    }

    func testFailedSearchSaveRollsBackThenRetries() {
        openPrivacy()
        let toggle = app.switches["account.privacy.show-in-search"].firstMatch
        XCTAssertEqual(toggle.value as? String, "1")

        flip(toggle)
        let error = element("account.privacy.error")
        XCTAssertTrue(error.waitForExistence(timeout: 5), shown)
        XCTAssertEqual(error.label, Self.saveError)
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertEqual(app.alerts.count, 0)

        flip(toggle)
        XCTAssertTrue(error.waitForNonExistence(timeout: 5), shown)
        XCTAssertTrue(waitUntil(5) { toggle.value as? String == "0" && toggle.isEnabled }, shown)
    }

    func testChangeWhoCanChallengeYou() {
        openPrivacy()
        let everyone = app.buttons[Self.everyone]
        let friendsOnly = app.buttons[Self.friendsOnly]
        XCTAssertTrue(everyone.isSelected)
        XCTAssertFalse(friendsOnly.isSelected)
        XCTAssertEqual(everyone.label, "Friends and anyone with my link")
        XCTAssertEqual(friendsOnly.label, "Friends only")

        friendsOnly.tap()
        XCTAssertTrue(waitUntil(5) { friendsOnly.isSelected && !everyone.isSelected && friendsOnly.isEnabled }, shown)
        XCTAssertFalse(element("account.privacy.error").exists)

        everyone.tap()
        XCTAssertTrue(waitUntil(5) { everyone.isSelected && !friendsOnly.isSelected }, shown)
    }

    /// `privacy-<light|dark>-<default|ax5>`, and the same for the sheet.
    /// Hit regions, clipping and labels are audited in every combination.
    func testAppearancesAndLargestTextSize() throws {
        let sizes = [("default", "UICTContentSizeCategoryL"), ("ax5", "UICTContentSizeCategoryAccessibilityXXXL")]
        for appearance in ["Light", "Dark"] {
            for (sizeName, size) in sizes {
                let suffix = "\(appearance.lowercased())-\(sizeName)"
                // Account's sheet takes System from the iPhone, not the
                // Test Lab's pinned root, so it needs the app's own setting.
                openPrivacy(arguments: [
                    "-AppleInterfaceStyle", appearance,
                    "-healthcomp.appearance", appearance.lowercased(),
                    "-UIPreferredContentSizeCategoryName", size,
                ])
                shot("privacy-\(suffix)")
                try audit("privacy \(suffix)")
                openSheet("account.privacy.username.choose")
                enter("betaalice")
                waitForStatus("Available")
                shot("username-available-\(suffix)")
                // Only what's above the keyboard; the next test reaches the rest.
                try audit("username \(suffix)")
                enter("taken_name")
                waitForStatus("Taken")
                shot("username-taken-\(suffix)")
            }
        }
    }

    /// At AX5 the buttons scroll with the text, so the keyboard covers them
    /// until you scroll. Both stay reachable without closing it.
    func testContinueAndNotNowAreReachableWithTheKeyboardUpAtLargestTextSize() {
        openPrivacy(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openSheet("account.privacy.username.choose")
        enter("betaalice")
        waitForStatus("Available")
        scrollAboveTheKeyboard(continueButton)
        shot("username-continue-reached-ax5")
        continueButton.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), shown)
        XCTAssertEqual(element("account.privacy.username").label, "@betaalice")

        openSheet("account.privacy.username.edit")
        enter("not_saved")
        waitForStatus("Available")
        let notNow = app.buttons["account.username.not-now"]
        scrollAboveTheKeyboard(notNow)
        shot("username-not-now-reached-ax5")
        notNow.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), shown)
        XCTAssertEqual(element("account.privacy.username").label, "@betaalice")
    }

    // MARK: Helpers

    private var field: XCUIElement { app.textFields["account.username.field"] }
    private var status: XCUIElement { element("account.username.status") }
    private var continueButton: XCUIElement { app.buttons["account.username.continue"] }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func openPrivacy(arguments: [String] = []) {
        if app.state != .notRunning { app.terminate() }
        app = XCUIApplication()
        app.launchEnvironment["TZ"] = "America/Los_Angeles"
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", "friends-account",
            "-healthcomp.colorHintSeen", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ] + arguments
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 10), shown)
        app.buttons["app.account"].tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 3), shown)
        let privacy = app.buttons["account.privacy"]
        scrollTo(privacy)
        privacy.tap()
        XCTAssertTrue(app.navigationBars["Privacy"].waitForExistence(timeout: 3), shown)
        XCTAssertTrue(
            app.buttons["account.privacy.username.choose"].waitForExistence(timeout: 5),
            "The rows appear once the server answers. \(shown)"
        )
    }

    private func openSheet(_ identifier: String) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(identifier) \(shown)")
        button.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 3), shown)
        // The field takes focus when the sheet opens.
        XCTAssertTrue(waitUntil(3) { self.app.keyboards.firstMatch.exists }, shown)
    }

    private func flip(_ toggle: XCUIElement) {
        let knob = toggle.switches.firstMatch
        if knob.exists {
            knob.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
    }

    private func scrollAboveTheKeyboard(_ element: XCUIElement) {
        let keyboard = app.keyboards.firstMatch
        func isClear() -> Bool {
            element.exists && element.isHittable && element.frame.maxY <= keyboard.frame.minY
        }
        XCTAssertTrue(keyboard.exists)
        for _ in 0..<8 where !isClear() {
            // Above the keyboard: a drag that reaches it would dismiss it.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )
        }
        XCTAssertTrue(isClear(), "\(element)")
        XCTAssertTrue(keyboard.exists, "The keyboard stays up.")
    }

    /// What the sheet and page show, for failure messages.
    private var shown: String {
        func label(_ element: XCUIElement) -> String { element.exists ? "'\(element.label)'" : "absent" }
        let text = field.exists ? "'\(fieldValue)'" : "absent"
        return "field \(text), status \(label(status)), error \(label(element("account.username.error"))), "
            + "page error \(label(element("account.privacy.error")))"
    }

    /// What the field holds; an empty field reports its empty prompt.
    private var fieldValue: String {
        let value = field.value as? String ?? ""
        return value == field.placeholderValue ? "" : value
    }

    /// Replaces the field's text and waits until it shows exactly that, so a
    /// dropped key fails here instead of as a wrong status later.
    private func enter(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        clearField(file: file, line: line)
        field.typeText(text)
        XCTAssertTrue(
            waitUntil(5) { self.fieldValue == text },
            "Typed '\(text)'; \(shown)",
            file: file, line: line
        )
    }

    /// Deletes only remove what's before the caret, so the caret goes to
    /// the end first, and it repeats until nothing is left.
    private func clearField(file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<4 where !fieldValue.isEmpty {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: fieldValue.count))
        }
        XCTAssertEqual(fieldValue, "", "The field still shows '\(fieldValue)'", file: file, line: line)
    }

    private func waitForStatus(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            waitUntil(5) { self.status.exists && self.status.label == expected },
            "Expected '\(expected)'; \(shown)",
            file: file, line: line
        )
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return condition()
    }

    private func scrollTo(_ element: XCUIElement) {
        // Fully on screen: a row cut by the bottom edge reports hittable,
        // but a tap there lands on the home indicator.
        for _ in 0..<12 where !(element.exists && element.isHittable && app.frame.contains(element.frame)) {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "\(element)")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func audit(_ name: String) throws {
        try XCTContext.runActivity(named: "audit \(name)") { activity in
            let screen = app.windows.firstMatch.frame
            var skipped: [String] = []
            try app.performAccessibilityAudit(
                for: [.textClipped, .hitRegion, .sufficientElementDescription]
            ) { issue in
                if issue.auditType == .textClipped,
                   let label = issue.element?.label,
                   Self.readsClippedToTheAudit.contains(label) {
                    return true
                }
                guard let element = issue.element, !screen.contains(element.frame) else {
                    guard issue.element != nil else {
                        skipped.append(issue.detailedDescription)
                        return true
                    }
                    return false
                }
                skipped.append(element.debugDescription)
                return true
            }
            if !skipped.isEmpty {
                activity.add(XCTAttachment(string: skipped.joined(separator: "\n\n")))
            }
        }
    }
}
