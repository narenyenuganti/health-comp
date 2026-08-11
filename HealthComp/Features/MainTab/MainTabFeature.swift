import ComposableArchitecture
import CompetitionCore

@Reducer
struct MainTabFeature {
    @ObservableState
    struct State: Equatable {
        var competition: CompetitionFeature.State
        var path: [CompetitionID]
        var pendingRoute: CompetitionRouteEnvelope?
        var lastHandledRouteSequence: UInt64

        init(
            competition: CompetitionFeature.State = CompetitionFeature.State(),
            path: [CompetitionID] = [],
            pendingRoute: CompetitionRouteEnvelope? = nil,
            lastHandledRouteSequence: UInt64 = 0
        ) {
            self.competition = competition
            self.path = path
            self.pendingRoute = pendingRoute
            self.lastHandledRouteSequence = lastHandledRouteSequence
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
        case pathChanged([CompetitionID])
        case competition(CompetitionFeature.Action)
    }

    @Dependency(\.competitionRoutingClient) var competitionRoutingClient

    private enum CancelID {
        case routes
    }

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
                return .concatenate(
                    .cancel(id: CancelID.routes),
                    .send(.competition(.stop))
                )

            case let .routeReceived(envelope):
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

            case .competition(.publication):
                let visible = visibleCompetitionIDs(in: state)
                state.path = state.path.filter(visible.contains)
                guard let pending = state.pendingRoute else { return .none }
                return resolve(pending, state: &state)

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
}
