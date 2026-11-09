import SwiftUI

/// Stub: filled by the History screen PR.
struct GroupMatchRecord: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Duels").accessibilityIdentifier("competition.group.record.duels")
            Text("Free-for-all").accessibilityIdentifier("competition.group.record.free-for-all")
            Text("Doubles").accessibilityIdentifier("competition.group.record.doubles")
        }
        .padding()
    }
}
