import CompetitionCore
import SwiftUI

// MARK: Badges

/// Nine badges, worked out on this phone from your finished 1v1 weeks.
/// Nothing here is sent anywhere.
enum CompetitionBadgeKind: String, CaseIterable, Identifiable, Sendable {
    case sweep, comeback, photoFinish, tripleCrown, defender, fullWeek, hotStreak, collector, rival

    var id: String { rawValue }

    var name: String {
        switch self {
        case .sweep: "Sweep"
        case .comeback: "Comeback"
        case .photoFinish: "Photo finish"
        case .tripleCrown: "Triple crown"
        case .defender: "Defender"
        case .fullWeek: "Full week"
        case .hotStreak: "Hot streak"
        case .collector: "Collector"
        case .rival: "Rival"
        }
    }

    var rule: String {
        switch self {
        case .sweep: "Win all seven days of a week"
        case .comeback: "Win a week you trailed going into the last day"
        case .photoFinish: "Win by fewer than 10 points"
        case .tripleCrown: "Win Move, Exercise and Stand in one week"
        case .defender: "Defend one belt three weeks running"
        case .fullWeek: "Score on every day of a week"
        case .hotStreak: "Win five weeks in a row"
        case .collector: "Hold three belts at once"
        case .rival: "Play ten weeks with one person"
        }
    }

    var symbol: String {
        switch self {
        case .sweep: "checkmark.seal"
        case .comeback: "arrow.uturn.up"
        case .photoFinish: "flag.checkered"
        case .tripleCrown: "crown"
        case .defender: "shield"
        case .fullWeek: "calendar"
        case .hotStreak: "flame"
        case .collector: "square.stack.3d.up"
        case .rival: "person.2"
        }
    }

    /// What the ones you build toward need; nil for a single week's feat.
    var goal: Int? {
        switch self {
        case .defender, .collector: 3
        case .hotStreak: 5
        case .rival: 10
        case .sweep, .comeback, .photoFinish, .tripleCrown, .fullWeek: nil
        }
    }
}

struct CompetitionBadge: Equatable, Identifiable {
    let kind: CompetitionBadgeKind
    var count = 0
    /// The newest week that earned it.
    var latest: CompetitionID?
    /// The closest you have come to `kind.goal`.
    var progress = 0

    var id: String { kind.rawValue }
    var isEarned: Bool { count > 0 }

    /// "×3" once earned; "2 OF 3", "BEST 4" or "NOT YET" before.
    var countText: String {
        if isEarned { return "×\(count)" }
        guard let goal = kind.goal else { return "NOT YET" }
        return kind == .hotStreak ? "BEST \(progress)" : "\(min(progress, goal)) OF \(goal)"
    }

    /// "Sweep, earned 3 times. Win all seven days of a week."
    var accessibilityText: String {
        let state: String
        if isEarned {
            state = "earned \(competitionTimesText(count))"
        } else if let goal = kind.goal {
            state = kind == .hotStreak ? "not yet, best \(progress)" : "not yet, \(min(progress, goal)) of \(goal)"
        } else {
            state = "not yet"
        }
        return "\(kind.name), \(state). \(kind.rule)."
    }
}

func competitionTimesText(_ count: Int) -> String {
    switch count {
    case 1: "once"
    case 2: "twice"
    default: "\(count) times"
    }
}

struct CompetitionBadgeBook: Equatable {
    /// Every kind: the earned ones first, each group in its fixed order.
    var badges: [CompetitionBadge] = []
    /// What each week earned, without Full week, which most weeks earn.
    var byWeek: [CompetitionID: [CompetitionBadgeKind]] = [:]
}

func competitionBadgeBook(_ competitions: [LocalCompetitionPresentation]) -> CompetitionBadgeBook {
    struct Pair {
        var weeks = 0
        var youHold = false
        var defenses = 0
    }
    var found: [CompetitionBadgeKind: CompetitionBadge] = [:]
    var byWeek: [CompetitionID: [CompetitionBadgeKind]] = [:]
    func earn(_ kind: CompetitionBadgeKind, _ week: LocalCompetitionPresentation) {
        found[kind, default: CompetitionBadge(kind: kind)].count += 1
        found[kind]?.latest = week.id
        if kind != .fullWeek { byWeek[week.id, default: []].append(kind) }
    }
    func reach(_ kind: CompetitionBadgeKind, _ value: Int) {
        let best = max(found[kind]?.progress ?? 0, value)
        found[kind, default: CompetitionBadge(kind: kind)].progress = best
    }

    var streak = 0
    var held = 0
    var pairs: [String: Pair] = [:]
    for week in competitionHistoryWeeks(competitions).reversed() {
        guard let result = week.terminalResult else { continue }
        let days = week.days.sorted { $0.ordinal < $1.ordinal }
        let won = result.outcome == .win

        if days.count == 7, days.allSatisfy({ ($0.ownerAcceptedPoints ?? 0) > 0 }) {
            earn(.fullWeek, week)
        }
        if won {
            if competitionDayOutcomes(week) == Array(repeating: CompetitionOutcome.win, count: 7) {
                earn(.sweep, week)
            }
            let beforeLastDay = days.filter { $0.ordinal < 7 }.reduce(0.0) {
                $0 + ($1.ownerAcceptedPoints ?? 0) - ($1.opponentRevealedPoints ?? 0)
            }
            if days.count == 7, beforeLastDay < 0 { earn(.comeback, week) }
            if result.userPoints - result.opponentPoints < 10 { earn(.photoFinish, week) }
            if let split = competitionRingSplit(week.days), zip(split.you, split.them).allSatisfy({ $0 > $1 }) {
                earn(.tripleCrown, week)
            }
        }

        streak = won ? streak + 1 : 0
        if streak == 5 { earn(.hotStreak, week) }
        reach(.hotStreak, streak)

        var pair = pairs[week.opponentIdentity] ?? Pair()
        pair.weeks += 1
        if pair.weeks == 10 { earn(.rival, week) }
        reach(.rival, pair.weeks)
        // A deleted account's belt is retired, so it never counts as held.
        if week.opponentDisplayName != competitionFormerCompetitorName {
            switch result.outcome {
            case .win where pair.youHold:
                pair.defenses += 1
                if pair.defenses == 3 { earn(.defender, week) }
            case .win:
                pair.youHold = true
                pair.defenses = 0
            case .loss:
                pair.youHold = false
                pair.defenses = 0
            case .tie:
                break
            }
            reach(.defender, pair.defenses)
        }
        pairs[week.opponentIdentity] = pair

        let nowHeld = pairs.values.filter(\.youHold).count
        if nowHeld >= 3, held < 3 { earn(.collector, week) }
        reach(.collector, nowHeld)
        held = nowHeld
    }

    let all = CompetitionBadgeKind.allCases.map { found[$0] ?? CompetitionBadge(kind: $0) }
    return CompetitionBadgeBook(badges: all.filter(\.isEarned) + all.filter { !$0.isEarned }, byWeek: byWeek)
}

/// A week's seven days as you saw them, in order, by the same rule as the
/// strip and the result (`competitionDayOutcome`); nil where a day has no data.
func competitionDayOutcomes(_ week: LocalCompetitionPresentation) -> [CompetitionOutcome?] {
    week.days.sorted { $0.ordinal < $1.ordinal }.map { day in
        switch competitionDayOutcome(day, currentDayOrdinal: nil) {
        case .won: .win
        case .lost: .loss
        case .tied: .tie
        case .today, .upcoming, .noData: nil
        }
    }
}

/// "beat Sam", "lost to Sam" or "tied with Sam".
func competitionWeekVersusText(_ week: LocalCompetitionPresentation) -> String {
    switch week.terminalResult?.outcome {
    case .win: "beat \(week.opponentDisplayName)"
    case .loss: "lost to \(week.opponentDisplayName)"
    case .tie, nil: "tied with \(week.opponentDisplayName)"
    }
}

// MARK: History filter

enum CompetitionWeekFilter: String, CaseIterable, Identifiable {
    case all, won, lost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .won: "Won"
        case .lost: "Lost"
        }
    }
}

/// History's weeks under its filter and, with `person`, with that one person.
func competitionFilteredWeeks(
    _ weeks: [LocalCompetitionPresentation],
    filter: CompetitionWeekFilter,
    person: String?
) -> [LocalCompetitionPresentation] {
    weeks.filter { week in
        guard person == nil || week.opponentIdentity == person else { return false }
        switch filter {
        case .all: return true
        case .won: return week.terminalResult?.outcome == .win
        case .lost: return week.terminalResult?.outcome == .loss
        }
    }
}

// MARK: Your records

struct CompetitionOwnRecord: Equatable, Identifiable {
    let label: String
    let value: String
    let detail: String
    /// The week it happened in, which the row opens.
    var weekID: CompetitionID?
    /// 0 Move, 1 Exercise, 2 Stand.
    var ring: Int?

    var id: String { label }
}

struct CompetitionOwnRecordSection: Equatable, Identifiable {
    let title: String
    let rows: [CompetitionOwnRecord]

    var id: String { title }
}

/// Your bests across everyone: scoring, streaks, then each ring's best day.
/// Weeks are finished and oldest first; a section with nothing to say is left out.
func competitionOwnRecordSections(
    _ weeks: [LocalCompetitionPresentation],
    now: Date,
    locale: Locale = .current
) -> [CompetitionOwnRecordSection] {
    func points(_ value: Double) -> String { competitionPointsText(value, locale: locale) }
    func range(_ week: LocalCompetitionPresentation) -> String {
        week.acceptedConfiguration.flatMap {
            competitionScheduleDateRangeText($0.schedule, now: now, locale: locale)
        } ?? ""
    }
    func date(_ day: LocalCompetitionDayPresentation) -> String {
        competitionDayText(day.day, now: now, locale: locale)
    }
    func margin(_ week: LocalCompetitionPresentation) -> Double {
        (week.terminalResult?.userPoints ?? 0) - (week.terminalResult?.opponentPoints ?? 0)
    }
    // >=: on a tie the later one holds it.
    func best<T>(_ items: [T], _ value: (T) -> Double) -> T? {
        items.reduce(T?.none) { held, item in
            held.map { value(item) >= value($0) ? item : $0 } ?? item
        }
    }
    let days = weeks.flatMap { week in
        week.days.sorted { $0.ordinal < $1.ordinal }.map { (week: week, day: $0) }
    }

    var scoring: [CompetitionOwnRecord] = []
    if let week = best(weeks, \.userPoints) {
        scoring.append(.init(
            label: "Best week", value: points(week.userPoints),
            detail: "\(range(week)) · \(competitionWeekVersusText(week))", weekID: week.id
        ))
    }
    if let top = best(days.filter { $0.day.ownerAcceptedPoints != nil }, { $0.day.ownerAcceptedPoints ?? 0 }) {
        scoring.append(.init(
            label: "Best day", value: points(top.day.ownerAcceptedPoints ?? 0),
            detail: date(top.day), weekID: top.week.id
        ))
    }
    let wins = weeks.filter { $0.terminalResult?.outcome == .win }
    if let week = best(wins, margin) {
        scoring.append(.init(
            label: "Biggest win", value: "+\(points(margin(week)))",
            detail: "\(range(week)) · \(competitionWeekVersusText(week))", weekID: week.id
        ))
    }
    if wins.count > 1, let week = best(wins, { -margin($0) }) {
        scoring.append(.init(
            label: "Closest win", value: "+\(points(margin(week)))",
            detail: "\(range(week)) · \(competitionWeekVersusText(week))", weekID: week.id
        ))
    }

    var streaks: [CompetitionOwnRecord] = []
    var run = 0
    var longest: (count: Int, last: Int) = (0, 0)
    for (index, week) in weeks.enumerated() {
        run = week.terminalResult?.outcome == .win ? run + 1 : 0
        if run > 0, run >= longest.count { longest = (run, index) }
    }
    if longest.count > 1 {
        let last = weeks[longest.last]
        streaks.append(.init(
            label: "Weeks won in a row", value: String(longest.count),
            detail: longest.last == weeks.count - 1 ? "Still going" : "Ended \(range(last))", weekID: last.id
        ))
    }
    run = 0
    longest = (0, 0)
    for (index, entry) in days.enumerated() {
        let you = entry.day.ownerAcceptedPoints, them = entry.day.opponentRevealedPoints
        run = (you ?? 0) > (them ?? .infinity) ? run + 1 : 0
        if run > 0, run >= longest.count { longest = (run, index) }
    }
    if longest.count > 1 {
        let last = days[longest.last]
        streaks.append(.init(
            label: "Days won in a row", value: String(longest.count),
            detail: "Ended \(date(last.day))", weekID: last.week.id
        ))
    }
    if let record = best(competitionOpponentRecords(weeks), { Double($0.belt.you.longestReign) }),
       record.belt.you.longestReign > 0 {
        streaks.append(.init(
            label: "Longest belt run", value: String(record.belt.you.longestReign),
            detail: "Weeks holding it against \(record.opponentDisplayName)"
        ))
    }

    let ringed = days.filter { $0.day.ownerAcceptedPoints != nil && $0.day.ownerRingPoints?.count == 3 }
    let rings = ["Move", "Exercise", "Stand"].enumerated().compactMap { ring, name -> CompetitionOwnRecord? in
        guard let top = best(ringed, { $0.day.ownerRingPoints?[ring] ?? 0 }) else { return nil }
        return CompetitionOwnRecord(
            label: name, value: points(top.day.ownerRingPoints?[ring] ?? 0),
            detail: date(top.day), weekID: top.week.id, ring: ring
        )
    }

    return [
        CompetitionOwnRecordSection(title: "SCORING", rows: scoring),
        CompetitionOwnRecordSection(title: "STREAKS", rows: streaks),
        CompetitionOwnRecordSection(title: "EACH RING · BEST DAY", rows: rings),
    ].filter { !$0.rows.isEmpty }
}

// MARK: Badge views

/// Amber once earned, an outline until then.
struct CompetitionBadgePlate: View {
    let kind: CompetitionBadgeKind
    let isEarned: Bool
    var size: CGFloat = 46

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(isEarned ? Theme.onYouFill : Theme.tertiary)
            .frame(width: size, height: size)
            .background {
                if isEarned {
                    Circle().fill(Theme.youFill)
                } else {
                    Circle().strokeBorder(Theme.outline, lineWidth: 1.5)
                }
            }
            .accessibilityHidden(true)
    }
}

/// A badge's name on a History row.
struct CompetitionBadgeTag: View {
    let name: String

    @Environment(\.locale) private var locale

    var body: some View {
        Text(name.uppercased(with: locale))
            .themeLabel(tracking: 1)
            .foregroundStyle(Theme.onYouFill)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.youFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Seven marks, one per day, as the week strip draws them: amber a day you
/// won, ink one you lost, grey a tie, the stripe for a day without data.
struct CompetitionDayMarks: View {
    let outcomes: [CompetitionOutcome?]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(outcomes.indices, id: \.self) { index in
                switch outcomes[index] {
                case .win: SlantedBar().fill(Theme.youFill)
                case .loss: SlantedBar().fill(Theme.ink)
                case .tie: SlantedBar().fill(Theme.tertiary)
                case nil: HatchBar()
                }
            }
            .frame(width: 7, height: 10)
        }
        .accessibilityHidden(true)
    }
}

/// The profile's row: the first five badges, earned ones first.
struct CompetitionBadgesRow: View {
    let badges: [CompetitionBadge]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .headline) private var plateSize: CGFloat = 46

    var body: some View {
        let earned = badges.filter(\.isEarned).count
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionLabel("BADGES · \(earned)")
                Spacer(minLength: 8)
                CompetitionAllLabel()
            }
            .padding(.horizontal, 4)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Text("\(earned) of \(badges.count) earned")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(alignment: .top, spacing: 4) {
                        ForEach(badges.prefix(5)) { badge in
                            VStack(spacing: 6) {
                                CompetitionBadgePlate(kind: badge.kind, isEarned: badge.isEarned, size: min(plateSize, 56))
                                Text(badge.kind.name)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(badge.countText)
                                    .font(.themeLabel.monospacedDigit())
                                    .foregroundStyle(Theme.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .themePanel()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Badges, \(earned) of \(badges.count) earned")
        .accessibilityHint("Opens your badges")
    }
}

/// "ALL ›" at the end of a section header that opens a page.
struct CompetitionAllLabel: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("ALL")
                .themeLabel()
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(Theme.secondary)
    }
}

/// Every badge: what earns it, how often you have, and how close you are.
/// A tap opens its sheet, and the sheet opens the latest week that earned it.
struct CompetitionBadgesView: View {
    let publication: LocalCompetitionPublication
    /// Pushes a finished week, once the sheet has closed.
    let openWeek: (CompetitionID) -> Void

    @State private var shown: CompetitionBadge?
    @State private var pendingWeek: CompetitionID?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .headline) private var plateSize: CGFloat = 56

    var body: some View {
        let competitions = publication.dashboard.competitions
        let book = competitionBadgeBook(competitions)
        let columns = dynamicTypeSize.isAccessibilitySize ? 1 : 3
        let rows = stride(from: 0, to: book.badges.count, by: columns).map {
            Array(book.badges[$0..<min($0 + columns, book.badges.count)])
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SectionLabel("EARNED")
                    Spacer(minLength: 8)
                    Text("\(book.badges.filter(\.isEarned).count) OF \(book.badges.count)")
                        .themeLabel()
                        .foregroundStyle(Theme.secondary)
                        .accessibilityIdentifier("competition.badges.count")
                }
                .padding(.horizontal, 4)
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(rows.indices, id: \.self) { index in
                        GridRow {
                            ForEach(rows[index]) { badge in
                                Button { shown = badge } label: { card(badge) }
                                    .buttonStyle(CompetitionPressButtonStyle())
                                    .accessibilityLabel(badge.accessibilityText)
                                    .accessibilityIdentifier("competition.badge.\(badge.kind.rawValue)")
                            }
                        }
                    }
                }
                Text("Badges come from your finished 1v1 weeks. Only you see them.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.ground)
        .navigationTitle("Badges")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("competition.badges")
        .sheet(item: $shown, onDismiss: {
            if let week = pendingWeek {
                pendingWeek = nil
                openWeek(week)
            }
        }) { badge in
            CompetitionBadgeSheet(
                badge: badge,
                week: competitions.first { $0.id == badge.latest },
                now: publication.evaluatedAt,
                open: {
                    pendingWeek = $0
                    shown = nil
                }
            )
            .presentationDetents([.medium, .large])
        }
    }

    private func card(_ badge: CompetitionBadge) -> some View {
        VStack(spacing: 8) {
            CompetitionBadgePlate(kind: badge.kind, isEarned: badge.isEarned, size: min(plateSize, 72))
            Text(badge.kind.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text(badge.kind.rule)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .frame(maxHeight: .infinity, alignment: .top)
            Text(badge.countText)
                .font(.themeLabel.monospacedDigit())
                .tracking(0.6)
                .foregroundStyle(badge.isEarned ? Theme.ink : Theme.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .themePanel()
        .contentShape(Rectangle())
    }
}

/// One badge: its rule, how often you earned it, and the latest week.
struct CompetitionBadgeSheet: View {
    let badge: CompetitionBadge
    /// The latest week that earned it, while that week is still on this phone.
    let week: LocalCompetitionPresentation?
    let now: Date
    let open: (CompetitionID) -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                CompetitionBadgePlate(kind: badge.kind, isEarned: badge.isEarned, size: 72)
                Text(badge.kind.name)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(badge.kind.rule)
                    .font(.body)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(badge.isEarned ? "EARNED \(competitionTimesText(badge.count).uppercased(with: locale))" : badge.countText)
                    .font(.themeLabel.monospacedDigit())
                    .tracking(1.2)
                    .foregroundStyle(Theme.secondary)
                    .accessibilityIdentifier("competition.badge.earned")
                if let week {
                    Button { open(week.id) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Latest")
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.secondary)
                                Text(latestText(week))
                                    .font(.headline)
                                    .foregroundStyle(Theme.ink)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 8)
                            DisclosureChevron()
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .themePanel()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CompetitionPressButtonStyle())
                    .accessibilityHint("Opens that week")
                    .accessibilityIdentifier("competition.badge.latest")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 20)
        }
        .background(Theme.ground)
        .accessibilityIdentifier("competition.badge.sheet")
    }

    private func latestText(_ week: LocalCompetitionPresentation) -> String {
        let range = week.acceptedConfiguration.flatMap {
            competitionScheduleDateRangeText($0.schedule, now: now, locale: locale)
        }
        return [range, competitionWeekVersusText(week)].compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: Your records view

/// One push from your profile: your bests across everyone. A row with a
/// week behind it opens that week. With weeks from before this year, a
/// year / All time picker filters them all.
struct CompetitionOwnRecordsView: View {
    let publication: LocalCompetitionPublication

    @State private var showsAllTime = false
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .title2) private var valueSize: CGFloat = 25

    var body: some View {
        let all = Array(competitionHistoryWeeks(publication.dashboard.competitions).reversed())
        let thisYear = competitionYearWeeks(all, now: publication.evaluatedAt).flatMap {
            $0.weeks.count < all.count ? $0 : nil
        }
        let weeks = showsAllTime ? all : thisYear?.weeks ?? all
        let sections = competitionOwnRecordSections(weeks, now: publication.evaluatedAt, locale: locale)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let thisYear {
                    CompetitionSegments(
                        selection: $showsAllTime, options: [(false, String(thisYear.year)), (true, "All time")]
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Records from")
                    .accessibilityIdentifier("competition.ownRecords.year")
                }
                if sections.isEmpty {
                    Text("Finished matches appear here.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(section.title)
                            .padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, record in
                                if index > 0 {
                                    CompetitionRowDivider(inset: 16)
                                }
                                row(record)
                            }
                        }
                        .themePanel()
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
            }
            .moving(Motion.settle, value: showsAllTime)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.ground)
        .navigationTitle("Records")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("competition.ownRecords")
    }

    @ViewBuilder
    private func row(_ record: CompetitionOwnRecord) -> some View {
        let identifier = "competition.ownRecords.\(record.label.lowercased().replacingOccurrences(of: " ", with: "-"))"
        if let weekID = record.weekID {
            NavigationLink(value: CompetitionHomeRoute.competition(weekID)) {
                content(record, opens: true)
            }
            .buttonStyle(CompetitionRowButtonStyle())
            .accessibilityLabel("\(record.label): \(record.value). \(record.detail)")
            .accessibilityHint("Opens that week")
            .accessibilityIdentifier(identifier)
        } else {
            content(record, opens: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(record.label): \(record.value). \(record.detail)")
                .accessibilityIdentifier(identifier)
        }
    }

    private func content(_ record: CompetitionOwnRecord, opens: Bool) -> some View {
        HStack(spacing: 10) {
            if let ring = record.ring {
                SlantedBar()
                    .fill([Theme.move, Theme.exercise, Theme.stand][ring])
                    .frame(width: 5, height: 14)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(record.label)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text(record.detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Text(record.value)
                .font(.score(size: valueSize).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            DisclosureChevron()
                .opacity(opens ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .contentShape(Rectangle())
    }
}
