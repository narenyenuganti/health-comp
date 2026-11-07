import SwiftUI

/// Who leads, as shown. A change of side crossfades the sentence; the same
/// side only rolls the margin.
enum CompetitionLeadSide: Hashable {
    case you, them, square
}

func competitionLeadSide(userPoints: Double, opponentPoints: Double) -> CompetitionLeadSide {
    let margin = competitionDisplayedMargin(
        userPoints: userPoints, opponentPoints: opponentPoints
    )
    return margin > 0 ? .you : margin < 0 ? .them : .square
}

/// "You lead by 12.", "Hermes leads by 382." or "All square.", from the
/// numbers as shown. The margin is bold, amber for you and ink for them.
@MainActor
func competitionLeadText(
    userPoints: Double,
    opponentPoints: Double,
    opponentDisplayName: String,
    locale: Locale = .current
) -> Text {
    let margin = competitionDisplayedMargin(
        userPoints: userPoints, opponentPoints: opponentPoints
    )
    guard margin != 0 else { return Text("All square.") }
    let points = Text(competitionPointsText(abs(margin), locale: locale))
        .fontWeight(.bold)
    return margin > 0
        ? Text("You lead by ") + points.foregroundStyle(Theme.you) + Text(".")
        : Text("\(opponentDisplayName) leads by ") + points.foregroundStyle(Theme.ink) + Text(".")
}
