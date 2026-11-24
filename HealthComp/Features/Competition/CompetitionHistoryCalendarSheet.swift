import CompetitionCore
import SwiftUI

struct CompetitionCalendarDayKey: Hashable, Comparable, Identifiable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    var id: String { "\(year)-\(month)-\(day)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    init(_ day: CompetitionDay) {
        self.year = day.year
        self.month = day.month
        self.day = day.day
    }

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }
}

struct CompetitionCalendarDayEntry: Equatable, Identifiable {
    let key: CompetitionCalendarDayKey
    let day: CompetitionDay
    let competitionID: CompetitionID
    let opponentName: String
    let outcome: CompetitionOutcome?
    let userPoints: Double?
    let opponentPoints: Double?

    var id: CompetitionCalendarDayKey { key }
}

struct CompetitionCalendarMonth: Equatable, Identifiable {
    let year: Int
    let month: Int
    let leadingBlanks: Int
    let days: [CompetitionCalendarDayKey]

    var id: String { "\(year)-\(month)" }
}

func competitionCalendarEntries(
    _ competitions: [LocalCompetitionPresentation]
) -> [CompetitionCalendarDayKey: CompetitionCalendarDayEntry] {
    var map: [CompetitionCalendarDayKey: CompetitionCalendarDayEntry] = [:]
    let ordered = competitions.filter { !$0.isPractice }.sorted { lhs, rhs in
        let l = lhs.acceptedConfiguration?.schedule.startDay
        let r = rhs.acceptedConfiguration?.schedule.startDay
        return (l?.year ?? 0, l?.month ?? 0, l?.day ?? 0) < (r?.year ?? 0, r?.month ?? 0, r?.day ?? 0)
    }
    for competition in ordered {
        for day in competition.days where day.ownerLatestAvailability != .notYetOccurred {
            let outcome: CompetitionOutcome?
            switch competitionDayOutcome(day, currentDayOrdinal: competition.currentDayOrdinal) {
            case .won: outcome = .win
            case .lost: outcome = .loss
            case .tied: outcome = .tie
            case .today, .upcoming, .noData:
                if let u = day.ownerAcceptedPoints, let t = day.opponentRevealedPoints, u > 0 || t > 0 {
                    outcome = u > t ? .win : u < t ? .loss : .tie
                } else {
                    outcome = nil
                }
            }
            let key = CompetitionCalendarDayKey(day.day)
            map[key] = CompetitionCalendarDayEntry(
                key: key,
                day: day.day,
                competitionID: competition.id,
                opponentName: competition.opponentDisplayName,
                outcome: outcome,
                userPoints: day.ownerAcceptedPoints,
                opponentPoints: day.opponentRevealedPoints
            )
        }
    }
    return map
}

func competitionCalendarMonths(
    from entries: [CompetitionCalendarDayKey: CompetitionCalendarDayEntry]
) -> [CompetitionCalendarMonth] {
    var gmt = Calendar(identifier: .gregorian)
    gmt.timeZone = .gmt
    let keys = Set(entries.keys.map { "\($0.year)-\($0.month)" })
    let pairs: [(Int, Int)] = keys.compactMap { raw in
        let parts = raw.split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return (y, m)
    }.sorted { lhs, rhs in
        lhs.0 != rhs.0 ? lhs.0 > rhs.0 : lhs.1 > rhs.1
    }
    return pairs.compactMap { year, month in
        guard let first = gmt.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = gmt.range(of: .day, in: .month, for: first)
        else { return nil }
        let weekday = gmt.component(.weekday, from: first)
        let mondayOffset = (weekday + 5) % 7
        let days = range.map { CompetitionCalendarDayKey(year: year, month: month, day: $0) }
        return CompetitionCalendarMonth(
            year: year,
            month: month,
            leadingBlanks: mondayOffset,
            days: days
        )
    }
}

struct CompetitionHistoryCalendarSheet: View {
    let competitions: [LocalCompetitionPresentation]
    let now: Date
    let openMatch: (CompetitionID) -> Void

    @State private var selectedDay: CompetitionCalendarDayKey?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    private let weekdayHeaders = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        let entries = competitionCalendarEntries(competitions)
        let months = competitionCalendarMonths(from: entries)
        let activeEntry = selectedDay.flatMap { entries[$0] }
            ?? entries.keys.sorted().last.flatMap { entries[$0] }

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let activeEntry {
                        selectedBanner(activeEntry)
                    }

                    if months.isEmpty {
                        Text("Played match days appear on your calendar.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(months) { month in
                            monthCard(month, entries: entries, selected: activeEntry?.key)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Theme.ground)
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("competition.calendar.done")
                }
            }
        }
        .accessibilityIdentifier("competition.calendar.sheet")
    }

    private func selectedBanner(_ entry: CompetitionCalendarDayEntry) -> some View {
        let verdict: String
        let verdictColor: Color
        switch entry.outcome {
        case .win:
            verdict = "YOU WON DAY"
            verdictColor = Theme.you
        case .loss:
            verdict = "\(entry.opponentName.uppercased()) WON"
            verdictColor = Theme.ink
        case .tie:
            verdict = "TIED DAY"
            verdictColor = Theme.secondary
        case nil:
            verdict = "IN PLAY"
            verdictColor = Theme.secondary
        }
        return Button {
            dismiss()
            openMatch(entry.competitionID)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(competitionDayText(entry.day, now: now, locale: locale))
                            .font(.headline)
                            .foregroundStyle(Theme.ink)
                        Text(verdict)
                            .font(.caption2.weight(.heavy).width(.condensed))
                            .tracking(0.8)
                            .foregroundStyle(verdictColor)
                    }
                    Text("vs \(entry.opponentName) · You \(competitionPointsText(entry.userPoints, locale: locale)) · \(entry.opponentName) \(competitionPointsText(entry.opponentPoints, locale: locale))")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                DisclosureChevron()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themePanel()
            .contentShape(Rectangle())
        }
        .buttonStyle(CompetitionPressButtonStyle())
        .accessibilityIdentifier("competition.calendar.selected")
    }

    private func monthCard(
        _ month: CompetitionCalendarMonth,
        entries: [CompetitionCalendarDayKey: CompetitionCalendarDayEntry],
        selected: CompetitionCalendarDayKey?
    ) -> some View {
        let monthEntries = month.days.compactMap { entries[$0] }
        let wins = monthEntries.filter { $0.outcome == .win }.count
        let losses = monthEntries.filter { $0.outcome == .loss }.count
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(monthTitle(month))
                Spacer(minLength: 8)
                Text("\(wins)–\(losses) DAYS")
                    .themeLabel()
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(weekdayHeaders.indices, id: \.self) { index in
                        Text(weekdayHeaders[index])
                            .font(.caption2.weight(.bold).width(.condensed))
                            .foregroundStyle(Theme.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(0..<month.leadingBlanks, id: \.self) { _ in
                        Color.clear.frame(height: 36)
                    }
                    ForEach(month.days, id: \.self) { day in
                        dayCell(day, entry: entries[day], isSelected: day == selected)
                    }
                }
            }
            .padding(14)
            .themePanel()
        }
    }

    private func dayCell(
        _ day: CompetitionCalendarDayKey,
        entry: CompetitionCalendarDayEntry?,
        isSelected: Bool
    ) -> some View {
        Button {
            if let entry {
                if selectedDay == day {
                    dismiss()
                    openMatch(entry.competitionID)
                } else {
                    selectedDay = day
                }
            }
        } label: {
            VStack(spacing: 4) {
                Text(String(day.day))
                    .font(.caption.weight(entry != nil ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(entry != nil ? Theme.ink : Theme.faint)
                pip(for: entry)
                    .frame(width: 16, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.ground)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Theme.ink, lineWidth: 1.5)
                        }
                } else if entry != nil {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.control)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(entry == nil)
        .accessibilityLabel(dayAccessibilityLabel(day, entry: entry))
        .accessibilityIdentifier("competition.calendar.day.\(day.year)-\(day.month)-\(day.day)")
    }

    @ViewBuilder
    private func pip(for entry: CompetitionCalendarDayEntry?) -> some View {
        switch entry?.outcome {
        case .win: SlantedBar().fill(Theme.youFill)
        case .loss: SlantedBar().fill(Theme.ink)
        case .tie: SlantedBar().fill(Theme.tertiary)
        case nil:
            if entry != nil {
                SlantedBar().stroke(Theme.secondary, lineWidth: 1)
            } else {
                SlantedBar().fill(Theme.track.opacity(0.5))
            }
        }
    }

    private func monthTitle(_ month: CompetitionCalendarMonth) -> String {
        var gmt = Calendar(identifier: .gregorian)
        gmt.timeZone = .gmt
        guard let date = gmt.date(from: DateComponents(year: month.year, month: month.month, day: 1)) else {
            return "\(month.year)-\(month.month)"
        }
        return date.formatted(Date.FormatStyle(locale: locale, calendar: gmt, timeZone: .gmt).month(.wide).year())
            .uppercased(with: locale)
    }

    private func dayAccessibilityLabel(_ day: CompetitionCalendarDayKey, entry: CompetitionCalendarDayEntry?) -> String {
        guard let entry else { return "\(day.month)/\(day.day), no match" }
        let base = competitionDayText(entry.day, now: now, locale: locale)
        let result: String = switch entry.outcome {
        case .win: "you won"
        case .loss: "\(entry.opponentName) won"
        case .tie: "tied"
        case nil: "in play"
        }
        return "\(base), versus \(entry.opponentName), \(result)"
    }
}
