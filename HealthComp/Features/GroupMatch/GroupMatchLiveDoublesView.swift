import ComposableArchitecture
import SwiftUI

/// Stub: filled by the Live doubles screen PR.
struct GroupMatchLiveDoublesView: View {
    let match: GroupMatchPresentation
    let store: StoreOf<GroupMatchFeature>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(match.leadText ?? "").accessibilityIdentifier("competition.group.lead")
                Text("Banter").accessibilityIdentifier("competition.group.banter")
                ForEach(match.standingRows) { row in
                    Text(match.name(of: row.subject)).accessibilityIdentifier(
                        "competition.group.team.\(row.subject == match.viewerSubject ? "you" : "them")"
                    )
                }
                Text("Who's Carrying").accessibilityIdentifier("competition.group.carrying")
                GroupWeekGrid(match: match)
                Button("Nudge") { store.send(.commandTapped(.nudge(match.id))) }
                    .accessibilityIdentifier("competition.group.nudge")
                Button("Leave Match") { store.send(.commandTapped(.leave(match.id))) }
                    .accessibilityIdentifier("competition.group.leave")
            }
            .padding()
        }
        .background(Theme.ground)
    }
}
