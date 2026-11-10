import ComposableArchitecture
import Foundation
import CompetitionCore

@Reducer
struct MainTabFeature {
    struct PendingClaimNavigation: Equatable, Sendable {
        let competitionID: CompetitionID
        let expectedPublicationRevision: UInt64
    }

    enum InviteClaimStatus: Equatable, Sendable {
        case idle
        /// Asking the server who sent it.
        case loadingPreview
        case ready
        /// The server is recording a decline.
        case declining
        case claiming
        case waitingForCompetition
        case confirmationTimedOut
        case unavailable
        /// You opened your own challenge's link.
        case ownChallenge
        /// You already have a match with the sender that hasn't ended.
        case activeMatchExists
        case retryable
        /// The link arrived before this account existed, so it can't be for it.
        case wrongAccount
    }

    /// Someone's challenge link, opened on this iPhone.
    struct ChallengeFromLink: Equatable, Sendable, Identifiable {
        enum Status: Hashable, Sendable {
            case resolving
            /// The link owner's display name; Send uses the link's code.
            case ready(displayName: String)
            case ownLink
            case unavailable
            case retryable
        }

        let sequence: UInt64
        let code: CompetitionChallengeLinkCode
        var status: Status

        var id: UInt64 { sequence }
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
        /// Friends, at the bottom of the stack as History is.
        var showsFriends = false
        var isAccountPresented: Bool
        /// A route to a match that isn't loaded yet: it refreshed once and
        /// waits for the match, without moving the current screens.
        var heldRouteSequence: UInt64?
        /// Accept was tapped before the competition started; the claim is
        /// sent on its first publication.
        var acceptsClaimOnStart = false
        /// The open person page, by opponent identity: under History, a
        /// match, or both, as `personPlace` says.
        var historyPersonIdentity: String?
        var personPlace = CompetitionPersonPlace()
        var healthAccess: HealthAccessStatus?
        var notificationPrompt: NotificationPromptPhase = .unscheduled
        /// Mirrors MainTabView's Challenge and practice sheets.
        var isChallengeSheetOpen = false
        /// Claim links up to this sequence arrived before this account
        /// existed, so they can't be for it.
        var claimLinksBeforeAccountThrough: UInt64 = 0
        /// Who sent the open challenge link, from the server.
        var inviteClaimPreview: CompetitionInvitePreview?
        /// The `now` the preview's dates are written against.
        var inviteClaimPreviewEvaluatedAt: Date?
        /// A second challenge link that opens when the current one is done.
        var queuedClaimRoute: CompetitionRouteEnvelope?
        var claimDeclineFailed = false
        var challengeFromLink: ChallengeFromLink?

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
        case claimPreviewResponse(
            sequence: UInt64,
            Result<CompetitionInvitePreview, CompetitionRemoteFailure>
        )
        case acceptClaimTapped
        /// Not Now or swipe: forget the link on this iPhone, tell no one.
        case notNowClaimTapped
        /// Decline, after its confirmation: the sender is told.
        case declineClaimConfirmed
        /// Decline and Block, after its confirmation.
        case blockClaimConfirmed
        case declineClaimFinished(sequence: UInt64, succeeded: Bool)
        case retryClaimTapped
        case dismissClaimStatus
        case challengeLinkResolved(
            sequence: UInt64,
            Result<String, CompetitionRemoteFailure>
        )
        case sendChallengeFromLinkTapped
        case retryChallengeFromLinkTapped
        case dismissChallengeFromLink
        case pathChanged([CompetitionID])
        case historyPresentationChanged(Bool)
        case friendsPresentationChanged(Bool)
        case historyPersonChanged(String?)
        case personPlaceChanged(CompetitionPersonPlace)
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
    @Dependency(\.date) var date
    @Dependency(\.permissionOnboardingClient) var permissionOnboardingClient

    private enum CancelID {
        case routes
        case inviteClaim
        case claimConfirmationTimeout
        case routeHold
        case notificationPrompt
        case challengeLink
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
                guard state.inviteClaimStatus == .idle else { return .none }
                return startPreview(state: &state)

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
                state.inviteClaimPreview = nil
                state.inviteClaimPreviewEvaluatedAt = nil
                state.queuedClaimRoute = nil
                state.claimDeclineFailed = false
                state.challengeFromLink = nil
                return .concatenate(
                    .merge(
                        .cancel(id: CancelID.routes),
                        .cancel(id: CancelID.inviteClaim),
                        .cancel(id: CancelID.claimConfirmationTimeout),
                        .cancel(id: CancelID.routeHold),
                        .cancel(id: CancelID.notificationPrompt),
                        .cancel(id: CancelID.challengeLink)
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
                    // The same link again is ignored.
                    if state.pendingClaimRoute?.route == envelope.route
                        || state.queuedClaimRoute?.route == envelope.route {
                        return .run { _ in
                            competitionRoutingClient.consume(envelope.sequence)
                        }
                    }
                    // A second link waits while another is open, still
                    // waiting for the first publication, or just accepted
                    // and waiting for its match. Only the newest waiting
                    // one is kept.
                    if state.pendingClaimRoute != nil
                        || state.pendingClaimNavigation != nil {
                        state.queuedClaimRoute = envelope
                        return .none
                    }
                    // Accept always applies to the link on screen.
                    if state.pendingClaimRoute != envelope {
                        state.acceptsClaimOnStart = false
                    }
                    state.pendingClaimRoute = envelope
                    return startPreview(state: &state)
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
                if !isPresented {
                    state.historyPersonIdentity = nil
                }
                return .none

            case let .friendsPresentationChanged(isPresented):
                guard !isPresented else {
                    state.showsFriends = true
                    return .none
                }
                state.historyPersonIdentity = nil
                return closeFriends(state: &state)

            case let .historyPersonChanged(identity):
                state.historyPersonIdentity = identity
                return .none

            case let .personPlaceChanged(place):
                state.personPlace = place
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

            case let .claimPreviewResponse(sequence, result):
                guard sequence == state.pendingClaimRoute?.sequence,
                      state.inviteClaimStatus == .loadingPreview
                else {
                    return .none
                }
                switch result {
                case let .success(preview) where preview.state == .pending:
                    state.inviteClaimPreview = preview
                    state.inviteClaimPreviewEvaluatedAt = date.now
                    state.inviteClaimStatus = .ready
                    return .none
                case let .success(preview):
                    // Already accepted by you (the link was tapped twice):
                    // no sheet, go to the match. Over the Health step nothing
                    // has started; it shows on Home once Health is set up.
                    // Once Health is done, the match is awaited even before
                    // the first publication.
                    guard state.onboarding == nil else {
                        state.inviteClaimStatus = .idle
                        return .merge(
                            consumeClaimRoute(sequence, state: &state),
                            advanceClaimQueue(state: &state)
                        )
                    }
                    state.claimRouteSequenceInFlight = sequence
                    return .send(.claimInviteResponse(
                        sequence: sequence,
                        .success(
                            CompetitionID(preview.competitionID),
                            expectedRevision: state.competition.publication?
                                .publicationRevision ?? 0
                        )
                    ))
                case .failure(.inviteUnavailable):
                    state.inviteClaimStatus = .unavailable
                    return consumeClaimRoute(sequence, state: &state)
                case .failure(.forbidden):
                    state.inviteClaimStatus = .ownChallenge
                    return consumeClaimRoute(sequence, state: &state)
                case .failure(.activeMatchExists):
                    state.inviteClaimStatus = .activeMatchExists
                    return consumeClaimRoute(sequence, state: &state)
                case .failure:
                    state.inviteClaimStatus = .retryable
                    return .none
                }

            case .acceptClaimTapped:
                guard state.inviteClaimStatus == .ready else {
                    return .none
                }
                state.claimDeclineFailed = false
                // Claiming needs the started competition, which starts after
                // Health.
                if state.competition.publication == nil {
                    state.acceptsClaimOnStart = true
                    state.inviteClaimStatus = .idle
                    return .none
                }
                return .send(.processPendingClaim)

            case .notNowClaimTapped:
                guard [.loadingPreview, .ready, .retryable]
                    .contains(state.inviteClaimStatus),
                      let sequence = state.pendingClaimRoute?.sequence
                else {
                    return .none
                }
                state.inviteClaimStatus = .idle
                return .merge(
                    .cancel(id: CancelID.inviteClaim),
                    consumeClaimRoute(sequence, state: &state),
                    advanceClaimQueue(state: &state)
                )

            case .declineClaimConfirmed:
                return declineClaim(&state, block: false)

            case .blockClaimConfirmed:
                return declineClaim(&state, block: true)

            case let .declineClaimFinished(sequence, succeeded):
                guard sequence == state.pendingClaimRoute?.sequence,
                      state.inviteClaimStatus == .declining
                else {
                    return .none
                }
                guard succeeded else {
                    state.inviteClaimStatus = .ready
                    state.claimDeclineFailed = true
                    return .none
                }
                state.inviteClaimStatus = .idle
                return .merge(
                    consumeClaimRoute(sequence, state: &state),
                    advanceClaimQueue(state: &state)
                )

            case let .challengeLinkResolved(sequence, result):
                guard state.challengeFromLink?.sequence == sequence,
                      state.challengeFromLink?.status == .resolving
                else {
                    return .none
                }
                switch result {
                case let .success(displayName):
                    guard let code = state.challengeFromLink?.code else { return .none }
                    state.challengeFromLink?.status = .ready(displayName: displayName)
                    // The + sheet's slot sends by the link's code.
                    return .send(.competition(.challengeRecipientChosen(
                        .init(link: code, displayName: displayName)
                    )))
                case .failure(.ownChallengeLink):
                    state.challengeFromLink?.status = .ownLink
                case .failure(.recipientUnavailable), .failure(.notFound):
                    state.challengeFromLink?.status = .unavailable
                case .failure:
                    state.challengeFromLink?.status = .retryable
                }
                return .none

            case .sendChallengeFromLinkTapped:
                guard case .ready? = state.challengeFromLink?.status else {
                    return .none
                }
                return .send(.competition(.createInviteTapped))

            case .retryChallengeFromLinkTapped:
                guard state.challengeFromLink?.status == .retryable else {
                    return .none
                }
                state.challengeFromLink?.status = .resolving
                return resolveChallengeLink(state: state)

            case .dismissChallengeFromLink:
                guard state.challengeFromLink != nil else { return .none }
                state.challengeFromLink = nil
                return .merge(
                    .cancel(id: CancelID.challengeLink),
                    .send(.competition(.challengeSheetDismissed))
                )

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
                    state.inviteClaimPreview = nil
                    state.inviteClaimPreviewEvaluatedAt = nil
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
                    let postClaim = Effect<Action>.run { _ in
                        competitionRoutingClient.consume(sequence)
                    }
                    let prompt = scheduleNotificationPromptIfDue(state: &state)
                    guard state.pendingClaimNavigation != nil else {
                        return .merge(
                            postClaim,
                            .cancel(id: CancelID.claimConfirmationTimeout),
                            advanceClaimQueue(state: &state),
                            prompt
                        )
                    }
                    return .merge(
                        postClaim,
                        claimConfirmationTimeoutEffect(pendingNavigation),
                        prompt
                    )

                case .failure(.inviteUnavailable), .failure(.forbidden),
                     .failure(.activeMatchExists):
                    state.inviteClaimStatus = switch response {
                    case .failure(.forbidden): .ownChallenge
                    case .failure(.activeMatchExists): .activeMatchExists
                    default: .unavailable
                    }
                    return consumeClaimRoute(sequence, state: &state)

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
                    guard state.inviteClaimPreview != nil else {
                        return startPreview(state: &state)
                    }
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
                case .idle, .loadingPreview, .ready, .declining, .claiming,
                     .waitingForCompetition, .unavailable, .wrongAccount,
                     .ownChallenge, .activeMatchExists:
                    return .none
                }

            case .dismissClaimStatus:
                switch state.inviteClaimStatus {
                case .unavailable, .wrongAccount, .ownChallenge, .activeMatchExists:
                    state.inviteClaimStatus = .idle
                    // A wrong-account notice can cover a newer, valid link.
                    if state.pendingClaimRoute != nil,
                       state.claimRouteSequenceInFlight == nil {
                        return startPreview(state: &state)
                    }
                    return advanceClaimQueue(state: &state)
                case .confirmationTimedOut:
                    state.pendingClaimNavigation = nil
                    state.inviteClaimStatus = .idle
                    return .merge(
                        .cancel(id: CancelID.claimConfirmationTimeout),
                        advanceClaimQueue(state: &state)
                    )
                case .idle, .loadingPreview, .ready, .declining, .claiming,
                     .waitingForCompetition, .retryable:
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
                    effects.append(startPreview(state: &state))
                }
                effects.append(advanceClaimQueue(state: &state))
                effects.append(followSentChallengeFromLink(state: &state))
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

            case .competition(.createInviteResponse):
                // The link was reset, or its owner left, after it opened.
                if case .ready? = state.challengeFromLink?.status,
                   state.competition.inviteRecipient == nil,
                   state.competition.inviteRecipientStatus == .notFound {
                    state.challengeFromLink?.status = .unavailable
                }
                return followSentChallengeFromLink(state: &state)

            case .competition:
                return followSentChallengeFromLink(state: &state)
            }
        }
    }

    /// Schedules the notifications prompt once a match with a person (not a
    /// practice) exists.
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
                  where: { !$0.isPractice && Self.hasPerson($0.lifecycle) }
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
    /// finished. Expired, declined and cancelled ones don't count.
    private static func hasPerson(
        _ lifecycle: LocalCompetitionLifecyclePresentation
    ) -> Bool {
        switch lifecycle {
        case .pending, .scheduled, .active, .endsToday, .tallying:
            true
        case .declined, .expired, .cancelled, .completed, .archived:
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
            let closesFriends = closeFriends(state: &state)
            state.historyPersonIdentity = nil
            state.personPlace = CompetitionPersonPlace()
            let closesAccount = state.isAccountPresented
            state.isAccountPresented = false
            state.path = [id]
            return .merge(
                closesFriends,
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
        case let .challengeLink(code):
            // Newest link wins.
            state.pendingRoute = nil
            state.lastHandledRouteSequence = envelope.sequence
            state.challengeFromLink = ChallengeFromLink(
                sequence: envelope.sequence,
                code: code,
                status: .resolving
            )
            return .merge(
                .run { _ in competitionRoutingClient.consume(envelope.sequence) },
                resolveChallengeLink(state: state)
            )
        }
    }

    private func resolveChallengeLink(state: State) -> Effect<Action> {
        guard let link = state.challengeFromLink else { return .none }
        return .run { send in
            do {
                let displayName = try await competitionClient.resolveChallengeLink(link.code)
                await send(.challengeLinkResolved(sequence: link.sequence, .success(displayName)))
            } catch is CancellationError {
                return
            } catch {
                await send(.challengeLinkResolved(
                    sequence: link.sequence,
                    .failure((error as? CompetitionRemoteFailure) ?? .operationFailed)
                ))
            }
        }
        .cancellable(id: CancelID.challengeLink, cancelInFlight: true)
    }

    /// The challenge sent from someone's link: close the link sheet, free
    /// the + sheet's slot and open the challenge once Home shows it.
    private func followSentChallengeFromLink(state: inout State) -> Effect<Action> {
        guard case .ready? = state.challengeFromLink?.status,
              case let .sent(id, _, _) = state.competition.challengeSheetStatus,
              visibleCompetitionIDs(in: state).contains(id)
        else {
            return .none
        }
        state.challengeFromLink = nil
        state.showsHistory = false
        let closesFriends = closeFriends(state: &state)
        state.historyPersonIdentity = nil
        state.personPlace = CompetitionPersonPlace()
        state.path = [id]
        return .merge(closesFriends, .send(.competition(.challengeSheetDismissed)))
    }

    /// Friends leaving the stack stops its search, load and changes.
    private func closeFriends(state: inout State) -> Effect<Action> {
        guard state.showsFriends else { return .none }
        state.showsFriends = false
        return .send(.competition(.friends(.closed)))
    }

    /// Asks the server who sent the pending link before showing the sheet.
    /// The signed-in session answers before Health is set up, so the sheet
    /// over Health names the sender too. Only a cold start, before Health
    /// is checked, waits for the first publication.
    private func startPreview(state: inout State) -> Effect<Action> {
        guard state.competition.publication != nil || state.onboarding != nil,
              state.claimRouteSequenceInFlight == nil,
              let envelope = state.pendingClaimRoute,
              case let .claimInvite(token) = envelope.route
        else {
            return .none
        }
        state.inviteClaimPreview = nil
        state.inviteClaimPreviewEvaluatedAt = nil
        state.claimDeclineFailed = false
        state.inviteClaimStatus = .loadingPreview
        return .run { send in
            do {
                let request = try CompetitionInviteClaimRequest(token: token.rawValue)
                let preview = try await competitionClient.previewInvite(request)
                await send(.claimPreviewResponse(sequence: envelope.sequence, .success(preview)))
            } catch is CancellationError {
                return
            } catch {
                await send(.claimPreviewResponse(
                    sequence: envelope.sequence,
                    .failure((error as? CompetitionRemoteFailure) ?? .operationFailed)
                ))
            }
        }
        .cancellable(id: CancelID.inviteClaim, cancelInFlight: true)
    }

    /// Decline, or Decline and Block; both finish through declineClaimFinished.
    private func declineClaim(_ state: inout State, block: Bool) -> Effect<Action> {
        guard state.inviteClaimStatus == .ready,
              let preview = state.inviteClaimPreview,
              let sequence = state.pendingClaimRoute?.sequence
        else {
            return .none
        }
        state.inviteClaimStatus = .declining
        state.claimDeclineFailed = false
        let id = CompetitionID(preview.competitionID)
        return .run { send in
            let returned = block
                ? await competitionClient.block(id)
                : await competitionClient.decline(id)
            await send(.declineClaimFinished(
                sequence: sequence,
                succeeded: !returned.dashboard.issues.contains(.commandRejected(id))
            ))
        }
        .cancellable(id: CancelID.inviteClaim, cancelInFlight: true)
    }

    /// Forgets the pending link on this iPhone.
    private func consumeClaimRoute(
        _ sequence: UInt64,
        state: inout State
    ) -> Effect<Action> {
        if state.pendingClaimRoute?.sequence == sequence {
            state.pendingClaimRoute = nil
        }
        state.lastHandledClaimRouteSequence = max(
            state.lastHandledClaimRouteSequence,
            sequence
        )
        state.inviteClaimPreview = nil
        state.inviteClaimPreviewEvaluatedAt = nil
        return .run { _ in competitionRoutingClient.consume(sequence) }
    }

    /// Opens the waiting link once the current one is done.
    private func advanceClaimQueue(state: inout State) -> Effect<Action> {
        guard state.inviteClaimStatus == .idle,
              state.pendingClaimRoute == nil,
              state.pendingClaimNavigation == nil,
              state.claimRouteSequenceInFlight == nil,
              let queued = state.queuedClaimRoute
        else {
            return .none
        }
        state.queuedClaimRoute = nil
        state.pendingClaimRoute = queued
        return startPreview(state: &state)
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
