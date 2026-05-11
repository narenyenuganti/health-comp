import ComposableArchitecture

@Reducer
struct MainTabFeature {
    @ObservableState
    struct State: Equatable {
        var currentUser: User
        var selectedTab: Tab = .compete
        var compete: CompeteFeature.State
        var friends = FriendsFeature.State()
        var awards = AwardsFeature.State()

        init(
            currentUser: User,
            selectedTab: Tab = .compete,
            compete: CompeteFeature.State? = nil,
            friends: FriendsFeature.State = FriendsFeature.State(),
            awards: AwardsFeature.State = AwardsFeature.State()
        ) {
            self.currentUser = currentUser
            self.selectedTab = selectedTab
            self.compete = compete ?? CompeteFeature.State(currentUserId: currentUser.id)
            self.friends = friends
            self.awards = awards
        }
    }

    enum Tab: String, Equatable, Sendable, CaseIterable {
        case compete
        case friends
        case awards
        case profile
    }

    enum Action: Equatable, Sendable {
        case tabSelected(Tab)
        case compete(CompeteFeature.Action)
        case friends(FriendsFeature.Action)
        case awards(AwardsFeature.Action)
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.compete, action: \.compete) {
            CompeteFeature()
        }
        Scope(state: \.friends, action: \.friends) {
            FriendsFeature()
        }
        Scope(state: \.awards, action: \.awards) {
            AwardsFeature()
        }
        Reduce { state, action in
            switch action {
            case .tabSelected(let tab):
                state.selectedTab = tab
                return .none
            case .compete, .friends, .awards:
                return .none
            }
        }
    }
}
