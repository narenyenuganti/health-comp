import Dependencies
import DependenciesMacros
import Foundation

enum AuthResult: Equatable, Sendable {
    case existingUser(User)
    case newUser(UUID)
}

enum AuthError: Error, Equatable, LocalizedError {
    case signInFailed(String)
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .signInFailed(let message): return message
        case .sessionExpired: return "Session expired. Please sign in again."
        }
    }
}

@DependencyClient
struct AuthClient: Sendable {
    var signInWithApple: @Sendable () async throws -> AuthResult
    var signOut: @Sendable () async throws -> Void
    var currentUserId: @Sendable () async -> UUID? = { nil }
    var restoreSession: @Sendable () async throws -> AuthResult
}

extension AuthClient: TestDependencyKey {
    static let testValue = AuthClient()
}

extension DependencyValues {
    var authClient: AuthClient {
        get { self[AuthClient.self] }
        set { self[AuthClient.self] = newValue }
    }
}
