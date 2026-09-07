import Foundation

struct StagingAppleWebAuthenticationConfiguration: Equatable, Sendable {
    struct InvalidCallback: Error, Equatable {}

    let redirectURL: URL
    let clientID: String

    private init(clientID: String) {
        self.clientID = clientID
        redirectURL = URL(string: "healthcomp-staging-auth://apple/callback")!
    }

    // Eligibility only: this does not enable a UI, create an SDK client, or prove
    // the hosted provider and paired deletion flow have been qualified.
    static func parse(_ infoDictionary: [String: Any]) -> Self? {
#if HEALTHCOMP_STAGING
        guard infoDictionary["CFBundleIdentifier"] as? String
                == "com.narenyenuganti.HealthComp.staging",
              infoDictionary["SUPABASE_URL"] as? String
                == "https://xhfdfdrtxwptrwhvvlhg.supabase.co",
              infoDictionary["HEALTHCOMP_ENABLE_APPLE_WEB_SIGN_IN"] as? String
                == "YES",
              let clientID = infoDictionary["HEALTHCOMP_APPLE_WEB_CLIENT_ID"] as? String,
              clientID.range(of: #"\A[A-Za-z0-9.-]{1,255}\z"#, options: .regularExpression) != nil,
              clientID != "com.narenyenuganti.HealthComp",
              clientID != "com.narenyenuganti.HealthComp.staging"
        else { return nil }
        return Self(clientID: clientID)
#else
        return nil
#endif
    }

    // Call only for the callback delivered to the owning browser operation.
    // PKCE, cancellation, replay and server identity checks belong to that
    // operation; a well-shaped URL alone must never import an Auth session.
    func authorizationCode(from callbackURL: URL) throws -> String {
        guard let components = URLComponents(
            url: callbackURL,
            resolvingAgainstBaseURL: false
        ),
            components.scheme == redirectURL.scheme,
            components.host == redirectURL.host,
            components.percentEncodedPath == redirectURL.path,
            components.user == nil,
            components.password == nil,
            components.port == nil,
            components.fragment == nil,
            let items = components.queryItems,
            items.count == 1,
            items[0].name == "code",
            let code = items[0].value,
            (16...4096).contains(code.utf8.count),
            !code.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
            })
        else { throw InvalidCallback() }
        return code
    }

    // Shape/correlation only. The caller owns the pending operation and must
    // discard it on completion/cancellation. This does not prove deletion or
    // consume the server claim, and must never be used to import an Auth session.
    func validateDeletionCallback(_ callbackURL: URL, requestID: String) throws {
        guard requestID.utf8.count == 64,
              requestID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              components.scheme == redirectURL.scheme,
              components.host == redirectURL.host,
              components.percentEncodedPath == "/deletion-callback",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              let items = components.queryItems,
              items.count == 1,
              items[0].name == "request_id",
              items[0].value == requestID
        else { throw InvalidCallback() }
    }
}
