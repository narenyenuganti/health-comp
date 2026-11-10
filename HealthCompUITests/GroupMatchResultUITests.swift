import XCTest

final class GroupMatchResultUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTiedResultSaysNoBelt() {
        let app = XCUIApplication.launchGroupLab("result-ffa-tied")
        XCTAssertTrue(app.groupElement("competition.group.result.no-belt").waitForExistence(timeout: 8))
    }

    func testFreeForAllResultShowsSharedPlacesAndRematch() {
        var app = XCUIApplication.launchGroupLab("result-ffa-won")
        XCTAssertTrue(app.groupElement("competition.group.result.title").waitForExistence(timeout: 8))
        XCTAssertEqual(app.groupElement("competition.group.result.title").label, "You won")
        XCTAssertEqual(
            app.groupElement("competition.group.result.summary").label,
            "By 38 over Sam. You won 4 days."
        )
        XCTAssertTrue(app.groupElement("competition.group.result.row.1").label.hasPrefix("1st, You"))
        XCTAssertTrue(app.groupElement("competition.group.result.row.4").label.hasPrefix("4th, Leo"))
        // Rematch Everyone opens New Match on the same format; nothing is sent yet.
        app.buttons["competition.group.result.rematch"].tap()
        XCTAssertTrue(app.groupElement("competition.group.format.four-way").waitForExistence(timeout: 4))

        app.terminate()
        app = XCUIApplication.launchGroupLab("result-ffa-tied")
        XCTAssertTrue(app.groupElement("competition.group.result.title").waitForExistence(timeout: 8))
        XCTAssertEqual(app.groupElement("competition.group.result.title").label, "Tied for 1st")
        let places = (1...4).map { app.groupElement("competition.group.result.row.\($0)").label }
        XCTAssertTrue(places[0].hasPrefix("1st, tied"), places[0])
        XCTAssertTrue(places[1].hasPrefix("1st, tied"), places[1])
        XCTAssertTrue(places[2].hasPrefix("3rd, Priya"), places[2])

        // A tie across the podium's edge lists every place the same way.
        app.terminate()
        app = XCUIApplication.launchGroupLab("result-ffa-tied-third")
        XCTAssertTrue(app.groupElement("competition.group.result.title").waitForExistence(timeout: 8))
        XCTAssertEqual(app.groupElement("competition.group.result.title").label, "Tied for 3rd")
        XCTAssertTrue(app.groupElement("competition.group.result.row.4").label.hasPrefix("3rd, tied"))
    }

    func testDoublesResultShowsTeamsTiesAndWhoCarried() {
        var app = XCUIApplication.launchGroupLab("result-doubles")
        XCTAssertTrue(app.groupElement("competition.group.result.title").waitForExistence(timeout: 8))
        XCTAssertEqual(app.groupElement("competition.group.result.title").label, "Your team won")
        XCTAssertTrue(app.groupElement("competition.group.result.team.yours").label.contains("You and Priya"))
        XCTAssertTrue(app.groupElement("competition.group.result.carry.yours").label.contains("53 percent"))
        XCTAssertTrue(app.groupElement("competition.group.result.carry.theirs").label.hasPrefix("Sam"))
        XCTAssertTrue(app.groupElement("competition.group.result.no-belt").exists)

        app.terminate()
        app = XCUIApplication.launchGroupLab("result-doubles-tied")
        XCTAssertTrue(app.groupElement("competition.group.result.title").waitForExistence(timeout: 8))
        XCTAssertEqual(app.groupElement("competition.group.result.title").label, "Tied")
        XCTAssertTrue(app.groupElement("competition.group.result.team.theirs").label.hasPrefix("1st"))
    }
}
