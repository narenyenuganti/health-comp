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

// MARK: - Live Implementation

import AuthenticationServices
import Supabase

extension AuthClient: DependencyKey {
    static let liveValue: AuthClient = {
        let supabase = SupabaseService.shared

        return AuthClient(
            signInWithApple: {
                let credential = try await AppleSignInHelper.performSignIn()

                guard let tokenData = credential.identityToken,
                      let idToken = String(data: tokenData, encoding: .utf8) else {
                    throw AuthError.signInFailed("Missing identity token from Apple")
                }

                let session = try await supabase.auth.signInWithIdToken(
                    credentials: .init(provider: .apple, idToken: idToken)
                )

                let profile: User? = try? await supabase
                    .from("users")
                    .select()
                    .eq("id", value: session.user.id.uuidString)
                    .single()
                    .execute()
                    .value

                if let profile {
                    return .existingUser(profile)
                } else {
                    return .newUser(session.user.id)
                }
            },
            signOut: {
                try await supabase.auth.signOut()
            },
            currentUserId: {
                try? await supabase.auth.session.user.id
            },
            restoreSession: {
                let session = try await supabase.auth.session

                let profile: User? = try? await supabase
                    .from("users")
                    .select()
                    .eq("id", value: session.user.id.uuidString)
                    .single()
                    .execute()
                    .value

                if let profile {
                    return .existingUser(profile)
                } else {
                    return .newUser(session.user.id)
                }
            }
        )
    }()
}

// MARK: - Apple Sign In Helper

final class AppleSignInHelper: NSObject, ASAuthorizationControllerDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?

    @MainActor
    static func performSignIn() async throws -> ASAuthorizationAppleIDCredential {
        let helper = AppleSignInHelper()
        return try await withCheckedThrowingContinuation { continuation in
            helper.continuation = continuation
            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.fullName, .email]

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = helper
            controller.performRequests()
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            continuation?.resume(throwing: AuthError.signInFailed("Invalid credential type"))
            return
        }
        continuation?.resume(returning: credential)
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        continuation?.resume(throwing: AuthError.signInFailed(error.localizedDescription))
    }
}

extension DependencyValues {
    var authClient: AuthClient {
        get { self[AuthClient.self] }
        set { self[AuthClient.self] = newValue }
    }
}
