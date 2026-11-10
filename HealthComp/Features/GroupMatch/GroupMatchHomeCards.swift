import SwiftUI

/// Stub: filled by the Home screen PR.
struct GroupMatchHomeCards: View {
    let matches: [GroupMatchPresentation]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(matches) { match in
                Text(match.format.title).accessibilityIdentifier(
                    "competition.sharing.\(competitionSharingState(match.lifecycle)).\(match.id.rawValue.uuidString.lowercased())"
                )
            }
        }
        .padding()
    }
}
