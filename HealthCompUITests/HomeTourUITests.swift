import XCTest

final class HomeTourUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testNewAccountTourWalksEveryStopAndReplaysFromAccount() {
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", "friends",
            "-healthcomp.colorHintSeen", "YES",
            "-tourLab", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        let title = app.staticTexts["tour.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "The logo is a button")
        XCTAssertTrue(app.staticTexts["TOUR · 1 OF 6"].exists)

        app.buttons["tour.match"].tap()
        XCTAssertEqual(title.label, "The logo is a button", "Only the highlighted stop advances")

        app.buttons["tour.logo"].tap()
        let rings = app.otherElements["home.todayRings"]
        XCTAssertTrue(rings.waitForExistence(timeout: 5))
        XCTAssertTrue(rings.label.hasSuffix("199 points of 600 today."), rings.label)
        rings.swipeDown(velocity: .fast)
        XCTAssertTrue(rings.waitForNonExistence(timeout: 5))

        let stops = [
            ("tour.match", "This is a match"),
            ("tour.challenge", "Start a match"),
            ("tour.friends", "Find your friends"),
            ("tour.history", "Every result is kept"),
            ("tour.account", "This is you"),
        ]
        for (stop, expected) in stops {
            XCTAssertTrue(waitUntil { title.label == expected }, "\(expected), got \(title.label)")
            let button = app.buttons[stop]
            XCTAssertTrue(button.isHittable, stop)
            button.tap()
        }
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))

        let account = app.buttons["app.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        let replay = app.buttons["account.tour"]
        XCTAssertTrue(app.buttons["account.health"].waitForExistence(timeout: 5))
        for _ in 0..<4 where !(replay.exists && replay.isHittable) { app.swipeUp() }
        XCTAssertTrue(replay.isHittable)
        replay.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "The logo is a button")
        app.buttons["tour.skip"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertTrue(replay.exists)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
