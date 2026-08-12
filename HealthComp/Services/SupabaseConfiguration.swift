import Foundation
import Supabase

struct SupabaseConfiguration: Equatable, Sendable {
    let url: URL
    let publishableKey: String

    static func parse(_ infoDictionary: [String: Any]) throws -> Self {
        guard let rawURL = trimmedString(
            infoDictionary["SUPABASE_URL"]
        ) else {
            throw SupabaseConfigurationError.missingURL
        }
        guard !isPlaceholderURL(rawURL) else {
            throw SupabaseConfigurationError.placeholderURL
        }
        guard let components = URLComponents(string: rawURL),
              let scheme = components.scheme,
              let host = components.host,
              !host.isEmpty,
              let url = components.url
        else {
            throw SupabaseConfigurationError.invalidURL
        }
        guard scheme.lowercased() == "https" else {
            throw SupabaseConfigurationError.insecureURL
        }

        guard let publishableKey = trimmedString(
            infoDictionary["SUPABASE_PUBLISHABLE_KEY"]
        ) else {
            throw SupabaseConfigurationError.missingPublishableKey
        }
        guard !isPlaceholderKey(publishableKey) else {
            throw SupabaseConfigurationError.placeholderPublishableKey
        }
        guard !isServiceRoleKey(publishableKey) else {
            throw SupabaseConfigurationError.serviceRolePublishableKey
        }

        return Self(url: url, publishableKey: publishableKey)
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isPlaceholderURL(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.contains("$(")
            || normalized.contains("placeholder")
            || normalized.contains("your-project")
            || normalized.contains("example.com")
            || normalized.contains("replace-me")
    }

    private static func isPlaceholderKey(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.contains("$(")
            || normalized.contains("placeholder")
            || normalized.contains("your-publishable-key")
            || normalized.contains("replace-me")
    }

    private static func isServiceRoleKey(_ value: String) -> Bool {
        let privatePrefix = "sb_" + "secret_"
        if value.lowercased().hasPrefix(privatePrefix) {
            return true
        }

        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let payload = base64URLDecoded(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: payload)
        else {
            return false
        }
        return containsServiceRole(object)
    }

    private static func base64URLDecoded(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    private static func containsServiceRole(_ value: Any) -> Bool {
        let serviceRole = "service" + "_role"
        if let dictionary = value as? [String: Any] {
            for (key, nestedValue) in dictionary {
                if key.lowercased() == "role",
                   let role = nestedValue as? String,
                   role.lowercased() == serviceRole {
                    return true
                }
                if containsServiceRole(nestedValue) {
                    return true
                }
            }
        } else if let array = value as? [Any] {
            return array.contains(where: containsServiceRole)
        }
        return false
    }
}

enum SupabaseConfigurationError:
    Error, Equatable, Sendable, CustomStringConvertible
{
    case missingURL
    case invalidURL
    case insecureURL
    case placeholderURL
    case missingPublishableKey
    case placeholderPublishableKey
    case serviceRolePublishableKey

    var description: String {
        switch self {
        case .missingURL:
            "Supabase URL is missing."
        case .invalidURL:
            "Supabase URL is invalid."
        case .insecureURL:
            "Supabase URL must use HTTPS."
        case .placeholderURL:
            "Supabase URL is still a placeholder."
        case .missingPublishableKey:
            "Supabase publishable key is missing."
        case .placeholderPublishableKey:
            "Supabase publishable key is still a placeholder."
        case .serviceRolePublishableKey:
            "A private Supabase key cannot be used by the app."
        }
    }
}

struct SupabaseClientProvider: Sendable {
    private let makeClient: @Sendable () throws -> SupabaseClient

    init(makeClient: @escaping @Sendable () throws -> SupabaseClient) {
        self.makeClient = makeClient
    }

    func client() throws -> SupabaseClient {
        try makeClient()
    }

    static func live(
        infoDictionary: @escaping @Sendable () -> [String: Any] = {
            Bundle.main.infoDictionary ?? [:]
        }
    ) -> Self {
        Self {
            let configuration = try SupabaseConfiguration.parse(infoDictionary())
            return SupabaseClient(
                supabaseURL: configuration.url,
                supabaseKey: configuration.publishableKey
            )
        }
    }
}
