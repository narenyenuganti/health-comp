import XCTest

final class FriendsAccountUITests: XCTestCase {
    private var app: XCUIApplication!

    private static let saveError = "Couldn’t save. Check your connection and try again."
    private static let footer = "Off: only people with your link can add you. Search shows your name, photo and username, never your rings."
    private static let everyone = "account.privacy.challenge.friends_and_link"
    private static let friendsOnly = "account.privacy.challenge.friends_only"
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

        field.typeText("Be-ta Alice!")
        XCTAssertEqual(field.value as? String, "betaalice")
        waitForStatus("Available")
        XCTAssertTrue(continueButton.isEnabled)

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

        enter("taken_name2")
        waitForStatus("Available")

        enter("late_taken")
        waitForStatus("Available")
        continueButton.tap()
        waitForStatus("Taken")
        XCTAssertTrue(field.exists)

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

    func testAppearancesAndLargestTextSize() throws {
        let sizes = [("default", "UICTContentSizeCategoryL"), ("ax5", "UICTContentSizeCategoryAccessibilityXXXL")]
        for appearance in ["Light", "Dark"] {
            for (sizeName, size) in sizes {
                let suffix = "\(appearance.lowercased())-\(sizeName)"
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
                try audit("username \(suffix)")
                enter("taken_name")
                waitForStatus("Taken")
                shot("username-taken-\(suffix)")
            }
        }
    }

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

    private var shown: String {
        func label(_ element: XCUIElement) -> String { element.exists ? "'\(element.label)'" : "absent" }
        let text = field.exists ? "'\(fieldValue)'" : "absent"
        return "field \(text), status \(label(status)), error \(label(element("account.username.error"))), "
            + "page error \(label(element("account.privacy.error")))"
    }

    private var fieldValue: String {
        let value = field.value as? String ?? ""
        return value == field.placeholderValue ? "" : value
    }

    private func enter(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        clearField(file: file, line: line)
        field.typeText(text)
        XCTAssertTrue(
            waitUntil(5) { self.fieldValue == text },
            "Typed '\(text)'; \(shown)",
            file: file, line: line
        )
    }

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
                    guard issue.element != nil || issue.auditType != .textClipped else {
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
