import CompetitionCore
import SwiftUI

extension GroupMatchPresentation {
    /// The day being played, or nil before Day 1 and after Day 7.
    var liveDay: Int? {
        switch lifecycle {
        case let .active(dayOrdinal): dayOrdinal
        case .endsToday: 7
        default: nil
        }
    }

    /// Today's banter for this viewer: nil before Day 3, off a live day, or
    /// when nothing triggers. The same scores give every phone the same line.
    var banter: String? {
        guard let liveDay else { return nil }
        var bots: [UUID: String] = [:]
        for seat in seats { if case let .bot(mode) = seat.occupant { bots[seat.id] = mode.rawValue } }
        guard let line = try? MatchBanter.line(
            matchID: id.rawValue, configuration: configuration, dayOrdinal: liveDay, days: days, botModes: bots
        ) else { return nil }
        return MatchBanter.render(
            line, names: Dictionary(uniqueKeysWithValues: seats.map { ($0.id, $0.name) }), viewerSeatID: viewerSeatID,
            formatPoints: { competitionPointsText(Double($0)) }
        )
    }

    /// Last day with scores: the live day, or all seven once the week is over.
    var lastPlayedDay: Int {
        switch lifecycle {
        case let .active(dayOrdinal): dayOrdinal
        case .endsToday, .tallying, .completed, .archived: 7
        case .pending, .declined, .expired, .cancelled, .scheduled: 0
        }
    }

    var canLeave: Bool { liveDay != nil && !hasLeft(viewer) }

    func hasLeft(_ seat: GroupMatchSeat) -> Bool {
        configuration.leaveCutoffs[seat.id] != nil
    }

    func members(of subject: MatchStandingSubject) -> [GroupMatchSeat] {
        let members = switch subject {
        case let .seat(id): seats.filter { $0.id == id }
        case let .team(team): seats.filter { $0.team == team }
        }
        return members.sorted { ($0.id == viewerSeatID ? 0 : $0.number) < ($1.id == viewerSeatID ? 0 : $1.number) }
    }

    /// A seat's accepted points for one day; nil while not synced, unavailable or after leaving.
    func dayCentipoints(_ seat: GroupMatchSeat, ordinal: Int) -> Int? {
        guard let value = days.first(where: { $0.seatID == seat.id && $0.ordinal == ordinal })?.value,
              case let .centipoints(points) = value
        else { return nil }
        return points
    }

    /// One day on its own, ranked by MatchScoring: seats, or teams in doubles.
    func dayStandings(ordinal: Int) -> [MatchStanding] {
        (try? MatchScoring.standings(
            configuration: configuration, days: days.filter { $0.ordinal == ordinal }, throughDay: ordinal
        ).standings) ?? []
    }

    /// Who won a finished day. Today's leaders aren't winners yet.
    func finalDayWinners(ordinal: Int) -> [MatchStandingSubject] {
        guard ordinal < liveDay ?? 8, case let .winners(subjects) = dayWinners(ordinal: ordinal) else { return [] }
        return subjects
    }

    var calendarDays: [CompetitionDay] {
        schedule.flatMap { try? $0.calendar.sevenDayWindow(startingOn: $0.startDay) } ?? []
    }
}

/// "BOT" or "LEFT" beside a name.
struct GroupMatchTag: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.bold).width(.condensed))
            .kerning(1.2)
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.secondary, lineWidth: 1.5))
            .fixedSize()
    }
}

/// The week, one row per seat (per team in doubles) in standings order. A
/// filled square won that day; amber is you. Each played day opens that day.
struct GroupWeekGrid: View {
    let match: GroupMatchPresentation
    let openDay: (Int) -> Void

    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 26
    @Environment(\.locale) private var locale

    var body: some View {
        let subjects = match.standingRows.map(\.subject)
        HStack(spacing: 2) {
            VStack(alignment: .leading, spacing: 4) {
                Color.clear.frame(width: 1, height: rowHeight)
                ForEach(subjects, id: \.self) { subject in
                    rowName(subject)
                        .frame(height: rowHeight)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.trailing, 6)
            .accessibilityHidden(true)
            ForEach(1...7, id: \.self) { ordinal in
                dayColumn(ordinal, subjects: subjects)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        // Seven columns of numbers fit a phone only up to here.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(12)
        .themePanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.group.week")
    }

    private func rowName(_ subject: MatchStandingSubject) -> some View {
        let isYou = subject == match.viewerSubject
        // Doubles rows say whose team, not both full names, which would take
        // the days' width; the scoreboard above names the teams.
        let name = match.format == .doubles ? (isYou ? "Your team" : "Their team") : match.name(of: subject)
        return Text(name)
            .font(.subheadline.weight(isYou ? .bold : .regular))
            .foregroundStyle(isYou ? Theme.you : Theme.ink)
    }

    private func dayColumn(_ ordinal: Int, subjects: [MatchStandingSubject]) -> some View {
        let played = ordinal <= match.lastPlayedDay
        let winners = match.finalDayWinners(ordinal: ordinal)
        let totals = Dictionary(
            match.dayStandings(ordinal: ordinal).map { ($0.subject, $0.centipoints) }, uniquingKeysWith: { $1 }
        )
        return Button { openDay(ordinal) } label: {
            VStack(spacing: 4) {
                Text(letter(ordinal))
                    .font(.subheadline.weight(.bold).width(.condensed))
                    .foregroundStyle(ordinal == match.liveDay ? Theme.ink : Theme.secondary)
                    .frame(maxWidth: .infinity, minHeight: rowHeight)
                ForEach(subjects, id: \.self) { subject in
                    cell(
                        played && hasScore(subject, ordinal) ? totals[subject] : nil,
                        won: winners.contains(subject),
                        isYou: subject == match.viewerSubject
                    )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!played)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dayLabel(ordinal, subjects: subjects, totals: totals, winners: winners))
        .accessibilityAddTraits(played ? .isButton : [])
        .accessibilityIdentifier("competition.group.week.\(ordinal)")
    }

    private func cell(_ centipoints: Int?, won: Bool, isYou: Bool) -> some View {
        let text = centipoints.map { competitionPointsText(Double($0) / 100, locale: locale) } ?? "–"
        let color: Color = if won { isYou ? Theme.onYouFill : Theme.onInk } else {
            centipoints == nil ? Theme.secondary : Theme.ink
        }
        let fill: Color = won ? (isYou ? Theme.youFill : Theme.ink) : .clear
        return Text(text)
            .font(.subheadline.weight(.bold).width(.condensed).monospacedDigit())
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: rowHeight)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
    }

    private func hasScore(_ subject: MatchStandingSubject, _ ordinal: Int) -> Bool {
        match.members(of: subject).contains { match.dayCentipoints($0, ordinal: ordinal) != nil }
    }

    private func letter(_ ordinal: Int) -> String {
        guard match.calendarDays.indices.contains(ordinal - 1) else { return "\(ordinal)" }
        return String(weekdayText(match.calendarDays[ordinal - 1], locale: locale).prefix(1))
    }

    /// "Day 1, Thursday. Sam 448, won the day. You 421."
    private func dayLabel(
        _ ordinal: Int,
        subjects: [MatchStandingSubject],
        totals: [MatchStandingSubject: Int],
        winners: [MatchStandingSubject]
    ) -> String {
        let weekday = match.calendarDays.indices.contains(ordinal - 1)
            ? ", \(weekdayName(match.calendarDays[ordinal - 1], locale: locale))" : ""
        guard ordinal <= match.lastPlayedDay else { return "Day \(ordinal)\(weekday). Not played yet." }
        let scores = subjects.map { subject in
            let points = hasScore(subject, ordinal) ? totals[subject].map { Double($0) / 100 } : nil
            return "\(match.name(of: subject)) \(competitionPointsAccessibilityText(points, locale: locale))"
                + (winners.contains(subject) ? ", won the day" : "")
        }
        return (["Day \(ordinal)\(weekday)"] + scores).joined(separator: ". ") + "."
    }
}
