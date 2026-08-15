import Foundation
import XCTest

final class AppAttestConfigurationTests: XCTestCase {
    func testEntitlementUsesBuildConfigurationVariable() throws {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(
            "HealthComp/Resources/HealthComp.entitlements"
        ))
        let propertyList = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )

        XCTAssertEqual(
            propertyList["com.apple.developer.devicecheck.appattest-environment"]
                as? String,
            "$(APP_ATTEST_ENVIRONMENT)"
        )
    }

    func testBuildConfigurationsSelectExpectedAppAttestEnvironment() throws {
        let expected = [
            "Configuration/Development.xcconfig": "development",
            "Configuration/Staging.xcconfig": "development",
            "Configuration/Production.xcconfig": "production",
        ]

        for (path, environment) in expected {
            let values = try xcconfigValues(at: path)
            XCTAssertEqual(
                values["APP_ATTEST_ENVIRONMENT"],
                environment,
                path
            )
        }
    }

    private func xcconfigValues(at path: String) throws -> [String: String] {
        let contents = try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
        return contents.split(separator: "\n").reduce(into: [:]) {
            result, rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  !line.hasPrefix("#"),
                  let separator = line.firstIndex(of: "=")
            else { return }
            let key = line[..<separator]
                .trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
