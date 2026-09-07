import Foundation

enum AppleWebAccountDeletionFailure: Error, Equatable {
    case reauthenticationRequired
    case invalidResponse
    case operationInProgress
}

struct AppleWebDeletionBeginRequest: Encodable, Equatable, Sendable {
    let claimVerifier: String
    let nonce: String
    enum CodingKeys: String, CodingKey {
        case claimVerifier = "claim_verifier"
        case nonce
    }
}

struct AppleWebDeletionBeginResponse: Decodable, Sendable {
    let requestID: String
    let authorizationURL: URL
    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case authorizationURL = "authorization_url"
    }
}

enum AppleWebDeletionCompletionRequest: Encodable, Equatable, Sendable {
    case resume
    case claim(requestID: String, verifier: String)
    enum CodingKeys: String, CodingKey {
        case resume
        case requestID = "request_id"
        case verifier = "claim_verifier"
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .resume: try values.encode(true, forKey: .resume)
        case let .claim(requestID, verifier):
            try values.encode(requestID, forKey: .requestID)
            try values.encode(verifier, forKey: .verifier)
        }
    }
}

struct AppleWebDeletionReceipt: Decodable, Sendable {
    enum Status: String, Decodable, Sendable { case deleted }
    let status: Status
}

enum AppleWebDeletionHTTP {
    static func decodeCompletion(statusCode: Int, data: Data) throws -> AppleWebDeletionReceipt {
        guard data.count <= 512,
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
        else { throw AppleWebAccountDeletionFailure.invalidResponse }
        if statusCode == 200, body == ["status": "deleted"] {
            return AppleWebDeletionReceipt(status: .deleted)
        }
        if statusCode == 401, body == ["error": "reauthentication_required"] {
            throw AppleWebAccountDeletionFailure.reauthenticationRequired
        }
        throw AppleWebAccountDeletionFailure.invalidResponse
    }
}

@MainActor
final class AppleWebAccountDeletionClient {
    let configuration: StagingAppleWebAuthenticationConfiguration
    let clientID: String
    let browser: AppleWebAuthenticationSessionClient
    let secrets: () throws -> AppleWebDeletionBeginRequest
    let begin: (AppleWebDeletionBeginRequest) async throws -> AppleWebDeletionBeginResponse
    let complete: (AppleWebDeletionCompletionRequest) async throws -> AppleWebDeletionReceipt
    private var isRunning = false

    init(
        configuration: StagingAppleWebAuthenticationConfiguration,
        clientID: String,
        browser: AppleWebAuthenticationSessionClient,
        secrets: @escaping () throws -> AppleWebDeletionBeginRequest,
        begin: @escaping (AppleWebDeletionBeginRequest) async throws -> AppleWebDeletionBeginResponse,
        complete: @escaping (AppleWebDeletionCompletionRequest) async throws -> AppleWebDeletionReceipt
    ) {
        self.configuration = configuration
        self.clientID = clientID
        self.browser = browser
        self.secrets = secrets
        self.begin = begin
        self.complete = complete
    }

    func deleteConfirmedAccount() async throws {
        // Caller must already hold the app-auth transition and user confirmation.
        // Resume can advance server deletion; it is not an inventory operation.
        guard !isRunning else { throw AppleWebAccountDeletionFailure.operationInProgress }
        try Task.checkCancellation()
        guard clientID.range(of: #"\A[A-Za-z0-9.-]{1,255}\z"#, options: .regularExpression) != nil,
              clientID != "com.narenyenuganti.HealthComp.staging",
              clientID != "com.narenyenuganti.HealthComp"
        else { throw AppleWebAccountDeletionFailure.invalidResponse }
        isRunning = true
        defer { isRunning = false }
        do {
            _ = try await complete(.resume)
            return
        } catch AppleWebAccountDeletionFailure.reauthenticationRequired {
            // Only this explicit server result permits a new Apple grant.
        }
        try Task.checkCancellation()
        let request = try secrets()
        guard Self.isHandle(request.claimVerifier), Self.isHandle(request.nonce) else {
            throw AppleWebAccountDeletionFailure.invalidResponse
        }
        let response = try await begin(request)
        try Task.checkCancellation()
        try validate(response, nonce: request.nonce)
        let callback = try await browser.authenticate(
            response.authorizationURL, configuration.redirectURL.scheme!
        )
        try Task.checkCancellation()
        try configuration.validateDeletionCallback(callback, requestID: response.requestID)
        _ = try await complete(.claim(requestID: response.requestID, verifier: request.claimVerifier))
        // Preserve an actual confirmed receipt even if cancellation raced it.
        // No detached timeout and no inference that a failed request rolled back.
    }

    private func validate(_ response: AppleWebDeletionBeginResponse, nonce: String) throws {
        guard Self.isHandle(response.requestID),
              let url = URLComponents(url: response.authorizationURL, resolvingAgainstBaseURL: false),
              url.scheme == "https", url.host == "appleid.apple.com",
              url.percentEncodedPath == "/auth/authorize",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let items = url.queryItems, items.count == 6,
              Set(items.map(\.name)) == Set(["client_id", "redirect_uri", "response_type", "response_mode", "state", "nonce"])
        else { throw AppleWebAccountDeletionFailure.invalidResponse }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard !clientID.isEmpty,
              values["client_id"] == clientID,
              values["redirect_uri"] == "https://xhfdfdrtxwptrwhvvlhg.supabase.co/functions/v1/apple-deletion-callback",
              values["response_type"] == "code", values["response_mode"] == "form_post",
              values["nonce"] == nonce, Self.isHandle(values["state"] ?? "")
        else { throw AppleWebAccountDeletionFailure.invalidResponse }
    }

    private static func isHandle(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
