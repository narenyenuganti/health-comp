import XCTest

final class SleepBetaUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.appearance = .light
        app = nil
    }

    func testLiveMatchShowsSleepRowAndNight() {
        launch()
        let jordan = card("active", "Jordan")
        scrollToElement(jordan)
        sleep(3)
        shot("sleep-home")
        jordan.tap()
        XCTAssertTrue(app.navigationBars["Jordan"].waitForExistence(timeout: 3))

        let rings = element("competition.ownerRings")
        XCTAssertTrue(rings.waitForExistence(timeout: 3))
        XCTAssertTrue(rings.label.contains("Sleep, 6 hours 5 minutes asleep, 60 points"), rings.label)
        scrollToElement(rings)
        shot("sleep-today")

        let row = app.buttons["competition.sleep.row"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.staticTexts["Night before Day 3"].waitForExistence(timeout: 3))
        for part in ["Time asleep, 6h 05m of 8h, 38/50", "Bedtime, Fell asleep 12:40\u{202F}AM, usual 11:10\u{202F}PM, 10/30", "Wake-ups, 34 min awake, 12/20"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", part)).firstMatch.exists, part)
        }
        XCTAssertTrue(app.staticTexts["Waiting to sync"].exists, "Jordan's third night isn't in")
        shot("sleep-night")
        app.buttons["Close"].firstMatch.tap()

        let dayOne = app.buttons["competition.strip.day.1"]
        XCTAssertTrue(dayOne.waitForExistence(timeout: 3))
        dayOne.tap()
        XCTAssertTrue(rings.waitForExistence(timeout: 3))
        XCTAssertTrue(rings.label.contains("Sleep, 7 hours 18 minutes asleep"), rings.label)

        let leadLine = element("competition.leadLine")
        scrollToElement(leadLine)
        XCTAssertTrue(leadLine.exists)
        shot("sleep-week")
    }

    func testCreateSheetOffersRingsAndSleep() {
        app.launchEnvironment["TZ"] = "America/Los_Angeles"
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", "challenge-friend",
            "-healthcomp.colorHintSeen", "YES",
            "-healthcomp.sleepBeta.introSeen", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 10))
        let open = app.buttons["competition.create.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        sleep(2)
        open.tap()
        let players = app.buttons["competition.group.choose-players"]
        XCTAssertTrue(players.waitForExistence(timeout: 3))
        players.tap()
        let friend = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "competition.create.friend.", "Dev Patel")).firstMatch
        XCTAssertTrue(friend.waitForExistence(timeout: 5))
        friend.tap()
        let sleepTile = app.buttons["competition.metrics.tile.sleep"]
        XCTAssertTrue(sleepTile.waitForExistence(timeout: 3))
        sleepTile.tap()
        XCTAssertTrue(app.staticTexts["Up to 100 points a night"].waitForExistence(timeout: 3))
        let standTile = app.buttons["competition.metrics.tile.stand"]
        XCTAssertTrue(standTile.exists)
        standTile.tap()
        XCTAssertTrue(app.staticTexts["500 PTS/DAY"].waitForExistence(timeout: 3))
        sleep(1)
        shot("sleep-create")
    }

    func testSettingsPrimesBeforeHealthAndPicksASource() {
        app.launchEnvironment["TZ"] = "America/Los_Angeles"
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", "account",
            "-healthcomp.colorHintSeen", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 8))
        let row = element("account.sleep")
        scrollToElement(row)
        row.tap()
        XCTAssertTrue(app.navigationBars["Sleep"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Oura Ring"].waitForExistence(timeout: 3))
        let connect = app.buttons["account.sleep.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 3))
        connect.tap()
        let proceed = app.buttons["account.sleep.continue"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 3))
        sleep(1)
        shot("sleep-priming")
        proceed.tap()
        XCTAssertTrue(proceed.waitForNonExistence(timeout: 3))
        sleep(1)
        shot("sleep-settings")
    }

    private func launch() {
        XCUIDevice.shared.appearance = .light
        app.launchEnvironment["TZ"] = "America/Los_Angeles"
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", "sleep",
            "-healthcomp.colorHintSeen", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 10))
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func card(_ state: String, _ name: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "competition.sharing.\(state).",
                name
            )
        ).firstMatch
    }

    private func scrollToElement(_ element: XCUIElement) {
        for _ in 0..<12 {
            if element.exists, element.isHittable,
               app.frame.insetBy(dx: 0, dy: 60).contains(element.frame) { return }
            app.swipeUp()
        }
    }
}
