import XCTest

final class MultiUserCompetitionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.appearance = .light
        app = nil
    }

    func testCreateRemoteUpdatesHistoryAnonymizationRematchAndArchive() throws {
        launch(.sharing)

        XCTAssertTrue(app.navigationBars["Sharing"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["REMOTE UI TEST LAB"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Compete privately with real people while raw Health data stays on this iPhone."
            ].exists
        )
        XCTAssertFalse(app.staticTexts["FIXTURE DATA"].exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "simulated")
        ).firstMatch.exists)
        let timeZone = app.staticTexts[
            "Competition time zone, America/Los_Angeles"
        ]
        scrollToElement(timeZone)
        XCTAssertTrue(timeZone.exists)

        let create = app.buttons["competition.create.button"]
        scrollToElement(create)
        create.tap()
        XCTAssertTrue(
            app.buttons["competition.create.share"]
                .waitForExistence(timeout: 3)
        )
        let creationToken = rawFixtureToken(byte: 0x51)
        try assertNoPrivateFixtureContentIsSpoken(rawTokens: [creationToken])

        let scheduled = sharingCard(state: "scheduled", name: "Priya")
        scrollToElement(scheduled)
        scheduled.tap()
        XCTAssertTrue(
            app.navigationBars["Competition with Priya"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertEqual(
            app.staticTexts["competition.schedule.dates"].label,
            "Aug 13, 2026–Aug 19, 2026 (America/Los_Angeles)"
        )
        navigateBackToSharing()

        let active = sharingCard(state: "active", name: "Jordan")
        scrollToElement(active)
        active.tap()
        XCTAssertTrue(
            app.navigationBars["Competition with Jordan"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["Day 3"].exists)
        XCTAssertTrue(
            app.otherElements["competition.scoreHeader.naren"].label
                .contains("Beta Alice")
        )
        XCTAssertTrue(
            app.otherElements["competition.scoreHeader.alex"].label
                .contains("Jordan")
        )
        XCTAssertTrue(
            app.otherElements["competition.scoreHeader.naren"].label
                .contains("1,450")
        )
        navigateBackToSharing()

        let completed = sharingCard(
            state: "completed",
            name: "Former competitor"
        )
        scrollToElement(completed)
        completed.tap()
        XCTAssertTrue(app.navigationBars["Result"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["You Won"].exists)
        XCTAssertTrue(app.staticTexts["Victory Over Former competitor"].exists)
        XCTAssertTrue(
            app.otherElements["competition.result"].label
                .contains("Former competitor")
        )
        XCTAssertFalse(
            app.otherElements["competition.result"].label
                .localizedCaseInsensitiveContains("simulated")
        )

        let rematch = app.buttons["competition.rematch.create"]
        scrollToElement(rematch)
        rematch.tap()
        XCTAssertTrue(
            app.buttons["competition.rematch.share"]
                .waitForExistence(timeout: 3)
        )
        let rematchToken = rawFixtureToken(byte: 0x52)
        try assertNoPrivateFixtureContentIsSpoken(
            rawTokens: [creationToken, rematchToken]
        )

        let archive = app.buttons["Archive"]
        scrollToElement(archive)
        archive.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["competition.history.preserved"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.buttons["Delete Local Data"].exists)
    }

    func testColdWarmAndSignedOutClaimConfirmationFlows() {
        for scenario in [Scenario.coldClaim, .warmClaim] {
            launch(scenario)
            XCTAssertTrue(
                app.navigationBars["Competition Invitation"]
                    .waitForExistence(timeout: 8)
            )
            XCTAssertTrue(app.staticTexts["Join this competition?"].exists)
            XCTAssertTrue(
                app.staticTexts["Raw Health data stays on this iPhone"].exists
            )
            XCTAssertTrue(app.buttons["competition.claim.accept"].exists)
            XCTAssertTrue(app.buttons["competition.claim.decline"].exists)
            app.buttons["competition.claim.accept"].tap()
            XCTAssertTrue(
                app.staticTexts["Competition Confirmed"]
                    .waitForExistence(timeout: 5)
            )
            XCTAssertTrue(
                app.staticTexts.matching(
                    NSPredicate(
                        format: "label CONTAINS %@",
                        "America/Los_Angeles"
                    )
                ).firstMatch.exists
            )
        }

        launch(.signedOutClaim)
        XCTAssertTrue(
            app.staticTexts["Sign in to continue"].waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.staticTexts[
                "Your private invitation is waiting on this iPhone. Sign in before deciding whether to join."
            ].exists
        )
        app.buttons["multiuser.claim.sign-in"].tap()
        XCTAssertTrue(
            app.buttons["competition.claim.decline"]
                .waitForExistence(timeout: 3)
        )
        app.buttons["competition.claim.decline"].tap()
        XCTAssertTrue(
            app.staticTexts["Invitation Declined"]
                .waitForExistence(timeout: 3)
        )
    }

    func testUnavailableConsumedAndOfflineClaimRecoveryStayPrivacyCollapsed() {
        launch(.unavailableClaim)
        XCTAssertTrue(
            app.staticTexts["Invitation unavailable"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.staticTexts[
                "This link may be expired, already used, or no longer valid. Ask the sender for a new invitation."
            ].exists
        )
        XCTAssertFalse(app.debugDescription.contains("/invite/"))
        app.buttons["competition.claim.dismiss"].tap()
        XCTAssertTrue(
            app.staticTexts["Invitation Closed"].waitForExistence(timeout: 3)
        )

        launch(.offlineClaim)
        XCTAssertTrue(
            app.staticTexts["Couldn’t connect"].waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.buttons["competition.claim.retry"].exists)
        app.buttons["competition.claim.retry"].tap()
        XCTAssertTrue(
            app.buttons["competition.claim.accept"].waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.debugDescription.contains("/invite/"))
    }

    func testAccountEditingAndPrivacyBoundariesRemainAccessible() {
        launch(.account)
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Raw Health data stays on this iPhone"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Competitors receive only daily competition points"
            ].exists
        )
        app.buttons["account.settings.edit-display-name"].tap()
        let field = app.textFields["account.settings.display-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.press(forDuration: 0.8)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
        }
        field.typeText("Former competitor")
        app.buttons["account.settings.save-display-name"].tap()
        XCTAssertTrue(
            app.staticTexts["account.message"].waitForExistence(timeout: 3)
        )
        XCTAssertEqual(
            app.staticTexts["account.message"].label,
            "Choose a name from 1 to 64 characters without line breaks."
        )
        XCTAssertTrue(app.buttons["account.sign-out"].exists)
    }

    func testAccountDeletionConfirmationCanBeCancelledSafely() {
        launch(.account)
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 8))

        let deleteAccount = app.buttons["account.delete"]
        scrollToElement(deleteAccount)
        deleteAccount.tap()

        let alert = app.alerts["Delete Account?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(
            alert.staticTexts[
                "You will confirm with Sign in with Apple. This permanently deletes your account and cannot be undone."
            ].exists
        )
        XCTAssertTrue(alert.buttons["Delete Account"].exists)
        alert.buttons["Cancel"].tap()

        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Account"].exists)
        XCTAssertTrue(deleteAccount.exists)
        XCTAssertFalse(app.progressIndicators["Deleting account"].exists)
    }

    func testRemoteCompetitionAppearanceAndTypeSizeMatrix() throws {
        let cases: [(
            appearance: String,
            contentSize: String,
            expectedDynamicTypeSize: String
        )] = [
            ("Light", "UICTContentSizeCategoryXS", "xSmall"),
            (
                "Light",
                "UICTContentSizeCategoryAccessibilityXXXL",
                "accessibility5"
            ),
            ("Dark", "UICTContentSizeCategoryXS", "xSmall"),
            (
                "Dark",
                "UICTContentSizeCategoryAccessibilityXXXL",
                "accessibility5"
            ),
        ]
        let auditTypes = XCUIAccessibilityAuditType.textClipped
            .union(.hitRegion)
            .union(.sufficientElementDescription)

        for item in cases {
            let expectedConfiguration =
                "Appearance: \(item.appearance); Dynamic Type: \(item.expectedDynamicTypeSize)"
            launch(
                .sharing,
                appearanceArguments: [
                    "-AppleInterfaceStyle", item.appearance,
                    "-UIPreferredContentSizeCategoryName", item.contentSize,
                    "-UIAccessibilityReduceMotionEnabled", "YES",
                ]
            )
            XCTAssertTrue(
                app.navigationBars["Sharing"].waitForExistence(timeout: 8)
            )
            let create = app.buttons["competition.create.button"]
            scrollToElement(create)
            XCTAssertTrue(create.isHittable)
            assertRemoteRenderedConfiguration(expectedConfiguration)
            try app.performAccessibilityAudit(for: auditTypes)
            try assertNoPrivateFixtureContentIsSpoken()

            let active = sharingCard(state: "active", name: "Jordan")
            scrollToElement(active)
            XCTAssertTrue(active.isHittable)
            active.tap()
            XCTAssertTrue(
                app.navigationBars["Competition with Jordan"]
                    .waitForExistence(timeout: 3)
            )
            let owner = app.otherElements["competition.scoreHeader.naren"]
            let opponent = app.otherElements["competition.scoreHeader.alex"]
            scrollToElement(owner)
            XCTAssertTrue(owner.label.contains("Beta Alice"))
            XCTAssertTrue(
                owner.label.contains("Today"),
                "Expected active current-day context in '\(owner.label)'; type \(owner.elementType), id \(owner.identifier)."
            )
            XCTAssertTrue(
                owner.label.contains(", total "),
                "Expected active cumulative total in '\(owner.label)'."
            )
            scrollToElement(opponent)
            XCTAssertTrue(opponent.label.contains("Jordan"))
            XCTAssertTrue(
                opponent.label.contains("Today"),
                "Expected active current-day context in '\(opponent.label)'; type \(opponent.elementType), id \(opponent.identifier)."
            )
            XCTAssertTrue(
                opponent.label.contains(", total "),
                "Expected active cumulative total in '\(opponent.label)'."
            )
            assertRemoteRenderedConfiguration(expectedConfiguration)
            try app.performAccessibilityAudit(for: auditTypes)

            let dayContexts: [(ordinal: Int, context: String)] = [
                (1, ", complete."),
                (3, "Today, scores so far"),
                (7, "upcoming, no scores yet"),
            ]
            for dayContext in dayContexts {
                let day = app.descendants(matching: .any)[
                    "competition.day.\(dayContext.ordinal)"
                ]
                scrollToElement(day)
                let label = day.label
                XCTAssertTrue(label.hasPrefix("Day \(dayContext.ordinal),"))
                XCTAssertTrue(label.contains(dayContext.context))
                XCTAssertTrue(label.contains("Beta Alice"))
                XCTAssertTrue(label.contains("Jordan"))
                assertRemoteRenderedConfiguration(expectedConfiguration)
                try app.performAccessibilityAudit(for: auditTypes)
            }
            try assertNoPrivateFixtureContentIsSpoken()
            navigateBackToSharing()

            let completed = sharingCard(
                state: "completed",
                name: "Former competitor"
            )
            scrollToElement(completed)
            XCTAssertTrue(completed.isHittable)
            completed.tap()
            XCTAssertTrue(
                app.navigationBars["Result"].waitForExistence(timeout: 3)
            )
            let result = app.otherElements["competition.result"]
            scrollToElement(result)
            XCTAssertTrue(result.label.contains("Beta Alice"))
            XCTAssertTrue(result.label.contains("Former competitor"))
            XCTAssertTrue(result.label.contains("Final score"))
            assertRemoteRenderedConfiguration(expectedConfiguration)
            let resultScreenshot = XCTAttachment(screenshot: app.screenshot())
            resultScreenshot.name =
                "remote-result-\(item.appearance)-\(item.expectedDynamicTypeSize)"
            resultScreenshot.lifetime = .keepAlways
            add(resultScreenshot)
            try app.performAccessibilityAudit(for: auditTypes)

            let rematch = app.buttons["competition.rematch.create"]
            scrollToElement(rematch)
            XCTAssertTrue(rematch.isHittable)
            let archive = app.buttons["Archive"]
            scrollToElement(archive)
            XCTAssertTrue(archive.isHittable)
            assertRemoteRenderedConfiguration(expectedConfiguration)
            try app.performAccessibilityAudit(for: auditTypes)
            try assertNoPrivateFixtureContentIsSpoken()
            navigateBackToSharing()
        }
    }

    func testRemoteCompetitionDynamicTypeRemainsReadable() throws {
        // XCTest changes the content-size category during this audit, so it
        // must run without a fixed preferred-category launch override.
        launch(.sharing)
        XCTAssertTrue(app.navigationBars["Sharing"].waitForExistence(timeout: 8))

        let active = sharingCard(state: "active", name: "Jordan")
        scrollToElement(active)
        active.tap()
        XCTAssertTrue(
            app.navigationBars["Competition with Jordan"]
                .waitForExistence(timeout: 3)
        )
        scrollToElement(app.otherElements["competition.scoreHeader.naren"])
        try app.performAccessibilityAudit(for: .dynamicType)
        navigateBackToSharing()

        let completed = sharingCard(
            state: "completed",
            name: "Former competitor"
        )
        scrollToElement(completed)
        completed.tap()
        XCTAssertTrue(app.navigationBars["Result"].waitForExistence(timeout: 3))
        let result = app.otherElements["competition.result"]
        scrollToElement(result)
        XCTAssertEqual(
            result.label,
            "You Won. Final score. Beta Alice 3,520 points. Former competitor 3,410 points."
        )
        let resultScreenshot = XCTAttachment(screenshot: app.screenshot())
        resultScreenshot.name = "remote-result-default-dynamic-type"
        resultScreenshot.lifetime = .keepAlways
        add(resultScreenshot)
        try app.performAccessibilityAudit(for: .dynamicType)
    }


    func testRemoteActiveDayRemainsReadableAtXXXL() throws {
        try assertRemoteActiveDayReadability(
            contentSize: "UICTContentSizeCategoryXXXL",
            expectedDynamicTypeSize: "xxxLarge"
        )
    }

    func testRemoteActiveDayRemainsReadableAtAccessibility5() throws {
        try assertRemoteActiveDayReadability(
            contentSize: "UICTContentSizeCategoryAccessibilityXXXL",
            expectedDynamicTypeSize: "accessibility5"
        )
    }

    private func assertRemoteActiveDayReadability(
        contentSize: String,
        expectedDynamicTypeSize: String
    ) throws {
        let expectedConfiguration =
            "Appearance: Light; Dynamic Type: \(expectedDynamicTypeSize)"
        launch(
            .sharing,
            appearanceArguments: [
                "-AppleInterfaceStyle", "Light",
                "-UIPreferredContentSizeCategoryName", contentSize,
                "-UIAccessibilityReduceMotionEnabled", "YES",
            ]
        )
        XCTAssertTrue(
            app.navigationBars["Sharing"].waitForExistence(timeout: 8)
        )
        assertRemoteRenderedConfiguration(expectedConfiguration)

        let active = sharingCard(state: "active", name: "Jordan")
        scrollToElement(active)
        active.tap()
        XCTAssertTrue(
            app.navigationBars["Competition with Jordan"]
                .waitForExistence(timeout: 3)
        )

        let upcomingDay = app.descendants(matching: .any)["competition.day.7"]
        scrollToElement(upcomingDay)
        let upcomingLabel = upcomingDay.label
        XCTAssertTrue(upcomingLabel.hasPrefix("Day 7,"))
        XCTAssertTrue(upcomingLabel.contains("upcoming, no scores yet"))
        XCTAssertTrue(upcomingLabel.contains("Beta Alice, future, --"))
        XCTAssertTrue(upcomingLabel.contains("Jordan, future, --"))
        XCTAssertFalse(upcomingLabel.contains("0 points"))
        XCTAssertFalse(upcomingLabel.localizedCaseInsensitiveContains("unavailable"))

        let currentDay = app.descendants(matching: .any)["competition.day.3"]
        scrollToElement(currentDay)
        centerRemoteDayForScreenshot(currentDay)
        assertRemoteRenderedConfiguration(expectedConfiguration)
        XCTAssertEqual(
            currentDay.label,
            "Day 3, Today, scores so far. Beta Alice, 430 points. Jordan, 450 points."
        )
        try assertNoPrivateFixtureContentIsSpoken()

        // Spoken labels already passed before the visual defect. Retain
        // the actual day presentation before the unsuppressed clipping audit.
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "remote-day-three-\(expectedDynamicTypeSize)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        try app.performAccessibilityAudit(for: .textClipped)
    }

    private func centerRemoteDayForScreenshot(_ day: XCUIElement) {
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.exists)
        for _ in 0..<6 {
            let viewport = visibleRemoteScrollFrame(scrollView)
            XCTAssertGreaterThan(viewport.height, 0)
            let dayFrame = day.frame
            if viewport.contains(dayFrame) { return }
            let offset = (dayFrame.midY - viewport.midY) / viewport.height
            let distance = min(0.35, max(0.08, abs(offset)))
            let startY = offset > 0 ? 0.7 : 0.3
            let endY = startY + (offset > 0 ? -distance : distance)
            let start = scrollView.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: startY)
            )
            let end = scrollView.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: endY)
            )
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(
            visibleRemoteScrollFrame(scrollView).contains(day.frame),
            "The full fixture day must be visible before capturing visual evidence."
        )
    }

    private func visibleRemoteScrollFrame(_ scrollView: XCUIElement) -> CGRect {
        let frame = scrollView.frame
        let navigationBar = app.navigationBars.firstMatch
        let top = max(
            frame.minY,
            navigationBar.exists ? navigationBar.frame.maxY : frame.minY
        ) + 2
        return CGRect(
            x: frame.minX,
            y: top,
            width: frame.width,
            height: max(0, frame.maxY - top - 2)
        )
    }

    func testMalformedMultiUserLabArgumentsFailClosed() {
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", "unknown",
        ]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)[
                "multiuser.testlab.configuration-error"
            ].waitForExistence(timeout: 8)
        )
        XCTAssertFalse(app.navigationBars["Sharing"].exists)
    }

    private enum Scenario: String {
        case sharing
        case coldClaim = "cold-claim"
        case warmClaim = "warm-claim"
        case signedOutClaim = "signed-out-claim"
        case unavailableClaim = "unavailable-claim"
        case offlineClaim = "offline-claim"
        case account
    }

    private func launch(
        _ scenario: Scenario,
        appearanceArguments: [String] = []
    ) {
        if app.state != .notRunning { app.terminate() }
        app = XCUIApplication()
        XCUIDevice.shared.appearance = appearanceArguments.contains("Dark")
            ? .dark
            : .light
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", scenario.rawValue,
        ] + appearanceArguments
        app.launch()
    }

    private func sharingCard(state: String, name: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "competition.sharing.\(state).",
                name
            )
        ).firstMatch
    }

    private func rawFixtureToken(byte: UInt8) -> String {
        Data(repeating: byte, count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func assertRemoteRenderedConfiguration(
        _ expectedValue: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let banner = app.staticTexts["REMOTE UI TEST LAB"]
        let observedConfiguration = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "exists == true AND value == %@",
                expectedValue
            ),
            object: banner
        )
        let waitResult = XCTWaiter.wait(
            for: [observedConfiguration],
            timeout: 3
        )
        let actualValue = banner.exists
            ? (banner.value as? String ?? "<no accessibility value>")
            : "<banner missing>"
        XCTAssertEqual(
            waitResult,
            .completed,
            "Expected rendered configuration '\(expectedValue)', observed '\(actualValue)'.",
            file: file,
            line: line
        )
    }

    private func assertNoPrivateFixtureContentIsSpoken(
        rawTokens: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        // Fixture UUIDs can identify routing controls, but must never be spoken.
        // Raw invitation tokens must not appear in any accessibility field.
        var remaining = [try app.snapshot()]
        var spokenContent: [String] = []
        var identifiers: [String] = []
        while let element = remaining.popLast() {
            spokenContent.append(element.label)
            identifiers.append(element.identifier)
            if let value = element.value as? String {
                spokenContent.append(value)
            }
            remaining.append(contentsOf: element.children)
        }
        let spokenText = spokenContent.joined(separator: "\n")
        let privateContent = [
            "A1000000-0000-4000-8000-000000000001",
            "A1000000-0000-4000-8000-000000000002",
            "A1000000-0000-4000-8000-000000000003",
            "A1000000-0000-4000-8000-000000000004",
            "remote-profile:v1:",
        ] + rawTokens
        for content in privateContent {
            XCTAssertFalse(
                spokenText.localizedCaseInsensitiveContains(content),
                "Accessibility labels and values must not expose private fixture content.",
                file: file,
                line: line
            )
        }
        let allAccessibilityText = spokenText + "\n" + identifiers.joined(separator: "\n")
        for token in rawTokens {
            XCTAssertFalse(
                allAccessibilityText.localizedCaseInsensitiveContains(token),
                "Accessibility fields must not expose raw invitation tokens.",
                file: file,
                line: line
            )
        }
    }

    private func navigateBackToSharing() {
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Sharing"].waitForExistence(timeout: 3))
        resetSharingScrollToIntro()
    }

    private func resetSharingScrollToIntro() {
        // People can be absent from the lazy hierarchy while Awards is visible.
        // Restore an invariant earlier anchor before searching downward again;
        // the Create button is replaced after an invitation has been created.
        let intro = app.staticTexts[
            "Compete privately with real people while raw Health data stays on this iPhone."
        ]
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.exists)
        for _ in 0..<24 {
            if intro.exists, intro.isHittable { return }
            let start = scrollView.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)
            )
            let end = scrollView.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)
            )
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(intro.exists, "Sharing intro must exist after scrolling toward the top.")
        XCTAssertTrue(intro.isHittable, "Sharing intro must be reachable before searching People.")
    }

    private func scrollToElement(_ element: XCUIElement) {
        for _ in 0..<24 {
            if element.exists, element.isHittable { return }
            let scrollView = app.scrollViews.firstMatch
            let surface: XCUIElement = scrollView.exists ? scrollView : app
            let movesTowardEarlierContent = element.exists
                && element.frame != .zero
                && element.frame.midY < surface.frame.midY
            let start = surface.coordinate(
                withNormalizedOffset: CGVector(
                    dx: 0.5,
                    dy: movesTowardEarlierContent ? 0.3 : 0.7
                )
            )
            let end = surface.coordinate(
                withNormalizedOffset: CGVector(
                    dx: 0.5,
                    dy: movesTowardEarlierContent ? 0.55 : 0.45
                )
            )
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
    }
}
