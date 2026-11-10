import ComposableArchitecture
import SwiftUI

/// Stub: filled by the Result screen PR.
struct GroupMatchResultView: View {
    let match: GroupMatchPresentation
    let store: StoreOf<GroupMatchFeature>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(match.standingRows) { row in
                    Text("\(row.place). \(match.name(of: row.subject))")
                }
                Text("No belt on the line.").accessibilityIdentifier("competition.group.result.no-belt")
                Button("Rematch Everyone") { store.send(.commandTapped(.rematch(match.id))) }
                    .accessibilityIdentifier("competition.group.result.rematch")
            }
            .padding()
        }
        .background(Theme.ground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.group.result")
    }
}
