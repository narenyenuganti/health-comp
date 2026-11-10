import XCTest

final class GroupMatchJoinUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testInviteShowsTheLineupAndAnswers() {
        let app = XCUIApplication.launchGroupLab("invite-ffa")
        XCTAssertTrue(app.groupElement("competition.group.invite.accept").waitForExistence(timeout: 8))
        XCTAssertTrue(app.groupElement("competition.group.invite.lineup").exists)
        XCTAssertEqual(app.groupElement("competition.group.invite.seat.1").label, "Sam, Host")
        XCTAssertEqual(app.groupElement("competition.group.invite.seat.2").label, "Priya, In")
        XCTAssertEqual(app.groupElement("competition.group.invite.seat.3").label, "Leo, Invited")
        XCTAssertEqual(app.groupElement("competition.group.invite.seat.4").label, "You, Your seat")
        XCTAssertTrue(app.buttons["competition.group.invite.not-now"].exists)
        shot(app, "Invite-four-way")
        app.buttons["competition.group.invite.decline"].tap()
        XCTAssertTrue(app.buttons["Decline Match"].waitForExistence(timeout: 4))
    }

    func testHostLobbyWaitsForEverySeat() {
        let app = XCUIApplication.launchGroupLab("lobby-host")
        XCTAssertTrue(app.buttons["competition.group.lobby.cancel"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["competition.group.lobby.share"].exists)
        XCTAssertTrue(app.groupElement("competition.group.lobby.status").label.uppercased().hasPrefix("WAITING FOR 2"))
        XCTAssertTrue(app.staticTexts["Starts once every seat has accepted."].exists)
        XCTAssertEqual(app.groupElement("competition.group.lobby.seat.2").label, "Sam, In")
        XCTAssertEqual(app.groupElement("competition.group.lobby.seat.3").label, "Priya, Invited")
        XCTAssertFalse(app.buttons["competition.group.lobby.withdraw"].exists)
        shot(app, "Lobby-host")
        app.buttons["competition.group.lobby.cancel"].tap()
        XCTAssertTrue(app.buttons["Cancel Match"].waitForExistence(timeout: 4))
    }

    func testAcceptedInviteeLobbyOffersOnlyWithdraw() {
        let app = XCUIApplication.launchGroupLab("lobby-invitee")
        XCTAssertTrue(app.buttons["competition.group.lobby.withdraw"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["competition.group.lobby.share"].exists)
        XCTAssertFalse(app.buttons["competition.group.lobby.cancel"].exists)
        XCTAssertEqual(app.groupElement("competition.group.lobby.seat.4").label, "Leo, Invited")
        shot(app, "Lobby-invitee")
    }

    func testScheduledLobbyKeepsCancelAndWithdrawUntilDayOne() {
        var app = XCUIApplication.launchGroupLab("lobby-scheduled")
        let cancel = app.buttons["competition.group.lobby.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        let status = app.groupElement("competition.group.lobby.status").label.uppercased()
        XCTAssertTrue(status.hasPrefix("EVERYONE’S IN"), status)
        XCTAssertTrue(status.contains("STARTS MON, AUG 17"), status)
        XCTAssertEqual(app.groupElement("competition.group.lobby.seat.3").label, "Priya, In")
        XCTAssertEqual(app.groupElement("competition.group.lobby.seat.4").label, "Leo, In")
        XCTAssertFalse(app.buttons["competition.group.lobby.share"].exists)
        XCTAssertFalse(app.buttons["competition.group.lobby.withdraw"].exists)
        XCTAssertFalse(app.groupElement("competition.group.standings").exists, "Live views wait for Day 1.")
        shot(app, "Lobby-scheduled-host")
        cancel.tap()
        XCTAssertTrue(app.staticTexts["Cancel this match?"].waitForExistence(timeout: 4))
        app.terminate()

        app = XCUIApplication.launchGroupLab("lobby-scheduled-invitee")
        let withdraw = app.buttons["competition.group.lobby.withdraw"]
        XCTAssertTrue(withdraw.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["competition.group.lobby.cancel"].exists)
        XCTAssertTrue(app.staticTexts["Until Day 1, you can still withdraw."].exists)
        shot(app, "Lobby-scheduled-invitee")
        withdraw.tap()
        XCTAssertTrue(app.staticTexts["Withdraw from this match?"].waitForExistence(timeout: 4))
    }

    func testWithdrawalNamesWhoWithdrew() {
        let app = XCUIApplication.launchGroupLab("lobby-withdrew")
        XCTAssertTrue(app.staticTexts["One seat short"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.groupElement("competition.group.lobby.seat.2").label, "Sam, Withdrew")
        XCTAssertEqual(app.groupElement("competition.group.lobby.seat.4").label, "Leo, In")
        let detail = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Sam withdrew, so this match didn’t start."))
        XCTAssertTrue(detail.firstMatch.exists)
        XCTAssertTrue(app.buttons["competition.group.lobby.new-match"].exists)
        shot(app, "LobbyShort-withdrew")
    }

    func testDidNotStartOffersTheHostANewMatch() {
        let app = XCUIApplication.launchGroupLab("lobby-expired")
        XCTAssertTrue(app.staticTexts["One seat short"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.groupElement("competition.group.lobby.seat.4").label, "Leo, No answer")
        XCTAssertTrue(app.buttons["competition.group.lobby.done"].exists)
        shot(app, "LobbyShort-host")
        app.buttons["competition.group.lobby.new-match"].tap()
        XCTAssertTrue(app.buttons["competition.group.format.doubles"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["competition.group.format.doubles"].isSelected)
        app.buttons["competition.group.choose-players"].tap()
        XCTAssertTrue(app.groupElement("competition.group.seat.4").waitForExistence(timeout: 4))
        XCTAssertTrue(app.groupElement("competition.group.seat.4").label.contains("Leo"))
        shot(app, "LobbyShort-new-match")
    }

    func testDidNotStartNamesEveryMissingSeat() {
        let app = XCUIApplication.launchGroupLab("lobby-declined")
        XCTAssertTrue(app.staticTexts["Two seats short"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.groupElement("competition.group.lobby.seat.3").label, "Priya, Declined")
        shot(app, "LobbyShort-declined")
    }

    func testDidNotStartGivesOthersDone() {
        let app = XCUIApplication.launchGroupLab("lobby-short-invitee")
        XCTAssertTrue(app.buttons["competition.group.lobby.done"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["competition.group.lobby.new-match"].exists)
        XCTAssertTrue(app.staticTexts["Leo didn’t accept, so this match didn’t start."].exists)
        shot(app, "LobbyShort-invitee")
    }

    func testInviteFitsTheLargestTextInDark() throws {
        let app = XCUIApplication.launchGroupLab("invite-ffa", dark: true, largestText: true)
        XCTAssertTrue(app.groupElement("competition.group.invite.lineup").waitForExistence(timeout: 8))
        shot(app, "Invite-dark-ax5")
        try app.performAccessibilityAudit(for: [.textClipped, .hitRegion, .sufficientElementDescription])
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
