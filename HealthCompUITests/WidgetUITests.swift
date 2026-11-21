import XCTest

final class WidgetUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let posterboard = XCUIApplication(bundleIdentifier: "com.apple.PosterBoard")
    private let sampleLabel = "Sam, Day 5 of 7. You 1,204 points. Sam 1,150 points. You lead by 54. Updated"

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }

    private let ourWidgetPredicate = NSPredicate(
        format: "identifier IN %@", ["widget.match", "widget.empty"]
    )
    private var changedTextSize = false

    override func tearDownWithError() throws {
        XCUIDevice.shared.appearance = .light
        if changedTextSize { setLargestText(false) }
        removeOurWidgets()
    }

    private struct Expectation {
        let scenario: String
        let label: String
        var updated = true
    }

    private var homeStates: [Expectation] {
        [
            Expectation(scenario: "live", label: sampleLabel.replacingOccurrences(of: " Updated", with: "")),
            Expectation(scenario: "trailing", label: "Sam, Day 3 of 7. You 610 points. Sam 664 points. Sam leads by 54."),
            Expectation(scenario: "square", label: "Sam, Day 2 of 7. You 480 points. Sam 480 points. All square."),
            Expectation(scenario: "lastDay", label: "Sam, Last day. You 2,190 points. Sam 2,171 points. You lead by 19."),
            Expectation(scenario: "pending",
                        label: "Sam, Final score pending. You 2,190 points. Sam 2,171 points. You lead by 19."),
            Expectation(scenario: "won", label: "Sam, Final. You 1,840 points. Sam 1,726 points. Won by 114 points."),
            Expectation(scenario: "lost", label: "Sam, Final. You 1,700 points. Sam 1,720 points. Lost by 20 points."),
            Expectation(scenario: "tied", label: "Sam, Final. You 1,650 points. Sam 1,650 points. Tied."),
            Expectation(scenario: "scheduled", label: "Sam, Day 1 is \(dayOneWeekday(daysAhead: 2)).", updated: false),
            Expectation(scenario: "empty", label: "Nothing live right now. Challenge someone", updated: false),
            Expectation(scenario: "challenge", label: "Nothing live right now. A challenge is waiting.", updated: false),
            Expectation(
                scenario: "longName",
                label: "Maximiliana Featherstonehaugh-Worthington, Day 5 of 7. You 12,045 points. "
                    + "Maximiliana Featherstonehaugh-Worthington 11,980 points. You lead by 65."
            ),
            Expectation(scenario: "former",
                        label: "Former competitor, Final. You 1,840 points. Former competitor 1,726 points. Won by 114 points."),
            Expectation(scenario: "several", label: sampleLabel.replacingOccurrences(of: " Updated", with: "")),
            Expectation(scenario: "noData", label: "Sam, Day 4 of 7. You 742 points. Sam 510 points. You lead by 232.",
                        updated: false),
            Expectation(scenario: "none", label: "HealthComp. Open the app to see your matches.", updated: false),
        ]
    }

    func testHomeScreenWidgetsShowEveryMatchState() throws {
        launch(scenario: "live")
        XCUIDevice.shared.press(.home)
        removeOurWidgets()
        addWidget(sizeSwipes: 1)
        addWidget(sizeSwipes: 0)
        XCTAssertTrue(ourWidgets().firstMatch.waitForExistence(timeout: 15), springboard.debugDescription)
        setLargestText(false)
        for state in homeStates {
            launch(scenario: state.scenario)
            XCUIDevice.shared.press(.home)
            assertWidgets(state, count: 2)
            sleep(2)
            shot("home-\(state.scenario)-light-default")
            XCUIDevice.shared.appearance = .dark
            sleep(3)
            assertWidgets(state, count: 2)
            shot("home-\(state.scenario)-dark-default")
            XCUIDevice.shared.appearance = .light
            sleep(2)
        }
    }

    func testHomeScreenWidgetsShowGroupMatches() throws {
        launch(scenario: "groupFFA")
        XCUIDevice.shared.press(.home)
        removeOurWidgets()
        addWidget(sizeSwipes: 1)
        addWidget(sizeSwipes: 0)
        XCTAssertTrue(ourWidgets().firstMatch.waitForExistence(timeout: 15), springboard.debugDescription)
        let ffa = "Four-Way, Day 4 of 7. You're 2nd. 48 behind Sam."
        let doubles = "Doubles, Day 4 of 7. Your team 3,162 points. Sam + Leo 2,915 points. Your team up 247."
        for largest in [false, true] {
            setLargestText(largest)
            for (state, medium) in [
                (Expectation(scenario: "groupFFA", label: ffa, updated: false),
                 ffa + " 1st, Sam, 1,712 points. 2nd, You, 1,664 points. 3rd, Priya, 1,498 points. 4th, Leo, 1,203 points."),
                (Expectation(scenario: "groupDoubles", label: doubles, updated: false), doubles),
            ] {
                launch(scenario: state.scenario)
                XCUIDevice.shared.press(.home)
                if medium == state.label {
                    assertWidgets(state, count: 2)
                } else {
                    assertWidgets(state, count: 1)
                    assertWidgets(Expectation(scenario: state.scenario, label: medium, updated: false), count: 1)
                }
                sleep(2)
                shot("home-\(state.scenario)-light" + (largest ? "-ax5" : ""))
            }
        }
    }

    func testPickedPersonShowsOnlyTheirMatchAndNeverAnOldName() throws {
        launch(scenario: "several")
        XCUIDevice.shared.press(.home)
        removeOurWidgets()
        addWidget(sizeSwipes: 0)
        let samLive = homeStates.first { $0.scenario == "several" }!
        assertWidgets(samLive, count: 1)

        pickPerson("Riley", expectingList: ["Ending soonest", "Alex", "Casey", "Riley", "Sam"],
                   absent: ["Former competitor"])
        assertWidgets(Expectation(
            scenario: "several",
            label: "Riley, Final score pending. You 2,190 points. Riley 2,171 points. You lead by 19."
        ), count: 1)

        pickPerson("Casey", expectingList: nil, absent: [])
        assertWidgets(Expectation(
            scenario: "several", label: "Casey, Day 1 is \(dayOneWeekday(daysAhead: 3)).", updated: false
        ), count: 1)

        pickPerson("Sam", expectingList: nil, absent: [])
        assertWidgets(samLive, count: 1)

        launch(scenario: "samGone")
        XCUIDevice.shared.press(.home)
        assertWidgets(Expectation(scenario: "samGone", label: "No match with Sam right now.", updated: false), count: 1)
        sleep(2)
        shot("home-picked-gone-light-default")

        launch(scenario: "noSam")
        XCUIDevice.shared.press(.home)
        assertWidgets(Expectation(scenario: "noSam", label: "No match with this person right now.", updated: false),
                      count: 1)
        sleep(2)
        shot("home-picked-missing-light-default")

        launch(scenario: "none")
        XCUIDevice.shared.press(.home)
        assertWidgets(homeStates.first { $0.scenario == "none" }!, count: 1)

        launch(scenario: "several")
        XCUIDevice.shared.press(.home)
        assertWidgets(samLive, count: 1)

        launch(scenario: "samGone")
        XCUIDevice.shared.press(.home)
        pickPerson("Ending soonest", expectingList: nil, absent: [])
        assertWidgets(Expectation(
            scenario: "samGone", label: "Alex, Day 2 of 7. You 480 points. Alex 455 points. You lead by 25."
        ), count: 1)
    }

    func testLockScreenWidgetsShowEveryMatchState() throws {
        setLargestText(false)
        launch(scenario: "live")
        XCUIDevice.shared.press(.home)
        showLockScreen()
        if !lockScreenElement("You lead Sam by 54 points").waitForExistence(timeout: 3) {
            addLockScreenWidgets()
        }
        XCUIDevice.shared.press(.home)
        let full = Dictionary(uniqueKeysWithValues: homeStates.map { ($0.scenario, $0) })
        let states: [(String, String, Expectation?)] = [
            ("live", "You lead Sam by 54 points", full["live"]),
            ("trailing", "Sam leads by 54 points", full["trailing"]),
            ("square", "All square with Sam", full["square"]),
            ("pending", "You lead Sam by 19 points", full["pending"]),
            ("won", full["won"]!.label, nil),
            ("lost", full["lost"]!.label, nil),
            ("scheduled", full["scheduled"]!.label, nil),
            ("longName", "You lead Maximiliana Featherstonehaugh-Worthington by 65 points", full["longName"]),
            ("empty", full["empty"]!.label, nil),
            ("none", full["none"]!.label, nil),
        ]
        for largest in [false, true] {
            if largest { setLargestText(true) }
            for (scenario, circle, rectangle) in states {
                launch(scenario: scenario)
                XCUIDevice.shared.press(.home)
                showLockScreen()
                let size = largest ? "ax5" : "default"
                if let rectangle {
                    assertLockScreen(circle, count: 1)
                    assertLockScreen(rectangle.label, count: 1)
                } else {
                    assertLockScreen(circle, count: 2)
                }
                shot("lock-\(scenario)-light-\(size)")
                XCUIDevice.shared.appearance = .dark
                sleep(3)
                shot("lock-\(scenario)-dark-\(size)")
                XCUIDevice.shared.appearance = .light
                XCUIDevice.shared.press(.home)
                sleep(1)
            }
        }
    }

    private func launch(scenario: String, arguments: [String] = []) {
        let app = XCUIApplication()
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", "sharing",
            "--widget-scenario", scenario,
            "-healthcomp.colorHintSeen", "YES",
        ] + arguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(2)
    }

    private func dayOneWeekday(daysAhead: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(byAdding: .day, value: daysAhead, to: calendar.startOfDay(for: Date()))!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter.string(from: day)
    }

    private func assertWidgets(_ state: Expectation, count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = state.updated
            ? NSPredicate(format: "label MATCHES %@",
                          "^" + NSRegularExpression.escapedPattern(for: state.label)
                              + " Updated \\d{1,2}:\\d{2}\\s?[AP]M\\.$")
            : NSPredicate(format: "label == %@", state.label)
        assertOnScreen(predicate, count: count, name: state.scenario, expected: state.label, file: file, line: line)
    }

    private func assertLockScreen(_ label: String, count: Int, file: StaticString = #filePath, line: UInt = #line) {
        assertOnScreen(NSPredicate(format: "label BEGINSWITH %@", label), count: count,
                       name: "lock", expected: label, widgetsOnly: false, file: file, line: line)
    }

    private func assertOnScreen(
        _ predicate: NSPredicate, count: Int, name: String, expected: String,
        widgetsOnly: Bool = true, file: StaticString, line: UInt
    ) {
        let query = springboard.descendants(matching: .any).matching(
            widgetsOnly ? NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, ourWidgetPredicate]) : predicate
        )
        let visible = {
            Set(query.allElementsBoundByIndex.filter(\.isHittable).map { "\($0.frame)" }).count
        }
        let deadline = Date().addingTimeInterval(20)
        while visible() < count, Date() < deadline { usleep(500_000) }
        let found = visible()
        guard found != count else { return }
        shot("wrong-\(name)")
        let tree = XCTAttachment(string: springboard.debugDescription)
        tree.name = "wrong-\(name)-tree"
        tree.lifetime = .keepAlways
        add(tree)
        let labels = (widgetsOnly ? ourWidgets() : query).allElementsBoundByIndex
            .map { "\($0.label) (\($0.isHittable ? "on" : "off") screen)" }
        XCTFail("\(name): expected \(count) × \(expected), found \(found): \(labels)", file: file, line: line)
    }

    private func pickPerson(_ name: String, expectingList: [String]?, absent: [String]) {
        let widget = ourWidgets().firstMatch
        XCTAssertTrue(widget.waitForExistence(timeout: 10))
        widget.press(forDuration: 1.3)
        tap([springboard.buttons["Edit Widget"]], "Edit Widget")
        sleep(2)
        let current = ["Ending soonest", "Person", "Choose", "Alex", "Casey", "Riley", "Sam"]
            .map { springboard.buttons[$0] }
        tap(current, "Person value")
        let person = { (label: String) in
            self.springboard.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        XCTAssertTrue(person(name).waitForExistence(timeout: 5), springboard.debugDescription)
        if let expectingList {
            shot("edit-widget-people")
            let tops = expectingList.map { label -> CGFloat in
                let element = person(label)
                XCTAssertTrue(element.exists, "Person list lacks \(label)")
                return element.frame.minY
            }
            XCTAssertEqual(tops, tops.sorted(), "Person list isn't in order")
            for label in absent {
                XCTAssertFalse(person(label).exists, "Person list offers \(label)")
            }
        }
        person(name).tap()
        sleep(1)
        XCUIDevice.shared.press(.home)
        sleep(2)
        if springboard.buttons["Done"].exists { springboard.buttons["Done"].tap() }
    }

    private func setLargestText(_ on: Bool) {
        changedTextSize = true
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.activate()
        for step in ["Accessibility", "Display & Text Size", "Larger Text"] {
            let row = settings.staticTexts[step]
            for _ in 0..<4 where !(row.exists && row.isHittable) { settings.swipeUp(); sleep(1) }
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Settings has no \(step)")
            row.tap()
            sleep(1)
        }
        let toggle = settings.switches["Larger Accessibility Sizes"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), settings.debugDescription)
        if (toggle.value as? String) != "1" { flip(toggle) }
        sleep(1)
        let expected = on ? "100%" : "27%"
        for _ in 0..<6 {
            let slider = settings.sliders.firstMatch
            if (slider.value as? String) == expected { break }
            slider.adjust(toNormalizedSliderPosition: on ? 1 : 3.0 / 11.0)
            sleep(2)
        }
        XCTAssertEqual(settings.sliders.firstMatch.value as? String, expected, "Larger Text slider")
        if !on {
            flip(toggle)
            sleep(1)
            XCTAssertEqual(toggle.value as? String, "0", "Larger Accessibility Sizes")
        }
        shot(on ? "settings-text-ax5" : "settings-text-default")
        changedTextSize = on
        settings.terminate()
        XCUIDevice.shared.press(.home)
        sleep(3)
    }

    func testMatchWidgetShowsTheSampleScoreAndPicksAPerson() throws {
        let app = XCUIApplication()
        launchWithSample()
        XCUIDevice.shared.press(.home)
        removeOurWidgets()

        addWidget(sizeSwipes: 1)
        addWidget(sizeSwipes: 0)

        let widgets = widgetElements()
        XCTAssertTrue(widgets.firstMatch.waitForExistence(timeout: 15), springboard.debugDescription)
        assertOnScreen(widgetPredicate, count: 2, name: "added", expected: sampleLabel,
                       file: #filePath, line: #line)
        shot("home-light")

        XCUIDevice.shared.appearance = .dark
        sleep(4)
        assertOnScreen(widgetPredicate, count: 2, name: "dark", expected: sampleLabel,
                       file: #filePath, line: #line)
        shot("home-dark")
        XCUIDevice.shared.appearance = .light
        sleep(3)

        let widget = widgetElements().firstMatch
        widget.press(forDuration: 1.3)
        tap([springboard.buttons["Edit Widget"]], "Edit Widget")
        sleep(2)
        shot("edit-widget")
        tap(["Ending soonest", "Person", "Choose"].map { springboard.buttons[$0] }, "Person value")
        let sam = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Sam'")).firstMatch
        XCTAssertTrue(sam.waitForExistence(timeout: 5), springboard.debugDescription)
        shot("edit-widget-people")
        sam.tap()
        sleep(1)
        XCUIDevice.shared.press(.home)
        sleep(2)
        if springboard.buttons["Done"].exists { springboard.buttons["Done"].tap() }
        assertOnScreen(widgetPredicate, count: 2, name: "picked", expected: sampleLabel,
                       file: #filePath, line: #line)

        app.terminate()
        widgetElements().firstMatch.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    func testLockScreenWidgetsShowTheLeadAndBothTotals() throws {
        launchWithSample()
        XCUIDevice.shared.press(.home)
        showLockScreen()
        let circular = lockScreenElement("You lead Sam by 54 points")
        let rectangular = lockScreenElement(sampleLabel)
        if !circular.waitForExistence(timeout: 3) {
            addLockScreenWidgets()
            showLockScreen()
        }
        sleep(3)
        shot("lock-light")
        XCTAssertTrue(circular.waitForExistence(timeout: 15), springboard.debugDescription)
        XCTAssertTrue(rectangular.exists, springboard.debugDescription)
        XCUIDevice.shared.appearance = .dark
        sleep(3)
        shot("lock-dark")
        XCUIDevice.shared.press(.home)
        sleep(1)
    }

    private func launchWithSample() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", "sharing",
            "--widget-sample",
            "-healthcomp.colorHintSeen", "YES",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(2)
    }

    private func showLockScreen() {
        let lock = NSSelectorFromString("pressLockButton")
        XCUIDevice.shared.perform(lock)
        sleep(2)
        XCUIDevice.shared.perform(lock)
        sleep(3)
    }

    private func lockScreenElement(_ prefix: String) -> XCUIElement {
        springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func addLockScreenWidgets() {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 1.8)
        sleep(2)
        tap([springboard.buttons["Customize"], springboard.staticTexts["Customize"]], "Customize")
        sleep(2)
        tap([springboard.cells.matching(NSPredicate(format: "label BEGINSWITH 'Customize Lock'")).firstMatch],
            "Customize Lock Screen")
        sleep(3)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.29)).tap()
        sleep(2)
        tap([posterboard.buttons["Continue"]], "keyboard intro", timeout: 3, required: false)
        let result = posterboard.cells["HealthComp"]
        XCTAssertTrue(result.waitForExistence(timeout: 5), posterboard.debugDescription)
        for _ in 0..<8 where !result.isHittable {
            posterboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                .press(forDuration: 0.05, thenDragTo: posterboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)))
            sleep(1)
        }
        tap([result], "HealthComp in the Lock Screen gallery")
        sleep(2)
        for size in ["Circular", "Rectangular"] {
            let widget = posterboard.buttons
                .matching(NSPredicate(format: "label == 'HealthComp, Match' AND value CONTAINS %@", size)).firstMatch
            tap([widget], "\(size) widget")
            sleep(1)
        }
        shot("lock-editor")
        if !tap([posterboard.buttons["close"]], "close gallery", timeout: 3, required: false) {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.91, dy: 0.475)).tap()
        }
        sleep(2)
        let done = posterboard.buttons["editing-done"]
        for _ in 0..<3 {
            if done.exists, done.isHittable { done.tap() } else {
                springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.037)).tap()
            }
            sleep(2)
            if !done.exists { break }
        }
        shot("lock-after-done")
        tap([springboard.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'posterboard-posteruuid'")).firstMatch],
            "poster", timeout: 3, required: false)
        sleep(2)
    }

    private func flip(_ toggle: XCUIElement) {
        let inner = toggle.switches.firstMatch
        (inner.exists ? inner : toggle).tap()
    }

    private func ourWidgets() -> XCUIElementQuery {
        springboard.descendants(matching: .any).matching(ourWidgetPredicate)
    }

    private func widgetElements() -> XCUIElementQuery {
        springboard.descendants(matching: .any).matching(widgetPredicate)
    }

    private var widgetPredicate: NSPredicate {
        let pattern = NSRegularExpression.escapedPattern(for: sampleLabel)
            .replacingOccurrences(of: "Day 5", with: "Day \\d")
        return NSPredicate(format: "label MATCHES %@", "^" + pattern + ".*")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @discardableResult
    private func tap(
        _ candidates: [XCUIElement],
        _ step: String,
        timeout: TimeInterval = 6,
        required: Bool = true
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = candidates.first(where: { $0.exists && $0.isHittable }) {
                hit.tap()
                return true
            }
            usleep(250_000)
        }
        if required {
            shot("missing-\(step)")
            XCTFail("SpringBoard has no \(step)\n\(springboard.debugDescription)")
        }
        return false
    }

    private func enterEditMode() {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            .press(forDuration: 1.6)
        sleep(1)
        tap([springboard.buttons["Edit Home Screen"]], "Edit Home Screen", timeout: 2, required: false)
    }

    private func addWidget(sizeSwipes: Int) {
        enterEditMode()
        tap([springboard.buttons["Edit"]], "Edit")
        tap([springboard.buttons["Add Widget"]], "Add Widget")
        sleep(2)
        tap([springboard.buttons["Continue"]], "keyboard intro", timeout: 3, required: false)
        let result = springboard.cells["HealthComp"]
        if !result.waitForExistence(timeout: 2) {
            tap([springboard.searchFields["Search Widgets"]], "Search Widgets")
            tap([springboard.buttons["Continue"]], "keyboard intro", timeout: 3, required: false)
        }
        XCTAssertTrue(result.waitForExistence(timeout: 5), springboard.debugDescription)
        for _ in 0..<8 where !result.isHittable {
            let list = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            list.press(
                forDuration: 0.05,
                thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
            )
            sleep(1)
        }
        shot("gallery-list")
        tap([result], "HealthComp in the widget gallery")
        sleep(2)
        for _ in 0..<sizeSwipes {
            springboard.swipeLeft()
            sleep(1)
        }
        tap([springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Add Widget'")).firstMatch], "Add Widget (size)")
        sleep(2)
        tap([springboard.buttons["Done"]], "Done", timeout: 3, required: false)
        sleep(1)
    }

    private func removeOurWidgets() {
        XCUIDevice.shared.press(.home)
        sleep(1)
        let remove = springboard.alerts.buttons["Remove"]
        var pages = 0
        for _ in 0..<10 {
            guard let widget = ourWidgets().allElementsBoundByIndex.first(where: { $0.isHittable }) else {
                guard pages < 2 else { break }
                pages += 1
                springboard.swipeLeft()
                sleep(1)
                continue
            }
            widget.press(forDuration: 1.3)
            guard tap([springboard.buttons["Remove Widget"]], "Remove Widget", timeout: 3, required: false)
            else { break }
            if remove.waitForExistence(timeout: 5) { remove.tap() }
            sleep(1)
        }
        let cancel = springboard.alerts.buttons["Cancel"]
        if cancel.exists { cancel.tap() }
        if springboard.buttons["Done"].exists { springboard.buttons["Done"].tap() }
        XCUIDevice.shared.press(.home)
        sleep(1)
    }
}
