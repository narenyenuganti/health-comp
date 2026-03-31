import ComposableArchitecture

@Reducer
struct MainTabFeature {
    @ObservableState
    struct State: Equatable {
        var selectedTab: Tab = .compete
    }

    enum Tab: String, Equatable, Sendable, CaseIterable {
        case compete
        case friends
        case awards
        case profile
    }

    enum Action: Equatable, Sendable {
        case tabSelected(Tab)
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .tabSelected(let tab):
                state.selectedTab = tab
                return .none
            }
        }
    }
}
