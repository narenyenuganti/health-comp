import ComposableArchitecture
import SwiftUI

/// Stub: filled by the Live free-for-all screen PR.
struct GroupMatchLiveFFAView: View {
    let match: GroupMatchPresentation
    let store: StoreOf<GroupMatchFeature>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(match.leadText ?? "").accessibilityIdentifier("competition.group.lead")
                Text("Banter").accessibilityIdentifier("competition.group.banter")
                VStack(alignment: .leading) {
                    ForEach(match.standingRows) { row in
                        Text("\(row.place). \(match.name(of: row.subject))")
                            .accessibilityIdentifier("competition.group.standing.\(row.place)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("competition.group.standings")
                Text("What It Takes").accessibilityIdentifier("competition.group.what-it-takes")
                GroupWeekGrid(match: match)
                Button("Leave Match") { store.send(.commandTapped(.leave(match.id))) }
                    .accessibilityIdentifier("competition.group.leave")
            }
            .padding()
        }
        .background(Theme.ground)
    }
}
