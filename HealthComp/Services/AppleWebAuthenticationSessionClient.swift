import Foundation

enum AppleWebAuthenticationSessionFailure: Error, Equatable, Sendable {
    case cancelled
    case failed
}

struct AppleWebAuthenticationSessionRequest: Equatable, Sendable {
    let url: URL
    let callbackScheme: String
    let prefersEphemeralBrowserSession: Bool
}

typealias AppleWebAuthenticationSessionCompletion =
    @MainActor @Sendable (Result<URL, AppleWebAuthenticationSessionFailure>) -> Void

struct AppleWebAuthenticationSessionHandle: Sendable {
    let start: @MainActor @Sendable () -> Bool
    let cancel: @MainActor @Sendable () -> Void
}

struct AppleWebAuthenticationSessionClient: Sendable {
    var authenticate: @MainActor @Sendable (URL, String) async throws -> URL

    static func make(
        factory: @escaping @MainActor @Sendable (
            AppleWebAuthenticationSessionRequest,
            @escaping AppleWebAuthenticationSessionCompletion
        ) -> AppleWebAuthenticationSessionHandle
    ) -> Self {
        Self(authenticate: { url, callbackScheme in
            guard !Task.isCancelled else {
                throw AppleWebAuthenticationSessionFailure.cancelled
            }
            guard callbackScheme.range(
                of: #"\A[A-Za-z][A-Za-z0-9+.-]*\z"#,
                options: .regularExpression
            ) != nil else {
                throw AppleWebAuthenticationSessionFailure.failed
            }
            let cancellation = AppleWebAuthenticationCancellation()
            let operation = AppleWebAuthenticationSessionOperation(
                cancellation: cancellation
            )
            return try await withTaskCancellationHandler {
                try await operation.run(
                    request: AppleWebAuthenticationSessionRequest(
                        url: url,
                        callbackScheme: callbackScheme,
                        prefersEphemeralBrowserSession: true
                    ),
                    factory: factory
                )
            } onCancel: {
                // Mark synchronously: a callback can reach the MainActor before
                // the separately enqueued cancellation work gets to run.
                cancellation.request()
                Task { @MainActor in operation.cancel() }
            }
        })
    }
}

private final class AppleWebAuthenticationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    var isRequested: Bool { lock.withLock { requested } }

    func request() {
        lock.withLock { requested = true }
    }
}

@MainActor
private final class AppleWebAuthenticationSessionOperation {
    private let cancellation: AppleWebAuthenticationCancellation
    private var continuation: CheckedContinuation<URL, any Error>?
    private var session: AppleWebAuthenticationSessionHandle?

    init(cancellation: AppleWebAuthenticationCancellation) {
        self.cancellation = cancellation
    }

    func run(
        request: AppleWebAuthenticationSessionRequest,
        factory: @MainActor @Sendable (
            AppleWebAuthenticationSessionRequest,
            @escaping AppleWebAuthenticationSessionCompletion
        ) -> AppleWebAuthenticationSessionHandle
    ) async throws -> URL {
        guard !Task.isCancelled, !cancellation.isRequested else {
            throw AppleWebAuthenticationSessionFailure.cancelled
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            guard !cancellation.isRequested else {
                cancel()
                return
            }
            let createdSession = factory(request) { [weak self] result in
                self?.complete(result)
            }
            guard self.continuation != nil else {
                if cancellation.isRequested { createdSession.cancel() }
                return
            }
            session = createdSession
            guard !cancellation.isRequested else {
                cancel()
                return
            }
            if !createdSession.start() {
                complete(.failure(.failed))
            }
        }
    }

    func cancel() {
        finish(.failure(.cancelled), cancelSession: true)
    }

    private func complete(
        _ result: Result<URL, AppleWebAuthenticationSessionFailure>
    ) {
        if cancellation.isRequested {
            cancel()
        } else {
            finish(result, cancelSession: false)
        }
    }

    private func finish(
        _ result: Result<URL, AppleWebAuthenticationSessionFailure>,
        cancelSession: Bool
    ) {
        guard let continuation else { return }
        self.continuation = nil
        let completedSession = session
        session = nil
        // Clear ownership before cancel(), which may synchronously call back.
        if cancelSession { completedSession?.cancel() }
        switch result {
        case let .success(url): continuation.resume(returning: url)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }
}

#if canImport(AuthenticationServices) && canImport(UIKit)
import AuthenticationServices
import UIKit

extension AppleWebAuthenticationSessionClient {
    // Unwired presentation factory only. Callers must separately establish the
    // staging configuration, operation-owned callback and Auth transaction.
    static let live = Self.make { request, completion in
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        else {
            return AppleWebAuthenticationSessionHandle(
                start: { false },
                cancel: {}
            )
        }
        let presentation = AppleWebAuthenticationPresentation(window: window)
        let session = ASWebAuthenticationSession(
            url: request.url,
            callbackURLScheme: request.callbackScheme
        ) { url, error in
            let result: Result<URL, AppleWebAuthenticationSessionFailure>
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                result = .failure(.cancelled)
            } else if error != nil {
                result = .failure(.failed)
            } else if let url {
                result = .success(url)
            } else {
                result = .failure(.failed)
            }
            Task { @MainActor in completion(result) }
        }
        session.prefersEphemeralWebBrowserSession =
            request.prefersEphemeralBrowserSession
        session.presentationContextProvider = presentation
        return AppleWebAuthenticationSessionHandle(
            start: { withExtendedLifetime(presentation) { session.start() } },
            cancel: { session.cancel() }
        )
    }
}

@MainActor
private final class AppleWebAuthenticationPresentation:
    NSObject, ASWebAuthenticationPresentationContextProviding
{
    private let window: UIWindow

    init(window: UIWindow) {
        self.window = window
    }

    func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        window
    }
}
#endif
