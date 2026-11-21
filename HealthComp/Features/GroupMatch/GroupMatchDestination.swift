import ComposableArchitecture
import SwiftUI

enum GroupMatchScreen: Equatable {
    case invite, lobby, liveFreeForAll, liveDoubles, result
}

extension GroupMatchPresentation {
    var screen: GroupMatchScreen {
        switch lifecycle {
        case .pending:
            viewer.invite == .invited ? .invite : .lobby
        case .scheduled, .declined, .expired, .cancelled:
            .lobby
        case .active, .endsToday, .tallying:
            format == .doubles ? .liveDoubles : .liveFreeForAll
        case .completed, .archived:
            .result
        }
    }
}

struct GroupMatchDestination: View {
    let match: GroupMatchPresentation
    let store: StoreOf<GroupMatchFeature>
    let createNewMatch: () -> Void

    var body: some View {
        switch match.screen {
        case .invite: GroupMatchInviteView(match: match, store: store)
        case .lobby: GroupMatchLobbyView(match: match, store: store, createNewMatch: createNewMatch)
        case .liveFreeForAll: GroupMatchLiveFFAView(match: match, store: store)
        case .liveDoubles: GroupMatchLiveDoublesView(match: match, store: store)
        case .result: GroupMatchResultView(match: match, createNewMatch: createNewMatch)
        }
    }
}
