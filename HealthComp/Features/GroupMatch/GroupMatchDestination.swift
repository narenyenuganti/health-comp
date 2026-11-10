import ComposableArchitecture
import SwiftUI

/// Which screen a group match draws.
enum GroupMatchScreen: Equatable {
    case invite, lobby, liveFreeForAll, liveDoubles, result
}

extension GroupMatchPresentation {
    var screen: GroupMatchScreen {
        switch lifecycle {
        case .pending:
            viewer.invite == .invited ? .invite : .lobby
        // Everyone is in but Day 1 is tomorrow, so anyone can still back out.
        // Nothing is edited in place: a match that didn't start stays a read-only lobby.
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

    var body: some View {
        switch match.screen {
        case .invite: GroupMatchInviteView(match: match, store: store)
        case .lobby: GroupMatchLobbyView(match: match, store: store)
        case .liveFreeForAll: GroupMatchLiveFFAView(match: match, store: store)
        case .liveDoubles: GroupMatchLiveDoublesView(match: match, store: store)
        case .result: GroupMatchResultView(match: match, store: store)
        }
    }
}
