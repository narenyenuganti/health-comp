import Foundation
import Supabase

struct SupabaseConfiguration: Equatable, Sendable {
    let url: URL
    let publishableKey: String

    // Preserve Supabase Swift's project-scoped storage namespace explicitly.
    var authStorageKey: String {
        "sb-\(url.host!.split(separator: ".")[0])-auth-token"
    }

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

enum SupabaseTransport {
    fileprivate enum SignOutScope: String { case global, local }

    fileprivate static func confirmSignOut(
        accessToken: String, scope: SignOutScope,
        configuration: SupabaseConfiguration, session: URLSession
    ) async throws {
        var components = URLComponents(
            url: configuration.url.appendingPathComponent("auth/v1/logout"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [.init(name: "scope", value: scope.rawValue)]
        guard let url = components?.url else {
            throw AuthenticationClientFailure.operationFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode)
                || [401, 403, 404].contains(response.statusCode) else {
            throw AuthenticationClientFailure.operationFailed
        }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }
}

final class FailClosedAuthLocalStorage: AuthLocalStorage, @unchecked Sendable {
    private struct RemovalState {
        let key: String
        let failed: Bool
    }

    private let underlying: any AuthLocalStorage
    private let sessionKey: @Sendable () throws -> String
    private let isRemovalPending: @Sendable () -> Bool
    private let setRemovalPending: @Sendable (Bool) -> Void
    private let lock = NSLock()
    private var lastRemoval: RemovalState?

    init(
        underlying: any AuthLocalStorage,
        sessionKey: @escaping @Sendable () throws -> String,
        isRemovalPending: @escaping @Sendable () -> Bool = { false },
        setRemovalPending: @escaping @Sendable (Bool) -> Void = { _ in }
    ) {
        self.underlying = underlying
        self.sessionKey = sessionKey
        self.isRemovalPending = isRemovalPending
        self.setRemovalPending = setRemovalPending
    }

    func store(key: String, value: Data) throws {
        let isSession = key == (try sessionKey())
        if isSession, isRemovalPending() {
            // A fresh login cannot acknowledge retirement while the SDK could
            // still migrate a surviving legacy account over that new session.
            try underlying.remove(key: "supabase.session")
            guard try underlying.retrieve(key: "supabase.session") == nil else {
                throw AuthenticationClientFailure.operationFailed
            }
        }
        try underlying.store(key: key, value: value)
        if isSession { setRemovalPending(false) }
    }

    func retrieve(key: String) throws -> Data? {
        let expectedKey = try sessionKey()
        // The SDK also uses this store for PKCE and legacy session migration.
        // Neither auxiliary-key activity nor legacy migration may acknowledge
        // successful removal of the actual project session.
        guard key == expectedKey || key == "supabase.session" else {
            return try underlying.retrieve(key: key)
        }
        if isRemovalPending() {
            try? underlying.remove(key: key)
            guard key == expectedKey else { return nil }
            try? underlying.remove(key: "supabase.session")
            do {
                if try underlying.retrieve(key: key) == nil,
                   try underlying.retrieve(key: "supabase.session") == nil {
                    setRemovalPending(false)
                }
            } catch {}
            return nil
        }
        return try underlying.retrieve(key: key)
    }

    func remove(key: String) throws {
        guard key == (try sessionKey()) else {
            try underlying.remove(key: key)
            return
        }
        do {
            try underlying.remove(key: key)
            try underlying.remove(key: "supabase.session")
            guard try underlying.retrieve(key: key) == nil,
                  try underlying.retrieve(key: "supabase.session") == nil else {
                recordRemoval(key: key, failed: true)
                throw AuthenticationClientFailure.operationFailed
            }
            recordRemoval(key: key, failed: false)
        } catch {
            recordRemoval(key: key, failed: true)
            throw error
        }
    }

    func removeCurrentSession() throws {
        try remove(key: sessionKey())
    }

    func verifyLastRemoval() throws {
        guard let removal = lock.withLock({ lastRemoval }),
              !removal.failed,
              removal.key == (try sessionKey())
        else {
            throw AuthenticationClientFailure.operationFailed
        }
        do {
            guard try underlying.retrieve(key: removal.key) == nil,
                  try underlying.retrieve(key: "supabase.session") == nil else {
                throw AuthenticationClientFailure.operationFailed
            }
            setRemovalPending(false)
        } catch {
            throw AuthenticationClientFailure.operationFailed
        }
    }

    func prepareForRemovalVerification() {
        setRemovalPending(true)
        lock.withLock { lastRemoval = nil }
    }

    private func recordRemoval(key: String, failed: Bool) {
        lock.withLock {
            lastRemoval = RemovalState(key: key, failed: failed)
        }
    }
}

private final class AuthRemovalPendingStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    var isPending: Bool {
        defaults.bool(forKey: key)
    }

    func setPending(_ isPending: Bool) {
        defaults.set(isPending, forKey: key)
    }
}

/// Immutable operation owner. Keep this reference across asynchronous cleanup;
/// never reacquire another owner's callbacks after an await.
final class SupabaseAuthenticationLifetime: Sendable {
    let eventTasks = AuthenticationLifetimeTasks()
    let client: SupabaseClient
    let confirmGlobalSignOut: @Sendable (String) async throws -> Void
    let confirmLocalSignOut: @Sendable (String) async throws -> Void
    let prepareAuthSessionRemovalVerification: @Sendable () throws -> Void
    let verifyAuthSessionRemoved: @Sendable () throws -> Void
    let retireAuthStorage: @Sendable () throws -> Void

    init(
        client: SupabaseClient,
        confirmGlobalSignOut: @escaping @Sendable (String) async throws -> Void,
        confirmLocalSignOut: @escaping @Sendable (String) async throws -> Void = { _ in
            throw AuthenticationClientFailure.operationFailed
        },
        prepareAuthSessionRemovalVerification: @escaping @Sendable () throws -> Void,
        verifyAuthSessionRemoved: @escaping @Sendable () throws -> Void,
        retireAuthStorage: @escaping @Sendable () throws -> Void = {
            throw AuthenticationClientFailure.operationFailed
        }
    ) {
        self.client = client
        self.confirmGlobalSignOut = confirmGlobalSignOut
        self.confirmLocalSignOut = confirmLocalSignOut
        self.prepareAuthSessionRemovalVerification = prepareAuthSessionRemovalVerification
        self.verifyAuthSessionRemoved = verifyAuthSessionRemoved
        self.retireAuthStorage = retireAuthStorage
    }
}

struct SupabaseClientProvider: Sendable {
    private let sharedClient: SharedClientLifetime<SupabaseAuthenticationLifetime>

    init(
        makeClient: @escaping @Sendable () throws -> SupabaseClient,
        confirmGlobalSignOut: @escaping @Sendable (
            _ accessToken: String
        ) async throws -> Void = { _ in
            throw AuthenticationClientFailure.operationFailed
        },
        prepareAuthSessionRemovalVerification: @escaping @Sendable () throws -> Void = {},
        verifyAuthSessionRemoved: @escaping @Sendable () throws -> Void = {}
    ) {
        self.init(makeLifetime: {
            SupabaseAuthenticationLifetime(
                client: try makeClient(),
                confirmGlobalSignOut: confirmGlobalSignOut,
                prepareAuthSessionRemovalVerification: prepareAuthSessionRemovalVerification,
                verifyAuthSessionRemoved: verifyAuthSessionRemoved
            )
        })
    }

    private init(makeLifetime: @escaping @Sendable () throws -> SupabaseAuthenticationLifetime) {
        self.sharedClient = SharedClientLifetime(makeClient: makeLifetime)
    }

    func client() throws -> SupabaseClient {
        try authenticationLifetime().client
    }

    func authenticationLifetime() throws -> SupabaseAuthenticationLifetime {
        try sharedClient.client()
    }

    func retireAuthenticationLifetime(
        _ owner: SupabaseAuthenticationLifetime,
        beforeStorage: @escaping @Sendable () async throws -> Void = {}
    ) async throws {
        try await sharedClient.retire(owner) { retiring in
            // Registry admission is already closed while remote confirmation
            // is pending. Failure retains the same owner for an explicit retry.
            try await beforeStorage()
            try retiring.retireAuthStorage()
            await retiring.eventTasks.cancelAndDrain()
        }
    }

    func beginFreshAuthenticationLifetime() throws -> SupabaseAuthenticationLifetime {
        try sharedClient.beginFreshLifetime()
    }

    func eventOrigin(for owner: SupabaseAuthenticationLifetime) -> AuthenticationEventOrigin {
        AuthenticationEventOrigin(registry: sharedClient, owner: owner)
    }

    func confirmGlobalSignOut(accessToken: String) async throws {
        let owner = try authenticationLifetime()
        try await owner.confirmGlobalSignOut(accessToken)
    }

    func verifyAuthSessionRemoved() throws {
        try authenticationLifetime().verifyAuthSessionRemoved()
    }

    func prepareAuthSessionRemovalVerification() throws {
        try authenticationLifetime().prepareAuthSessionRemovalVerification()
    }

    static func live(
        infoDictionary: @escaping @Sendable () -> [String: Any] = {
            Bundle.main.infoDictionary ?? [:]
        },
        urlSession injectedURLSession: URLSession? = nil,
        authStorage injectedAuthStorage: FailClosedAuthLocalStorage? = nil,
        makeURLSession: @escaping @Sendable () -> URLSession = { SupabaseTransport.makeSession() }
    ) -> Self {
        let removalPendingKey =
            "HealthCompSupabaseAuthSessionRemovalPending"
        let pendingStore = AuthRemovalPendingStore(
            defaults: .standard,
            key: removalPendingKey
        )
        return Self(makeLifetime: {
            let configuration = try SupabaseConfiguration.parse(infoDictionary())
            // Default transports belong to this owner, not the provider cache.
            // An explicit session override remains a caller-owned testing seam.
            let urlSession = injectedURLSession ?? makeURLSession()
            let authStorage = injectedAuthStorage ?? FailClosedAuthLocalStorage(
                underlying: SupabaseAuthKeychainStorage(),
                sessionKey: {
                    configuration.authStorageKey
                },
                isRemovalPending: {
                    pendingStore.isPending
                },
                setRemovalPending: { isPending in
                    pendingStore.setPending(isPending)
                }
            )
            // Construct a new immutable guard with every admitted owner. Injected
            // backing storage is a test seam; the live backing adapter is also new.
            let lifetimeStorage = SupabaseAuthStorageLifetime(
                underlying: authStorage,
                prepareRemoval: { authStorage.prepareForRemovalVerification() },
                verifyRemoval: { try authStorage.verifyLastRemoval() }
            )
            let client = SupabaseClient(
                supabaseURL: configuration.url,
                supabaseKey: configuration.publishableKey,
                options: SupabaseClientOptions(
                    auth: .init(
                        storage: lifetimeStorage,
                        storageKey: configuration.authStorageKey
                    ),
                    global: .init(session: urlSession)
                )
            )
            return SupabaseAuthenticationLifetime(
                client: client,
                confirmGlobalSignOut: { accessToken in
                    try await SupabaseTransport.confirmSignOut(
                        accessToken: accessToken, scope: .global,
                        configuration: configuration, session: urlSession
                    )
                },
                confirmLocalSignOut: { accessToken in
                    try await SupabaseTransport.confirmSignOut(
                        accessToken: accessToken, scope: .local,
                        configuration: configuration, session: urlSession
                    )
                },
                prepareAuthSessionRemovalVerification: {
                    try lifetimeStorage.prepareForRemovalVerification()
                },
                verifyAuthSessionRemoved: {
                    try lifetimeStorage.verifyLastRemoval()
                },
                retireAuthStorage: {
                    try lifetimeStorage.removeSessionAndRetire {
                        try authStorage.removeCurrentSession()
                    }
                }
            )
        })
    }
}
