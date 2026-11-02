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
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["FIXTURE DATA"].exists)
        XCTAssertTrue(app.staticTexts["Alex"].exists)
        // The row adds the challenge's expiry after its status.
        XCTAssertTrue(staticText(beginningWith: "Challenge sent").exists)
        XCTAssertTrue(
            app.staticTexts["Alex is simulated on this iPhone."].exists
        )
        XCTAssertFalse(pendingSharingCard.label.contains("points"))

        pendingSharingCard.tap()
        XCTAssertTrue(
            app.navigationBars["Alex"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["Challenge to Alex"].exists)
        XCTAssertTrue(app.buttons["Start with Alex"].exists)
        XCTAssertFalse(app.buttons["Decline"].exists)
        capture("light-small-pending")
        app.buttons["Start with Alex"].tap()

        XCTAssertTrue(waitForStatus("Scheduled"))
        XCTAssertFalse(app.staticTexts["Seven-day schedule"].exists)
        XCTAssertTrue(
            app.staticTexts["competition.schedule.dates"].exists
        )
        let dayOne = app.staticTexts["competition.schedule.dates"].label
        XCTAssertFalse(dayOne.contains(":"))
        XCTAssertTrue(dayOne.hasPrefix("Day 1 is "), dayOne)
        XCTAssertTrue(dayOne.hasSuffix("Points start counting at midnight."), dayOne)
        XCTAssertFalse(app.otherElements["competition.scoreHeader.naren"].exists)
        XCTAssertFalse(app.otherElements["competition.scoreHeader.alex"].exists)
        XCTAssertTrue(app.staticTexts["You versus Alex"].exists)
        XCTAssertFalse(app.buttons["Week"].exists)
        capture("light-small-scheduled")

        nextCheckpoint()
        XCTAssertTrue(waitForStatus("Day 1 of 7"))
        assertScoreHeaders()
        let rings = app.otherElements["competition.ownerRings"]
        XCTAssertTrue(rings.waitForExistence(timeout: 3))
        XCTAssertTrue(rings.label.contains("Stand or Roll"))
        XCTAssertTrue(rings.label.contains("200 points"))
        XCTAssertTrue(app.staticTexts["competition.updated"].label.hasPrefix("Updated "))
        XCTAssertFalse(app.otherElements["competition.opponentRings"].exists)
        showWeek()
        assertSevenPairedDays()
        let futureDay = app.descendants(matching: .any)["competition.day.7"].label
        XCTAssertTrue(futureDay.contains("upcoming"))
        XCTAssertFalse(futureDay.contains("--"))
        capture("light-small-active")

        for _ in 0..<6 { nextCheckpoint() }
        XCTAssertTrue(waitForStatus("Last day"))
        // Late sync: Day 7 has no Health summary yet.
        app.buttons["Today"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["competition.notSynced"]
                .waitForExistence(timeout: 3)
        )
        showWeek()
        let finalDay = app.descendants(matching: .any)["competition.day.7"]
        scrollToElement(finalDay)
        XCTAssertTrue(finalDay.label.contains("You"))
        XCTAssertTrue(finalDay.label.contains("Alex"))
        scrollToTop()
        capture("light-small-ends-today")

        nextCheckpoint()
        XCTAssertTrue(
            waitForStatus("Final score pending")
        )
        let tally = app.descendants(matching: .any)["competition.tally"]
        XCTAssertTrue(tally.label.contains("Waiting for your Day 7"), tally.label)
        XCTAssertFalse(tally.label.contains("days 7"))
        XCTAssertTrue(app.buttons["Day 7"].exists)
        XCTAssertFalse(app.buttons["Today"].exists)
        tapMoreMenuItem("Sync status")
        XCTAssertTrue(
            app.staticTexts.matching(identifier: "competition.lastSync")
                .firstMatch.waitForExistence(timeout: 3)
        )
        app.buttons["Close"].tap()
        let tallyFinalDay = app.descendants(matching: .any)["competition.day.7"]
        scrollToElement(tallyFinalDay)
        XCTAssertTrue(tallyFinalDay.label.contains("missing"))
        scrollToTop()
        let tallyHeader = app.otherElements["competition.scoreHeader.naren"].label
        XCTAssertTrue(tallyHeader.contains("provisional total"))
        XCTAssertTrue(tallyHeader.contains("Day 7"))
        capture("light-small-tally")

        nextCheckpoint()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier == %@ AND label CONTAINS %@",
                "competition.tally", "Checking the last scores"
            )).firstMatch.waitForExistence(timeout: 3)
        )
        nextCheckpoint()

        XCTAssertTrue(app.staticTexts["You beat Alex"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts["competition.result.summary"].label.hasPrefix("Won by ")
        )
        XCTAssertTrue(app.otherElements["competition.result"].label.contains("Final score"))
        XCTAssertTrue(app.staticTexts["Victory Over Alex"].exists)
        XCTAssertEqual(app.buttons["competition.rematch.create"].label, "Rematch Alex")
        XCTAssertTrue(moreMenu.exists)
        XCTAssertTrue(app.otherElements["competition.result"].label.contains("You"))
        XCTAssertTrue(app.otherElements["competition.result"].label.contains("Alex"))
        capture("light-small-result")

        // A single tap: the double-submit guard has its own test, and a
        // second tap here could open the new row.
        app.buttons["competition.rematch.create"].tap()
        let rematchReady = app.descendants(matching: .any)["competition.rematch.sent"]
        XCTAssertTrue(rematchReady.waitForExistence(timeout: 3))
        XCTAssertTrue(rematchReady.label.contains("Rematch ready"))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
        scrollToElement(pendingSharingCard)
        XCTAssertEqual(sharingCards(state: "pending").count, 1)
        XCTAssertEqual(sharingCards(state: "completed").count, 1)
        // The rematch waits in Up next; the result sits in Recent results.
        XCTAssertTrue(app.descendants(matching: .any)["competition.home.upNext"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["competition.home.results"].exists)

        openHistory()
        let rivalry = app.descendants(matching: .any)["competition.rivalry"]
        scrollToElement(rivalry)
        XCTAssertTrue(rivalry.exists)
        let records = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "competition.record.")
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records.firstMatch.label.contains("Alex"))
        XCTAssertTrue(records.firstMatch.label.contains("1 win"))
        XCTAssertEqual(sharingCards(state: "completed").count, 1)
        XCTAssertFalse(app.buttons["Awards"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))

        // Swiping a result left reveals Archive; it moves to History.
        let completed = sharingCards(state: "completed").firstMatch
        scrollToElement(completed)
        completed.swipeLeft()
        let archive = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "competition.archive.")
        ).firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 3))
        archive.tap()
        XCTAssertTrue(completed.waitForNonExistence(timeout: 5))
        XCTAssertEqual(sharingCards(state: "completed").count, 0)
        XCTAssertEqual(sharingCards(state: "archived").count, 0)
        openHistory()
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
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        scrollToElement(pendingSharingCard)
        XCTAssertEqual(sharingCards(state: "pending").count, 1)
        openHistory()
        XCTAssertEqual(sharingCards(state: "archived").count, 1)

        let archived = sharingCards(state: "archived").firstMatch
        scrollToElement(archived)
        archived.tap()
        XCTAssertTrue(app.navigationBars["Alex"].waitForExistence(timeout: 5))
        moreMenu.tap()
        XCTAssertFalse(app.buttons["Archive"].exists)
        let delete = app.buttons["Delete Local Data"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        XCTAssertTrue(delete.isHittable)
        capture("light-small-archived")

        delete.tap()
        let deleteConfirmation = app.sheets[
            "Delete this match from this iPhone?"
        ]
        XCTAssertTrue(deleteConfirmation.waitForExistence(timeout: 3))
        deleteConfirmation.buttons["Delete Local Data"].tap()
        // Deleting returns to History, where the competition was opened.
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        XCTAssertEqual(sharingCards(state: "archived").count, 0)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
        XCTAssertEqual(sharingCards(state: "pending").count, 1)
        capture("light-small-deleted")
    }

    func testIncomingDeclineClosesInPlaceAndReinviteIsReachableAndIdempotent() {
        launch(fixture: "late-sync", direction: "incoming")

        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        XCTAssertTrue(staticText(beginningWith: "Challenge received").exists)
        pendingSharingCard.tap()
        XCTAssertTrue(
            app.staticTexts["Challenge from Alex"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["Accept challenge from Alex"].exists)
        XCTAssertTrue(app.buttons["Decline challenge from Alex"].exists)
        app.buttons["Decline challenge from Alex"].tap()
        let confirmation = app.alerts["Decline challenge from Alex?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Alex"].exists)
        XCTAssertTrue(confirmation.buttons["Keep Challenge"].exists)
        confirmation.buttons["Decline Challenge"].tap()
        // The screen stays and says what happened.
        let closed = app.descendants(matching: .any)["competition.closed"]
        XCTAssertTrue(closed.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Challenge declined"].exists)
        XCTAssertTrue(app.navigationBars["Alex"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
        let reinvite = app.buttons["Challenge Alex Again"]
        XCTAssertTrue(reinvite.waitForExistence(timeout: 3))
        reinvite.doubleTap()
        scrollToElement(pendingSharingCard)
        XCTAssertEqual(sharingCards(state: "pending").count, 1)
    }

    func testIncomingAcceptSchedulesWithoutPrestartScores() {
        launch(fixture: "late-sync", direction: "incoming")

        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        pendingSharingCard.tap()
        let accept = app.buttons["Accept challenge from Alex"]
        XCTAssertTrue(accept.waitForExistence(timeout: 3))
        accept.tap()

        XCTAssertTrue(waitForStatus("Scheduled"))
        XCTAssertTrue(app.staticTexts["You versus Alex"].exists)
        XCTAssertFalse(app.buttons["Week"].exists)
        XCTAssertFalse(app.otherElements["competition.scoreHeader.naren"].exists)
        XCTAssertFalse(app.otherElements["competition.scoreHeader.alex"].exists)
    }

    func testUnavailableFixtureNamesTheSourceStateWithoutInventingRings() {
        launch(fixture: "unavailable", direction: "outgoing")

        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        pendingSharingCard.tap()
        app.buttons["Start with Alex"].tap()
        nextCheckpoint()
        XCTAssertTrue(
            app.staticTexts["Activity source is temporarily unavailable."]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.otherElements["competition.ownerRings"].exists)
        XCTAssertTrue(waitForStatus("Day 1 of 7"))
        showWeek()
        let unavailableDay = app.descendants(matching: .any)["competition.day.1"]
        scrollToElement(unavailableDay)
        let unavailableLabel = unavailableDay.label
        XCTAssertTrue(unavailableLabel.contains("Day 1, Today, scores so far"))
        XCTAssertTrue(unavailableLabel.contains(
            "You, Activity source is temporarily unavailable, no points yet"
        ))
        XCTAssertTrue(unavailableLabel.contains("Alex,"))
        XCTAssertFalse(unavailableLabel.contains("unavailable, 0 points"))
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
        XCTAssertFalse(app.navigationBars["Home"].exists)
        XCTAssertFalse(app.staticTexts["FIXTURE DATA"].exists)
    }

    func testBestAvailableResultDisclosesItsBasis() {
        launch(fixture: "best-available", direction: "outgoing")
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        pendingSharingCard.tap()
        app.buttons["Start with Alex"].tap()

        for _ in 0..<9 { nextCheckpoint() }

        XCTAssertTrue(app.navigationBars["Alex"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts[
                "Finalized from the best available accepted Activity data after the reconciliation deadline."
            ].exists
        )
        XCTAssertTrue(app.otherElements["competition.result"].exists)
        capture("light-small-best-available-result")
    }

    func testMoveTimeRollRingRowsUseTruthfulUnits() {
        launch(fixture: "move-time-roll", direction: "outgoing")
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        pendingSharingCard.tap()
        app.buttons["Start with Alex"].tap()
        nextCheckpoint()

        let rings = app.otherElements["competition.ownerRings"]
        XCTAssertTrue(rings.waitForExistence(timeout: 5))
        XCTAssertTrue(rings.label.contains("Your rings"))
        XCTAssertTrue(rings.label.contains("Move Time"))
        XCTAssertTrue(rings.label.contains("60 of 30 minutes"))
        XCTAssertTrue(rings.label.contains("Roll, 24 of 12 hours"))
        XCTAssertFalse(app.otherElements["competition.opponentRings"].exists)

        app.scrollViews.firstMatch.swipeDown()
        XCTAssertTrue(rings.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["competition.updated"].exists)
    }

    func testLossAndTieFixturesRenderBothResultOutcomes() {
        let cases = [
            (
                fixture: "loss",
                title: "Alex won",
                evidenceName: "light-small-loss-result"
            ),
            (
                fixture: "tie",
                title: "All square with Alex",
                evidenceName: "light-small-tie-result"
            ),
        ]

        for item in cases {
            launch(fixture: item.fixture, direction: "outgoing")
            XCTAssertTrue(
                app.navigationBars["Home"].waitForExistence(timeout: 8)
            )
            pendingSharingCard.tap()
            app.buttons["Start with Alex"].tap()
            for _ in 0..<9 { nextCheckpoint() }

            XCTAssertTrue(
                app.staticTexts[item.title].waitForExistence(timeout: 5)
            )
            let result = app.otherElements["competition.result"]
            XCTAssertTrue(result.exists)
            XCTAssertTrue(result.label.contains("You"))
            XCTAssertTrue(result.label.contains("Alex"))
            capture(item.evidenceName)
        }
    }

    func testLossFixtureShowsWhatItTakesAboveYourRings() throws {
        try assertWhatItTakesAboveYourRings(prefix: "light-small")
    }

    func testLossFixtureWhatItTakesWrapsAtDarkAccessibilitySize() throws {
        try assertWhatItTakesAboveYourRings(
            prefix: "dark-ax5",
            appearanceArguments: [
                "-AppleInterfaceStyle", "Dark",
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        )
    }

    private func assertWhatItTakesAboveYourRings(prefix: String, appearanceArguments: [String] = []) throws {
        launch(fixture: "loss", direction: "outgoing", appearanceArguments: appearanceArguments)
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        scrollToElement(pendingSharingCard)
        pendingSharingCard.tap()
        tapAfterScrolling(app.buttons["Start with Alex"])
        // The first checkpoint is the Day 1 boundary: 0–0, goals of 100.
        nextCheckpoint()
        XCTAssertTrue(waitForStatus("Day 1 of 7"))

        let takes = app.descendants(matching: .any)["competition.takes"]
        XCTAssertTrue(takes.waitForExistence(timeout: 3))
        XCTAssertEqual(
            takes.label,
            "1 point to take the lead. About 10 kilocalories of Move or 1 minute of Exercise. Alex can still add points today."
        )
        let rings = app.otherElements["competition.ownerRings"]
        XCTAssertTrue(rings.exists)
        XCTAssertLessThan(takes.frame.minY, rings.frame.minY)
        try app.performAccessibilityAudit(for: .textClipped)
        capture("\(prefix)-takes")

        for _ in 0..<6 { nextCheckpoint() }
        XCTAssertTrue(waitForStatus("Last day"))
        tapAfterScrolling(app.buttons["Today"])
        // Alex has six days and you have none: more than one day can cover.
        XCTAssertTrue(takes.waitForExistence(timeout: 3))
        XCTAssertTrue(takes.label.hasPrefix("Out of reach today"), takes.label)
        XCTAssertFalse(takes.label.contains("of Move"), takes.label)
        try app.performAccessibilityAudit(for: .textClipped)
        capture("\(prefix)-takes-out-of-reach")
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
        XCTAssertTrue(waitForStatus("Day 1 of 7"))
        capture("dark-accessibility-active")
        showWeek()
        assertSevenPairedDays()
        try app.performAccessibilityAudit(
            for: XCUIAccessibilityAuditType.textClipped
                .union(.hitRegion)
                .union(.sufficientElementDescription)
        )

        for _ in 0..<6 { nextCheckpoint() }
        XCTAssertTrue(waitForStatus("Last day"))
        nextCheckpoint()
        XCTAssertTrue(
            waitForStatus("Final score pending")
        )
        scrollToTop()
        capture("dark-accessibility-tally")
        try app.performAccessibilityAudit(
            for: XCUIAccessibilityAuditType.textClipped
                .union(.hitRegion)
        )

        nextCheckpoint()
        nextCheckpoint()
        XCTAssertTrue(app.navigationBars["Alex"].waitForExistence(timeout: 5))
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
                app.navigationBars["Home"].waitForExistence(timeout: 8)
            )
            XCTAssertEqual(
                app.descendants(matching: .any)["testlab.appearance"].label,
                item.expectedAppearanceLabel
            )
            scrollToElement(pendingSharingCard)
            pendingSharingCard.tap()
            XCTAssertTrue(
                app.navigationBars["Alex"]
                    .waitForExistence(timeout: 5)
            )
            scrollToTop()
            capture("\(item.prefix)-pending")

            tapAfterScrolling(app.buttons["Start with Alex"])
            nextCheckpoint()
            XCTAssertTrue(waitForStatus("Day 1 of 7"))
            scrollToTop()
            capture("\(item.prefix)-active")

            for _ in 0..<6 { nextCheckpoint() }
            XCTAssertTrue(
                waitForStatus("Last day")
            )
            nextCheckpoint()
            XCTAssertTrue(
                waitForStatus("Final score pending")
            )
            scrollToTop()
            capture("\(item.prefix)-tally")

            nextCheckpoint()
            nextCheckpoint()
            XCTAssertTrue(
                app.navigationBars["Alex"].waitForExistence(timeout: 5)
            )
            scrollToTop()
            capture("\(item.prefix)-result")
        }
    }

    func testDynamicTypeAuditCyclesAllSupportedCategories() throws {
        launch(fixture: "late-sync", direction: "outgoing")

        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        XCTAssertEqual(
            app.descendants(matching: .any)["testlab.appearance"].label,
            "Light appearance"
        )
        pendingSharingCard.tap()
        tapAfterScrolling(app.buttons["Start with Alex"])
        nextCheckpoint()
        XCTAssertTrue(waitForStatus("Day 1 of 7"))

        // XCTest changes the content-size category during this audit, so it
        // must run without a fixed preferred-category launch override.
        try app.performAccessibilityAudit(for: .dynamicType)
    }

    private func assertScoreHeaders() {
        let naren = app.otherElements["competition.scoreHeader.naren"]
        let alex = app.otherElements["competition.scoreHeader.alex"]
        XCTAssertTrue(naren.exists)
        XCTAssertTrue(alex.exists)
        XCTAssertTrue(naren.label.contains("You"))
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
            if day.label.contains("upcoming") {
                XCTAssertFalse(day.label.contains("You"))
                XCTAssertFalse(day.label.contains("Alex"))
            } else {
                XCTAssertTrue(day.label.contains("You"))
                XCTAssertTrue(day.label.contains("Alex"))
            }
        }
    }

    private func waitForStatus(_ prefix: String, timeout: TimeInterval = 5) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@",
            "competition.status", prefix)).firstMatch.waitForExistence(timeout: timeout)
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

    // A match opens on Today; the day rows live on Week.
    private func showWeek() {
        let week = app.buttons["Week"]
        XCTAssertTrue(week.waitForExistence(timeout: 3))
        week.tap()
    }

    // iOS 18 exposes Menu's identified wrapper, not its nested button, as hittable.
    private var moreMenu: XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "competition.more")
            .firstMatch
    }

    private func tapMoreMenuItem(_ title: String) {
        let more = moreMenu
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        more.tap()
        let item = app.buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.tap()
    }

    private func openHistory() {
        let history = app.buttons["competition.history.open"]
        scrollToElement(history)
        history.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 3))
    }

    private func staticText(beginningWith prefix: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", prefix)
        ).firstMatch
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
        app = XCUIApplication()
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
            // The one-time color hint would shift scoreboards by test order.
            "-healthcomp.colorHintSeen", "YES",
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
