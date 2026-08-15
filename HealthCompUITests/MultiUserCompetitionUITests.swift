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

    func testCreateRemoteUpdatesHistoryAnonymizationRematchAndArchive() {
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
        let rawFixtureToken = Data(repeating: UInt8(0x51), count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertFalse(app.debugDescription.contains(rawFixtureToken))

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
        XCTAssertFalse(app.debugDescription.contains(rawFixtureToken))

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

    func testDarkAccessibilitySizeSharingSurfaceHasNoClippedOrUnnamedControls()
        throws
    {
        launch(
            .sharing,
            appearanceArguments: [
                "-AppleInterfaceStyle", "Dark",
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL",
                "-UIAccessibilityReduceMotionEnabled", "YES",
            ]
        )
        XCTAssertTrue(app.navigationBars["Sharing"].waitForExistence(timeout: 8))
        try app.performAccessibilityAudit(
            for: XCUIAccessibilityAuditType.textClipped
                .union(.hitRegion)
                .union(.sufficientElementDescription)
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

    private func navigateBackToSharing() {
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Sharing"].waitForExistence(timeout: 3))
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
