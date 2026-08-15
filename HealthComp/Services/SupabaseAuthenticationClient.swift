import AuthenticationServices
import Foundation
import Supabase
import UIKit

struct SupabaseAuthenticationSession: Equatable, Sendable {
    let userID: UUID
    let expiresAt: Date

    var appValue: AuthenticationSession {
        AuthenticationSession(userID: userID, expiresAt: expiresAt)
    }
}

enum SupabaseAuthenticationEvent: Equatable, Sendable {
    case tokenRefreshed(SupabaseAuthenticationSession)
    case signedOut
    case accountDeleted
    case ignored
}

struct SupabaseAuthenticationOperations: Sendable {
    var currentSession: @Sendable () async throws ->
        SupabaseAuthenticationSession?
    var refreshSession: @Sendable () async throws -> SupabaseAuthenticationSession
    var exchangeAppleIDToken: @Sendable (
        _ identityToken: String,
        _ rawNonce: String
    ) async throws -> SupabaseAuthenticationSession
    var bootstrapProfile: @Sendable (String?) async throws -> AuthenticatedProfile
    var updateProfile: @Sendable (String) async throws -> AuthenticatedProfile = { _ in
        throw AuthenticationClientFailure.operationFailed
    }
    var events: @Sendable () -> AsyncStream<SupabaseAuthenticationEvent>
    var clearLocalSession: @Sendable () async -> Void
    var remoteSignOut: @Sendable () async throws -> Void
    var classifyRefreshFailure: @Sendable (
        _ error: any Error
    ) -> AuthenticationClientFailure
}

struct AppleAuthorizationClient: Sendable {
    var authorize: @MainActor @Sendable (
        _ nonceChallenge: String
    ) async throws -> Data?

    init(
        authorize: @escaping @MainActor @Sendable (
            _ nonceChallenge: String
        ) async throws -> Data?
    ) {
        self.authorize = authorize
    }
}

enum SupabaseAuthenticationClient {
    static func make(
        operations: SupabaseAuthenticationOperations,
        appleAuthorization: AppleAuthorizationClient,
        nonce: @escaping @Sendable () throws -> AppleSignInNonce = {
            try AppleSignInNonce.generate()
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> AuthenticationClient {
        AuthenticationClient(
            restoreSession: {
                let current: SupabaseAuthenticationSession?
                do {
                    current = try await operations.currentSession()
                } catch let failure as AuthenticationClientFailure {
                    throw failure
                } catch {
                    throw AuthenticationClientFailure.operationFailed
                }
                guard let current else {
                    return nil
                }
                let sdkExpiryMargin: TimeInterval = 30
                let refreshThreshold = now().addingTimeInterval(
                    sdkExpiryMargin
                )
                if current.expiresAt >= refreshThreshold {
                    return current.appValue
                }
                do {
                    return try await operations.refreshSession().appValue
                } catch {
                    let failure = operations.classifyRefreshFailure(error)
                    if failure == .terminalSession {
                        await operations.clearLocalSession()
                    }
                    throw failure
                }
            },
            signInWithApple: {
                let nonce = try nonce()
                let identityToken = try await appleAuthorization.authorize(
                    nonce.challenge
                )
                let token = try AppleIdentityTokenNonceValidator.validate(
                    identityToken: identityToken,
                    expectedChallenge: nonce.challenge
                )
                return try await operations.exchangeAppleIDToken(
                    token,
                    nonce.rawValue
                ).appValue
            },
            bootstrapProfile: { displayName in
                do {
                    return try await operations.bootstrapProfile(displayName)
                } catch {
                    throw classifyBootstrapFailure(error)
                }
            },
            updateProfile: { displayName in
                do {
                    return try await operations.updateProfile(displayName)
                } catch {
                    throw classifyBootstrapFailure(error)
                }
            },
            events: {
                AsyncStream { continuation in
                    let task = Task {
                        for await event in operations.events() {
                            guard !Task.isCancelled else { break }
                            switch event {
                            case let .tokenRefreshed(session):
                                continuation.yield(
                                    .sessionRefreshed(session.appValue)
                                )
                            case .signedOut:
                                continuation.yield(.signedOut)
                            case .accountDeleted:
                                continuation.yield(.accountDeleted)
                            case .ignored:
                                continue
                            }
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            signOut: {
                try? await operations.remoteSignOut()
            }
        )
    }

    static func live(
        provider: SupabaseClientProvider,
        appleAuthorization: AppleAuthorizationClient = .live
    ) -> AuthenticationClient {
        make(
            operations: .live(provider: provider),
            appleAuthorization: appleAuthorization
        )
    }

    static func classifyBootstrapFailure(
        code: String?,
        message: String
    ) -> AuthenticationClientFailure {
        switch (code, message) {
        case ("P0001", "display_name_required"):
            .displayNameRequired
        case ("22023", "invalid_display_name"):
            .invalidDisplayName
        case ("42501", "authentication_required"),
             ("42501", "active_profile_required"):
            .terminalSession
        default:
            .operationFailed
        }
    }

    private static func classifyBootstrapFailure(
        _ error: any Error
    ) -> AuthenticationClientFailure {
        if let failure = error as? AuthenticationClientFailure {
            return failure
        }
        guard let error = error as? PostgrestError else {
            return .operationFailed
        }
        return classifyBootstrapFailure(
            code: error.code,
            message: error.message
        )
    }
}

private extension SupabaseAuthenticationOperations {
    static func live(provider: SupabaseClientProvider) -> Self {
        let clientBox = SupabaseAuthenticationClientBox(provider: provider)
        return Self(
            currentSession: {
                guard let session = try await clientBox.client().auth.currentSession
                else { return nil }
                return SupabaseAuthenticationSession(session)
            },
            refreshSession: {
                let session = try await clientBox.client().auth.refreshSession()
                return SupabaseAuthenticationSession(session)
            },
            exchangeAppleIDToken: { identityToken, rawNonce in
                let session = try await clientBox.client().auth.signInWithIdToken(
                    credentials: OpenIDConnectCredentials(
                        provider: .apple,
                        idToken: identityToken,
                        nonce: rawNonce
                    )
                )
                return SupabaseAuthenticationSession(session)
            },
            bootstrapProfile: { suggestedDisplayName in
                struct Parameters: Encodable {
                    let suggestedDisplayName: String?

                    enum CodingKeys: String, CodingKey {
                        case suggestedDisplayName = "suggested_display_name"
                    }
                }
                return try await clientBox.client()
                    .rpc(
                        "bootstrap_current_profile",
                        params: Parameters(
                            suggestedDisplayName: suggestedDisplayName
                        )
                    )
                    .execute()
                    .value
            },
            updateProfile: { displayName in
                struct Parameters: Encodable {
                    let newDisplayName: String

                    enum CodingKeys: String, CodingKey {
                        case newDisplayName = "new_display_name"
                    }
                }
                return try await clientBox.client()
                    .rpc(
                        "update_current_profile",
                        params: Parameters(newDisplayName: displayName)
                    )
                    .execute()
                    .value
            },
            events: {
                AsyncStream { continuation in
                    let task = Task {
                        do {
                            let client = try await clientBox.client()
                            for await change in client.auth.authStateChanges {
                                guard !Task.isCancelled else { break }
                                switch change.event {
                                case .tokenRefreshed:
                                    if let session = change.session {
                                        continuation.yield(
                                            .tokenRefreshed(
                                                SupabaseAuthenticationSession(
                                                    session
                                                )
                                            )
                                        )
                                    }
                                case .signedOut:
                                    continuation.yield(.signedOut)
                                case .userDeleted:
                                    continuation.yield(.accountDeleted)
                                default:
                                    continuation.yield(.ignored)
                                }
                            }
                        } catch {}
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            clearLocalSession: {
                guard let client = try? await clientBox.client() else { return }
                try? await client.auth.signOut(scope: .local)
            },
            remoteSignOut: {
                try await clientBox.client().auth.signOut(scope: .global)
            },
            classifyRefreshFailure: { error in
                classifyRefreshFailure(error)
            }
        )
    }

    static func classifyRefreshFailure(
        _ error: any Error
    ) -> AuthenticationClientFailure {
        guard let authError = error as? AuthError else {
            return .refreshRetryable
        }
        switch authError.errorCode {
        case .sessionNotFound, .refreshTokenNotFound, .refreshTokenAlreadyUsed,
             .userNotFound, .invalidJWT:
            return .terminalSession
        default:
            return .refreshRetryable
        }
    }
}

private extension SupabaseAuthenticationSession {
    init(_ session: Session) {
        self.init(
            userID: session.user.id,
            expiresAt: Date(timeIntervalSince1970: session.expiresAt)
        )
    }
}

private actor SupabaseAuthenticationClientBox {
    private let provider: SupabaseClientProvider
    private var cachedClient: SupabaseClient?

    init(provider: SupabaseClientProvider) {
        self.provider = provider
    }

    func client() throws -> SupabaseClient {
        if let cachedClient { return cachedClient }
        let client = try provider.client()
        cachedClient = client
        return client
    }
}

private extension AppleAuthorizationClient {
    static let live = Self { nonceChallenge in
        try await AppleAuthorizationBridge.authorize(
            nonceChallenge: nonceChallenge
        )
    }
}

struct AppleAuthorizationCancellationState {
    private(set) var isCancelled = false

    mutating func cancel() {
        isCancelled = true
    }
}

@MainActor
private final class AppleAuthorizationBridge:
    NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    private var continuation: CheckedContinuation<Data?, any Error>?
    private var controller: ASAuthorizationController?
    private var cancellationState = AppleAuthorizationCancellationState()

    static func authorize(nonceChallenge: String) async throws -> Data? {
        let bridge = AppleAuthorizationBridge()
        return try await withTaskCancellationHandler {
            try await bridge.perform(nonceChallenge: nonceChallenge)
        } onCancel: {
            Task { @MainActor in bridge.cancel() }
        }
    }

    private func perform(nonceChallenge: String) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            guard !cancellationState.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = []
            request.nonce = nonceChallenge
            let controller = ASAuthorizationController(
                authorizationRequests: [request]
            )
            self.controller = controller
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential
            as? ASAuthorizationAppleIDCredential
        else {
            finish(throwing: AuthenticationClientFailure.invalidCredential)
            return
        }
        finish(returning: credential.identityToken)
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: any Error
    ) {
        if (error as? ASAuthorizationError)?.code == .canceled {
            finish(throwing: AuthenticationClientFailure.cancelled)
        } else {
            finish(throwing: AuthenticationClientFailure.invalidCredential)
        }
    }

    func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? ASPresentationAnchor()
    }

    private func cancel() {
        cancellationState.cancel()
        controller?.cancel()
        finish(throwing: CancellationError())
    }

    private func finish(returning identityToken: Data?) {
        guard let continuation else { return }
        self.continuation = nil
        controller = nil
        continuation.resume(returning: identityToken)
    }

    private func finish(throwing error: any Error) {
        guard let continuation else { return }
        self.continuation = nil
        controller = nil
        continuation.resume(throwing: error)
    }
}
