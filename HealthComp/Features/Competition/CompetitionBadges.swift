import CompetitionCore
import SwiftUI

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
    var latest: CompetitionID?
    var progress = 0

    var id: String { kind.rawValue }
    var isEarned: Bool { count > 0 }

    var countText: String {
        if isEarned { return "×\(count)" }
        guard let goal = kind.goal else { return "NOT YET" }
        return kind == .hotStreak ? "BEST \(progress)" : "\(min(progress, goal)) OF \(goal)"
    }

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
    var badges: [CompetitionBadge] = []
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

func competitionWeekVersusText(_ week: LocalCompetitionPresentation) -> String {
    switch week.terminalResult?.outcome {
    case .win: "beat \(week.opponentDisplayName)"
    case .loss: "lost to \(week.opponentDisplayName)"
    case .tie, nil: "tied with \(week.opponentDisplayName)"
    }
}

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

struct CompetitionOwnRecord: Equatable, Identifiable {
    let label: String
    let value: String
    let detail: String
    var weekID: CompetitionID?
    var ring: Int?

    var id: String { label }
}

struct CompetitionOwnRecordSection: Equatable, Identifiable {
    let title: String
    let rows: [CompetitionOwnRecord]

    var id: String { title }
}

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
    func best<T>(_ items: [T], _ value: (T) -> Double) -> T? {
        items.reduce(T?.none) { held, item in
            held.map { value(item) >= value($0) ? item : $0 } ?? item
        }
    }
    let standardWeeks = weeks.filter(\.metrics.isDefaultRings)
    let standardDays = standardWeeks.flatMap { week in
        week.days.sorted { $0.ordinal < $1.ordinal }.map { (week: week, day: $0) }
    }
    let days = weeks.flatMap { week in
        week.days.sorted { $0.ordinal < $1.ordinal }.map { (week: week, day: $0) }
    }

    var scoring: [CompetitionOwnRecord] = []
    if let week = best(standardWeeks, \.userPoints) {
        scoring.append(.init(
            label: "Best week", value: points(week.userPoints),
            detail: "\(range(week)) · \(competitionWeekVersusText(week))", weekID: week.id
        ))
    }
    if let top = best(standardDays.filter { $0.day.ownerAcceptedPoints != nil }, { $0.day.ownerAcceptedPoints ?? 0 }) {
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

struct CompetitionBadgePlate: View {
    let kind: CompetitionBadgeKind
    let isEarned: Bool
    var size: CGFloat = 46

    var body: some View {
        CompetitionMedal(art: .badge(kind), isEarned: isEarned, size: size)
    }
}

struct CompetitionBadgeTag: View {
    let name: String

    @Environment(\.locale) private var locale

    var body: some View {
        Text(name.uppercased(with: locale))
            .themeLabel(tracking: 1)
            .foregroundStyle(Theme.onYouFill)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.youFill, in: RoundedRectangle(cornerRadius: 6))
    }
}

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

struct CompetitionRivalTrophy: Equatable, Identifiable {
    let opponentIdentity: String
    let opponentDisplayName: String
    let wins: Int
    let losses: Int
    let ties: Int
    let latestWin: CompetitionID
    let latestWeek: LocalCompetitionPresentation
    let holdsBelt: Bool

    var id: String { opponentIdentity }

    var recordText: String {
        ([wins, losses] + (ties > 0 ? [ties] : [])).map(String.init).joined(separator: "–")
    }
}

func competitionRivalTrophies(
    _ competitions: [LocalCompetitionPresentation]
) -> [CompetitionRivalTrophy] {
    let records = competitionOpponentRecords(competitions)
    var trophies: [CompetitionRivalTrophy] = []
    for record in records where record.wins > 0
        && record.opponentDisplayName != competitionFormerCompetitorName {
        let wins = competitionHistoryWeeks(competitions).filter {
            $0.opponentIdentity == record.opponentIdentity && $0.terminalResult?.outcome == .win
        }
        guard let latest = wins.first else { continue }
        trophies.append(CompetitionRivalTrophy(
            opponentIdentity: record.opponentIdentity,
            opponentDisplayName: record.opponentDisplayName,
            wins: record.wins,
            losses: record.losses,
            ties: record.ties,
            latestWin: latest.id,
            latestWeek: latest,
            holdsBelt: record.belt.holder == .you
        ))
    }
    return trophies.sorted { lhs, rhs in
        if lhs.wins != rhs.wins { return lhs.wins > rhs.wins }
        return lhs.opponentDisplayName.localizedStandardCompare(rhs.opponentDisplayName) == .orderedAscending
    }
}

struct CompetitionChampionshipPlate: View {
    let art: CompetitionMedalArt
    let title: String
    let subtitle: String
    let engravedKicker: String
    let engravedHeadline: String
    let engravedDetail: String
    let isEarned: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0
    @State private var dragStart: Double?
    @State private var flipCount = 0

    private var isShowingBack: Bool {
        let normalized = angle.truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        return positive >= 90 && positive < 270
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                if reduceMotion {
                    if isShowingBack {
                        backFace
                    } else {
                        frontFace
                    }
                } else {
                    ZStack {
                        frontFace
                            .opacity(isShowingBack ? 0 : 1)
                        backFace
                            .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                            .opacity(isShowingBack ? 1 : 0)
                    }
                    .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
                }
            }
            .frame(width: 176, height: 176)
            .contentShape(Rectangle())
            .onTapGesture {
                guard isEarned else { return }
                toggleFlip()
            }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard isEarned, !reduceMotion else { return }
                        let base = dragStart ?? angle
                        if dragStart == nil { dragStart = angle }
                        angle = base + Double(value.translation.width) * 0.85
                    }
                    .onEnded { value in
                        guard isEarned, !reduceMotion else { return }
                        let base = dragStart ?? angle
                        dragStart = nil
                        let projected = base + Double(value.predictedEndTranslation.width) * 0.65
                        let snapped = (projected / 180).rounded() * 180
                        angle = snapped
                        flipCount += 1
                    }
            )
            .moving(Motion.settle, value: angle)
            .animation(Motion.fade, value: isShowingBack)
            .sensoryFeedback(.impact(weight: .light), trigger: flipCount)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(isEarned ? .isButton : [])
            .accessibilityLabel(
                isShowingBack
                    ? "\(title) reverse engraved: \(engravedHeadline). \(engravedDetail)."
                    : "\(title), \(subtitle)."
            )
            .accessibilityHint(isEarned ? "Double tap to flip plate" : "")
            .accessibilityIdentifier("competition.plate.3d")

            if isEarned {
                Text(isShowingBack ? "ENGRAVED REVERSE · TAP TO FLIP" : "DRAG OR TAP TO INSPECT REVERSE")
                    .font(.caption2.weight(.bold).width(.condensed))
                    .tracking(1.0)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 14)
        .background(Theme.beltWell, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func toggleFlip() {
        angle += 180
        flipCount += 1
    }

    private var frontFace: some View {
        CompetitionMedal(art: art, isEarned: isEarned, size: 176)
            .environment(\.colorScheme, .dark)
    }

    private var backFace: some View {
        CompetitionMedalBack(
            family: art.family,
            kicker: engravedKicker,
            headline: engravedHeadline,
            detail: engravedDetail
        )
    }
}

struct CompetitionBadgesView: View {
    let publication: LocalCompetitionPublication
    let openWeek: (CompetitionID) -> Void

    @State private var shown: CompetitionBadge?
    @State private var shownRival: CompetitionRivalTrophy?
    @State private var pendingWeek: CompetitionID?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .headline) private var medalSize: CGFloat = 80

    var body: some View {
        let competitions = publication.dashboard.competitions
        let book = competitionBadgeBook(competitions)
        let rivals = competitionRivalTrophies(competitions)
        let earned = book.badges.filter(\.isEarned)
        let notYet = book.badges.filter { !$0.isEarned }
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("EARNED", count: "\(earned.count) OF \(book.badges.count)", countIdentifier: "competition.badges.count") {
                    if earned.isEmpty {
                        Text("Win a week to earn your first badge.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 4)
                    } else {
                        grid(earned) { badgeButton($0) }
                    }
                }

                if !rivals.isEmpty {
                    section("RIVAL TROPHIES", count: "\(rivals.count)") {
                        grid(rivals) { trophy in
                            Button { shownRival = trophy } label: {
                                medalCell(
                                    art: .rival(initial: competitionMedalInitial(trophy.opponentDisplayName)),
                                    isEarned: true,
                                    name: trophy.opponentDisplayName,
                                    count: "×\(trophy.wins)"
                                )
                            }
                            .buttonStyle(CompetitionPressButtonStyle())
                            .accessibilityLabel(
                                "Victory over \(trophy.opponentDisplayName), \(competitionTimesText(trophy.wins)). Record \(trophy.recordText)."
                            )
                            .accessibilityIdentifier("competition.badge.rival.\(trophy.opponentIdentity)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("competition.badges.rivals")
                }

                if !notYet.isEmpty {
                    section("NOT YET", count: "\(notYet.count)") {
                        grid(notYet) { badgeButton($0) }
                    }
                }
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
            .presentationDetents([.large])
        }
        .sheet(item: $shownRival, onDismiss: {
            if let week = pendingWeek {
                pendingWeek = nil
                openWeek(week)
            }
        }) { trophy in
            CompetitionRivalTrophySheet(
                trophy: trophy,
                now: publication.evaluatedAt,
                open: {
                    pendingWeek = $0
                    shownRival = nil
                }
            )
            .presentationDetents([.large])
        }
    }

    private func section<Content: View>(
        _ title: String,
        count: String,
        countIdentifier: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionLabel(title)
                Spacer(minLength: 8)
                Text(count)
                    .themeLabel()
                    .foregroundStyle(Theme.secondary)
                    .accessibilityIdentifier(countIdentifier ?? "")
            }
            .padding(.horizontal, 4)
            content()
        }
    }

    private func grid<Item: Identifiable, Cell: View>(
        _ items: [Item],
        @ViewBuilder cell: @escaping (Item) -> Cell
    ) -> some View {
        let columns = dynamicTypeSize.isAccessibilitySize ? 1 : 3
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        return Grid(alignment: .top, horizontalSpacing: 8, verticalSpacing: 22) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    ForEach(rows[index]) { cell($0) }
                    ForEach(rows[index].count..<columns, id: \.self) { _ in
                        Color.clear.gridCellUnsizedAxes(.vertical)
                    }
                }
            }
        }
    }

    private func badgeButton(_ badge: CompetitionBadge) -> some View {
        Button { shown = badge } label: {
            medalCell(art: .badge(badge.kind), isEarned: badge.isEarned, name: badge.kind.name, count: badge.countText)
        }
        .buttonStyle(CompetitionPressButtonStyle())
        .accessibilityLabel(badge.accessibilityText)
        .accessibilityIdentifier("competition.badge.\(badge.kind.rawValue)")
    }

    private func medalCell(art: CompetitionMedalArt, isEarned: Bool, name: String, count: String) -> some View {
        VStack(spacing: 6) {
            CompetitionMedal(art: art, isEarned: isEarned, size: min(medalSize, 104))
                .padding(.bottom, 2)
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isEarned ? Theme.ink : Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(count)
                .font(.themeLabel.monospacedDigit())
                .tracking(0.6)
                .foregroundStyle(isEarned ? Theme.you : Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .contentShape(Rectangle())
    }
}

struct CompetitionBadgeSheet: View {
    let badge: CompetitionBadge
    let week: LocalCompetitionPresentation?
    let now: Date
    let open: (CompetitionID) -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                CompetitionChampionshipPlate(
                    art: .badge(badge.kind),
                    title: badge.kind.name,
                    subtitle: badge.isEarned ? "Earned \(badge.countText)" : badge.countText,
                    engravedKicker: "Engraved · HealthComp",
                    engravedHeadline: engravedHeadline,
                    engravedDetail: engravedDetail,
                    isEarned: badge.isEarned
                )
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
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
        .background(Theme.ground)
        .accessibilityIdentifier("competition.badge.sheet")
    }

    private var engravedHeadline: String {
        guard let week else { return badge.kind.name }
        let margin = competitionPointsText(abs(week.userPoints - week.opponentPoints), locale: locale)
        return "\(badge.kind.name) · +\(margin) vs \(week.opponentDisplayName)"
    }

    private var engravedDetail: String {
        guard let week else { return badge.kind.rule }
        let range = week.acceptedConfiguration.flatMap {
            competitionScheduleDateRangeText($0.schedule, now: now, locale: locale)
        } ?? ""
        return "\(competitionPointsText(week.userPoints, locale: locale))–\(competitionPointsText(week.opponentPoints, locale: locale)) · \(range)"
    }

    private func latestText(_ week: LocalCompetitionPresentation) -> String {
        let range = week.acceptedConfiguration.flatMap {
            competitionScheduleDateRangeText($0.schedule, now: now, locale: locale)
        }
        return [range, competitionWeekVersusText(week)].compactMap { $0 }.joined(separator: ", ")
    }
}

struct CompetitionRivalTrophySheet: View {
    let trophy: CompetitionRivalTrophy
    let now: Date
    let open: (CompetitionID) -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        let range = trophy.latestWeek.acceptedConfiguration.flatMap {
            competitionScheduleDateRangeText($0.schedule, now: now, locale: locale)
        } ?? ""
        ScrollView {
            VStack(spacing: 14) {
                CompetitionChampionshipPlate(
                    art: .rival(initial: competitionMedalInitial(trophy.opponentDisplayName)),
                    title: "vs \(trophy.opponentDisplayName)",
                    subtitle: "Rival Plate ×\(trophy.wins)",
                    engravedKicker: "Rivalry Record · \(trophy.recordText)",
                    engravedHeadline: "\(competitionOrdinalText(trophy.wins)) win over \(trophy.opponentDisplayName)",
                    engravedDetail: "Latest · \(range)",
                    isEarned: true
                )
                Text("Victory over \(trophy.opponentDisplayName)")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Earn this plate each time you win a seven-day match against \(trophy.opponentDisplayName).")
                    .font(.body)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button { open(trophy.latestWin) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Latest win")
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondary)
                            Text("\(range) · \(competitionPointsText(trophy.latestWeek.userPoints, locale: locale))–\(competitionPointsText(trophy.latestWeek.opponentPoints, locale: locale))")
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
                .accessibilityIdentifier("competition.rivalTrophy.latest")
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
        .background(Theme.ground)
        .accessibilityIdentifier("competition.rivalTrophy.sheet")
    }
}

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
                CompetitionFormCard(competitions: publication.dashboard.competitions)
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
                        .clipShape(RoundedRectangle(cornerRadius: 20))
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
        let identifier = "competition.ownRecords.\(record.label.lowercased().replacing(" ", with: "-"))"
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

enum CompetitionMedalFamily: Equatable {
    case weekly, reign, rival
}

enum CompetitionMedalArt: Equatable {
    case badge(CompetitionBadgeKind)
    case rival(initial: String)

    var family: CompetitionMedalFamily {
        switch self {
        case .badge(let kind): kind.medalFamily
        case .rival: .rival
        }
    }
}

extension CompetitionBadgeKind {
    var medalFamily: CompetitionMedalFamily {
        switch self {
        case .sweep, .comeback, .photoFinish, .tripleCrown, .fullWeek: .weekly
        case .defender, .hotStreak, .collector, .rival: .reign
        }
    }
}

func competitionMedalInitial(_ name: String) -> String {
    name.first.map { String($0).uppercased() } ?? "?"
}

struct CompetitionMedal: View {
    let art: CompetitionMedalArt
    let isEarned: Bool
    var size: CGFloat = 80

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let finish: MedalFinish = isEarned ? .earned : colorScheme == .dark ? .lockedDark : .locked
        Canvas { context, canvas in
            context.scaleBy(x: canvas.width / 120, y: canvas.height / 120)
            MedalPainter(finish: finish).front(art, in: &context)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct CompetitionMedalBack: View {
    let family: CompetitionMedalFamily
    let kicker: String
    let headline: String
    let detail: String
    var size: CGFloat = 176

    @Environment(\.locale) private var locale

    var body: some View {
        let top: CGFloat = family == .reign ? 30 : 36
        ZStack(alignment: .top) {
            Canvas { context, canvas in
                context.scaleBy(x: canvas.width / 120, y: canvas.height / 120)
                MedalPainter(finish: .earned).back(family, in: &context)
            }
            VStack(spacing: size * 0.012) {
                engraved(kicker, size: 0.05, weight: .heavy)
                engraved(headline, size: 0.075, weight: .heavy, lines: 2)
                engraved(detail, size: 0.05, weight: .bold, lines: 2)
            }
            .multilineTextAlignment(.center)
            .frame(width: size * (family == .reign ? 0.5 : 0.58))
            .padding(.top, size * top / 120)
        }
        .frame(width: size, height: size)
    }

    private func engraved(_ text: String, size scale: CGFloat, weight: Font.Weight, lines: Int = 1) -> some View {
        Text(text.uppercased(with: locale))
            .font(.system(size: size * scale, weight: weight).width(.condensed))
            .tracking(0.4)
            .foregroundStyle(Color(hex: 0x6E4706))
            .shadow(color: Color(hex: 0xFCE9B4).opacity(0.8), radius: 0, y: size * 0.006)
            .lineLimit(lines)
            .minimumScaleFactor(0.7)
    }
}

private enum MedalFinish {
    case earned, locked, lockedDark

    var markUnder: Color {
        switch self {
        case .earned: Color(hex: 0x211F1C)
        case .locked: Color(hex: 0xC2C2BB)
        case .lockedDark: Color(hex: 0x08080A)
        }
    }

    var markFlat: Color { self == .lockedDark ? Color(hex: 0x303035) : Color(hex: 0xDCDCD5) }
    var rim: Color { self == .lockedDark ? Color(hex: 0x1F1F22) : Color(hex: 0xE8E8E2) }
    var line: Color { self == .lockedDark ? Color(hex: 0x3A3A40) : Color(hex: 0xCBCBC4) }
    var face: Color { self == .lockedDark ? Color(hex: 0x17171A) : Color(hex: 0xF1F1EC) }
    var inlay: Color { self == .lockedDark ? Color(hex: 0x222226) : Color(hex: 0xE7E7E1) }
}

private enum MedalMarkPart {
    case fill(Path, hue: Color? = nil)
    case stroke(Path, width: CGFloat)
    case letter(String)
}

private enum MedalGeometry {
    static let slant = tan(12 * Double.pi / 180)

    static func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    static func polygon(_ points: [CGPoint]) -> Path {
        Path { path in
            path.addLines(points)
            path.closeSubpath()
        }
    }

    static func polyline(_ points: [CGPoint]) -> Path {
        Path { $0.addLines(points) }
    }

    static func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Path {
        polyline([pt(x1, y1), pt(x2, y2)])
    }

    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Path {
        Path(CGRect(x: x, y: y, width: w, height: h))
    }

    static func leaning(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Path {
        polygon([pt(x + h * slant, y), pt(x + w + h * slant, y), pt(x + w, y + h), pt(x, y + h)])
    }

    static func chamfer(_ corners: [CGPoint], _ cut: Double) -> [CGPoint] {
        corners.indices.flatMap { index -> [CGPoint] in
            let corner = corners[index]
            func toward(_ other: CGPoint) -> CGPoint {
                let dx = other.x - corner.x, dy = other.y - corner.y, length = hypot(dx, dy)
                return pt(corner.x + dx / length * cut, corner.y + dy / length * cut)
            }
            return [
                toward(corners[(index + corners.count - 1) % corners.count]),
                toward(corners[(index + 1) % corners.count]),
            ]
        }
    }

    static func plate(_ cx: Double, _ cy: Double, _ w: Double, _ h: Double, cut: Double) -> Path {
        polygon(chamfer([
            pt(cx - w + h * slant, cy - h), pt(cx + w + h * slant, cy - h),
            pt(cx + w - h * slant, cy + h), pt(cx - w - h * slant, cy + h),
        ], cut))
    }

    static func circle(_ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: 60 - r, y: 60 - r, width: r * 2, height: r * 2))
    }

    static func hexagon(_ r: Double) -> Path {
        polygon(chamfer([
            pt(60, 60 - r), pt(60 + r * 0.866, 60 - r / 2), pt(60 + r * 0.866, 60 + r / 2),
            pt(60, 60 + r), pt(60 - r * 0.866, 60 + r / 2), pt(60 - r * 0.866, 60 - r / 2),
        ], 2.5))
    }

    static func shield(_ inset: Double) -> Path {
        let left = 16 + inset, right = 104 - inset, top = 10 + inset, middle = 60.0
        let bottom = 112 - inset * 1.3, cut = 5.0
        return Path { path in
            path.move(to: pt(left + cut, top))
            path.addLine(to: pt(right - cut, top))
            path.addLine(to: pt(right, top + cut))
            path.addLine(to: pt(right, middle))
            path.addCurve(
                to: pt(60, bottom),
                control1: pt(right, middle + 28 - inset * 0.5),
                control2: pt(82 - inset * 0.3, bottom - 9)
            )
            path.addCurve(
                to: pt(left, middle),
                control1: pt(38 + inset * 0.3, bottom - 9),
                control2: pt(left, middle + 28 - inset * 0.5)
            )
            path.addLine(to: pt(left, top + cut))
            path.closeSubpath()
        }
    }

    static func shapes(_ family: CompetitionMedalFamily) -> (outer: Path, wall: Path, face: Path) {
        switch family {
        case .weekly: (circle(52), circle(46), circle(43))
        case .reign: (shield(0), shield(6.5), shield(9))
        case .rival: (hexagon(54), hexagon(48), hexagon(44))
        }
    }

    static func mark(_ art: CompetitionMedalArt) -> [MedalMarkPart] {
        guard case .badge(let kind) = art else {
            if case .rival(let initial) = art { return [.letter(initial)] }
            return []
        }
        switch kind {
        case .sweep:
            return (0..<7).map { .fill(leaning(0.6 + Double($0) * 4.9, 7, 3, 26)) }
        case .comeback:
            return [
                .stroke(polyline([pt(3, 11), pt(14.5, 28.5), pt(30.2, 9.9)]), width: 5.2),
                .fill(polygon([pt(36, 3.5), pt(35.2, 15.6), pt(24.7, 7.4)])),
            ]
        case .photoFinish:
            let cell = 4.6, top = 3.9, left = 12.6, height = 7 * cell
            var parts: [MedalMarkPart] = [.stroke(leaning(left - 1, top - 1, 3 * cell + 2, height + 2), width: 1.3)]
            for row in 0..<7 {
                for column in 0..<3 where (row + column) % 2 == 0 {
                    let base = top + Double(row + 1) * cell
                    parts.append(.fill(leaning(
                        left + Double(column) * cell + (top + height - base) * slant,
                        top + Double(row) * cell, cell, cell
                    )))
                }
            }
            return parts
        case .tripleCrown:
            let hues = [Theme.move, Theme.exercise, Theme.stand]
            func lean(_ x: Double, _ y: Double) -> CGPoint { pt(x + (31 - y) * slant, y) }
            let points: [MedalMarkPart] = [9.0, 3, 9].enumerated().map { index, peak in
                let x = 3.2 + Double(index) * 10.4
                return .fill(polygon([
                    lean(x, 31), lean(x + 8.2, 31), lean(x + 8.2, peak + 5.5), lean(x + 4.1, peak), lean(x, peak + 5.5),
                ]), hue: hues[index])
            }
            return points + [.fill(leaning(2.2, 33, 32.6, 4))]
        case .fullWeek:
            var parts: [MedalMarkPart] = [
                .stroke(Path(roundedRect: CGRect(x: 4, y: 6, width: 32, height: 29), cornerRadius: 3), width: 3),
                .fill(Path(roundedRect: CGRect(x: 4, y: 6, width: 32, height: 7.5), cornerRadius: 2)),
                .fill(rect(11, 2.5, 3.2, 7)),
                .fill(rect(25.8, 2.5, 3.2, 7)),
            ]
            for (count, left, y) in [(4, 7.4, 16.6), (3, 11.0, 24.8)] {
                parts += (0..<count).map { MedalMarkPart.fill(leaning(left + Double($0) * 7.2, y, 4.8, 5.2)) }
            }
            return parts
        case .hotStreak:
            return (0..<5).map { index in
                let y = 3 + Double(index) * 6.6
                return .stroke(polyline([pt(5.5, y + 9), pt(20, y), pt(34.5, y + 9)]), width: 3.7)
            }
        case .defender:
            return [
                .fill(rect(0, 14.5, 7, 11)),
                .fill(rect(33, 14.5, 7, 11)),
                .fill(plate(20, 20, 11, 12.5, cut: 12.5 * 0.26)),
            ]
        case .collector:
            return [(20.0, 11.0), (10, 29), (30, 29)].map { .fill(plate($0.0, $0.1, 7.6, 7, cut: 7 * 0.26)) }
        case .rival:
            return [3.5, 22].flatMap { left -> [MedalMarkPart] in
                (0..<4).map { index -> MedalMarkPart in
                    let x = left + Double(index) * 3.7
                    return .stroke(line(x + 23 * slant, 8, x, 31), width: 2.3)
                } + [.stroke(line(left - 2.5, 25, left + 16, 13), width: 2.6)]
            }
        }
    }
}

private struct MedalPainter {
    let finish: MedalFinish

    private typealias G = MedalGeometry

    func front(_ art: CompetitionMedalArt, in context: inout GraphicsContext) {
        let (outer, wall, face) = G.shapes(art.family)
        body(outer: outer, wall: wall, face: face, in: &context)
        var inner = context
        inner.clip(to: face)
        switch art.family {
        case .weekly:
            inner.fill(G.rect(0, 0, 120, 76), with: inlay(CGRect(x: 0, y: 0, width: 120, height: 76)))
            inner.fill(G.rect(0, 76, 120, 44), with: band(CGRect(x: 0, y: 76, width: 120, height: 44)))
            for y in [82.0, 88, 94, 100] { groove(G.line(10, y, 110, y), width: 1.2, in: &inner) }
            inner.stroke(G.line(10, 76, 110, 76), with: .color(seam), lineWidth: 1.3)
        case .reign:
            inner.fill(G.rect(0, 0, 120, 120), with: inlay(CGRect(x: 0, y: 0, width: 120, height: 120)))
            inner.fill(
                G.polygon([G.pt(0, 64), G.pt(60, 86), G.pt(120, 64), G.pt(120, 120), G.pt(0, 120)]),
                with: band(CGRect(x: 0, y: 64, width: 120, height: 56))
            )
            for y in [70.0, 76, 82, 88] { groove(chevron(y), width: 1.4, in: &inner) }
        case .rival:
            let upper = 60 + 50 * G.slant, lower = 60 - 50 * G.slant
            inner.fill(G.rect(0, 0, 120, 120), with: inlay(CGRect(x: 0, y: 0, width: 120, height: 120)))
            inner.fill(
                G.polygon([G.pt(0, 10), G.pt(upper, 10), G.pt(lower, 110), G.pt(0, 110)]),
                with: band(CGRect(x: 0, y: 10, width: upper, height: 100))
            )
            for y in stride(from: 26.0, through: 96, by: 7) { groove(G.line(10, y, 62, y), width: 1, in: &inner) }
            inner.stroke(G.line(upper, 10, lower, 110), with: .color(seam), lineWidth: 1.6)
        }
        context.stroke(face, with: .color(edge), lineWidth: 0.9)
        let (center, size): (CGPoint, Double) = switch art.family {
        case .weekly: (G.pt(60, 47), 46)
        case .reign: (G.pt(60, 41), 40)
        case .rival: (G.pt(79, 60), 36)
        }
        mark(G.mark(art), center: center, size: size, in: &context)
    }

    func back(_ family: CompetitionMedalFamily, in context: inout GraphicsContext) {
        let (outer, wall, face) = G.shapes(family)
        body(outer: outer, wall: wall, face: face, in: &context)
        var inner = context
        inner.clip(to: face)
        if family == .reign {
            for y in [72.0, 78, 84] { groove(chevron(y), width: 1.4, in: &inner) }
        } else {
            for y in [82.0, 88, 94, 100] { groove(G.line(10, y, 110, y), width: 1.2, in: &inner) }
        }
        let top: Double = family == .reign ? 18 : 24
        let cut = GraphicsContext.Shading.color(Color(hex: 0x6E4706))
        for index in 0..<3 { context.fill(G.leaning(48.5 + Double(index) * 4.2, top, 2.6, 8), with: cut) }
        context.fill(G.leaning(62.4, top, 7, 8), with: cut)
    }

    private var seam: Color { finish == .earned ? Color(hex: 0xFBE2A0) : finish.line }
    private var edge: Color { finish == .earned ? Color(hex: 0x7A4F08) : finish.line }

    private func chevron(_ y: Double) -> Path {
        G.polyline([G.pt(10, y), G.pt(60, y + 22), G.pt(110, y)])
    }

    private func gradient(_ stops: [(UInt32, Double)], _ rect: CGRect, _ start: UnitPoint, _ end: UnitPoint) -> GraphicsContext.Shading {
        .linearGradient(
            Gradient(stops: stops.map { Gradient.Stop(color: Color(hex: $0.0), location: $0.1) }),
            startPoint: CGPoint(x: rect.minX + rect.width * start.x, y: rect.minY + rect.height * start.y),
            endPoint: CGPoint(x: rect.minX + rect.width * end.x, y: rect.minY + rect.height * end.y)
        )
    }

    private func inlay(_ rect: CGRect) -> GraphicsContext.Shading {
        finish == .earned
            ? gradient([(0x57524B, 0), (0x36332F, 1)], rect, UnitPoint(x: 0.2, y: 0), UnitPoint(x: 0.8, y: 1))
            : .color(finish.inlay)
    }

    private func band(_ rect: CGRect) -> GraphicsContext.Shading {
        finish == .earned ? gradient([(0xD9A54A, 0), (0xB98422, 1)], rect, .top, .bottom) : .color(finish.face)
    }

    private func body(outer: Path, wall: Path, face: Path, in context: inout GraphicsContext) {
        guard finish == .earned else {
            context.fill(outer, with: .color(finish.rim))
            context.stroke(outer, with: .color(finish.line), lineWidth: 1)
            context.stroke(wall, with: .color(finish.line), lineWidth: 0.8)
            context.fill(face, with: .color(finish.face))
            return
        }
        let lit = UnitPoint(x: 0.15, y: 0.05), shaded = UnitPoint(x: 0.85, y: 0.95)
        context.fill(outer, with: gradient(
            [(0xF7DD94, 0), (0xDDA94A, 0.42), (0xB07B18, 0.78), (0x875809, 1)], outer.boundingRect, lit, shaded
        ))
        context.stroke(outer, with: .color(Color(hex: 0x7A4F08)), lineWidth: 0.8)
        context.fill(wall, with: gradient([(0x8E5E0C, 0), (0xC08A28, 0.55), (0xF3D486, 1)], wall.boundingRect, lit, shaded))
        context.fill(face, with: gradient(
            [(0xF1D387, 0), (0xE0B460, 0.6), (0xCC9A3C, 1)], face.boundingRect, UnitPoint(x: 0.3, y: 0), UnitPoint(x: 0.7, y: 1)
        ))
    }

    private func groove(_ path: Path, width: CGFloat, in context: inout GraphicsContext) {
        guard finish == .earned else {
            context.stroke(path, with: .color(finish.line), lineWidth: width)
            return
        }
        context.stroke(path, with: .color(Color(hex: 0x8A5A0A).opacity(0.6)), lineWidth: width)
        context.stroke(
            path.offsetBy(dx: 0, dy: width * 0.8),
            with: .color(Color(hex: 0xFCE9B4).opacity(0.7)),
            lineWidth: width * 0.6
        )
    }

    private func mark(_ parts: [MedalMarkPart], center: CGPoint, size: Double, in context: inout GraphicsContext) {
        var box = context
        box.translateBy(x: center.x - size / 2, y: center.y - size / 2)
        box.scaleBy(x: size / 40, y: size / 40)
        var under = box
        under.translateBy(x: 0, y: -0.9)
        draw(parts, with: .color(finish.markUnder), color: finish.markUnder, hued: false, in: &under)
        let raised: GraphicsContext.Shading = finish == .earned
            ? gradient([(0xFBE6AA, 0), (0xE7B95C, 0.55), (0xC79232, 1)], CGRect(x: 0, y: 0, width: 40, height: 40), .top, .bottom)
            : .color(finish.markFlat)
        draw(parts, with: raised, color: finish == .earned ? Color(hex: 0xEBC067) : finish.markFlat, hued: finish == .earned, in: &box)
    }

    private func draw(
        _ parts: [MedalMarkPart],
        with shading: GraphicsContext.Shading,
        color: Color,
        hued: Bool,
        in context: inout GraphicsContext
    ) {
        for part in parts {
            switch part {
            case .fill(let path, let hue):
                if hued, let hue {
                    context.fill(path, with: .color(hue))
                } else {
                    context.fill(path, with: shading)
                }
            case .stroke(let path, let width):
                context.stroke(path, with: shading, style: StrokeStyle(lineWidth: width, lineCap: .butt, lineJoin: .miter))
            case .letter(let letter):
                context.draw(
                    Text(letter).font(.system(size: 34, weight: .heavy).width(.compressed)).foregroundStyle(color),
                    at: CGPoint(x: 20, y: 20)
                )
            }
        }
    }
}
