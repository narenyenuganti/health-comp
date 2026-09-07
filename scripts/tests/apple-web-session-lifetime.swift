import Foundation

@main
@MainActor
enum AppleWebSessionLifetimeTests {
    static func main() async {
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            FileHandle.standardError.write(Data("FAIL: session_lifetime_timeout\n".utf8))
            exit(1)
        }
        defer { watchdog.cancel() }
        do {
            try await run()
        } catch {
            let label = (error as? Failure)?.label ?? "unexpected_lifetime_error"
            FileHandle.standardError.write(Data("FAIL: \(label)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let tests = Checks()
        let requestURL = URL(string: "https://auth.invalid/authorize")!
        let callbackURL = URL(string: "test-auth://apple/callback?code=synthetic-code")!
        let scheme = "test-auth"

        for invalidScheme in ["", " ", "1invalid", "bad scheme", "bad:scheme", "éxample"] {
            let fixture = Fixture()
            fixture.onStart = { complete in complete(.success(callbackURL)) }
            let result = await capture {
                try await fixture.client.authenticate(requestURL, invalidScheme)
            }
            try tests.expect(result == .failure(.failed), "invalid_callback_scheme_is_rejected")
            try tests.expect(fixture.requests.isEmpty, "invalid_callback_scheme_creates_no_session")
        }

        do {
            let fixture = Fixture()
            fixture.onStart = { complete in complete(.success(callbackURL)) }
            let result = await capture {
                try await fixture.client.authenticate(requestURL, scheme)
            }
            try tests.expect(result == .success(callbackURL), "successful_callback_returns_url")
            try tests.expect(fixture.requests.count == 1, "one_session_created")
            try tests.expect(fixture.requests.first?.url == requestURL, "authorization_url_forwarded")
            try tests.expect(fixture.requests.first?.callbackScheme == scheme, "callback_scheme_forwarded")
            try tests.expect(fixture.requests.first?.prefersEphemeralBrowserSession == true, "ephemeral_browsing_requested")
            try tests.expect(fixture.startCount == 1, "session_started_once")
            try tests.expect(fixture.cancelCount == 0, "successful_session_not_cancelled")
            try tests.expect(fixture.resource == nil, "successful_session_released")
        }

        do {
            let fixture = Fixture()
            fixture.onStart = { complete in complete(.success(callbackURL)) }
            let result = await capture {
                try await fixture.client.authenticate(requestURL, "test.auth+v1")
            }
            try tests.expect(result == .success(callbackURL), "valid_scheme_punctuation_is_supported")
        }

        do {
            let fixture = Fixture()
            fixture.canStart = false
            let result = await capture { try await fixture.client.authenticate(requestURL, scheme) }
            try tests.expect(result == .failure(.failed), "start_false_fails_without_hanging")
            try tests.expect(fixture.startCount == 1, "failed_start_called_once")
            try tests.expect(fixture.resource == nil, "failed_start_releases_session")
        }

        for failure in [AppleWebAuthenticationSessionFailure.cancelled, .failed] {
            let fixture = Fixture()
            fixture.onStart = { complete in complete(.failure(failure)) }
            let result = await capture { try await fixture.client.authenticate(requestURL, scheme) }
            try tests.expect(result == .failure(failure), "callback_failure_is_normalized")
            try tests.expect(fixture.resource == nil, "callback_failure_releases_session")
        }

        do {
            let fixture = Fixture()
            let entered = Signal()
            let task = Task { @MainActor in
                await entered.wait()
                return await capture { try await fixture.client.authenticate(requestURL, scheme) }
            }
            task.cancel()
            entered.release()
            let result = await task.value
            try tests.expect(result == .failure(.cancelled), "pre_cancelled_task_is_cancelled")
            try tests.expect(fixture.requests.isEmpty, "pre_cancelled_task_creates_no_session")
            try tests.expect(fixture.startCount == 0, "pre_cancelled_task_starts_no_session")
        }

        do {
            let fixture = Fixture()
            let task = Task { @MainActor in
                await capture { try await fixture.client.authenticate(requestURL, scheme) }
            }
            await fixture.started.wait()
            try tests.expect(fixture.resource != nil, "active_session_is_retained")
            task.cancel()
            let result = await task.value
            try tests.expect(result == .failure(.cancelled), "task_cancellation_finishes_operation")
            try tests.expect(fixture.cancelCount == 1, "task_cancellation_cancels_owned_session_once")
            try tests.expect(fixture.resource == nil, "cancelled_session_released")
            fixture.complete(.success(callbackURL))
            fixture.complete(.failure(.failed))
            task.cancel()
            try tests.expect(fixture.cancelCount == 1, "late_callbacks_do_not_repeat_cancellation")
        }

        do {
            let fixture = Fixture()
            let task = Task { @MainActor in
                await capture { try await fixture.client.authenticate(requestURL, scheme) }
            }
            await fixture.started.wait()
            // The cancellation handler's MainActor task cannot run until this
            // actor yields. The callback must still observe cancellation first.
            task.cancel()
            fixture.complete(.success(callbackURL))
            let result = await task.value
            try tests.expect(result == .failure(.cancelled), "cancel_before_callback_wins")
            try tests.expect(fixture.cancelCount == 1, "ordered_cancellation_cancels_once")
        }

        do {
            let fixture = Fixture()
            let task = Task { @MainActor in
                await capture { try await fixture.client.authenticate(requestURL, scheme) }
            }
            await fixture.started.wait()
            fixture.complete(.success(callbackURL))
            task.cancel()
            let result = await task.value
            try tests.expect(result == .success(callbackURL), "callback_before_cancel_wins")
            try tests.expect(fixture.cancelCount == 0, "completed_session_not_cancelled_later")
        }

        do {
            let fixture = Fixture()
            fixture.onStart = { complete in
                complete(.success(callbackURL))
                complete(.failure(.failed))
                complete(.success(URL(string: "test-auth://ignored")!))
            }
            let result = await capture { try await fixture.client.authenticate(requestURL, scheme) }
            try tests.expect(result == .success(callbackURL), "first_callback_completes_once")
            try tests.expect(fixture.resource == nil, "duplicate_callbacks_do_not_retain_session")
        }

        do {
            let fixture = Fixture()
            fixture.canStart = false
            fixture.onStart = { complete in complete(.success(callbackURL)) }
            let result = await capture { try await fixture.client.authenticate(requestURL, scheme) }
            try tests.expect(result == .success(callbackURL), "synchronous_callback_wins_over_later_start_false")
            try tests.expect(fixture.resource == nil, "synchronous_callback_start_false_releases_session")
        }

        do {
            let fixture = Fixture()
            fixture.onCancel = { complete in
                complete(.success(callbackURL))
                complete(.failure(.cancelled))
            }
            let task = Task { @MainActor in
                await capture { try await fixture.client.authenticate(requestURL, scheme) }
            }
            await fixture.started.wait()
            task.cancel()
            let result = await task.value
            try tests.expect(result == .failure(.cancelled), "reentrant_cancel_callback_cannot_change_result")
            try tests.expect(fixture.cancelCount == 1, "reentrant_cancel_does_not_recurse")
        }

        do {
            let fixture = Fixture()
            let canceller = Canceller()
            fixture.onCreate = { canceller.cancel() }
            let task = Task { @MainActor in
                await capture { try await fixture.client.authenticate(requestURL, scheme) }
            }
            canceller.cancel = { task.cancel() }
            let result = await task.value
            try tests.expect(result == .failure(.cancelled), "cancel_during_creation_is_cancelled")
            try tests.expect(fixture.startCount == 0, "cancel_during_creation_prevents_start")
            try tests.expect(fixture.cancelCount == 1, "cancel_during_creation_releases_created_session")
        }

        do {
            let fixture = Fixture()
            let client = fixture.client
            let first = Task { @MainActor in
                await capture { try await client.authenticate(requestURL, scheme) }
            }
            await fixture.started.wait()
            let oldCompletion = fixture.complete
            first.cancel()
            let firstResult = await first.value
            try tests.expect(firstResult == .failure(.cancelled), "first_operation_is_cancelled")
            try tests.expect(fixture.cancelCount == 1, "first_operation_cancelled_once")

            fixture.started = Signal()
            let second = Task { @MainActor in
                await capture { try await client.authenticate(requestURL, scheme) }
            }
            await fixture.started.wait()
            oldCompletion(.success(URL(string: "test-auth://stale-operation")!))
            try tests.expect(fixture.resource != nil, "old_callback_cannot_release_new_session")
            fixture.complete(.success(callbackURL))
            let secondResult = await second.value
            try tests.expect(secondResult == .success(callbackURL), "new_operation_ignores_old_callback")
            try tests.expect(fixture.cancelCount == 1, "old_callback_cannot_cancel_new_operation")
            try tests.expect(fixture.startCount == 2, "each_operation_starts_its_own_session")
        }

        print("PASS: apple_web_session_lifetime checks=\(tests.count) live_browser_launches=0")
    }

    private static func capture(
        _ operation: () async throws -> URL
    ) async -> Result<URL, AppleWebAuthenticationSessionFailure> {
        do { return .success(try await operation()) }
        catch { return .failure(error as? AppleWebAuthenticationSessionFailure ?? .failed) }
    }

    private struct Failure: Error { let label: String }

    private final class Checks {
        private(set) var count = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) throws {
            count += 1
            guard value() else { throw Failure(label: label) }
        }
    }

    private final class Canceller { var cancel: () -> Void = {} }

    @MainActor
    private final class Signal {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private final class Resource {}

    @MainActor
    private final class Fixture {
        var requests: [AppleWebAuthenticationSessionRequest] = []
        var startCount = 0
        var cancelCount = 0
        var canStart = true
        var onCreate: () -> Void = {}
        var onStart: (AppleWebAuthenticationSessionCompletion) -> Void = { _ in }
        var onCancel: (AppleWebAuthenticationSessionCompletion) -> Void = { _ in }
        var complete: AppleWebAuthenticationSessionCompletion = { _ in }
        weak var resource: Resource?
        var started = Signal()

        var client: AppleWebAuthenticationSessionClient {
            .make { request, complete in
                self.requests.append(request)
                self.complete = complete
                let resource = Resource()
                self.resource = resource
                self.onCreate()
                return AppleWebAuthenticationSessionHandle(
                    start: {
                        _ = resource
                        self.startCount += 1
                        self.started.release()
                        self.onStart(complete)
                        return self.canStart
                    },
                    cancel: {
                        _ = resource
                        self.cancelCount += 1
                        self.onCancel(complete)
                    }
                )
            }
        }
    }
}
