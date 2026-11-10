import SwiftUI

/// Stub: filled by the Live free-for-all screen PR; doubles reuses it.
struct GroupMatchDayView: View {
    let match: GroupMatchPresentation
    let ordinal: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(match.seats) { seat in
                    Text(seat.name).accessibilityIdentifier("competition.group.day.player.\(seat.number)")
                }
            }
            .padding()
        }
        .background(Theme.ground)
    }
}
