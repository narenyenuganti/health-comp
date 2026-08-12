import Foundation
import ComposableArchitecture
import XCTest
@testable import HealthComp

final class SupabaseConfigurationTests: XCTestCase {
    func testParsesValidPublishableConfiguration() throws {
        let configuration = try SupabaseConfiguration.parse([
            "SUPABASE_URL": "  https://project-ref.supabase.co  ",
            "SUPABASE_PUBLISHABLE_KEY": "  sb_publishable_test-fixture  ",
        ])

        XCTAssertEqual(
            configuration.url,
            URL(string: "https://project-ref.supabase.co")
        )
        XCTAssertEqual(
            configuration.publishableKey,
            "sb_publishable_test-fixture"
        )
    }

    func testRejectsMissingOrWhitespaceURL() {
        for value in [nil, "", "   "] {
            XCTAssertThrowsError(
                try SupabaseConfiguration.parse(dictionary(url: value))
            ) { error in
                XCTAssertEqual(error as? SupabaseConfigurationError, .missingURL)
            }
        }
    }

    func testRejectsMalformedOrHostlessURL() {
        for value in ["not a url", "https:", "https:///rest/v1"] {
            XCTAssertThrowsError(
                try SupabaseConfiguration.parse(dictionary(url: value))
            ) { error in
                XCTAssertEqual(error as? SupabaseConfigurationError, .invalidURL)
            }
        }
    }

    func testRejectsNonHTTPSURL() {
        XCTAssertThrowsError(
            try SupabaseConfiguration.parse(
                dictionary(url: "http://project-ref.supabase.co")
            )
        ) { error in
            XCTAssertEqual(error as? SupabaseConfigurationError, .insecureURL)
        }
    }

    func testRejectsPlaceholderURL() {
        for value in [
            "https://example.com",
            "https://your-project.supabase.co",
            "$(SUPABASE_URL)",
        ] {
            XCTAssertThrowsError(
                try SupabaseConfiguration.parse(dictionary(url: value))
            ) { error in
                XCTAssertEqual(error as? SupabaseConfigurationError, .placeholderURL)
            }
        }
    }

    func testRejectsMissingOrWhitespacePublishableKey() {
        for value in [nil, "", "   "] {
            XCTAssertThrowsError(
                try SupabaseConfiguration.parse(dictionary(key: value))
            ) { error in
                XCTAssertEqual(
                    error as? SupabaseConfigurationError,
                    .missingPublishableKey
                )
            }
        }
    }

    func testRejectsPlaceholderPublishableKey() {
        for value in [
            "your-publishable-key",
            "replace-me",
            "$(SUPABASE_PUBLISHABLE_KEY)",
        ] {
            XCTAssertThrowsError(
                try SupabaseConfiguration.parse(dictionary(key: value))
            ) { error in
                XCTAssertEqual(
                    error as? SupabaseConfigurationError,
                    .placeholderPublishableKey
                )
            }
        }
    }

    func testRejectsSecretKeyPrefix() {
        let secretPrefix = "sb_" + "secret_"
        XCTAssertThrowsError(
            try SupabaseConfiguration.parse(
                dictionary(key: secretPrefix + "private-test-value")
            )
        ) { error in
            XCTAssertEqual(
                error as? SupabaseConfigurationError,
                .serviceRolePublishableKey
            )
        }
    }

    func testRejectsJWTWithServiceRolePayload() throws {
        let header = try base64URL(["alg": "HS256", "typ": "JWT"])
        let payload = try base64URL(["role": "service" + "_role"])
        let key = "\(header).\(payload).signature"

        XCTAssertThrowsError(
            try SupabaseConfiguration.parse(dictionary(key: key))
        ) { error in
            XCTAssertEqual(
                error as? SupabaseConfigurationError,
                .serviceRolePublishableKey
            )
        }
    }

    func testConfigurationErrorsNeverExposeSecretInput() {
        let secret = "sb_" + "secret_" + "never-print-this-value"

        XCTAssertThrowsError(
            try SupabaseConfiguration.parse(dictionary(key: secret))
        ) { error in
            XCTAssertFalse(String(describing: error).contains(secret))
        }
    }

#if DEBUG
    @MainActor
    func testTestLabCreatesNoAuthGraphAndOrdinaryLaunchInjectsOneLazyAdapter()
        async
    {
        let clientCreationCount = LockedCounter()
        let adapterCreationCount = LockedCounter()
        let restoreCount = LockedCounter()
        let poisonedProvider = SupabaseClientProvider {
            clientCreationCount.increment()
            fatalError("Supabase client must be lazy")
        }
        let authenticationClientFactory = AuthenticationClientFactory {
            _ in
            adapterCreationCount.increment()
            return AuthenticationClient(
                restoreSession: {
                    restoreCount.increment()
                    return nil
                },
                signInWithApple: {
                    throw AuthenticationClientFailure.operationFailed
                },
                bootstrapProfile: { _ in
                    throw AuthenticationClientFailure.operationFailed
                },
                events: { AsyncStream { $0.finish() } },
                signOut: {}
            )
        }

        var labLaunchCount = 0
        for fixture in CompetitionTestLabFixtureKind.allCases {
            for direction in ["incoming", "outgoing"] {
                for journalMode in ["unique", "persistent"] {
                    var arguments = [
                        "HealthComp",
                        "--local-competition-test-lab",
                        "--local-competition-fixture", fixture.rawValue,
                        "--local-competition-direction", direction,
                    ]
                    if journalMode == "persistent" {
                        arguments += [
                            "--local-competition-run-id",
                            "supabase-poison-\(labLaunchCount)",
                        ]
                    }
                    _ = HealthCompApp(
                        arguments: arguments,
                        supabaseClientProvider: poisonedProvider,
                        authenticationClientFactory:
                            authenticationClientFactory
                    )
                    labLaunchCount += 1
                }
            }
        }
        _ = HealthCompApp(
            arguments: [
                "HealthComp",
                "--local-competition-test-lab",
                "--local-competition-fixture",
                "not-a-fixture",
            ],
            supabaseClientProvider: poisonedProvider,
            authenticationClientFactory: authenticationClientFactory
        )

        XCTAssertEqual(labLaunchCount, 28)
        XCTAssertEqual(adapterCreationCount.value, 0)
        XCTAssertEqual(clientCreationCount.value, 0)

        _ = HealthCompApp(
            arguments: ["HealthComp"],
            supabaseClientProvider: poisonedProvider,
            authenticationClientFactory: authenticationClientFactory
        )

        XCTAssertEqual(adapterCreationCount.value, 1)
        XCTAssertEqual(clientCreationCount.value, 0)

        let store = HealthCompLiveComposition.store(
            supabaseClientProvider: poisonedProvider,
            authenticationClientFactory: authenticationClientFactory
        )
        await store.send(.task).finish()
        XCTAssertEqual(adapterCreationCount.value, 2)
        XCTAssertEqual(restoreCount.value, 1)
        XCTAssertEqual(clientCreationCount.value, 0)
        XCTAssertEqual(store.phase, .signedOut)
    }
#endif

    private func dictionary(
        url: String? = "https://project-ref.supabase.co",
        key: String? = "sb_publishable_test-fixture"
    ) -> [String: Any] {
        var result: [String: Any] = [:]
        result["SUPABASE_URL"] = url
        result["SUPABASE_PUBLISHABLE_KEY"] = key
        return result
    }

    private func base64URL(_ object: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
