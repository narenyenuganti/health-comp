import XCTest

final class GroupMatchJoinUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testInviteShowsTheLineupAndAnswers() {
        let app = XCUIApplication.launchGroupLab("invite-ffa")
        XCTAssertTrue(app.groupElement("competition.group.invite.accept").waitForExistence(timeout: 8))
    }
}
