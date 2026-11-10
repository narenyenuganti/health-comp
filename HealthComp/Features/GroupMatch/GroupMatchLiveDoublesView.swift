import CompetitionCore
import ComposableArchitecture
import SwiftUI

/// Live doubles: the two-sided scoreboard of team totals, who's carrying,
/// the week by team, today, and a nudge for your partner.
struct GroupMatchLiveDoublesView: View {
    let match: GroupMatchPresentation
    let store: StoreOf<GroupMatchFeature>

    @ScaledMetric(relativeTo: .largeTitle) private var scoreSize: CGFloat = 64
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @State private var nudged = false

    var body: some View {
        GroupMatchLiveScreen(match: match, store: store) { openDay in
            scoreboard
            if competitionShouldShowScores(match.lifecycle) {
                GroupMatchLeadLine(match: match)
            }
            // Banter's place: nothing shows until there's a line.
            Color.clear.frame(height: 0).accessibilityIdentifier("competition.group.banter")
            if competitionShouldShowScores(match.lifecycle) {
                SectionLabel("WHO’S CARRYING")
                carrying
                SectionLabel("THE WEEK")
                GroupWeekGrid(match: match, openDay: openDay)
            }
            if let today = match.liveDay {
                SectionLabel("TODAY")
                todayPanel(today)
            }
            nudge
        }
    }

    private var yourTeam: MatchStandingSubject { match.viewerSubject }

    private var theirTeam: MatchStandingSubject {
        match.standingRows.map(\.subject).first { $0 != yourTeam } ?? yourTeam
    }

    private var partner: GroupMatchSeat? {
        match.members(of: yourTeam).first { $0.id != match.viewerSeatID }
    }

    private var scoreboard: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 12))
        return layout {
            teamBlock(yourTeam, alignment: .leading, identifier: "competition.group.team.you")
                .frame(maxWidth: .infinity, alignment: .leading)
            teamBlock(theirTeam, alignment: stacked ? .leading : .trailing, identifier: "competition.group.team.them")
                .frame(maxWidth: .infinity, alignment: stacked ? .leading : .trailing)
        }
    }

    private func teamBlock(
        _ team: MatchStandingSubject,
        alignment: HorizontalAlignment,
        identifier: String
    ) -> some View {
        let total = Double(match.standingRows.first { $0.subject == team }?.centipoints ?? 0) / 100
        let name = match.name(of: team)
        return VStack(alignment: alignment, spacing: 6) {
            Text(name.uppercased(with: locale))
                .font(.themeLabel)
                .tracking(1.2)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            if competitionShouldShowScores(match.lifecycle) {
                Text(competitionPointsText(total, locale: locale))
                    .font(.score(size: scoreSize).monospacedDigit())
                    .fixedSize()
            }
        }
        .foregroundStyle(team == yourTeam ? Theme.you : Theme.ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            competitionShouldShowScores(match.lifecycle)
                ? "\(name), \(competitionPointsAccessibilityText(total, locale: locale))" : name
        )
        .accessibilityIdentifier(identifier)
    }

    private var carrying: some View {
        VStack(alignment: .leading, spacing: 10) {
            teamSplit(yourTeam)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            teamSplit(theirTeam)
        }
        .padding(16)
        .themePanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.group.carrying")
    }

    /// Two bars sized by each partner's share of the team's points. Yours is
    /// amber and a person partner an amber outline; a bot is never amber.
    private func teamSplit(_ team: MatchStandingSubject) -> some View {
        let members = match.members(of: team)
        let isYours = team == yourTeam
        let lead = members[0]
        let percent = match.carryPercent(seatID: lead.id)
        return VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                let width = max(geometry.size.width - 3, 0)
                let share = Double(percent ?? 50) / 100
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isYours ? Theme.youFill : Theme.ink)
                        .frame(width: width * share)
                    Group {
                        if isYours, !members[1].isBot {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.youFill, lineWidth: 2)
                        } else {
                            RoundedRectangle(cornerRadius: 4).fill(Theme.tertiary)
                        }
                    }
                    .frame(width: width * (1 - share))
                }
            }
            .frame(height: 14)
            .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline) {
                memberLegend(lead, percent: percent)
                Spacer(minLength: 8)
                memberLegend(members[1], percent: nil)
            }
            .font(.subheadline)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(members.map(memberLabel).joined(separator: ". "))
    }

    /// "You, 1,664 points, 53 percent"
    private func memberLabel(_ seat: GroupMatchSeat) -> String {
        var parts = [
            seat.id == match.viewerSeatID ? "You" : seat.name,
            competitionPointsAccessibilityText(seatPoints(seat), locale: locale),
        ]
        if let percent = match.carryPercent(seatID: seat.id) { parts.append("\(percent) percent") }
        if match.hasLeft(seat) { parts.append("left the match") }
        return parts.joined(separator: ", ")
    }

    private func memberLegend(_ seat: GroupMatchSeat, percent: Int?) -> some View {
        let isYou = seat.id == match.viewerSeatID
        return HStack(spacing: 6) {
            Text("\(isYou ? "You" : seat.name) \(competitionPointsText(seatPoints(seat), locale: locale))")
                .fontWeight(isYou ? .bold : .regular)
                .foregroundStyle(isYou ? Theme.you : Theme.ink)
                + Text(percent.map { " · \($0)%" } ?? "").foregroundStyle(Theme.secondary)
            if seat.isBot { GroupMatchTag("BOT") }
            if match.hasLeft(seat) { GroupMatchTag("LEFT") }
        }
    }

    private func seatPoints(_ seat: GroupMatchSeat) -> Double {
        Double(match.projection.seatTotals[seat.id] ?? 0) / 100
    }

    /// Partners side by side with the opponent in the same row.
    private func todayPanel(_ ordinal: Int) -> some View {
        let yours = match.members(of: yourTeam)
        let theirs = match.members(of: theirTeam)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<2, id: \.self) { index in
                HStack {
                    todayScore(yours[index], ordinal: ordinal)
                    Spacer(minLength: 8)
                    todayScore(theirs[index], ordinal: ordinal)
                }
            }
        }
        .font(.subheadline)
        .padding(16)
        .themePanel()
        .accessibilityElement(children: .combine)
    }

    private func todayScore(_ seat: GroupMatchSeat, ordinal: Int) -> some View {
        let isYou = seat.id == match.viewerSeatID
        let points = match.dayCentipoints(seat, ordinal: ordinal).map { Double($0) / 100 }
        return Text("\(isYou ? "You" : seat.name) \(points.map { competitionPointsText($0, locale: locale) } ?? "–")")
            .fontWeight(isYou ? .bold : .regular)
            .foregroundStyle(isYou ? Theme.you : Theme.ink)
            .accessibilityLabel("\(isYou ? "You" : seat.name), \(competitionPointsAccessibilityText(points, locale: locale)) today")
    }

    /// Your partner only, while you both play. Never a bot.
    @ViewBuilder
    private var nudge: some View {
        if let partner, !partner.isBot, match.liveDay != nil, !match.hasLeft(partner), !match.hasLeft(match.viewer) {
            let command = GroupMatchCommand.nudge(match.id)
            let isSending = store.inFlight.contains(command)
            VStack(alignment: .leading, spacing: 6) {
                if nudged {
                    Label("Nudged \(partner.name).", systemImage: "checkmark")
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("competition.group.nudge.sent")
                } else {
                    Button {
                        store.send(.commandTapped(command))
                    } label: {
                        BusyLabel("Nudge \(partner.name)", isBusy: isSending)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isSending)
                    .accessibilityHint("Sends \(partner.name) a notification to open HealthComp.")
                    .accessibilityIdentifier("competition.group.nudge")
                    if store.failed.contains(command) {
                        Text("Couldn’t send the nudge. Try again.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                            .accessibilityIdentifier("competition.group.nudge.error")
                    }
                }
            }
            .padding(.top, 8)
            .onChange(of: isSending) { wasSending, sending in
                if wasSending, !sending, !store.failed.contains(command) { nudged = true }
            }
        }
    }
}
