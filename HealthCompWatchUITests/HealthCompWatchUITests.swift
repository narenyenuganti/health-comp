import XCTest

/// Runs on the Mac mini, not CI. `--watch-scenario` needs no phone: one
/// simulator, no WatchConnectivity.
final class HealthCompWatchUITests: XCTestCase {
    private func launch(_ scenario: String, _ arguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--watch-scenario", scenario] + arguments
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private let matches: [(scenario: String, label: String)] = [
        ("live", "Sam, Day 5 of 7. You 1,204 points. Sam 1,150 points. You lead by 54."),
        ("trailing", "Sam, Day 3 of 7. You 610 points. Sam 664 points. Sam leads by 54."),
        ("square", "Sam, Day 2 of 7. You 480 points. Sam 480 points. All square."),
        ("lastDay", "Sam, Last day. You 2,190 points. Sam 2,171 points. You lead by 19."),
        ("pending", "Sam, Final score pending. You 2,190 points. Sam 2,171 points. You lead by 19."),
        ("won", "Sam, Final. You 1,840 points. Sam 1,726 points. Won by 114 points."),
        ("lost", "Sam, Final. You 1,700 points. Sam 1,720 points. Lost by 20 points."),
        ("tied", "Sam, Final. You 1,650 points. Sam 1,650 points. Tied."),
        ("closeFinal", "Sam, Final. You 1,840.25 points. Sam 1,840.40 points. Lost by 0.15 points."),
        ("scheduled", "Sam, Day 1 is"),
        ("longName", "Maximiliana Featherstonehaugh-Worthington, Day 5 of 7. You 12,045 points. "
            + "Maximiliana Featherstonehaugh-Worthington 11,980 points. You lead by 65."),
        ("former", "Former competitor, Final. You 1,840 points. Former competitor 1,726 points. Won by 114 points."),
        ("noData", "Sam, Day 4 of 7. You 742 points. Sam 510 points. You lead by 232."),
        ("stale", "Sam, Day 5 of 7. You 1,204 points. Sam 1,150 points. You lead by 54. Updated"),
        ("samGone", "Alex, Day 2 of 7. You 480 points. Alex 455 points. You lead by 25."),
        ("noSam", "Alex, Day 2 of 7. You 480 points. Alex 455 points. You lead by 25."),
    ]

    private let beltMatches: [(scenario: String, label: String)] = [
        ("beltLive", "You hold the belt, 2 defenses."),
        ("beltTrailing", "Sam holds the belt, 1 defense."),
        ("beltTaken", "You hold the belt."),
        ("beltLost", "Sam holds the belt."),
        ("beltDefended", "You hold the belt, 3 defenses."),
    ]

    private let nothing: [(scenario: String, label: String)] = [
        ("empty", "Nothing live right now"),
        ("challenge", "Nothing live right now. A challenge is waiting."),
        ("none", "HealthComp. Open HealthComp on iPhone."),
    ]

    func testEveryMatchState() {
        for (scenario, label) in matches {
            let match = element(launch(scenario), "watch.match")
            XCTAssertTrue(match.waitForExistence(timeout: 15), scenario)
            XCTAssertTrue(match.label.hasPrefix(label), "\(scenario): \(match.label)")
        }
    }

    func testTheBeltIsSpoken() {
        for (scenario, label) in beltMatches {
            let match = element(launch(scenario), "watch.match")
            XCTAssertTrue(match.waitForExistence(timeout: 15), scenario)
            XCTAssertTrue(match.label.contains(label), "\(scenario): \(match.label)")
        }
    }

    func testNothingToShow() {
        for (scenario, label) in nothing {
            let empty = element(launch(scenario), "watch.empty")
            XCTAssertTrue(empty.waitForExistence(timeout: 15), scenario)
            XCTAssertEqual(empty.label, label, scenario)
        }
    }

    /// Crown pages between people, and exactly one page is on screen.
    func testCrownMovesBetweenMatches() {
        let app = launch("several")
        let match = element(app, "watch.match")
        XCTAssertTrue(match.waitForExistence(timeout: 15))
        let pages = app.descendants(matching: .any).matching(identifier: "watch.match")
        func hittable() -> [XCUIElement] {
            pages.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        }
        XCTAssertEqual(hittable().count, 1)
        XCTAssertTrue(hittable()[0].label.hasPrefix("Sam, Day 5 of 7."), hittable()[0].label)

        XCUIDevice.shared.rotateDigitalCrown(delta: 0.3)
        sleep(2)
        XCTAssertEqual(hittable().count, 1)
        XCTAssertTrue(hittable()[0].label.hasPrefix("Alex, Day 2 of 7."), hittable()[0].label)
    }
}
