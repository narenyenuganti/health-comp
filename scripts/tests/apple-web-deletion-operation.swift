import Foundation

@main @MainActor
enum AppleWebDeletionOperationTests {
    static func main() async {
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            FileHandle.standardError.write(Data("FAIL: deletion_operation_timeout\n".utf8))
            exit(1)
        }
        defer { watchdog.cancel() }
        do { try await run() }
        catch {
            let label = (error as? Failure)?.label ?? "operation_failed"
            FileHandle.standardError.write(Data("FAIL: \(label)\n".utf8))
            exit(1)
        }
    }
    struct Failure: Error { let label: String }
    static func run() async throws {
        var checks = 0
        func expect(_ value: Bool, _ label: String) throws {
            guard value else { throw Failure(label: label) }
            checks += 1
        }
        let configuration = StagingAppleWebAuthenticationConfiguration.parse([
            "CFBundleIdentifier": "com.narenyenuganti.HealthComp.staging",
            "SUPABASE_URL": "https://xhfdfdrtxwptrwhvvlhg.supabase.co",
            "HEALTHCOMP_ENABLE_APPLE_WEB_SIGN_IN": "YES",
            "HEALTHCOMP_APPLE_WEB_CLIENT_ID": "com.example.staging.web",
        ])!
        let request = AppleWebDeletionBeginRequest(
            claimVerifier: String(repeating: "a", count: 64),
            nonce: String(repeating: "b", count: 64)
        )
        let id = String(repeating: "c", count: 64)
        let service = "com.example.staging.web"
        var authorization = URLComponents(string: "https://appleid.apple.com/auth/authorize")!
        authorization.queryItems = [
            .init(name: "client_id", value: service),
            .init(name: "redirect_uri", value: "https://xhfdfdrtxwptrwhvvlhg.supabase.co/functions/v1/apple-deletion-callback"),
            .init(name: "response_type", value: "code"),
            .init(name: "response_mode", value: "form_post"),
            .init(name: "nonce", value: request.nonce),
            .init(name: "state", value: String(repeating: "d", count: 64)),
        ]
        let response = AppleWebDeletionBeginResponse(requestID: id, authorizationURL: authorization.url!)
        let callback = URL(string: "healthcomp-staging-auth://apple/deletion-callback?request_id=\(id)")!
        let receipt = try JSONDecoder().decode(AppleWebDeletionReceipt.self, from: Data(#"{"status":"deleted"}"#.utf8))

        var events: [String] = []
        let resumed = AppleWebAccountDeletionClient(
            configuration: configuration, clientID: service,
            browser: .init(authenticate: { _, _ in events.append("browser"); return callback }),
            secrets: { events.append("secrets"); return request },
            begin: { _ in events.append("begin"); return response },
            complete: { body in
                events.append(body == .resume ? "resume" : "claim")
                return receipt
            }
        )
        do { try await resumed.deleteConfirmedAccount() }
        catch { throw Failure(label: "confirmed_resume_rejected") }
        try expect(events == ["resume"], "resume_must_not_create_fresh_grant")

        events = []
        let fresh = AppleWebAccountDeletionClient(
            configuration: configuration, clientID: service,
            browser: .init(authenticate: { url, scheme in
                try expect(url == response.authorizationURL && scheme == "healthcomp-staging-auth", "owned_browser_request")
                events.append("browser"); return callback
            }),
            secrets: { events.append("secrets"); return request },
            begin: { body in
                try expect(body == request, "fresh_secrets_sent_only_to_begin")
                events.append("begin"); return response
            },
            complete: { body in
                if body == .resume {
                    events.append("resume")
                    throw AppleWebAccountDeletionFailure.reauthenticationRequired
                }
                try expect(body == .claim(requestID: id, verifier: request.claimVerifier), "own_claim_payload")
                events.append("claim"); return receipt
            }
        )
        try await fresh.deleteConfirmedAccount()
        try expect(events == ["resume", "secrets", "begin", "browser", "claim"], "fresh_grant_order")

        var invalidAuthorizations = [URL(string: "https://example.invalid/authorize")!]
        for key in ["client_id", "redirect_uri", "response_type", "response_mode", "nonce", "state"] {
            var invalid = authorization
            invalid.queryItems = invalid.queryItems!.map {
                $0.name == key ? URLQueryItem(name: key, value: "wrong") : $0
            }
            invalidAuthorizations.append(invalid.url!)
        }
        var extra = authorization
        extra.queryItems!.append(.init(name: "scope", value: "email"))
        invalidAuthorizations.append(extra.url!)
        for invalidURL in invalidAuthorizations {
            events = []
            let invalid = AppleWebAccountDeletionClient(
                configuration: configuration, clientID: service,
                browser: .init(authenticate: { _, _ in events.append("browser"); return callback }),
                secrets: { request },
                begin: { _ in .init(requestID: id, authorizationURL: invalidURL) },
                complete: { body in
                    if body == .resume { throw AppleWebAccountDeletionFailure.reauthenticationRequired }
                    events.append("claim"); return receipt
                }
            )
            do {
                try await invalid.deleteConfirmedAccount()
                throw Failure(label: "invalid_authorization_was_accepted")
            } catch AppleWebAccountDeletionFailure.invalidResponse {}
            try expect(events.isEmpty, "invalid_authorization_has_no_browser_or_claim")
        }
        events = []
        let failedResume = AppleWebAccountDeletionClient(
            configuration: configuration, clientID: service,
            browser: .init(authenticate: { _, _ in events.append("browser"); return callback }),
            secrets: { events.append("secrets"); return request },
            begin: { _ in events.append("begin"); return response },
            complete: { _ in throw Failure(label: "synthetic_transport_failure") }
        )
        do {
            try await failedResume.deleteConfirmedAccount()
            throw Failure(label: "failed_resume_reported_success")
        } catch let failure as Failure {
            try expect(failure.label == "synthetic_transport_failure", "transport_failure_preserved")
        }
        try expect(events.isEmpty, "transport_failure_does_not_start_fresh_grant")

        let entered = Signal()
        let released = Signal()
        events = []
        let suspended = AppleWebAccountDeletionClient(
            configuration: configuration, clientID: service,
            browser: .init(authenticate: { _, _ in events.append("browser"); return callback }),
            secrets: { request },
            begin: { _ in entered.release(); await released.wait(); return response },
            complete: { body in
                if body == .resume {
                    events.append("resume")
                    throw AppleWebAccountDeletionFailure.reauthenticationRequired
                }
                events.append("claim"); return receipt
            }
        )
        let pending = Task { try await suspended.deleteConfirmedAccount() }
        await entered.wait()
        pending.cancel()
        do {
            try await suspended.deleteConfirmedAccount()
            throw Failure(label: "overlap_was_accepted")
        } catch AppleWebAccountDeletionFailure.operationInProgress { checks += 1 }
        try expect(events == ["resume"], "cancellation_retains_ownership_until_inflight_begin_settles")
        released.release()
        do {
            try await pending.value
            throw Failure(label: "cancelled_begin_continued")
        } catch is CancellationError { checks += 1 }
        try expect(events == ["resume"], "cancelled_begin_cannot_launch_browser_or_claim")
        try await suspended.deleteConfirmedAccount()
        try expect(events == ["resume", "resume", "browser", "claim"], "settled_cancellation_allows_new_operation")

        for wrongCallback in [true, false] {
            events = []
            let cancelledBrowser = AppleWebAccountDeletionClient(
                configuration: configuration, clientID: service,
                browser: .init(authenticate: { _, _ in
                    if wrongCallback { return URL(string: "healthcomp-staging-auth://apple/deletion-callback?request_id=\(String(repeating: "e", count: 64))")! }
                    throw AppleWebAuthenticationSessionFailure.cancelled
                }),
                secrets: { request },
                begin: { _ in response },
                complete: { body in
                    if body == .resume { throw AppleWebAccountDeletionFailure.reauthenticationRequired }
                    events.append("claim"); return receipt
                }
            )
            do {
                try await cancelledBrowser.deleteConfirmedAccount()
                throw Failure(label: "invalid_browser_result_reported_success")
            } catch is StagingAppleWebAuthenticationConfiguration.InvalidCallback {
                try expect(wrongCallback, "wrong_handle_failure")
            } catch AppleWebAuthenticationSessionFailure.cancelled {
                try expect(!wrongCallback, "browser_cancellation_preserved")
            }
            try expect(events.isEmpty, "invalid_browser_result_cannot_claim")
        }

        for invalidClient in ["", "invalid client", "com.narenyenuganti.HealthComp.staging", "com.narenyenuganti.HealthComp"] {
            events = []
            let invalid = AppleWebAccountDeletionClient(
                configuration: configuration, clientID: invalidClient,
                browser: .init(authenticate: { _, _ in events.append("browser"); return callback }),
                secrets: { request }, begin: { _ in events.append("begin"); return response },
                complete: { _ in events.append("complete"); return receipt }
            )
            do {
                try await invalid.deleteConfirmedAccount()
                throw Failure(label: "invalid_client_dispatched_deletion")
            } catch AppleWebAccountDeletionFailure.invalidResponse { checks += 1 }
            try expect(events.isEmpty, "invalid_client_has_no_external_effect")
        }

        let encoder = JSONEncoder()
        let resumeBody = try JSONSerialization.jsonObject(with: encoder.encode(AppleWebDeletionCompletionRequest.resume)) as! [String: Any]
        try expect(resumeBody.count == 1 && resumeBody["resume"] as? Bool == true, "exact_resume_body")
        let claimBody = try JSONSerialization.jsonObject(with: encoder.encode(AppleWebDeletionCompletionRequest.claim(requestID: id, verifier: request.claimVerifier))) as! [String: String]
        try expect(claimBody == ["request_id": id, "claim_verifier": request.claimVerifier], "exact_claim_body")
        let beginBody = try JSONSerialization.jsonObject(with: encoder.encode(request)) as! [String: String]
        try expect(beginBody == ["nonce": request.nonce, "claim_verifier": request.claimVerifier], "exact_begin_body")
        for text in [#"{"status":"pending"}"#, #"{"deleted":true}"#] {
            do {
                _ = try JSONDecoder().decode(AppleWebDeletionReceipt.self, from: Data(text.utf8))
                throw Failure(label: "unconfirmed_receipt_decoded")
            } catch is DecodingError { checks += 1 }
        }
        let reauthorization = Data(#"{"error":"reauthentication_required"}"#.utf8)
        do {
            _ = try AppleWebDeletionHTTP.decodeCompletion(statusCode: 401, data: reauthorization)
            throw Failure(label: "reauthorization_error_was_success")
        } catch AppleWebAccountDeletionFailure.reauthenticationRequired { checks += 1 }
        catch { throw Failure(label: "explicit_reauthorization_not_classified") }
        let confirmed = try AppleWebDeletionHTTP.decodeCompletion(statusCode: 200, data: Data(#"{"status":"deleted"}"#.utf8))
        try expect(confirmed.status == .deleted, "http_200_deleted_confirmed")
        for statusCode in [200, 201, 202, 400, 403, 409, 500, 503] {
            do {
                _ = try AppleWebDeletionHTTP.decodeCompletion(statusCode: statusCode, data: reauthorization)
                throw Failure(label: "wrong_status_was_success")
            } catch AppleWebAccountDeletionFailure.invalidResponse { checks += 1 }
        }
        for text in [#"{"error":"authentication_required"}"#, #"{"error":"apple_identity_mismatch"}"#,
                     #"{"error":"reauthentication_required","unexpected":true}"#, "", "not-json"] {
            do {
                _ = try AppleWebDeletionHTTP.decodeCompletion(statusCode: 401, data: Data(text.utf8))
                throw Failure(label: "unrelated_error_was_success")
            } catch AppleWebAccountDeletionFailure.invalidResponse { checks += 1 }
        }
        for statusCode in [201, 202, 204, 400, 401, 500] {
            do {
                _ = try AppleWebDeletionHTTP.decodeCompletion(statusCode: statusCode, data: Data(#"{"status":"deleted"}"#.utf8))
                throw Failure(label: "non_200_receipt_was_success")
            } catch AppleWebAccountDeletionFailure.invalidResponse { checks += 1 }
        }
        print("PASS: apple_web_deletion_operation checks=\(checks) external_effects=0")
    }

    @MainActor final class Signal {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }
}
