import SwiftUI

enum CompetitionLeadSide: Hashable {
    case you, them, square
}

func competitionLeadSide(userPoints: Double, opponentPoints: Double) -> CompetitionLeadSide {
    let margin = competitionDisplayedMargin(
        userPoints: userPoints, opponentPoints: opponentPoints
    )
    return margin > 0 ? .you : margin < 0 ? .them : .square
}

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
        .bold()
    return margin > 0
        ? Text("You lead by \(points.foregroundStyle(Theme.you)).")
        : Text("\(opponentDisplayName) leads by \(points.foregroundStyle(Theme.ink)).")
}
