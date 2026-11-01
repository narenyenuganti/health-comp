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

    func testCreatingInvitationRequiresConfirmingAnExistingAccount() {
        launch(.sharing)
        defer { app.terminate() }
        openChallengeDrawer()
        let create = app.buttons["competition.create.button"]
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        XCTAssertFalse(create.isEnabled)
        chooseRecipient()
        XCTAssertEqual(app.staticTexts["competition.create.recipient-name"].label, "Challenge Sam")
        scrollToElement(create)
        XCTAssertTrue(create.isEnabled)
        create.tap()
        XCTAssertTrue(app.buttons["competition.create.share"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Waiting for someone to accept. The link works once."].exists)
        // Once sent, the sheet can't switch to someone else.
        XCTAssertTrue(app.staticTexts["Challenge sent"].exists)
        XCTAssertFalse(app.buttons["competition.create.find-recipient"].isEnabled)
        XCTAssertFalse(recipientCodeField.isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "recipient-bound-invitation-confirmation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testChallengeSheetReopensEmpty() {
        launch(.sharing)
        defer { app.terminate() }
        openChallengeDrawer()
        chooseRecipient()
        let create = app.buttons["competition.create.button"]
        scrollToElement(create)
        create.tap()
        XCTAssertTrue(app.buttons["competition.create.share"].waitForExistence(timeout: 3))
        closeChallengeDrawer()

        openChallengeDrawer()
        XCTAssertFalse(app.staticTexts["competition.create.recipient-name"].exists)
        XCTAssertTrue(app.buttons["competition.create.find-recipient"].waitForExistence(timeout: 3))
        let field = recipientCodeField
        XCTAssertTrue(field.isEnabled)
        XCTAssertFalse((field.value as? String ?? "").contains("a1000000"))
        let reopenedCreate = app.buttons["competition.create.button"]
        scrollToElement(reopenedCreate)
        XCTAssertFalse(reopenedCreate.isEnabled)
    }

    func testAccountCodeErrorsAndReturnKey() {
        launch(.sharing)
        defer { app.terminate() }
        let error = app.staticTexts["competition.create.recipient-error"]
        // Each code goes into a freshly opened sheet, which starts empty.
        // Return runs Find; Find is never tapped.
        func submit(_ code: String) {
            openChallengeDrawer()
            let field = recipientCodeField
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            field.tap()
            field.typeText(code + "\n")
        }

        submit("abc")
        XCTAssertTrue(error.waitForExistence(timeout: 3))
        XCTAssertEqual(
            error.label,
            "That isn’t a full challenge link. Ask them to share it again."
        )
        closeChallengeDrawer()

        submit("a1000000-0000-4000-8000-000000000099")
        XCTAssertTrue(error.waitForExistence(timeout: 3))
        XCTAssertEqual(error.label, "That’s your own link. Ask them for theirs.")
        closeChallengeDrawer()

        // A challenge link finds the person too.
        submit("healthcomp://challenge/SamSamSamSamSamSamSam1")
        let linked = app.staticTexts["competition.create.recipient-name"]
        XCTAssertTrue(linked.waitForExistence(timeout: 3))
        XCTAssertEqual(linked.label, "Challenge Sam")
        closeChallengeDrawer()

        submit("a1000000-0000-4000-8000-000000000005")
        let recipient = app.staticTexts["competition.create.recipient-name"]
        XCTAssertTrue(recipient.waitForExistence(timeout: 3))
        XCTAssertEqual(recipient.label, "Challenge Sam")
        XCTAssertFalse(error.exists)
    }

    // The field wraps a long code, so XCTest may expose it as a text view.
    private var recipientCodeField: XCUIElement {
        let field = app.textFields["competition.create.recipient-code"]
        return field.exists ? field : app.textViews["competition.create.recipient-code"]
    }

    func testCopyCustomSchemeInvitationIncludesTheCompleteLink() throws {
        launch(.sharingCustomScheme)
        defer { app.terminate() }
        openChallengeDrawer()
        chooseRecipient()
        let create = app.buttons["competition.create.button"]
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        create.tap()
        // The drawer covers the lab's Paste control.
        assertSharedInvitationCopiesCompleteLink(
            app.buttons["competition.create.share"],
            beforePaste: closeChallengeDrawer
        )
    }

    func testCopyCustomSchemeRematchIncludesTheCompleteLink() throws {
        launch(.sharingCustomScheme)
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
        app.scrollViews.firstMatch.swipeUp()
        let completed = sharingCard(state: "completed", name: "Former competitor")
        scrollToElement(completed)
        completed.tap()
        XCTAssertTrue(app.navigationBars["Former competitor"].waitForExistence(timeout: 3))
        app.scrollViews.firstMatch.swipeUp()
        let create = app.buttons["competition.rematch.create"]
        scrollToElement(create)
        create.tap()
        assertSharedInvitationCopiesCompleteLink(
            app.buttons["competition.rematch.share"]
        )
    }

    private func assertSharedInvitationCopiesCompleteLink(
        _ share: XCUIElement,
        beforePaste: () -> Void = {}
    ) {
        XCTAssertTrue(share.waitForExistence(timeout: 3))
        share.tap()

        let copy = app.cells.matching(
            NSPredicate(format: "label == %@", "Copy")
        ).firstMatch
        guard copy.waitForExistence(timeout: 10) else {
            XCTFail(
                """
                The system share sheet must offer Copy.
                Synthetic Test Lab accessibility hierarchy at failure:
                \(app.debugDescription)
                """
            )
            return
        }
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        beforePaste()
        let paste = app.buttons.matching(
            NSPredicate(format: "label == %@", "Paste")
        ).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        paste.tap()
        let status = app.staticTexts.matching(
            NSPredicate(format: "label IN %@", [
                "Not checked", "Complete invitation link", "Message only",
                "Missing invitation link"
            ])
        ).firstMatch
        let pasted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", "Not checked"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 5), .completed)
        XCTAssertEqual(
            status.label,
            "Complete invitation link",
            "System Copy must include the complete invitation link in plain text, not only its message."
        )
    }

    func testCreateRemoteUpdatesHistoryAnonymizationRematchAndArchive() throws {
        launch(.sharing)

        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["REMOTE UI TEST LAB"].exists)
        XCTAssertFalse(app.staticTexts["FIXTURE DATA"].exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "simulated")
        ).firstMatch.exists)

        openChallengeDrawer()
        let timeZone = app.staticTexts["competition.create.time-zone"]
        XCTAssertTrue(timeZone.waitForExistence(timeout: 3))
        XCTAssertEqual(
            timeZone.label,
            "Days run midnight to midnight, Pacific Time."
        )

        chooseRecipient()
        let create = app.buttons["competition.create.button"]
        scrollToElement(create)
        create.tap()
        XCTAssertTrue(
            app.buttons["competition.create.share"]
                .waitForExistence(timeout: 3)
        )
        let creationToken = rawFixtureToken(byte: 0x51)
        try assertNoPrivateFixtureContentIsSpoken(rawTokens: [creationToken])
        closeChallengeDrawer()

        let scheduled = sharingCard(state: "scheduled", name: "Priya")
        scrollToElement(scheduled)
        scheduled.tap()
        XCTAssertTrue(
            app.navigationBars["Priya"]
                .waitForExistence(timeout: 3)
        )
        let localRange = app.staticTexts["competition.schedule.dates"].label
        XCTAssertFalse(localRange.contains(":"))
        XCTAssertFalse(localRange.contains("America/Los_Angeles"))
        XCTAssertTrue(localRange.hasPrefix("Day 1 is "), localRange)
        navigateBackToSharing()

        let active = sharingCard(state: "active", name: "Jordan")
        scrollToElement(active)
        active.tap()
        XCTAssertTrue(
            app.navigationBars["Jordan"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(waitForStatus("Day 3 of 7"))
        let updated = app.staticTexts["competition.updated"].label
        XCTAssertTrue(updated.hasPrefix("You: updated"), updated)
        XCTAssertTrue(updated.contains("Jordan: updated"), updated)
        XCTAssertTrue(
            app.otherElements["competition.scoreHeader.naren"].label
                .contains("You")
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
        XCTAssertTrue(app.navigationBars["Former competitor"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["You beat Former competitor"].exists)
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
        XCTAssertEqual(rematch.label, "Rematch Former competitor")
        rematch.tap()
        let rematchSent = app.descendants(matching: .any)["competition.rematch.sent"]
        XCTAssertTrue(rematchSent.waitForExistence(timeout: 3))
        XCTAssertTrue(rematchSent.label.contains("Rematch sent"))
        XCTAssertTrue(
            app.buttons["competition.rematch.share"]
                .waitForExistence(timeout: 3)
        )
        let rematchToken = rawFixtureToken(byte: 0x52)
        try assertNoPrivateFixtureContentIsSpoken(
            rawTokens: [creationToken, rematchToken]
        )

        tapMoreMenuItem("Archive")
        XCTAssertTrue(
            app.descendants(matching: .any)["competition.history.preserved"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(moreMenu.exists)
        XCTAssertFalse(app.buttons["Delete Local Data"].exists)
    }

    func testHomeGroupsLiveMatchesByEndTimeAndShowsMatchIssues() {
        launch(.sharing)
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))

        let live = app.descendants(matching: .any)["competition.home.live"]
        XCTAssertTrue(live.waitForExistence(timeout: 3))
        XCTAssertTrue(
            live.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@", "LIVE · 2")
            ).firstMatch.exists
        )
        let jordan = sharingCard(state: "active", name: "Jordan")
        let riley = sharingCard(state: "active", name: "Riley")
        XCTAssertTrue(jordan.exists)
        XCTAssertTrue(riley.exists)
        // Jordan's week ends a day before Riley's.
        XCTAssertLessThan(jordan.frame.minY, riley.frame.minY)

        let rileyID = "a1000000-0000-4000-8000-000000000006"
        let issue = app.descendants(matching: .any)["competition.issue.\(rileyID)"]
        XCTAssertTrue(issue.exists)
        XCTAssertEqual(issue.label, "Couldn’t update scores")
        XCTAssertTrue(app.buttons["competition.issue.retry.\(rileyID)"].exists)
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Some matches")
            ).firstMatch.exists
        )

        let upNext = app.descendants(matching: .any)["competition.home.upNext"]
        let priya = upNext.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "competition.sharing.scheduled.", "Priya"
            )
        ).firstMatch
        scrollToElement(priya)
        XCTAssertTrue(priya.exists)

        let results = app.descendants(matching: .any)["competition.home.results"]
        let former = results.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "competition.sharing.completed.", "Former competitor"
            )
        ).firstMatch
        scrollToElement(former)
        XCTAssertTrue(former.label.contains("Moves to History"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "remote-home-groups"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testClosedChallengeRowChallengesAgainAndDismisses() {
        launch(.sharing)
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))

        let taylorID = "a1000000-0000-4000-8000-000000000007"
        let row = app.descendants(matching: .any)["competition.sharing.expired.\(taylorID)"]
        let again = app.buttons["competition.closedRow.again.\(taylorID)"]
        scrollToElement(again)
        XCTAssertTrue(row.exists)
        XCTAssertTrue(
            row.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "Taylor didn’t accept")
            ).firstMatch.exists
        )
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "remote-home-closed-row"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        again.tap()
        let recipient = app.staticTexts["competition.create.recipient-name"]
        XCTAssertTrue(recipient.waitForExistence(timeout: 3))
        XCTAssertEqual(recipient.label, "Challenge Taylor")
        closeChallengeDrawer()

        let dismiss = app.buttons["competition.closedRow.dismiss.\(taylorID)"]
        scrollToElement(dismiss)
        dismiss.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 3))
    }

    func testRemoteDayDrawerShowsRingsThatAddUpToTheDayScore() {
        launch(.sharing)
        let active = sharingCard(state: "active", name: "Jordan")
        scrollToElement(active)
        active.tap()
        XCTAssertTrue(
            app.navigationBars["Jordan"]
                .waitForExistence(timeout: 3)
        )
        showWeek()
        let day = app.buttons["competition.day.1"]
        scrollToElement(day)
        day.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 3))

        let summary = app.otherElements["competition.day.1"]
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        XCTAssertTrue(summary.label.contains("You, 500 points"))
        XCTAssertTrue(summary.label.contains("Jordan, 480 points"))
        let rings = app.otherElements["competition.ownerRings"]
        XCTAssertTrue(rings.exists)
        XCTAssertTrue(rings.label.contains("Move, 1,000 of 500 kilocalories, 200 points"), rings.label)
        XCTAssertTrue(rings.label.contains("Stand, 12 of 12 hours, 100 points"), rings.label)
        XCTAssertTrue(
            app.staticTexts[
                "1 point per 1% of each ring, up to 200% per ring. Your ring values stay on this iPhone."
            ].exists
        )
    }

    func testColdWarmAndSignedOutClaimConfirmationFlows() {
        for scenario in [Scenario.coldClaim, .warmClaim] {
            launch(scenario)
            XCTAssertTrue(
                app.navigationBars["Challenge"]
                    .waitForExistence(timeout: 8)
            )
            XCTAssertEqual(
                app.staticTexts["competition.claim.sender"].label,
                "Naren challenged you"
            )
            XCTAssertTrue(
                element("competition.claim.start").label.contains("Pacific Time")
            )
            XCTAssertTrue(
                app.staticTexts["Naren sees your daily points and rounded ring percentages"].exists
            )
            XCTAssertTrue(app.staticTexts["Most points after 7 days wins"].exists)
            XCTAssertTrue(app.buttons["competition.claim.accept"].exists)
            XCTAssertTrue(app.buttons["competition.claim.not-now"].exists)
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
        let confirm = app.buttons["Decline Challenge"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(
            app.staticTexts["Invitation Declined"]
                .waitForExistence(timeout: 3)
        )

        // Not Now only closes the sheet.
        launch(.coldClaim)
        let notNow = app.buttons["competition.claim.not-now"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 8))
        notNow.tap()
        XCTAssertTrue(
            app.staticTexts["Challenge Kept"].waitForExistence(timeout: 3)
        )
    }

    func testAccountShowsChallengeLinkAndCode() {
        launch(.account)
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 8))
        let url = element("account.challenge-link.url")
        XCTAssertTrue(url.waitForExistence(timeout: 3))
        XCTAssertTrue(url.label.contains("Your challenge link"))
        XCTAssertTrue(element("account.challenge-link.share").exists)
        XCTAssertFalse(
            app.debugDescription.range(
                of: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
                options: [.regularExpression, .caseInsensitive]
            ) != nil,
            "Account shows no 36-character account code"
        )
        let showCode = element("account.challenge-link.show-code")
        scrollToElement(showCode)
        showCode.tap()
        XCTAssertTrue(element("account.challenge-link.qr").waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Your Challenge Code"].exists)
    }

    func testRemoteOutgoingChallengeOffersCancel() {
        launch(.sharing)
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        let pending = sharingCard(state: "pending", name: "Sam")
        scrollToElement(pending)
        pending.tap()
        XCTAssertTrue(app.buttons["competition.invite.share"].waitForExistence(timeout: 3))
        let cancel = app.buttons["competition.invite.cancel"]
        XCTAssertTrue(cancel.exists)
        cancel.tap()
        // The dialog's destructive button, not the screen's.
        let confirm = app.buttons.matching(
            NSPredicate(
                format: "label == %@ AND identifier != %@",
                "Cancel Challenge",
                "competition.invite.cancel"
            )
        ).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Sam won’t be able to accept it."].exists)
        confirm.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
    }

    func testChallengeLinkSheetSendsFromSomeonesLink() {
        launch(.challengeLink)
        defer { app.terminate() }
        let name = element("competition.link.name")
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        XCTAssertEqual(name.label, "Challenge Maya?")
        XCTAssertTrue(app.staticTexts["Maya gets it in HealthComp. Nothing to send back."].exists)
        app.buttons["competition.link.send"].tap()
        XCTAssertTrue(app.staticTexts["Sending…"].waitForExistence(timeout: 3))
    }

    func testChallengeScreensAppearanceAndTypeSizeMatrix() throws {
        let auditTypes = XCUIAccessibilityAuditType.textClipped
            .union(.hitRegion)
            .union(.sufficientElementDescription)
        for (appearance, size) in [
            ("Light", "UICTContentSizeCategoryXS"),
            ("Dark", "UICTContentSizeCategoryAccessibilityXXXL"),
        ] {
            let arguments = [
                "-AppleInterfaceStyle", appearance,
                "-UIPreferredContentSizeCategoryName", size,
                "-UIAccessibilityReduceMotionEnabled", "YES",
            ]
            launch(.coldClaim, appearanceArguments: arguments)
            XCTAssertTrue(app.buttons["competition.claim.accept"].waitForExistence(timeout: 8))
            attachScreenshot("claim-\(appearance)-\(size)")
            try app.performAccessibilityAudit(for: auditTypes)

            launch(.challengeLink, appearanceArguments: arguments)
            XCTAssertTrue(element("competition.link.name").waitForExistence(timeout: 8))
            attachScreenshot("challenge-link-\(appearance)-\(size)")
            try app.performAccessibilityAudit(for: auditTypes)

            launch(.account, appearanceArguments: arguments)
            let url = element("account.challenge-link.url")
            XCTAssertTrue(url.waitForExistence(timeout: 8))
            scrollToElement(url)
            attachScreenshot("account-challenge-link-\(appearance)-\(size)")
            let showCode = element("account.challenge-link.show-code")
            scrollToElement(showCode)
            showCode.tap()
            XCTAssertTrue(element("account.challenge-link.qr").waitForExistence(timeout: 3))
            attachScreenshot("challenge-code-\(appearance)-\(size)")
            try app.performAccessibilityAudit(for: auditTypes)
        }
        app.terminate()
    }

    private func attachScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testUnavailableConsumedAndOfflineClaimRecoveryStayPrivacyCollapsed() {
        launch(.unavailableClaim)
        XCTAssertTrue(
            app.staticTexts["Challenge unavailable"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.staticTexts[
                "This link may be expired, already used, or no longer valid. Ask the sender for a new challenge."
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

    func testRemoteInvitationDisclosesSharedDerivedActivity() {
        launch(.sharing)
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        let pending = sharingCard(state: "pending", name: "Sam")
        scrollToElement(pending)
        pending.tap()
        XCTAssertTrue(app.navigationBars["Sam"].waitForExistence(timeout: 3))
        let disclosure = app.staticTexts["Sam sees your daily points and rounded ring percentages"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 3))
        scrollToElement(disclosure)
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(
                format: "label CONTAINS %@", "Your Health data stays on your iPhone"
            )).firstMatch.exists
        )
        XCTAssertTrue(app.staticTexts["Day 1 is the day after the challenge is accepted."].exists)
        XCTAssertFalse(app.staticTexts["Only daily points are shared"].exists)
        XCTAssertTrue(app.staticTexts["Waiting for Sam"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["competition.invite.share"].exists
        )
        XCTAssertTrue(
            app.staticTexts["competition.invite.expiry"].label
                .hasPrefix("Expires ")
        )
    }

    func testHealthOnboardingDisclosesSharedDerivedActivity() {
        launch(.healthOnboarding)
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Score with your rings"].waitForExistence(timeout: 8))
        let disclosure = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                "Derived match data is shared",
                "Daily points, rounded Activity percentages and modes"
            )
        ).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 3))
        scrollToElement(disclosure)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Only daily points are shared")
        ).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Your opponent never sees your rings")
        ).firstMatch.exists)
    }

    func testChallengeHealthOnboardingFramesTheMatch() {
        launch(.healthOnboardingChallenge)
        defer { app.terminate() }
        XCTAssertTrue(
            app.staticTexts["Connect Health so your rings count"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.staticTexts[
                "HealthComp reads your Activity rings to score each match day. You’ll join the match right after."
            ].exists
        )
        XCTAssertTrue(app.buttons["Connect Health"].exists)
        let disclosure = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                "Derived match data is shared",
                "Daily points, rounded Activity percentages and modes"
            )
        ).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 3))
    }

    func testWelcomeIsSignInAndPrivacyPolicyOnly() {
        launch(.welcome)
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Welcome to HealthComp"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.descendants(matching: .any)["account.sign-in-with-apple"].exists
        )
        XCTAssertFalse(app.staticTexts["HOW TO READ IT"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Your rings")
        ).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["account.subtitle"].exists)
        let privacyPolicy = app.descendants(matching: .any)["account.privacy-policy"]
        guard privacyPolicy.waitForExistence(timeout: 3) else {
            return XCTFail("Privacy Policy must be available before signing in.")
        }
        scrollToElement(privacyPolicy)
        XCTAssertGreaterThanOrEqual(privacyPolicy.frame.height, 44)
        privacyPolicy.tap()
        let openedURL = app.staticTexts["https://healthcomp.app/privacy"]
        XCTAssertTrue(openedURL.waitForExistence(timeout: 3))
    }

    func testWelcomeWithPendingChallengeAsksToSignIn() {
        launch(.welcomeChallenge)
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["You have a challenge"].waitForExistence(timeout: 8))
        let subtitle = app.staticTexts["account.subtitle"]
        XCTAssertTrue(subtitle.exists)
        XCTAssertEqual(subtitle.label, "Sign in with the account it was sent to.")
        XCTAssertTrue(
            app.descendants(matching: .any)["account.sign-in-with-apple"].exists
        )
    }

    func testAccountEditingAndPrivacyBoundariesRemainAccessible() {
        launch(.account)
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 8))
        let privacy = element("account.privacy")
        scrollToElement(privacy)
        privacy.tap()
        XCTAssertTrue(app.navigationBars["Privacy"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Raw Health data stays on this iPhone"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "The other person gets your daily points, rounded Activity percentages and modes"
            ].exists
        )
        let privacyPolicy = app.descendants(matching: .any)["account.privacy-policy"]
        guard privacyPolicy.waitForExistence(timeout: 3) else {
            return XCTFail("Privacy Policy must remain available in Account settings.")
        }
        scrollToElement(privacyPolicy)
        XCTAssertGreaterThanOrEqual(privacyPolicy.frame.height, 44)
        privacyPolicy.tap()
        XCTAssertTrue(app.staticTexts["https://healthcomp.app/privacy"].waitForExistence(timeout: 3))
        app.navigationBars["Privacy"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 3))
        let edit = app.buttons["account.settings.edit-display-name"]
        scrollToElement(edit)
        edit.tap()
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
            "That name is reserved. Try another."
        )
        // Sign out sits below Appearance, under the keyboard; Return
        // dismisses it so the list can scroll.
        field.typeText("\n")
        scrollToElement(app.buttons["account.sign-out"])
    }

    func testAccountDeletionConfirmationCanBeCancelledSafely() {
        launch(.account)
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 8))

        let deleteAccount = app.buttons["account.delete"]
        scrollToElement(deleteAccount)
        deleteAccount.tap()
        XCTAssertFalse(app.navigationBars["Delete Account"].exists)

        let alert = app.alerts["Delete Account?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(
            text(
                "You’ll confirm with Sign in with Apple. Live matches are cancelled, and finished matches stay in the other person’s history under the name Former competitor. This can’t be undone.",
                in: alert
            ).exists
        )
        XCTAssertTrue(alert.buttons["Delete Account"].exists)
        alert.buttons["Cancel"].tap()

        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Account"].exists)
        XCTAssertTrue(deleteAccount.exists)
        XCTAssertFalse(app.progressIndicators["Deleting account"].exists)
    }

    func testAccountDeletionFailureShowsUnderDeleteRow() {
        launch(.account)
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 8))
        let deleteAccount = app.buttons["account.delete"]
        scrollToElement(deleteAccount)
        deleteAccount.tap()
        let alert = app.alerts["Delete Account?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["account.delete.confirm"].firstMatch.tap()

        let message = app.staticTexts["account.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 3))
        XCTAssertEqual(
            message.label,
            "Couldn’t delete your account. Check your connection and try again."
        )
        XCTAssertTrue(app.buttons["account.delete"].isEnabled)
        XCTAssertFalse(app.progressIndicators["Deleting account"].exists)
    }

    func testSignOutAsksFirstAndStatesTheEffect() {
        launch(.account)
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 8))
        let signOut = app.buttons["account.sign-out"]
        scrollToElement(signOut)
        signOut.tap()

        let alert = app.alerts["Sign out?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(
            text(
                "While you’re signed out, your points stop reaching your 2 live matches and notifications stop. Sign back in before they end to catch up.",
                in: alert
            ).exists
        )
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        XCTAssertNotEqual(signOut.value as? String, "Signing out")

        signOut.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["account.sign-out.confirm"].firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        XCTAssertEqual(signOut.value as? String, "Signing out")
    }

    func testNotificationsPageOpensSettingsAndUnmutes() throws {
        launch(.account)
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 8))
        element("account.notifications").tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Turned off in iOS Settings"].exists)
        let mutedHeader = app.staticTexts["MUTED"]
        XCTAssertTrue(mutedHeader.exists)
        // The remote suite's audit set. `.dynamicType` flags a different
        // List element on each run here (header, name, initial), so it's
        // left to the local suite's single-screen audit, as elsewhere.
        try app.performAccessibilityAudit(
            for: XCUIAccessibilityAuditType.textClipped
                .union(.hitRegion)
                .union(.sufficientElementDescription)
        )

        app.buttons["account.notifications.settings"].tap()
        XCTAssertTrue(
            app.staticTexts[UIApplication.openNotificationSettingsURLString]
                .waitForExistence(timeout: 3)
        )

        let unmute = app.buttons["Unmute Hermes"]
        XCTAssertTrue(unmute.exists)
        unmute.tap()
        XCTAssertTrue(mutedHeader.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.buttons["account.notifications.unmute"].exists)
    }

    func testHealthPageOpensSettings() {
        launch(.account)
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 8))
        element("account.health").tap()
        XCTAssertTrue(app.navigationBars["Health"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            text(
                "iOS doesn’t tell apps whether Health access is on. If your points aren’t updating, turn on all categories for HealthComp in Settings → Privacy & Security → Health."
            ).exists
        )
        app.buttons["account.health.settings"].tap()
        XCTAssertTrue(
            app.staticTexts[UIApplication.openSettingsURLString]
                .waitForExistence(timeout: 3)
        )
    }

    func testRemoteAppearanceSwitchRendersLightAndDark() {
        for appearance in ["Light", "Dark"] {
            launch(
                .sharing,
                appearanceArguments: [
                    "-AppleInterfaceStyle", appearance,
                    "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXS",
                ]
            )
            assertRemoteRenderedConfiguration(
                "Appearance: \(appearance); Dynamic Type: xSmall"
            )
        }
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
                app.navigationBars["Home"].waitForExistence(timeout: 8)
            )
            let open = app.buttons["competition.create.open"]
            XCTAssertTrue(open.waitForExistence(timeout: 3))
            XCTAssertTrue(open.isHittable)
            assertRemoteRenderedConfiguration(expectedConfiguration)
            let homeScreenshot = XCTAttachment(screenshot: app.screenshot())
            homeScreenshot.name =
                "remote-home-\(item.appearance)-\(item.expectedDynamicTypeSize)"
            homeScreenshot.lifetime = .keepAlways
            add(homeScreenshot)
            try app.performAccessibilityAudit(for: auditTypes)
            try assertNoPrivateFixtureContentIsSpoken()

            openChallengeDrawer()
            chooseRecipient()
            let create = app.buttons["competition.create.button"]
            scrollToElement(create)
            XCTAssertTrue(create.isHittable)
            try app.performAccessibilityAudit(for: auditTypes)
            closeChallengeDrawer()

            let active = sharingCard(state: "active", name: "Jordan")
            scrollToElement(active)
            XCTAssertTrue(active.isHittable)
            active.tap()
            XCTAssertTrue(
                app.navigationBars["Jordan"]
                    .waitForExistence(timeout: 3)
            )
            let owner = app.otherElements["competition.scoreHeader.naren"]
            let opponent = app.otherElements["competition.scoreHeader.alex"]
            scrollToElement(owner)
            XCTAssertTrue(owner.label.contains("You"))
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

            showWeek()
            let dayContexts: [(ordinal: Int, context: String)] = [
                (1, ", complete."),
                (3, "Today, scores so far"),
                (7, "upcoming."),
            ]
            for dayContext in dayContexts {
                let day = app.descendants(matching: .any)[
                    "competition.day.\(dayContext.ordinal)"
                ]
                scrollToElement(day)
                let label = day.label
                XCTAssertTrue(label.hasPrefix("Day \(dayContext.ordinal),"))
                XCTAssertTrue(label.contains(dayContext.context))
                if dayContext.ordinal == 7 {
                    XCTAssertFalse(label.contains("--"))
                } else {
                    XCTAssertTrue(label.contains("You"))
                    XCTAssertTrue(label.contains("Jordan"))
                }
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
            revealRemoteElementFully(completed)
            XCTAssertTrue(completed.isHittable)
            completed.tap()
            XCTAssertTrue(
                app.navigationBars["Former competitor"].waitForExistence(timeout: 3)
            )
            let result = app.otherElements["competition.result"]
            scrollToElement(result)
            XCTAssertTrue(result.label.contains("You"))
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
            XCTAssertTrue(moreMenu.isHittable)
            assertRemoteRenderedConfiguration(expectedConfiguration)
            try app.performAccessibilityAudit(for: auditTypes)
            try assertNoPrivateFixtureContentIsSpoken()
            navigateBackToSharing()
        }
    }

    private func chooseRecipient() {
        let input = recipientCodeField
        scrollToElement(input)
        input.tap()
        input.typeText("a1000000-0000-4000-8000-000000000005")
        let done = app.buttons["competition.create.keyboard-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        done.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        let find = app.buttons["competition.create.find-recipient"]
        scrollToElement(find)
        find.tap()
        XCTAssertTrue(app.staticTexts["competition.create.recipient-name"].waitForExistence(timeout: 3))
    }

    func testRemoteCompetitionDynamicTypeRemainsReadable() throws {
        // XCTest changes the content-size category during this audit, so it
        // must run without a fixed preferred-category launch override.
        launch(.sharing)
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))

        let active = sharingCard(state: "active", name: "Jordan")
        scrollToElement(active)
        active.tap()
        XCTAssertTrue(
            app.navigationBars["Jordan"]
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
        XCTAssertTrue(app.navigationBars["Former competitor"].waitForExistence(timeout: 3))
        let result = app.otherElements["competition.result"]
        scrollToElement(result)
        XCTAssertEqual(
            result.label,
            "You beat Former competitor. Final score. You 3,520 points. Former competitor 3,410 points."
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
            app.navigationBars["Home"].waitForExistence(timeout: 8)
        )
        assertRemoteRenderedConfiguration(expectedConfiguration)

        let active = sharingCard(state: "active", name: "Jordan")
        scrollToElement(active)
        active.tap()
        XCTAssertTrue(
            app.navigationBars["Jordan"]
                .waitForExistence(timeout: 3)
        )
        showWeek()

        let upcomingDay = app.descendants(matching: .any)["competition.day.7"]
        scrollToElement(upcomingDay)
        let upcomingLabel = upcomingDay.label
        XCTAssertTrue(upcomingLabel.hasPrefix("Day 7,"))
        XCTAssertTrue(upcomingLabel.contains("upcoming."))
        XCTAssertFalse(upcomingLabel.contains("--"))
        XCTAssertFalse(upcomingLabel.contains("0 points"))
        XCTAssertFalse(upcomingLabel.localizedCaseInsensitiveContains("unavailable"))

        let currentDay = app.descendants(matching: .any)["competition.day.3"]
        scrollToElement(currentDay)
        revealRemoteElementFully(currentDay)
        assertRemoteRenderedConfiguration(expectedConfiguration)
        XCTAssertEqual(
            currentDay.label,
            "Day 3, Today, scores so far. You, 430 points. Jordan, 450 points."
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

    private func revealRemoteElementFully(_ element: XCUIElement) {
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.exists)
        var geometry: [String] = []
        func attachGeometry() {
            let attachment = XCTAttachment(string: geometry.joined(separator: "\n"))
            attachment.name = "remote-element-visibility-geometry"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for iteration in 0..<6 {
            let viewport = visibleRemoteScrollFrame(scrollView)
            XCTAssertGreaterThan(viewport.height, 0)
            let elementFrame = element.frame
            geometry.append("iteration=\(iteration); viewport=\(viewport); element=\(elementFrame)")
            if viewport.contains(elementFrame) {
                attachGeometry()
                return
            }
            let offset = (elementFrame.midY - viewport.midY) / viewport.height
            let distance = min(0.35, max(0.08, abs(offset)))
            let startY = offset > 0 ? 0.7 : 0.3
            let endY = startY + (offset > 0 ? -distance : distance)
            let start = scrollView.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: startY)
            )
            let end = scrollView.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: endY)
            )
            // Stop before releasing so scroll momentum cannot overshoot the element.
            start.press(
                forDuration: 0.05,
                thenDragTo: end,
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )
        }
        geometry.append("final viewport=\(visibleRemoteScrollFrame(scrollView)); element=\(element.frame)")
        attachGeometry()
        XCTAssertTrue(
            visibleRemoteScrollFrame(scrollView).contains(element.frame),
            "The full element must be visible before interacting. "
                + "viewport=\(visibleRemoteScrollFrame(scrollView)); element=\(element.frame)"
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
        XCTAssertFalse(app.navigationBars["Home"].exists)
    }

    private enum Scenario: String {
        case sharing
        case sharingCustomScheme = "sharing-custom-scheme"
        case coldClaim = "cold-claim"
        case warmClaim = "warm-claim"
        case signedOutClaim = "signed-out-claim"
        case unavailableClaim = "unavailable-claim"
        case offlineClaim = "offline-claim"
        case challengeLink = "challenge-link"
        case account
        case welcome
        case welcomeChallenge = "welcome-challenge"
        case healthOnboarding = "health-onboarding"
        case healthOnboardingChallenge = "health-onboarding-challenge"
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
            // The one-time color hint would shift scoreboards by test order.
            "-healthcomp.colorHintSeen", "YES",
        ] + appearanceArguments
        app.launch()
    }

    /// Subscripts reject identifiers over 128 characters; match the label.
    private func text(
        _ label: String,
        in root: XCUIElement? = nil
    ) -> XCUIElement {
        (root ?? app).staticTexts
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }

    // List rows that push a page may surface as cells, not buttons.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
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
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
        resetSharingScrollToTop()
    }

    private func resetSharingScrollToTop() {
        // Restore the page's first card, the competition in play, before
        // searching downward again.
        let hero = sharingCard(state: "active", name: "Jordan")
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.exists)
        for _ in 0..<24 {
            if hero.exists, hero.isHittable { return }
            let start = scrollView.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)
            )
            let end = scrollView.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)
            )
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(hero.exists, "The competition in play must exist after scrolling toward the top.")
        XCTAssertTrue(hero.isHittable, "The competition in play must be reachable before searching matches.")
    }

    private func openChallengeDrawer() {
        let open = app.buttons["competition.create.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        open.tap()
        XCTAssertTrue(
            app.buttons["competition.create.done"].waitForExistence(timeout: 3)
        )
    }

    private func closeChallengeDrawer() {
        let close = app.buttons["competition.create.done"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 3))
    }

    // A match opens on Today; the day rows live on Week.
    private func waitForStatus(_ prefix: String, timeout: TimeInterval = 5) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@",
            "competition.status", prefix)).firstMatch.waitForExistence(timeout: timeout)
    }

    private func showWeek() {
        let week = app.buttons["Week"]
        XCTAssertTrue(week.waitForExistence(timeout: 3))
        week.tap()
    }

    // iOS 18 exposes Menu's identified wrapper, not its nested button, as hittable.
    private var moreMenu: XCUIElement {
        element("competition.more")
    }

    private func tapMoreMenuItem(_ title: String) {
        let more = moreMenu
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        more.tap()
        let item = app.buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.tap()
    }

    private func scrollToElement(_ element: XCUIElement) {
        for _ in 0..<24 {
            // Fully on screen: a row cut by the bottom edge reports hittable,
            // but a tap there lands on the home indicator.
            if element.exists, element.isHittable,
               app.frame.contains(element.frame) { return }
            // List is a CollectionView on iOS 18; keyboard dismissal can
            // remove a transient ScrollView between coordinate lookups.
            let collectionView = app.collectionViews.firstMatch
            let scrollView = app.scrollViews.firstMatch
            let surface: XCUIElement = collectionView.exists
                ? collectionView : (scrollView.exists ? scrollView : app)
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
