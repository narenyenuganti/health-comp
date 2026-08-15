import ComposableArchitecture
import Foundation

@Reducer
struct AppFeature {
    @ObservableState
    struct State: Equatable {
        enum Phase: Equatable, Sendable {
            case launching
            case signedOut
            case bootstrappingProfile
            case settingUpProfile
            case authenticated
            case launchFailure
        }

        var phase: Phase
        var account: AccountFeature.State
        var mainTab: MainTabFeature.State?
        var profile: AuthenticatedProfile?
        var profileStoragePaths: AuthenticatedProfileStoragePaths?
        var authEpoch: UInt64
        var isAuthenticationMonitoring: Bool

        init(
            phase: Phase = .launching,
            account: AccountFeature.State = AccountFeature.State(
                mode: .signedOut
            ),
            mainTab: MainTabFeature.State? = nil,
            profile: AuthenticatedProfile? = nil,
            profileStoragePaths: AuthenticatedProfileStoragePaths? = nil,
            authEpoch: UInt64 = 0,
            isAuthenticationMonitoring: Bool = false
        ) {
            self.phase = phase
            self.account = account
            self.mainTab = mainTab
            self.profile = profile
            self.profileStoragePaths = profileStoragePaths
            self.authEpoch = authEpoch
            self.isAuthenticationMonitoring = isAuthenticationMonitoring
        }

        static func signedOut(epoch: UInt64) -> Self {
            Self(
                phase: .signedOut,
                account: AccountFeature.State(mode: .signedOut),
                authEpoch: epoch
            )
        }

        static func authenticated(
            profile: AuthenticatedProfile,
            epoch: UInt64
        ) -> Self {
            Self(
                phase: .authenticated,
                account: AccountFeature.State(
                    mode: .authenticated,
                    displayName: profile.displayName
                ),
                mainTab: MainTabFeature.State(),
                profile: profile,
                authEpoch: epoch
            )
        }
    }

    enum SessionResponse: Equatable, Sendable {
        case success(AuthenticationSession?)
        case failure(AuthenticationClientFailure)
    }

    enum SignInResponse: Equatable, Sendable {
        case success(AuthenticationSession)
        case failure(AuthenticationClientFailure)
    }

    enum ProfileResponse: Equatable, Sendable {
        case success(AuthenticatedProfile)
        case failure(AuthenticationClientFailure)
    }

    enum ProfileStorageResponse: Equatable, Sendable {
        case success(AuthenticatedProfileStoragePaths)
        case failure(AuthenticatedProfileStorageFailure)
    }

    enum TeardownReason: Equatable, Sendable {
        case userRequested
        case sessionEnded
        case accountDeleted
    }

    enum Action: Equatable, Sendable {
        case task
        case stop
        case restoreSessionResponse(epoch: UInt64, SessionResponse)
        case signInResponse(epoch: UInt64, SignInResponse)
        case bootstrapProfileResponse(epoch: UInt64, ProfileResponse)
        case updateProfileResponse(epoch: UInt64, ProfileResponse)
        case profileStorageResponse(
            epoch: UInt64,
            profile: AuthenticatedProfile,
            ProfileStorageResponse
        )
        case authenticationEvent(AuthenticationEvent)
        case teardownCompleted(epoch: UInt64, reason: TeardownReason)
        case teardownFailed(
            epoch: UInt64,
            reason: TeardownReason,
            failure: AuthenticatedProfileStorageFailure
        )
        case account(AccountFeature.Action)
        case mainTab(MainTabFeature.Action)
    }

    @Dependency(\.authenticationClient) private var authenticationClient
    @Dependency(\.authenticatedProfileStorage)
    private var authenticatedProfileStorage
    @Dependency(\.competitionClient) private var competitionClient

    private enum CancelID {
        case authenticationEvents
        case authenticationOperation
        case teardown
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.account, action: \.account) {
            AccountFeature()
        }
        Reduce { state, action in
            switch action {
            case .task:
                guard !state.isAuthenticationMonitoring else { return .none }
                state.isAuthenticationMonitoring = true
                state.authEpoch &+= 1
                state.phase = .launching
                let epoch = state.authEpoch
                return .merge(
                    restoreSession(epoch: epoch),
                    authenticationEvents()
                )

            case .stop:
                state.isAuthenticationMonitoring = false
                let shouldStopRuntime = state.profile != nil
                    || state.mainTab != nil
                return .merge(
                    .cancel(id: CancelID.authenticationEvents),
                    .cancel(id: CancelID.authenticationOperation),
                    .cancel(id: CancelID.teardown),
                    shouldStopRuntime
                        ? .run { _ in await competitionClient.stop() }
                        : .none
                )

            case let .restoreSessionResponse(epoch, response):
                guard epoch == state.authEpoch else { return .none }
                switch response {
                case .success(nil):
                    becomeSignedOut(state: &state, message: nil)
                    return .none

                case .success(.some):
                    state.phase = .bootstrappingProfile
                    state.account.isRequestInFlight = false
                    state.account.message = nil
                    return bootstrapProfile(nil, epoch: epoch)

                case let .failure(failure):
                    return handleLaunchFailure(failure, state: &state)
                }

            case let .signInResponse(epoch, response):
                guard epoch == state.authEpoch else { return .none }
                switch response {
                case .success:
                    state.phase = .bootstrappingProfile
                    state.account.isRequestInFlight = false
                    state.account.message = nil
                    return bootstrapProfile(nil, epoch: epoch)

                case let .failure(failure):
                    becomeSignedOut(
                        state: &state,
                        message: accountMessage(for: failure)
                    )
                    return .none
                }

            case let .bootstrapProfileResponse(epoch, response):
                guard epoch == state.authEpoch else { return .none }
                switch response {
                case let .success(profile):
                    state.profile = profile
                    state.profileStoragePaths = nil
                    return mountProfileStorage(profile, epoch: epoch)

                case .failure(.displayNameRequired):
                    state.phase = .settingUpProfile
                    state.profile = nil
                    state.profileStoragePaths = nil
                    state.mainTab = nil
                    state.account = AccountFeature.State(
                        mode: .settingUpProfile
                    )
                    return .none

                case .failure(.invalidDisplayName):
                    state.phase = .settingUpProfile
                    state.account.isRequestInFlight = false
                    state.account.message = .invalidDisplayName
                    return .none

                case let .failure(failure):
                    return handleLaunchFailure(failure, state: &state)
                }

            case let .authenticationEvent(event):
                switch event {
                case .sessionRefreshed:
                    return .none

                case .signedOut:
                    // A user-requested global sign-out emits this event before
                    // its best-effort SDK operation returns. The in-flight
                    // teardown already owns the ordered transition.
                    guard state.phase != .signedOut else { return .none }
                    guard !(
                        state.phase == .authenticated
                            && state.account.isRequestInFlight
                    ) else {
                        return .none
                    }
                    state.authEpoch &+= 1
                    state.account.isRequestInFlight = true
                    return teardown(
                        epoch: state.authEpoch,
                        reason: .sessionEnded,
                        stopRuntime: state.profile != nil
                            || state.mainTab != nil,
                        profileID: state.profile?.id
                    )

                case .accountDeleted:
                    state.authEpoch &+= 1
                    state.account.isRequestInFlight = true
                    return teardown(
                        epoch: state.authEpoch,
                        reason: .accountDeleted,
                        stopRuntime: state.profile != nil
                            || state.mainTab != nil,
                        profileID: state.profile?.id
                    )
                }

            case let .profileStorageResponse(epoch, profile, response):
                guard epoch == state.authEpoch,
                      state.profile == profile
                else {
                    return .none
                }
                switch response {
                case let .success(paths) where paths.profileID == profile.id:
                    state.phase = .authenticated
                    state.profileStoragePaths = paths
                    state.account = AccountFeature.State(
                        mode: .authenticated,
                        displayName: profile.displayName
                    )
                    state.mainTab = MainTabFeature.State()
                case .success, .failure:
                    becomeLaunchFailure(state: &state)
                }
                return .none

            case let .teardownCompleted(epoch, reason):
                guard epoch == state.authEpoch else { return .none }
                becomeSignedOut(
                    state: &state,
                    message: reason == .userRequested ? nil : .sessionEnded
                )
                return .none

            case let .teardownFailed(epoch, _, _):
                guard epoch == state.authEpoch else { return .none }
                becomeLaunchFailure(state: &state)
                return .none

            case .account(.delegate(.signInWithAppleRequested)):
                guard state.phase == .signedOut else { return .none }
                state.authEpoch &+= 1
                return signInWithApple(epoch: state.authEpoch)

            case let .account(.delegate(.displayNameSubmitted(name))):
                guard state.phase == .settingUpProfile else { return .none }
                return bootstrapProfile(name, epoch: state.authEpoch)

            case let .account(.delegate(.displayNameUpdateRequested(name))):
                guard state.phase == .authenticated,
                      state.profile != nil
                else {
                    return .none
                }
                return updateProfile(name, epoch: state.authEpoch)

            case let .updateProfileResponse(epoch, response):
                guard epoch == state.authEpoch,
                      state.phase == .authenticated,
                      let currentProfile = state.profile
                else {
                    return .none
                }
                switch response {
                case let .success(profile) where profile.id == currentProfile.id:
                    state.profile = profile
                    return .merge(
                        .send(
                            .account(
                                .profileUpdateFinished(profile.displayName)
                            )
                        ),
                        .run { _ in
                            _ = await competitionClient.reconcileAll(
                                .pullToRefresh
                            )
                        }
                    )

                case .success:
                    state.account.isRequestInFlight = false
                    state.account.message = .tryAgain
                    return .none

                case let .failure(failure):
                    if failure == .terminalSession
                        || failure == .sessionExpired {
                        state.authEpoch &+= 1
                        return teardown(
                            epoch: state.authEpoch,
                            reason: .sessionEnded,
                            stopRuntime: state.profile != nil
                                || state.mainTab != nil,
                            profileID: currentProfile.id
                        )
                    }
                    state.account.isRequestInFlight = false
                    state.account.message = accountMessage(for: failure)
                    return .none
                }

            case .account(.delegate(.retryRequested)):
                guard state.phase == .launchFailure else { return .none }
                state.authEpoch &+= 1
                state.phase = .launching
                return restoreSession(epoch: state.authEpoch)

            case .account(.delegate(.signOutRequested)):
                guard state.phase == .authenticated else { return .none }
                state.authEpoch &+= 1
                return teardown(
                    epoch: state.authEpoch,
                    reason: .userRequested,
                    stopRuntime: state.mainTab != nil,
                    profileID: state.profile?.id
                )

            case .account, .mainTab:
                return .none
            }
        }
        .ifLet(\.mainTab, action: \.mainTab) {
            MainTabFeature()
        }
    }

    private func authenticationEvents() -> Effect<Action> {
        .run { send in
            for await event in authenticationClient.events() {
                guard !Task.isCancelled else { return }
                await send(.authenticationEvent(event))
            }
        }
        .cancellable(
            id: CancelID.authenticationEvents,
            cancelInFlight: true
        )
    }

    private func restoreSession(epoch: UInt64) -> Effect<Action> {
        .run { send in
            do {
                await send(
                    .restoreSessionResponse(
                        epoch: epoch,
                        .success(try await authenticationClient.restoreSession())
                    )
                )
            } catch {
                await send(
                    .restoreSessionResponse(
                        epoch: epoch,
                        .failure(authenticationFailure(from: error))
                    )
                )
            }
        }
        .cancellable(
            id: CancelID.authenticationOperation,
            cancelInFlight: true
        )
    }

    private func signInWithApple(epoch: UInt64) -> Effect<Action> {
        .run { send in
            do {
                await send(
                    .signInResponse(
                        epoch: epoch,
                        .success(
                            try await authenticationClient.signInWithApple()
                        )
                    )
                )
            } catch {
                await send(
                    .signInResponse(
                        epoch: epoch,
                        .failure(authenticationFailure(from: error))
                    )
                )
            }
        }
        .cancellable(
            id: CancelID.authenticationOperation,
            cancelInFlight: true
        )
    }

    private func bootstrapProfile(
        _ displayName: String?,
        epoch: UInt64
    ) -> Effect<Action> {
        .run { send in
            do {
                await send(
                    .bootstrapProfileResponse(
                        epoch: epoch,
                        .success(
                            try await authenticationClient.bootstrapProfile(
                                displayName
                            )
                        )
                    )
                )
            } catch {
                await send(
                    .bootstrapProfileResponse(
                        epoch: epoch,
                        .failure(authenticationFailure(from: error))
                    )
                )
            }
        }
        .cancellable(
            id: CancelID.authenticationOperation,
            cancelInFlight: true
        )
    }

    private func updateProfile(
        _ displayName: String,
        epoch: UInt64
    ) -> Effect<Action> {
        .run { send in
            do {
                await send(
                    .updateProfileResponse(
                        epoch: epoch,
                        .success(
                            try await authenticationClient.updateProfile(
                                displayName
                            )
                        )
                    )
                )
            } catch {
                await send(
                    .updateProfileResponse(
                        epoch: epoch,
                        .failure(authenticationFailure(from: error))
                    )
                )
            }
        }
        .cancellable(
            id: CancelID.authenticationOperation,
            cancelInFlight: true
        )
    }

    private func mountProfileStorage(
        _ profile: AuthenticatedProfile,
        epoch: UInt64
    ) -> Effect<Action> {
        .run { send in
            do {
                let paths = try await authenticatedProfileStorage.mount(
                    profile.id
                )
                do {
                    try await competitionClient.mountAuthenticatedProfile(
                        profile,
                        paths
                    )
                } catch let mountError {
                    await competitionClient.stop()
                    do {
                        try await authenticatedProfileStorage.teardown(
                            profile.id
                        )
                    } catch {
                        throw error as? AuthenticatedProfileStorageFailure
                            ?? .cleanupFailed
                    }
                    throw mountError
                }
                await send(
                    .profileStorageResponse(
                        epoch: epoch,
                        profile: profile,
                        .success(paths)
                    )
                )
            } catch {
                await send(
                    .profileStorageResponse(
                        epoch: epoch,
                        profile: profile,
                        .failure(
                            error as? AuthenticatedProfileStorageFailure
                                ?? .unsafeFilesystemEntry
                        )
                    )
                )
            }
        }
        .cancellable(
            id: CancelID.authenticationOperation,
            cancelInFlight: true
        )
    }

    private func teardown(
        epoch: UInt64,
        reason: TeardownReason,
        stopRuntime: Bool,
        profileID: UUID?
    ) -> Effect<Action> {
        .merge(
            .cancel(id: CancelID.authenticationOperation),
            .run { send in
                if stopRuntime {
                    do {
                        try await competitionClient
                            .prepareForProfileTeardown(
                                requireRemoteInstallationRemoval:
                                    reason == .userRequested
                            )
                    } catch {
                        await competitionClient.stop()
                        await send(
                            .teardownFailed(
                                epoch: epoch,
                                reason: reason,
                                failure: .cleanupFailed
                            )
                        )
                        return
                    }
                    await competitionClient.stop()
                }
                if let profileID {
                    do {
                        try await authenticatedProfileStorage.teardown(
                            profileID
                        )
                    } catch {
                        await send(
                            .teardownFailed(
                                epoch: epoch,
                                reason: reason,
                                failure: error as?
                                    AuthenticatedProfileStorageFailure
                                    ?? .cleanupFailed
                            )
                        )
                        return
                    }
                }
                if reason == .userRequested {
                    await authenticationClient.signOut()
                }
                await send(.teardownCompleted(epoch: epoch, reason: reason))
            }
            .cancellable(id: CancelID.teardown, cancelInFlight: true)
        )
    }

    private func handleLaunchFailure(
        _ failure: AuthenticationClientFailure,
        state: inout State
    ) -> Effect<Action> {
        switch failure {
        case .terminalSession, .sessionExpired:
            becomeSignedOut(state: &state, message: .sessionEnded)

        case .displayNameRequired:
            state.phase = .settingUpProfile
            state.profile = nil
            state.profileStoragePaths = nil
            state.mainTab = nil
            state.account = AccountFeature.State(mode: .settingUpProfile)

        case .invalidDisplayName:
            state.phase = .settingUpProfile
            state.profile = nil
            state.profileStoragePaths = nil
            state.mainTab = nil
            state.account = AccountFeature.State(mode: .settingUpProfile)
            state.account.message = .invalidDisplayName

        case .cancelled:
            becomeSignedOut(state: &state, message: nil)

        case .invalidCredential, .nonceMismatch, .nonceGenerationFailed,
             .refreshRetryable, .operationFailed:
            state.phase = .launchFailure
            state.profile = nil
            state.profileStoragePaths = nil
            state.mainTab = nil
            state.account = AccountFeature.State(mode: .launchFailure)
            state.account.message = accountMessage(for: failure)
        }
        return .none
    }

    private func becomeSignedOut(
        state: inout State,
        message: AccountFeature.Message?
    ) {
        state.phase = .signedOut
        state.profile = nil
        state.profileStoragePaths = nil
        state.mainTab = nil
        state.account = AccountFeature.State(mode: .signedOut)
        state.account.message = message
    }

    private func becomeLaunchFailure(state: inout State) {
        state.phase = .launchFailure
        state.profile = nil
        state.profileStoragePaths = nil
        state.mainTab = nil
        state.account = AccountFeature.State(mode: .launchFailure)
        state.account.message = .tryAgain
    }

    private func authenticationFailure(
        from error: any Error
    ) -> AuthenticationClientFailure {
        error as? AuthenticationClientFailure ?? .operationFailed
    }

    private func accountMessage(
        for failure: AuthenticationClientFailure
    ) -> AccountFeature.Message? {
        switch failure {
        case .cancelled:
            nil
        case .invalidCredential, .nonceMismatch:
            .invalidCredential
        case .terminalSession, .sessionExpired:
            .sessionEnded
        case .invalidDisplayName:
            .invalidDisplayName
        case .refreshRetryable, .nonceGenerationFailed,
             .displayNameRequired, .operationFailed:
            .tryAgain
        }
    }
}
