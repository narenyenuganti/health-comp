import ComposableArchitecture

@Reducer
struct AppFeature {
    @ObservableState
    struct State: Equatable {
        var mainTab: MainTabFeature.State

        init(mainTab: MainTabFeature.State = MainTabFeature.State()) {
            self.mainTab = mainTab
        }
    }

    enum Action: Equatable, Sendable {
        case mainTab(MainTabFeature.Action)
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.mainTab, action: \.mainTab) {
            MainTabFeature()
        }
    }
}
