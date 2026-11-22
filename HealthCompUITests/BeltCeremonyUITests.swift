import XCTest

final class BeltCeremonyUITests: XCTestCase {
    private var app: XCUIApplication!

    private static let ceremonies: [(byte: UInt8, name: String, clip: String, words: [String])] = [
        (0x61, "Avery", "earned", ["AND NEW", "You took the belt"]),
        (0x75, "Sam", "taken", ["AND NEW", "You took the belt from Sam", "SAM’S REIGN: 4 WEEKS · 2 DEFENSES"]),
        (0x85, "Riley", "lost", ["AND NEW", "Riley took the belt", "YOUR REIGN: 4 WEEKS · 2 DEFENSES"]),
        (0x94, "Jordan", "defended", ["AND STILL", "3rd title defense"]),
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        if app.state != .notRunning { app.terminate() }
        app = nil
    }

    func testEachEventPlaysItsClipThenTheResultAndNeverAgain() {
        launchLab()
        for ceremony in Self.ceremonies {
            openPerson(ceremony.byte, title: ceremony.name)
            tapWeek(ceremony.byte)
            XCTAssertTrue(soon(5) { self.ceremony.exists }, ceremony.clip)
            XCTAssertTrue(soon(3) { self.element("competition.belt.ceremony.clip.\(ceremony.clip)").exists })
            for word in ceremony.words {
                XCTAssertTrue(soon(6) { self.app.staticTexts[word].exists }, word)
            }
            if ceremony.clip == "defended" {
                let count = element("competition.belt.ceremony.count")
                XCTAssertTrue(soon(3) { count.label == "3 defenses" }, count.label)
            }
            assertCeremonyEnds(within: 6)
            XCTAssertTrue(element("competition.result.belt").exists)

            goBack(to: ceremony.name)
            tapWeek(ceremony.byte)
            assertNoCeremony()
            goBack(to: ceremony.name)
            goBack(to: "History")
        }
    }

    func testTapSkipsAndTheBannerReplays() {
        launchLab()
        openPerson(0x75, title: "Sam")
        tapWeek(0x75)
        XCTAssertTrue(ceremony.waitForExistence(timeout: 5))
        ceremony.tap()
        assertCeremonyEnds(within: 1.5)
        XCTAssertFalse(app.staticTexts["AND NEW"].exists)

        let banner = element("competition.result.belt")
        XCTAssertTrue(banner.waitForExistence(timeout: 3))
        banner.tap()
        XCTAssertTrue(ceremony.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["AND NEW"].waitForExistence(timeout: 6))
        ceremony.tap()
        assertCeremonyEnds(within: 1.5)

        goBack(to: "Sam")
        tapWeek(0x75)
        assertNoCeremony()
    }

    func testOtherEventsHaveNoCeremony() {
        launchLab()
        for (byte, name, banner) in [
            (UInt8(0xA1), "Casey", "Casey took the belt"),
            (0xB2, "Dana", "Dana’s 1st title defense, 2 weeks in a row."),
        ] {
            openPerson(byte, title: name)
            tapWeek(byte)
            assertNoCeremony()
            let row = element("competition.result.belt")
            XCTAssertEqual(row.label, banner)
            row.tap()
            assertNoCeremony()
            goBack(to: name)
            goBack(to: "History")
        }
        openPerson(0xC2, title: "Taylor")
        tapWeek(0xC2)
        assertNoCeremony()
    }

    func testOffUnlessTheLaunchArgumentAsksForIt() {
        launchLab(ceremonies: false)
        openPerson(0x94, title: "Jordan")
        tapWeek(0x94)
        assertNoCeremony()
        element("competition.result.belt").tap()
        assertNoCeremony()
    }

    func testReduceMotionShowsThePosterWithTheSameWords() {
        launchLab(["--belt-reduce-motion"])
        openPerson(0x94, title: "Jordan")
        tapWeek(0x94)
        XCTAssertTrue(soon(5) { self.element("competition.belt.ceremony.poster.defended").exists })
        XCTAssertTrue(app.staticTexts["AND STILL"].exists)
        XCTAssertEqual(element("competition.belt.ceremony.count").label, "3 defenses")
        XCTAssertFalse(element("competition.belt.ceremony.clip.defended").exists)
        assertCeremonyEnds(within: 3)
    }

    func testBackgroundingEndsItWithoutAReplay() {
        launchLab()
        openPerson(0x85, title: "Riley")
        tapWeek(0x85)
        XCTAssertTrue(ceremony.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) || app.state == .runningBackgroundSuspended)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(element("competition.result.belt").waitForExistence(timeout: 3))
        XCTAssertFalse(ceremony.exists)
        goBack(to: "Riley")
        tapWeek(0x85)
        assertNoCeremony()
    }

    private var ceremony: XCUIElement { element("competition.belt.ceremony") }

    private func launchLab(_ arguments: [String] = [], ceremonies: Bool = true) {
        if app.state != .notRunning { app.terminate() }
        app = XCUIApplication()
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", "belt-ceremony",
            "-healthcomp.colorHintSeen", "YES",
        ] + (ceremonies ? ["--belt-ceremonies"] : []) + arguments
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
    }

    private func openPerson(_ latest: UInt8, title: String) {
        if !app.navigationBars["History"].exists {
            let history = app.buttons["competition.history.open"]
            scrollTo(history)
            history.tap()
            XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 3))
        }
        let row = element("competition.record.\(Self.uuid(latest))")
        scrollTo(row)
        row.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3))
        XCTAssertTrue(element("competition.person.belt").waitForExistence(timeout: 3))
    }

    private func tapWeek(_ byte: UInt8) {
        let week = element("competition.sharing.completed.\(Self.uuid(byte))")
        scrollTo(week)
        week.tap()
    }

    private func goBack(to title: String) {
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3))
    }

    private func assertCeremonyEnds(
        within seconds: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ended = ceremony.waitForNonExistence(timeout: seconds)
        if !ended {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(ended, file: file, line: line)
        XCTAssertTrue(element("competition.result").waitForExistence(timeout: 3), file: file, line: line)
    }

    private func assertNoCeremony(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element("competition.result").waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertFalse(ceremony.waitForExistence(timeout: 1), file: file, line: line)
    }

    private func soon(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
        } while Date() < deadline
        return false
    }

    private func scrollTo(_ target: XCUIElement) {
        for _ in 0..<12 {
            var visible = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 12)
            let navigation = app.navigationBars.firstMatch
            if navigation.exists {
                visible.origin.y = navigation.frame.maxY
                visible.size.height = app.windows.firstMatch.frame.maxY - visible.minY - 12
            }
            let challenge = element("competition.person.challenge")
            if challenge.exists, challenge.isHittable {
                visible.size.height = min(visible.maxY, challenge.frame.minY) - visible.minY
            }
            if target.exists, target.isHittable, visible.contains(target.frame) { return }
            if target.exists, target.frame.midY < visible.midY {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        XCTFail("Could not fully reveal \(target)")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private static func uuid(_ byte: UInt8) -> String {
        String(format: "a3000000-0000-4000-8000-0000000000%02x", byte)
    }
}
