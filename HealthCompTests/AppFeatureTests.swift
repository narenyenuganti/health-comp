import ComposableArchitecture
import Foundation
import XCTest
@testable import HealthComp

final class AppFeatureTests: XCTestCase {
    @MainActor
    func testCancelledPersistedSignInRetirementIsRecoverableWithoutRestoringOrSigningOutGlobally() async {
        for action in [
            AppFeature.Action.signInResponse(epoch: 0, .failure(.retirementRequired)),
            .restoreSessionResponse(epoch: 0, .failure(.retirementRequired)),
        ] {
            let calls = OrderedCallRecorder()
            var authentication = AuthenticationClient.test(signOut: { calls.record("global-logout") })
            authentication.finishRetirement = {
                calls.record("retire")
                if calls.calls.count == 1 { throw AuthenticationClientFailure.operationFailed }
            }
            let store = TestStore(initialState: AppFeature.State()) { AppFeature() } withDependencies: {
                $0.authenticationClient = authentication
            }
            store.exhaustivity = .off(showSkippedAssertions: false)
            await store.send(action)
            await store.finish()
            await store.skipReceivedActions(strict: false)
            XCTAssertEqual(store.state.phase, .launchFailure)
            XCTAssertEqual(store.state.pendingTeardown?.stage, .retireAuthentication)
            XCTAssertEqual(calls.calls, ["retire"])
            await store.send(.account(.delegate(.retryRequested)))
            await store.finish()
            await store.skipReceivedActions(strict: false)
            XCTAssertEqual(calls.calls, ["retire", "retire"])
            XCTAssertEqual(store.state.phase, .signedOut)
            XCTAssertNil(store.state.pendingTeardown)
            XCTAssertNil(store.state.account.message)
        }
    }

    @MainActor
    func testConfirmedDeletionRetirementRetryDoesNotRepeatServerOrProfileTeardown() async {
        for inBrowser in [false, true] {
            let calls = OrderedCallRecorder()
            let storage = profileStorageFixture(for: profile, recorder: calls)
            var authentication = AuthenticationClient.test(
                deleteAccount: { calls.record("server-confirmed") }
            )
            authentication.deleteAccountInBrowser = { calls.record("server-confirmed") }
            authentication.finishRetirement = {
                calls.record("retire")
                if calls.calls.filter({ $0 == "retire" }).count == 1 {
                    throw AuthenticationClientFailure.operationFailed
                }
            }
            var initial = AppFeature.State.authenticated(profile: profile, epoch: 3)
            initial.account.isDeletingAccount = true
            initial.account.isRequestInFlight = true
            initial.account.isBrowserDeletionAvailable = inBrowser
            let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
                $0.authenticationClient = authentication
                $0.authenticatedProfileStorage = storage.client
                $0.competitionClient = .test(
                    stop: { calls.record("runtime-stop") },
                    prepareForProfileTeardown: { _ in calls.record("runtime-prepare") }
                )
            }
            store.exhaustivity = .off(showSkippedAssertions: false)
            await store.send(.account(.delegate(inBrowser ? .deleteAccountInBrowserRequested : .deleteAccountRequested)))
            await store.finish()
            await store.skipReceivedActions(strict: false)
            XCTAssertEqual(store.state.phase, .launchFailure)
            XCTAssertEqual(store.state.pendingTeardown?.stage, .retireAuthentication)
            XCTAssertEqual(store.state.pendingTeardown?.reason, .accountDeleted)
            XCTAssertEqual(calls.calls, ["server-confirmed", "runtime-prepare", "runtime-stop", "storage-teardown", "retire"])
            await store.send(.account(.delegate(.retryRequested)))
            await store.finish()
            await store.skipReceivedActions(strict: false)
            XCTAssertEqual(calls.calls, ["server-confirmed", "runtime-prepare", "runtime-stop", "storage-teardown", "retire", "retire"])
            XCTAssertEqual(store.state.phase, .signedOut)
            XCTAssertNil(store.state.pendingTeardown)
        }
    }

    @MainActor
    func testNoProfileTerminalPathsAwaitRetirementAndRetainFailureForRetry() async {
        let cases: [(AppFeature.Action, AccountFeature.Message?)] = [
            (.restoreSessionResponse(epoch: 0, .success(nil)), nil),
            (.restoreSessionResponse(epoch: 0, .failure(.terminalSession)), .sessionEnded),
            (.restoreSessionResponse(epoch: 0, .failure(.sessionExpired)), .sessionEnded),
            (.bootstrapProfileResponse(epoch: 0, .failure(.terminalSession)), .sessionEnded),
        ]
        for (action, message) in cases {
            let calls = OrderedCallRecorder()
            var authentication = AuthenticationClient.test(
                signOut: { calls.record("remote-sign-out") }
            )
            authentication.finishRetirement = {
                calls.record("retire")
                if calls.calls.count == 1 { throw AuthenticationClientFailure.operationFailed }
            }
            let store = TestStore(initialState: AppFeature.State()) { AppFeature() } withDependencies: {
                $0.authenticationClient = authentication
            }
            store.exhaustivity = .off(showSkippedAssertions: false)
            await store.send(action)
            await store.finish()
            await store.skipReceivedActions(strict: false)
            XCTAssertEqual(store.state.phase, .launchFailure)
            XCTAssertEqual(store.state.pendingTeardown?.stage, .retireAuthentication)
            XCTAssertEqual(calls.calls, ["retire"])
            guard store.state.phase == .launchFailure else { continue }
            await store.send(.account(.delegate(.retryRequested)))
            await store.finish()
            await store.skipReceivedActions(strict: false)
            XCTAssertEqual(calls.calls, ["retire", "retire"])
            XCTAssertEqual(store.state.phase, .signedOut)
            XCTAssertNil(store.state.pendingTeardown)
            XCTAssertEqual(store.state.account.message, message)
        }
    }

    @MainActor
    func testRetirementRetryDoesNotRepeatConfirmedRemoteSignOut() async {
        let calls = OrderedCallRecorder()
        var authentication = AuthenticationClient.test(signOut: { calls.record("sign-out") })
        authentication.finishRetirement = {
            calls.record("retire")
            if calls.calls.filter({ $0 == "retire" }).count == 1 {
                throw AuthenticationClientFailure.operationFailed
            }
        }
        var initial = AppFeature.State.signedOut(epoch: 4)
        initial.phase = .tearingDown
        initial.pendingTeardown = AppFeature.PendingTeardown(
            reason: .userRequested, profileID: nil, stopRuntime: false,
            stage: .finishUserSignOut, isRunning: false
        )
        let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
            $0.authenticationClient = authentication
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.task)
        await store.finish()
        await store.skipReceivedActions(strict: false)
        XCTAssertEqual(store.state.phase, .launchFailure)
        XCTAssertEqual(store.state.pendingTeardown?.stage, .retireAuthentication)
        await store.send(.account(.delegate(.retryRequested)))
        await store.finish()
        await store.skipReceivedActions(strict: false)
        XCTAssertEqual(calls.calls, ["sign-out", "retire", "retire"])
        XCTAssertEqual(store.state.phase, .signedOut)
        XCTAssertNil(store.state.pendingTeardown)
    }

    @MainActor
    func testRetirementFailurePreventsTeardownCompletion() async {
        let attempted = expectation(description: "retirement attempted")
        var authentication = AuthenticationClient.test()
        authentication.finishRetirement = {
            attempted.fulfill()
            throw AuthenticationClientFailure.operationFailed
        }
        var initial = AppFeature.State.signedOut(epoch: 4)
        initial.phase = .tearingDown
        initial.pendingTeardown = AppFeature.PendingTeardown(
            reason: .sessionEnded, profileID: nil, stopRuntime: false,
            stage: .finishUserSignOut, isRunning: false
        )
        let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
            $0.authenticationClient = authentication
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.task)
        await fulfillment(of: [attempted], timeout: 1)
        await store.finish()
        await store.skipReceivedActions(strict: false)
        XCTAssertEqual(store.state.phase, .launchFailure)
        XCTAssertNotNil(store.state.pendingTeardown)
        XCTAssertEqual(store.state.pendingTeardown?.isRunning, false)
    }

    @MainActor
    func testSuccessfulAuthenticationCancelsThePreviousListener() async {
        let oldCancelled = expectation(description: "previous listener cancelled")
        let renewed = expectation(description: "replacement listener subscribed")
        let initialSubscription = expectation(description: "initial listener subscribed")
        let (oldEvents, oldContinuation) = AsyncStream<AuthenticationEvent>.makeStream()
        let (newEvents, newContinuation) = AsyncStream<AuthenticationEvent>.makeStream()
        defer { oldContinuation.finish(); newContinuation.finish() }
        oldContinuation.onTermination = { _ in oldCancelled.fulfill() }
        let calls = OrderedCallRecorder()
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() } withDependencies: {
            $0.authenticationClient = .test(
                restoreSession: { nil },
                bootstrapProfile: { _ in throw AuthenticationClientFailure.displayNameRequired },
                events: {
                    calls.record("subscribe")
                    if calls.calls.count == 1 {
                        initialSubscription.fulfill()
                        return oldEvents
                    }
                    renewed.fulfill()
                    return newEvents
                }
            )
        }
        await store.send(.task) {
            $0.authEpoch = 1
            $0.isAuthenticationMonitoring = true
        }
        await store.receive(.restoreSessionResponse(epoch: 1, .success(nil))) {
            $0.phase = .signedOut
            $0.account = AccountFeature.State(mode: .signedOut)
        }
        await fulfillment(of: [initialSubscription], timeout: 1)
        await store.send(.signInResponse(epoch: 1, .success(session))) {
            $0.phase = .bootstrappingProfile
        }
        await store.receive(.bootstrapProfileResponse(epoch: 1, .failure(.displayNameRequired))) {
            $0.phase = .settingUpProfile
            $0.account = AccountFeature.State(mode: .settingUpProfile)
        }
        await fulfillment(of: [oldCancelled, renewed], timeout: 1)
        XCTAssertEqual(calls.calls, ["subscribe", "subscribe"])
        newContinuation.finish()
        await store.finish()
    }

    @MainActor
    func testSuccessfulAuthenticationDoesNotStartStoppedMonitoring() async {
        let store = TestStore(initialState: .signedOut(epoch: 1)) { AppFeature() } withDependencies: {
            $0.authenticationClient = .test(
                bootstrapProfile: { _ in throw AuthenticationClientFailure.displayNameRequired },
                events: {
                    XCTFail("Stopped monitoring must not acquire an event subscription.")
                    return AsyncStream { $0.finish() }
                }
            )
        }
        await store.send(.signInResponse(epoch: 1, .success(session))) {
            $0.phase = .bootstrappingProfile
        }
        await store.receive(.bootstrapProfileResponse(epoch: 1, .failure(.displayNameRequired))) {
            $0.phase = .settingUpProfile
            $0.account = AccountFeature.State(mode: .settingUpProfile)
        }
        await store.finish()
        XCTAssertFalse(store.state.isAuthenticationMonitoring)
    }

    @MainActor
    func testSuccessfulAuthenticationRenewsMonitoringForTheActiveOwner() async throws {
        let registry = SharedClientLifetime { AuthenticationEventTestOwner() }
        let oldOwner = try registry.client()
        let oldOrigin = AuthenticationEventOrigin(registry: registry, owner: oldOwner)
        try await registry.retire(oldOwner) { _ in }
        let newOwner = try registry.beginFreshLifetime()
        let newOrigin = AuthenticationEventOrigin(registry: registry, owner: newOwner)
        let subscribed = expectation(description: "fresh authentication listener")
        let (events, continuation) = AsyncStream<AuthenticationEvent>.makeStream()
        defer { continuation.finish() }
        var initial = AppFeature.State.signedOut(epoch: 1)
        initial.isAuthenticationMonitoring = true
        let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
            $0.authenticationClient = .test(
                bootstrapProfile: { _ in throw AuthenticationClientFailure.displayNameRequired },
                events: {
                    subscribed.fulfill()
                    return events
                }
            )
        }
        await store.send(.signInResponse(epoch: 1, .success(session))) {
            $0.phase = .bootstrappingProfile
        }
        await store.receive(.bootstrapProfileResponse(epoch: 1, .failure(.displayNameRequired))) {
            $0.phase = .settingUpProfile
            $0.account = AccountFeature.State(mode: .settingUpProfile)
        }
        await fulfillment(of: [subscribed], timeout: 1)
        // A queued old-owner event remains harmless; a fresh-owner event reaches
        // the reducer through the renewed stream without re-stamping either one.
        let stale = AuthenticationEvent.owned(oldOrigin, .signedOut)
        continuation.yield(stale)
        await store.receive(.authenticationEvent(stale))
        let fresh = AuthenticationEvent.owned(newOrigin, .sessionRefreshed(session))
        continuation.yield(fresh)
        await store.receive(.authenticationEvent(fresh))
        continuation.finish()
        await store.finish()
    }

    func testAuthenticationEventMappingPreservesOriginalOwner() throws {
        let registry = SharedClientLifetime { AuthenticationEventTestOwner() }
        let owner = try registry.client()
        let origin = AuthenticationEventOrigin(registry: registry, owner: owner)
        XCTAssertEqual(
            SupabaseAuthenticationEvent.owned(origin, .signedOut).appValue,
            .owned(origin, .signedOut)
        )
        XCTAssertEqual(
            SupabaseAuthenticationEvent.owned(origin, .accountDeleted).appValue,
            .owned(origin, .accountDeleted)
        )
        XCTAssertNil(SupabaseAuthenticationEvent.owned(origin, .ignored).appValue)
    }

    @MainActor
    func testQueuedEventsFromRetiredOwnerCannotChangeCurrentState() async throws {
        let registry = SharedClientLifetime { AuthenticationEventTestOwner() }
        let first = try registry.client()
        let origin = AuthenticationEventOrigin(registry: registry, owner: first)
        let queued: [AuthenticationEvent] = [
            .owned(origin, .signedOut), .owned(origin, .accountDeleted),
        ]
        try await registry.retire(first) { _ in }
        _ = try registry.beginFreshLifetime()
        for event in queued {
            let store = TestStore(initialState: .authenticated(profile: profile, epoch: 10)) {
                AppFeature()
            }
            await store.send(.authenticationEvent(event))
        }
    }

    @MainActor
    func testBrowserSignInUsesOptionalRouteAndQuietCancellation() async {
        var authentication = AuthenticationClient.test(signInWithApple: {
            XCTFail("Browser choice invoked native sign-in")
            throw AuthenticationClientFailure.operationFailed
        })
        authentication.signInWithAppleInBrowser = { throw AuthenticationClientFailure.cancelled }
        let store = TestStore(initialState: .signedOut(epoch: 4)) {
            AppFeature()
        } withDependencies: { $0.authenticationClient = authentication }
        await store.send(.account(.appeared)) { $0.account.isBrowserSignInAvailable = true }
        await store.send(.account(.browserSignInButtonTapped)) { $0.account.isRequestInFlight = true }
        await store.receive(.account(.delegate(.signInWithAppleInBrowserRequested))) { $0.authEpoch = 5 }
        await store.receive(.signInResponse(epoch: 5, .failure(.cancelled))) {
            $0.account.isRequestInFlight = false
        }
        XCTAssertEqual(store.state.phase, .signedOut)
        XCTAssertNil(store.state.account.message)
        await store.send(.account(.browserSignInButtonTapped)) { $0.account.isRequestInFlight = true }
        await store.receive(.account(.delegate(.signInWithAppleInBrowserRequested))) { $0.authEpoch = 6 }
        await store.receive(.signInResponse(epoch: 6, .failure(.cancelled))) {
            $0.account.isRequestInFlight = false
        }
    }

    @MainActor
    func testConfirmedBrowserDeletionUsesOptionalRouteAndPreservesStateOnCancellation() async {
        var authentication = AuthenticationClient.test(deleteAccount: {
            XCTFail("Browser choice invoked native deletion")
            throw AuthenticationClientFailure.operationFailed
        })
        authentication.deleteAccountInBrowser = { throw AuthenticationClientFailure.cancelled }
        let store = TestStore(initialState: .authenticated(profile: profile, epoch: 3)) {
            AppFeature()
        } withDependencies: { $0.authenticationClient = authentication }
        await store.send(.account(.appeared)) { $0.account.isBrowserDeletionAvailable = true }
        await store.send(.account(.deleteAccountButtonTapped)) { $0.account.isDeleteConfirmationPresented = true }
        await store.send(.account(.browserDeleteConfirmationAccepted)) {
            $0.account.isDeleteConfirmationPresented = false
            $0.account.isDeletingAccount = true
            $0.account.isRequestInFlight = true
        }
        await store.receive(.account(.delegate(.deleteAccountInBrowserRequested))) { $0.authEpoch = 4 }
        await store.receive(.accountDeletionResponse(epoch: 4, .failure(.cancelled)))
        await store.receive(.account(.operationFailed(.cancelled))) {
            $0.account.isDeletingAccount = false
            $0.account.isRequestInFlight = false
        }
        XCTAssertEqual(store.state.phase, .authenticated)
        XCTAssertEqual(store.state.profile, profile)
        XCTAssertNotNil(store.state.mainTab)
        XCTAssertNil(store.state.pendingTeardown)
    }

    private let session = AuthenticationSession(
        userID: UUID(uuidString: "93000000-0000-4000-8000-000000000001")!,
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
    )
    private let profile = AuthenticatedProfile(
        id: UUID(uuidString: "94000000-0000-4000-8000-000000000001")!,
        displayName: "Taylor"
    )

    @MainActor
    private func receiveSuccessfulTeardown(
        _ store: TestStoreOf<AppFeature>,
        epoch: UInt64,
        reason: AppFeature.TeardownReason
    ) async {
        await store.receive(
            .teardownStageCompleted(
                epoch: epoch,
                reason: reason,
                stage: .prepareRuntime
            )
        ) {
            $0.pendingTeardown?.stage = .removeProfileStorage
        }
        await store.receive(
            .teardownStageCompleted(
                epoch: epoch,
                reason: reason,
                stage: .removeProfileStorage
            )
        ) {
            $0.pendingTeardown?.stage = .finishUserSignOut
        }
        await store.receive(
            .teardownStageCompleted(
                epoch: epoch,
                reason: reason,
                stage: .finishUserSignOut
            )
        )
        await store.receive(
            .teardownCompleted(epoch: epoch, reason: reason)
        ) {
            $0.phase = .signedOut
            $0.profile = nil
            $0.profileStoragePaths = nil
            $0.pendingTeardown = nil
            $0.account = AccountFeature.State(mode: .signedOut)
            $0.account.message = reason == .sessionEnded
                ? .sessionEnded
                : nil
        }
    }

    @MainActor
    func testColdLaunchWithNoSessionBecomesSignedOut() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.authenticationClient = .test(restoreSession: { nil })
        }

        await store.send(.task) {
            $0.authEpoch = 1
            $0.isAuthenticationMonitoring = true
        }
        await store.receive(
            .restoreSessionResponse(epoch: 1, .success(nil))
        ) {
            $0.phase = .signedOut
            $0.account = AccountFeature.State(mode: .signedOut)
        }
    }

    @MainActor
    func testValidStoredSessionBootstrapsProfileBeforeConstructingMain() async {
        let session = session
        let profile = profile
        let storage = profileStorageFixture(for: profile)
        let competitionMounts = OrderedCallRecorder()
        var competitionClient = CompetitionClient.testValue
        competitionClient.mountAuthenticatedProfile = {
            mountedProfile,
            mountedPaths in
            competitionMounts.record(
                "\(mountedProfile.id.uuidString):\(mountedPaths.rootDirectory.path)"
            )
        }
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.authenticationClient = .test(
                restoreSession: { session },
                bootstrapProfile: { suggestedName in
                    guard suggestedName == nil else {
                        throw AuthenticationClientFailure.operationFailed
                    }
                    return profile
                }
            )
            $0.authenticatedProfileStorage = storage.client
            $0.competitionClient = competitionClient
        }

        await store.send(.task) {
            $0.authEpoch = 1
            $0.isAuthenticationMonitoring = true
        }
        await store.receive(
            .restoreSessionResponse(epoch: 1, .success(session))
        ) {
            $0.phase = .bootstrappingProfile
        }
        XCTAssertNil(store.state.mainTab)
        await store.receive(
            .bootstrapProfileResponse(epoch: 1, .success(profile))
        ) {
            $0.profile = profile
        }
        await store.receive(
            .profileStorageResponse(
                epoch: 1,
                profile: profile,
                .success(storage.paths)
            )
        ) {
            $0.phase = .authenticated
            $0.profileStoragePaths = storage.paths
            $0.account = AccountFeature.State(
                mode: .authenticated,
                displayName: profile.displayName
            )
            $0.mainTab = MainTabFeature.State()
        }
        XCTAssertEqual(
            competitionMounts.calls,
            ["\(profile.id.uuidString):\(storage.paths.rootDirectory.path)"]
        )
    }

    @MainActor
    func testExpiredStoredSessionRefreshesBeforeProfileBootstrap() async {
        let expired = SupabaseAuthenticationSession(
            userID: session.userID,
            expiresAt: Date(timeIntervalSince1970: 99)
        )
        let refreshed = SupabaseAuthenticationSession(
            userID: session.userID,
            expiresAt: session.expiresAt
        )
        let profile = profile
        let recorder = OrderedCallRecorder()
        let storage = profileStorageFixture(for: profile)
        let client = SupabaseAuthenticationClient.make(
            operations: SupabaseAuthenticationOperations(
                currentSession: { expired },
                refreshSession: {
                    recorder.record("refresh")
                    return refreshed
                },
                exchangeAppleIDToken: { _, _ in
                    throw AuthenticationClientFailure.operationFailed
                },
                bootstrapProfile: { _ in
                    recorder.record("bootstrap")
                    return profile
                },
                events: { AsyncStream { $0.finish() } },
                clearLocalSession: {},
                remoteSignOut: {},
                classifyRefreshFailure: { _ in .refreshRetryable }
            ),
            appleAuthorization: .testUnavailable,
            now: { Date(timeIntervalSince1970: 100) }
        )
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.authenticationClient = client
            $0.authenticatedProfileStorage = storage.client
        }

        await store.send(.task) {
            $0.authEpoch = 1
            $0.isAuthenticationMonitoring = true
        }
        await store.receive(
            .restoreSessionResponse(epoch: 1, .success(session))
        ) {
            $0.phase = .bootstrappingProfile
        }
        await store.receive(
            .bootstrapProfileResponse(epoch: 1, .success(profile))
        ) {
            $0.profile = profile
        }
        await store.receive(
            .profileStorageResponse(
                epoch: 1,
                profile: profile,
                .success(storage.paths)
            )
        ) {
            $0.phase = .authenticated
            $0.profileStoragePaths = storage.paths
            $0.account = AccountFeature.State(
                mode: .authenticated,
                displayName: profile.displayName
            )
            $0.mainTab = MainTabFeature.State()
        }
        XCTAssertEqual(recorder.calls, ["refresh", "bootstrap"])
    }

    @MainActor
    func testTerminalRestoreFailureSignsOutButRetryableFailureCanRetry() async {
        for (failure, expectedPhase, expectedMode, expectedMessage) in [
            (
                AuthenticationClientFailure.terminalSession,
                AppFeature.State.Phase.signedOut,
                AccountFeature.State.Mode.signedOut,
                AccountFeature.Message.sessionEnded
            ),
            (
                .refreshRetryable,
                .launchFailure,
                .launchFailure,
                .tryAgain
            ),
        ] {
            let store = TestStore(initialState: AppFeature.State()) {
                AppFeature()
            } withDependencies: {
                $0.authenticationClient = .test(
                    restoreSession: { throw failure }
                )
            }

            await store.send(.task) {
                $0.authEpoch = 1
                $0.isAuthenticationMonitoring = true
            }
            await store.receive(
                .restoreSessionResponse(epoch: 1, .failure(failure))
            ) {
                $0.phase = expectedPhase
                $0.account = AccountFeature.State(mode: expectedMode)
                $0.account.message = expectedMessage
            }
        }
    }

    @MainActor
    func testMissingProfileRequiresExplicitNameAndSuccessfulSetupEntersMain()
        async
    {
        let session = session
        let profile = profile
        let names = OrderedCallRecorder()
        let storage = profileStorageFixture(for: profile)
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.authenticationClient = .test(
                restoreSession: { session },
                bootstrapProfile: { name in
                    names.record(name ?? "nil")
                    if name == nil {
                        throw AuthenticationClientFailure.displayNameRequired
                    }
                    return profile
                }
            )
            $0.authenticatedProfileStorage = storage.client
        }

        await store.send(.task) {
            $0.authEpoch = 1
            $0.isAuthenticationMonitoring = true
        }
        await store.receive(
            .restoreSessionResponse(epoch: 1, .success(session))
        ) {
            $0.phase = .bootstrappingProfile
        }
        await store.receive(
            .bootstrapProfileResponse(
                epoch: 1,
                .failure(.displayNameRequired)
            )
        ) {
            $0.phase = .settingUpProfile
            $0.account = AccountFeature.State(mode: .settingUpProfile)
        }
        await store.send(.account(.displayNameChanged("  Taylor  "))) {
            $0.account.displayName = "  Taylor  "
        }
        await store.send(.account(.submitDisplayNameButtonTapped)) {
            $0.account.displayName = "Taylor"
            $0.account.isRequestInFlight = true
        }
        await store.receive(
            .account(.delegate(.displayNameSubmitted("Taylor")))
        )
        await store.receive(
            .bootstrapProfileResponse(epoch: 1, .success(profile))
        ) {
            $0.profile = profile
        }
        await store.receive(
            .profileStorageResponse(
                epoch: 1,
                profile: profile,
                .success(storage.paths)
            )
        ) {
            $0.phase = .authenticated
            $0.profileStoragePaths = storage.paths
            $0.account = AccountFeature.State(
                mode: .authenticated,
                displayName: profile.displayName
            )
            $0.mainTab = MainTabFeature.State()
        }
        XCTAssertEqual(names.calls, ["nil", "Taylor"])
    }

    @MainActor
    func testSignInSuccessBootstrapsAndCancellationRemainsSignedOut() async {
        let session = session
        let profile = profile
        let storage = profileStorageFixture(for: profile)
        let success = TestStore(initialState: .signedOut(epoch: 1)) {
            AppFeature()
        } withDependencies: {
            $0.authenticationClient = .test(
                signInWithApple: { session },
                bootstrapProfile: { _ in profile }
            )
            $0.authenticatedProfileStorage = storage.client
        }

        await success.send(.account(.signInButtonTapped)) {
            $0.account.isRequestInFlight = true
        }
        await success.receive(
            .account(.delegate(.signInWithAppleRequested))
        ) {
            $0.authEpoch = 2
        }
        await success.receive(
            .signInResponse(epoch: 2, .success(session))
        ) {
            $0.phase = .bootstrappingProfile
            $0.account.isRequestInFlight = false
        }
        await success.receive(
            .bootstrapProfileResponse(epoch: 2, .success(profile))
        ) {
            $0.profile = profile
        }
        await success.receive(
            .profileStorageResponse(
                epoch: 2,
                profile: profile,
                .success(storage.paths)
            )
        ) {
            $0.phase = .authenticated
            $0.profileStoragePaths = storage.paths
            $0.account = AccountFeature.State(
                mode: .authenticated,
                displayName: profile.displayName
            )
            $0.mainTab = MainTabFeature.State()
        }

        let cancelled = TestStore(initialState: .signedOut(epoch: 4)) {
            AppFeature()
        } withDependencies: {
            $0.authenticationClient = .test(
                signInWithApple: {
                    throw AuthenticationClientFailure.cancelled
                }
            )
        }
        await cancelled.send(.account(.signInButtonTapped)) {
            $0.account.isRequestInFlight = true
        }
        await cancelled.receive(
            .account(.delegate(.signInWithAppleRequested))
        ) {
            $0.authEpoch = 5
        }
        await cancelled.receive(
            .signInResponse(epoch: 5, .failure(.cancelled))
        ) {
            $0.account.isRequestInFlight = false
        }
    }

    @MainActor
    func testTokenRefreshPreservesAuthenticatedProfileAndMain() async {
        let initial = AppFeature.State.authenticated(
            profile: profile,
            epoch: 8
        )
        let store = TestStore(initialState: initial) {
            AppFeature()
        }

        await store.send(.authenticationEvent(.sessionRefreshed(session)))
        XCTAssertEqual(store.state, initial)
    }

    @MainActor
    func testAuthenticatedDisplayNameUpdateReplacesPresentationOnly()
        async
    {
        let profile = profile
        let updated = AuthenticatedProfile(
            id: profile.id,
            displayName: "Taylor Prime"
        )
        var competitionClient = CompetitionClient.testValue
        competitionClient.reconcileAll = { _ in
            CompetitionPublication(
                publicationRevision: 1,
                dashboard: CompetitionDashboard(
                    competitions: [],
                    awards: [],
                    issues: [],
                    hiddenTerminalCompetitionCount: 0
                ),
                source: .remoteParticipants
            )
        }
        let store = TestStore(
            initialState: .authenticated(profile: profile, epoch: 8)
        ) {
            AppFeature()
        } withDependencies: {
            $0.authenticationClient = .test(
                updateProfile: { name in
                    XCTAssertEqual(name, "Taylor Prime")
                    return updated
                }
            )
            $0.competitionClient = competitionClient
        }

        await store.send(.account(.editDisplayNameButtonTapped)) {
            $0.account.isEditingDisplayName = true
        }
        await store.send(.account(.displayNameChanged("Taylor Prime"))) {
            $0.account.displayName = "Taylor Prime"
        }
        await store.send(.account(.saveDisplayNameButtonTapped)) {
            $0.account.isRequestInFlight = true
        }
        await store.receive(
            .account(.delegate(.displayNameUpdateRequested("Taylor Prime")))
        )
        await store.receive(
            .updateProfileResponse(epoch: 8, .success(updated))
        ) {
            $0.profile = updated
        }
        await store.receive(
            .account(.profileUpdateFinished("Taylor Prime"))
        ) {
            $0.account.committedDisplayName = "Taylor Prime"
            $0.account.isEditingDisplayName = false
            $0.account.isRequestInFlight = false
        }
        await store.finish()
    }

    @MainActor
    func testTerminalProfileUpdateFailuresTearDownAuthenticatedRuntime()
        async
    {
        for failure in [
            AuthenticationClientFailure.terminalSession,
            .sessionExpired,
        ] {
            let calls = OrderedCallRecorder()
            let storage = profileStorageFixture(for: profile, recorder: calls)
            var initial = AppFeature.State.authenticated(
                profile: profile,
                epoch: 8
            )
            initial.account.isEditingDisplayName = true
            initial.account.isRequestInFlight = true
            let store = TestStore(initialState: initial) {
                AppFeature()
            } withDependencies: {
                $0.authenticatedProfileStorage = storage.client
                $0.competitionClient = .test(
                    stop: { calls.record("runtime-stop") }
                )
            }

            await store.send(
                .updateProfileResponse(epoch: 8, .failure(failure))
            ) {
                $0.authEpoch = 9
                $0.phase = .tearingDown
                $0.mainTab = nil
                $0.pendingTeardown = AppFeature.PendingTeardown(
                    reason: .sessionEnded,
                    profileID: self.profile.id,
                    stopRuntime: true,
                    stage: .prepareRuntime,
                    isRunning: true
                )
            }
            await receiveSuccessfulTeardown(
                store,
                epoch: 9,
                reason: .sessionEnded
            )

            XCTAssertEqual(
                calls.calls,
                ["runtime-stop", "storage-teardown"]
            )
            await store.finish()
        }
    }

    @MainActor
    func testDuplicateSignedOutEventIsIgnoredAfterTransitionCompletes() async {
        let initial = AppFeature.State.signedOut(epoch: 9)
        let store = TestStore(initialState: initial) {
            AppFeature()
        }

        await store.send(.authenticationEvent(.signedOut))
        XCTAssertEqual(store.state, initial)
    }

    @MainActor
    func testSignedOutDuringBootstrapInvalidatesPendingProfileWork() async {
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .bootstrappingProfile,
                authEpoch: 9
            )
        ) {
            AppFeature()
        }

        await store.send(.authenticationEvent(.signedOut)) {
            $0.authEpoch = 10
            $0.account.isRequestInFlight = true
            $0.phase = .tearingDown
            $0.pendingTeardown = AppFeature.PendingTeardown(
                reason: .sessionEnded,
                profileID: nil,
                stopRuntime: false,
                stage: .prepareRuntime,
                isRunning: true
            )
        }
        await receiveSuccessfulTeardown(
            store,
            epoch: 10,
            reason: .sessionEnded
        )
        await store.send(
            .bootstrapProfileResponse(epoch: 9, .success(profile))
        )
        XCTAssertNil(store.state.profile)
        XCTAssertNil(store.state.mainTab)
    }

    @MainActor
    func testSignedOutDuringProfileMountStopsRuntimeBeforeStorageTeardown()
        async
    {
        let calls = OrderedCallRecorder()
        let storage = profileStorageFixture(for: profile, recorder: calls)
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .bootstrappingProfile,
                profile: profile,
                authEpoch: 9
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.authenticatedProfileStorage = storage.client
            $0.competitionClient = .test(
                stop: { calls.record("runtime-stop") },
                prepareForProfileTeardown: { requireRemoteRemoval in
                    calls.record(
                        "installation-teardown:\(requireRemoteRemoval)"
                    )
                }
            )
        }

        await store.send(.authenticationEvent(.signedOut)) {
            $0.authEpoch = 10
            $0.account.isRequestInFlight = true
            $0.phase = .tearingDown
            $0.pendingTeardown = AppFeature.PendingTeardown(
                reason: .sessionEnded,
                profileID: self.profile.id,
                stopRuntime: true,
                stage: .prepareRuntime,
                isRunning: true
            )
        }
        await receiveSuccessfulTeardown(
            store,
            epoch: 10,
            reason: .sessionEnded
        )
        XCTAssertEqual(
            calls.calls,
            [
                "installation-teardown:false",
                "runtime-stop",
                "storage-teardown",
            ]
        )
    }

    @MainActor
    func testTerminalTeardownWaitsForCancellationIgnoringProfileMount() async {
        let calls = OrderedCallRecorder()
        let storage = profileStorageFixture(for: profile, recorder: calls)
        let mountGate = AppFeatureCancellationIgnoringGate()
        let earlyPrepare = expectation(
            description: "teardown must not overtake profile mount"
        )
        earlyPrepare.isInverted = true
        let observationWindow = LockedFlag(true)
        var competitionClient = CompetitionClient.test(
            stop: { calls.record("runtime-stop") },
            prepareForProfileTeardown: { requireRemoteRemoval in
                calls.record("installation-teardown:\(requireRemoteRemoval)")
                if observationWindow.value { earlyPrepare.fulfill() }
            }
        )
        competitionClient.mountAuthenticatedProfile = { _, _ in
            calls.record("competition-mount-start")
            await mountGate.enterAndWait()
            calls.record("competition-mount-finished")
        }
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .bootstrappingProfile,
                authEpoch: 9
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.authenticatedProfileStorage = storage.client
            $0.competitionClient = competitionClient
        }

        await store.send(
            .bootstrapProfileResponse(epoch: 9, .success(profile))
        ) {
            $0.profile = self.profile
        }
        await mountGate.waitUntilEntered()

        await store.send(.authenticationEvent(.signedOut)) {
            $0.authEpoch = 10
            $0.account.isRequestInFlight = true
            $0.phase = .tearingDown
            $0.pendingTeardown = AppFeature.PendingTeardown(
                reason: .sessionEnded,
                profileID: self.profile.id,
                stopRuntime: true,
                stage: .prepareRuntime,
                isRunning: true
            )
        }
        await fulfillment(of: [earlyPrepare], timeout: 0.1)
        XCTAssertEqual(
            calls.calls,
            ["storage-mount", "competition-mount-start"]
        )

        observationWindow.set(false)
        await mountGate.release()
        await receiveSuccessfulTeardown(
            store,
            epoch: 10,
            reason: .sessionEnded
        )
        XCTAssertEqual(
            calls.calls,
            [
                "storage-mount",
                "competition-mount-start",
                "competition-mount-finished",
                "installation-teardown:false",
                "runtime-stop",
                "storage-teardown",
            ]
        )
    }

    @MainActor
    func testUserSignOutStopsRuntimeBeforeClearingAuth() async {
        let calls = OrderedCallRecorder()
        let storage = profileStorageFixture(
            for: profile,
            recorder: calls
        )
        let store = TestStore(
            initialState: .authenticated(profile: profile, epoch: 3)
        ) {
            AppFeature()
        } withDependencies: {
            $0.authenticationClient = .test(
                signOut: { calls.record("auth-sign-out") }
            )
            $0.authenticatedProfileStorage = storage.client
            $0.competitionClient = .test(
                stop: { calls.record("runtime-stop") },
                prepareForProfileTeardown: { requireRemoteRemoval in
                    calls.record(
                        "installation-teardown:\(requireRemoteRemoval)"
                    )
                }
            )
        }

        await store.send(.account(.signOutButtonTapped)) {
            $0.account.isRequestInFlight = true
        }
        await store.receive(.account(.delegate(.signOutRequested))) {
            $0.authEpoch = 4
            $0.phase = .tearingDown
            $0.mainTab = nil
            $0.pendingTeardown = AppFeature.PendingTeardown(
                reason: .userRequested,
                profileID: self.profile.id,
                stopRuntime: true,
                stage: .prepareRuntime,
                isRunning: true
            )
        }
        await receiveSuccessfulTeardown(
            store,
            epoch: 4,
            reason: .userRequested
        )
        XCTAssertEqual(
            calls.calls,
            [
                "installation-teardown:true",
                "runtime-stop",
                "storage-teardown",
                "auth-sign-out",
            ]
        )
    }

    @MainActor
    func testExpectedSignedOutEchoPreservesUserRequestedTeardownReason() async {
        let pendingTeardown = AppFeature.PendingTeardown(
            reason: .userRequested,
            profileID: profile.id,
            stopRuntime: true,
            stage: .finishUserSignOut,
            isRunning: true
        )
        let initial = AppFeature.State(
            phase: .tearingDown,
            account: AccountFeature.State(mode: .authenticated),
            profile: profile,
            pendingTeardown: pendingTeardown,
            authEpoch: 4
        )
        let store = TestStore(initialState: initial) {
            AppFeature()
        }

        await store.send(.authenticationEvent(.signedOut))

        XCTAssertEqual(store.state.pendingTeardown, pendingTeardown)
    }

    @MainActor
    func testUserSignOutFailureDoesNotCompleteTransition() async {
        let calls = OrderedCallRecorder()
        let storage = profileStorageFixture(
            for: profile,
            recorder: calls
        )
        let store = TestStore(
            initialState: .authenticated(profile: profile, epoch: 3)
        ) {
            AppFeature()
        } withDependencies: {
            $0.authenticationClient = .test(
                signOut: {
                    calls.record("auth-sign-out")
                    throw AuthenticationClientFailure.operationFailed
                }
            )
            $0.authenticatedProfileStorage = storage.client
            $0.competitionClient = .test(
                stop: { calls.record("runtime-stop") },
                prepareForProfileTeardown: { requireRemoteRemoval in
                    calls.record(
                        "installation-teardown:\(requireRemoteRemoval)"
                    )
                }
            )
        }

        await store.send(.account(.signOutButtonTapped)) {
            $0.account.isRequestInFlight = true
        }
        await store.receive(.account(.delegate(.signOutRequested))) {
            $0.authEpoch = 4
            $0.phase = .tearingDown
            $0.mainTab = nil
            $0.pendingTeardown = AppFeature.PendingTeardown(
                reason: .userRequested,
                profileID: self.profile.id,
                stopRuntime: true,
                stage: .prepareRuntime,
                isRunning: true
            )
        }
        await store.receive(
            .teardownStageCompleted(
                epoch: 4,
                reason: .userRequested,
                stage: .prepareRuntime
            )
        ) {
            $0.pendingTeardown?.stage = .removeProfileStorage
        }
        await store.receive(
            .teardownStageCompleted(
                epoch: 4,
                reason: .userRequested,
                stage: .removeProfileStorage
            )
        ) {
            $0.pendingTeardown?.stage = .finishUserSignOut
        }
        await store.receive(
            .teardownFailed(
                epoch: 4,
                reason: .userRequested,
                stage: .finishUserSignOut,
                failure: .cleanupFailed
            )
        ) {
            $0.phase = .launchFailure
            $0.mainTab = nil
            $0.pendingTeardown?.stage = .finishUserSignOut
            $0.pendingTeardown?.isRunning = false
            $0.account = AccountFeature.State(mode: .launchFailure)
            $0.account.message = .tryAgain
        }
        XCTAssertEqual(
            calls.calls,
            [
                "installation-teardown:true",
                "runtime-stop",
                "storage-teardown",
                "auth-sign-out",
            ]
        )
    }

    @MainActor
    func testRequiredInstallationRemovalFailurePreservesRuntimeAndProfileStorage()
        async
    {
        let calls = OrderedCallRecorder()
        let profile = profile
        let storage = profileStorageFixture(for: profile, recorder: calls)
        var initial = AppFeature.State.authenticated(
            profile: profile,
            epoch: 3
        )
        initial.profileStoragePaths = storage.paths
        let store = TestStore(
            initialState: initial
        ) {
            AppFeature()
        } withDependencies: {
            $0.authenticationClient = .test(
                signOut: { calls.record("auth-sign-out") }
            )
            $0.authenticatedProfileStorage = storage.client
            $0.competitionClient = .test(
                stop: { calls.record("runtime-stop") },
                prepareForProfileTeardown: { requireRemoteRemoval in
                    calls.record(
                        "installation-teardown:\(requireRemoteRemoval)"
                    )
                    throw CompetitionRemoteFailure.retryableTransport
                }
            )
        }

        await store.send(.account(.signOutButtonTapped)) {
            $0.account.isRequestInFlight = true
        }
        await store.receive(.account(.delegate(.signOutRequested))) {
            $0.authEpoch = 4
            $0.phase = .tearingDown
            $0.mainTab = nil
            $0.pendingTeardown = AppFeature.PendingTeardown(
                reason: .userRequested,
                profileID: profile.id,
                stopRuntime: true,
                stage: .prepareRuntime,
                isRunning: true
            )
        }
        await store.receive(
            .teardownFailed(
                epoch: 4,
                reason: .userRequested,
                stage: .prepareRuntime,
                failure: .cleanupFailed
            )
        ) {
            $0.phase = .launchFailure
            $0.mainTab = nil
            $0.pendingTeardown?.isRunning = false
            $0.account = AccountFeature.State(mode: .launchFailure)
            $0.account.message = .tryAgain
        }
        XCTAssertEqual(
            calls.calls,
            ["installation-teardown:true"]
        )
        XCTAssertEqual(store.state.profile, profile)
        XCTAssertEqual(store.state.profileStoragePaths, storage.paths)
    }

    @MainActor
    func testAccountDeletionTearsDownLocalStateOnlyAfterServerReceipt() async {
        let calls = OrderedCallRecorder()
        let storage = profileStorageFixture(for: profile, recorder: calls)
        let store = TestStore(
            initialState: .authenticated(profile: profile, epoch: 3)
        ) {
            AppFeature()
        } withDependencies: {
            $0.authenticationClient = .test(
                deleteAccount: { calls.record("server-confirmed") }
            )
            $0.authenticatedProfileStorage = storage.client
            $0.competitionClient = .test(
                stop: { calls.record("runtime-stop") },
                prepareForProfileTeardown: { requireRemoteRemoval in
                    calls.record(
                        "installation-teardown:\(requireRemoteRemoval)"
                    )
                }
            )
        }

        await store.send(.account(.deleteAccountButtonTapped)) {
            $0.account.isDeleteConfirmationPresented = true
        }
        await store.send(.account(.deleteAccountConfirmationAccepted)) {
            $0.account.isDeleteConfirmationPresented = false
            $0.account.isRequestInFlight = true
            $0.account.isDeletingAccount = true
        }
        await store.receive(.account(.delegate(.deleteAccountRequested))) {
            $0.authEpoch = 4
        }
        await store.receive(.accountDeletionResponse(epoch: 4, .success)) {
            $0.authEpoch = 5
            $0.phase = .tearingDown
            $0.mainTab = nil
            $0.pendingTeardown = AppFeature.PendingTeardown(
                reason: .accountDeleted,
                profileID: self.profile.id,
                stopRuntime: true,
                stage: .prepareRuntime,
                isRunning: true
            )
        }
        await receiveSuccessfulTeardown(
            store,
            epoch: 5,
            reason: .accountDeleted
        )

        XCTAssertEqual(
            calls.calls,
            [
                "server-confirmed",
                "installation-teardown:false",
                "runtime-stop",
                "storage-teardown",
            ]
        )
    }

    @MainActor
    func testStopDoesNotCancelInFlightServerAccountDeletion() async {
        let deletionStarted = expectation(description: "deletion started")
        let deletionCancelled = expectation(description: "deletion cancelled")
        deletionCancelled.isInverted = true
        let (deletionRelease, releaseDeletion) = AsyncStream<Void>.makeStream()
        releaseDeletion.onTermination = { termination in
            if case .cancelled = termination {
                deletionCancelled.fulfill()
            }
        }
        let profile = profile
        let storage = profileStorageFixture(for: profile)
        var initial = AppFeature.State.authenticated(
            profile: profile,
            epoch: 3
        )
        initial.profileStoragePaths = storage.paths
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.authenticationClient = .test(
                deleteAccount: {
                    deletionStarted.fulfill()
                    for await _ in deletionRelease { break }
                }
            )
            $0.authenticatedProfileStorage = storage.client
            $0.competitionClient = .test(
                stop: {},
                prepareForProfileTeardown: { _ in }
            )
        }

        await store.send(.account(.deleteAccountButtonTapped)) {
            $0.account.isDeleteConfirmationPresented = true
        }
        await store.send(.account(.deleteAccountConfirmationAccepted)) {
            $0.account.isDeleteConfirmationPresented = false
            $0.account.isRequestInFlight = true
            $0.account.isDeletingAccount = true
        }
        await store.receive(.account(.delegate(.deleteAccountRequested))) {
            $0.authEpoch = 4
        }
        await fulfillment(of: [deletionStarted], timeout: 1)

        await store.send(.stop)
        await fulfillment(of: [deletionCancelled], timeout: 0.1)

        releaseDeletion.yield()
        releaseDeletion.finish()
        await store.receive(.accountDeletionResponse(epoch: 4, .success)) {
            $0.authEpoch = 5
            $0.phase = .tearingDown
            $0.mainTab = nil
            $0.pendingTeardown = AppFeature.PendingTeardown(
                reason: .accountDeleted,
                profileID: profile.id,
                stopRuntime: true,
                stage: .prepareRuntime,
                isRunning: true
            )
        }
        await store.receive(
            .teardownStageCompleted(
                epoch: 5,
                reason: .accountDeleted,
                stage: .prepareRuntime
            )
        ) {
            $0.pendingTeardown?.stage = .removeProfileStorage
        }
        await store.receive(
            .teardownStageCompleted(
                epoch: 5,
                reason: .accountDeleted,
                stage: .removeProfileStorage
            )
        ) {
            $0.pendingTeardown?.stage = .finishUserSignOut
        }
        await store.receive(
            .teardownStageCompleted(
                epoch: 5,
                reason: .accountDeleted,
                stage: .finishUserSignOut
            )
        )
        await store.receive(
            .teardownCompleted(epoch: 5, reason: .accountDeleted)
        ) {
            $0.phase = .signedOut
            $0.profile = nil
            $0.profileStoragePaths = nil
            $0.pendingTeardown = nil
            $0.account = AccountFeature.State(mode: .signedOut)
        }
    }

    @MainActor
    func testAuthoritativeSignedOutUpgradeDoesNotStrandRunningTeardown()
        async
    {
        let prepareStarted = expectation(description: "prepare started")
        let (prepareRelease, releasePrepare) = AsyncStream<Void>.makeStream()
        let calls = OrderedCallRecorder()
        let profile = profile
        let storage = profileStorageFixture(for: profile, recorder: calls)
        var initial = AppFeature.State.authenticated(
            profile: profile,
            epoch: 3
        )
        initial.profileStoragePaths = storage.paths
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.authenticationClient = .test(
                signOut: { calls.record("unexpected-auth-sign-out") }
            )
            $0.authenticatedProfileStorage = storage.client
            $0.competitionClient = .test(
                stop: { calls.record("runtime-stop") },
                prepareForProfileTeardown: { _ in
                    prepareStarted.fulfill()
                    for await _ in prepareRelease { break }
                }
            )
        }

        await store.send(.account(.signOutButtonTapped)) {
            $0.account.isRequestInFlight = true
        }
        await store.receive(.account(.delegate(.signOutRequested))) {
            $0.authEpoch = 4
            $0.phase = .tearingDown
            $0.mainTab = nil
            $0.pendingTeardown = AppFeature.PendingTeardown(
                reason: .userRequested,
                profileID: profile.id,
                stopRuntime: true,
                stage: .prepareRuntime,
                isRunning: true
            )
        }
        await fulfillment(of: [prepareStarted], timeout: 1)
        await store.send(.authenticationEvent(.signedOut)) {
            $0.pendingTeardown?.reason = .sessionEnded
        }

        releasePrepare.yield()
        releasePrepare.finish()
        await store.receive(
            .teardownStageCompleted(
                epoch: 4,
                reason: .userRequested,
                stage: .prepareRuntime
            )
        ) {
            $0.pendingTeardown?.stage = .removeProfileStorage
        }
        await store.receive(
            .teardownStageCompleted(
                epoch: 4,
                reason: .sessionEnded,
                stage: .removeProfileStorage
            )
        ) {
            $0.pendingTeardown?.stage = .finishUserSignOut
        }
        await store.receive(
            .teardownStageCompleted(
                epoch: 4,
                reason: .sessionEnded,
                stage: .finishUserSignOut
            )
        )
        await store.receive(
            .teardownCompleted(epoch: 4, reason: .sessionEnded)
        ) {
            $0.phase = .signedOut
            $0.profile = nil
            $0.profileStoragePaths = nil
            $0.pendingTeardown = nil
            $0.account = AccountFeature.State(mode: .signedOut)
            $0.account.message = .sessionEnded
        }
        XCTAssertEqual(
            calls.calls,
            ["runtime-stop", "storage-teardown"]
        )
    }

    @MainActor
    func testEarlySignedOutCannotCompleteDeletionBeforeCleanupFailure() async {
        var initial = AppFeature.State.authenticated(profile: profile, epoch: 4)
        initial.account.isDeletingAccount = true
        initial.account.isRequestInFlight = true
        let store = TestStore(initialState: initial) {
            AppFeature()
        }

        // The SDK may emit this before local removal verification settles.
        await store.send(.authenticationEvent(.signedOut))
        XCTAssertEqual(store.state.phase, .authenticated)
        XCTAssertEqual(store.state.profile, profile)
        XCTAssertNil(store.state.pendingTeardown)

        await store.send(
            .accountDeletionResponse(epoch: 4, .failure(.operationFailed))
        )
        await store.receive(.account(.operationFailed(.operationFailed))) {
            $0.account.isRequestInFlight = false
            $0.account.isDeletingAccount = false
            $0.account.message = .tryAgain
        }
        XCTAssertEqual(store.state.phase, .authenticated)
        XCTAssertEqual(store.state.profile, profile)
        XCTAssertNotNil(store.state.mainTab)
        XCTAssertNil(store.state.pendingTeardown)
    }

    @MainActor
    func testAccountDeletionFailurePreservesAuthenticatedLocalState() async {
        let calls = OrderedCallRecorder()
        let storage = profileStorageFixture(for: profile, recorder: calls)
        let store = TestStore(
            initialState: .authenticated(profile: profile, epoch: 3)
        ) {
            AppFeature()
        } withDependencies: {
            $0.authenticationClient = .test(
                deleteAccount: {
                    calls.record("server-failed")
                    throw AuthenticationClientFailure.operationFailed
                }
            )
            $0.authenticatedProfileStorage = storage.client
            $0.competitionClient = .test(
                stop: { calls.record("unexpected-runtime-stop") },
                prepareForProfileTeardown: { _ in
                    calls.record("unexpected-installation-teardown")
                }
            )
        }

        await store.send(.account(.deleteAccountButtonTapped)) {
            $0.account.isDeleteConfirmationPresented = true
        }
        await store.send(.account(.deleteAccountConfirmationAccepted)) {
            $0.account.isDeleteConfirmationPresented = false
            $0.account.isRequestInFlight = true
            $0.account.isDeletingAccount = true
        }
        await store.receive(.account(.delegate(.deleteAccountRequested))) {
            $0.authEpoch = 4
        }
        await store.receive(
            .accountDeletionResponse(epoch: 4, .failure(.operationFailed))
        )
        await store.receive(.account(.operationFailed(.operationFailed))) {
            $0.account.isRequestInFlight = false
            $0.account.isDeletingAccount = false
            $0.account.message = .tryAgain
        }

        XCTAssertEqual(store.state.phase, .authenticated)
        XCTAssertEqual(store.state.profile, profile)
        XCTAssertNotNil(store.state.mainTab)
        XCTAssertEqual(calls.calls, ["server-failed"])
    }

    @MainActor
    func testAuthoritativeAccountDeletedEventWinsOverPendingFailure() async {
        let calls = OrderedCallRecorder()
        let storage = profileStorageFixture(for: profile, recorder: calls)
        var initial = AppFeature.State.authenticated(
            profile: profile,
            epoch: 4
        )
        initial.account.isRequestInFlight = true
        initial.account.isDeletingAccount = true
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.authenticatedProfileStorage = storage.client
            $0.competitionClient = .test(
                stop: { calls.record("runtime-stop") }
            )
        }

        await store.send(.authenticationEvent(.accountDeleted)) {
            $0.authEpoch = 5
            $0.phase = .tearingDown
            $0.mainTab = nil
            $0.pendingTeardown = AppFeature.PendingTeardown(
                reason: .accountDeleted,
                profileID: self.profile.id,
                stopRuntime: true,
                stage: .prepareRuntime,
                isRunning: true
            )
        }
        await store.receive(
            .teardownStageCompleted(
                epoch: 5,
                reason: .accountDeleted,
                stage: .prepareRuntime
            )
        ) {
            $0.pendingTeardown?.stage = .removeProfileStorage
        }
        await store.receive(
            .teardownStageCompleted(
                epoch: 5,
                reason: .accountDeleted,
                stage: .removeProfileStorage
            )
        ) {
            $0.pendingTeardown?.stage = .finishUserSignOut
        }
        await store.receive(
            .teardownStageCompleted(
                epoch: 5,
                reason: .accountDeleted,
                stage: .finishUserSignOut
            )
        )
        await store.receive(
            .teardownCompleted(epoch: 5, reason: .accountDeleted)
        ) {
            $0.phase = .signedOut
            $0.profile = nil
            $0.pendingTeardown = nil
            $0.account = AccountFeature.State(mode: .signedOut)
        }

        await store.send(
            .accountDeletionResponse(epoch: 4, .failure(.operationFailed))
        )
        XCTAssertEqual(store.state.phase, .signedOut)
        XCTAssertNil(store.state.profile)
        XCTAssertNil(store.state.mainTab)
        XCTAssertEqual(calls.calls, ["runtime-stop", "storage-teardown"])
    }

    @MainActor
    func testSignedOutAndDeletedEventsTearDownAuthenticatedMain() async {
        let registry = SharedClientLifetime { AuthenticationEventTestOwner() }
        guard let owner = try? registry.client() else { return XCTFail("Missing test owner") }
        let origin = AuthenticationEventOrigin(registry: registry, owner: owner)
        for (event, reason) in [
            (
                AuthenticationEvent.signedOut,
                AppFeature.TeardownReason.sessionEnded
            ),
            (.accountDeleted, .accountDeleted),
            (.owned(origin, .signedOut), .sessionEnded),
            (.owned(origin, .accountDeleted), .accountDeleted),
        ] {
            let calls = OrderedCallRecorder()
            let storage = profileStorageFixture(
                for: profile,
                recorder: calls
            )
            let store = TestStore(
                initialState: .authenticated(profile: profile, epoch: 10)
            ) {
                AppFeature()
            } withDependencies: {
                $0.authenticatedProfileStorage = storage.client
                $0.competitionClient = .test(
                    stop: { calls.record("runtime-stop") }
                )
            }

            await store.send(.authenticationEvent(event)) {
                $0.authEpoch = 11
                $0.account.isRequestInFlight = true
                $0.phase = .tearingDown
                $0.mainTab = nil
                $0.pendingTeardown = AppFeature.PendingTeardown(
                    reason: reason,
                    profileID: self.profile.id,
                    stopRuntime: true,
                    stage: .prepareRuntime,
                    isRunning: true
                )
            }
            await receiveSuccessfulTeardown(
                store,
                epoch: 11,
                reason: reason
            )
            XCTAssertEqual(calls.calls, ["runtime-stop", "storage-teardown"])
        }
    }

    @MainActor
    func testStopCancelsSingleAuthenticationEventStream() async {
        let cancellation = expectation(description: "auth stream cancelled")
        let (events, continuation) = AsyncStream<AuthenticationEvent>
            .makeStream()
        continuation.onTermination = { _ in cancellation.fulfill() }
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.authenticationClient = .test(
                restoreSession: { nil },
                events: { events }
            )
        }

        await store.send(.task) {
            $0.authEpoch = 1
            $0.isAuthenticationMonitoring = true
        }
        await store.receive(
            .restoreSessionResponse(epoch: 1, .success(nil))
        ) {
            $0.phase = .signedOut
            $0.account = AccountFeature.State(mode: .signedOut)
        }
        await store.send(.task)
        await store.send(.stop) {
            $0.isAuthenticationMonitoring = false
        }
        await fulfillment(of: [cancellation], timeout: 1)
    }

    @MainActor
    func testRestartWithNoSessionTerminallyCleansStoppedAuthenticatedProfile()
        async
    {
        let calls = OrderedCallRecorder()
        let storage = profileStorageFixture(for: profile, recorder: calls)
        let store = TestStore(
            initialState: .authenticated(profile: profile, epoch: 3)
        ) {
            AppFeature()
        } withDependencies: {
            $0.authenticationClient = .test(restoreSession: { nil })
            $0.authenticatedProfileStorage = storage.client
            $0.competitionClient = .test(
                stop: { calls.record("runtime-stop") },
                prepareForProfileTeardown: { requireRemoteRemoval in
                    calls.record(
                        "installation-teardown:\(requireRemoteRemoval)"
                    )
                }
            )
        }

        await store.send(.task) {
            $0.authEpoch = 4
            $0.phase = .launching
            $0.isAuthenticationMonitoring = true
        }
        await store.receive(
            .restoreSessionResponse(epoch: 4, .success(nil))
        ) {
            $0.phase = .tearingDown
            $0.account.isRequestInFlight = true
            $0.mainTab = nil
            $0.pendingTeardown = AppFeature.PendingTeardown(
                reason: .sessionEnded,
                profileID: self.profile.id,
                stopRuntime: true,
                stage: .prepareRuntime,
                isRunning: true
            )
        }
        await receiveSuccessfulTeardown(
            store,
            epoch: 4,
            reason: .sessionEnded
        )

        XCTAssertEqual(
            calls.calls,
            [
                "installation-teardown:false",
                "runtime-stop",
                "storage-teardown",
            ]
        )
    }

    @MainActor
    func testStaleAuthEpochResponsesCannotReplaceCurrentIdentity() async {
        let current = AppFeature.State.authenticated(
            profile: profile,
            epoch: 12
        )
        let store = TestStore(initialState: current) {
            AppFeature()
        }

        await store.send(
            .bootstrapProfileResponse(
                epoch: 11,
                .success(
                    AuthenticatedProfile(
                        id: UUID(
                            uuidString:
                                "94000000-0000-4000-8000-000000000099"
                        )!,
                        displayName: "Stale"
                    )
                )
            )
        )
        await store.send(
            .signInResponse(epoch: 11, .success(session))
        )
        XCTAssertEqual(store.state, current)
    }

    @MainActor
    func testProfileStorageMountFailureNeverConstructsMain() async {
        let profile = profile
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .bootstrappingProfile,
                authEpoch: 7
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.authenticatedProfileStorage = AuthenticatedProfileStorage(
                mount: { _ in
                    throw AuthenticatedProfileStorageFailure
                        .unsafeFilesystemEntry
                },
                teardown: { _ in }
            )
        }

        await store.send(
            .bootstrapProfileResponse(epoch: 7, .success(profile))
        ) {
            $0.profile = profile
        }
        XCTAssertNil(store.state.mainTab)
        await store.receive(
            .profileStorageResponse(
                epoch: 7,
                profile: profile,
                .failure(.unsafeFilesystemEntry)
            )
        ) {
            $0.phase = .launchFailure
            $0.profile = nil
            $0.account = AccountFeature.State(mode: .launchFailure)
            $0.account.message = .tryAgain
        }
        XCTAssertNil(store.state.mainTab)
    }

    @MainActor
    func testCompetitionMountFailureCleansUpMountedProfileStorage() async {
        let calls = OrderedCallRecorder()
        let profile = profile
        let storage = profileStorageFixture(for: profile, recorder: calls)
        var competitionClient = CompetitionClient.test(
            stop: { calls.record("runtime-stop") }
        )
        competitionClient.mountAuthenticatedProfile = { _, _ in
            calls.record("competition-mount")
            throw RemoteCompetitionRuntimeFailure.storageUnavailable
        }
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .bootstrappingProfile,
                authEpoch: 7
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.authenticatedProfileStorage = storage.client
            $0.competitionClient = competitionClient
        }

        await store.send(
            .bootstrapProfileResponse(epoch: 7, .success(profile))
        ) {
            $0.profile = profile
        }
        await store.receive(
            .profileStorageResponse(
                epoch: 7,
                profile: profile,
                .failure(.unsafeFilesystemEntry)
            )
        ) {
            $0.phase = .launchFailure
            $0.profile = nil
            $0.account = AccountFeature.State(mode: .launchFailure)
            $0.account.message = .tryAgain
        }
        XCTAssertEqual(
            calls.calls,
            [
                "storage-mount",
                "competition-mount",
                "runtime-stop",
                "storage-teardown",
            ]
        )
        XCTAssertNil(store.state.mainTab)
    }

    @MainActor
    func testStorageFailureRetriesStorageWithoutRepeatingPrepareOrStop()
        async
    {
        let calls = OrderedCallRecorder()
        let storageAttempts = LockedAttemptCounter()
        let storageRetried = expectation(description: "storage retried")
        let authenticationFinished = expectation(
            description: "authentication sign-out finished"
        )
        let profile = profile
        let storage = profileStorageFixture(for: profile)
        var initial = AppFeature.State.authenticated(
            profile: profile,
            epoch: 3
        )
        initial.profileStoragePaths = storage.paths
        let store = TestStore(
            initialState: initial
        ) {
            AppFeature()
        } withDependencies: {
            $0.authenticationClient = .test(
                restoreSession: {
                    calls.record("unexpected-restore-session")
                    return nil
                },
                signOut: {
                    calls.record("auth-sign-out")
                    authenticationFinished.fulfill()
                }
            )
            $0.authenticatedProfileStorage = AuthenticatedProfileStorage(
                mount: { _ in
                    throw AuthenticatedProfileStorageFailure
                        .unsafeFilesystemEntry
                },
                teardown: { id in
                    let attempt = storageAttempts.next()
                    calls.record("storage-teardown:\(attempt):\(id.uuidString)")
                    if attempt == 1 {
                        throw AuthenticatedProfileStorageFailure.cleanupFailed
                    }
                    storageRetried.fulfill()
                }
            )
            $0.competitionClient = .test(
                stop: { calls.record("runtime-stop") },
                prepareForProfileTeardown: { requireRemoteRemoval in
                    calls.record(
                        "installation-teardown:\(requireRemoteRemoval)"
                    )
                }
            )
        }

        await store.send(.account(.signOutButtonTapped)) {
            $0.account.isRequestInFlight = true
        }
        await store.receive(.account(.delegate(.signOutRequested))) {
            $0.authEpoch = 4
            $0.phase = .tearingDown
            $0.mainTab = nil
            $0.pendingTeardown = AppFeature.PendingTeardown(
                reason: .userRequested,
                profileID: profile.id,
                stopRuntime: true,
                stage: .prepareRuntime,
                isRunning: true
            )
        }
        await store.receive(
            .teardownStageCompleted(
                epoch: 4,
                reason: .userRequested,
                stage: .prepareRuntime
            )
        ) {
            $0.pendingTeardown?.stage = .removeProfileStorage
        }
        await store.receive(
            .teardownFailed(
                epoch: 4,
                reason: .userRequested,
                stage: .removeProfileStorage,
                failure: .cleanupFailed
            )
        ) {
            $0.phase = .launchFailure
            $0.mainTab = nil
            $0.pendingTeardown?.stage = .removeProfileStorage
            $0.pendingTeardown?.isRunning = false
            $0.account = AccountFeature.State(mode: .launchFailure)
            $0.account.message = .tryAgain
        }

        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.account(.retryButtonTapped))
        await fulfillment(
            of: [storageRetried, authenticationFinished],
            timeout: 1
        )
        await store.skipReceivedActions(strict: false)

        XCTAssertEqual(
            calls.calls,
            [
                "installation-teardown:true",
                "runtime-stop",
                "storage-teardown:1:\(profile.id.uuidString)",
                "storage-teardown:2:\(profile.id.uuidString)",
                "auth-sign-out",
            ]
        )
        XCTAssertEqual(storageAttempts.value, 2)
        XCTAssertEqual(store.state.phase, .signedOut)
    }

    @MainActor
    func testTeardownPersistsStorageStageBeforeRemovingProfileStorage()
        async
    {
        let storageStarted = expectation(description: "storage removal started")
        let (storageRelease, releaseStorage) = AsyncStream<Void>.makeStream()
        let profile = profile
        let storage = profileStorageFixture(for: profile)
        var initial = AppFeature.State.authenticated(
            profile: profile,
            epoch: 3
        )
        initial.profileStoragePaths = storage.paths
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.authenticationClient = .test()
            $0.authenticatedProfileStorage = AuthenticatedProfileStorage(
                mount: storage.client.mount,
                teardown: { _ in
                    storageStarted.fulfill()
                    for await _ in storageRelease {
                        break
                    }
                }
            )
            $0.competitionClient = .test(
                stop: {},
                prepareForProfileTeardown: { _ in }
            )
        }

        await store.send(.account(.signOutButtonTapped)) {
            $0.account.isRequestInFlight = true
        }
        await store.receive(.account(.delegate(.signOutRequested))) {
            $0.authEpoch = 4
            $0.phase = .tearingDown
            $0.mainTab = nil
            $0.pendingTeardown = AppFeature.PendingTeardown(
                reason: .userRequested,
                profileID: profile.id,
                stopRuntime: true,
                stage: .prepareRuntime,
                isRunning: true
            )
        }

        await store.receive(
            .teardownStageCompleted(
                epoch: 4,
                reason: .userRequested,
                stage: .prepareRuntime
            )
        ) {
            $0.pendingTeardown?.stage = .removeProfileStorage
        }

        await fulfillment(of: [storageStarted], timeout: 1)
        XCTAssertEqual(
            store.state.pendingTeardown?.stage,
            .removeProfileStorage
        )

        releaseStorage.yield()
        releaseStorage.finish()
        await store.receive(
            .teardownStageCompleted(
                epoch: 4,
                reason: .userRequested,
                stage: .removeProfileStorage
            )
        ) {
            $0.pendingTeardown?.stage = .finishUserSignOut
        }
        await store.receive(
            .teardownStageCompleted(
                epoch: 4,
                reason: .userRequested,
                stage: .finishUserSignOut
            )
        )
        await store.receive(
            .teardownCompleted(epoch: 4, reason: .userRequested)
        ) {
            $0.phase = .signedOut
            $0.profile = nil
            $0.profileStoragePaths = nil
            $0.pendingTeardown = nil
            $0.account = AccountFeature.State(mode: .signedOut)
        }
    }
}

private final class AuthenticationEventTestOwner: Sendable {}

private final class OrderedCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var calls: [String] {
        lock.withLock { storage }
    }

    func record(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private final class LockedAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func next() -> Int {
        lock.withLock {
            storage += 1
            return storage
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    init(_ value: Bool) {
        self.storage = value
    }

    var value: Bool {
        lock.withLock { storage }
    }

    func set(_ value: Bool) {
        lock.withLock { storage = value }
    }
}

private actor AppFeatureCancellationIgnoringGate {
    private var didEnter = false
    private var didRelease = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        didEnter = true
        let waiters = entryWaiters
        entryWaiters = []
        waiters.forEach { $0.resume() }
        guard !didRelease else { return }
        await withCheckedContinuation { continuation in
            if didRelease {
                continuation.resume()
            } else {
                releaseWaiter = continuation
            }
        }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        didRelease = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private struct ProfileStorageFixture {
    let client: AuthenticatedProfileStorage
    let paths: AuthenticatedProfileStoragePaths
}

private func profileStorageFixture(
    for profile: AuthenticatedProfile,
    recorder: OrderedCallRecorder? = nil
) -> ProfileStorageFixture {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("healthcomp-app-feature-tests", isDirectory: true)
        .appendingPathComponent(
            profile.id.uuidString.lowercased(),
            isDirectory: true
        )
    let paths = AuthenticatedProfileStoragePaths(
        profileID: profile.id,
        rootDirectory: root
    )
    return ProfileStorageFixture(
        client: AuthenticatedProfileStorage(
            mount: { id in
                guard id == profile.id else {
                    throw AuthenticatedProfileStorageFailure
                        .profileTransitionRequiresCleanup
                }
                recorder?.record("storage-mount")
                return paths
            },
            teardown: { id in
                guard id == profile.id else {
                    throw AuthenticatedProfileStorageFailure
                        .profileTransitionRequiresCleanup
                }
                recorder?.record("storage-teardown")
            }
        ),
        paths: paths
    )
}

private extension AuthenticationClient {
    static func test(
        restoreSession: @escaping @Sendable () async throws ->
            AuthenticationSession? = { nil },
        signInWithApple: @escaping @MainActor @Sendable () async throws ->
            AuthenticationSession = {
                throw AuthenticationClientFailure.operationFailed
            },
        bootstrapProfile: @escaping @Sendable (String?) async throws ->
            AuthenticatedProfile = { _ in
                throw AuthenticationClientFailure.operationFailed
            },
        updateProfile: @escaping @Sendable (String) async throws ->
            AuthenticatedProfile = { _ in
                throw AuthenticationClientFailure.operationFailed
            },
        deleteAccount: @escaping @MainActor @Sendable () async throws ->
            Void = {
                throw AuthenticationClientFailure.operationFailed
            },
        events: @escaping @Sendable () -> AsyncStream<AuthenticationEvent> = {
            AsyncStream { $0.finish() }
        },
        signOut: @escaping @Sendable () async throws -> Void = {}
    ) -> Self {
        Self(
            restoreSession: restoreSession,
            signInWithApple: signInWithApple,
            bootstrapProfile: bootstrapProfile,
            updateProfile: updateProfile,
            deleteAccount: deleteAccount,
            events: events,
            signOut: signOut
        )
    }
}

private extension AppleAuthorizationClient {
    static let testUnavailable = Self { _ in
        throw AuthenticationClientFailure.operationFailed
    }
}

private extension CompetitionClient {
    static func test(
        stop: @escaping @Sendable () async -> Void,
        prepareForProfileTeardown: @escaping @Sendable (
            Bool
        ) async throws -> Void = { _ in }
    ) -> Self {
        let publication = CompetitionPublication(
            publicationRevision: 0,
            dashboard: CompetitionDashboard(
                competitions: [],
                awards: [],
                issues: [],
                hiddenTerminalCompetitionCount: 0
            )
        )
        return Self(
            start: { AsyncStream { $0.finish() } },
            updates: { AsyncStream { $0.finish() } },
            reconcileAll: { _ in publication },
            accept: { _ in publication },
            decline: { _ in publication },
            archive: { _ in publication },
            rematch: { _ in publication },
            reinvite: { publication },
            waitUntil: { _ in },
            stop: stop,
            prepareForProfileTeardown: prepareForProfileTeardown
        )
    }
}
