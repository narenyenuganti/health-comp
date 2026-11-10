import CompetitionCore
import SwiftUI

/// Group matches on Home, one card each, in their own block: they never
/// enter the duel layout, so no duel rule (belt, hero, recent results) can
/// pick one up. They leave Home on the duels' clock; their detail, History
/// and record keep them.
struct GroupMatchHomeCards: View {
    let matches: [GroupMatchPresentation]
    let now: Date
    var select: (CompetitionID) -> Void = { _ in }

    /// Invites, then waiting, live, scheduled, results and didn't-start, each
    /// in the dashboard's order. A result leaves when a duel's would, a match
    /// that didn't start when a closed challenge would, and a live match once
    /// you've left it.
    static func shown(_ matches: [GroupMatchPresentation], now: Date) -> [GroupMatchPresentation] {
        func rank(_ match: GroupMatchPresentation) -> Int? {
            switch match.lifecycle {
            case .pending: match.viewer.invite == .invited ? 0 : 1
            case .active, .endsToday, .tallying: match.hasLeft(match.viewer) ? nil : 2
            case .scheduled: 3
            case let .completed(_, _, completedAt):
                now < (match.schedule.flatMap {
                    competitionResultLeavesHome(schedule: $0, completedAt: completedAt)?.at
                } ?? .distantFuture) ? 4 : nil
            case .declined, .expired, .cancelled:
                competitionIsRetainedOnDashboard(match.lifecycle, now: now) ? 5 : nil
            case .archived: nil
            }
        }
        return matches.enumerated()
            .compactMap { index, match in rank(match).map { ($0, index, match) } }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .map(\.2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.shown(matches, now: now)) { match in
                Button { select(match.id) } label: {
                    GroupMatchHomeCard(match: match)
                }
                .buttonStyle(CompetitionPressButtonStyle())
                .accessibilityIdentifier(
                    "competition.sharing.\(competitionSharingState(match.lifecycle)).\(match.id.rawValue.uuidString.lowercased())"
                )
                .transition(Motion.appear)
            }
        }
    }
}

private struct GroupMatchHomeCard: View {
    let match: GroupMatchPresentation

    @ScaledMetric(relativeTo: .title) private var rowScore: CGFloat = 22
    @ScaledMetric(relativeTo: .largeTitle) private var teamScore: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 26
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusRow
            if competitionShouldShowScores(match.lifecycle) {
                if match.format == .doubles {
                    teams
                    lead
                } else {
                    lead
                    standings
                }
            } else {
                Text(headline)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                lineup
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .themePanel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Status

    private var isLive: Bool { match.liveDay != nil }

    /// "Live", "Invite", "Waiting", "Didn't start", "Scheduled", "Final".
    private var stateWord: String {
        switch match.lifecycle {
        case .pending: match.viewer.invite == .invited ? "Invite" : "Waiting"
        case .declined, .expired, .cancelled: "Didn’t start"
        case .scheduled: "Scheduled"
        case .active, .endsToday, .tallying: "Live"
        case .completed, .archived: "Final"
        }
    }

    /// "Day 4 of 7", "Starts Mon", the week once finished.
    private var trailing: String? {
        let status = competitionStatusText(
            match.lifecycle, schedule: match.schedule, opponentDisplayName: "", style: .card,
            locale: locale, timeZone: timeZone
        )
        switch match.lifecycle {
        case .active, .endsToday, .tallying: return status.title
        case .scheduled, .completed, .archived: return status.timing
        case .pending, .declined, .expired, .cancelled: return nil
        }
    }

    private var statusRow: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isLive {
                    Circle().fill(Theme.ink).frame(width: 8, height: 8)
                }
                Text(stateWord).foregroundStyle(Theme.ink)
                    + Text(" · \(match.format.title)").foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing {
                Text(trailing).foregroundStyle(Theme.secondary)
            }
        }
        .font(.themeLabel)
        .tracking(1.2)
        .textCase(.uppercase)
    }

    // MARK: Before the start

    private func names(_ seats: [GroupMatchSeat]) -> String {
        seats.map(\.name).formatted(.list(type: .and))
    }

    private var headline: String {
        let others = match.seats.filter { $0.id != match.viewerSeatID && !$0.isBot }
        switch match.lifecycle {
        case .pending:
            if match.viewer.invite == .invited, let host = match.seats.first(where: { $0.number == 1 }) {
                return "\(host.name) invited you."
            }
            let waiting = others.filter { $0.invite == .invited }
            return waiting.isEmpty ? "Everyone’s in." : "Waiting on \(names(waiting))."
        case .declined:
            let withdrew = match.closedBeforeStartSeats.filter { $0.invite == .withdrew }
            if !withdrew.isEmpty { return "\(names(withdrew)) withdrew." }
            let declined = match.closedBeforeStartSeats.filter { $0.id != match.viewerSeatID }
            return declined.isEmpty ? "Someone didn’t accept." : "\(names(declined)) didn’t accept."
        case .expired:
            let waiting = others.filter { $0.invite == .invited }
            return waiting.isEmpty ? "The invite expired." : "\(names(waiting)) didn’t answer in time."
        case .cancelled:
            return "Cancelled before it started."
        default:
            return "Everyone’s in."
        }
    }

    /// Everyone's avatar, so the card says who before it says how many.
    private var lineup: some View {
        HStack(spacing: -4) {
            ForEach(match.seats.sorted { $0.number < $1.number }) { seat in
                PersonAvatar(
                    name: seat.name, photo: seat.profileID, size: avatarSize,
                    isYou: seat.id == match.viewerSeatID, isBot: seat.isBot
                )
                .opacity(seat.invite == nil || seat.invite == .accepted ? 1 : 0.45)
            }
        }
    }

    // MARK: Scores

    @ViewBuilder
    private var lead: some View {
        if let text = finalLine {
            Text(text)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            GroupMatchLeadLine(match: match)
        }
    }

    /// The result in words; nil while live.
    private var finalLine: String? {
        guard match.frozenStandings != nil,
              let place = match.standingRows.first(where: { $0.subject == match.viewerSubject })?.place
        else { return nil }
        let tied = match.standingRows.filter { $0.place == place }.count > 1
        if match.format == .doubles {
            return tied ? "Tied." : place == 1 ? "Your team won." : "Your team lost."
        }
        let placeText = GroupMatchPresentation.placeText(place)
        return tied ? "You tied for \(placeText)." : "You finished \(placeText)."
    }

    private var standings: some View {
        VStack(spacing: 0) {
            ForEach(match.standingRows) { row in
                if case let .seat(id) = row.subject, let seat = match.seats.first(where: { $0.id == id }) {
                    standingRow(row, seat: seat)
                }
            }
        }
    }

    private func standingRow(_ row: GroupMatchStandingRow, seat: GroupMatchSeat) -> some View {
        let isYou = seat.id == match.viewerSeatID
        let color = isYou ? Theme.you : Theme.ink
        return HStack(spacing: 10) {
            Text("\(row.place)")
                .font(.score(size: rowScore))
                .foregroundStyle(color)
                .frame(minWidth: 14, alignment: .leading)
            PersonAvatar(name: seat.name, photo: seat.profileID, size: avatarSize, isYou: isYou, isBot: seat.isBot)
            Text(isYou ? "You" : seat.name)
                .fontWeight(isYou ? .bold : .regular)
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(GroupMatchPresentation.pointsText(row.centipoints))
                .font(.score(size: rowScore).monospacedDigit())
                .foregroundStyle(color)
                .fixedSize()
        }
        .frame(minHeight: 34)
    }

    private var teams: some View {
        let rows = match.standingRows
        let yours = rows.first { $0.subject == match.viewerSubject }
        let theirs = rows.first { $0.subject != match.viewerSubject }
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 12))
        return layout {
            if let yours { team(yours, isYours: true, alignment: .leading) }
            if !stacked { Spacer(minLength: 0) }
            if let theirs { team(theirs, isYours: false, alignment: stacked ? .leading : .trailing) }
        }
    }

    private func team(_ row: GroupMatchStandingRow, isYours: Bool, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(match.name(of: row.subject))
                .font(.themeLabel)
                .tracking(1.2)
                .textCase(.uppercase)
            Text(GroupMatchPresentation.pointsText(row.centipoints))
                .font(.score(size: teamScore).monospacedDigit())
                .fixedSize()
        }
        .foregroundStyle(isYours ? Theme.you : Theme.ink)
    }

    // MARK: VoiceOver

    private var accessibilityText: String {
        var parts = ["\(match.format.title), \(stateWord)"]
        if let trailing { parts.append(trailing) }
        if competitionShouldShowScores(match.lifecycle) {
            if let line = finalLine ?? match.leadText { parts.append(line) }
            parts += match.standingRows.map { row in
                let points = competitionPointsAccessibilityText(Double(row.centipoints) / 100, locale: locale)
                return match.format == .doubles
                    ? "\(match.name(of: row.subject)), \(points)"
                    : "\(GroupMatchPresentation.placeText(row.place)), \(match.name(of: row.subject)), \(points)"
            }
        } else {
            parts.append(headline)
        }
        return parts.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }.joined(separator: ". ") + "."
    }
}
