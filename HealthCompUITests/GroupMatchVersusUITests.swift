import XCTest

/// The group versus intro over a scheduled match, held with `--versus-hold`
/// (Reduce Motion shows it composed), and again from the live ••• menu.
final class GroupMatchVersusUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static let hold = ["--versus-intro", "--versus-hold"]

    /// By label: the lab root's identifier replaces any id on the overlay.
    private func intro(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func testFreeForAllIntroShowsTheLineupThenTheMatch() {
        let app = XCUIApplication.launchGroupLab("versus-ffa", arguments: Self.hold)
        let intro = intro(app, "Four-Way. ")
        XCTAssertTrue(intro.waitForExistence(timeout: 8))
        XCTAssertEqual(
            intro.label,
            "Four-Way. You, Sam, Priya, and Leo. Day 1 is Thursday. Most points after seven days wins."
        )
        shot(app, "VersusFFA")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.groupElement("competition.group.status").waitForExistence(timeout: 8))
        XCTAssertFalse(intro.waitForExistence(timeout: 2))
    }

    func testDoublesIntroPutsYourTeamFirst() {
        let app = XCUIApplication.launchGroupLab("versus-doubles", arguments: Self.hold)
        let intro = intro(app, "Doubles. ")
        XCTAssertTrue(intro.waitForExistence(timeout: 8))
        XCTAssertEqual(
            intro.label,
            "Doubles. You and Priya versus Sam and Leo. Day 1 is Thursday. Partners’ points add up."
        )
        shot(app, "VersusDoubles")
    }

    func testPhotosAndABot() {
        for (setup, prefix) in [("versus-ffa-photos", "Four-Way. "), ("versus-doubles-photos", "Doubles. "),
                                ("versus-bot", "Four-Way. ")] {
            let app = XCUIApplication.launchGroupLab(setup, arguments: Self.hold)
            XCTAssertTrue(intro(app, prefix).waitForExistence(timeout: 8), setup)
            shot(app, setup)
            app.terminate()
        }
    }

    func testIntroAtTheLargestTextSizeInDark() {
        let app = XCUIApplication.launchGroupLab("versus-ffa", arguments: Self.hold + [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-AppleInterfaceStyle", "Dark",
        ])
        XCTAssertTrue(intro(app, "Four-Way. ").waitForExistence(timeout: 8))
        shot(app, "VersusFFA-ax5-dark")
    }

    func testReplaysFromTheMenuOnALaterDay() {
        let app = XCUIApplication.launchGroupLab("live-ffa", arguments: Self.hold)
        XCTAssertTrue(app.groupElement("competition.group.standings").waitForExistence(timeout: 8))
        // Day 4: no autoplay.
        XCTAssertFalse(intro(app, "Four-Way. ").waitForExistence(timeout: 2))
        // The wrapper, as iOS 18 exposes it.
        app.groupElement("competition.more").tap()
        let replay = app.buttons["competition.versus.replay"]
        XCTAssertTrue(replay.waitForExistence(timeout: 3))
        replay.tap()
        let intro = intro(app, "Four-Way. ")
        XCTAssertTrue(intro.waitForExistence(timeout: 5))
        XCTAssertTrue(intro.label.hasSuffix("Day 4 of 7. Most points after seven days wins."), intro.label)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
