import XCTest

/// The Challenge sheet's friends, and Remove Friend, Block and Report on a
/// person page, through the app's own root view. `FriendsTestLabServer`
/// scripts the server: every call takes 0.3 s; Jordan has asked to be
/// friends; your friends are Priya (your challenge is waiting), Maya (live),
/// Sam (starts soon), Dev (one finished week) and Kai (nothing yet, and the
/// server refuses a challenge to Kai); Sam's challenge link finds Sam Okafor.
final class ChallengeFriendUITests: XCTestCase {
    private var app: XCUIApplication!

    private enum Person {
        static let priya = "d1000000-0000-4000-8000-0000000000a2"
        static let maya = "d1000000-0000-4000-8000-0000000000b1"
        static let sam = "d1000000-0000-4000-8000-0000000000b2"
        static let dev = "d1000000-0000-4000-8000-0000000000b3"
        static let kai = "d1000000-0000-4000-8000-0000000000b4"
    }

    private enum Scenario: String {
        case challengeFriend = "challenge-friend"
        case empty = "friends-empty"
    }

    /// Wrapped text the clipping audit flags anyway, seen whole in the
    /// attached screenshots.
    private static let readsClippedToTheAudit: Set<String> = [
        "Friends can challenge each other without a link.",
        "Confirm this is the person you intended before creating the challenge.",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        if app.state != .notRunning { app.terminate() }
        app = nil
    }

    // MARK: Challenge sheet

    func testPickAFriendConfirmAndSend() {
        launch(.challengeFriend)
        openSheet()
        let dev = friendRow(Person.dev)
        XCTAssertTrue(dev.isEnabled)
        XCTAssertTrue(dev.label.contains("Dev Patel"), dev.label)
        XCTAssertTrue(dev.label.contains("You lead 1–0"), dev.label)
        XCTAssertTrue(friendRow(Person.kai).label.contains("No matches yet"))
        XCTAssertTrue(element("competition.create.someone-else").exists)
        // Nothing to confirm yet, so no Create button.
        XCTAssertFalse(app.buttons["competition.create.button"].exists)

        dev.tap()
        let name = app.staticTexts["competition.create.recipient-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        XCTAssertEqual(name.label, "Challenge Dev Patel")
        // A friend needs no link: the field never shows.
        XCTAssertFalse(element("competition.create.recipient-code").exists)
        XCTAssertFalse(app.buttons["competition.create.find-recipient"].exists)
        XCTAssertTrue(app.staticTexts["competition.create.time-zone"].exists)
        let create = app.buttons["competition.create.button"]
        XCTAssertTrue(create.isEnabled)
        create.tap()
        XCTAssertTrue(app.buttons["competition.create.share"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Challenge sent"].exists)
    }

    func testAFriendYouArePlayingOrChallengedIsDimmedAndCannotBeChosen() {
        launch(.challengeFriend)
        openSheet()
        let maya = friendRow(Person.maya)
        XCTAssertFalse(maya.isEnabled)
        XCTAssertTrue(maya.label.contains("In a match with you"), maya.label)
        let sam = friendRow(Person.sam)
        XCTAssertFalse(sam.isEnabled)
        XCTAssertTrue(sam.label.contains("In a match with you"), sam.label)
        let priya = friendRow(Person.priya)
        XCTAssertFalse(priya.isEnabled)
        XCTAssertTrue(priya.label.contains("Challenge pending"), priya.label)

        maya.tap()
        XCTAssertFalse(app.staticTexts["competition.create.recipient-name"].waitForExistence(timeout: 2))
        XCTAssertTrue(element("competition.create.friends").exists, "Still choosing")
    }

    func testARefusedFriendIsNeverToldNoAccountHasALink() {
        launch(.challengeFriend)
        openSheet()
        friendRow(Person.kai).tap()
        let create = app.buttons["competition.create.button"]
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        create.tap()
        let refusal = element("competition.create.recipient-unavailable")
        XCTAssertTrue(refusal.waitForExistence(timeout: 5))
        XCTAssertEqual(refusal.label, "You can’t challenge Kai Ito right now.")
        XCTAssertFalse(element("competition.create.recipient-error").exists)
        XCTAssertFalse(app.staticTexts["No account has this link. Check it and try again."].exists)
        XCTAssertEqual(app.staticTexts["competition.create.recipient-name"].label, "Challenge Kai Ito")
        XCTAssertEqual(app.alerts.count, 0)
    }

    func testSearchPeopleOpensFriendsWithTheFieldFocused() {
        launch(.challengeFriend)
        openSheet()
        app.buttons["competition.create.search-people"].tap()
        XCTAssertTrue(app.navigationBars["Friends"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("competition.create.card").exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("marc")
        XCTAssertTrue(app.buttons["friends.result.d1000000-0000-4000-8000-0000000000c1"].waitForExistence(timeout: 5))
    }

    func testPasteTheirLinkStillFindsThemFromItsRow() {
        launch(.challengeFriend)
        openSheet()
        XCTAssertFalse(element("competition.create.recipient-code").exists)
        app.buttons["competition.create.paste-link"].tap()
        let field = recipientCodeField
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertFalse(element("competition.create.friends").exists, "The link replaces the groups")
        field.tap()
        // Return runs Find.
        field.typeText("healthcomp://challenge/SamSamSamSamSamSamSam1\n")
        let name = app.staticTexts["competition.create.recipient-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.label, "Challenge Sam Okafor")
        let create = app.buttons["competition.create.button"]
        scrollTo(create)
        create.tap()
        XCTAssertTrue(app.buttons["competition.create.share"].waitForExistence(timeout: 5))
    }

    func testNoFriendsOmitsTheGroup() {
        launch(.empty)
        openSheet(waitForFriends: false)
        XCTAssertTrue(app.buttons["competition.create.paste-link"].waitForExistence(timeout: 3))
        XCTAssertFalse(element("competition.create.friends").exists)
        XCTAssertTrue(app.buttons["competition.create.search-people"].exists)
    }

    // MARK: Person pages

    func testRemoveFriend() {
        launch(.challengeFriend)
        openFriend(Person.dev)
        XCTAssertTrue(element("competition.person").waitForExistence(timeout: 5))
        // Their username, under the record.
        XCTAssertTrue(element("competition.person.record").label.contains("@devp"))
        openMenu()
        XCTAssertTrue(menuItem("friends.menu.block").exists)
        XCTAssertTrue(menuItem("friends.menu.report").exists)
        XCTAssertFalse(menuItem("friends.menu.add").exists)
        menuItem("friends.menu.remove").tap()
        XCTAssertTrue(app.staticTexts["Remove Dev Patel as a friend?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["You can still play each other with a link."].exists)
        confirm("Remove Friend", menuID: "friends.menu.remove")
        // The menu only changes when it opens again: after the 0.3 s call.
        Thread.sleep(forTimeInterval: 1)
        openMenu()
        // Played but no longer friends: they can be added again.
        XCTAssertTrue(menuItem("friends.menu.add").exists)
        XCTAssertFalse(menuItem("friends.menu.remove").exists)
        closeMenu()
        back()
        XCTAssertTrue(app.buttons["friends.friend.\(Person.dev)"].waitForNonExistence(timeout: 5))
    }

    func testBlockFromAFriendsPageThenSeeThemInAccount() {
        launch(.challengeFriend)
        openFriend(Person.kai)
        XCTAssertTrue(element("friends.person").waitForExistence(timeout: 5))
        openMenu()
        menuItem("friends.menu.block").tap()
        XCTAssertTrue(app.staticTexts["Block Kai Ito?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts[
            "Kai Ito can’t challenge you or find you in search, and you’ll no longer be friends. They aren’t notified."
        ].exists)
        confirm("Block Kai Ito", menuID: "friends.menu.block")
        // Back where they were found, and gone from it.
        XCTAssertTrue(element("friends.person").waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Friends"].exists)
        XCTAssertTrue(app.buttons["friends.friend.\(Person.kai)"].waitForNonExistence(timeout: 5))

        back()
        openAccount()
        let unblock = app.buttons["Unblock Kai Ito"]
        scrollTo(unblock)
        XCTAssertEqual(unblock.identifier, "account.blocked.unblock")
    }

    func testReportThenReportAndBlock() {
        launch(.challengeFriend)
        openFriend(Person.dev)
        XCTAssertTrue(element("competition.person").waitForExistence(timeout: 5))
        openMenu()
        menuItem("friends.menu.report").tap()
        XCTAssertTrue(app.staticTexts["Report Dev Patel?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["We’ll review this account. Reporting doesn’t block them."].exists)
        XCTAssertTrue(app.buttons["Report and Block Dev Patel"].exists)
        confirm("Report", menuID: "friends.menu.report")
        let reported = element("friends.person.reported")
        XCTAssertTrue(reported.waitForExistence(timeout: 5))
        XCTAssertEqual(reported.label, "Reported. Thanks.")
        XCTAssertTrue(element("competition.person").exists, "Reporting doesn't block")
        XCTAssertEqual(app.alerts.count, 0)
        back()

        let maya = app.buttons["friends.friend.\(Person.maya)"]
        XCTAssertTrue(maya.waitForExistence(timeout: 5))
        maya.tap()
        XCTAssertTrue(element("friends.person").waitForExistence(timeout: 5))
        openMenu()
        menuItem("friends.menu.report").tap()
        XCTAssertTrue(app.staticTexts["Report Maya Chen?"].waitForExistence(timeout: 3))
        confirm("Report and Block Maya Chen", menuID: "friends.menu.report")
        XCTAssertTrue(element("friends.person").waitForNonExistence(timeout: 6))
        XCTAssertTrue(maya.waitForNonExistence(timeout: 5))
        back()
        openAccount()
        let unblock = app.buttons["Unblock Maya Chen"]
        scrollTo(unblock)
        XCTAssertTrue(unblock.exists)
    }

    // MARK: Appearances

    /// Named `<screen>-<light|dark>-<default|ax5>`, for review.
    func testAppearancesAndLargestTextSize() throws {
        let sizes = [("default", "UICTContentSizeCategoryL"), ("ax5", "UICTContentSizeCategoryAccessibilityXXXL")]
        for appearance in ["Light", "Dark"] {
            for (sizeName, size) in sizes {
                let suffix = "\(appearance.lowercased())-\(sizeName)"
                let arguments = [
                    "-AppleInterfaceStyle", appearance,
                    "-healthcomp.appearance", appearance.lowercased(),
                    "-UIPreferredContentSizeCategoryName", size,
                ]
                launch(.challengeFriend, arguments: arguments)
                openSheet()
                shot("sheet-friends-\(suffix)")
                try audit("sheet \(suffix)")
                let kai = friendRow(Person.kai)
                scrollTo(kai)
                kai.tap()
                let create = app.buttons["competition.create.button"]
                XCTAssertTrue(create.waitForExistence(timeout: 3))
                shot("confirm-friend-\(suffix)")
                try audit("confirm \(suffix)")
                scrollTo(create)
                create.tap()
                let refusal = element("competition.create.recipient-unavailable")
                XCTAssertTrue(refusal.waitForExistence(timeout: 5))
                scrollTo(refusal)
                shot("refusal-\(suffix)")
                app.buttons["competition.create.done"].tap()
                XCTAssertTrue(app.buttons["competition.create.done"].waitForNonExistence(timeout: 3))

                openFriend(Person.dev)
                XCTAssertTrue(element("competition.person").waitForExistence(timeout: 5))
                shot("friend-page-\(suffix)")
                try audit("friend page \(suffix)")
                openMenu()
                shot("friend-menu-\(suffix)")
                menuItem("friends.menu.remove").tap()
                XCTAssertTrue(app.staticTexts["Remove Dev Patel as a friend?"].waitForExistence(timeout: 3))
                shot("dialog-remove-\(suffix)")
                dismissDialog()
                openMenu()
                menuItem("friends.menu.block").tap()
                XCTAssertTrue(app.staticTexts["Block Dev Patel?"].waitForExistence(timeout: 3))
                shot("dialog-block-\(suffix)")
                dismissDialog()
                openMenu()
                menuItem("friends.menu.report").tap()
                XCTAssertTrue(app.staticTexts["Report Dev Patel?"].waitForExistence(timeout: 3))
                shot("dialog-report-\(suffix)")
                dismissDialog()

                launch(.empty, arguments: arguments)
                openSheet(waitForFriends: false)
                XCTAssertTrue(app.buttons["competition.create.paste-link"].waitForExistence(timeout: 3))
                shot("sheet-no-friends-\(suffix)")
                try audit("sheet no friends \(suffix)")
            }
        }
    }

    // MARK: Helpers

    private var recipientCodeField: XCUIElement {
        let field = app.textFields["competition.create.recipient-code"]
        return field.exists ? field : app.textViews["competition.create.recipient-code"]
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func friendRow(_ id: String) -> XCUIElement {
        let row = app.buttons["competition.create.friend.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), id)
        return row
    }

    // iOS 18 exposes Menu's identified wrapper, not its nested button, as hittable.
    private func openMenu() {
        let more = element("competition.more")
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        more.tap()
        XCTAssertTrue(menuItem("friends.menu.block").waitForExistence(timeout: 3))
    }

    private func closeMenu() {
        // A tap above the menu, on the navigation bar's title.
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        _ = menuItem("friends.menu.block").waitForNonExistence(timeout: 2)
    }

    private func menuItem(_ identifier: String) -> XCUIElement {
        app.buttons[identifier]
    }

    /// The dialog's button, not the menu item of the same name.
    private func confirm(_ label: String, menuID: String) {
        let button = app.buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", label, menuID)
        ).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 3), label)
        button.tap()
    }

    /// Cancel, or a tap outside where iOS shows the dialog as a popover.
    private func dismissDialog() {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists, cancel.isHittable {
            cancel.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        }
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 3))
    }

    private func launch(_ scenario: Scenario, arguments: [String] = []) {
        if app.state != .notRunning { app.terminate() }
        app = XCUIApplication()
        app.launchEnvironment["TZ"] = "America/Los_Angeles"
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", scenario.rawValue,
            "-healthcomp.colorHintSeen", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ] + arguments
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 10))
    }

    private func openSheet(waitForFriends: Bool = true) {
        if waitForFriends {
            // The badge shows once the Friends list has loaded.
            XCTAssertTrue(waitUntil(5) { self.app.buttons["friends.open"].label == "Friends, 1 request" })
        }
        let open = app.buttons["competition.create.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(app.buttons["competition.create.done"].waitForExistence(timeout: 3))
    }

    private func openFriend(_ id: String) {
        let friends = app.buttons["friends.open"]
        XCTAssertTrue(friends.waitForExistence(timeout: 5))
        friends.tap()
        XCTAssertTrue(app.navigationBars["Friends"].waitForExistence(timeout: 5))
        let row = app.buttons["friends.friend.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        scrollTo(row)
        row.tap()
    }

    private func openAccount() {
        let account = app.buttons["app.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
    }

    private func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    private func scrollTo(_ target: XCUIElement) {
        let window = app.windows.firstMatch
        for _ in 0..<16 where !(target.exists && target.isHittable) {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        }
        XCTAssertTrue(target.isHittable, "\(target)")
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return condition()
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
                    guard issue.element != nil else {
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
