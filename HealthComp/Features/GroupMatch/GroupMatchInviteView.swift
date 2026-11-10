import ComposableArchitecture
import SwiftUI

/// Stub: filled by the Lobby and Invite screen PR.
struct GroupMatchInviteView: View {
    let match: GroupMatchPresentation
    let store: StoreOf<GroupMatchFeature>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading) {
                    ForEach(match.seats) { Text($0.name) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("competition.group.invite.lineup")
                Button("Accept") { store.send(.commandTapped(.accept(match.id))) }
                    .accessibilityIdentifier("competition.group.invite.accept")
                Button("Not Now") {}.accessibilityIdentifier("competition.group.invite.not-now")
                Button("Decline") { store.send(.commandTapped(.decline(match.id))) }
                    .accessibilityIdentifier("competition.group.invite.decline")
            }
            .padding()
        }
        .background(Theme.ground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.group.invite")
    }
}
