import ComposableArchitecture
import Foundation
import XCTest
@testable import HealthComp

final class AppFeatureTests: XCTestCase {
    private let session = AuthenticationSession(
        userID: UUID(uuidString: "93000000-0000-4000-8000-000000000001")!,
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
    )
    private let profile = AuthenticatedProfile(
        id: UUID(uuidString: "94000000-0000-4000-8000-000000000001")!,
        displayName: "Taylor"
    )

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
            }
            await store.receive(
                .teardownCompleted(epoch: 9, reason: .sessionEnded)
            ) {
                $0.phase = .signedOut
                $0.profile = nil
                $0.mainTab = nil
                $0.account = AccountFeature.State(mode: .signedOut)
                $0.account.message = .sessionEnded
            }

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
        }
        await store.receive(
            .teardownCompleted(epoch: 10, reason: .sessionEnded)
        ) {
            $0.phase = .signedOut
            $0.account = AccountFeature.State(mode: .signedOut)
            $0.account.message = .sessionEnded
        }
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
        }
        await store.receive(
            .teardownCompleted(epoch: 10, reason: .sessionEnded)
        ) {
            $0.phase = .signedOut
            $0.profile = nil
            $0.account = AccountFeature.State(mode: .signedOut)
            $0.account.message = .sessionEnded
        }
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
        }
        await store.receive(
            .teardownCompleted(epoch: 4, reason: .userRequested)
        ) {
            $0.phase = .signedOut
            $0.profile = nil
            $0.mainTab = nil
            $0.account = AccountFeature.State(mode: .signedOut)
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
    func testRequiredInstallationRemovalFailurePreservesProfileAndAuth()
        async
    {
        let calls = OrderedCallRecorder()
        let profile = profile
        let storage = profileStorageFixture(for: profile, recorder: calls)
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
                    throw CompetitionRemoteFailure.retryableTransport
                }
            )
        }

        await store.send(.account(.signOutButtonTapped)) {
            $0.account.isRequestInFlight = true
        }
        await store.receive(.account(.delegate(.signOutRequested))) {
            $0.authEpoch = 4
        }
        await store.receive(
            .teardownFailed(
                epoch: 4,
                reason: .userRequested,
                failure: .cleanupFailed
            )
        ) {
            $0.phase = .launchFailure
            $0.profile = nil
            $0.mainTab = nil
            $0.account = AccountFeature.State(mode: .launchFailure)
            $0.account.message = .tryAgain
        }
        XCTAssertEqual(
            calls.calls,
            ["installation-teardown:true", "runtime-stop"]
        )
    }

    @MainActor
    func testSignedOutAndDeletedEventsTearDownAuthenticatedMain() async {
        for (event, reason) in [
            (
                AuthenticationEvent.signedOut,
                AppFeature.TeardownReason.sessionEnded
            ),
            (.accountDeleted, .accountDeleted),
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
            }
            await store.receive(
                .teardownCompleted(epoch: 11, reason: reason)
            ) {
                $0.phase = .signedOut
                $0.profile = nil
                $0.mainTab = nil
                $0.account = AccountFeature.State(mode: .signedOut)
                $0.account.message = .sessionEnded
            }
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
    func testCleanupFailureStopsRuntimeButDoesNotClearAuthentication()
        async
    {
        let calls = OrderedCallRecorder()
        let profile = profile
        let store = TestStore(
            initialState: .authenticated(profile: profile, epoch: 3)
        ) {
            AppFeature()
        } withDependencies: {
            $0.authenticationClient = .test(
                signOut: { calls.record("auth-sign-out") }
            )
            $0.authenticatedProfileStorage = AuthenticatedProfileStorage(
                mount: { _ in
                    throw AuthenticatedProfileStorageFailure
                        .unsafeFilesystemEntry
                },
                teardown: { id in
                    calls.record("storage-teardown:\(id.uuidString)")
                    throw AuthenticatedProfileStorageFailure.cleanupFailed
                }
            )
            $0.competitionClient = .test(
                stop: { calls.record("runtime-stop") }
            )
        }

        await store.send(.account(.signOutButtonTapped)) {
            $0.account.isRequestInFlight = true
        }
        await store.receive(.account(.delegate(.signOutRequested))) {
            $0.authEpoch = 4
        }
        await store.receive(
            .teardownFailed(
                epoch: 4,
                reason: .userRequested,
                failure: .cleanupFailed
            )
        ) {
            $0.phase = .launchFailure
            $0.profile = nil
            $0.mainTab = nil
            $0.account = AccountFeature.State(mode: .launchFailure)
            $0.account.message = .tryAgain
        }
        XCTAssertEqual(
            calls.calls,
            [
                "runtime-stop",
                "storage-teardown:\(profile.id.uuidString)",
            ]
        )
    }
}

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
        events: @escaping @Sendable () -> AsyncStream<AuthenticationEvent> = {
            AsyncStream { $0.finish() }
        },
        signOut: @escaping @Sendable () async -> Void = {}
    ) -> Self {
        Self(
            restoreSession: restoreSession,
            signInWithApple: signInWithApple,
            bootstrapProfile: bootstrapProfile,
            updateProfile: updateProfile,
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
