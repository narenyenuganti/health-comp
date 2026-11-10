import ComposableArchitecture
import SwiftUI

/// Stub: filled by the Lobby and Invite screen PR.
struct GroupMatchLobbyView: View {
    let match: GroupMatchPresentation
    let store: StoreOf<GroupMatchFeature>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(match.format.title).accessibilityIdentifier("competition.group.lobby.status")
                ForEach(match.seats) { seat in
                    Text(seat.name).accessibilityIdentifier("competition.group.lobby.seat.\(seat.number)")
                }
                Button("Share Match Link") {}.accessibilityIdentifier("competition.group.lobby.share")
                Button("Cancel Match") { store.send(.commandTapped(.cancel(match.id))) }
                    .accessibilityIdentifier("competition.group.lobby.cancel")
            }
            .padding()
        }
        .background(Theme.ground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.group.lobby")
    }
}
