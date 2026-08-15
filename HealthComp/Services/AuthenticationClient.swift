import CryptoKit
import Dependencies
import Foundation
import Security

struct AuthenticationSession: Codable, Equatable, Sendable {
    let userID: UUID
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case expiresAt = "expires_at"
    }

    func isExpired(at date: Date) -> Bool {
        expiresAt <= date
    }
}

struct AuthenticatedProfile: Codable, Equatable, Sendable {
    let id: UUID
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

struct AccountDeletionRequest: Codable, Equatable, Sendable {
    let authorizationCode: String
    let nonce: String

    enum CodingKeys: String, CodingKey {
        case authorizationCode = "authorization_code"
        case nonce
    }
}

struct AccountDeletionReceipt: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable {
        case deleted
    }

    let status: Status
}

enum AuthenticationEvent: Equatable, Sendable {
    case sessionRefreshed(AuthenticationSession)
    case signedOut
    case accountDeleted
}

enum AuthenticationClientFailure: Error, Equatable, Sendable {
    case cancelled
    case invalidCredential
    case nonceMismatch
    case nonceGenerationFailed
    case sessionExpired
    case refreshRetryable
    case terminalSession
    case displayNameRequired
    case invalidDisplayName
    case reauthenticationRequired
    case operationFailed
}

struct AuthenticationClient: Sendable {
    var restoreSession: @Sendable () async throws -> AuthenticationSession?
    var signInWithApple: @MainActor @Sendable () async throws -> AuthenticationSession
    var bootstrapProfile: @Sendable (String?) async throws -> AuthenticatedProfile
    var updateProfile: @Sendable (String) async throws -> AuthenticatedProfile
    var deleteAccount: @MainActor @Sendable () async throws -> Void
    var events: @Sendable () -> AsyncStream<AuthenticationEvent>
    var signOut: @Sendable () async -> Void

    init(
        restoreSession: @escaping @Sendable () async throws -> AuthenticationSession?,
        signInWithApple: @escaping @MainActor @Sendable () async throws -> AuthenticationSession,
        bootstrapProfile: @escaping @Sendable (String?) async throws -> AuthenticatedProfile,
        updateProfile: @escaping @Sendable (String) async throws -> AuthenticatedProfile = { _ in
            throw AuthenticationClientFailure.operationFailed
        },
        deleteAccount: @escaping @MainActor @Sendable () async throws -> Void = {
            throw AuthenticationClientFailure.operationFailed
        },
        events: @escaping @Sendable () -> AsyncStream<AuthenticationEvent>,
        signOut: @escaping @Sendable () async -> Void
    ) {
        self.restoreSession = restoreSession
        self.signInWithApple = signInWithApple
        self.bootstrapProfile = bootstrapProfile
        self.updateProfile = updateProfile
        self.deleteAccount = deleteAccount
        self.events = events
        self.signOut = signOut
    }
}

extension AuthenticationClient: TestDependencyKey {
    static let testValue = Self(
        restoreSession: { nil },
        signInWithApple: { throw AuthenticationClientFailure.operationFailed },
        bootstrapProfile: { _ in
            throw AuthenticationClientFailure.operationFailed
        },
        updateProfile: { _ in
            throw AuthenticationClientFailure.operationFailed
        },
        deleteAccount: {
            throw AuthenticationClientFailure.operationFailed
        },
        events: { AsyncStream { $0.finish() } },
        signOut: {}
    )
}

extension DependencyValues {
    var authenticationClient: AuthenticationClient {
        get { self[AuthenticationClient.self] }
        set { self[AuthenticationClient.self] = newValue }
    }
}

struct AppleSignInNonce: Equatable, Sendable {
    let rawValue: String
    let challenge: String

    typealias RandomData = (_ byteCount: Int) throws -> Data

    static func generate(
        randomData: RandomData = secureRandomData
    ) throws -> Self {
        let data = try randomData(32)
        guard data.count == 32 else {
            throw AuthenticationClientFailure.nonceGenerationFailed
        }
        let rawValue = data.base64URLEncodedString
        return Self(rawValue: rawValue, challenge: challenge(for: rawValue))
    }

    static func challenge(for rawValue: String) -> String {
        SHA256.hash(data: Data(rawValue.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func secureRandomData(byteCount: Int) throws -> Data {
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw AuthenticationClientFailure.nonceGenerationFailed
        }
        return data
    }
}

enum AppleIdentityTokenNonceValidator {
    static func validate(
        identityToken: Data?,
        expectedChallenge: String
    ) throws -> String {
        guard let identityToken,
              let token = String(data: identityToken, encoding: .utf8)
        else {
            throw AuthenticationClientFailure.invalidCredential
        }
        let segments = token.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard segments.count == 3,
              let payloadData = Data(base64URL: String(segments[1])),
              let payload = try? JSONSerialization.jsonObject(
                with: payloadData
              ) as? [String: Any],
              let nonce = payload["nonce"] as? String,
              nonce == expectedChallenge
        else {
            throw AuthenticationClientFailure.nonceMismatch
        }
        return token
    }
}

extension JSONEncoder {
    static var healthCompAuth: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

extension JSONDecoder {
    static var healthCompAuth: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

private extension Data {
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var value = base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder != 0 {
            value += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: value)
    }
}
