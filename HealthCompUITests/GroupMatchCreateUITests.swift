import XCTest

final class GroupMatchCreateUITests: XCTestCase {
    private static let priya = "c2000000-0000-4000-8000-000000000003"
    private static let leo = "c2000000-0000-4000-8000-000000000004"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFormatPickerOffersEveryFormat() {
        let app = XCUIApplication.launchGroupLab("format-picker")
        XCTAssertTrue(app.groupElement("competition.group.format.doubles").waitForExistence(timeout: 8))
        for format in ["duel", "three-way", "four-way"] {
            XCTAssertTrue(app.buttons["competition.group.format.\(format)"].exists, format)
        }
        XCTAssertTrue(app.buttons["competition.group.format.duel"].isSelected)
        app.buttons["competition.group.format.four-way"].tap()
        XCTAssertTrue(app.buttons["competition.group.format.four-way"].isSelected)
        shot(app, "Main-four-way")
        app.buttons["competition.group.choose-players"].tap()
        XCTAssertTrue(app.navigationBars["Four-Way"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.groupElement("competition.group.seat.4").exists)
    }

    func testFourWayLineupFillsSeatsAndDropsToThreeWay() {
        let app = XCUIApplication.launchGroupLab("lineup-ffa")
        let create = app.buttons["competition.group.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 8))
        XCTAssertFalse(create.isEnabled, "Two seats are still empty.")
        XCTAssertTrue(app.staticTexts["PLAYERS · 2 OF 4"].exists)
        shot(app, "LineupFFA-two-of-four")

        app.buttons["competition.group.person.\(Self.priya).add"].tap()
        XCTAssertTrue(app.groupElement("competition.group.seat.3").label.contains("Priya"))
        XCTAssertFalse(app.buttons["competition.group.person.\(Self.priya).add"].exists)
        app.buttons["competition.group.seat.4.remove"].tap()
        XCTAssertTrue(app.navigationBars["Three-Way"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.groupElement("competition.group.seat.4").exists)
        XCTAssertTrue(app.staticTexts["PLAYERS · 3 OF 3"].exists)
        XCTAssertFalse(app.buttons["competition.group.seat.3.remove"].label.contains("seat"))
        XCTAssertTrue(create.isEnabled)
        shot(app, "LineupFFA-three-way")

        // Back and forward keeps the three-way.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["competition.group.format.three-way"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["competition.group.format.three-way"].isSelected)
        app.buttons["competition.group.choose-players"].tap()
        XCTAssertTrue(app.navigationBars["Three-Way"].waitForExistence(timeout: 4))
        XCTAssertTrue(create.isEnabled)
        create.tap()
    }

    func testPastedChallengeLinkAddsThatPerson() {
        let app = XCUIApplication.launchGroupLab("lineup-ffa")
        let paste = app.buttons["competition.group.paste-link"]
        XCTAssertTrue(paste.waitForExistence(timeout: 8))
        paste.tap()
        let field = app.groupElement("competition.group.link.field")
        let find = app.buttons["competition.group.link.find"]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        XCTAssertFalse(find.isEnabled)

        field.tap()
        field.typeText("sam")
        find.tap()
        XCTAssertTrue(app.staticTexts["That isn’t a full challenge link. Ask them to share it again."].exists)

        replace(field, with: "healthcomp://challenge/Zz9yX8wV7uT6sR5qP4oN3m")
        find.tap()
        XCTAssertTrue(app.staticTexts["No account has this link. Check it and try again."].waitForExistence(timeout: 4))

        replace(field, with: "Ux0aB1cD2eF3gH4iJ5kL6m")
        find.tap()
        XCTAssertTrue(app.staticTexts["You can’t add this person to a match."].waitForExistence(timeout: 4))
        shot(app, "PasteLink-unavailable")

        replace(field, with: "Mx7kQ2pL9vR4tN8wB3cY6z")
        find.tap()
        shot(app, "PasteLink-resolving")
        let add = app.buttons["competition.group.link.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 4))
        XCTAssertEqual(app.groupElement("competition.group.link.found").label, "Maya, Found")
        shot(app, "PasteLink-found")
        add.tap()
        XCTAssertTrue(app.navigationBars["Four-Way"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.groupElement("competition.group.seat.3").label.contains("Maya"))
        shot(app, "LineupFFA-pasted-link")
    }

    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80) + text)
    }

    func testDoublesLineupPutsEachPlayerOnAChosenTeam() {
        let app = XCUIApplication.launchGroupLab("lineup-doubles")
        XCTAssertTrue(app.staticTexts["YOUR TEAM"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["THEIR TEAM"].exists)
        XCTAssertTrue(app.groupElement("competition.group.seat.2").label.contains("Priya"))
        XCTAssertFalse(app.buttons["competition.group.create"].isEnabled)
        shot(app, "LineupDoubles-one-empty")

        // Only their team has room, so Leo goes straight there.
        app.buttons["competition.group.person.\(Self.leo).add"].tap()
        XCTAssertTrue(app.groupElement("competition.group.seat.4").label.contains("Leo"))
        XCTAssertTrue(app.buttons["competition.group.create"].isEnabled)

        // With room on both teams, you pick the team.
        app.buttons["competition.group.seat.2.remove"].tap()
        app.buttons["competition.group.seat.3.remove"].tap()
        app.buttons["competition.group.person.\(Self.priya).add"].tap()
        let theirs = app.buttons["Their Team"]
        XCTAssertTrue(theirs.waitForExistence(timeout: 4))
        theirs.tap()
        // The dialog places the seat once it has finished closing.
        let placed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS 'Priya'"),
            object: app.groupElement("competition.group.seat.3")
        )
        XCTAssertEqual(XCTWaiter().wait(for: [placed], timeout: 4), .completed)
        XCTAssertTrue(app.groupElement("competition.group.seat.2").label.contains("Empty seat"))
    }

    func testBotPickerAddsTheChosenBot() {
        let app = XCUIApplication.launchGroupLab("bot-picker")
        XCTAssertTrue(app.buttons["competition.group.bot.pacer"].waitForExistence(timeout: 8))
        for mode in ["chill", "erratic", "beast"] {
            XCTAssertTrue(app.buttons["competition.group.bot.\(mode)"].exists, mode)
        }
        app.buttons["competition.group.bot.erratic"].tap()
        let add = app.buttons["competition.group.bot.add"]
        XCTAssertEqual(add.label, "Add Erratic")
        shot(app, "BotPicker-erratic")
        add.tap()
        XCTAssertTrue(app.navigationBars["Four-Way"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.groupElement("competition.group.seat.3").label.contains("Erratic"))
    }

    func testLineupFitsTheLargestTextInDark() throws {
        let app = XCUIApplication.launchGroupLab("lineup-doubles", dark: true, largestText: true)
        XCTAssertTrue(app.buttons["competition.group.create"].waitForExistence(timeout: 8))
        shot(app, "LineupDoubles-dark-ax5")
        try app.performAccessibilityAudit(for: [.textClipped, .hitRegion, .sufficientElementDescription])
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
