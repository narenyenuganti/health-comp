import XCTest

extension XCUIApplication {
    static func launchGroupLab(
        _ setup: String, arguments: [String] = [], dark: Bool = false, largestText: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--multi-user-competition-test-lab",
            "--multi-user-competition-scenario", "group-matches",
            "-healthcomp.colorHintSeen", "YES",
            "-groupLab", setup,
            "-UIAccessibilityReduceMotionEnabled", "YES",
        ] + arguments
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
