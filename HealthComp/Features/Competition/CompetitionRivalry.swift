import Charts
import CompetitionCore
import SwiftUI

// MARK: Rivalry stats

/// What the person page shows at a number of finished weeks: nothing from
/// one or two weeks, Records from five. The ledger (you blocked them, or
/// their account is gone) keeps the record, form, belt title and weeks.
struct CompetitionRivalryPieces: Equatable {
    var form = false
    var tape = false
    var rings = false
    var records = false
    /// Weeks listed before "All N weeks"; nil lists them all.
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

/// One person's finished weeks, oldest first. Practice never counts.
func competitionRivalryWeeks(
    _ competitions: [LocalCompetitionPresentation],
    opponentIdentity: String
) -> [LocalCompetitionPresentation] {
    Array(competitionHistoryWeeks(competitions)
        .filter { $0.opponentIdentity == opponentIdentity }
        .reversed())
}

/// "You won the last 2", "Sam won the last one" or "The last one was a tie".
/// Outcomes oldest first.
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

/// The strip as one element: "Last 10: 6 wins, 3 losses, 1 tie. You won the last 2."
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

/// The belt over these weeks without the one whose Verdict hasn't been seen,
/// so the page never gets ahead of the ceremony.
func competitionPersonBelt(
    _ weeks: [LocalCompetitionPresentation],
    holdingBack held: CompetitionID?,
    isRetired: Bool
) -> CompetitionBelt {
    competitionBelt(of: weeks.filter { $0.id != held }, isRetired: isRetired)
}

/// Days each of you won per ring (Move, Exercise, Stand): counts only, never
/// the values or ring settings. Nil until a day has both sides' rings.
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

/// The decided week with the smallest margin; the later one on a tie.
func competitionClosestFinish(_ weeks: [LocalCompetitionPresentation]) -> LocalCompetitionPresentation? {
    weeks.filter { $0.terminalResult.map { $0.outcome != .tie } ?? false }
        .reversed()
        .min { competitionMargin($0) < competitionMargin($1) }
}

/// The largest end-of-day deficit the winner overcame, from the end of day 4
/// to the end of day 6; yours first, then theirs, each only once it happened.
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

/// Days won, lost and tied across all weeks, where both sides scored.
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

/// One row of the Records screen. Each goes to whoever holds it.
struct CompetitionRivalryRecord: Equatable {
    enum Value: Equatable {
        /// You, then them: "2,223 / 2,190".
        case sides(you: String, them: String)
        case tally(won: Int, lost: Int, tied: Int)
        case text(String, holder: CompetitionBeltHolder?)
    }

    let label: String
    let value: Value
    let detail: String
}

/// Best week, best day, day record, closest finish, biggest comebacks and,
/// once that week is behind "All N weeks", the first match. Weeks oldest first.
func competitionRivalryRecords(
    _ weeks: [LocalCompetitionPresentation],
    opponentName: String,
    now: Date,
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
    // >=: on a tie the later week holds it.
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
            detail: "Days won, all weeks"
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

    if weeks.count > 5, let first = weeks.first, let outcome = first.terminalResult?.outcome {
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

/// What VoiceOver reads for a record's value; two-sided rows read "You x, Sam y".
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

private func competitionMargin(_ week: LocalCompetitionPresentation) -> Double {
    abs((week.terminalResult?.userPoints ?? 0) - (week.terminalResult?.opponentPoints ?? 0))
}

// MARK: Your record with them

/// "Your record with Sam": opens their page, or pops back to it when it's
/// already on the stack.
struct CompetitionRecordLink {
    let record: CompetitionOpponentRecord
    let open: () -> Void

    var title: String { "Your record with \(record.opponentDisplayName)" }
    /// "Your record with Sam, 6 wins, 3 losses, 1 tie".
    var accessibilityLabel: String { "Your record with \(record.accessibilityText)" }
}

/// The record a match's "Your record with" row shows: never for practice or a
/// deleted account, and only once a week with them has finished.
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

/// The row on the Verdict and the received challenge.
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
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.tertiary)
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

// MARK: Person page pieces

/// The last ten weeks, oldest first: amber you, ink them, grey a tie. With a
/// week in play, the last slot is dashed and nothing is counted for it.
struct CompetitionFormStrip: View {
    let outcomes: [CompetitionOutcome]
    let opponentName: String
    var isLive = false

    @ScaledMetric(relativeTo: .body) private var barHeight: CGFloat = 10

    var body: some View {
        let shown = Array(outcomes.suffix(isLive ? 9 : 10))
        VStack(alignment: .leading, spacing: 8) {
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
            if let line = competitionFormLine(outcomes, opponentName: opponentName) {
                Text(line + (isLive ? " · this week isn’t counted yet" : ""))
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        case .tie: Theme.faint
        }
    }
}

/// Days won per ring: amber you, ink them, grey bars on a tie. Counts only.
struct CompetitionRingDaysPanel: View {
    let counts: [(you: Int, them: Int)]
    let opponentName: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let rings: [(name: String, color: Color)] = [
        ("Move", Theme.move), ("Exercise", Theme.exercise), ("Stand", Theme.stand),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionLabel("EACH RING")
                Spacer(minLength: 8)
                Text("DAYS WON PER RING")
                    .font(.themeLabel)
                    .tracking(1.2)
                    .foregroundStyle(Theme.secondary)
            }
            ForEach(rings.indices, id: \.self) { index in
                row(rings[index], counts[index])
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(rings[index].name): you won \(dayCount(counts[index].you)), \(opponentName) \(counts[index].them)"
                    )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themePanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.person.rings")
    }

    private func dayCount(_ value: Int) -> String { value == 1 ? "1 day" : "\(value) days" }

    // At accessibility sizes the ring's name sits above its bar.
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

// MARK: Records

/// One push from the person page: weekly points as the timeline (drag to
/// pick a week; its row opens the Verdict), then each record once it exists.
struct CompetitionRecordsView: View {
    let publication: LocalCompetitionPublication
    let opponentIdentity: String

    @State private var selection: Date?
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let weeks = competitionRivalryWeeks(publication.dashboard.competitions, opponentIdentity: opponentIdentity)
        let name = weeks.last?.opponentDisplayName ?? ""
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                weeklyPoints(weeks, name: name)
                let records = competitionRivalryRecords(
                    weeks, opponentName: name, now: publication.evaluatedAt, locale: locale
                )
                if !records.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("RECORDS")
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
                    }
                }
            }
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
        let selected = selection.flatMap { date in
            weeks.min { abs(start($0).timeIntervalSince(date)) < abs(start($1).timeIntervalSince(date)) }
        }
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
                    // One element per week, on your point.
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
                .font(.themeLabel)
                .tracking(1.2)
                .foregroundStyle(Theme.secondary)
        }
        .accessibilityHidden(true)
    }

    /// "you 2,040, Sam 2,002, you won".
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
            (Text(competitionPointsText(week.userPoints, locale: locale)).foregroundStyle(Theme.you)
                + Text(" / ").foregroundStyle(Theme.faint)
                + Text(competitionPointsText(week.opponentPoints, locale: locale)).foregroundStyle(Theme.ink))
                .font(.headline.weight(.heavy).width(.condensed).monospacedDigit())
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.tertiary)
        }
        .padding(12)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    // Label then value; at accessibility sizes the value sits under the label.
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
            Text(you).foregroundStyle(Theme.you)
                + Text(" / ").foregroundStyle(Theme.faint)
                + Text(them).foregroundStyle(Theme.ink)
        case let .tally(won, lost, tied):
            Text(String(won)).foregroundStyle(Theme.you)
                + Text("–" + String(lost)).foregroundStyle(Theme.ink)
                + (tied > 0 ? Text("–" + String(tied)).foregroundStyle(Theme.secondary) : Text(""))
        case let .text(text, holder):
            Text(text).foregroundStyle(holder == .you ? Theme.you : Theme.ink)
        }
    }
}

// MARK: What's in play with them

/// The newest finished week while it's on Home and its Verdict hasn't been
/// seen: the page shows it on top and holds the belt and the button for it.
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

/// The one thing in play with them, from Home's own grouping, and its
/// section title. A result counts only while its Verdict is unseen.
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

/// The foot button: "Challenge Sam Again" after a decline or expiry, "Rematch
/// Sam" while the last week is on Home, else "Challenge Sam". Nil while
/// anything is in flight or a Verdict waits, so a rematch can't skip it.
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

/// "Last played Oct 26 – Nov 1 · 5 weeks ago", once it's been two weeks.
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
