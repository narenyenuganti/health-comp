import Foundation

@main
enum StagingAppleWebContractTests {
    static func main() {
        do {
            try run()
        } catch {
            let message = (error as? Failure)?.description ?? "FAIL: unexpected_contract_error"
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            checks += 1
            guard condition() else {
                // Labels are static. Never print configuration or callback values.
                throw Failure(label: label)
            }
        }

        let valid: [String: Any] = [
            "CFBundleIdentifier": "com.narenyenuganti.HealthComp.staging",
            "SUPABASE_URL": "https://xhfdfdrtxwptrwhvvlhg.supabase.co",
            "HEALTHCOMP_ENABLE_APPLE_WEB_SIGN_IN": "YES",
            "HEALTHCOMP_APPLE_WEB_CLIENT_ID": "com.example.healthcomp.web",
        ]
        let configuration = StagingAppleWebAuthenticationConfiguration.parse(valid)
#if HEALTHCOMP_STAGING
        try expect(configuration != nil, "exact_staging_opt_in_is_available")
#else
        try expect(configuration == nil, "ordinary_build_cannot_enable_web_auth")
#endif

        let invalidOverrides: [[String: Any]] = [
            ["CFBundleIdentifier": "com.narenyenuganti.HealthComp"],
            ["CFBundleIdentifier": ""],
            ["SUPABASE_URL": "https://another-project.supabase.co"],
            ["SUPABASE_URL": "http://xhfdfdrtxwptrwhvvlhg.supabase.co"],
            ["SUPABASE_URL": "https://xhfdfdrtxwptrwhvvlhg.supabase.co.attacker.invalid"],
            ["SUPABASE_URL": "https://user@xhfdfdrtxwptrwhvvlhg.supabase.co"],
            ["SUPABASE_URL": "https://xhfdfdrtxwptrwhvvlhg.supabase.co:443"],
            ["SUPABASE_URL": "https://xhfdfdrtxwptrwhvvlhg.supabase.co/path"],
            ["SUPABASE_URL": "https://xhfdfdrtxwptrwhvvlhg.supabase.co?query=1"],
            ["SUPABASE_URL": "https://xhfdfdrtxwptrwhvvlhg.supabase.co#fragment"],
            ["SUPABASE_URL": "$(SUPABASE_URL)"],
            ["HEALTHCOMP_ENABLE_APPLE_WEB_SIGN_IN": "NO"],
            ["HEALTHCOMP_ENABLE_APPLE_WEB_SIGN_IN": "yes"],
            ["HEALTHCOMP_ENABLE_APPLE_WEB_SIGN_IN": true],
            ["HEALTHCOMP_ENABLE_APPLE_WEB_SIGN_IN": "$(FLAG)"],
            ["HEALTHCOMP_APPLE_WEB_CLIENT_ID": ""],
            ["HEALTHCOMP_APPLE_WEB_CLIENT_ID": "$(CLIENT_ID)"],
            ["HEALTHCOMP_APPLE_WEB_CLIENT_ID": "com.narenyenuganti.HealthComp"],
            ["HEALTHCOMP_APPLE_WEB_CLIENT_ID": "com.narenyenuganti.HealthComp.staging"],
            ["HEALTHCOMP_APPLE_WEB_CLIENT_ID": " com.example.web"],
            ["HEALTHCOMP_APPLE_WEB_CLIENT_ID": String(repeating: "a", count: 256)],
            ["HEALTHCOMP_APPLE_WEB_CLIENT_ID": true],
        ]
        for override in invalidOverrides {
            let dictionary = valid.merging(override) { _, new in new }
            try expect(
                StagingAppleWebAuthenticationConfiguration.parse(dictionary) == nil,
                "invalid_configuration_is_unavailable"
            )
        }
        for key in valid.keys {
            var missing = valid
            missing.removeValue(forKey: key)
            try expect(
                StagingAppleWebAuthenticationConfiguration.parse(missing) == nil,
                "missing_configuration_is_unavailable"
            )
        }

#if HEALTHCOMP_STAGING
        guard let configuration else { throw Failure(label: "staging_configuration_missing") }
        try expect(configuration.clientID == "com.example.healthcomp.web", "configured_services_id_preserved")
        let base = "healthcomp-staging-auth://apple/callback"
        let code = "synthetic-pkce-code-0123456789"
        try expect(configuration.redirectURL.absoluteString == base, "dedicated_callback_route")
        let accepted = try configuration.authorizationCode(from: URL(string: "\(base)?code=\(code)")!)
        try expect(accepted == code, "valid_callback_yields_only_code")

        let invalidCallbacks = [
            "healthcomp://apple/callback?code=\(code)",
            "healthcomp-staging-auth://competition/callback?code=\(code)",
            "healthcomp-staging-auth://apple/other?code=\(code)",
            "healthcomp-staging-auth://apple/callback/?code=\(code)",
            "healthcomp-staging-auth://apple/%63allback?code=\(code)",
            "healthcomp-staging-auth://user@apple/callback?code=\(code)",
            "healthcomp-staging-auth://apple:123/callback?code=\(code)",
            "\(base)?code=\(code)#fragment",
            "\(base)#code=\(code)",
            "\(base)",
            "\(base)?code",
            "\(base)?code=",
            "\(base)?code=short",
            "\(base)?code=\(String(repeating: "a", count: 4097))",
            "\(base)?code=\(code)&code=other-synthetic-code",
            "\(base)?code=\(code)&error=access_denied",
            "\(base)?code=\(code)&unexpected=1",
            "\(base)?error=access_denied",
            "\(base)?code=synthetic%20pkce%20code",
            "\(base)?code=synthetic%0Apkce%0Acode",
            "\(base)?code=synthetic%00pkce%00code",
        ]
        for text in invalidCallbacks {
            let url = URL(string: text)!
            do {
                _ = try configuration.authorizationCode(from: url)
                throw Failure(label: "invalid_callback_was_accepted")
            } catch is StagingAppleWebAuthenticationConfiguration.InvalidCallback {
                checks += 1
            }
        }
        let deletionBase = "healthcomp-staging-auth://apple/deletion-callback"
        let requestID = String(repeating: "a1", count: 32)
        let deletionURL = URL(string: "\(deletionBase)?request_id=\(requestID)")!
        do {
            try configuration.validateDeletionCallback(deletionURL, requestID: requestID)
            checks += 1
        } catch {
            throw Failure(label: "owned_deletion_handle_was_rejected")
        }
        let invalidDeletionCallbacks = [
            "healthcomp://apple/deletion-callback?request_id=\(requestID)",
            "healthcomp-staging-auth://other/deletion-callback?request_id=\(requestID)",
            "\(base)?request_id=\(requestID)",
            "\(deletionBase)/?request_id=\(requestID)",
            "healthcomp-staging-auth://apple/%64eletion-callback?request_id=\(requestID)",
            "healthcomp-staging-auth://user@apple/deletion-callback?request_id=\(requestID)",
            "healthcomp-staging-auth://apple:443/deletion-callback?request_id=\(requestID)",
            "\(deletionBase)?request_id=\(requestID)#fragment",
            "\(deletionBase)?request_id=\(String(repeating: "b", count: 64))",
            "\(deletionBase)?request_id=\(requestID)&request_id=\(requestID)",
            "\(deletionBase)?request_id=\(requestID)&code=synthetic-code",
            "\(deletionBase)?request_id=\(requestID)&status=deleted",
            "\(deletionBase)?request_id=\(requestID)&error=cancelled",
            "\(deletionBase)?code=\(code)",
            "\(deletionBase)?request_id=",
            deletionBase,
        ]
        for text in invalidDeletionCallbacks {
            do {
                try configuration.validateDeletionCallback(URL(string: text)!, requestID: requestID)
                throw Failure(label: "unowned_deletion_callback_was_accepted")
            } catch is StagingAppleWebAuthenticationConfiguration.InvalidCallback {
                checks += 1
            }
        }
        for invalidID in ["", "short", String(repeating: "a", count: 63),
                          String(repeating: "a", count: 65), String(repeating: "A", count: 64),
                          String(repeating: "g", count: 64), String(repeating: "０", count: 64)] {
            var components = URLComponents(string: deletionBase)!
            components.queryItems = [URLQueryItem(name: "request_id", value: invalidID)]
            do {
                try configuration.validateDeletionCallback(components.url!, requestID: invalidID)
                throw Failure(label: "invalid_pending_deletion_handle_was_accepted")
            } catch is StagingAppleWebAuthenticationConfiguration.InvalidCallback {
                checks += 1
            }
        }
        print("PASS: staging_apple_web_contract checks=\(checks) external_effects=0")
#else
        print("PASS: ordinary_build_web_auth_denial checks=\(checks) external_effects=0")
#endif
    }

    private struct Failure: Error, CustomStringConvertible {
        let label: String
        var description: String { "FAIL: \(label)" }
    }
}
