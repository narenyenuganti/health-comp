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
    indirect case owned(AuthenticationEventOrigin, SupabaseAuthenticationEvent)
    case tokenRefreshed(SupabaseAuthenticationSession)
    case signedOut
    case accountDeleted
    case ignored

    var appValue: AuthenticationEvent? {
        switch self {
        case let .owned(origin, event):
            if case .owned = event { return nil }
            return event.appValue.map { .owned(origin, $0) }
        case let .tokenRefreshed(session): return .sessionRefreshed(session.appValue)
        case .signedOut: return .signedOut
        case .accountDeleted: return .accountDeleted
        case .ignored: return nil
        }
    }
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
    var requestAccountDeletion: @Sendable (
        AccountDeletionRequest
    ) async throws -> AccountDeletionReceipt = { _ in
        throw AuthenticationClientFailure.operationFailed
    }
    var events: @Sendable () -> AsyncStream<SupabaseAuthenticationEvent>
    var clearLocalSession: @Sendable () async throws -> Void
    var remoteSignOut: @Sendable () async throws -> Void
    var classifyRefreshFailure: @Sendable (
        _ error: any Error
    ) -> AuthenticationClientFailure
}

struct AppleAuthorizationClient: Sendable {
    var authorize: @MainActor @Sendable (
        _ nonceChallenge: String
    ) async throws -> Data?
    var reauthorizeForDeletion: @MainActor @Sendable (
        _ nonceChallenge: String
    ) async throws -> Data?

    init(
        authorize: @escaping @MainActor @Sendable (
            _ nonceChallenge: String
        ) async throws -> Data?
    ) {
        self.authorize = authorize
        self.reauthorizeForDeletion = { _ in
            throw AuthenticationClientFailure.reauthenticationRequired
        }
    }

    init(
        authorize: @escaping @MainActor @Sendable (
            _ nonceChallenge: String
        ) async throws -> Data?,
        reauthorizeForDeletion: @escaping @MainActor @Sendable (
            _ nonceChallenge: String
        ) async throws -> Data?
    ) {
        self.authorize = authorize
        self.reauthorizeForDeletion = reauthorizeForDeletion
    }
}

enum SupabaseAuthenticationClient {
    static func make(
        operations: SupabaseAuthenticationOperations,
        appleAuthorization: AppleAuthorizationClient,
        browserDeletion: (@MainActor @Sendable () async throws -> Void)? = nil,
        browserSignIn: (@MainActor @Sendable () async throws -> AuthenticationSession)? = nil,
        finishRetirement: (@Sendable () async throws -> Void)? = nil,
        nonce: @escaping @Sendable () throws -> AppleSignInNonce = {
            try AppleSignInNonce.generate()
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> AuthenticationClient {
        var client = AuthenticationClient(
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
                    if failure == .terminalSession, finishRetirement == nil {
                        do {
                            try await operations.clearLocalSession()
                        } catch {
                            // Do not present ordinary session expiry when local
                            // retirement could not be confirmed. Keep retry available.
                            throw AuthenticationClientFailure.operationFailed
                        }
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
            deleteAccount: {
                let nonce = try nonce()
                let authorizationCodeData: Data?
                do {
                    authorizationCodeData = try await appleAuthorization
                        .reauthorizeForDeletion(nonce.challenge)
                } catch is CancellationError {
                    throw AuthenticationClientFailure.cancelled
                } catch let failure as AuthenticationClientFailure {
                    throw failure
                } catch {
                    throw AuthenticationClientFailure
                        .reauthenticationRequired
                }
                guard let authorizationCodeData,
                      let authorizationCode = String(
                        data: authorizationCodeData,
                        encoding: .utf8
                      ),
                      (16...4096).contains(authorizationCode.count),
                      !authorizationCode.unicodeScalars.contains(where: {
                        CharacterSet.whitespacesAndNewlines.contains($0)
                            || CharacterSet.controlCharacters.contains($0)
                      })
                else {
                    throw AuthenticationClientFailure
                        .reauthenticationRequired
                }

                let receipt: AccountDeletionReceipt
                do {
                    receipt = try await operations.requestAccountDeletion(
                        AccountDeletionRequest(
                            authorizationCode: authorizationCode,
                            nonce: nonce.challenge
                        )
                    )
                } catch {
                    throw SupabaseAuthenticationOperations
                        .classifyAccountDeletionFailure(error)
                }
                guard receipt.status == .deleted else {
                    throw AuthenticationClientFailure.operationFailed
                }
                // Preserve the server receipt for the app's post-runtime,
                // retryable retirement stage when that boundary is configured.
                if finishRetirement == nil {
                    try await operations.clearLocalSession()
                }
            },
            events: {
                AsyncStream { continuation in
                    let task = Task {
                        for await event in operations.events() {
                            guard !Task.isCancelled else { break }
                            if let appEvent = event.appValue {
                                continuation.yield(appEvent)
                            }
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            signOut: {
                do {
                    try await operations.remoteSignOut()
                } catch let failure as AuthenticationClientFailure {
                    throw failure
                } catch {
                    throw AuthenticationClientFailure.operationFailed
                }
            }
        )
        if let browserDeletion {
            client.deleteAccountInBrowser = {
                do {
                    try await browserDeletion()
                } catch is CancellationError {
                    throw AuthenticationClientFailure.cancelled
                } catch AppleWebAuthenticationSessionFailure.cancelled {
                    throw AuthenticationClientFailure.cancelled
                } catch let failure as AuthenticationClientFailure {
                    throw failure
                } catch {
                    throw AuthenticationClientFailure.operationFailed
                }
                if finishRetirement == nil {
                    try await operations.clearLocalSession()
                }
            }
        }
        let gate = ExplicitAuthenticationOperationGate()
        if let finishRetirement {
            client.finishRetirement = {
                try await gate.run { try await finishRetirement() }
            }
        }
        // Restoration can refresh or retire a session, so it participates in
        // the same explicit-operation ownership as sign-in and sign-out.
        let restoreSession = client.restoreSession
        client.restoreSession = {
            try await gate.run { try await restoreSession() }
        }
        let bootstrapProfile = client.bootstrapProfile
        client.bootstrapProfile = { displayName in
            try await gate.run { try await bootstrapProfile(displayName) }
        }
        let updateProfile = client.updateProfile
        client.updateProfile = { displayName in
            try await gate.run { try await updateProfile(displayName) }
        }
        let nativeSignIn = client.signInWithApple
        client.signInWithApple = {
            try await gate.run { try await nativeSignIn() }
        }
        let nativeDeletion = client.deleteAccount
        client.deleteAccount = {
            try await gate.run { try await nativeDeletion() }
        }
        let signOut = client.signOut
        client.signOut = {
            try await gate.run { try await signOut() }
        }
        if let browserDeletion = client.deleteAccountInBrowser {
            client.deleteAccountInBrowser = {
                try await gate.run { try await browserDeletion() }
            }
        }
        if let browserSignIn {
            client.signInWithAppleInBrowser = {
                try await gate.run {
                    do {
                        return try await browserSignIn()
                    } catch is CancellationError {
                        throw AuthenticationClientFailure.cancelled
                    } catch AppleWebAuthenticationSessionFailure.cancelled {
                        throw AuthenticationClientFailure.cancelled
                    } catch let failure as AuthenticationClientFailure {
                        throw failure
                    } catch {
                        throw AuthenticationClientFailure.operationFailed
                    }
                }
            }
        }
        return client
    }

    static func live(
        provider: SupabaseClientProvider,
        appleAuthorization: AppleAuthorizationClient = .live,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        browser: AppleWebAuthenticationSessionClient = .live
    ) -> AuthenticationClient {
        let clientBox = SupabaseAuthenticationClientBox(provider: provider)
        let operations = SupabaseAuthenticationOperations.live(
            provider: provider, clientBox: clientBox
        )
        let ownedAppleAuthorization = AppleAuthorizationClient(
            authorize: { challenge in
                // Reject unfinished retirement before asking for credentials.
                _ = try await clientBox.beginAuthentication()
                return try await appleAuthorization.authorize(challenge)
            },
            reauthorizeForDeletion: appleAuthorization.reauthorizeForDeletion
        )
        let browserDeletion: (@MainActor @Sendable () async throws -> Void)?
        let browserSignIn: (@MainActor @Sendable () async throws -> AuthenticationSession)?
        if let configuration = StagingAppleWebAuthenticationConfiguration.parse(infoDictionary) {
            let transport = SupabaseAppleWebDeletionTransport(provider: provider)
            browserSignIn = {
                try Task.checkCancellation()
                let client = try await clientBox.beginAuthentication()
                guard client.auth.currentSession == nil else {
                    throw AuthenticationClientFailure.operationFailed
                }
                let authorizationURL = try client.auth.getOAuthSignInURL(
                    provider: .apple, redirectTo: configuration.redirectURL
                )
                let callback = try await browser.authenticate(
                    authorizationURL, configuration.redirectURL.scheme!
                )
                try Task.checkCancellation()
                let code = try configuration.authorizationCode(from: callback)
                guard client.auth.currentSession == nil else {
                    throw AuthenticationClientFailure.operationFailed
                }
                let session = try await client.auth.exchangeCodeForSession(authCode: code)
                return try await clientBox.acceptExchangedSession(session).appValue
            }
            browserDeletion = {
                let operation = AppleWebAccountDeletionClient(
                    configuration: configuration,
                    clientID: configuration.clientID,
                    browser: browser,
                    secrets: {
                        // Independent secure random draws; only their SHA-256
                        // hex challenges leave this in-memory operation.
                        try AppleWebDeletionBeginRequest(
                            claimVerifier: AppleSignInNonce.generate().challenge,
                            nonce: AppleSignInNonce.generate().challenge
                        )
                    },
                    begin: { try await transport.begin($0) },
                    complete: { try await transport.complete($0) }
                )
                try await operation.deleteConfirmedAccount()
            }
        } else {
            browserDeletion = nil
            browserSignIn = nil
        }
        return make(
            operations: operations,
            appleAuthorization: ownedAppleAuthorization,
            browserDeletion: browserDeletion,
            browserSignIn: browserSignIn,
            finishRetirement: { try await clientBox.finishRetirement() }
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
    static func live(
        provider: SupabaseClientProvider,
        clientBox: SupabaseAuthenticationClientBox
    ) -> Self {
        return Self(
            currentSession: {
                try await clientBox.currentSession()
            },
            refreshSession: {
                let session = try await clientBox.client().auth.refreshSession()
                return SupabaseAuthenticationSession(session)
            },
            exchangeAppleIDToken: { identityToken, rawNonce in
                let client = try await clientBox.beginAuthentication()
                let session = try await client.auth.signInWithIdToken(
                    credentials: OpenIDConnectCredentials(
                        provider: .apple,
                        idToken: identityToken,
                        nonce: rawNonce
                    )
                )
                return try await clientBox.acceptExchangedSession(session)
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
            requestAccountDeletion: { request in
                try await clientBox.client().functions.invoke(
                    "delete-account",
                    options: FunctionInvokeOptions(
                        method: .post,
                        body: request
                    )
                )
            },
            events: {
                AsyncStream { continuation in
                    do {
                        let owner = try provider.authenticationLifetime()
                        let origin = provider.eventOrigin(for: owner)
                        let task = try owner.eventTasks.start {
                            defer { continuation.finish() }
                            for await change in owner.client.auth.authStateChanges {
                                guard !Task.isCancelled else { break }
                                let event: SupabaseAuthenticationEvent
                                switch change.event {
                                case .tokenRefreshed:
                                    guard let session = change.session else { continue }
                                    event = .tokenRefreshed(SupabaseAuthenticationSession(session))
                                case .signedOut:
                                    event = .signedOut
                                case .userDeleted:
                                    event = .accountDeleted
                                default:
                                    event = .ignored
                                }
                                continuation.yield(.owned(origin, event))
                            }
                        }
                        continuation.onTermination = { _ in task.cancel() }
                    } catch {
                        continuation.finish()
                    }
                }
            },
            clearLocalSession: {
                do {
                    let owner = try provider.authenticationLifetime()
                    try owner.prepareAuthSessionRemovalVerification()
                    try await owner.client.auth.signOut(scope: .local)
                    try owner.verifyAuthSessionRemoved()
                } catch {
                    throw AuthenticationClientFailure.operationFailed
                }
            },
            remoteSignOut: {
                let owner = try provider.authenticationLifetime()
                guard let accessToken = owner.client.auth.currentSession?.accessToken
                else {
                    throw AuthenticationClientFailure.terminalSession
                }
                try await owner.confirmGlobalSignOut(accessToken)
                // App teardown records this confirmation before the separate,
                // retryable storage retirement stage. Do not perform a second
                // SDK logout or lose this receipt to a local cleanup failure.
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

    static func classifyAccountDeletionFailure(
        _ error: any Error
    ) -> AuthenticationClientFailure {
        if let failure = error as? AuthenticationClientFailure {
            return failure
        }
        guard case let FunctionsError.httpError(_, data) = error,
              let response = try? JSONDecoder().decode(
                AccountDeletionErrorResponse.self,
                from: data
              )
        else {
            return .operationFailed
        }
        switch response.error {
        case "authentication_required":
            return .terminalSession
        case "reauthentication_required", "apple_identity_mismatch":
            return .reauthenticationRequired
        default:
            return .operationFailed
        }
    }
}

// Owns explicit app operations only. It does not claim to drain SDK refresh
// work or queued Auth/Functions/Realtime events; those need separate evidence.
private actor ExplicitAuthenticationOperationGate {
    private var active = false

    func run<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        guard !active else { throw AuthenticationClientFailure.operationFailed }
        guard !Task.isCancelled else { throw AuthenticationClientFailure.cancelled }
        active = true
        defer { active = false }
        return try await operation()
    }
}

private struct AccountDeletionErrorResponse: Decodable {
    let error: String
}

private extension SupabaseAuthenticationSession {
    init(_ session: Session) {
        self.init(
            userID: session.user.id,
            expiresAt: Date(timeIntervalSince1970: session.expiresAt)
        )
    }
}

actor SupabaseAuthenticationClientBox {
    private let provider: SupabaseClientProvider
    private enum Phase {
        case active
        case retiring
        case failed(SupabaseAuthenticationLifetime)
        case retired
    }
    private var phase: Phase = .active
    private var cancelledAuthenticationPending = false
    private var cancelledAccessToken: String?

    init(provider: SupabaseClientProvider) {
        self.provider = provider
    }

    func client() throws -> SupabaseClient {
        guard case .active = phase else {
            throw AuthenticationClientFailure.operationFailed
        }
        return try provider.client()
    }

    func currentSession() throws -> SupabaseAuthenticationSession? {
        switch phase {
        case .retired:
            // Reopening the signed-out app is a read, not fresh admission.
            return nil
        case .active:
            return try provider.client().auth.currentSession.map(SupabaseAuthenticationSession.init)
        case .retiring, .failed:
            throw cancelledAuthenticationPending
                ? AuthenticationClientFailure.retirementRequired : .operationFailed
        }
    }

    func acceptExchangedSession(_ session: Session) async throws -> SupabaseAuthenticationSession {
        if Task.isCancelled {
            // Both native and browser exchanges may persist after cancellation.
            // Await uncancelled cleanup while the explicit operation gate stays
            // held. No fire-and-forget work or second account can pass this gate.
            try await Task {
                try await self.cancelPersistedAuthentication(accessToken: session.accessToken)
            }.value
            throw AuthenticationClientFailure.cancelled
        }
        return SupabaseAuthenticationSession(session)
    }

    private func cancelPersistedAuthentication(accessToken: String) async throws {
        guard case .active = phase else {
            throw AuthenticationClientFailure.retirementRequired
        }
        // Captured directly from this exchange, never reacquired from storage
        // after the pending-removal marker hides the cancelled session.
        cancelledAuthenticationPending = true
        cancelledAccessToken = accessToken
        do { try await finishRetirement() }
        catch { throw AuthenticationClientFailure.retirementRequired }
    }

    private func confirmCancelledAuthentication(_ owner: SupabaseAuthenticationLifetime) async throws {
        guard let accessToken = cancelledAccessToken else { return }
        try owner.prepareAuthSessionRemovalVerification()
        try await owner.confirmLocalSignOut(accessToken)
        // A later storage failure must not repeat confirmed server logout.
        cancelledAccessToken = nil
    }

    func finishRetirement() async throws {
        try Task.checkCancellation()
        let owner: SupabaseAuthenticationLifetime
        switch phase {
        case .active:
            owner = try provider.authenticationLifetime()
        case let .failed(retainedOwner):
            owner = retainedOwner
        case .retiring:
            throw AuthenticationClientFailure.operationFailed
        case .retired:
            return
        }
        // Keep the original owner across suspension and failure. Ordinary
        // provider access intentionally remains unavailable during recovery.
        phase = .retiring
        do {
            try await provider.retireAuthenticationLifetime(owner) {
                try await self.confirmCancelledAuthentication(owner)
            }
            cancelledAuthenticationPending = false
            phase = .retired
        } catch {
            phase = .failed(owner)
            throw error
        }
    }

    func beginAuthentication() throws -> SupabaseClient {
        try Task.checkCancellation()
        switch phase {
        case .active, .retired:
            let owner = try provider.beginFreshAuthenticationLifetime()
            phase = .active
            guard owner.client.auth.currentSession == nil else {
                throw AuthenticationClientFailure.operationFailed
            }
            return owner.client
        case .retiring, .failed:
            throw cancelledAuthenticationPending
                ? AuthenticationClientFailure.retirementRequired : .operationFailed
        }
    }
}

private extension AppleAuthorizationClient {
    static let live = Self(
        authorize: { nonceChallenge in
            try await AppleAuthorizationBridge.authorizeCredential(
                nonceChallenge: nonceChallenge
            ).identityToken
        },
        reauthorizeForDeletion: { nonceChallenge in
            try await AppleAuthorizationBridge.authorizeCredential(
                nonceChallenge: nonceChallenge
            ).authorizationCode
        }
    )
}

private struct AppleAuthorizationCredentialPayload {
    let identityToken: Data?
    let authorizationCode: Data?
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
    private var continuation: CheckedContinuation<
        AppleAuthorizationCredentialPayload,
        any Error
    >?
    private var controller: ASAuthorizationController?
    private var cancellationState = AppleAuthorizationCancellationState()

    static func authorizeCredential(
        nonceChallenge: String
    ) async throws -> AppleAuthorizationCredentialPayload {
        let bridge = AppleAuthorizationBridge()
        return try await withTaskCancellationHandler {
            try await bridge.perform(nonceChallenge: nonceChallenge)
        } onCancel: {
            Task { @MainActor in bridge.cancel() }
        }
    }

    private func perform(
        nonceChallenge: String
    ) async throws -> AppleAuthorizationCredentialPayload {
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
        finish(
            returning: AppleAuthorizationCredentialPayload(
                identityToken: credential.identityToken,
                authorizationCode: credential.authorizationCode
            )
        )
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

    private func finish(
        returning credential: AppleAuthorizationCredentialPayload
    ) {
        guard let continuation else { return }
        self.continuation = nil
        controller = nil
        continuation.resume(returning: credential)
    }

    private func finish(throwing error: any Error) {
        guard let continuation else { return }
        self.continuation = nil
        controller = nil
        continuation.resume(throwing: error)
    }
}
