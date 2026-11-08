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
        ("outOfReach", "Sam, Last day. You 1,700 points. Sam 2,171 points. Sam leads by 471."),
    ]

    private let chaseMatches: [(scenario: String, label: String)] = [
        ("trailing", "55 points to take the lead. 200 of 255 today."),
        ("outOfReach", "Out of reach today."),
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

    func testTheChaseIsSpoken() {
        for (scenario, label) in chaseMatches {
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

        // Half a turn or less snaps back; a full turn pages twice.
        XCUIDevice.shared.rotateDigitalCrown(delta: 0.75)
        sleep(2)
        XCTAssertEqual(hittable().count, 1)
        XCTAssertTrue(hittable()[0].label.hasPrefix("Alex, Day 2 of 7."), hittable()[0].label)
    }

    /// The default face's bottom slot reads the file the app just wrote. The
    /// other shapes need a face with their slots, so they're checked by eye.
    func testComplicationOnTheFace() {
        XCTAssertTrue(element(launch("live"), "watch.match").waitForExistence(timeout: 15))
        let face = XCUIApplication(bundleIdentifier: "com.apple.Carousel")
        XCUIDevice.shared.press(.home)  // Home toggles face and app grid: never press it twice.
        sleep(3)
        face.press(forDuration: 2)
        sleep(3)
        face.buttons["Edit"].firstMatch.tap()
        sleep(3)
        face.swipeLeft()
        sleep(2)
        face.swipeLeft()
        sleep(2)
        let bottom = face.buttons["Bottom complication"].firstMatch
        if (bottom.value as? String)?.contains("HealthComp") != true {
            bottom.tap()
            sleep(3)
            let ours = face.cells["AppGroupCell -- HealthComp"]
            for _ in 0..<14 where !(ours.exists && ours.isHittable) {
                face.swipeUp()
                sleep(1)
            }
            XCTAssertTrue(ours.exists, "HealthComp is not in the picker")
            ours.tap()
            sleep(3)
            face.cells["ComplicationListCell -- Match"].firstMatch.tap()
            sleep(3)
        }
        XCTAssertEqual(face.descendants(matching: .any)["bottom-center"].firstMatch.label, "HealthComp")
        let score = face.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '54'")).firstMatch
        XCTAssertTrue(score.waitForExistence(timeout: 10), face.debugDescription)
        XCUIDevice.shared.press(.home)
    }
}
