import SwiftUI

/// Stub: filled by the Versus screen PR.
struct GroupMatchVersusIntro: View {
    let match: GroupMatchPresentation

    var body: some View {
        VStack(spacing: 12) {
            ForEach(match.seats) { seat in
                HStack {
                    PersonAvatar(
                        name: seat.name,
                        photo: seat.profileID,
                        size: 44,
                        isYou: seat.id == match.viewerSeatID,
                        isBot: seat.isBot
                    )
                    Text(seat.name)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.group.versus")
    }
}
