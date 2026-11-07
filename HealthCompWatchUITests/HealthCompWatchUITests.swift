import XCTest

final class HealthCompWatchUITests: XCTestCase {
    func testLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["watch.empty"].waitForExistence(timeout: 15))
    }
}
