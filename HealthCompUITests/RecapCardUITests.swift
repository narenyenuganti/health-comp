import XCTest

/// Share Result and its sheet (spec §9.2), driven through the remote Test Lab.
final class RecapCardUITests: XCTestCase {
    private var app: XCUIApplication!

    private static let longName = "Maximiliana Alexandrovna Featherstonehaugh-Montgomery Wellington"
    private static let morganWeek = "competition.sharing.archived.a1000000-0000-4000-8000-000000000004"
    private static let jordanPastWeek = "competition.sharing.archived.a1000000-0000-4000-8000-000000000009"
    private static let longNameWeek = "competition.sharing.archived.a1000000-0000-4000-8000-00000000000d"
    private static let darkAX5 = [
        "-AppleInterfaceStyle", "Dark",
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        "-UIAccessibilityReduceMotionEnabled", "YES",
    ]
    private static let caseyShown = "Casey won. Aug 13 to 19, 2026. You 2,692 points. Casey 2,800 points. Lost by 108 points, won 1 day, lost 6. Best day: Sunday, 512 points. Casey took the belt."

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.appearance = .light
        app = nil
    }

    // MARK: Flows

    func testLossSheetPreviewsTheCardAndClosesBackToTheResult() {
        launchLab()
        openHomeResult("Casey")

        // Share Result sits in the scroll after the belt banner and the week,
        // above the one pinned primary action.
        let share = app.buttons["competition.result.share"]
        scrollToElement(share)
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertEqual(share.label, "Share Result")
        XCTAssertEqual(buttons("competition.result.share").count, 1)
        let week = element("competition.result.week")
        XCTAssertTrue(week.exists)
        XCTAssertLessThanOrEqual(week.frame.maxY, share.frame.minY)
        XCTAssertLessThanOrEqual(element("competition.result.belt").frame.maxY, week.frame.minY)
        // An unarchived result has no archive note.
        XCTAssertFalse(element("competition.history.preserved").exists)
        let rematch = app.buttons["competition.rematch.create"]
        XCTAssertEqual(rematch.label, "Rematch Casey")
        XCTAssertTrue(rematch.isHittable)
        XCTAssertLessThanOrEqual(share.frame.maxY, rematch.frame.minY)

        share.tap()
        let card = element("competition.recap.card")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Share Result"].exists)
        XCTAssertEqual(all("competition.recap.card").count, 1)
        XCTAssertEqual(buttons("competition.recap.share").count, 1)
        XCTAssertFalse(element("competition.recap.error").exists)
        app.buttons["Show Casey"].tap()
        XCTAssertTrue(app.buttons["Show Casey"].isSelected)
        XCTAssertFalse(app.buttons["Hide name"].isSelected)
        XCTAssertEqual(card.label, Self.caseyShown)

        // A 4:5 preview, at most 320 pt wide and centred.
        XCTAssertLessThanOrEqual(card.frame.width, 321)
        XCTAssertEqual(card.frame.height / card.frame.width, 1.25, accuracy: 0.02)
        XCTAssertEqual(card.frame.midX, app.frame.midX, accuracy: 1)

        let imageShare = waitForEnabledShare()
        XCTAssertEqual(imageShare.label, "Share")
        XCTAssertTrue(imageShare.isHittable)
        // Clear of the home indicator.
        XCTAssertLessThanOrEqual(imageShare.frame.maxY, app.frame.maxY - 34)
        XCTAssertGreaterThanOrEqual(imageShare.frame.height, 44)

        app.buttons["Close"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Casey"].exists)
        XCTAssertTrue(share.isHittable)

        // A swipe down dismisses it too.
        share.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.swipeDown(velocity: .fast)
        XCTAssertTrue(card.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Casey"].exists)
    }

    func testHideNameIsOneChoiceForEveryPersonAndATieHasNoBeltLine() {
        launchLab()
        openHomeResult("Casey")
        openSheet()
        app.buttons["Hide name"].tap()
        let card = element("competition.recap.card")
        XCTAssertEqual(
            card.label,
            "They won. Aug 13 to 19, 2026. You 2,692 points. Them 2,800 points. Lost by 108 points, won 1 day, lost 6. Best day: Sunday, 512 points. They took the belt."
        )
        XCTAssertTrue(app.buttons["Hide name"].isSelected)
        waitForEnabledShare()
        closeSheet()

        // Morgan's archived tie, from History, inherits the choice.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
        openHistory()
        openWeek(Self.morganWeek, title: "Morgan")
        openSheet()
        XCTAssertTrue(app.buttons["Hide name"].isSelected)
        XCTAssertEqual(
            card.label,
            "All square. Aug 13 to 19, 2026. You 3,000 points. Them 3,000 points."
        )
        app.buttons["Show Morgan"].tap()
        XCTAssertEqual(
            card.label,
            "All square. Aug 13 to 19, 2026. You 3,000 points. Morgan 3,000 points."
        )
        XCTAssertFalse(card.label.contains("belt"))
        waitForEnabledShare()
        closeSheet()

        // Back on Casey, the choice Morgan's sheet made holds.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
        openHomeResult("Casey")
        openSheet()
        XCTAssertEqual(card.label, Self.caseyShown)
        closeSheet()
    }

    func testFormerCompetitorIgnoresAndKeepsTheStoredChoice() {
        launchLab()
        openHomeResult("Casey")
        openSheet()
        app.buttons["Hide name"].tap()
        closeSheet()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))

        openHomeResult("Former competitor")
        openSheet()
        let card = element("competition.recap.card")
        XCTAssertEqual(
            card.label,
            "Match won. Aug 13 to 19, 2026. You 3,520 points. Them 3,410 points. Won by 110 points."
        )
        XCTAssertFalse(element("competition.recap.name").exists)
        XCTAssertFalse(app.buttons["Hide name"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show '")).firstMatch.exists)
        waitForEnabledShare()
        closeSheet()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))

        openHomeResult("Casey")
        openSheet()
        XCTAssertTrue(app.buttons["Hide name"].isSelected)
        XCTAssertTrue(card.label.hasPrefix("They won."), card.label)
        app.buttons["Show Casey"].tap()
        closeSheet()
    }

    func testArchivedLossFromThePersonPageCarriesTheirBeltLine() {
        launchLab()
        openHistory()
        let record = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "competition.record.", "Jordan")
        ).firstMatch
        scrollToElement(record)
        record.tap()
        XCTAssertTrue(app.navigationBars["Jordan"].waitForExistence(timeout: 3))
        openWeek(Self.jordanPastWeek, title: "Jordan")
        XCTAssertEqual(element("competition.result.belt").label, "Jordan took the belt")

        openSheet(showing: "Jordan")
        XCTAssertEqual(
            element("competition.recap.card").label,
            "Jordan won. Aug 1 to 7, 2026. You 3,050 points. Jordan 3,210 points. Lost by 160 points. Jordan took the belt."
        )
        waitForEnabledShare()
        closeSheet()

        // Back walks the same stack: result, person page, History.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Jordan"].waitForExistence(timeout: 3))
        XCTAssertTrue(element("competition.person.belt").exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 3))
    }

    func testWinAtTwoDecimalsAgainstTheLongestNameTakesTheBelt() {
        launchLab()
        openHistory()
        openWeek(Self.longNameWeek, title: Self.longName)
        XCTAssertEqual(element("competition.result.belt").label, "You took the belt")
        let share = app.buttons["competition.result.share"]
        scrollToElement(share)
        XCTAssertLessThanOrEqual(element("competition.history.preserved").frame.maxY, share.frame.minY)

        openSheet(showing: Self.longName)
        let card = element("competition.recap.card")
        let shown = "Match won. Aug 6 to 12, 2026. You 2,104.30 points. \(Self.longName) 2,104.00 points. Won by 0.30 points, won 3 days, lost 4. Photo finish: decided by 0.30 points. Comeback: down 90 points after Saturday. Took the belt."
        XCTAssertEqual(card.label, shown)
        // The segment may truncate on screen; VoiceOver reads it in full.
        XCTAssertTrue(app.buttons["Show \(Self.longName)"].isHittable)
        waitForEnabledShare()
        attachScreenshot("qa-sheet-long-name")

        app.buttons["Hide name"].tap()
        XCTAssertEqual(
            card.label,
            shown.replacingOccurrences(of: "\(Self.longName) 2,104.00", with: "Them 2,104.00")
        )
        XCTAssertFalse(card.label.contains("Maximiliana"))
        app.buttons["Show \(Self.longName)"].tap()
        closeSheet()
    }

    func testShareResultIsOnlyOnFinishedRemoteMatches() {
        launchLab()
        let live = sharingCard(state: "active", name: "Jordan")
        XCTAssertTrue(live.waitForExistence(timeout: 5))
        live.tap()
        XCTAssertTrue(app.navigationBars["Jordan"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["competition.result.share"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))

        let pending = sharingCard(state: "pending", name: "Sam")
        scrollToElement(pending)
        pending.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["competition.result.share"].exists)

        // The simulated (local) result never offers it.
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "--local-competition-test-lab",
            "--local-competition-fixture", "loss",
            "--local-competition-direction", "outgoing",
            "--local-competition-seed", "424242",
            "--local-competition-difficulty", "balanced",
            "--local-competition-run-id", "ui-\(UUID().uuidString.lowercased())",
            "-healthcomp.colorHintSeen", "YES",
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "competition.sharing.pending.")
        ).firstMatch.tap()
        app.buttons["Start with Alex"].tap()
        for _ in 0..<9 {
            let next = app.buttons["competition.testLab.nextCheckpoint"]
            XCTAssertTrue(next.waitForExistence(timeout: 5))
            wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: next)], timeout: 8)
            next.tap()
        }
        XCTAssertTrue(app.staticTexts["Alex won"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["competition.rematch.create"].exists)
        XCTAssertFalse(app.buttons["competition.result.share"].exists)
    }

    func testShareOpensTheSystemSheetWithSaveImage() {
        launchLab()
        openHomeResult("Casey")
        openSheet()
        let share = waitForEnabledShare()
        share.tap()

        // The system share sheet lists Save Image for the PNG.
        let saveImage = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Save Image'")).firstMatch
        XCTAssertTrue(saveImage.waitForExistence(timeout: 10))
        attachScreenshot("qa-system-share-sheet")
        saveImage.tap()

        // Saving asks for add-only Photos access (NSPhotoLibraryAddUsageDescription); without
        // the key the app would crash here.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 5) {
            attachScreenshot("qa-photos-add-prompt", springboard: true)
            XCTAssertTrue(
                alert.staticTexts["HealthComp saves your match result image to Photos when you choose Save Image."].exists
            )
            let allow = alert.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow'")).firstMatch
            (allow.exists ? allow : alert.buttons.element(boundBy: 1)).tap()
        }
        // Saving closes only the system sheet: Share Result stays open, ready to share again.
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(saveImage.waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("competition.recap.card").exists)
        XCTAssertTrue(waitForEnabledShare().isHittable)
        XCTAssertFalse(element("competition.recap.error").exists)
    }

    func testFarTimeZoneKeepsTheMatchWeek() {
        launchLab(environment: ["TZ": "Pacific/Kiritimati"])
        openHomeResult("Casey")
        openSheet()
        XCTAssertEqual(element("competition.recap.card").label, Self.caseyShown)
        closeSheet()
        launchLab(environment: ["TZ": "Pacific/Pago_Pago"])
        openHomeResult("Casey")
        openSheet()
        XCTAssertEqual(element("competition.recap.card").label, Self.caseyShown)
        closeSheet()
    }

    func testDarkAX5SheetUsesASwitchAndScrollsToShare() throws {
        launchLab(Self.darkAX5)
        openHomeResult("Casey")
        let share = app.buttons["competition.result.share"]
        scrollToElement(share)
        // At AX sizes Rematch moves into the scroll, after Share Result.
        let rematch = app.buttons["competition.rematch.create"]
        scrollToElement(rematch)
        XCTAssertLessThanOrEqual(share.frame.maxY, rematch.frame.minY)
        scrollToElement(share)
        share.tap()

        let card = element("competition.recap.card")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let toggle = app.switches["competition.recap.name"]
        XCTAssertTrue(toggle.exists)
        XCTAssertFalse(app.buttons["Hide name"].exists)
        if (toggle.value as? String) == "1" { tapSwitch(toggle) }
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertEqual(card.label, Self.caseyShown)
        tapSwitch(toggle)
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(card.label.hasPrefix("They won."), card.label)
        tapSwitch(toggle)
        XCTAssertEqual(card.label, Self.caseyShown)

        let imageShare = waitForEnabledShare()
        scrollToElement(imageShare, in: sheetScroll)
        XCTAssertTrue(imageShare.isHittable)
        XCTAssertLessThanOrEqual(imageShare.frame.maxY, app.frame.maxY - 34)
        try app.performAccessibilityAudit(
            for: XCUIAccessibilityAuditType.textClipped
                .union(.hitRegion)
                .union(.sufficientElementDescription)
        )
        let close = app.buttons["Close"]
        scrollToElement(close, in: sheetScroll)
        close.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 3))
    }

    // MARK: Screenshot matrix (not in CI)

    func testScreenshotMatrix() {
        let configurations: [(appearance: String, size: String, arguments: [String])] = [
            ("light", "default", []),
            ("dark", "default", ["-AppleInterfaceStyle", "Dark"]),
            ("light", "ax5", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]),
            ("dark", "ax5", Self.darkAX5),
        ]
        for config in configurations {
            let suffix = "\(config.appearance)-\(config.size)"
            launchLab(config.arguments + ["-UIAccessibilityReduceMotionEnabled", "YES"])
            openHomeResult("Casey")
            let share = app.buttons["competition.result.share"]
            scrollToElement(share)
            if config.size == "default" { app.scrollViews.firstMatch.swipeUp() }
            attachScreenshot("result-\(suffix)")
            openSheet(showing: "Casey")
            waitForEnabledShare()
            attachScreenshot("sheet-\(suffix)")
            if config.size == "ax5" {
                scrollToElement(app.buttons["competition.recap.share"], in: sheetScroll)
                attachScreenshot("sheet-bottom-\(suffix)")
            }
            closeSheet()
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))

            openHistory()
            openWeek(Self.longNameWeek, title: Self.longName)
            let longShare = app.buttons["competition.result.share"]
            scrollToElement(longShare)
            if config.size == "default" { app.scrollViews.firstMatch.swipeUp() }
            attachScreenshot("result-win-\(suffix)")
            openSheet(showing: Self.longName)
            waitForEnabledShare()
            attachScreenshot("sheet-win-\(suffix)")
            closeSheet()
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 3))
            openWeek(Self.morganWeek, title: "Morgan")
            openSheet(showing: "Morgan")
            waitForEnabledShare()
            attachScreenshot("sheet-tie-\(suffix)")
            closeSheet()
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 3))
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
            openHomeResult("Former competitor")
            openSheet()
            waitForEnabledShare()
            attachScreenshot("sheet-former-\(suffix)")
            closeSheet()
        }
    }

    // MARK: Helpers

    private func launchLab(_ arguments: [String] = [], environment: [String: String] = [:]) {
        if app.state != .notRunning { app.terminate() }
        app = XCUIApplication()
        XCUIDevice.shared.appearance = arguments.contains("Dark") ? .dark : .light
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", "sharing",
            "-healthcomp.colorHintSeen", "YES",
        ] + arguments
        app.launchEnvironment = environment
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
    }

    private func openHomeResult(_ name: String) {
        let card = sharingCard(state: "completed", name: name)
        scrollToElement(card)
        card.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 3))
    }

    private func openHistory() {
        let history = app.buttons["competition.history.open"]
        scrollToElement(history)
        history.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 3))
    }

    private func openWeek(_ identifier: String, title: String) {
        let week = element(identifier)
        scrollToElement(week)
        week.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3))
    }

    /// Opens Share Result and, for a named person, resets the remembered choice to Show.
    private func openSheet(showing name: String? = nil) {
        let share = app.buttons["competition.result.share"]
        scrollToElement(share)
        share.tap()
        XCTAssertTrue(element("competition.recap.card").waitForExistence(timeout: 5))
        if let name {
            let toggle = app.switches["competition.recap.name"]
            if toggle.exists {
                if (toggle.value as? String) == "1" { tapSwitch(toggle) }
            } else {
                app.buttons["Show \(name)"].tap()
            }
        }
    }

    private func closeSheet() {
        let close = app.buttons["Close"]
        scrollToElement(close, in: sheetScroll)
        close.tap()
        XCTAssertTrue(element("competition.recap.card").waitForNonExistence(timeout: 3))
    }

    @discardableResult
    private func waitForEnabledShare() -> XCUIElement {
        let share = app.buttons["competition.recap.share"]
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: share
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        return share
    }

    /// A Toggle's tappable area is its trailing switch.
    private func tapSwitch(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
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

    private func sharingCard(state: String, name: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "competition.sharing.\(state).",
                name
            )
        ).firstMatch
    }

    private func attachScreenshot(_ name: String, springboard: Bool = false) {
        let shot = springboard ? XCUIScreen.main.screenshot() : app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The Share Result drawer's own scroll view, not the result behind it.
    private var sheetScroll: XCUIElement {
        app.scrollViews.containing(NSPredicate(format: "identifier == %@", "competition.recap.card")).firstMatch
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
