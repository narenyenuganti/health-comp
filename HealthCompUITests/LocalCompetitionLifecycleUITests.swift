import XCTest

final class LocalCompetitionLifecycleUITests: XCTestCase {
    private var app: XCUIApplication!
    private var currentRunID = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        launch(
            fixture: "late-sync",
            direction: "outgoing",
            appearanceArguments: [
                "-AppleInterfaceStyle", "Light",
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryXS",
            ]
        )
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.appearance = .light
        app = nil
    }

    func testOutgoingCompetitionCompletesTheSevenDayLifecycle() {
        XCTAssertTrue(app.navigationBars["Sharing"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["FIXTURE DATA"].exists)
        XCTAssertTrue(app.staticTexts["Alex"].exists)
        XCTAssertTrue(app.staticTexts["Outgoing invitation"].exists)
        XCTAssertTrue(
            app.staticTexts["Alex is simulated on this iPhone."].exists
        )
        XCTAssertFalse(pendingSharingCard.label.contains("total points"))

        pendingSharingCard.tap()
        XCTAssertTrue(
            app.navigationBars["Compete with Alex"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["Outgoing invitation to Alex"].exists)
        XCTAssertTrue(app.buttons["Start with Alex"].exists)
        XCTAssertFalse(app.buttons["Decline"].exists)
        capture("light-small-pending")
        app.buttons["Start with Alex"].tap()

        XCTAssertTrue(app.staticTexts["Scheduled"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Starts next competition day"].exists)
        XCTAssertFalse(app.otherElements["competition.scoreHeader.naren"].exists)
        XCTAssertFalse(app.otherElements["competition.scoreHeader.alex"].exists)
        XCTAssertTrue(app.staticTexts["Scores begin Day 1"].exists)
        capture("light-small-scheduled")

        nextCheckpoint()
        XCTAssertTrue(app.staticTexts["Day 1"].waitForExistence(timeout: 3))
        assertScoreHeaders()
        let rings = app.otherElements["competition.ownerRings"]
        XCTAssertTrue(rings.waitForExistence(timeout: 3))
        XCTAssertTrue(rings.label.contains("Stand or Roll"))
        XCTAssertTrue(rings.label.contains("pause status unknown"))
        XCTAssertFalse(app.otherElements["competition.opponentRings"].exists)
        assertSevenPairedDays()
        XCTAssertTrue(
            app.descendants(matching: .any)["competition.day.7"].label
                .contains("future, --")
        )
        capture("light-small-active")

        for _ in 0..<6 { nextCheckpoint() }
        XCTAssertTrue(app.staticTexts["Ends Today"].waitForExistence(timeout: 3))
        let finalDay = app.descendants(matching: .any)["competition.day.7"]
        scrollToElement(finalDay)
        XCTAssertTrue(finalDay.label.contains("Naren"))
        XCTAssertTrue(finalDay.label.contains("Alex"))
        scrollToTop()
        capture("light-small-ends-today")

        nextCheckpoint()
        XCTAssertTrue(
            app.staticTexts["Tallying Points"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["Day 7 is missing activity data."].exists)
        XCTAssertTrue(
            app.staticTexts.matching(identifier: "competition.lastSync")
                .firstMatch.exists
        )
        let tallyFinalDay = app.descendants(matching: .any)["competition.day.7"]
        scrollToElement(tallyFinalDay)
        XCTAssertTrue(tallyFinalDay.label.contains("missing"))
        scrollToTop()
        XCTAssertTrue(
            app.otherElements["competition.scoreHeader.naren"].label
                .contains("provisional total")
        )
        capture("light-small-tally")

        nextCheckpoint()
        XCTAssertTrue(
            app.staticTexts["Waiting for one more stable read."]
                .waitForExistence(timeout: 3)
        )
        nextCheckpoint()

        XCTAssertTrue(app.staticTexts["You Won"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Final score"].exists)
        XCTAssertTrue(app.staticTexts["Competition Complete"].exists)
        XCTAssertTrue(app.staticTexts["Victory Over Alex"].exists)
        XCTAssertTrue(app.buttons["Rematch"].exists)
        XCTAssertTrue(app.buttons["Archive"].exists)
        XCTAssertTrue(app.otherElements["competition.result"].label.contains("Naren"))
        XCTAssertTrue(app.otherElements["competition.result"].label.contains("Alex"))
        capture("light-small-result")

        let rematch = app.buttons["Rematch"]
        rematch.doubleTap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Sharing"].waitForExistence(timeout: 3))
        scrollToElement(pendingSharingCard)
        XCTAssertEqual(sharingCards(state: "pending").count, 1)
        XCTAssertEqual(sharingCards(state: "completed").count, 1)
        scrollToElement(app.staticTexts["Awards"])
        XCTAssertTrue(app.staticTexts["Awards"].exists)
        XCTAssertTrue(app.staticTexts["Competition Complete"].exists)
        XCTAssertTrue(app.staticTexts["Victory Over Alex"].exists)
        let rivalry = app.descendants(matching: .any)["competition.rivalry"]
        scrollToElement(rivalry)
        XCTAssertTrue(rivalry.exists)
        let earned = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Earned ")
        ).firstMatch
        scrollToElement(earned)
        XCTAssertTrue(earned.exists)
        let completed = sharingCards(state: "completed").firstMatch
        scrollToElement(completed)
        completed.tap()
        XCTAssertTrue(app.navigationBars["Result"].waitForExistence(timeout: 3))
        app.buttons["Archive"].tap()
        XCTAssertTrue(
            app.buttons["Archive"].waitForNonExistence(timeout: 5)
        )
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Sharing"].waitForExistence(timeout: 3))
        XCTAssertEqual(sharingCards(state: "archived").count, 1)

        launch(
            fixture: "late-sync",
            direction: "outgoing",
            appearanceArguments: [
                "-AppleInterfaceStyle", "Light",
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryXS",
            ],
            reuseRunID: true
        )
        XCTAssertTrue(app.navigationBars["Sharing"].waitForExistence(timeout: 8))
        scrollToElement(pendingSharingCard)
        XCTAssertEqual(sharingCards(state: "pending").count, 1)
        XCTAssertEqual(sharingCards(state: "archived").count, 1)
        XCTAssertTrue(app.staticTexts["Awards"].exists)

        let archived = sharingCards(state: "archived").firstMatch
        scrollToElement(archived)
        archived.tap()
        XCTAssertTrue(app.navigationBars["Result"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Archive"].exists)
        let delete = app.buttons["Delete Local Data"]
        scrollToElement(delete)
        XCTAssertTrue(delete.isHittable)
        capture("light-small-archived")

        delete.tap()
        let deleteConfirmation = app.sheets[
            "Delete this competition from this iPhone?"
        ]
        XCTAssertTrue(deleteConfirmation.waitForExistence(timeout: 3))
        deleteConfirmation.buttons["Delete Local Data"].tap()
        XCTAssertTrue(app.navigationBars["Sharing"].waitForExistence(timeout: 5))
        XCTAssertEqual(sharingCards(state: "archived").count, 0)
        XCTAssertEqual(sharingCards(state: "pending").count, 1)
        capture("light-small-deleted")
    }

    func testIncomingDeclinePopsAndReinviteIsReachableAndIdempotent() {
        launch(fixture: "late-sync", direction: "incoming")

        XCTAssertTrue(app.navigationBars["Sharing"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Incoming invitation"].exists)
        pendingSharingCard.tap()
        XCTAssertTrue(
            app.staticTexts["Invitation from Alex"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["Accept invitation from Alex"].exists)
        XCTAssertTrue(app.buttons["Decline invitation from Alex"].exists)
        app.buttons["Decline invitation from Alex"].tap()
        let confirmation = app.alerts["Decline invitation from Alex?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Invitation from Alex"].exists)
        XCTAssertTrue(confirmation.buttons["Keep Invitation"].exists)
        confirmation.buttons["Decline Invitation"].tap()
        XCTAssertTrue(app.navigationBars["Sharing"].waitForExistence(timeout: 3))
        let reinvite = app.buttons["Invite Alex Again"]
        XCTAssertTrue(reinvite.waitForExistence(timeout: 3))
        reinvite.doubleTap()
        scrollToElement(pendingSharingCard)
        XCTAssertEqual(sharingCards(state: "pending").count, 1)
    }

    func testIncomingAcceptSchedulesWithoutPrestartScores() {
        launch(fixture: "late-sync", direction: "incoming")

        XCTAssertTrue(app.navigationBars["Sharing"].waitForExistence(timeout: 8))
        pendingSharingCard.tap()
        let accept = app.buttons["Accept invitation from Alex"]
        XCTAssertTrue(accept.waitForExistence(timeout: 3))
        accept.tap()

        XCTAssertTrue(app.staticTexts["Scheduled"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Scores begin Day 1"].exists)
        XCTAssertFalse(app.otherElements["competition.scoreHeader.naren"].exists)
        XCTAssertFalse(app.otherElements["competition.scoreHeader.alex"].exists)
    }

    func testUnavailableFixtureNamesTheSourceStateWithoutInventingRings() {
        launch(fixture: "unavailable", direction: "outgoing")

        XCTAssertTrue(app.navigationBars["Sharing"].waitForExistence(timeout: 8))
        pendingSharingCard.tap()
        app.buttons["Start with Alex"].tap()
        nextCheckpoint()
        XCTAssertTrue(
            app.staticTexts["Activity source is temporarily unavailable."]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.otherElements["competition.ownerRings"].exists)
        XCTAssertTrue(app.staticTexts["Day 1"].exists)
        capture("light-small-unavailable")
    }

    func testMalformedLabArgumentsFailClosed() {
        app.terminate()
        app.launchArguments = [
            "--local-competition-test-lab",
            "--local-competition-fixture", "not-a-fixture",
        ]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["testlab.configuration-error"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertFalse(app.navigationBars["Sharing"].exists)
        XCTAssertFalse(app.staticTexts["FIXTURE DATA"].exists)
    }

    func testBestAvailableResultDisclosesItsBasis() {
        launch(fixture: "best-available", direction: "outgoing")
        XCTAssertTrue(app.navigationBars["Sharing"].waitForExistence(timeout: 8))
        pendingSharingCard.tap()
        app.buttons["Start with Alex"].tap()

        for _ in 0..<9 { nextCheckpoint() }

        XCTAssertTrue(app.navigationBars["Result"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts[
                "Finalized from the best available accepted Activity data after the reconciliation deadline."
            ].exists
        )
        XCTAssertTrue(app.otherElements["competition.result"].exists)
        capture("light-small-best-available-result")
    }

    func testMoveTimeRollUsesOwnerOnlyTruthfulSystemRings() {
        launch(fixture: "move-time-roll", direction: "outgoing")
        XCTAssertTrue(app.navigationBars["Sharing"].waitForExistence(timeout: 8))
        pendingSharingCard.tap()
        app.buttons["Start with Alex"].tap()
        nextCheckpoint()

        let rings = app.otherElements["competition.ownerRings"]
        XCTAssertTrue(rings.waitForExistence(timeout: 5))
        XCTAssertTrue(rings.label.contains("Naren activity"))
        XCTAssertTrue(rings.label.contains("Move Time"))
        XCTAssertTrue(rings.label.contains("60 of 30 minutes"))
        XCTAssertTrue(rings.label.contains("Roll, 24 of 12 hours"))
        XCTAssertFalse(app.otherElements["competition.opponentRings"].exists)
    }

    func testLossAndTieFixturesRenderBothResultOutcomes() {
        let cases = [
            (
                fixture: "loss",
                title: "Alex Won",
                evidenceName: "light-small-loss-result"
            ),
            (
                fixture: "tie",
                title: "It’s a Tie",
                evidenceName: "light-small-tie-result"
            ),
        ]

        for item in cases {
            launch(fixture: item.fixture, direction: "outgoing")
            XCTAssertTrue(
                app.navigationBars["Sharing"].waitForExistence(timeout: 8)
            )
            pendingSharingCard.tap()
            app.buttons["Start with Alex"].tap()
            for _ in 0..<9 { nextCheckpoint() }

            XCTAssertTrue(
                app.staticTexts[item.title].waitForExistence(timeout: 5)
            )
            let result = app.otherElements["competition.result"]
            XCTAssertTrue(result.exists)
            XCTAssertTrue(result.label.contains("Naren"))
            XCTAssertTrue(result.label.contains("Alex"))
            capture(item.evidenceName)
        }
    }

    func testDarkAccessibilitySizeRemainsNavigableAndReadable() throws {
        launch(
            fixture: "late-sync",
            direction: "outgoing",
            appearanceArguments: [
                "-AppleInterfaceStyle", "Dark",
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL",
                "-UIAccessibilityReduceMotionEnabled", "YES",
            ]
        )

        XCTAssertTrue(
            app.descendants(matching: .any)["testlab.root"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["testlab.appearance"].label,
            "Dark appearance"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["testlab.logical-time"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["testlab.current-step"].exists
        )
        XCTAssertTrue(
            app.buttons.matching(identifier: "testlab.controls")
                .firstMatch.exists
        )
        try app.performAccessibilityAudit(for: .textClipped)
        scrollToElement(pendingSharingCard)
        capture("dark-accessibility-pending")
        pendingSharingCard.tap()
        let start = app.buttons["Start with Alex"]
        tapAfterScrolling(start)
        nextCheckpoint()
        XCTAssertTrue(app.staticTexts["Day 1"].waitForExistence(timeout: 5))
        capture("dark-accessibility-active")
        assertSevenPairedDays()
        try app.performAccessibilityAudit(
            for: XCUIAccessibilityAuditType.textClipped
                .union(.hitRegion)
                .union(.sufficientElementDescription)
        )

        for _ in 0..<6 { nextCheckpoint() }
        XCTAssertTrue(app.staticTexts["Ends Today"].waitForExistence(timeout: 5))
        nextCheckpoint()
        XCTAssertTrue(
            app.staticTexts["Tallying Points"].waitForExistence(timeout: 5)
        )
        scrollToTop()
        capture("dark-accessibility-tally")
        try app.performAccessibilityAudit(
            for: XCUIAccessibilityAuditType.textClipped
                .union(.hitRegion)
        )

        nextCheckpoint()
        nextCheckpoint()
        XCTAssertTrue(app.navigationBars["Result"].waitForExistence(timeout: 5))
        capture("dark-accessibility-result")
    }

    func testAccessibilityPendingCheckpointControlExpandsForItsTwoLineLabel() {
        launch(
            fixture: "late-sync",
            direction: "outgoing",
            appearanceArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        )

        let next = app.buttons["competition.testLab.nextCheckpoint"]
        XCTAssertTrue(next.waitForExistence(timeout: 8))
        XCTAssertGreaterThanOrEqual(
            next.frame.height,
            96,
            "The AXXXL two-line checkpoint label must remain inside its control."
        )
    }

    func testRemainingAppearanceAndTypeSizeGalleryMatrix() {
        let cases: [(
            prefix: String,
            appearance: String,
            contentSize: String,
            expectedAppearanceLabel: String
        )] = [
            (
                prefix: "light-accessibility",
                appearance: "Light",
                contentSize: "UICTContentSizeCategoryAccessibilityXXXL",
                expectedAppearanceLabel: "Light appearance"
            ),
            (
                prefix: "dark-small",
                appearance: "Dark",
                contentSize: "UICTContentSizeCategoryXS",
                expectedAppearanceLabel: "Dark appearance"
            ),
        ]

        for item in cases {
            launch(
                fixture: "late-sync",
                direction: "outgoing",
                appearanceArguments: [
                    "-AppleInterfaceStyle", item.appearance,
                    "-UIPreferredContentSizeCategoryName", item.contentSize,
                    "-UIAccessibilityReduceMotionEnabled", "YES",
                ]
            )
            XCTAssertTrue(
                app.navigationBars["Sharing"].waitForExistence(timeout: 8)
            )
            XCTAssertEqual(
                app.descendants(matching: .any)["testlab.appearance"].label,
                item.expectedAppearanceLabel
            )
            scrollToElement(pendingSharingCard)
            pendingSharingCard.tap()
            XCTAssertTrue(
                app.navigationBars["Compete with Alex"]
                    .waitForExistence(timeout: 5)
            )
            scrollToTop()
            capture("\(item.prefix)-pending")

            tapAfterScrolling(app.buttons["Start with Alex"])
            nextCheckpoint()
            XCTAssertTrue(app.staticTexts["Day 1"].waitForExistence(timeout: 5))
            scrollToTop()
            capture("\(item.prefix)-active")

            for _ in 0..<6 { nextCheckpoint() }
            XCTAssertTrue(
                app.staticTexts["Ends Today"].waitForExistence(timeout: 5)
            )
            nextCheckpoint()
            XCTAssertTrue(
                app.staticTexts["Tallying Points"].waitForExistence(timeout: 5)
            )
            scrollToTop()
            capture("\(item.prefix)-tally")

            nextCheckpoint()
            nextCheckpoint()
            XCTAssertTrue(
                app.navigationBars["Result"].waitForExistence(timeout: 5)
            )
            scrollToTop()
            capture("\(item.prefix)-result")
        }
    }

    func testDynamicTypeAuditCyclesAllSupportedCategories() throws {
        launch(fixture: "late-sync", direction: "outgoing")

        XCTAssertTrue(app.navigationBars["Sharing"].waitForExistence(timeout: 8))
        XCTAssertEqual(
            app.descendants(matching: .any)["testlab.appearance"].label,
            "Light appearance"
        )
        pendingSharingCard.tap()
        tapAfterScrolling(app.buttons["Start with Alex"])
        nextCheckpoint()
        XCTAssertTrue(app.staticTexts["Day 1"].waitForExistence(timeout: 5))

        // XCTest changes the content-size category during this audit, so it
        // must run without a fixed preferred-category launch override.
        try app.performAccessibilityAudit(for: .dynamicType)
    }

    private func assertScoreHeaders() {
        let naren = app.otherElements["competition.scoreHeader.naren"]
        let alex = app.otherElements["competition.scoreHeader.alex"]
        XCTAssertTrue(naren.exists)
        XCTAssertTrue(alex.exists)
        XCTAssertTrue(naren.label.contains("Naren"))
        XCTAssertTrue(naren.label.contains("Today"))
        XCTAssertTrue(naren.label.contains("total"))
        XCTAssertTrue(alex.label.contains("Alex"))
        XCTAssertTrue(alex.label.contains("Today"))
        XCTAssertTrue(alex.label.contains("total"))
    }

    private func assertSevenPairedDays() {
        for ordinal in 1...7 {
            let day = app.descendants(matching: .any)[
                "competition.day.\(ordinal)"
            ]
            if !day.exists { scrollToElement(day) }
            XCTAssertTrue(day.label.contains("Day \(ordinal)"))
            XCTAssertTrue(day.label.contains("Naren"))
            XCTAssertTrue(day.label.contains("Alex"))
        }
    }

    private func nextCheckpoint() {
        let button = app.buttons["competition.testLab.nextCheckpoint"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        let enabled = expectation(
            for: NSPredicate(format: "enabled == true"),
            evaluatedWith: button
        )
        wait(for: [enabled], timeout: 8)
        button.tap()
    }

    private var pendingSharingCard: XCUIElement {
        sharingCards(state: "pending").firstMatch
    }

    private func sharingCards(state: String) -> XCUIElementQuery {
        app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "competition.sharing.\(state)."
            )
        )
    }

    private func launch(
        fixture: String,
        direction: String,
        appearanceArguments: [String] = [],
        reuseRunID: Bool = false
    ) {
        if app.state != .notRunning { app.terminate() }
        XCUIDevice.shared.appearance = appearanceArguments.contains("Dark")
            ? .dark
            : .light
        if !reuseRunID || currentRunID.isEmpty {
            currentRunID = "ui-\(UUID().uuidString.lowercased())"
        }
        app.launchArguments = [
            "--local-competition-test-lab",
            "--local-competition-fixture", fixture,
            "--local-competition-direction", direction,
            "--local-competition-seed", "424242",
            "--local-competition-difficulty", "balanced",
            "--local-competition-run-id", currentRunID,
        ] + appearanceArguments
        app.launch()
    }

    private func tapAfterScrolling(_ element: XCUIElement) {
        scrollToElement(element)
        XCTAssertTrue(element.isHittable)
        element.tap()
    }

    private func scrollToElement(_ element: XCUIElement) {
        for _ in 0..<20 {
            if element.exists, element.isHittable { return }
            let scrollView = app.scrollViews.firstMatch
            let surface: XCUIElement = scrollView.exists ? scrollView : app!
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

    private func scrollToTop() {
        let scrollView = app.scrollViews.firstMatch
        guard scrollView.exists else { return }
        for _ in 0..<8 { scrollView.swipeDown() }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
