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
        case retryable
    }

    enum InviteClaimResponse: Equatable, Sendable {
        case success(CompetitionID, expectedRevision: UInt64)
        case failure(CompetitionRemoteFailure)
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

        init(
            competition: CompetitionFeature.State = CompetitionFeature.State(),
            path: [CompetitionID] = [],
            pendingRoute: CompetitionRouteEnvelope? = nil,
            pendingClaimRoute: CompetitionRouteEnvelope? = nil,
            lastHandledRouteSequence: UInt64 = 0,
            lastHandledClaimRouteSequence: UInt64 = 0,
            claimRouteSequenceInFlight: UInt64? = nil,
            pendingClaimNavigation: PendingClaimNavigation? = nil,
            inviteClaimStatus: InviteClaimStatus = .idle
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
        case competition(CompetitionFeature.Action)
    }

    @Dependency(\.competitionRoutingClient) var competitionRoutingClient
    @Dependency(\.competitionClient) var competitionClient
    @Dependency(\.continuousClock) var continuousClock

    private enum CancelID {
        case routes
        case inviteClaim
        case claimConfirmationTimeout
    }

    private static let claimConfirmationTimeout: Duration = .seconds(15)

    var body: some ReducerOf<Self> {
        Scope(state: \.competition, action: \.competition) {
            CompetitionFeature()
        }
        Reduce { state, action in
            switch action {
            case .task:
                return .merge(
                    .send(.competition(.task)),
                    .run { send in
                        for await envelope in competitionRoutingClient.routes() {
                            guard !Task.isCancelled else { return }
                            await send(.routeReceived(envelope))
                        }
                    }
                    .cancellable(id: CancelID.routes, cancelInFlight: true)
                )

            case .scenePhaseChanged(.active):
                return .send(.competition(.sceneBecameActive))

            case .scenePhaseChanged(.inactive),
                 .scenePhaseChanged(.background):
                return .none

            case .timeZoneChanged:
                return .send(.competition(.timeZoneChanged))

            case .stop:
                state.claimRouteSequenceInFlight = nil
                state.pendingClaimNavigation = nil
                state.inviteClaimStatus = .idle
                return .concatenate(
                    .merge(
                        .cancel(id: CancelID.routes),
                        .cancel(id: CancelID.inviteClaim),
                        .cancel(id: CancelID.claimConfirmationTimeout)
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
                    if envelope.sequence
                        >= (state.pendingClaimRoute?.sequence ?? 0) {
                        state.pendingClaimRoute = envelope
                    }
                    if state.competition.publication != nil,
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
                    guard state.pendingClaimNavigation != nil else {
                        return .merge(
                            postClaim,
                            .cancel(id: CancelID.claimConfirmationTimeout)
                        )
                    }
                    return .merge(
                        postClaim,
                        claimConfirmationTimeoutEffect(pendingNavigation)
                    )

                case .failure(.inviteUnavailable):
                    if state.pendingClaimRoute?.sequence == sequence {
                        state.pendingClaimRoute = nil
                    }
                    state.lastHandledClaimRouteSequence = max(
                        state.lastHandledClaimRouteSequence,
                        sequence
                    )
                    state.inviteClaimStatus = .unavailable
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
                     .unavailable:
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
                case .unavailable:
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
                if state.pendingClaimRoute != nil,
                   state.claimRouteSequenceInFlight == nil,
                   state.inviteClaimStatus == .idle {
                    state.inviteClaimStatus = .ready
                }
                return .merge(effects)

            case .competition:
                return .none
            }
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
        state.pendingRoute = nil
        state.lastHandledRouteSequence = envelope.sequence
        switch envelope.route {
        case let .competition(id):
            state.path = visibleCompetitionIDs(in: state).contains(id)
                ? [id]
                : []
        case .claimInvite:
            // Claim routes remain pending in the process-rooted hub until the
            // authenticated claim flow explicitly accepts or rejects them.
            return .none
        }
        return .run { _ in
            competitionRoutingClient.consume(envelope.sequence)
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
