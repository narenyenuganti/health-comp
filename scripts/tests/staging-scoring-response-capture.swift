import Foundation

#if HEALTHCOMP_CAPTURE_ABSENCE_TEST
typealias CaptureMustBeAbsent = StagingScoringResponseCapture
typealias OperatorMustBeAbsent = StagingScoringOperatorControls
#endif

#if HEALTHCOMP_STAGING
private final class CaptureProtocol: URLProtocol, @unchecked Sendable {
    static let body = Data(#"{"code":"app_attest_proof_rejected"}"#.utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host?.hasSuffix(".invalid") == true else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        if request.value(forHTTPHeaderField: "X-Test-Error") == "1" {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let headers = request.value(forHTTPHeaderField: "X-Test-No-ID") == "1" ? [:] : [
            "sb-request-id": request.value(forHTTPHeaderField: "X-Test-ID") ?? "00000000-0000-4000-8000-000000000001"
        ]
        let response = HTTPURLResponse(url: url,
            statusCode: Int(request.value(forHTTPHeaderField: "X-Test-Status") ?? "401")!,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class CaptureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func expire() { lock.withLock { instant += .seconds(61) } }
}

private final class BlockingCaptureClock: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var now: ContinuousClock.Instant {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
        return .now
    }
}
#endif

@main
private enum StagingScoringResponseCaptureChecks {
    static func check(_ label: String, _ result: Bool) {
        guard result else {
            FileHandle.standardError.write(Data("FAIL \(label)\n".utf8))
            exit(1)
        }
        print("PASS \(label)")
    }

    static func main() async {
#if HEALTHCOMP_STAGING
        let controls = StagingScoringOperatorControls()
        check("unbound_display_has_no_reference", controls.displayState() == .unavailable)
        check("unbound_operator_refuses_arm", !controls.requestArm())
        let controlOwner = StagingScoringCaptureOwner()
        controls.bind(controlOwner)
        check("bound_display_starts_off", controls.displayState() == .off)
        check("bound_operator_arms_once", controls.requestArm() && !controls.requestArm())
        check("armed_display_waits_without_consuming", controls.displayState() == .waiting)
        check("requested_operator_has_no_response", controls.takeResponse() == nil)
        check("operator_request_consumed_once", controls.consumeArmRequest(for: controlOwner) != nil
            && controls.consumeArmRequest(for: controlOwner) == nil)
        controls.recordResponse("00000000-0000-4000-8000-000000000001", for: controlOwner)
        check("display_does_not_consume_or_replace_reference", controls.displayState() == .captured("00000000-0000-4000-8000-000000000001")
            && controls.displayState() == .captured("00000000-0000-4000-8000-000000000001"))
        check("operator_retrieval_destructive", controls.takeResponse() == "00000000-0000-4000-8000-000000000001"
            && controls.takeResponse() == nil && !controls.requestArm())
        check("display_closes_after_destructive_retrieval", controls.displayState() == .closed)
        let inactiveControls = StagingScoringOperatorControls()
        inactiveControls.bind(controlOwner)
        inactiveControls.cancelForInactivity()
        check("inactivity_preserves_never_armed_slot", inactiveControls.displayState() == .off
            && inactiveControls.requestArm())
        inactiveControls.cancelForInactivity()
        check("inactivity_closes_started_capture", inactiveControls.displayState() == .closed
            && inactiveControls.consumeArmRequest(for: controlOwner) == nil)
        let operatorClock = CaptureClock()
        let expiringControls = StagingScoringOperatorControls(now: { operatorClock.now })
        expiringControls.bind(controlOwner)
        check("expiring_operator_armed", expiringControls.requestArm())
        _ = expiringControls.consumeArmRequest(for: controlOwner)
        expiringControls.recordResponse("00000000-0000-4000-8000-000000000001", for: controlOwner)
        operatorClock.expire()
        check("display_cannot_extend_original_deadline", expiringControls.displayState() == .closed)
        check("expired_operator_response_discarded", expiringControls.takeResponse() == nil
            && !expiringControls.requestArm())
        let replacement = StagingScoringCaptureOwner()
        expiringControls.bind(replacement)
        expiringControls.cancel(for: controlOwner)
        check("old_owner_cannot_cancel_replacement", expiringControls.requestArm())
        expiringControls.cancel(for: replacement)
        expiringControls.bind(replacement)
        check("same_retired_owner_cannot_rearm", !expiringControls.requestArm())
        let cancelledControls = StagingScoringOperatorControls()
        cancelledControls.bind(controlOwner)
        check("cancel_requested_fixture_armed", cancelledControls.requestArm())
        check("explicit_cancel_confirms_empty_read_clearance", cancelledControls.takeResponse() == nil
            && cancelledControls.cancelCapture()
            && cancelledControls.consumeArmRequest(for: controlOwner) == nil
            && !cancelledControls.requestArm())
        cancelledControls.recordResponse("00000000-0000-4000-8000-000000000001", for: controlOwner)
        check("cancelled_operator_cannot_refill", cancelledControls.takeResponse() == nil)
        cancelledControls.bind(replacement)
        check("replacement_after_operator_cancel_starts_empty", cancelledControls.takeResponse() == nil
            && cancelledControls.requestArm())
        _ = cancelledControls.consumeArmRequest(for: replacement)
        cancelledControls.recordResponse("00000000-0000-4000-8000-000000000001", for: replacement)
        check("explicit_cancel_discards_captured_response", cancelledControls.cancelCapture()
            && cancelledControls.takeResponse() == nil && !cancelledControls.requestArm())
        check("already_closed_cancel_confirms_clearance", cancelledControls.cancelCapture())
        checkBusyControls()
        let url = URL(string: "https://staging.invalid/functions/v1/submit-score-revision")!
        let observer = StagingScoringResponseCapture(scoringURL: url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureProtocol.self]
        let session = URLSession(configuration: configuration, delegate: observer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        do {
            let (body, response) = try await session.data(for: request)
            check("unarmed_transport_and_body_unchanged", body == CaptureProtocol.body && (response as? HTTPURLResponse)?.statusCode == 401)
            check("default_off", observer.take() == nil)
            check("explicit_arm_once", observer.arm() && !observer.arm())
            _ = try await session.data(for: request)
            check("armed_exact_response_available", observer.take() == "00000000-0000-4000-8000-000000000001")
            check("taking_is_destructive", observer.take() == nil)
            _ = try await session.data(for: request)
            check("late_response_cannot_refill_taken_capture", observer.take() == nil && !observer.arm())
            for (label, rawURL, method, headers) in [
                ("wrong_origin", "https://other.invalid/functions/v1/submit-score-revision", "POST", [:]),
                ("wrong_path", "https://staging.invalid/auth/v1/logout", "POST", [:]),
                ("insecure_request", "http://staging.invalid/functions/v1/submit-score-revision", "POST", [:]),
                ("unexpected_port", "https://staging.invalid:8443/functions/v1/submit-score-revision", "POST", [:]),
                ("query_rejected", "https://staging.invalid/functions/v1/submit-score-revision?a=1", "POST", [:]),
                ("wrong_method", url.absoluteString, "GET", [:]),
                ("success_not_captured", url.absoluteString, "POST", ["X-Test-Status": "200"]),
                ("other_failure_not_captured", url.absoluteString, "POST", ["X-Test-Status": "403"]),
                ("missing_header", url.absoluteString, "POST", ["X-Test-No-ID": "1"]),
                ("malformed_header", url.absoluteString, "POST", ["X-Test-ID": "not-a-uuid"]),
                ("oversized_header", url.absoluteString, "POST", ["X-Test-ID": String(repeating: "a", count: 4096)]),
                ("uppercase_header", url.absoluteString, "POST", ["X-Test-ID": "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"])
            ] {
                let scoped = StagingScoringResponseCapture(scoringURL: url)
                check("scope_fixture_armed", scoped.arm())
                let scopedSession = URLSession(configuration: configuration, delegate: scoped, delegateQueue: nil)
                defer { scopedSession.invalidateAndCancel() }
                var scopedRequest = URLRequest(url: URL(string: rawURL)!)
                scopedRequest.httpMethod = method
                for (key, value) in headers { scopedRequest.setValue(value, forHTTPHeaderField: key) }
                _ = try await scopedSession.data(for: scopedRequest)
                check(label, scoped.take() == nil)
            }
            let clock = CaptureClock()
            let expired = StagingScoringResponseCapture(scoringURL: url, now: { clock.now })
            check("expiry_fixture_armed", expired.arm())
            let expiredSession = URLSession(configuration: configuration, delegate: expired, delegateQueue: nil)
            defer { expiredSession.invalidateAndCancel() }
            _ = try await expiredSession.data(for: request)
            check("expiry_fixture_received_response", expired.hasCapturedResponse)
            clock.expire()
            check("expired_access_clears_capture", expired.take() == nil && !expired.hasCapturedResponse)
            let cancelled = StagingScoringResponseCapture(scoringURL: url)
            check("cancellation_fixture_armed", cancelled.arm())
            let cancelledSession = URLSession(configuration: configuration, delegate: cancelled, delegateQueue: nil)
            defer { cancelledSession.invalidateAndCancel() }
            _ = try await cancelledSession.data(for: request)
            cancelled.cancel()
            _ = try await cancelledSession.data(for: request)
            check("cancel_clears_and_disables_capture", cancelled.take() == nil && !cancelled.hasCapturedResponse && !cancelled.arm())
            let ambiguous = StagingScoringResponseCapture(scoringURL: url)
            check("ambiguity_fixture_armed", ambiguous.arm())
            let ambiguousSession = URLSession(configuration: configuration, delegate: ambiguous, delegateQueue: nil)
            defer { ambiguousSession.invalidateAndCancel() }
            _ = try await ambiguousSession.data(for: request)
            _ = try await ambiguousSession.data(for: request)
            check("multiple_matching_tasks_discard_capture", ambiguous.take() == nil)
            let errored = StagingScoringResponseCapture(scoringURL: url)
            check("error_fixture_armed", errored.arm())
            let erroredSession = URLSession(configuration: configuration, delegate: errored, delegateQueue: nil)
            defer { erroredSession.invalidateAndCancel() }
            var failedRequest = request
            failedRequest.setValue("1", forHTTPHeaderField: "X-Test-Error")
            do {
                _ = try await erroredSession.data(for: failedRequest)
                check("native_network_error_preserved", false)
            } catch let error as URLError {
                check("native_network_error_preserved", error.code == .networkConnectionLost)
            }
            check("native_error_not_captured", errored.take() == nil)
            for timeout in [Duration.zero, .seconds(-1), .seconds(61)] {
                let invalid = StagingScoringResponseCapture(scoringURL: url)
                check("invalid_window_refused", !invalid.arm(timeout: timeout))
            }
        } catch {
            check("synthetic_transport_completed", false)
        }
#else
        check("non_staging_capture_compiled_out", true)
#endif
    }

#if HEALTHCOMP_STAGING
    private static func checkBusyControls() {
        let clock = BlockingCaptureClock()
        let controls = StagingScoringOperatorControls(now: { clock.now })
        let controlsOwner = StagingScoringCaptureOwner()
        controls.bind(controlsOwner)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = controls.requestArm()
            finished.signal()
        }
        check("held_lock_fixture_ready", clock.entered.wait(timeout: .now() + 2) == .success)
        let started = ContinuousClock.now
        let refused = !controls.requestArm() && controls.takeResponse() == nil
            && !controls.cancelCapture()
        let returnedPromptly = started.duration(to: .now) < .seconds(1)
        clock.release.signal()
        check("held_operator_lock_refuses_without_waiting", refused && returnedPromptly)
        check("held_lock_fixture_released", finished.wait(timeout: .now() + 2) == .success)
        check("released_operator_lock_allows_confirmed_cancel", controls.cancelCapture()
            && controls.consumeArmRequest(for: controlsOwner) == nil)
    }
#endif
}
