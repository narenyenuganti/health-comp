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

    /// A group match: the standings, never a belt.
    func testGroupMatches() {
        for (scenario, label) in [
            ("groupFFA", "Four-Way, Day 4 of 7. You're 2nd. 48 behind Sam."),
            ("groupDoubles", "Doubles, Day 4 of 7. Your team 3,162 points. Sam + Leo 2,915 points. Your team up 247."),
        ] {
            let app = launch(scenario)
            let match = element(app, "watch.match")
            XCTAssertTrue(match.waitForExistence(timeout: 15), scenario)
            XCTAssertEqual(match.label, label)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "watch-\(scenario)"
            shot.lifetime = .keepAlways
            add(shot)
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

    private func rows(_ app: XCUIApplication) -> [String] {
        app.descendants(matching: .any).matching(identifier: "watch.card.row").allElementsBoundByIndex.map(\.label)
    }

    private func row(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'watch.card.row' AND label BEGINSWITH %@", prefix))
            .firstMatch
    }

    /// The back button on screen. By query, the first match can be the one
    /// under a pushed screen, which does nothing.
    private func back(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.14)).tap()
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Two or more matches open on the card, in the Board's order. An
    /// unrevealed final says only "Final" until its Board has played.
    func testTheCardListsEveryMatch() {
        let app = launch("card")
        XCTAssertTrue(element(app, "watch.card").waitForExistence(timeout: 15))
        XCTAssertFalse(element(app, "watch.match").exists)
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
        shoot(app, "watch-card-end")

        let jo = row(app, "Jo")
        jo.tap()
        let board = element(app, "watch.match")
        XCTAssertTrue(board.waitForExistence(timeout: 5))
        XCTAssertTrue(board.label.hasPrefix("Jo, Final."), board.label)
        sleep(4)  // the reveal
        back(app)
        XCTAssertTrue(element(app, "watch.card").waitForExistence(timeout: 5))
        XCTAssertTrue(row(app, "Jo").label.contains("Won by 114 points."), row(app, "Jo").label)
    }

    /// A row opens its Board; a duel's Board opens its week.
    func testARowOpensTheBoardAndTheBoardOpensTheWeek() {
        let app = launch("card")
        XCTAssertTrue(element(app, "watch.card").waitForExistence(timeout: 15))
        row(app, "Robin").tap()
        let board = element(app, "watch.match")
        XCTAssertTrue(board.waitForExistence(timeout: 5))
        XCTAssertTrue(board.label.hasPrefix("Robin, Day 3 of 7."), board.label)
        shoot(app, "watch-card-board")

        board.tap()
        let week = element(app, "watch.week")
        XCTAssertTrue(week.waitForExistence(timeout: 5))
        // Day 1 is two days ago, whatever weekday that is.
        let first = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ENDSWITH '. You 142. Robin 388.'")).firstMatch
        XCTAssertTrue(first.exists, app.debugDescription)
        let empty = app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH '. No points.'"))
        XCTAssertEqual(empty.count, 4)
        shoot(app, "watch-week")

        back(app)
        XCTAssertTrue(week.waitForNonExistence(timeout: 5))
        XCTAssertTrue(board.waitForExistence(timeout: 5))
    }

    /// No week for a group: its Board stays put.
    func testAGroupBoardHasNoWeek() {
        let app = launch("card")
        XCTAssertTrue(element(app, "watch.card").waitForExistence(timeout: 15))
        row(app, "Four-Way").tap()
        let board = element(app, "watch.match")
        XCTAssertTrue(board.waitForExistence(timeout: 5))
        board.tap()
        sleep(1)
        XCTAssertFalse(element(app, "watch.week").exists)
    }

    /// One match opens straight on its Board, which still opens the week.
    func testOneMatchOpensOnTheBoard() {
        let app = launch("live")
        let board = element(app, "watch.match")
        XCTAssertTrue(board.waitForExistence(timeout: 15))
        XCTAssertFalse(element(app, "watch.card").exists)
        board.tap()
        XCTAssertTrue(element(app, "watch.week").waitForExistence(timeout: 5))
    }

    /// A tapped alert opens its match over the card.
    func testATappedAlertOpensItsMatch() {
        let app = launch("card", "--watch-alert", "00000000-0000-0000-0000-000000000013")
        let board = element(app, "watch.match")
        XCTAssertTrue(board.waitForExistence(timeout: 15))
        XCTAssertTrue(board.label.hasPrefix("Robin, Day 3 of 7."), board.label)
        back(app)
        XCTAssertTrue(element(app, "watch.card").waitForExistence(timeout: 5))
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
