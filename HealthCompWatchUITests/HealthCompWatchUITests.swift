import XCTest

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

    func testGroupMatchesAndGroupWeek() {
        for (scenario, label) in [
            ("groupFFA", "Four-Way, Day 4 of 7. You're 2nd. 48 behind Sam. 1st, Sam, 1,712 points. "
                + "2nd, You, 1,664 points. 3rd, Priya, 1,498 points. 4th, Leo, 1,203 points."),
            ("groupDoubles", "Doubles, Day 4 of 7. Your team 3,162 points. Sam + Leo 2,915 points. Your team up 247."),
        ] {
            let app = launch(scenario)
            let match = element(app, "watch.match")
            XCTAssertTrue(match.waitForExistence(timeout: 15), scenario)
            XCTAssertEqual(match.label, label)
            shoot(app, "watch-\(scenario)")
        }

        let groupWeek = launch("groupFFA", "--watch-page", "week")
        XCTAssertTrue(element(groupWeek, "watch.week").waitForExistence(timeout: 15))
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

    private func rows(_ app: XCUIApplication) -> [String] {
        app.descendants(matching: .any).matching(identifier: "watch.card.row").allElementsBoundByIndex.map(\.label)
    }

    private func row(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'watch.card.row' AND label BEGINSWITH %@", prefix))
            .firstMatch
    }

    private func openMatches(_ app: XCUIApplication) {
        let button = element(app, "watch.matches.button")
        if button.waitForExistence(timeout: 5), button.isHittable {
            button.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.14)).tap()
        }
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testMultiMatchLaunchesOnFeaturedAndSwitchesViaMatchesList() {
        let app = launch("card")
        let featured = element(app, "watch.match")
        XCTAssertTrue(featured.waitForExistence(timeout: 15))
        XCTAssertTrue(featured.label.hasPrefix("Sam, Day 5 of 7."), featured.label)
        XCTAssertTrue(element(app, "watch.matches.button").waitForExistence(timeout: 5))
        shoot(app, "watch-featured")

        openMatches(app)
        XCTAssertTrue(element(app, "watch.card").waitForExistence(timeout: 5))
        XCTAssertEqual(rows(app), [
            "You lead Sam by 54 points. Day 5.",
            "Four-Way, Day 4 of 7. You're 2nd. 48 behind Sam.",
            "Robin leads by 371 points. 372 points to take the lead. 31 of 403 today.",
            "Riley leads by 19 points. Pending.",
            "Jo, Final.",
        ])
        shoot(app, "watch-card")

        app.swipeUp()
        sleep(1)
        let jo = row(app, "Jo")
        XCTAssertTrue(jo.waitForExistence(timeout: 5))
        jo.tap()
        let board = element(app, "watch.match")
        XCTAssertTrue(board.waitForExistence(timeout: 5))
        XCTAssertTrue(board.label.hasPrefix("Jo, Final."), board.label)
        sleep(4)

        openMatches(app)
        XCTAssertTrue(element(app, "watch.card").waitForExistence(timeout: 5))
        app.swipeUp()
        sleep(1)
        XCTAssertTrue(row(app, "Jo").label.contains("Won by 114 points."), row(app, "Jo").label)
    }

    func testVerticalPagesShowTodayRingsWeekChartAndRivalry() {
        let todayApp = launch("trailing", "--watch-page", "today")
        let today = element(todayApp, "watch.today")
        XCTAssertTrue(today.waitForExistence(timeout: 15))
        XCTAssertTrue(today.label.contains("165 kcal"), today.label)
        shoot(todayApp, "watch-today-chase")

        let weekApp = launch("trailing", "--watch-page", "week")
        let week = element(weekApp, "watch.week")
        XCTAssertTrue(week.waitForExistence(timeout: 15))
        let first = weekApp.descendants(matching: .any)
            .matching(NSPredicate(format: "label ENDSWITH '. You 200. Sam 220.'")).firstMatch
        XCTAssertTrue(first.exists, weekApp.debugDescription)
        let empty = weekApp.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH '. No points.'"))
        XCTAssertEqual(empty.count, 4)
        shoot(weekApp, "watch-week")

        let rivalryApp = launch("beltLive", "--watch-page", "rivalry")
        let rivalry = element(rivalryApp, "watch.rivalry")
        XCTAssertTrue(rivalry.waitForExistence(timeout: 15))
        XCTAssertTrue(rivalry.label.contains("4 wins, 2 losses"), rivalry.label)
        XCTAssertTrue(rivalry.label.contains("You hold the belt, 2 defenses."), rivalry.label)
        shoot(rivalryApp, "watch-rivalry")
    }

    func testSwipingUpPagesThroughVerticalTabs() {
        let app = launch("beltLive")
        XCTAssertTrue(element(app, "watch.match").waitForExistence(timeout: 15))

        app.swipeUp()
        XCTAssertTrue(element(app, "watch.today").waitForExistence(timeout: 5))

        app.swipeUp()
        XCTAssertTrue(element(app, "watch.week").waitForExistence(timeout: 5))

        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(element(app, "watch.rivalry").waitForExistence(timeout: 5))
    }

    func testSleepCustomMetricsAreSpokenAndRendered() {
        let app = launch("sleepMatch")
        let match = element(app, "watch.match")
        XCTAssertTrue(match.waitForExistence(timeout: 15))
        XCTAssertTrue(match.label.contains("Metrics: Move, Exercise, Stand, Sleep."), match.label)
        shoot(app, "watch-sleep-overview")

        let todayApp = launch("sleepMatch", "--watch-page", "today")
        let today = element(todayApp, "watch.today")
        XCTAssertTrue(today.waitForExistence(timeout: 15))
        XCTAssertTrue(today.label.contains("7h 48m"), today.label)
        shoot(todayApp, "watch-sleep-today")
    }

    func testOneMatchHidesMatchesButton() {
        let app = launch("live")
        XCTAssertTrue(element(app, "watch.match").waitForExistence(timeout: 15))
        XCTAssertFalse(element(app, "watch.matches.button").exists)
        XCTAssertFalse(element(app, "watch.card").exists)
    }

    func testATappedAlertOpensItsMatch() {
        let app = launch("card", "--watch-alert", "00000000-0000-0000-0000-000000000013")
        let board = element(app, "watch.match")
        XCTAssertTrue(board.waitForExistence(timeout: 15))
        XCTAssertTrue(board.label.hasPrefix("Robin, Day 3 of 7."), board.label)
        openMatches(app)
        XCTAssertTrue(element(app, "watch.card").waitForExistence(timeout: 5))
    }

    func testComplicationOnTheFace() throws {
        XCTAssertTrue(element(launch("live"), "watch.match").waitForExistence(timeout: 15))
        let face = XCUIApplication(bundleIdentifier: "com.apple.Carousel")
        XCUIDevice.shared.press(.home)
        sleep(3)
        let complicationSlot = face.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'complication'")).firstMatch
        var foundSlot = false
        for faceIndex in 0..<3 {
            face.press(forDuration: 2)
            sleep(2)
            if faceIndex > 0 {
                face.swipeLeft()
                sleep(2)
            }
            let edit = face.buttons["Edit"].firstMatch
            if edit.waitForExistence(timeout: 5) {
                edit.tap()
                sleep(2)
                for _ in 0..<3 {
                    if complicationSlot.exists {
                        foundSlot = true
                        break
                    }
                    face.swipeLeft()
                    sleep(2)
                }
            }
            if foundSlot { break }
            XCUIDevice.shared.press(.home)
            sleep(2)
        }
        guard foundSlot else {
            throw XCTSkip("No watch face with complication slots is configured on this Simulator.")
        }
        if (complicationSlot.value as? String)?.contains("HealthComp") != true {
            complicationSlot.tap()
            sleep(3)
            let ours = face.cells["AppGroupCell -- HealthComp"]
            for _ in 0..<14 {
                if ours.exists && ours.isHittable { break }
                face.swipeUp()
                sleep(1)
            }
            XCTAssertTrue(ours.exists, "HealthComp is not in the picker")
            ours.tap()
            sleep(3)
            face.cells["ComplicationListCell -- Match"].firstMatch.tap()
            sleep(3)
        }
        XCUIDevice.shared.press(.home)
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(2)
        let score = face.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '54'")).firstMatch
        XCTAssertTrue(score.waitForExistence(timeout: 10), face.debugDescription)
    }
}
