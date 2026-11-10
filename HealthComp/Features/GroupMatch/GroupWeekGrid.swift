import SwiftUI

/// Stub: filled by the Live free-for-all screen PR, shared with Live doubles.
struct GroupWeekGrid: View {
    let match: GroupMatchPresentation

    var body: some View {
        VStack(alignment: .leading) {
            ForEach(1...7, id: \.self) { day in
                Text("Day \(day)").accessibilityIdentifier("competition.group.week.\(day)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.group.week")
    }
}
