import XCTest

extension XCUIApplication {
    /// The group match Test Lab on one `-groupLab` setup.
    static func launchGroupLab(_ setup: String, dark: Bool = false, largestText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", "group-matches",
            "-healthcomp.colorHintSeen", "YES",
            "-groupLab", setup,
            "-UIAccessibilityReduceMotionEnabled", "YES",
        ]
        if dark { app.launchArguments += ["-AppleInterfaceStyle", "Dark"] }
        if largestText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    func groupElement(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier].firstMatch
    }
}
