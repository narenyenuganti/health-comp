import XCTest

/// The Friends screen, search and the new-person page, through the app's own
/// root view. `FriendsTestLabServer` scripts the server: every call takes
/// 0.3 s; Jordan and Priya have asked to be friends; Maya is live, Sam starts
/// soon, Dev has a finished week and Kai has nothing; Marcus and Mara can be
/// added (Mara's first Add fails), Mateo is already requested; `ratelimit`
/// hits the search limit.
final class FriendsUITests: XCTestCase {
    private var app: XCUIApplication!

    private enum Person {
        static let jordan = "d1000000-0000-4000-8000-0000000000a1"
        static let priya = "d1000000-0000-4000-8000-0000000000a2"
        static let maya = "d1000000-0000-4000-8000-0000000000b1"
        static let dev = "d1000000-0000-4000-8000-0000000000b3"
        static let marcus = "d1000000-0000-4000-8000-0000000000c1"
        static let mateo = "d1000000-0000-4000-8000-0000000000c2"
        static let mara = "d1000000-0000-4000-8000-0000000000c3"
    }

    private static let mayaHero = "competition.sharing.active.d2000000-0000-4000-8000-000000000001"

    private enum Scenario: String {
        case friends
        case empty = "friends-empty"
        case noUsername = "friends-no-username"
    }

    /// Wrapped or single-line text the clipping audit flags anyway, seen
    /// whole in the attached screenshots.
    private static let readsClippedToTheAudit: Set<String> = [
        "REQUESTS · 2", "FRIENDS · 4",
        // Replaced by "Search" at accessibility sizes.
        "Search name or username",
        "Can’t find them? Send your link from Friends.",
        "Friends can challenge each other without a link.",
        "No friends yet. Search for someone or send your link.",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        if app.state != .notRunning { app.terminate() }
        app = nil
    }

    func testBadgeCountsRequests() {
        launch(.friends)
        XCTAssertTrue(waitUntil(5) { self.openButton.label == "Friends, 2 requests" })
        openFriends()
        tapAccept(Person.jordan)
        back()
        XCTAssertTrue(waitUntil(5) { self.openButton.label == "Friends, 1 request" })
    }

    func testAcceptAndDeclineARequest() {
        launch(.friends)
        openFriends()
        XCTAssertTrue(app.staticTexts["REQUESTS · 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["FRIENDS · 4"].exists)
        XCTAssertTrue(app.staticTexts["@jordanlee"].exists)
        // The status line comes from match data: live, starts, record, none.
        XCTAssertTrue(app.staticTexts["Live · Day 3 of 7"].exists)
        XCTAssertTrue(app.staticTexts["You lead 1–0"].exists)

        tapAccept(Person.jordan)
        XCTAssertTrue(app.staticTexts["REQUESTS · 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["FRIENDS · 5"].waitForExistence(timeout: 5))

        let decline = app.buttons["friends.request.decline.\(Person.priya)"]
        XCTAssertEqual(decline.label, "Decline Priya Shah")
        decline.tap()
        XCTAssertTrue(decline.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["REQUESTS · 1"].exists)
        XCTAssertEqual(app.alerts.count, 0)
    }

    func testSearchAddThenCancelTheRequest() {
        launch(.friends)
        openFriends()
        search("mar")
        let action = app.buttons["friends.result.action.\(Person.marcus)"]
        expect(action)
        XCTAssertEqual(action.label, "Add")
        XCTAssertTrue(app.staticTexts["Can’t find them? Send your link from Friends."].exists)

        action.tap()
        XCTAssertTrue(waitUntil(5) { action.label == "Requested" })

        action.tap()
        let cancel = app.buttons["Cancel Request"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        // Keeping it changes nothing.
        app.buttons["Keep Request"].tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 3))
        XCTAssertEqual(action.label, "Requested")

        action.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.tap()
        XCTAssertTrue(waitUntil(5) { action.label == "Add" })

        // Someone already requested, and the friend label.
        search("mat")
        let mateo = app.buttons["friends.result.action.\(Person.mateo)"]
        expect(mateo)
        XCTAssertEqual(mateo.label, "Requested")
        search("maya")
        let maya = element("friends.result.action.\(Person.maya)")
        expect(maya)
        XCTAssertEqual(maya.label, "Friends")
    }

    func testSearchEmptyStatesAndALimit() {
        launch(.friends)
        openFriends()
        search("ma")
        // Under three characters shows nothing.
        XCTAssertFalse(element("friends.search.empty").waitForExistence(timeout: 1))
        XCTAssertFalse(element("friends.result.\(Person.marcus)").exists)

        search("maqqq")
        let empty = element("friends.search.empty")
        expect(empty)
        XCTAssertEqual(empty.label, "No one found.")
        XCTAssertFalse(element("friends.search.hint").exists)

        element("friends.search.clear").tap()
        XCTAssertTrue(empty.waitForNonExistence(timeout: 3))
        search("ratelimit")
        let error = element("friends.search.error")
        expect(error)
        XCTAssertEqual(error.label, "Too many searches. Try again in a minute.")

        // Clearing returns to the list. Back is every pushed page's one,
        // and leaves Friends from search too.
        let clear = element("friends.search.clear")
        XCTAssertGreaterThanOrEqual(clear.frame.width, 44)
        XCTAssertGreaterThanOrEqual(clear.frame.height, 44)
        clear.tap()
        XCTAssertTrue(app.staticTexts["REQUESTS · 2"].waitForExistence(timeout: 3))
        search("qqq")
        expect(empty)
        back()
        XCTAssertTrue(app.buttons["friends.open"].waitForExistence(timeout: 5))
        // Closing forgot the search.
        openFriends()
        XCTAssertTrue(app.staticTexts["REQUESTS · 2"].waitForExistence(timeout: 5))
        XCTAssertFalse(empty.exists)
    }

    func testAFailedAddStaysInlineAndCanBeTriedAgain() {
        launch(.friends)
        openFriends()
        search("mara")
        let action = app.buttons["friends.result.action.\(Person.mara)"]
        expect(action)
        action.tap()
        let failure = element("friends.failure.\(Person.mara)")
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertEqual(failure.label, "Couldn’t update. Check your connection and try again.")
        XCTAssertEqual(app.alerts.count, 0)
        XCTAssertEqual(action.label, "Add", "Rolled back")
        action.tap()
        XCTAssertTrue(waitUntil(5) { action.label == "Requested" })
        XCTAssertFalse(failure.exists)
    }

    func testOpenSomeoneNewAndAddThem() {
        launch(.friends)
        openFriends()
        search("marc")
        let row = app.buttons["friends.result.\(Person.marcus)"]
        expect(row)
        row.tap()
        XCTAssertTrue(element("friends.person").waitForExistence(timeout: 5))
        XCTAssertEqual(element("friends.person.name").label, "Marcus Hill")
        XCTAssertEqual(element("friends.person.username").label, "@marcush")
        XCTAssertTrue(app.staticTexts["Friends can challenge each other without a link."].exists)
        XCTAssertFalse(element("competition.person").exists, "A new person gets their own page")

        let action = app.buttons["friends.person.action"]
        XCTAssertEqual(action.label, "Add Friend")
        action.tap()
        XCTAssertTrue(waitUntil(5) { action.label == "Requested" })

        // Back in the results, with the answer already applied.
        back()
        XCTAssertTrue(waitUntil(5) {
            self.app.buttons["friends.result.action.\(Person.marcus)"].label == "Requested"
        })
    }

    func testOpenAFriendsExistingPage() {
        launch(.friends)
        openFriends()
        let row = app.buttons["friends.friend.\(Person.dev)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(element("friends.person").waitForExistence(timeout: 5))
        // All their weeks are one push further.
        let weeks = app.buttons["competition.profile.weeks"]
        XCTAssertTrue(weeks.waitForExistence(timeout: 5))
        weeks.tap()
        XCTAssertTrue(element("competition.person").waitForExistence(timeout: 5))
        back()
        XCTAssertTrue(element("friends.person").waitForExistence(timeout: 5))
        // Friends stays under it on the stack.
        back()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Friends"].exists)
    }

    /// Each side of Home's score opens that person; the rest of the card
    /// still opens the match.
    func testAPhotoOnTheScoreOpensTheProfile() {
        launch(.friends)
        let hero = app.buttons[Self.mayaHero]
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        hero.coordinate(withNormalizedOffset: CGVector(dx: 0.74, dy: 0.18)).tap()
        XCTAssertTrue(element("friends.person").waitForExistence(timeout: 5))
        XCTAssertEqual(element("friends.person.name").label, "Maya Chen")
        XCTAssertTrue(element("friends.person.prize").exists, "The belt is on offer")
        XCTAssertFalse(app.buttons["friends.person.challenge"].exists, "A match is already running")
        shot("profile-first-match")
        back()

        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        hero.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.18)).tap()
        XCTAssertTrue(element("competition.ownProfile").waitForExistence(timeout: 5))
        XCTAssertEqual(element("competition.ownProfile.record").label, "1–0")
        let share = app.switches["competition.ownProfile.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertEqual(share.value as? String, "0", "Off until you turn it on")
        share.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(5) { share.value as? String == "1" })
        shot("profile-you")
        back()

        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        hero.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        XCTAssertTrue(element("competition.scoreHeader.alex").waitForExistence(timeout: 5))
    }

    func testProfilesFromFriendsAtTheLargestText() throws {
        let sizes = [("default", "UICTContentSizeCategoryL"), ("ax5", "UICTContentSizeCategoryAccessibilityXXXL")]
        for (name, size) in sizes {
            launch(.friends, arguments: ["-UIPreferredContentSizeCategoryName", size])
            let hero = app.buttons[Self.mayaHero]
            XCTAssertTrue(hero.waitForExistence(timeout: 5))
            hero.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()
            let yours = element("competition.scoreHeader.naren")
            XCTAssertTrue(yours.waitForExistence(timeout: 5))
            yours.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
            XCTAssertTrue(element("competition.ownProfile").waitForExistence(timeout: 5))
            XCTAssertTrue(app.switches["competition.ownProfile.share"].waitForExistence(timeout: 5))
            shot("own-\(name)")
            try audit("own \(name)")
            back()
            back()

            openFriends()
            let dev = app.buttons["friends.friend.\(Person.dev)"]
            XCTAssertTrue(dev.waitForExistence(timeout: 5))
            dev.tap()
            let tape = element("friends.person.tape")
            XCTAssertTrue(tape.waitForExistence(timeout: 5), "Dev shares their career")
            XCTAssertTrue(tape.label.contains("Career: You 1–0, Dev Patel 18–9–1") || tape.label.contains("CAREER: You 1–0, Dev Patel 18–9–1"), tape.label)
            shot("dev-\(name)")
            try audit("dev \(name)")
            back()

            let kai = app.buttons["friends.friend.d1000000-0000-4000-8000-0000000000b4"]
            XCTAssertTrue(kai.waitForExistence(timeout: 5))
            kai.tap()
            XCTAssertTrue(element("friends.person.prize").waitForExistence(timeout: 5))
            XCTAssertFalse(element("friends.person.tape").exists, "Kai keeps it private")
            XCTAssertEqual(app.buttons["friends.person.challenge"].label, "Challenge Kai Ito")
            shot("kai-\(name)")
            try audit("kai \(name)")
        }
    }

    func testFirstOpenAsksForAUsernameOnce() {
        launch(.noUsername)
        openFriends()
        let sheet = element("account.username.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Pick a username"].exists)
        app.buttons["account.username.not-now"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 3))

        back()
        openFriends()
        XCTAssertFalse(sheet.waitForExistence(timeout: 2), "Not Now is respected")
    }

    func testEmptyFriends() {
        launch(.empty)
        XCTAssertEqual(openButton.label, "Friends")
        openFriends()
        let empty = element("friends.empty")
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertEqual(empty.label, "No friends yet. Search for someone or send your link.")
        XCTAssertTrue(element("friends.invite").waitForExistence(timeout: 3))
    }

    /// Named `<screen>-<light|dark>-<default|ax5>`. Hit regions, clipping
    /// and labels are audited in every combination.
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
                launch(.friends, arguments: arguments)
                XCTAssertTrue(waitUntil(5) { self.openButton.label == "Friends, 2 requests" })
                shot("home-badge-\(suffix)")
                openFriends()
                XCTAssertTrue(app.staticTexts["REQUESTS · 2"].waitForExistence(timeout: 5))
                shot("friends-requests-\(suffix)")
                try audit("friends \(suffix)")
                search("mar")
                expect(element("friends.result.\(Person.marcus)"))
                shot("search-results-\(suffix)")
                // Everything is reachable with the keyboard up.
                scrollTo(element("friends.search.hint"))
                // Pinned: the query and its clear button stay on screen.
                XCTAssertTrue(field.isHittable)
                XCTAssertTrue(element("friends.search.clear").isHittable)
                shot("search-results-scrolled-\(suffix)")
                // Keyboard down: its predictive bar has no label to audit.
                dismissKeyboard()
                try audit("search \(suffix)")
                search("qqq")
                expect(element("friends.search.empty"))
                shot("search-empty-\(suffix)")
                search("marc")
                let row = app.buttons["friends.result.\(Person.marcus)"]
                expect(row)
                dismissKeyboard()
                row.tap()
                XCTAssertTrue(element("friends.person").waitForExistence(timeout: 5))
                shot("new-person-\(suffix)")
                try audit("new person \(suffix)")

                launch(.empty, arguments: arguments)
                openFriends()
                XCTAssertTrue(element("friends.empty").waitForExistence(timeout: 5))
                shot("friends-empty-\(suffix)")
                try audit("empty \(suffix)")
            }
        }
    }

    // MARK: Helpers

    private var openButton: XCUIElement { app.buttons["friends.open"] }
    private var field: XCUIElement { app.textFields["friends.search.field"] }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
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
        XCTAssertTrue(openButton.waitForExistence(timeout: 5))
    }

    private func openFriends() {
        openButton.tap()
        XCTAssertTrue(app.navigationBars["Friends"].waitForExistence(timeout: 5))
    }

    private func tapAccept(_ id: String) {
        let accept = app.buttons["friends.request.accept.\(id)"]
        XCTAssertTrue(accept.waitForExistence(timeout: 5))
        accept.tap()
        XCTAssertTrue(accept.waitForNonExistence(timeout: 5))
    }

    /// Sets the query to exactly `text`, and waits until the field says so
    /// before anyone waits on results: a slow runner can drop keys.
    private func search(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
        for attempt in 1...2 where fieldText != text {
            if attempt > 1 {
                XCTContext.runActivity(named: "Retyping \"\(text)\": the field read \"\(fieldText)\"") { _ in }
            }
            let clear = element("friends.search.clear")
            if clear.exists {
                clear.tap()
                _ = waitUntil(3) { !clear.exists }
            }
            if !app.keyboards.firstMatch.exists { field.tap() }
            XCTAssertTrue(waitUntil(3) { self.app.keyboards.firstMatch.exists }, file: file, line: line)
            field.typeText(text)
            _ = waitUntil(3) { self.fieldText == text }
        }
        XCTAssertEqual(fieldText, text, "The search field's text", file: file, line: line)
    }

    /// The query as typed; empty, not the placeholder, when there's none.
    private var fieldText: String {
        guard field.exists else { return "<no field>" }
        let value = field.value as? String ?? ""
        return value == field.placeholderValue ? "" : value
    }

    /// Waits for a result, and on failure says what the field held and
    /// what was on screen.
    private func expect(
        _ target: XCUIElement,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard !target.waitForExistence(timeout: timeout) else { return }
        shot("missing-result")
        let texts = app.staticTexts.allElementsBoundByIndex.map(\.label)
        let buttons = app.buttons.allElementsBoundByIndex.map { $0.identifier.isEmpty ? $0.label : $0.identifier }
        XCTFail(
            "Not found: \(target). Field: \"\(fieldText)\". Texts: \(texts). Buttons: \(buttons)",
            file: file,
            line: line
        )
    }

    private func dismissKeyboard() {
        app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] 'search'")).firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
    }

    private func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    private func scrollTo(_ target: XCUIElement) {
        // A drag from mid-screen: the scroll view's own centre is on the
        // keyboard's top edge, where a swipe scrolls nothing.
        let window = app.windows.firstMatch
        for _ in 0..<12 where !(target.exists && target.isHittable) {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        }
        XCTAssertTrue(target.isHittable, "\(target)")
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
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
