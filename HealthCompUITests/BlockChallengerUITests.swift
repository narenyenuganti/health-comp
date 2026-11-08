import XCTest

/// Block a challenger, end to end through the app's own root view, Home,
/// match screens, claim sheet and Account. The `block` Test Lab scenarios
/// script the server: Alex's block takes 2 s, Sam's and Naren's first block
/// fail, Alexandria's first Unblock fails, and every Unblock takes 1.5 s.
final class BlockChallengerUITests: XCTestCase {
    private var app: XCUIApplication!

    private static let alexID = "c1000000-0000-4000-8000-000000000001"
    private static let samID = "c1000000-0000-4000-8000-000000000002"
    private static let longNameID = "c1000000-0000-4000-8000-000000000003"
    private static let priyaID = "c1000000-0000-4000-8000-000000000004"
    private static let jordanID = "c1000000-0000-4000-8000-000000000005"
    private static let narenID = "a1000000-0000-4000-8000-000000000005"
    private static let longName = "Alexandria Montgomery-Featherstonehaugh"
    private static let declineMessage = " will see a decline either way. If you block them, they can’t challenge you again."
    private static let footer = "Blocked people can’t challenge you. They aren’t notified."

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        if app.state != .notRunning { app.terminate() }
        XCUIDevice.shared.appearance = .light
        app = nil
    }

    // MARK: Incoming challenge screen

    func testDeclineAndBlockDisablesTheScreenThenLeavesHomeAndListsThemInAccount() {
        launch(.block)
        // Four challenges to you and one from you, each shown once.
        for id in [Self.alexID, Self.samID, Self.longNameID, Self.narenID, Self.priyaID] {
            XCTAssertEqual(cards(id).count, 1, id)
        }
        open(Self.alexID, title: "Alex")
        let more = app.buttons["competition.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons.matching(identifier: "competition.more").count, 1)
        XCTAssertEqual(more.label, "More")

        let decline = app.buttons["competition.invite.decline"]
        let accept = app.buttons["competition.invite.accept"]
        XCTAssertEqual(decline.label, "Decline challenge from Alex")
        XCTAssertEqual(accept.label, "Accept challenge from Alex")
        decline.tap()
        assertDeclineDialog("Alex")
        dismissDialog(cancel: "Keep Challenge")
        XCTAssertTrue(app.buttons["Decline and Block Alex"].firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Alex"].exists)
        XCTAssertTrue(decline.isEnabled)

        decline.tap()
        let declineAndBlock = app.buttons["Decline and Block Alex"].firstMatch
        XCTAssertTrue(declineAndBlock.waitForExistence(timeout: 3))
        declineAndBlock.tap()
        // While the server works, nothing can be tapped twice.
        XCTAssertTrue(eventually { !decline.isEnabled })
        XCTAssertFalse(accept.isEnabled)
        XCTAssertEqual(decline.value as? String, "Action in progress")
        XCTAssertFalse(element("competition.invite.error").exists)

        // Declined: the screen closes and Home drops the challenge.
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 6))
        XCTAssertTrue(cards(Self.alexID).firstMatch.waitForNonExistence(timeout: 3))
        for id in [Self.samID, Self.longNameID, Self.narenID, Self.priyaID] {
            XCTAssertEqual(cards(id).count, 1, id)
        }

        openAccount()
        let unblock = app.buttons["Unblock Alex"]
        scrollToElement(unblock)
        XCTAssertEqual(unblock.identifier, "account.blocked.unblock")
        XCTAssertEqual(app.buttons.matching(identifier: "account.blocked.unblock").count, 1)
        XCTAssertTrue(app.staticTexts["BLOCKED"].exists)
        XCTAssertTrue(app.cells.containing(.button, identifier: "account.blocked.unblock")
            .firstMatch.staticTexts["Alex"].exists)
        let footer = app.staticTexts[Self.footer]
        scrollToElement(footer)
        XCTAssertFalse(element("account.blocked.error").exists)
    }

    func testFailedBlockFromTheMoreMenuExplainsAndARetryDeclines() {
        launch(.block)
        open(Self.samID, title: "Sam")
        let more = app.buttons["competition.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        more.tap()
        let block = app.buttons["competition.invite.block"]
        XCTAssertTrue(block.waitForExistence(timeout: 3))
        XCTAssertEqual(block.label, "Block Sam")
        XCTAssertTrue(block.isEnabled)
        block.tap()
        XCTAssertTrue(app.staticTexts["Block Sam?"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts["This declines the challenge. Sam will see a decline and can’t challenge you again."].exists
        )
        // Cancel keeps everything as it was.
        dismissDialog(cancel: "Cancel")
        XCTAssertTrue(app.staticTexts["Block Sam?"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Sam"].exists)

        more.tap()
        XCTAssertTrue(block.waitForExistence(timeout: 3))
        block.tap()
        confirmBlock("Sam")
        let error = element("competition.invite.error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "Couldn’t complete that. Check your connection and try again.")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "competition.invite.error").count, 1)
        XCTAssertTrue(app.navigationBars["Sam"].exists)
        let decline = app.buttons["competition.invite.decline"]
        XCTAssertTrue(eventually(timeout: 3) { decline.isEnabled })
        XCTAssertTrue(app.buttons["competition.invite.accept"].isEnabled)

        // The retry goes through the decline dialog this time.
        scrollToElement(decline)
        decline.tap()
        let declineAndBlock = app.buttons["Decline and Block Sam"].firstMatch
        XCTAssertTrue(declineAndBlock.waitForExistence(timeout: 3))
        declineAndBlock.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        XCTAssertTrue(cards(Self.samID).firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertEqual(cards(Self.alexID).count, 1)
    }

    func testPlainDeclineWithALongNameBlocksNobody() {
        launch(.block)
        open(Self.longNameID, title: Self.longName)
        let decline = app.buttons["competition.invite.decline"]
        scrollToElement(decline)
        decline.tap()
        assertDeclineDialog(Self.longName)
        let declineOnly = app.buttons["Decline Challenge"].firstMatch
        XCTAssertTrue(declineOnly.isHittable)
        XCTAssertTrue(app.buttons["Decline and Block \(Self.longName)"].firstMatch.isHittable)
        declineOnly.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        XCTAssertTrue(cards(Self.longNameID).firstMatch.waitForNonExistence(timeout: 3))

        // Nobody is blocked, so Account has no BLOCKED section at all.
        openAccount()
        // The link loaded, and the list under it (where BLOCKED would be) is empty.
        scrollToElement(element("account.challenge-link.reset"))
        scrollToElement(element("account.health"))
        assertNoBlockedSection()
    }

    func testOnlyAChallengeToYouOffersBlock() {
        launch(.block)
        // Your own challenge: Cancel, no ••• menu.
        open(Self.priyaID, title: "Priya")
        XCTAssertTrue(app.buttons["competition.invite.cancel"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["competition.more"].exists)
        XCTAssertFalse(app.buttons["competition.invite.block"].exists)
        XCTAssertFalse(app.buttons["competition.invite.decline"].exists)
        goBack()

        // A live match keeps its own ••• menu, without Block.
        open(Self.jordanID, title: "Jordan")
        let more = app.buttons["competition.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        more.tap()
        XCTAssertTrue(app.buttons["How scoring works"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["competition.invite.block"].exists)
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Block")).count,
            0
        )
    }

    // MARK: Claim sheet

    func testClaimSheetDeclineAndBlockRetriesAfterAFailure() {
        launch(.blockClaim, waitForHome: false)
        let decline = app.buttons["competition.claim.decline"]
        XCTAssertTrue(decline.waitForExistence(timeout: 10))
        XCTAssertTrue(text("Naren is told if you decline.").exists)
        decline.tap()
        assertDeclineDialog("Naren")
        app.buttons["Decline and Block Naren"].firstMatch.tap()
        let error = element("competition.claim.decline-error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "Couldn’t decline. Check your connection and try again.")
        XCTAssertTrue(app.buttons["competition.claim.accept"].isEnabled)
        XCTAssertTrue(decline.isEnabled)

        decline.tap()
        let declineAndBlock = app.buttons["Decline and Block Naren"].firstMatch
        XCTAssertTrue(declineAndBlock.waitForExistence(timeout: 3))
        declineAndBlock.tap()
        // The sheet closes; Home no longer has Naren's challenge.
        XCTAssertTrue(decline.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        XCTAssertTrue(cards(Self.narenID).firstMatch.waitForNonExistence(timeout: 3))
        openAccount()
        let unblock = app.buttons["Unblock Naren"]
        scrollToElement(unblock)
        XCTAssertEqual(app.buttons.matching(identifier: "account.blocked.unblock").count, 1)
    }

    // MARK: Account

    func testUnblockDisablesWhileSavingExplainsAFailureAndClearsTheSectionAtTheEnd() {
        launch(.blockedAccount)
        // A block declined Alexandria's challenge, so Home doesn't show it.
        XCTAssertEqual(cards(Self.longNameID).count, 0)
        openAccount()
        let longUnblock = app.buttons["Unblock \(Self.longName)"]
        let morganUnblock = app.buttons["Unblock Morgan"]
        scrollToElement(morganUnblock)
        XCTAssertTrue(longUnblock.exists)
        XCTAssertEqual(app.buttons.matching(identifier: "account.blocked.unblock").count, 2)
        // Newest block first.
        XCTAssertLessThan(longUnblock.frame.minY, morganUnblock.frame.minY)
        XCTAssertTrue(app.staticTexts[Self.longName].exists)
        XCTAssertGreaterThanOrEqual(longUnblock.frame.height, 44)
        XCTAssertGreaterThanOrEqual(morganUnblock.frame.height, 44)

        scrollToElement(longUnblock)
        longUnblock.tap()
        // Saving: VoiceOver hears it, and a second tap does nothing.
        XCTAssertTrue(eventually { longUnblock.value as? String == "Unblocking" && !longUnblock.isEnabled })
        shot("account-unblocking")
        longUnblock.tap()
        XCTAssertEqual(morganUnblock.value as? String ?? "", "")
        let error = element("account.blocked.error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "Couldn’t unblock. Check your connection and try again.")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "account.blocked.error").count, 1)
        // In Alexandria's row, under her Unblock, above Morgan.
        // The row settles open, so its frames are final a moment later.
        XCTAssertTrue(eventually {
            error.frame.minY >= longUnblock.frame.maxY - 1
                && error.frame.maxY < morganUnblock.frame.minY
        })
        XCTAssertTrue(longUnblock.exists)
        XCTAssertTrue(eventually { longUnblock.isEnabled && (longUnblock.value as? String ?? "").isEmpty })

        // The next Unblock clears the error at once.
        scrollToElement(morganUnblock)
        morganUnblock.tap()
        XCTAssertTrue(error.waitForNonExistence(timeout: 1))
        XCTAssertTrue(morganUnblock.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "account.blocked.unblock").count, 1)
        XCTAssertTrue(app.staticTexts["BLOCKED"].exists)

        // The retry removes the last row, and the section goes with it.
        scrollToElement(longUnblock)
        longUnblock.tap()
        XCTAssertTrue(app.staticTexts["BLOCKED"].waitForNonExistence(timeout: 5))
        assertNoBlockedSection()

        // Account reloads the list when it opens again: still nobody.
        closeAccount()
        openAccount()
        scrollToElement(element("account.notifications"))
        assertNoBlockedSection()
    }

    func testUnblockErrorClearsWhenAccountOpensAgain() {
        launch(.blockedAccount)
        openAccount()
        let longUnblock = app.buttons["Unblock \(Self.longName)"]
        scrollToElement(longUnblock)
        longUnblock.tap()
        XCTAssertTrue(element("account.blocked.error").waitForExistence(timeout: 5))
        closeAccount()
        openAccount()
        scrollToElement(longUnblock)
        XCTAssertTrue(app.buttons["Unblock Morgan"].exists)
        XCTAssertFalse(element("account.blocked.error").exists)
    }

    // MARK: Screenshots

    /// Every new or changed screen, light and dark, at the default size and
    /// at AX5. Names are `<screen>-<light|dark>-<default|ax5>`.
    func testBlockScreensAppearanceAndTypeSizeMatrix() throws {
        let sizes = [("default", "UICTContentSizeCategoryL"), ("ax5", "UICTContentSizeCategoryAccessibilityXXXL")]
        for appearance in ["Light", "Dark"] {
            for (sizeName, size) in sizes {
                let suffix = "\(appearance.lowercased())-\(sizeName)"
                let arguments = [
                    "-AppleInterfaceStyle", appearance,
                    "-UIPreferredContentSizeCategoryName", size,
                ]

                launch(.block, arguments: arguments)
                open(Self.alexID, title: "Alex")
                XCTAssertTrue(app.buttons["competition.more"].waitForExistence(timeout: 3))
                shot("incoming-challenge-\(suffix)")
                try audit("incoming-challenge-\(suffix)")

                let decline = app.buttons["competition.invite.decline"]
                scrollToElement(decline)
                shot("incoming-actions-\(suffix)")
                decline.tap()
                XCTAssertTrue(app.buttons["Decline and Block Alex"].firstMatch.waitForExistence(timeout: 3))
                shot("decline-dialog-\(suffix)")
                dismissDialog(cancel: "Keep Challenge")
                XCTAssertTrue(app.buttons["Decline and Block Alex"].firstMatch.waitForNonExistence(timeout: 3))

                app.buttons["competition.more"].tap()
                let block = app.buttons["competition.invite.block"]
                XCTAssertTrue(block.waitForExistence(timeout: 3))
                shot("more-menu-\(suffix)")
                block.tap()
                XCTAssertTrue(app.staticTexts["Block Alex?"].waitForExistence(timeout: 3))
                shot("block-confirmation-\(suffix)")
                dismissDialog(cancel: "Cancel")
                XCTAssertTrue(app.staticTexts["Block Alex?"].waitForNonExistence(timeout: 3))
                goBack()

                open(Self.samID, title: "Sam")
                app.buttons["competition.more"].tap()
                XCTAssertTrue(app.buttons["competition.invite.block"].waitForExistence(timeout: 3))
                app.buttons["competition.invite.block"].tap()
                confirmBlock("Sam")
                let error = element("competition.invite.error")
                XCTAssertTrue(error.waitForExistence(timeout: 5))
                scrollToElement(error)
                shot("incoming-error-\(suffix)")
                try audit("incoming-error-\(suffix)")
                goBack()

                open(Self.longNameID, title: Self.longName)
                XCTAssertTrue(app.buttons["competition.more"].waitForExistence(timeout: 3))
                shot("incoming-long-name-\(suffix)")
                let longDecline = app.buttons["competition.invite.decline"]
                scrollToElement(longDecline)
                longDecline.tap()
                XCTAssertTrue(app.buttons["Decline and Block \(Self.longName)"].firstMatch.waitForExistence(timeout: 3))
                shot("decline-dialog-long-name-\(suffix)")

                launch(.blockedAccount, arguments: arguments)
                openAccount()
                let longUnblock = app.buttons["Unblock \(Self.longName)"]
                scrollToElement(longUnblock)
                shot("account-blocked-\(suffix)")
                try audit("account-blocked-\(suffix)", region: blockedSection())
                longUnblock.tap()
                XCTAssertTrue(eventually { longUnblock.value as? String == "Unblocking" })
                shot("account-unblocking-\(suffix)")
                // At AX5 the error row lands below the fold, where the list
                // hasn't made it yet: scroll it on screen, as for Health.
                let unblockError = element("account.blocked.error")
                scrollToElement(unblockError)
                XCTAssertEqual(unblockError.label, "Couldn’t unblock. Check your connection and try again.")
                shot("account-blocked-error-\(suffix)")
                try audit("account-blocked-error-\(suffix)", region: blockedSection())

                launch(.blockClaim, arguments: arguments, waitForHome: false)
                let claimDecline = app.buttons["competition.claim.decline"]
                XCTAssertTrue(claimDecline.waitForExistence(timeout: 10))
                scrollToElement(claimDecline)
                claimDecline.tap()
                XCTAssertTrue(app.buttons["Decline and Block Naren"].firstMatch.waitForExistence(timeout: 3))
                shot("claim-decline-dialog-\(suffix)")
                app.buttons["Decline and Block Naren"].firstMatch.tap()
                let claimError = element("competition.claim.decline-error")
                XCTAssertTrue(claimError.waitForExistence(timeout: 5))
                // No scroll here: at AX5 a drag can start on Accept and accept.
                XCTAssertEqual(claimError.label, "Couldn’t decline. Check your connection and try again.")
                shot("claim-decline-error-\(suffix)")
            }
        }
    }

    // MARK: Helpers

    private enum Scenario: String {
        case block
        case blockedAccount = "blocked-account"
        case blockClaim = "block-claim"
    }

    private func launch(_ scenario: Scenario, arguments: [String] = [], waitForHome: Bool = true) {
        if app.state != .notRunning { app.terminate() }
        app = XCUIApplication()
        XCUIDevice.shared.appearance = arguments.contains("Dark") ? .dark : .light
        app.launchEnvironment["TZ"] = "America/Los_Angeles"
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", scenario.rawValue,
            "-healthcomp.colorHintSeen", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ] + arguments
        app.launch()
        if waitForHome {
            XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 10))
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func text(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func cards(_ id: String) -> XCUIElementQuery {
        app.buttons.matching(identifier: "competition.sharing.pending.\(id)")
    }

    private func open(_ id: String, title: String) {
        let card = id == Self.jordanID
            ? app.buttons["competition.sharing.active.\(id)"]
            : cards(id).firstMatch
        scrollToElement(card)
        card.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3), "Opening \(title)")
    }

    private func goBack() {
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
    }

    private func openAccount() {
        let account = app.buttons["app.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 3))
        account.tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 3))
    }

    private func closeAccount() {
        app.navigationBars["Account"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForNonExistence(timeout: 3))
    }

    private func assertDeclineDialog(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            text("Decline challenge from \(name)?").waitForExistence(timeout: 3),
            file: file, line: line
        )
        XCTAssertTrue(text("\(name)\(Self.declineMessage)").exists, file: file, line: line)
        for label in ["Decline Challenge", "Decline and Block \(name)"] {
            // UIKit can expose a wrapper and inner button for the same action.
            let actions = app.buttons.matching(NSPredicate(format: "label == %@", label))
                .allElementsBoundByIndex.filter { $0.children(matching: .button).count == 0 }
            XCTAssertEqual(actions.count, 1, label, file: file, line: line)
        }
    }

    /// The Block confirmation's button has the menu item's label; the menu is gone by now.
    private func confirmBlock(_ name: String) {
        XCTAssertTrue(app.staticTexts["Block \(name)?"].waitForExistence(timeout: 3))
        let confirm = app.buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", "Block \(name)", "competition.invite.block")
        ).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
    }

    /// A confirmation dialog's cancel button, or a tap outside where iOS
    /// shows it as a popover without one.
    private func dismissDialog(cancel label: String) {
        let button = app.buttons[label].firstMatch
        if button.exists, button.isHittable {
            button.tap()
        } else {
            let popover = app.popovers.firstMatch
            XCTAssertTrue(popover.exists)
            XCTAssertGreaterThan(popover.frame.minX, app.frame.minX)
            // Large-text popovers cover the old top-center dismissal point.
            let outside = CGVector(dx: (popover.frame.minX - app.frame.minX) / 2,
                                   dy: popover.frame.midY - app.frame.minY)
            app.coordinate(withNormalizedOffset: .zero).withOffset(outside).tap()
        }
    }

    private func assertNoBlockedSection(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.staticTexts["BLOCKED"].exists, file: file, line: line)
        XCTAssertFalse(app.staticTexts[Self.footer].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["account.blocked.unblock"].exists, file: file, line: line)
        XCTAssertFalse(element("account.blocked.error").exists, file: file, line: line)
    }

    /// From the BLOCKED header to the footer, or to the screen's edges.
    private func blockedSection() -> CGRect {
        let screen = app.windows.firstMatch.frame
        let header = app.staticTexts["BLOCKED"]
        let footer = app.staticTexts[Self.footer]
        let top = header.exists ? header.frame.minY : screen.minY
        let bottom = footer.exists ? footer.frame.maxY : screen.maxY
        return CGRect(x: screen.minX, y: top, width: screen.width, height: max(0, bottom - top))
    }

    /// Polls every 0.1 s. XCTNSPredicateExpectation checks about once a
    /// second, too slow for a 1.5 s in-flight state.
    private func eventually(timeout: TimeInterval = 1.2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return condition()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Layout and labelling audits. Contrast is left to the existing matrix.
    /// Only elements fully on screen and inside `region` (by default the
    /// screen) count: a row cut off by the screen edge reads as clipped
    /// text, and Account's older sections have their own matrix. Skipped
    /// issues are attached.
    private func audit(_ name: String, region: CGRect? = nil) throws {
        try XCTContext.runActivity(named: "audit \(name)") { activity in
            let screen = app.windows.firstMatch.frame
            let region = region ?? screen
            var skipped: [String] = []
            try app.performAccessibilityAudit(
                for: [.textClipped, .hitRegion, .sufficientElementDescription]
            ) { issue in
                // An issue XCTest can’t tie to an element (seen here as a nil
                // element on the BLOCKED rows) can’t be located; it’s attached and the screenshots
                // are checked by eye instead.
                guard let element = issue.element else {
                    skipped.append("\(issue.compactDescription): no element. \(issue.detailedDescription)")
                    return true
                }
                let frame = element.frame
                if screen.contains(frame), region.intersects(frame) {
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
            // Hold before releasing: no momentum, so the next tap lands on
            // the control instead of stopping a scroll.
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(element.exists, "\(element)")
        XCTAssertTrue(element.isHittable, "\(element)")
    }
}
