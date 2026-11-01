import ComposableArchitecture
import CompetitionCore

@Reducer
struct MainTabFeature {
    struct PendingClaimNavigation: Equatable, Sendable {
        let competitionID: CompetitionID
        let expectedPublicationRevision: UInt64
    }

    enum InviteClaimStatus: Equatable, Sendable {
        case idle
        case ready
        case claiming
        case waitingForCompetition
        case confirmationTimedOut
        case unavailable
        /// You opened your own challenge's link.
        case ownChallenge
        case retryable
        /// The link arrived before this account existed, so it can't be for it.
        case wrongAccount
    }

    enum InviteClaimResponse: Equatable, Sendable {
        case success(CompetitionID, expectedRevision: UInt64)
        case failure(CompetitionRemoteFailure)
    }

    struct PermissionOnboarding: Equatable, Sendable {
        var steps: [PermissionOnboardingStep]
        var index = 0
        var isRequesting = false

        var step: PermissionOnboardingStep { steps[index] }
    }

    /// The one-time notifications prompt, shown once a match with a person
    /// exists.
    enum NotificationPromptPhase: Equatable, Sendable {
        case unscheduled
        case scheduled
        case presented
        case finished
    }

    @ObservableState
    struct State: Equatable {
        var competition: CompetitionFeature.State
        var path: [CompetitionID]
        var pendingRoute: CompetitionRouteEnvelope?
        var pendingClaimRoute: CompetitionRouteEnvelope?
        var lastHandledRouteSequence: UInt64
        var lastHandledClaimRouteSequence: UInt64
        var claimRouteSequenceInFlight: UInt64?
        var pendingClaimNavigation: PendingClaimNavigation?
        var inviteClaimStatus: InviteClaimStatus
        /// Shown instead of Home; the competition starts once it finishes.
        var onboarding: PermissionOnboarding?
        var showsHistory: Bool
        var isAccountPresented: Bool
        /// A route to a match that isn't loaded yet: it refreshed once and
        /// waits for the match, without moving the current screens.
        var heldRouteSequence: UInt64?
        /// Accept was tapped before the competition started; the claim is
        /// sent on its first publication.
        var acceptsClaimOnStart = false
        var healthAccess: HealthAccessStatus?
        var notificationPrompt: NotificationPromptPhase = .unscheduled
        /// Mirrors MainTabView's Challenge sheet.
        var isChallengeSheetOpen = false
        /// Claim links up to this sequence arrived before this account
        /// existed, so they can't be for it.
        var claimLinksBeforeAccountThrough: UInt64 = 0

        init(
            competition: CompetitionFeature.State = CompetitionFeature.State(),
            path: [CompetitionID] = [],
            pendingRoute: CompetitionRouteEnvelope? = nil,
            pendingClaimRoute: CompetitionRouteEnvelope? = nil,
            lastHandledRouteSequence: UInt64 = 0,
            lastHandledClaimRouteSequence: UInt64 = 0,
            claimRouteSequenceInFlight: UInt64? = nil,
            pendingClaimNavigation: PendingClaimNavigation? = nil,
            inviteClaimStatus: InviteClaimStatus = .idle,
            onboarding: PermissionOnboarding? = nil,
            showsHistory: Bool = false,
            isAccountPresented: Bool = false,
            heldRouteSequence: UInt64? = nil
        ) {
            self.competition = competition
            self.path = path
            self.pendingRoute = pendingRoute
            self.pendingClaimRoute = pendingClaimRoute
            self.lastHandledRouteSequence = lastHandledRouteSequence
            self.lastHandledClaimRouteSequence = lastHandledClaimRouteSequence
            self.claimRouteSequenceInFlight = claimRouteSequenceInFlight
            self.pendingClaimNavigation = pendingClaimNavigation
            self.inviteClaimStatus = inviteClaimStatus
            self.onboarding = onboarding
            self.showsHistory = showsHistory
            self.isAccountPresented = isAccountPresented
            self.heldRouteSequence = heldRouteSequence
        }
    }

    enum SceneState: Equatable, Sendable {
        case active
        case inactive
        case background
    }

    enum Action: Equatable, Sendable {
        case task
        case scenePhaseChanged(SceneState)
        case timeZoneChanged
        case stop
        case routeReceived(CompetitionRouteEnvelope)
        case processPendingClaim
        case claimInviteResponse(
            sequence: UInt64,
            InviteClaimResponse
        )
        case claimConfirmationTimedOut(PendingClaimNavigation)
        case acceptClaimTapped
        case declineClaimTapped
        case retryClaimTapped
        case dismissRetryableClaim
        case dismissClaimStatus
        case pathChanged([CompetitionID])
        case historyPresentationChanged(Bool)
        case accountPresentationChanged(Bool)
        case pendingRouteTimedOut(UInt64)
        case onboardingChecked([PermissionOnboardingStep])
        case onboardingContinueTapped
        case onboardingStepCompleted
        case refreshHealthAccess
        case healthAccessLoaded(HealthAccessStatus)
        case connectHealthTapped
        case challengeSheetVisibilityChanged(Bool)
        case notificationPromptReady
        case notificationPromptSkipped
        case notificationPromptTurnOnTapped
        case notificationPromptNotNowTapped
        case competition(CompetitionFeature.Action)
    }

    @Dependency(\.competitionRoutingClient) var competitionRoutingClient
    @Dependency(\.competitionClient) var competitionClient
    @Dependency(\.continuousClock) var continuousClock
    @Dependency(\.permissionOnboardingClient) var permissionOnboardingClient

    private enum CancelID {
        case routes
        case inviteClaim
        case claimConfirmationTimeout
        case routeHold
        case notificationPrompt
    }

    private static let claimConfirmationTimeout: Duration = .seconds(15)
    private static let routeHoldTimeout: Duration = .seconds(15)
    /// Lets the claim sheet finish dismissing; SwiftUI drops a sheet
    /// presented mid-dismissal.
    private static let notificationPromptDelay: Duration = .milliseconds(600)

    var body: some ReducerOf<Self> {
        Scope(state: \.competition, action: \.competition) {
            CompetitionFeature()
        }
        Reduce { state, action in
            switch action {
            case .task:
                // The competition starts after onboarding: starting it asks
                // iOS for Health access, which the Health screen explains.
                return .merge(
                    state.onboarding == nil
                        ? .run { send in
                            await send(
                                .onboardingChecked(
                                    PermissionOnboardingClient.steps(
                                        health: await permissionOnboardingClient
                                            .healthAccess()
                                    )
                                )
                            )
                        }
                        : .none,
                    .run { send in
                        for await envelope in competitionRoutingClient.routes() {
                            guard !Task.isCancelled else { return }
                            await send(.routeReceived(envelope))
                        }
                    }
                    .cancellable(id: CancelID.routes, cancelInFlight: true)
                )

            // iOS permission prompts make the scene inactive and active
            // again before the competition has started.
            case .scenePhaseChanged(.active):
                guard state.onboarding == nil else { return .none }
                // Coming back from Settings updates Account → Health.
                return .merge(
                    .send(.competition(.sceneBecameActive)),
                    state.healthAccess == nil
                        ? .none
                        : .send(.refreshHealthAccess)
                )

            case .scenePhaseChanged(.inactive),
                 .scenePhaseChanged(.background):
                return .none

            case .timeZoneChanged:
                guard state.onboarding == nil else { return .none }
                return .send(.competition(.timeZoneChanged))

            case let .onboardingChecked(steps):
                guard !steps.isEmpty else {
                    return .send(.competition(.task))
                }
                state.onboarding = PermissionOnboarding(steps: steps)
                // A challenge link shows its challenge before Health.
                if state.pendingClaimRoute != nil,
                   state.claimRouteSequenceInFlight == nil,
                   state.inviteClaimStatus == .idle {
                    state.inviteClaimStatus = .ready
                }
                return .none

            case .onboardingContinueTapped:
                guard let onboarding = state.onboarding,
                      !onboarding.isRequesting
                else {
                    return .none
                }
                state.onboarding?.isRequesting = true
                let step = onboarding.step
                return .run { send in
                    switch step {
                    case .health:
                        await permissionOnboardingClient.requestHealthAccess()
                    case .notifications:
                        // Notifications are asked in context, never here.
                        break
                    }
                    await send(.onboardingStepCompleted)
                }

            case .onboardingStepCompleted:
                guard var onboarding = state.onboarding else { return .none }
                onboarding.index += 1
                onboarding.isRequesting = false
                guard onboarding.index < onboarding.steps.count else {
                    state.onboarding = nil
                    return .send(.competition(.task))
                }
                state.onboarding = onboarding
                return .none

            case .stop:
                state.claimRouteSequenceInFlight = nil
                state.pendingClaimNavigation = nil
                state.inviteClaimStatus = .idle
                state.heldRouteSequence = nil
                state.acceptsClaimOnStart = false
                state.isChallengeSheetOpen = false
                state.notificationPrompt = .unscheduled
                return .concatenate(
                    .merge(
                        .cancel(id: CancelID.routes),
                        .cancel(id: CancelID.inviteClaim),
                        .cancel(id: CancelID.claimConfirmationTimeout),
                        .cancel(id: CancelID.routeHold),
                        .cancel(id: CancelID.notificationPrompt)
                    ),
                    .send(.competition(.stop))
                )

            case let .routeReceived(envelope):
                if case .claimInvite = envelope.route {
                    guard envelope.sequence
                        > state.lastHandledClaimRouteSequence
                    else {
                        return .none
                    }
                    // Decided on the device from the order of events; no
                    // claim request, so nothing about the link is revealed.
                    if envelope.sequence <= state.claimLinksBeforeAccountThrough,
                       state.claimRouteSequenceInFlight == nil {
                        state.lastHandledClaimRouteSequence = envelope.sequence
                        if let pending = state.pendingClaimRoute,
                           pending.sequence <= envelope.sequence {
                            state.pendingClaimRoute = nil
                        }
                        state.inviteClaimStatus = .wrongAccount
                        return .run { _ in
                            competitionRoutingClient.consume(envelope.sequence)
                        }
                    }
                    if envelope.sequence
                        >= (state.pendingClaimRoute?.sequence ?? 0) {
                        // Accept always applies to the link on screen.
                        if state.pendingClaimRoute != envelope {
                            state.acceptsClaimOnStart = false
                        }
                        state.pendingClaimRoute = envelope
                    }
                    if state.competition.publication != nil
                        || state.onboarding != nil,
                       state.claimRouteSequenceInFlight == nil {
                        state.inviteClaimStatus = .ready
                    }
                    return .none
                }
                guard envelope.sequence > state.lastHandledRouteSequence
                else {
                    return .none
                }
                guard state.competition.publication != nil else {
                    if envelope.sequence
                        >= (state.pendingRoute?.sequence ?? 0) {
                        state.pendingRoute = envelope
                    }
                    return .none
                }
                return resolve(envelope, state: &state)

            case let .pathChanged(path):
                let visible = visibleCompetitionIDs(in: state)
                state.path = path.filter(visible.contains)
                return .none

            case let .historyPresentationChanged(isPresented):
                state.showsHistory = isPresented
                return .none

            case let .accountPresentationChanged(isPresented):
                state.isAccountPresented = isPresented
                // Account covers Home, so the notifications prompt waits.
                return notificationPromptBlockerChanged(
                    isOpen: isPresented, state: &state
                )

            case let .pendingRouteTimedOut(sequence):
                guard state.pendingRoute?.sequence == sequence else {
                    return .none
                }
                state.pendingRoute = nil
                state.heldRouteSequence = nil
                state.lastHandledRouteSequence = max(
                    state.lastHandledRouteSequence,
                    sequence
                )
                return .run { _ in
                    competitionRoutingClient.consume(sequence)
                }

            case .processPendingClaim:
                guard state.competition.publication != nil,
                      state.claimRouteSequenceInFlight == nil,
                      let envelope = state.pendingClaimRoute,
                      envelope.sequence > state.lastHandledClaimRouteSequence,
                      case let .claimInvite(token) = envelope.route
                else {
                    return .none
                }
                state.claimRouteSequenceInFlight = envelope.sequence
                state.inviteClaimStatus = .claiming
                return .run { send in
                    do {
                        let request = try CompetitionInviteClaimRequest(
                            token: token.rawValue
                        )
                        let outcome = try await competitionClient.claimInvite(
                            request
                        )
                        await send(
                            .claimInviteResponse(
                                sequence: envelope.sequence,
                                .success(
                                    CompetitionID(outcome.claim.competitionID),
                                    expectedRevision: outcome
                                        .expectedPublicationRevision
                                )
                            )
                        )
                    } catch let failure as CompetitionRemoteFailure {
                        await send(
                            .claimInviteResponse(
                                sequence: envelope.sequence,
                                .failure(failure)
                            )
                        )
                    } catch is CancellationError {
                        return
                    } catch {
                        await send(
                            .claimInviteResponse(
                                sequence: envelope.sequence,
                                .failure(.operationFailed)
                            )
                        )
                    }
                }
                .cancellable(id: CancelID.inviteClaim, cancelInFlight: false)

            case .acceptClaimTapped:
                guard state.inviteClaimStatus == .ready else {
                    return .none
                }
                // Claiming needs the started competition, which starts after
                // Health.
                if state.competition.publication == nil {
                    state.acceptsClaimOnStart = true
                    state.inviteClaimStatus = .idle
                    return .none
                }
                return .send(.processPendingClaim)

            case .declineClaimTapped:
                guard state.inviteClaimStatus == .ready
                    || state.inviteClaimStatus == .retryable,
                      let sequence = state.pendingClaimRoute?.sequence
                else {
                    return .none
                }
                state.pendingClaimRoute = nil
                state.lastHandledClaimRouteSequence = max(
                    state.lastHandledClaimRouteSequence,
                    sequence
                )
                state.inviteClaimStatus = .idle
                return .run { _ in
                    competitionRoutingClient.consume(sequence)
                }

            case let .claimInviteResponse(sequence, response):
                guard state.claimRouteSequenceInFlight == sequence else {
                    return .none
                }
                state.claimRouteSequenceInFlight = nil
                switch response {
                case let .success(id, expectedRevision):
                    if state.pendingClaimRoute?.sequence == sequence {
                        state.pendingClaimRoute = nil
                    }
                    state.lastHandledClaimRouteSequence = max(
                        state.lastHandledClaimRouteSequence,
                        sequence
                    )
                    let pendingNavigation = PendingClaimNavigation(
                        competitionID: id,
                        expectedPublicationRevision: expectedRevision
                    )
                    state.pendingClaimNavigation = pendingNavigation
                    state.inviteClaimStatus = .waitingForCompetition
                    resolveClaimedNavigation(state: &state)
                    let postClaim = postClaimEffects(
                        consumedSequence: sequence,
                        hasNewerPendingClaim: state.pendingClaimRoute != nil
                    )
                    let prompt = scheduleNotificationPromptIfDue(state: &state)
                    guard state.pendingClaimNavigation != nil else {
                        return .merge(
                            postClaim,
                            .cancel(id: CancelID.claimConfirmationTimeout),
                            prompt
                        )
                    }
                    return .merge(
                        postClaim,
                        claimConfirmationTimeoutEffect(pendingNavigation),
                        prompt
                    )

                case .failure(.inviteUnavailable), .failure(.forbidden):
                    if state.pendingClaimRoute?.sequence == sequence {
                        state.pendingClaimRoute = nil
                    }
                    state.lastHandledClaimRouteSequence = max(
                        state.lastHandledClaimRouteSequence,
                        sequence
                    )
                    state.inviteClaimStatus = response == .failure(.forbidden)
                        ? .ownChallenge
                        : .unavailable
                    return postClaimEffects(
                        consumedSequence: sequence,
                        hasNewerPendingClaim: state.pendingClaimRoute != nil
                    )

                case .failure:
                    state.inviteClaimStatus = .retryable
                    return .none
                }

            case let .claimConfirmationTimedOut(pendingNavigation):
                guard state.pendingClaimNavigation == pendingNavigation,
                      state.inviteClaimStatus == .waitingForCompetition
                else {
                    return .none
                }
                state.inviteClaimStatus = .confirmationTimedOut
                return .none

            case .retryClaimTapped:
                switch state.inviteClaimStatus {
                case .retryable:
                    return .send(.processPendingClaim)
                case .confirmationTimedOut:
                    guard let pendingNavigation = state
                        .pendingClaimNavigation
                    else {
                        state.inviteClaimStatus = .idle
                        return .none
                    }
                    state.inviteClaimStatus = .waitingForCompetition
                    return .merge(
                        .send(.competition(.pullToRefresh)),
                        claimConfirmationTimeoutEffect(pendingNavigation)
                    )
                case .idle, .ready, .claiming, .waitingForCompetition,
                     .unavailable, .wrongAccount, .ownChallenge:
                    return .none
                }

            case .dismissRetryableClaim:
                guard state.inviteClaimStatus == .retryable else {
                    return .none
                }
                // A sheet swipe means "not now," not an explicit rejection.
                // Keep the private route for a later canonical publication;
                // Decline Invitation is the action that consumes it.
                state.inviteClaimStatus = .idle
                return .none

            case .dismissClaimStatus:
                switch state.inviteClaimStatus {
                case .unavailable, .wrongAccount, .ownChallenge:
                    state.inviteClaimStatus = .idle
                    return .none
                case .confirmationTimedOut:
                    state.pendingClaimNavigation = nil
                    state.inviteClaimStatus = .idle
                    return .cancel(id: CancelID.claimConfirmationTimeout)
                case .idle, .ready, .claiming, .waitingForCompetition,
                     .retryable:
                    return .none
                }

            case .competition(.publication):
                let visible = visibleCompetitionIDs(in: state)
                state.path = state.path.filter(visible.contains)
                let hadPendingClaimNavigation = state
                    .pendingClaimNavigation != nil
                resolveClaimedNavigation(state: &state)
                var effects: [Effect<Action>] = []
                if hadPendingClaimNavigation,
                   state.pendingClaimNavigation == nil {
                    effects.append(
                        .cancel(id: CancelID.claimConfirmationTimeout)
                    )
                }
                if let pending = state.pendingRoute {
                    effects.append(resolve(pending, state: &state))
                }
                let acceptedBeforeStart = state.acceptsClaimOnStart
                state.acceptsClaimOnStart = false
                if acceptedBeforeStart,
                   state.pendingClaimRoute != nil,
                   state.claimRouteSequenceInFlight == nil {
                    // The claim sheet is about to show; the publication that
                    // resolves the claim schedules the prompt.
                    effects.append(.send(.processPendingClaim))
                    return .merge(effects)
                }
                if state.pendingClaimRoute != nil,
                   state.claimRouteSequenceInFlight == nil,
                   state.inviteClaimStatus == .idle {
                    state.inviteClaimStatus = .ready
                }
                effects.append(scheduleNotificationPromptIfDue(state: &state))
                return .merge(effects)

            case .competition(.notificationAuthorizationLoaded):
                return scheduleNotificationPromptIfDue(state: &state)

            case .competition(.notificationAuthorizationRequestFinished):
                if state.notificationPrompt == .presented {
                    state.notificationPrompt = .finished
                }
                return .none

            case .refreshHealthAccess:
                return .run { send in
                    await send(
                        .healthAccessLoaded(
                            await permissionOnboardingClient.healthAccess()
                        )
                    )
                }

            case let .healthAccessLoaded(access):
                state.healthAccess = access
                return .none

            case .connectHealthTapped:
                return .run { send in
                    await permissionOnboardingClient.requestHealthAccess()
                    await send(
                        .healthAccessLoaded(
                            await permissionOnboardingClient.healthAccess()
                        )
                    )
                }

            case let .challengeSheetVisibilityChanged(isOpen):
                state.isChallengeSheetOpen = isOpen
                return notificationPromptBlockerChanged(isOpen: isOpen, state: &state)

            case .notificationPromptReady:
                guard state.notificationPrompt == .scheduled else {
                    return .none
                }
                guard state.inviteClaimStatus == .idle,
                      !state.isChallengeSheetOpen,
                      !state.isAccountPresented,
                      state.onboarding == nil,
                      state.competition.notificationAuthorizationState
                        == .notDetermined
                else {
                    // The next publication tries again.
                    state.notificationPrompt = .unscheduled
                    return .none
                }
                state.notificationPrompt = .presented
                return .none

            case .notificationPromptSkipped:
                state.notificationPrompt = .finished
                return .none

            case .notificationPromptTurnOnTapped:
                guard state.notificationPrompt == .presented else {
                    return .none
                }
                return .send(.competition(.enableNotificationsTapped))

            case .notificationPromptNotNowTapped:
                guard state.notificationPrompt == .presented else {
                    return .none
                }
                state.notificationPrompt = .finished
                return .run { _ in
                    await permissionOnboardingClient.deferNotifications()
                }

            case .competition:
                return .none
            }
        }
    }

    /// Schedules the notifications prompt once a match with a person exists.
    private func scheduleNotificationPromptIfDue(
        state: inout State
    ) -> Effect<Action> {
        guard state.notificationPrompt == .unscheduled,
              state.onboarding == nil,
              state.inviteClaimStatus == .idle,
              !state.isChallengeSheetOpen,
              !state.isAccountPresented,
              state.competition.notificationAuthorizationState == .notDetermined,
              state.competition.publication?.dashboard.competitions.contains(
                  where: { Self.hasPerson($0.lifecycle) }
              ) == true
        else {
            return .none
        }
        state.notificationPrompt = .scheduled
        return .run { send in
            try await continuousClock.sleep(for: Self.notificationPromptDelay)
            await send(
                await permissionOnboardingClient.notificationsDeferred()
                    ? .notificationPromptSkipped
                    : .notificationPromptReady
            )
        }
        .cancellable(id: CancelID.notificationPrompt, cancelInFlight: true)
    }

    /// Another sheet opening while the prompt is `.presented` means SwiftUI
    /// dropped the prompt (a showing prompt covers the controls that open
    /// them), so it goes back to unscheduled and retries when they close.
    private func notificationPromptBlockerChanged(
        isOpen: Bool,
        state: inout State
    ) -> Effect<Action> {
        if isOpen {
            if state.notificationPrompt == .presented {
                state.notificationPrompt = .unscheduled
            }
            return .none
        }
        return scheduleNotificationPromptIfDue(state: &state)
    }

    /// A pending challenge (either direction) or a match that hasn't
    /// finished. Expired and declined challenges don't count.
    private static func hasPerson(
        _ lifecycle: LocalCompetitionLifecyclePresentation
    ) -> Bool {
        switch lifecycle {
        case .pending, .scheduled, .active, .endsToday, .tallying:
            true
        case .declined, .expired, .completed, .archived:
            false
        }
    }

    private func resolve(
        _ envelope: CompetitionRouteEnvelope,
        state: inout State
    ) -> Effect<Action> {
        guard envelope.sequence > state.lastHandledRouteSequence else {
            state.pendingRoute = nil
            return .none
        }
        switch envelope.route {
        case let .competition(id):
            guard visibleCompetitionIDs(in: state).contains(id) else {
                // Keep the stack as it is; refresh and time out once per route.
                state.pendingRoute = envelope
                guard state.heldRouteSequence != envelope.sequence else {
                    return .none
                }
                state.heldRouteSequence = envelope.sequence
                return .merge(
                    .send(.competition(.pullToRefresh)),
                    .run { send in
                        try await continuousClock.sleep(for: Self.routeHoldTimeout)
                        await send(.pendingRouteTimedOut(envelope.sequence))
                    }
                    .cancellable(id: CancelID.routeHold, cancelInFlight: true)
                )
            }
            state.pendingRoute = nil
            state.heldRouteSequence = nil
            state.lastHandledRouteSequence = envelope.sequence
            state.showsHistory = false
            let closesAccount = state.isAccountPresented
            state.isAccountPresented = false
            state.path = [id]
            return .merge(
                .cancel(id: CancelID.routeHold),
                .run { _ in
                    competitionRoutingClient.consume(envelope.sequence)
                },
                closesAccount
                    ? notificationPromptBlockerChanged(isOpen: false, state: &state)
                    : .none
            )
        case .claimInvite:
            // Claim routes remain pending in the process-rooted hub until the
            // authenticated claim flow explicitly accepts or rejects them.
            state.pendingRoute = nil
            state.lastHandledRouteSequence = envelope.sequence
            return .none
        }
    }

    private func visibleCompetitionIDs(in state: State) -> Set<CompetitionID> {
        Set(
            state.competition.publication?.dashboard.competitions.map(\.id)
                ?? []
        )
    }

    private func resolveClaimedNavigation(state: inout State) {
        guard let pending = state.pendingClaimNavigation,
              let publication = state.competition.publication,
              publication.publicationRevision
                >= pending.expectedPublicationRevision,
              visibleCompetitionIDs(in: state).contains(pending.competitionID)
        else {
            return
        }
        state.path = [pending.competitionID]
        state.pendingClaimNavigation = nil
        state.inviteClaimStatus = .idle
    }

    private func postClaimEffects(
        consumedSequence: UInt64,
        hasNewerPendingClaim: Bool
    ) -> Effect<Action> {
        .merge(
            .run { _ in
                competitionRoutingClient.consume(consumedSequence)
            },
            hasNewerPendingClaim ? .send(.processPendingClaim) : .none
        )
    }

    private func claimConfirmationTimeoutEffect(
        _ pendingNavigation: PendingClaimNavigation
    ) -> Effect<Action> {
        .run { send in
            try await continuousClock.sleep(
                for: Self.claimConfirmationTimeout
            )
            await send(.claimConfirmationTimedOut(pendingNavigation))
        }
        .cancellable(
            id: CancelID.claimConfirmationTimeout,
            cancelInFlight: true
        )
    }
}
