import XCTest

/// Practice match (spec §9.9, PR 12), driven through the real Home, match
/// screen and result in the remote Test Lab's `practice` scenario.
final class PracticeMatchUITests: XCTestCase {
    private var app: XCUIApplication!

    private static let practiceUUID = "a1000000-0000-4000-8000-00000000000c"
    private static let emptyLine = "Challenge someone to a 7-day match, or warm up against a pacer."
    private static let sheetLine = "Seven days against a bot, scaled to your last two weeks. It doesn’t count toward your record."
    private static let startError = "Couldn’t start the practice match. Try again."
    private static let ax5 = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    private static let darkAX5 = ["-AppleInterfaceStyle", "Dark"] + ax5
    private static let audit = XCUIAccessibilityAuditType.textClipped
        .union(.hitRegion)
        .union(.sufficientElementDescription)

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.appearance = .light
        app = nil
    }

    // MARK: Start

    func testStartTomorrowFromTheEmptyHomeAndEndItBeforeItStarts() throws {
        launchLab(setup: "starts-scheduled")
        XCTAssertTrue(text("No matches yet").waitForExistence(timeout: 8))
        XCTAssertTrue(text(Self.emptyLine).exists)
        let challenge = app.buttons["competition.create.empty"]
        let open = app.buttons["competition.practice.open"]
        XCTAssertEqual(challenge.label, "Challenge Someone")
        XCTAssertEqual(open.label, "Practice Match")
        XCTAssertEqual(buttons("competition.practice.open").count, 1)
        // The quieter button sits under Challenge Someone.
        XCTAssertLessThanOrEqual(challenge.frame.maxY, open.frame.minY)
        XCTAssertGreaterThanOrEqual(open.frame.height, 44)
        XCTAssertFalse(app.buttons["competition.practice.challenge"].exists)
        XCTAssertFalse(app.buttons["competition.history.open"].exists)

        open.tap()
        let sheet = element("competition.practice.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        XCTAssertTrue(text("PRACTICE MATCH").exists)
        XCTAssertTrue(text(Self.sheetLine).exists)
        let pacer = app.buttons["competition.practice.pace.pacer"]
        let chill = app.buttons["competition.practice.pace.chill"]
        let erratic = app.buttons["competition.practice.pace.erratic"]
        let beast = app.buttons["competition.practice.pace.beast"]
        XCTAssertEqual(pacer.label, "Pacer, Your usual week, steady every day.")
        XCTAssertEqual(chill.label, "Chill, A little under your usual. Starts slow.")
        XCTAssertEqual(erratic.label, "Erratic, Huge days and off days. Hard to read.")
        XCTAssertEqual(beast.label, "Beast, Well above your usual, every day.")
        XCTAssertFalse(app.buttons["competition.practice.pace.balanced"].exists)
        // Pacer is the default, and only one bot is ever picked.
        XCTAssertEqual(selected(), ["pacer"])
        XCTAssertLessThan(pacer.frame.minY, chill.frame.minY)
        XCTAssertLessThan(chill.frame.minY, erratic.frame.minY)
        XCTAssertLessThan(erratic.frame.minY, beast.frame.minY)
        for row in [pacer, chill, erratic, beast] {
            XCTAssertGreaterThanOrEqual(row.frame.height, 44)
        }
        chill.tap()
        XCTAssertEqual(selected(), ["chill"])
        beast.tap()
        XCTAssertEqual(selected(), ["beast"])
        erratic.tap()
        XCTAssertEqual(selected(), ["erratic"])
        XCTAssertFalse(element("competition.practice.error").exists)
        let start = app.buttons["competition.practice.start"]
        XCTAssertEqual(start.label, "Start Tomorrow")
        XCTAssertTrue(start.isEnabled)
        XCTAssertTrue(start.isHittable)
        XCTAssertLessThanOrEqual(start.frame.maxY, app.frame.maxY - 34)
        try app.performAccessibilityAudit(for: Self.audit)

        start.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        // Tomorrow's practice is the hero, labeled, with Challenge Someone under it.
        let card = sharingCard(state: "scheduled")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertEqual(all("competition.sharing.scheduled.\(Self.practiceUUID)").count, 1)
        // VoiceOver reads the row line; the card shows "Practice · Scheduled".
        XCTAssertEqual(card.label, "Pacer. Practice · Starts Mon, Aug 17")
        XCTAssertFalse(text("No matches yet").exists)
        XCTAssertFalse(app.buttons["competition.practice.open"].exists)
        XCTAssertFalse(app.buttons["competition.create.empty"].exists)
        let homeChallenge = app.buttons["competition.practice.challenge"]
        scrollToElement(homeChallenge)
        XCTAssertEqual(homeChallenge.label, "Challenge Someone")
        XCTAssertEqual(buttons("competition.practice.challenge").count, 1)
        XCTAssertLessThanOrEqual(card.frame.maxY, homeChallenge.frame.minY)
        XCTAssertFalse(app.buttons["competition.history.open"].exists)
        // Practice never asks for notifications.
        XCTAssertFalse(app.buttons["onboarding.notNow"].waitForExistence(timeout: 2))

        scrollToElement(card)
        card.tap()
        XCTAssertTrue(app.navigationBars["Pacer"].waitForExistence(timeout: 3))
        openMenu()
        XCTAssertFalse(app.buttons["competition.match.cancel"].exists)
        XCTAssertFalse(app.buttons["Cancel Match"].exists)
        XCTAssertFalse(muteMenuItem.exists)
        let end = app.buttons["competition.practice.end"]
        XCTAssertEqual(end.label, "End Practice")
        end.tap()
        confirmEnd()
        XCTAssertTrue(text("No matches yet").waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Home"].exists)
        XCTAssertFalse(card.exists)
        XCTAssertFalse(app.buttons["competition.practice.challenge"].exists)
        // It can be started again.
        XCTAssertTrue(app.buttons["competition.practice.open"].isHittable)
    }

    func testAFailedStartExplainsOnTheSheetAndAReopenedSheetStartsClean() {
        launchLab(arguments: ["-practiceLabFailStarts", "2"])
        openSheet()
        let start = app.buttons["competition.practice.start"]
        start.tap()
        let error = element("competition.practice.error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, Self.startError)
        XCTAssertEqual(all("competition.practice.error").count, 1)
        // The sheet stays open with the same pace and Start ready again.
        XCTAssertTrue(element("competition.practice.sheet").exists)
        XCTAssertEqual(selected(), ["pacer"])
        waitForEnabled(start)
        XCTAssertLessThanOrEqual(error.frame.maxY, start.frame.minY)
        app.buttons["competition.practice.pace.beast"].tap()
        start.tap()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        waitForEnabled(start)
        XCTAssertEqual(selected(), ["beast"])

        // Closed and reopened, the old failure stays hidden.
        closeSheet()
        // The failure isn't repeated as a banner on Home.
        XCTAssertFalse(text(Self.startError).exists)
        XCTAssertFalse(app.staticTexts["Couldn’t finish that. Try again."].exists)
        XCTAssertTrue(text("No matches yet").exists)
        openSheet()
        XCTAssertFalse(element("competition.practice.error").exists)
        XCTAssertEqual(selected(), ["pacer"])
        start.tap()
        XCTAssertTrue(element("competition.practice.sheet").waitForNonExistence(timeout: 5))
        let card = sharingCard(state: "active")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertFalse(text(Self.startError).exists)
    }

    // MARK: Live

    func testLivePracticePlaysLikeAMatchAndEndsFromTheMenu() {
        launchLab()
        openSheet()
        app.buttons["competition.practice.start"].tap()
        let card = sharingCard(state: "active")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertEqual(
            card.label,
            "Pacer. Practice · Day 2 of 7 · Ends Fri night. You 486 points. Pacer 452 points"
        )
        XCTAssertFalse(element("competition.home.live").exists)

        card.tap()
        XCTAssertTrue(app.navigationBars["Pacer"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["competition.nudge"].exists)
        XCTAssertFalse(app.buttons["competition.result.share"].exists)

        // The rules say the pacer is simulated and nothing leaves the iPhone.
        openMenu()
        XCTAssertTrue(app.buttons["Sync status"].exists)
        XCTAssertFalse(muteMenuItem.exists)
        XCTAssertFalse(app.buttons["competition.match.cancel"].exists)
        app.buttons["How scoring works"].tap()
        XCTAssertTrue(text("Nothing leaves this iPhone").waitForExistence(timeout: 3))
        XCTAssertTrue(text("Pacer is simulated.").exists)
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(text("Nothing leaves this iPhone").waitForNonExistence(timeout: 3))

        // Keep Going leaves it running.
        openMenu()
        app.buttons["competition.practice.end"].tap()
        let dialog = app.sheets["End this practice match?"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 3))
        XCTAssertTrue(dialog.staticTexts["It’s removed from this iPhone."].exists)
        XCTAssertTrue(dialog.buttons["End Practice"].exists)
        dialogCancel(dialog, "Keep Going")
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Pacer"].exists)

        // Back returns to the same Home.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        card.tap()
        XCTAssertTrue(app.navigationBars["Pacer"].waitForExistence(timeout: 3))
        openMenu()
        app.buttons["competition.practice.end"].tap()
        confirmEnd()
        XCTAssertTrue(text("No matches yet").waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Pacer"].exists)
    }

    func testAFailedEndKeepsThePracticeAndSaysSo() {
        launchLab(arguments: ["-practiceLabFailEnds", "1"])
        openSheet()
        app.buttons["competition.practice.start"].tap()
        let card = sharingCard(state: "active")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(app.navigationBars["Pacer"].waitForExistence(timeout: 3))
        openMenu()
        app.buttons["competition.practice.end"].tap()
        confirmEnd()
        let issue = element("competition.issue.\(Self.practiceUUID)")
        XCTAssertTrue(issue.waitForExistence(timeout: 5))
        XCTAssertEqual(issue.label, "Couldn’t finish that. Try again.")
        XCTAssertTrue(app.navigationBars["Pacer"].exists)
        openMenu()
        app.buttons["competition.practice.end"].tap()
        confirmEnd()
        XCTAssertTrue(text("No matches yet").waitForExistence(timeout: 5))
    }

    func testTallyingPracticeIsLabeledAndKeepsEndPractice() {
        launchLab(setup: "tallying")
        let card = sharingCard(state: "tallying")
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        XCTAssertTrue(card.label.contains("Practice · "), card.label)
        XCTAssertFalse(card.label.contains("Practice · Practice"), card.label)
        XCTAssertTrue(app.buttons["competition.practice.challenge"].exists)
        card.tap()
        XCTAssertTrue(app.navigationBars["Pacer"].waitForExistence(timeout: 3))
        openMenu()
        XCTAssertTrue(app.buttons["competition.practice.end"].exists)
        XCTAssertFalse(muteMenuItem.exists)
    }

    // MARK: Results

    func testPracticeResultsSayPracticeAndOfferChallengeSomeone() throws {
        let outcomes: [(setup: String, title: String, home: String)] = [
            ("won", "You beat Pacer", "Practice · You won"),
            ("lost", "Pacer won", "Practice · Pacer won"),
            ("tied", "All square with Pacer", "Practice · "),
        ]
        for outcome in outcomes {
            launchLab(setup: outcome.setup)
            let row = sharingCard(state: "completed")
            XCTAssertTrue(row.waitForExistence(timeout: 8))
            XCTAssertEqual(all("competition.sharing.completed.\(Self.practiceUUID)").count, 1)
            XCTAssertTrue(row.label.contains(outcome.home), row.label)
            XCTAssertTrue(row.label.contains("Pacer"), row.label)
            // Nothing to archive and nothing moves to History.
            XCTAssertFalse(anyText(containing: "Moves to History").exists)
            XCTAssertFalse(app.buttons["competition.history.open"].exists)
            XCTAssertFalse(text("No matches yet").exists)
            XCTAssertTrue(app.buttons["competition.practice.challenge"].exists)
            XCTAssertFalse(app.buttons["Archive"].exists)

            row.tap()
            XCTAssertTrue(app.navigationBars["Pacer"].waitForExistence(timeout: 3))
            XCTAssertTrue(text(outcome.title).waitForExistence(timeout: 3), outcome.title)
            XCTAssertTrue(text("Practice · Final · Aug 8\u{2009}–\u{2009}14").exists)
            XCTAssertFalse(anyText(containing: "simulated").exists)
            XCTAssertFalse(element("competition.more").exists)
            XCTAssertFalse(app.buttons["competition.result.share"].exists)
            XCTAssertFalse(app.buttons["competition.rematch.create"].exists)
            XCTAssertFalse(element("competition.result.belt").exists)
            let challenge = app.buttons["competition.practice.challenge"]
            XCTAssertEqual(buttons("competition.practice.challenge").count, 1)
            XCTAssertEqual(challenge.label, "Challenge Someone")
            XCTAssertTrue(challenge.isHittable)
            XCTAssertLessThanOrEqual(challenge.frame.maxY, app.frame.maxY - 34)
        }

        // Challenge Someone goes back to Home and opens the Challenge sheet.
        app.buttons["competition.practice.challenge"].tap()
        XCTAssertTrue(element("competition.create.card").waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Pacer"].exists)
        // Close, not a drag: main's Challenge sheet inherits Home's pull to refresh.
        app.buttons["competition.create.done"].tap()
        XCTAssertTrue(element("competition.create.card").waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Home"].exists)
        XCTAssertTrue(sharingCard(state: "completed").waitForExistence(timeout: 3))
    }

    func testHomeChallengeSomeoneOpensTheChallengeSheet() {
        launchLab(setup: "won")
        let challenge = app.buttons["competition.practice.challenge"]
        XCTAssertTrue(challenge.waitForExistence(timeout: 8))
        XCTAssertEqual(challenge.label, "Challenge Someone")
        scrollToElement(challenge)
        challenge.tap()
        XCTAssertTrue(element("competition.create.card").waitForExistence(timeout: 5))
        app.buttons["competition.create.done"].tap()
        XCTAssertTrue(element("competition.create.card").waitForNonExistence(timeout: 3))
        XCTAssertTrue(challenge.isHittable)
    }

    // MARK: Beside real matches

    func testARealMatchTakesTheHeroAndHomeDropsThePracticeOnlyChallenge() {
        launchLab(setup: "with-scheduled-match")
        let priya = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "competition.sharing.scheduled.", "Priya"
        )).firstMatch
        XCTAssertTrue(priya.waitForExistence(timeout: 8))
        let practice = sharingCard(state: "active")
        XCTAssertTrue(practice.exists)
        let live = element("competition.home.live")
        XCTAssertTrue(live.exists)
        XCTAssertTrue(live.label.contains("LIVE · 1") || anyText(containing: "LIVE · 1").exists, live.label)
        // Priya leads; the practice is an equal card under LIVE.
        XCTAssertLessThan(priya.frame.minY, practice.frame.minY)
        XCTAssertTrue(practice.label.contains("Practice · Day 2 of 7"), practice.label)
        XCTAssertFalse(priya.label.contains("Practice"), priya.label)
        XCTAssertFalse(app.buttons["competition.practice.challenge"].exists)
        XCTAssertFalse(app.buttons["competition.practice.open"].exists)

        launchLab(setup: "with-live-match")
        let jordan = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "competition.sharing.active.", "Jordan"
        )).firstMatch
        XCTAssertTrue(jordan.waitForExistence(timeout: 8))
        XCTAssertTrue(sharingCard(state: "active").exists)
        XCTAssertTrue(anyText(containing: "LIVE · 2").exists)
        XCTAssertFalse(app.buttons["competition.practice.challenge"].exists)
        XCTAssertFalse(jordan.label.contains("Practice"), jordan.label)

        // The real match keeps its own screen: Jordan's has no End Practice.
        jordan.tap()
        XCTAssertTrue(app.navigationBars["Jordan"].waitForExistence(timeout: 3))
        openMenu()
        XCTAssertFalse(app.buttons["competition.practice.end"].exists)
    }

    func testAfterARealWeekHomeOffersNoPractice() {
        launchLab(setup: "after-records")
        XCTAssertTrue(text("Nothing live right now").waitForExistence(timeout: 8))
        XCTAssertFalse(text(Self.emptyLine).exists)
        XCTAssertFalse(app.buttons["competition.practice.open"].exists)
        XCTAssertTrue(app.buttons["competition.create.empty"].exists)
        XCTAssertTrue(app.buttons["competition.history.open"].exists)
    }

    func testOnlyARealMatchAsksForNotifications() {
        launchLab(arguments: ["-practiceLabNotifications", "YES"])
        openSheet()
        app.buttons["competition.practice.start"].tap()
        XCTAssertTrue(sharingCard(state: "active").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["onboarding.notNow"].waitForExistence(timeout: 3))

        launchLab(setup: "with-live-match", arguments: ["-practiceLabNotifications", "YES"])
        XCTAssertTrue(app.buttons["onboarding.notNow"].waitForExistence(timeout: 8))
    }

    /// A real challenge that arrives while the pace sheet is up must not lose
    /// the notifications prompt: it shows once the sheet closes.
    func testAChallengeArrivingUnderThePaceSheetStillGetsTheNotificationsPrompt() {
        launchLab(setup: "challenge-arrives", arguments: ["-practiceLabNotifications", "YES"])
        openSheet()
        // Sam's challenge lands behind the sheet.
        XCTAssertTrue(sharingCard(name: "Sam").waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["onboarding.notNow"].exists)
        sleep(2)
        XCTAssertTrue(element("competition.practice.sheet").exists)
        closeSheet()
        XCTAssertTrue(app.buttons["onboarding.notNow"].waitForExistence(timeout: 5))
    }

    // MARK: Sizes and zones

    func testDarkAX5SheetScrollsToAnInlineStart() throws {
        launchLab(arguments: Self.darkAX5)
        XCTAssertTrue(text("No matches yet").waitForExistence(timeout: 8))
        let open = app.buttons["competition.practice.open"]
        scrollToElement(open)
        open.tap()
        XCTAssertTrue(element("competition.practice.sheet").waitForExistence(timeout: 3))
        let beast = app.buttons["competition.practice.pace.beast"]
        scrollToElement(beast, in: sheetScroll)
        beast.tap()
        XCTAssertEqual(selected(), ["beast"])
        let start = app.buttons["competition.practice.start"]
        scrollToElement(start, in: sheetScroll)
        XCTAssertTrue(start.isHittable)
        XCTAssertLessThanOrEqual(start.frame.maxY, app.frame.maxY - 34)
        try app.performAccessibilityAudit(for: Self.audit)
        start.tap()
        XCTAssertTrue(element("competition.practice.sheet").waitForNonExistence(timeout: 5))
        let card = sharingCard(state: "active")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let challenge = app.buttons["competition.practice.challenge"]
        scrollToElement(challenge)
        try app.performAccessibilityAudit(for: Self.audit)

        launchLab(setup: "won", arguments: Self.darkAX5)
        let row = sharingCard(state: "completed")
        scrollToElement(row)
        row.tap()
        XCTAssertTrue(app.navigationBars["Pacer"].waitForExistence(timeout: 3))
        let resultChallenge = app.buttons["competition.practice.challenge"]
        scrollToElement(resultChallenge)
        XCTAssertTrue(resultChallenge.isHittable)
        try app.performAccessibilityAudit(for: Self.audit)
    }

    func testFarTimeZoneKeepsThePracticeWeekInItsOwnZone() {
        launchLab(setup: "starts-scheduled", environment: ["TZ": "Asia/Tokyo"])
        openSheet()
        app.buttons["competition.practice.start"].tap()
        let card = sharingCard(state: "scheduled")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertEqual(card.label, "Pacer. Practice · Starts Mon, Aug 17 PDT")
    }

    // MARK: Screenshot matrix (not in CI)

    func testScreenshotMatrix() {
        let configurations: [(name: String, arguments: [String])] = [
            ("light-default", []),
            ("dark-default", ["-AppleInterfaceStyle", "Dark"]),
            ("light-ax5", Self.ax5),
            ("dark-ax5", Self.darkAX5),
        ]
        for config in configurations {
            let suffix = config.name
            let ax = suffix.hasSuffix("ax5")
            launchLab(setup: "starts-scheduled", arguments: config.arguments + ["-practiceLabFailStarts", "1"])
            XCTAssertTrue(text("No matches yet").waitForExistence(timeout: 8))
            attachScreenshot("empty-home-\(suffix)")
            let open = app.buttons["competition.practice.open"]
            scrollToElement(open)
            if ax {
                scrollToElement(app.buttons["competition.create.empty"])
                attachScreenshot("empty-home-bottom-\(suffix)")
            }
            open.tap()
            XCTAssertTrue(element("competition.practice.sheet").waitForExistence(timeout: 3))
            sleep(1)
            attachScreenshot("sheet-\(suffix)")
            let start = app.buttons["competition.practice.start"]
            if ax {
                scrollToElement(start, in: sheetScroll)
                attachScreenshot("sheet-bottom-\(suffix)")
            }
            start.tap()
            XCTAssertTrue(element("competition.practice.error").waitForExistence(timeout: 5))
            if ax { scrollToElement(start, in: sheetScroll) }
            attachScreenshot("sheet-error-\(suffix)")
            start.tap()
            XCTAssertTrue(element("competition.practice.sheet").waitForNonExistence(timeout: 5))
            let scheduled = sharingCard(state: "scheduled")
            XCTAssertTrue(scheduled.waitForExistence(timeout: 5))
            // Home keeps the offset that reached Practice Match at AX sizes.
            scrollHomeToTop()
            attachScreenshot("home-scheduled-\(suffix)")
            scrollToElement(scheduled)
            scheduled.tap()
            XCTAssertTrue(app.navigationBars["Pacer"].waitForExistence(timeout: 3))
            attachScreenshot("match-scheduled-\(suffix)")

            launchLab(arguments: config.arguments)
            let openLive = app.buttons["competition.practice.open"]
            scrollToElement(openLive)
            openLive.tap()
            app.buttons["competition.practice.start"].tap()
            let card = sharingCard(state: "active")
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            scrollHomeToTop()
            attachScreenshot("home-live-\(suffix)")
            if ax {
                scrollToElement(app.buttons["competition.practice.challenge"])
                attachScreenshot("home-live-bottom-\(suffix)")
            }
            scrollToElement(card)
            card.tap()
            XCTAssertTrue(app.navigationBars["Pacer"].waitForExistence(timeout: 3))
            attachScreenshot("match-live-\(suffix)")
            openMenu()
            attachScreenshot("match-menu-\(suffix)")
            app.buttons["competition.practice.end"].tap()
            XCTAssertTrue(app.sheets["End this practice match?"].waitForExistence(timeout: 3))
            sleep(1)
            attachScreenshot("end-confirmation-\(suffix)")
            dialogCancel(app.sheets["End this practice match?"], "Keep Going")
            openMenu()
            app.buttons["How scoring works"].tap()
            XCTAssertTrue(text("Nothing leaves this iPhone").waitForExistence(timeout: 3))
            sleep(1)
            attachScreenshot("rules-\(suffix)")

            launchLab(setup: "tallying", arguments: config.arguments)
            XCTAssertTrue(sharingCard(state: "tallying").waitForExistence(timeout: 8))
            attachScreenshot("home-tallying-\(suffix)")

            launchLab(setup: "with-scheduled-match", arguments: config.arguments)
            XCTAssertTrue(sharingCard(state: "active").waitForExistence(timeout: 8))
            attachScreenshot("home-with-real-\(suffix)")

            launchLab(setup: "with-live-match", arguments: config.arguments)
            XCTAssertTrue(anyText(containing: "LIVE · 2").waitForExistence(timeout: 8))
            attachScreenshot("home-with-live-\(suffix)")

            launchLab(setup: "after-records", arguments: config.arguments)
            XCTAssertTrue(text("Nothing live right now").waitForExistence(timeout: 8))
            attachScreenshot("home-after-records-\(suffix)")

            launchLab(setup: "challenge-arrives", arguments: config.arguments)
            XCTAssertTrue(sharingCard(name: "Sam").waitForExistence(timeout: 12))
            attachScreenshot("home-challenge-arrived-\(suffix)")

            for outcome in ["won", "lost", "tied"] {
                launchLab(setup: outcome, arguments: config.arguments)
                let row = sharingCard(state: "completed")
                XCTAssertTrue(row.waitForExistence(timeout: 8))
                if outcome == "won" { attachScreenshot("home-result-\(suffix)") }
                scrollToElement(row)
                row.tap()
                XCTAssertTrue(app.navigationBars["Pacer"].waitForExistence(timeout: 3))
                sleep(1)
                attachScreenshot("result-\(outcome)-\(suffix)")
                if ax {
                    scrollToElement(app.buttons["competition.practice.challenge"])
                    attachScreenshot("result-\(outcome)-bottom-\(suffix)")
                }
            }
        }
    }

    // MARK: Helpers

    private func launchLab(
        setup: String = "",
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) {
        if app.state != .notRunning { app.terminate() }
        app = XCUIApplication()
        XCUIDevice.shared.appearance = arguments.contains("Dark") ? .dark : .light
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", "practice",
            "-healthcomp.colorHintSeen", "YES",
            "-practiceLab", setup,
            "-UIAccessibilityReduceMotionEnabled", "YES",
        ] + arguments
        app.launchEnvironment = environment
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
    }

    private func openSheet() {
        XCTAssertTrue(text("No matches yet").waitForExistence(timeout: 8))
        let open = app.buttons["competition.practice.open"]
        scrollToElement(open)
        open.tap()
        XCTAssertTrue(element("competition.practice.sheet").waitForExistence(timeout: 3))
    }

    private func closeSheet() {
        let sheet = element("competition.practice.sheet")
        app.buttons["competition.practice.cancel"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 3))
    }

    private func scrollHomeToTop() {
        for _ in 0..<3 { app.scrollViews.firstMatch.swipeDown(velocity: .fast) }
        sleep(2)
    }

    private func openMenu() {
        // iOS 18 exposes Menu's identified wrapper, not its nested button, as hittable.
        let more = element("competition.more")
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        more.tap()
        XCTAssertTrue(app.buttons["How scoring works"].waitForExistence(timeout: 3))
    }

    private func confirmEnd() {
        let dialog = app.sheets["End this practice match?"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 3))
        dialog.buttons["End Practice"].tap()
    }

    /// The cancel button of an action sheet; on iPhone it may sit outside
    /// the sheet element.
    private func dialogCancel(_ dialog: XCUIElement, _ label: String) {
        let inside = dialog.buttons[label]
        if inside.exists { inside.tap() } else { app.buttons[label].firstMatch.tap() }
    }

    private var muteMenuItem: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mute' OR label BEGINSWITH 'Unmute'")).firstMatch
    }

    /// The pace ids that read as selected.
    private func selected() -> [String] {
        ["pacer", "chill", "erratic", "beast"].filter {
            app.buttons["competition.practice.pace.\($0)"].isSelected
        }
    }

    private func waitForEnabled(_ element: XCUIElement) {
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
    }

    private func text(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func anyText(containing fragment: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    private func element(_ identifier: String) -> XCUIElement {
        all(identifier).firstMatch
    }

    private func all(_ identifier: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: identifier)
    }

    private func buttons(_ identifier: String) -> XCUIElementQuery {
        app.buttons.matching(identifier: identifier)
    }

    private func sharingCard(state: String) -> XCUIElement {
        app.buttons["competition.sharing.\(state).\(Self.practiceUUID)"]
    }

    private func sharingCard(name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "competition.sharing.", name
        )).firstMatch
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The pace sheet's own scroll view, not Home behind it.
    private var sheetScroll: XCUIElement {
        app.scrollViews.containing(
            NSPredicate(format: "identifier == %@", "competition.practice.pace.pacer")
        ).firstMatch
    }

    private func scrollToElement(_ element: XCUIElement, in container: XCUIElement? = nil) {
        for _ in 0..<24 {
            if element.exists, element.isHittable,
               app.frame.contains(element.frame) { return }
            let collectionView = app.collectionViews.firstMatch
            let scrollView = app.scrollViews.firstMatch
            let surface: XCUIElement = container
                ?? (collectionView.exists ? collectionView : (scrollView.exists ? scrollView : app))
            let movesTowardEarlierContent = element.exists
                && element.frame != .zero
                && element.frame.midY < surface.frame.midY
            let start = surface.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: movesTowardEarlierContent ? 0.3 : 0.7)
            )
            let end = surface.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: movesTowardEarlierContent ? 0.55 : 0.45)
            )
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
    }
}
