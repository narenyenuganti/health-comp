import Charts
import CompetitionCore
import SwiftUI

struct CompetitionRivalryPieces: Equatable {
    var form = false
    var tape = false
    var rings = false
    var records = false
    var weeksShown: Int?
}

func competitionRivalryPieces(weeks: Int, isLedger: Bool) -> CompetitionRivalryPieces {
    CompetitionRivalryPieces(
        form: weeks >= 3,
        tape: !isLedger && weeks >= 3,
        rings: !isLedger && weeks >= 3,
        records: !isLedger && weeks >= 5,
        weeksShown: weeks >= 6 ? 5 : nil
    )
}

func competitionRivalryWeeks(
    _ competitions: [LocalCompetitionPresentation],
    opponentIdentity: String
) -> [LocalCompetitionPresentation] {
    Array(competitionHistoryWeeks(competitions)
        .filter { $0.opponentIdentity == opponentIdentity }
        .reversed())
}

func competitionFormLine(_ outcomes: [CompetitionOutcome], opponentName: String) -> String? {
    guard let last = outcomes.last else { return nil }
    let who: String
    switch last {
    case .tie: return "The last one was a tie"
    case .win: who = "You"
    case .loss: who = opponentName
    }
    let run = outcomes.reversed().prefix { $0 == last }.count
    return run == 1 ? "\(who) won the last one" : "\(who) won the last \(run)"
}

func competitionFormAccessibilityText(_ outcomes: [CompetitionOutcome], opponentName: String) -> String {
    let shown = outcomes.suffix(10)
    func count(_ outcome: CompetitionOutcome, _ one: String, _ many: String) -> String? {
        let value = shown.filter { $0 == outcome }.count
        return outcome == .tie && value == 0 ? nil : "\(value) \(value == 1 ? one : many)"
    }
    let tally = [count(.win, "win", "wins"), count(.loss, "loss", "losses"), count(.tie, "tie", "ties")]
        .compactMap { $0 }
        .joined(separator: ", ")
    let line = competitionFormLine(outcomes, opponentName: opponentName).map { " \($0)." } ?? ""
    return "Last \(shown.count): \(tally).\(line)"
}

func competitionPersonBelt(
    _ weeks: [LocalCompetitionPresentation],
    holdingBack held: CompetitionID?,
    isRetired: Bool
) -> CompetitionBelt {
    competitionBelt(of: weeks.filter { $0.id != held }, isRetired: isRetired)
}

func competitionRingDaysWon(_ weeks: [LocalCompetitionPresentation]) -> [(you: Int, them: Int)]? {
    var counts = Array(repeating: (you: 0, them: 0), count: 3)
    var counted = false
    for day in weeks.flatMap(\.days) {
        guard let you = day.ownerRingPoints, let them = day.opponentRingPoints,
              you.count == 3, them.count == 3
        else { continue }
        counted = true
        for ring in 0..<3 {
            if you[ring] > them[ring] { counts[ring].you += 1 }
            if them[ring] > you[ring] { counts[ring].them += 1 }
        }
    }
    return counted ? counts : nil
}

struct CompetitionRingRecord: Equatable {
    var weeksYou = 0
    var weeksThem = 0
    var daysYou = 0
    var daysThem = 0
    var averageYou = 0.0
    var averageThem = 0.0
    var bestYou = 0.0
    var bestThem = 0.0
}

func competitionRingRecords(_ weeks: [LocalCompetitionPresentation]) -> [CompetitionRingRecord]? {
    guard let days = competitionRingDaysWon(weeks) else { return nil }
    let both = weeks.flatMap(\.days).compactMap { day -> (you: [Double], them: [Double])? in
        guard let you = day.ownerRingPoints, let them = day.opponentRingPoints,
              you.count == 3, them.count == 3
        else { return nil }
        return (you, them)
    }
    let splits = weeks.compactMap { competitionRingSplit($0.days) }
    let count = Double(both.count)
    return (0..<3).map { ring -> CompetitionRingRecord in
        let you: [Double] = both.map { $0.you[ring] }
        let them: [Double] = both.map { $0.them[ring] }
        var record = CompetitionRingRecord()
        record.weeksYou = splits.filter { $0.you[ring] > $0.them[ring] }.count
        record.weeksThem = splits.filter { $0.them[ring] > $0.you[ring] }.count
        record.daysYou = days[ring].you
        record.daysThem = days[ring].them
        record.averageYou = you.reduce(0, +) / count
        record.averageThem = them.reduce(0, +) / count
        record.bestYou = you.max() ?? 0
        record.bestThem = them.max() ?? 0
        return record
    }
}

func competitionClosestFinish(_ weeks: [LocalCompetitionPresentation]) -> LocalCompetitionPresentation? {
    weeks.filter { $0.terminalResult.map { $0.outcome != .tie } ?? false }
        .reversed()
        .min { competitionMargin($0) < competitionMargin($1) }
}

struct CompetitionComeback: Equatable {
    let weekID: CompetitionID
    let holder: CompetitionBeltHolder
    let deficit: Double
    let afterDay: Int
}

func competitionComebacks(_ weeks: [LocalCompetitionPresentation]) -> [CompetitionComeback] {
    var best: [CompetitionBeltHolder: CompetitionComeback] = [:]
    for week in weeks {
        let holder: CompetitionBeltHolder
        switch week.terminalResult?.outcome {
        case .win: holder = .you
        case .loss: holder = .them
        case .tie, nil: continue
        }
        var lead = 0.0
        for day in week.days.sorted(by: { $0.ordinal < $1.ordinal }) {
            lead += (day.ownerAcceptedPoints ?? 0) - (day.opponentRevealedPoints ?? 0)
            guard (4...6).contains(day.ordinal) else { continue }
            let deficit = holder == .you ? -lead : lead
            if deficit > 0, deficit > best[holder]?.deficit ?? 0 {
                best[holder] = CompetitionComeback(
                    weekID: week.id, holder: holder, deficit: deficit, afterDay: day.ordinal
                )
            }
        }
    }
    return [best[.you], best[.them]].compactMap { $0 }
}

func competitionDayRecord(_ weeks: [LocalCompetitionPresentation]) -> (won: Int, lost: Int, tied: Int)? {
    let days = weeks.flatMap(\.days).compactMap { day -> (Double, Double)? in
        guard let you = day.ownerAcceptedPoints, let them = day.opponentRevealedPoints else { return nil }
        return (you, them)
    }
    guard !days.isEmpty else { return nil }
    return (
        days.filter { $0.0 > $0.1 }.count,
        days.filter { $0.0 < $0.1 }.count,
        days.filter { $0.0 == $0.1 }.count
    )
}

struct CompetitionRivalryRecord: Equatable {
    enum Value: Equatable {
        case sides(you: String, them: String)
        case tally(won: Int, lost: Int, tied: Int)
        case text(String, holder: CompetitionBeltHolder?)
    }

    let label: String
    let value: Value
    let detail: String
}

func competitionRivalryRecords(
    _ weeks: [LocalCompetitionPresentation],
    opponentName: String,
    now: Date,
    year: Int? = nil,
    locale: Locale = .current
) -> [CompetitionRivalryRecord] {
    guard !weeks.isEmpty else { return [] }
    func points(_ value: Double) -> String { competitionPointsText(value, locale: locale) }
    func range(_ week: LocalCompetitionPresentation) -> String {
        week.acceptedConfiguration.flatMap {
            competitionScheduleDateRangeText($0.schedule, now: now, locale: locale)
        } ?? ""
    }
    func name(_ holder: CompetitionBeltHolder) -> String { holder == .you ? "You" : opponentName }
    func best<T>(_ items: [T], _ value: (T) -> Double) -> T? {
        items.reduce(T?.none) { best, item in
            best.map { value(item) >= value($0) ? item : $0 } ?? item
        }
    }
    var rows: [CompetitionRivalryRecord] = []

    if let you = best(weeks, \.userPoints), let them = best(weeks, \.opponentPoints) {
        rows.append(.init(
            label: "Best week",
            value: .sides(you: points(you.userPoints), them: points(them.opponentPoints)),
            detail: "\(range(you)) / \(range(them))"
        ))
    }

    let days = weeks.flatMap(\.days)
    if let you = best(days.filter { $0.ownerAcceptedPoints != nil }, { $0.ownerAcceptedPoints ?? 0 }),
       let them = best(days.filter { $0.opponentRevealedPoints != nil }, { $0.opponentRevealedPoints ?? 0 }) {
        func date(_ day: LocalCompetitionDayPresentation) -> String {
            competitionDayText(day.day, weekday: false, now: now, locale: locale)
        }
        rows.append(.init(
            label: "Best day",
            value: .sides(you: points(you.ownerAcceptedPoints ?? 0), them: points(them.opponentRevealedPoints ?? 0)),
            detail: "\(date(you)) / \(date(them))"
        ))
    }

    if let record = competitionDayRecord(weeks) {
        rows.append(.init(
            label: "Day record",
            value: .tally(won: record.won, lost: record.lost, tied: record.tied),
            detail: "Days won, \(year.map { "\($0)" } ?? "all weeks")"
        ))
    }

    if let close = competitionClosestFinish(weeks) {
        let holder: CompetitionBeltHolder = close.terminalResult?.outcome == .win ? .you : .them
        rows.append(.init(
            label: "Closest finish",
            value: .text("\(name(holder)) by \(points(competitionMargin(close)))", holder: holder),
            detail: range(close)
        ))
    }

    for comeback in competitionComebacks(weeks) {
        guard let week = weeks.first(where: { $0.id == comeback.weekID }) else { continue }
        rows.append(.init(
            label: "Biggest comeback",
            value: .text("\(name(comeback.holder)), from \(points(comeback.deficit)) down", holder: comeback.holder),
            detail: "Behind after day \(comeback.afterDay), won by \(points(competitionMargin(week))) · \(range(week))"
        ))
    }

    if year == nil, weeks.count > 5, let first = weeks.first, let outcome = first.terminalResult?.outcome {
        let holder: CompetitionBeltHolder? = switch outcome {
        case .win: .you
        case .loss: .them
        case .tie: nil
        }
        rows.append(.init(
            label: "First match",
            value: .text(holder.map { "\(name($0)) won" } ?? "Tied", holder: holder),
            detail: range(first)
        ))
    }
    return rows
}

func competitionRivalryRecordAccessibilityText(
    _ record: CompetitionRivalryRecord,
    opponentName: String
) -> String {
    let value: String = switch record.value {
    case let .sides(you, them): "You \(you), \(opponentName) \(them)"
    case let .tally(won, lost, tied):
        "won \(won), lost \(lost)" + (tied > 0 ? ", tied \(tied)" : "")
    case let .text(text, _): text
    }
    return "\(record.label): \(value). \(record.detail)"
}

func competitionYearWeeks(
    _ weeks: [LocalCompetitionPresentation],
    now: Date,
    timeZone: TimeZone = .current
) -> (year: Int, weeks: [LocalCompetitionPresentation])? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let year = calendar.component(.year, from: now)
    let played = weeks.filter { week in
        let lastDay = week.acceptedConfiguration.flatMap {
            try? $0.schedule.calendar.sevenDayWindow(startingOn: $0.schedule.startDay).last
        }
        return (lastDay?.year ?? week.terminalResult.map { calendar.component(.year, from: $0.completedAt) }) == year
    }
    return played.count >= 3 ? (year, played) : nil
}

func competitionAllTimeBestWeekNote(
    all: [LocalCompetitionPresentation],
    year: [LocalCompetitionPresentation],
    locale: Locale = .current
) -> String? {
    guard let top = all.map(\.userPoints).max(),
          let best = all.last(where: { $0.userPoints == top }),
          !year.contains(where: { $0.id == best.id }),
          let start = best.acceptedConfiguration?.schedule.startDay
    else { return nil }
    var gmt = Calendar(identifier: .gregorian)
    gmt.timeZone = .gmt
    guard let date = gmt.date(from: DateComponents(year: start.year, month: start.month, day: start.day)) else { return nil }
    let month = date.formatted(Date.FormatStyle(locale: locale, calendar: gmt, timeZone: .gmt).month(.wide).year())
    return "All time still shows your \(competitionPointsText(best.userPoints, locale: locale)) week from \(month)."
}

private func competitionMargin(_ week: LocalCompetitionPresentation) -> Double {
    abs((week.terminalResult?.userPoints ?? 0) - (week.terminalResult?.opponentPoints ?? 0))
}

struct CompetitionRecordLink {
    let record: CompetitionOpponentRecord
    let open: () -> Void

    var title: String { "Your record with \(record.opponentDisplayName)" }
    var accessibilityLabel: String { "Your record with \(record.accessibilityText)" }
}

func competitionRecordLinkRecord(
    for competition: LocalCompetitionPresentation,
    in competitions: [LocalCompetitionPresentation]
) -> CompetitionOpponentRecord? {
    guard !competition.isPractice,
          competition.opponentDisplayName != competitionFormerCompetitorName,
          let record = competitionOpponentRecords(competitions)
              .first(where: { $0.opponentIdentity == competition.opponentIdentity }),
          !record.belt.isRetired
    else { return nil }
    return record
}

struct CompetitionRecordLinkRow: View {
    let link: CompetitionRecordLink

    var body: some View {
        Button(action: link.open) {
            HStack(spacing: 12) {
                Text(link.title)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                competitionRecordText(link.record)
                    .font(.title3.weight(.heavy).width(.condensed).monospacedDigit())
                DisclosureChevron()
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .themePanel()
            .contentShape(Rectangle())
        }
        .buttonStyle(CompetitionPressButtonStyle())
        .accessibilityLabel(link.accessibilityLabel)
        .accessibilityHint("Opens your weeks with \(link.record.opponentDisplayName)")
        .accessibilityIdentifier("competition.record-link")
    }
}

struct CompetitionFormStrip: View {
    let outcomes: [CompetitionOutcome]
    let opponentName: String
    var isLive = false

    @ScaledMetric(relativeTo: .body) private var barHeight: CGFloat = 10

    var body: some View {
        let shown = Array(outcomes.suffix(isLive ? 9 : 10))
        HStack(spacing: 4) {
            ForEach(shown.indices, id: \.self) { index in
                SlantedBar()
                    .fill(color(shown[index]))
                    .frame(height: barHeight)
            }
            if isLive {
                SlantedBar()
                    .stroke(Theme.faint, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    .frame(height: barHeight)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            competitionFormAccessibilityText(outcomes, opponentName: opponentName)
                + (isLive ? " This week isn’t counted yet." : "")
        )
        .accessibilityIdentifier("competition.person.form")
    }

    private func color(_ outcome: CompetitionOutcome) -> Color {
        switch outcome {
        case .win: Theme.youFill
        case .loss: Theme.ink
        case .tie: Theme.tertiary
        }
    }
}

struct CompetitionRingRecordPanel: View {
    let records: [CompetitionRingRecord]
    let opponentName: String

    @State private var showsDays = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    private let rings: [(name: String, color: Color)] = [
        ("Move", Theme.move), ("Exercise", Theme.exercise), ("Stand", Theme.stand),
    ]

    var body: some View {
        let hasWeeks = records.contains { $0.weeksYou + $0.weeksThem > 0 }
        let byDays = showsDays || !hasWeeks
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("EACH RING")
            if hasWeeks {
                CompetitionSegments(selection: $showsDays, options: [(false, "Weeks won"), (true, "Days won")])
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Count")
                    .accessibilityIdentifier("competition.person.rings.unit")
            }
            ForEach(rings.indices, id: \.self) { index in
                let record = records[index]
                let count = byDays
                    ? (you: record.daysYou, them: record.daysThem)
                    : (you: record.weeksYou, them: record.weeksThem)
                VStack(alignment: .leading, spacing: 6) {
                    row(rings[index], count)
                    stat("AVERAGE DAY", record.averageYou, record.averageThem)
                    stat("BEST DAY", record.bestYou, record.bestThem)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(rings[index].name): you won \(countText(count.you, byDays)), \(opponentName) \(count.them). "
                        + "Average day \(points(record.averageYou)) to \(points(record.averageThem)). "
                        + "Best day \(points(record.bestYou)) to \(points(record.bestThem))"
                )
                .accessibilityIdentifier("competition.person.rings.\(rings[index].name.lowercased())")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themePanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.person.rings")
    }

    private func points(_ value: Double) -> String { competitionPointsText(value, locale: locale) }

    private func countText(_ value: Int, _ byDays: Bool) -> String {
        "\(value) \(byDays ? (value == 1 ? "day" : "days") : (value == 1 ? "week" : "weeks"))"
    }

    @ViewBuilder
    private func stat(_ label: String, _ you: Double, _ them: Double) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            Text("\(label.capitalized(with: locale)): you \(points(you)), \(opponentName) \(points(them))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            CompetitionTapeRow(
                you: points(you), label: label, them: points(them),
                valueFont: .caption.weight(.semibold).monospacedDigit()
            )
            .padding(.leading, 96)
        }
    }

    private func row(_ ring: (name: String, color: Color), _ count: (you: Int, them: Int)) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        let tie = count.you == count.them
        let total = max(count.you + count.them, 1)
        return layout {
            HStack(spacing: 6) {
                SlantedBar()
                    .fill(ring.color)
                    .frame(width: 5, height: 14)
                Text(ring.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
            }
            .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? nil : 84, alignment: .leading)
            VStack(spacing: 4) {
                GeometryReader { proxy in
                    let width = proxy.size.width - 2
                    HStack(spacing: 2) {
                        SlantedBar()
                            .fill(tie ? Theme.track : Theme.youFill)
                            .opacity(count.you < count.them ? 0.32 : 1)
                            .frame(width: width * CGFloat(count.you) / CGFloat(total))
                        SlantedBar()
                            .fill(tie ? Theme.track : Theme.ink)
                            .opacity(count.them < count.you ? 0.32 : 1)
                    }
                }
                .frame(height: 14)
                HStack {
                    Text(String(count.you))
                        .foregroundStyle(tie ? Theme.secondary : Theme.you)
                    Spacer(minLength: 8)
                    Text(String(count.them))
                        .foregroundStyle(tie ? Theme.secondary : Theme.ink)
                }
                .font(.caption.weight(.semibold).monospacedDigit())
            }
        }
    }
}

struct CompetitionRecordsView: View {
    let publication: LocalCompetitionPublication
    let opponentIdentity: String

    @State private var selection: Date?
    @State private var picked: Date?
    @State private var showsAllTime = false
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let allWeeks = competitionRivalryWeeks(publication.dashboard.competitions, opponentIdentity: opponentIdentity)
        let thisYear = competitionYearWeeks(allWeeks, now: publication.evaluatedAt)
        let shown = showsAllTime ? nil : thisYear
        let weeks = shown?.weeks ?? allWeeks
        let name = allWeeks.last?.opponentDisplayName ?? ""
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let thisYear {
                    CompetitionSegments(
                        selection: $showsAllTime, options: [(false, String(thisYear.year)), (true, "All time")]
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Records from")
                    .accessibilityIdentifier("competition.records.year")
                }
                weeklyPoints(weeks, name: name)
                CompetitionRivalryTrendTiles(weeks: weeks)
                let records = competitionRivalryRecords(
                    weeks, opponentName: name, now: publication.evaluatedAt, year: shown?.year, locale: locale
                )
                if !records.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(shown.map { "RECORDS · \($0.year)" } ?? "RECORDS")
                            .padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            ForEach(Array(records.enumerated()), id: \.offset) { index, record in
                                if index > 0 {
                                    Rectangle().fill(Theme.hairline).frame(height: 1)
                                }
                                recordRow(record, name: name)
                            }
                        }
                        .padding(.horizontal, 16)
                        .themePanel()
                        if let shown, let note = competitionAllTimeBestWeekNote(all: allWeeks, year: shown.weeks, locale: locale) {
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 4)
                        }
                    }
                }
            }
            .moving(Motion.settle, value: showsAllTime)
            .onChange(of: showsAllTime) { picked = nil }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.ground)
        .navigationTitle("Records")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("competition.records")
    }

    private func start(_ week: LocalCompetitionPresentation) -> Date {
        week.acceptedConfiguration.flatMap { competitionScheduleBoundaries($0.schedule)?.start }
            ?? .distantPast
    }

    private func range(_ week: LocalCompetitionPresentation) -> String {
        week.acceptedConfiguration.flatMap {
            competitionScheduleDateRangeText($0.schedule, now: publication.evaluatedAt, locale: locale)
        } ?? ""
    }

    private func weeklyPoints(_ weeks: [LocalCompetitionPresentation], name: String) -> some View {
        let selected = picked.flatMap { date in
            weeks.min { abs(start($0).timeIntervalSince(date)) < abs(start($1).timeIntervalSince(date)) }
        } ?? weeks.max { start($0) < start($1) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                SectionLabel("WEEKLY POINTS")
                Spacer(minLength: 8)
                legend("YOU", Theme.youFill)
                legend(name.uppercased(), Theme.ink)
            }
            Chart {
                ForEach(weeks, id: \.id) { week in
                    LineMark(x: .value("Week", start(week)), y: .value("Points", week.opponentPoints), series: .value("Who", "them"))
                        .foregroundStyle(Theme.ink)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .accessibilityHidden(true)
                    LineMark(x: .value("Week", start(week)), y: .value("Points", week.userPoints), series: .value("Who", "you"))
                        .foregroundStyle(Theme.youFill)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .accessibilityHidden(true)
                    PointMark(x: .value("Week", start(week)), y: .value("Points", week.opponentPoints))
                        .foregroundStyle(Theme.ink)
                        .symbolSize(week.id == selected?.id ? 90 : 36)
                        .accessibilityHidden(true)
                    PointMark(x: .value("Week", start(week)), y: .value("Points", week.userPoints))
                        .foregroundStyle(Theme.youFill)
                        .symbolSize(week.id == selected?.id ? 90 : 36)
                        .accessibilityLabel(Text(range(week)))
                        .accessibilityValue(Text(weekValue(week, name: name)))
                }
                if let selected {
                    RuleMark(x: .value("Week", start(selected)))
                        .foregroundStyle(Theme.ink)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .accessibilityHidden(true)
                }
            }
            .chartXSelection(value: $selection)
            .onChange(of: selection) { _, new in
                if let new { picked = new }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated), centered: false)
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 160)

            if let selected {
                NavigationLink(value: CompetitionHomeRoute.competition(selected.id)) {
                    selectedRow(selected)
                }
                .buttonStyle(CompetitionRowButtonStyle())
                .accessibilityLabel("\(range(selected)), \(weekValue(selected, name: name))")
                .accessibilityHint("Opens this match")
                .transition(Motion.appear)
            }
        }
        .padding(16)
        .themePanel()
        .accessibilityElement(children: .contain)
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 12, height: 3)
            Text(title)
                .themeLabel()
                .foregroundStyle(Theme.secondary)
        }
        .accessibilityHidden(true)
    }

    private func weekValue(_ week: LocalCompetitionPresentation, name: String) -> String {
        let result = switch week.terminalResult?.outcome {
        case .win: "you won"
        case .loss: "\(name) won"
        case .tie, nil: "tied"
        }
        return "you \(competitionPointsText(week.userPoints, locale: locale)), \(name) \(competitionPointsText(week.opponentPoints, locale: locale)), \(result)"
    }

    private func selectedRow(_ week: LocalCompetitionPresentation) -> some View {
        HStack(spacing: 12) {
            Text(range(week))
                .font(.headline)
                .foregroundStyle(week.terminalResult?.outcome == .win ? Theme.you : Theme.ink)
            Spacer(minLength: 8)
            let you = Text(competitionPointsText(week.userPoints, locale: locale)).foregroundStyle(Theme.you)
            let slash = Text(" / ").foregroundStyle(Theme.faint)
            let them = Text(competitionPointsText(week.opponentPoints, locale: locale)).foregroundStyle(Theme.ink)
            Text("\(you)\(slash)\(them)")
                .font(.headline.weight(.heavy).width(.condensed).monospacedDigit())
            DisclosureChevron()
        }
        .padding(12)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }

    private func recordRow(_ record: CompetitionRivalryRecord, name: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text(record.detail)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 8)
            }
            value(record.value)
                .font(.subheadline.weight(.heavy).monospacedDigit())
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(competitionRivalryRecordAccessibilityText(record, opponentName: name))
    }

    private func value(_ value: CompetitionRivalryRecord.Value) -> Text {
        switch value {
        case let .sides(you, them):
            let youText = Text(you).foregroundStyle(Theme.you)
            let slash = Text(" / ").foregroundStyle(Theme.faint)
            let themText = Text(them).foregroundStyle(Theme.ink)
            return Text("\(youText)\(slash)\(themText)")
        case let .tally(won, lost, tied):
            let wonText = Text(String(won)).foregroundStyle(Theme.you)
            let lostText = Text("–\(lost)").foregroundStyle(Theme.ink)
            if tied > 0 {
                let tiedText = Text("–\(tied)").foregroundStyle(Theme.secondary)
                return Text("\(wonText)\(lostText)\(tiedText)")
            }
            return Text("\(wonText)\(lostText)")
        case let .text(text, holder):
            return Text(text).foregroundStyle(holder == .you ? Theme.you : Theme.ink)
        }
    }
}

func competitionUnseenResult(
    _ weeks: [LocalCompetitionPresentation],
    now: Date,
    seen: CompetitionMotionSeen
) -> CompetitionID? {
    guard let last = weeks.last,
          case .completed = last.lifecycle,
          now < competitionResultLeavesHome(last)?.at ?? .distantFuture,
          !seen.hasSeen(.verdict, last.id)
    else { return nil }
    return last.id
}

func competitionPersonNow(
    _ competitions: [LocalCompetitionPresentation],
    now: Date,
    unseenResult: CompetitionID?
) -> (competition: LocalCompetitionPresentation, section: String)? {
    let layout = competitionHomeLayout(
        LocalCompetitionDashboard(
            competitions: competitions,
            awards: [],
            issues: [],
            hiddenTerminalCompetitionCount: 0
        ),
        now: now
    )
    if let challenge = layout.needsYou.first { return (challenge, "NEEDS YOU") }
    if let live = layout.hero ?? layout.live.first {
        if case .scheduled = live.lifecycle { return (live, "UP NEXT") }
        return (live, "THIS WEEK")
    }
    if let next = layout.upNext.first { return (next, "UP NEXT") }
    if let result = layout.recentResults.first(where: { $0.id == unseenResult }) {
        return (result, "JUST FINISHED")
    }
    return nil
}

func competitionPersonButtonTitle(
    _ competitions: [LocalCompetitionPresentation],
    opponentName: String,
    now: Date,
    unseenResult: CompetitionID?
) -> String? {
    guard unseenResult == nil else { return nil }
    func inFlight(_ competition: LocalCompetitionPresentation) -> Bool {
        switch competition.lifecycle {
        case .pending, .scheduled, .active, .endsToday, .tallying: true
        default: false
        }
    }
    func onHome(_ competition: LocalCompetitionPresentation) -> Bool {
        guard case .completed = competition.lifecycle else { return false }
        return now < competitionResultLeavesHome(competition)?.at ?? .distantFuture
    }
    if competitions.contains(where: inFlight) { return nil }
    if competitions.contains(where: { competitionIsClosedOutgoing($0.lifecycle) }) {
        return "Challenge \(opponentName) Again"
    }
    if competitions.contains(where: onHome) { return "Rematch \(opponentName)" }
    return "Challenge \(opponentName)"
}

func competitionLastPlayedText(
    _ last: LocalCompetitionPresentation,
    now: Date,
    locale: Locale = .current
) -> String? {
    guard let schedule = last.acceptedConfiguration?.schedule,
          let end = competitionScheduleBoundaries(schedule)?.end,
          case let weeks = Int(now.timeIntervalSince(end) / 604_800), weeks >= 2,
          let range = competitionScheduleDateRangeText(schedule, now: now, locale: locale)
    else { return nil }
    return "Last played \(range) · \(weeks) weeks ago"
}

struct CompetitionProfileRivalry {
    let record: CompetitionOpponentRecord?
    let weeks: [LocalCompetitionPresentation]
    let belt: CompetitionBelt
    let isLive: Bool
    let challengeTitle: String?
    let now: Date

    init(
        _ competitions: [LocalCompetitionPresentation],
        identity: String,
        name: String,
        now: Date,
        seen: CompetitionMotionSeen,
        dismissedChallengeIDs: Set<CompetitionID> = []
    ) {
        let theirs = competitions.filter { $0.opponentIdentity == identity }
        let record = competitionOpponentRecords(competitions).first { $0.opponentIdentity == identity }
        let weeks = competitionRivalryWeeks(competitions, opponentIdentity: identity)
        let unseen = competitionUnseenResult(weeks, now: now, seen: seen)
        self.record = record
        self.weeks = weeks
        belt = competitionPersonBelt(weeks, holdingBack: unseen, isRetired: record?.belt.isRetired == true)
        isLive = theirs.contains {
            switch $0.lifecycle {
            case .active, .endsToday, .tallying: true
            default: false
            }
        }
        challengeTitle = competitionPersonButtonTitle(
            theirs.filter { !dismissedChallengeIDs.contains($0.id) },
            opponentName: name,
            now: now,
            unseenResult: unseen
        )
        self.now = now
    }
}

struct CompetitionOwnCareer: Equatable {
    var career = CompetitionCareer()
    var bestDay = 0.0
    var outcomes: [CompetitionOutcome] = []
}

func competitionOwnCareer(_ competitions: [LocalCompetitionPresentation]) -> CompetitionOwnCareer {
    let weeks = Array(competitionHistoryWeeks(competitions).reversed())
    let outcomes = weeks.compactMap(\.terminalResult?.outcome)
    let folded = weeks.map { week in
        (end: week.acceptedConfiguration.flatMap { competitionScheduleBoundaries($0.schedule)?.end } ?? .distantPast,
         id: week.id.rawValue.uuidString,
         outcome: week.terminalResult?.outcome)
    }.sorted { ($0.end, $0.id) < ($1.end, $1.id) }
    var streak = 0, longest = 0
    for week in folded where week.outcome != nil {
        streak = week.outcome == .win ? streak + 1 : 0
        longest = max(longest, streak)
    }
    let standardWeeks = weeks.filter(\.metrics.isDefaultRings)
    return CompetitionOwnCareer(
        career: CompetitionCareer(
            wins: outcomes.filter { $0 == .win }.count,
            losses: outcomes.filter { $0 == .loss }.count,
            ties: outcomes.filter { $0 == .tie }.count,
            people: Set(weeks.map(\.opponentIdentity)).count,
            belts: competitionOpponentRecords(competitions).filter { $0.belt.holder == .you }.count,
            winStreak: longest,
            bestWeek: standardWeeks.map(\.userPoints).max() ?? 0
        ),
        bestDay: standardWeeks.flatMap(\.days).compactMap(\.ownerAcceptedPoints).max() ?? 0,
        outcomes: outcomes
    )
}

struct CompetitionTapeRow: View {
    let you: String
    let label: String
    let them: String
    let valueFont: Font

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(you)
                .font(valueFont)
                .foregroundStyle(Theme.you)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(label)
                .themeLabel(tracking: 1.1)
                .foregroundStyle(Theme.secondary)
                .layoutPriority(1)
            Text(them)
                .font(valueFont)
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .lineLimit(1)
    }
}

struct CompetitionOwnProfileView: View {
    let publication: LocalCompetitionPublication
    let name: String
    let sharesCareer: Bool?
    let setSharesCareer: (Bool) -> Void
    let edit: () -> Void

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var nameSize: CGFloat = 52
    @ScaledMetric(relativeTo: .largeTitle) private var recordSize: CGFloat = 64
    @ScaledMetric(relativeTo: .title2) private var bestSize: CGFloat = 25

    var body: some View {
        let competitions = publication.dashboard.competitions
        let own = competitionOwnCareer(competitions)
        let belts = competitionOpponentRecords(competitions).filter { $0.belt.holder == .you }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    PersonAvatar(name: name, size: 96, isYou: true, initialFont: .largeTitle.weight(.heavy).width(.condensed))
                    Text("YOU")
                        .font(.score(size: min(nameSize, 72)))
                        .foregroundStyle(Theme.you)
                        .accessibilityAddTraits(.isHeader)
                }
                VStack(alignment: .leading, spacing: 4) {
                    let summary = "\(competitionWeeksText(own.career.weeks)) · \(own.career.people == 1 ? "1 person" : "\(own.career.people) people")"
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            SectionLabel("CAREER")
                            Spacer(minLength: 8)
                            careerSummary(summary)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            SectionLabel("CAREER")
                            careerSummary(summary)
                        }
                    }
                    competitionRecordText(wins: own.career.wins, losses: own.career.losses, ties: own.career.ties)
                        .font(.score(size: min(recordSize, 96)).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .accessibilityLabel(own.career.text)
                        .accessibilityIdentifier("competition.ownProfile.record")
                    if own.outcomes.count >= 3 {
                        CompetitionFormStrip(outcomes: own.outcomes, opponentName: "Opponents")
                    }
                }
                if own.career.weeks > 0 {
                    NavigationLink(value: CompetitionHomeRoute.ownBadges) {
                        CompetitionBadgesRow(badges: competitionBadgeBook(competitions).badges)
                    }
                    .buttonStyle(CompetitionPressButtonStyle())
                    .accessibilityIdentifier("competition.ownProfile.badges")
                }
                if !belts.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("BELTS · \(belts.count)")
                            .padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            ForEach(belts, id: \.opponentIdentity) { beltRow($0, competitions: competitions) }
                        }
                        .themePanel()
                    }
                }
                NavigationLink(value: CompetitionHomeRoute.ownRecords) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            SectionLabel("RECORDS")
                            Spacer(minLength: 8)
                            CompetitionAllLabel()
                        }
                        .padding(.horizontal, 4)
                        bestsLayout {
                            best("BEST WEEK", competitionPointsText(own.career.bestWeek))
                            best("BEST DAY", competitionPointsText(own.bestDay))
                            best("WIN STREAK", String(own.career.winStreak))
                        }
                        .padding(.vertical, 14)
                        .themePanel()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(CompetitionPressButtonStyle())
                .accessibilityHint("Opens your records")
                .accessibilityIdentifier("competition.ownProfile.records")
                if let sharesCareer {
                    Toggle(isOn: Binding(get: { sharesCareer }, set: setSharesCareer)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show my career")
                                .font(.headline)
                                .foregroundStyle(Theme.ink)
                            Text("To friends and people you play")
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    .tint(Theme.youFill)
                    .padding(16)
                    .themePanel()
                    .accessibilityIdentifier("competition.ownProfile.share")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("competition.ownProfile")
        }
        .background(Theme.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit", action: edit)
                    .accessibilityIdentifier("competition.ownProfile.edit")
            }
        }
    }

    private func careerSummary(_ text: String) -> some View {
        Text(text.uppercased(with: locale))
            .themeLabel()
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var bestsLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
    }

    private func beltRow(_ record: CompetitionOpponentRecord, competitions: [LocalCompetitionPresentation]) -> some View {
        let weeks = competitionRivalryWeeks(competitions, opponentIdentity: record.opponentIdentity)
        let since = record.belt.current.flatMap {
            competitionBeltSinceText($0, weeks: weeks, now: publication.evaluatedAt, locale: locale, timeZone: timeZone)
        }
        return NavigationLink(value: CompetitionHomeRoute.profile(record.opponentIdentity)) {
            HStack(spacing: 12) {
                PersonAvatar(name: record.opponentDisplayName, photo: record.latest.opponentProfileID, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.opponentDisplayName)
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    if let since {
                        Text(since)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if !dynamicTypeSize.isAccessibilitySize {
                    CompetitionBeltMark(holder: .you)
                }
                DisclosureChevron()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(CompetitionPressButtonStyle())
    }

    private func best(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.score(size: bestSize).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .themeLabel(tracking: 1.1)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct OpenCompetitionProfileAction: Equatable {
    let id: UUID
    private let perform: (CompetitionHomeRoute) -> Void

    init(id: UUID, perform: @escaping (CompetitionHomeRoute) -> Void) {
        self.id = id
        self.perform = perform
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func callAsFunction(_ route: CompetitionHomeRoute) {
        perform(route)
    }
}

extension EnvironmentValues {
    @Entry var openCompetitionProfile: OpenCompetitionProfileAction?
}

func competitionProfileRoute(for competition: LocalCompetitionPresentation) -> CompetitionHomeRoute? {
    guard !competition.isPractice,
          competition.opponentProfileID != nil,
          competition.opponentDisplayName != competitionFormerCompetitorName
    else { return nil }
    return .profile(competition.opponentIdentity)
}

func competitionOwnProfileRoute(for competition: LocalCompetitionPresentation) -> CompetitionHomeRoute? {
    competition.isPractice ? nil : .ownProfile
}

struct CompetitionProfileTap: ViewModifier {
    let route: CompetitionHomeRoute?
    @Environment(\.openCompetitionProfile) private var open

    func body(content: Content) -> some View {
        if let route, let open {
            content
                .contentShape(Rectangle().inset(by: -8))
                .onTapGesture { open(route) }
                .accessibilityAddTraits(.isButton)
        } else {
            content
        }
    }
}

struct CompetitionProfileAction: ViewModifier {
    let route: CompetitionHomeRoute?
    let name: String
    @Environment(\.openCompetitionProfile) private var open

    func body(content: Content) -> some View {
        if let route, let open {
            content.accessibilityAction(named: "\(name)’s profile") { open(route) }
        } else {
            content
        }
    }
}
