import XCTest

/// The November feature round's features together (spec §6 cross-feature
/// rules), through the Test Lab's `feature-round` Home: Sam's live match
/// (you hold the belt, Sam's 🔥 on your Day 1, updated 13 hours ago so a
/// nudge is offered), Sam's last week (the belt banner, Sam's 👏 on the
/// result, Share Result), Jordan tallying on Jordan's last check (😤 on your
/// Day 6, the tally panel's nudge), Riley, and a practice match. Account
/// switches use `notification-choices`; the Live Activity uses its preview.
/// Now is Sun Aug 16, 1:00 AM in Los Angeles.
final class FeatureRoundIntegrationUITests: XCTestCase {
    private var app: XCUIApplication!

    private static let samLive = "competition.sharing.active.a4000000-0000-4000-8000-000000000012"
    private static let samResult = "competition.sharing.completed.a4000000-0000-4000-8000-000000000011"
    private static let jordan = "competition.sharing.tallying.a4000000-0000-4000-8000-000000000021"
    private static let riley = "competition.sharing.active.a4000000-0000-4000-8000-000000000031"
    private static let practice = "competition.sharing.active.a1000000-0000-4000-8000-00000000000c"
    private static let ax5 = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        if app.state != .notRunning { app.terminate() }
        XCUIDevice.shared.appearance = .light
        app = nil
    }

    // MARK: Match screen

    func testMatchCarriesTheBeltAReactionAndANudgeInOrder() {
        launch()
        let sam = button(Self.samLive)
        scrollToElement(sam)
        let label = sam.label
        XCTAssertTrue(label.hasPrefix("Sam. Day 2 of 7"), label)
        // VoiceOver: the belt first, then the reaction.
        XCTAssertTrue(label.hasSuffix(". You hold the belt. Fire. Sam reacted to your Day 1"), label)

        sam.tap()
        XCTAssertTrue(app.navigationBars["Sam"].waitForExistence(timeout: 3))
        // The belt stays on Home, the result and the person page.
        XCTAssertEqual(labels(containing: "belt").count, 0)
        let nudge = app.buttons["competition.nudge"]
        XCTAssertTrue(nudge.waitForExistence(timeout: 3))
        XCTAssertEqual(nudge.label, "Nudge Sam")
        XCTAssertEqual(app.buttons.matching(identifier: "competition.nudge").count, 1)
        let latest = app.buttons["competition.reaction.latest"]
        XCTAssertTrue(latest.exists)
        XCTAssertEqual(latest.label, "Fire. Sam reacted to your Day 1")
        // Scoreboard group with the nudge, then the reaction line.
        XCTAssertLessThan(nudge.frame.maxY, latest.frame.minY + 1)
        XCTAssertFalse(app.buttons["competition.practice.end"].exists)

        nudge.tap()
        let sent = element("competition.nudge.sent")
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        XCTAssertEqual(spaced(sent.label), "Nudged at 1:00 AM. You can nudge again tomorrow.")
        XCTAssertFalse(nudge.exists)
        // The line stays after the nudge.
        XCTAssertTrue(latest.exists)

        latest.tap()
        XCTAssertTrue(app.staticTexts["Day 1"].waitForExistence(timeout: 3))
        XCTAssertEqual(element("competition.reaction.received").label, "Fire. Sam reacted to your Day 1")
        chip("clap").tap()
        XCTAssertTrue(waitFor(chip("clap"), "isSelected == true", timeout: 3))
        closeDrawer()
        XCTAssertTrue(sent.exists)

        // Seen: Home keeps the belt and drops the reaction.
        goBack()
        let after = button(Self.samLive)
        scrollToElement(after)
        XCTAssertTrue(after.label.hasSuffix(". You hold the belt"), after.label)
        XCTAssertFalse(after.label.contains("reacted"), after.label)
        // The nudge is still sent when you come back.
        after.tap()
        XCTAssertTrue(element("competition.nudge.sent").waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["competition.nudge"].exists)
    }

    func testTallyingMatchShowsTheReactionLineAboveTheTallyPanelAndItsNudge() {
        launch()
        let jordan = button(Self.jordan)
        scrollToElement(jordan)
        XCTAssertTrue(jordan.label.hasSuffix("Huffing. Jordan reacted to your Day 6"), jordan.label)
        XCTAssertFalse(jordan.label.contains("belt"), jordan.label)

        jordan.tap()
        XCTAssertTrue(app.navigationBars["Jordan"].waitForExistence(timeout: 3))
        let latest = app.buttons["competition.reaction.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 3))
        XCTAssertEqual(latest.label, "Huffing. Jordan reacted to your Day 6")
        let tally = element("competition.tally")
        XCTAssertTrue(tally.exists)
        XCTAssertTrue(tally.label.contains("Waiting for Jordan’s last check"), tally.label)
        XCTAssertLessThan(latest.frame.maxY, tally.frame.minY + 1)
        let nudge = app.buttons["competition.nudge"]
        XCTAssertTrue(nudge.exists)
        XCTAssertEqual(nudge.label, "Nudge Jordan")
        XCTAssertEqual(app.buttons.matching(identifier: "competition.nudge").count, 1)
        XCTAssertGreaterThanOrEqual(nudge.frame.minY, tally.frame.maxY)
        scrollToElement(nudge)
        nudge.tap()
        XCTAssertTrue(element("competition.nudge.sent").waitForExistence(timeout: 5))
        XCTAssertTrue(tally.exists)
    }

    // MARK: Result screen

    func testResultStacksTheBeltBannerReactionsAndShareResult() {
        launch()
        let result = button(Self.samResult)
        scrollToElement(result)
        let label = result.label
        XCTAssertTrue(label.contains("Moves to History"), label)
        XCTAssertTrue(label.hasSuffix(". Clap. Sam reacted to the result"), label)
        XCTAssertFalse(label.contains("belt"), label)

        result.tap()
        XCTAssertTrue(app.navigationBars["Sam"].waitForExistence(timeout: 3))
        let banner = element("competition.result.belt")
        XCTAssertTrue(banner.waitForExistence(timeout: 3))
        XCTAssertTrue(banner.label.hasPrefix("You took the belt"), banner.label)
        let panel = element("competition.result.react")
        XCTAssertTrue(panel.exists)
        XCTAssertEqual(element("competition.reaction.received").label, "Clap. Sam reacted to the result")
        // Title and score, belt banner, reaction panel, the week, Share Result.
        XCTAssertLessThanOrEqual(banner.frame.maxY, panel.frame.minY)
        let share = app.buttons["competition.result.share"]
        scrollToElement(share)
        XCTAssertLessThanOrEqual(panel.frame.maxY, share.frame.minY)
        XCTAssertLessThanOrEqual(element("competition.result.week").frame.maxY, share.frame.minY)
        XCTAssertEqual(app.buttons.matching(identifier: "competition.result.share").count, 1)
        // Sam's next match is live: the pinned action opens it.
        XCTAssertFalse(app.buttons["competition.rematch.create"].exists)
        let viewMatch = app.buttons["competition.rematch.view-match"]
        XCTAssertEqual(viewMatch.label, "View Match")
        XCTAssertLessThanOrEqual(share.frame.maxY, viewMatch.frame.minY)

        scrollToElement(chip("salute"))
        chip("salute").tap()
        XCTAssertTrue(waitFor(chip("salute"), "isSelected == true", timeout: 3))

        // The card carries the belt line.
        scrollToElement(share)
        share.tap()
        let card = element("competition.recap.card")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.label.hasSuffix("You took the belt."), card.label)
        XCTAssertFalse(card.label.contains("reacted"), card.label)
        app.buttons["Close"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 3))
        XCTAssertTrue(chip("salute").isSelected)
    }

    // MARK: Home

    func testHomeWithSeveralMatchesAndAPractice() {
        launch()
        XCTAssertTrue(anyText(beginningWith: "LIVE · 4").waitForExistence(timeout: 3))
        // Real matches are live: no practice-only Challenge Someone.
        XCTAssertFalse(app.buttons["competition.practice.challenge"].exists)

        let practice = button(Self.practice)
        scrollToElement(practice)
        XCTAssertTrue(practice.label.hasPrefix("Pacer. Practice · Day 2 of 7"), practice.label)
        XCTAssertFalse(practice.label.contains("belt"), practice.label)
        XCTAssertFalse(practice.label.contains("reacted"), practice.label)
        let riley = button(Self.riley)
        scrollToElement(riley)
        XCTAssertFalse(riley.label.contains("belt"), riley.label)
        XCTAssertFalse(riley.label.contains("Practice"), riley.label)

        // Live cards: soonest end first.
        let jordan = button(Self.jordan)
        scrollToElement(jordan)
        XCTAssertLessThan(jordan.frame.minY, button(Self.samLive).frame.minY)

        // The practice's screen: no nudge, reactions or mute; End Practice.
        scrollToElement(practice)
        practice.tap()
        XCTAssertTrue(app.navigationBars["Pacer"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["competition.nudge"].exists)
        XCTAssertFalse(app.buttons["competition.reaction.latest"].exists)
        XCTAssertEqual(labels(containing: "belt").count, 0)
        openDay(1)
        XCTAssertFalse(chip("clap").exists)
        closeDrawer()
        let more = element("competition.more")
        more.tap()
        XCTAssertTrue(app.buttons["competition.practice.end"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["competition.match.cancel"].exists)
        let dismiss = app.otherElements["PopoverDismissRegion"]
        if dismiss.exists {
            dismiss.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        }
        XCTAssertTrue(app.buttons["competition.practice.end"].waitForNonExistence(timeout: 3))
        goBack()

        // Only Sam's week is a result; the practice never reaches History.
        let history = app.buttons["competition.history.open"]
        scrollToElement(history)
        history.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 3))
        XCTAssertTrue(labels(containing: "Sam, 1 win").firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(labels(containing: "Pacer").count, 0)
        XCTAssertEqual(labels(containing: "Practice").count, 0)
    }

    // MARK: Account

    /// Switches held on this iPhone (What it takes, Live Activity) never
    /// reach the server; Nudges does.
    func testAccountNotificationSwitchesSendOnlyServerHeldKinds() {
        launchNotificationChoices()
        XCTAssertTrue(waitForServer("Muted push kinds: none. Registrations: 1. Failed: 0."))
        openNotifications()
        let order = ["lead-change", "close-score", "what-it-takes", "final-day", "live-activity", "reaction", "nudge"]
        for id in order {
            let toggle = choice(id)
            scrollToElement(toggle)
            XCTAssertEqual(toggle.value as? String, "1", id)
            XCTAssertTrue(toggle.isEnabled, id)
            XCTAssertGreaterThanOrEqual(toggle.frame.height, 43.5, id)
        }
        flip(choice("what-it-takes"))
        flip(choice("live-activity"))
        closeNotificationsAndAccount()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(serverLabel(), "Muted push kinds: none. Registrations: 1. Failed: 0.")

        openNotifications()
        XCTAssertEqual(choice("what-it-takes").value as? String, "0")
        XCTAssertEqual(choice("live-activity").value as? String, "0")
        flip(choice("nudge"))
        closeNotificationsAndAccount()
        XCTAssertTrue(waitForServer("Muted push kinds: nudge. Registrations: 2. Failed: 0."))

        // Back on.
        openNotifications()
        for id in ["what-it-takes", "live-activity", "nudge"] { flip(choice(id)) }
        closeNotificationsAndAccount()
        XCTAssertTrue(waitForServer("Muted push kinds: none. Registrations: 3. Failed: 0."))
    }

    // MARK: Live Activity and widget samples

    func testLiveActivityPreviewSamplesAndWidgetSampleLaunch() {
        for (sample, lead) in [
            ("lead", "You lead by 19."), ("behind", "Sam leads by 5."), ("square", "All square."),
            ("former", "Former competitor leads by 35."),
        ] {
            launchLiveActivity(sample: sample)
            let live = element("liveActivity.preview.live")
            XCTAssertTrue(live.waitForExistence(timeout: 10), sample)
            XCTAssertTrue(live.label.hasPrefix("Last day · "), live.label)
            XCTAssertTrue(live.label.contains(lead), live.label)
            XCTAssertTrue(element("liveActivity.preview.pending").label.contains("Not final yet."), sample)
            XCTAssertEqual(element("liveActivity.preview.minimal").label, lead)
            XCTAssertTrue(app.buttons["liveActivity.preview.start"].isEnabled, sample)
        }
        // The widget hooks write their snapshot alongside the Test Lab.
        for scenario in ["live", "won", "former"] {
            if app.state != .notRunning { app.terminate() }
            app = XCUIApplication()
            app.launchArguments = [
                "--multi-user-competition-test-lab",
                "--multi-user-competition-scenario", "feature-round",
                "--widget-scenario", scenario,
                "-healthcomp.colorHintSeen", "YES",
            ]
            app.launch()
            XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 10), scenario)
            XCTAssertTrue(button(Self.samLive).waitForExistence(timeout: 3), scenario)
        }
    }

    // MARK: Screenshot matrix (not in CI)

    func testScreenshotMatrix() {
        let configurations: [(name: String, arguments: [String])] = [
            ("light-default", ["-AppleInterfaceStyle", "Light"]),
            ("dark-default", ["-AppleInterfaceStyle", "Dark"]),
            ("light-ax5", ["-AppleInterfaceStyle", "Light"] + Self.ax5),
            ("dark-ax5", ["-AppleInterfaceStyle", "Dark"] + Self.ax5),
        ]
        for config in configurations {
            let suffix = config.name
            let arguments = config.arguments + ["-UIAccessibilityReduceMotionEnabled", "YES"]
            launch(arguments)
            shot("home-top", suffix)
            showAtTop(button(Self.samLive))
            shot("home-sam", suffix)
            showAtTop(button(Self.practice))
            shot("home-practice", suffix)
            showAtTop(button(Self.samResult))
            shot("home-results", suffix)

            open(Self.samLive, title: "Sam")
            shot("match-sam", suffix)
            let latest = app.buttons["competition.reaction.latest"]
            scrollToElement(latest)
            shot("match-sam-reaction", suffix)
            app.buttons["competition.nudge"].tap()
            XCTAssertTrue(element("competition.nudge.sent").waitForExistence(timeout: 5))
            shot("match-sam-nudged", suffix)
            latest.tap()
            XCTAssertTrue(app.staticTexts["Day 1"].waitForExistence(timeout: 3))
            shot("day-drawer-sam", suffix)
            closeDrawer()
            goBack()

            open(Self.jordan, title: "Jordan")
            shot("match-jordan-tally", suffix)
            scrollToElement(app.buttons["competition.nudge"])
            shot("match-jordan-tally-nudge", suffix)
            goBack()

            open(Self.practice, title: "Pacer")
            shot("match-practice", suffix)
            goBack()

            open(Self.samResult, title: "Sam")
            shot("result-sam", suffix)
            showAtTop(element("competition.result.belt"))
            shot("result-sam-banner", suffix)
            showAtTop(element("competition.result.react"))
            shot("result-sam-reactions", suffix)
            let share = app.buttons["competition.result.share"]
            scrollToElement(share)
            shot("result-sam-share", suffix)
            share.tap()
            XCTAssertTrue(element("competition.recap.card").waitForExistence(timeout: 5))
            shot("share-sheet-sam", suffix)
            app.buttons["Close"].tap()
            goBack()

            let history = app.buttons["competition.history.open"]
            scrollToElement(history)
            history.tap()
            XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 3))
            shot("history", suffix)

            launchNotificationChoices(arguments)
            openNotifications()
            shot("notifications-top", suffix)
            scrollToElement(choice("nudge"))
            shot("notifications-bottom", suffix)

            launchLiveActivity(sample: "lead", arguments: arguments)
            XCTAssertTrue(element("liveActivity.preview.live").waitForExistence(timeout: 10))
            shot("live-activity-preview", suffix)
        }
    }

    // MARK: Helpers

    private func launch(_ arguments: [String] = []) {
        start("feature-round", arguments)
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 10))
        XCTAssertTrue(button(Self.samLive).waitForExistence(timeout: 5))
    }

    private func launchNotificationChoices(_ arguments: [String] = []) {
        start("notification-choices", arguments)
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 10))
    }

    private func launchLiveActivity(sample: String, arguments: [String] = []) {
        start("live-activity", ["-liveActivityPreviewSample", sample] + arguments)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    private func start(_ scenario: String, _ arguments: [String]) {
        if app.state != .notRunning { app.terminate() }
        app = XCUIApplication()
        XCUIDevice.shared.appearance = arguments.contains("Dark") ? .dark : .light
        app.launchEnvironment["TZ"] = "America/Los_Angeles"
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", scenario,
            "-healthcomp.colorHintSeen", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ] + arguments
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func button(_ identifier: String) -> XCUIElement {
        app.buttons[identifier]
    }

    private func chip(_ kind: String) -> XCUIElement {
        app.buttons["competition.react.\(kind)"]
    }

    private func choice(_ id: String) -> XCUIElement {
        app.switches["account.notifications.choice.\(id)"].firstMatch
    }

    private func labels(containing text: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text))
    }

    private func anyText(beginningWith text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    private func spaced(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private func open(_ identifier: String, title: String) {
        let card = button(identifier)
        scrollToElement(card)
        card.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3), title)
    }

    private func goBack() {
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
    }

    private func openDay(_ ordinal: Int) {
        let week = app.buttons["Week"]
        if week.waitForExistence(timeout: 2), !week.isSelected {
            scrollToElement(week)
            week.tap()
        }
        let day = element("competition.day.\(ordinal)")
        scrollToElement(day)
        day.tap()
        XCTAssertTrue(app.staticTexts["Day \(ordinal)"].waitForExistence(timeout: 3))
    }

    private func closeDrawer() {
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 3))
    }

    private func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func openNotifications() {
        let account = app.buttons["app.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 3))
        account.tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 3))
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

    /// A Toggle's tappable area is its trailing switch.
    private func flip(_ toggle: XCUIElement) {
        scrollToElement(toggle)
        let knob = toggle.switches.firstMatch
        if knob.exists {
            knob.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
    }

    private func serverLabel() -> String {
        anyText(beginningWith: "Muted push kinds:").label
    }

    private func waitForServer(_ expected: String, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if serverLabel() == expected { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        XCTFail("Server shows \"\(serverLabel())\", expected \"\(expected)\"")
        return false
    }

    private func shot(_ screen: String, _ suffix: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "integration-\(screen)-\(suffix)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Scrolls until the element is on screen, then nudges it toward the top.
    private func showAtTop(_ element: XCUIElement) {
        scrollToElement(element)
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<6 where element.frame.minY > scroll.frame.minY + 140 {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    private func scrollToElement(_ element: XCUIElement) {
        for _ in 0..<30 {
            let collection = app.collectionViews.firstMatch
            let scrollView = app.scrollViews.firstMatch
            let surface: XCUIElement = collection.exists ? collection : (scrollView.exists ? scrollView : app)
            // A card taller than the screen (AX5) never fits: its top on
            // screen is enough.
            if element.exists, element.isHittable,
               app.frame.contains(element.frame)
                || (element.frame.height > surface.frame.height / 2
                    && surface.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.minY + 1))) {
                return
            }
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
        XCTAssertTrue(element.exists, "\(element)")
        XCTAssertTrue(element.isHittable, "\(element)")
    }
}
