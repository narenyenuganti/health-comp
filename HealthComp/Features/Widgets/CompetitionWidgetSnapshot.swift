import Foundation

// Foundation only: the widget extension and the watch compile this file with
// CompetitionDateFormatting.swift. Points only, never Health values.

/// What the app shares with its widgets through the App Group container, and
/// with the paired Watch through `CompetitionWatchSync`.
struct CompetitionWidgetSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 2
    static let fileName = "CompetitionWidgetSnapshot.json"

    var version = Self.currentVersion
    var matches: [Match]
    /// A pending incoming challenge exists; no name, no count.
    var hasIncomingChallenge: Bool

    struct Match: Codable, Equatable, Sendable {
        var id: UUID
        /// The other person's identity, for the widget's person picker.
        var personID: String
        var name: String
        /// Built by the app from `CompetitionRoute`, so the widget never
        /// hardcodes a scheme.
        var url: URL
        /// The match calendar.
        var timeZoneIdentifier: String
        /// Seven match-calendar midnights.
        var dayStarts: [Date]
        /// The midnight after Day 7.
        var endsAt: Date
        var userPoints: Double
        var opponentPoints: Double
        /// Seven entries, by day.
        var userDayPoints: [Double?]
        var opponentDayPoints: [Double?]
        var updatedAt: Date?
        var final: Final?
        /// The Watch's belt row and card. Optional, so older files still decode.
        var belt: Belt?
        /// The Watch's chase bar, from the phone's what it takes. Nil when
        /// you lead or the phone couldn't work it out.
        var chase: Chase?
    }

    /// What it takes to lead on a live day.
    struct Chase: Codable, Equatable, Sendable {
        /// The match day it was worked out for, 1...7.
        var day: Int
        /// Whole points that take the lead; nil when out of reach today.
        var points: Double?
    }

    /// Who holds this pair's belt now, and what this result did to it.
    struct Belt: Codable, Equatable, Sendable {
        enum Holder: String, Codable, Sendable { case you, them }
        /// Only the changes worth the Watch's card: not their vacant take,
        /// their defense, or a tie.
        enum Card: Codable, Equatable, Sendable {
            case earned
            case taken(weeks: Int, defenses: Int)
            case lost(weeks: Int, defenses: Int)
            case defended(Int)
        }

        var holder: Holder
        /// Title defenses in the current reign.
        var defenses: Int
        var card: Card?
    }

    /// Not `Result`, so it doesn't shadow `Swift.Result`.
    struct Final: Codable, Equatable, Sendable {
        enum Outcome: String, Codable, Sendable { case win, loss, tie }
        var outcome: Outcome
        var completedAt: Date
        var leavesAt: Date
    }

    enum State: Equatable, Sendable {
        case scheduled, live(day: Int), finalPending, final(Final.Outcome), gone

        var isLiveOrPending: Bool {
            switch self {
            case .live, .finalPending: true
            case .scheduled, .final, .gone: false
            }
        }
    }
}

// MARK: Which match

extension CompetitionWidgetSnapshot.Match {
    func state(at date: Date) -> CompetitionWidgetSnapshot.State {
        if let final {
            return date < final.leavesAt ? .final(final.outcome) : .gone
        }
        guard let first = dayStarts.first, date >= first else { return .scheduled }
        if date >= endsAt { return .finalPending }
        return .live(day: (dayStarts.lastIndex { $0 <= date } ?? 0) + 1)
    }
}

extension CompetitionWidgetSnapshot {
    /// Live ending soonest, then a pending final score, then the next
    /// scheduled match, then the newest result still on Home. With a person
    /// picked, only their matches, and nil rather than someone else's.
    func featured(personID: String?, at date: Date) -> Match? {
        let pool = matches.filter { personID == nil || $0.personID == personID }
        func first(
            _ keep: (State) -> Bool,
            by keys: [(Match) -> TimeInterval]
        ) -> Match? {
            pool.filter { keep($0.state(at: date)) }.min { lhs, rhs in
                for key in keys where key(lhs) != key(rhs) {
                    return key(lhs) < key(rhs)
                }
                let names = lhs.name.localizedStandardCompare(rhs.name)
                if names != .orderedSame { return names == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
        let start = { (match: Match) in match.dayStarts.first?.timeIntervalSinceReferenceDate ?? 0 }
        let end = { (match: Match) in match.endsAt.timeIntervalSinceReferenceDate }
        return first({ if case .live = $0 { true } else { false } }, by: [end, start])
            ?? first({ $0 == .finalPending }, by: [end])
            ?? first({ $0 == .scheduled }, by: [start])
            ?? first({ if case .final = $0 { true } else { false } }, by: [
                { -($0.final?.completedAt.timeIntervalSinceReferenceDate ?? 0) },
            ])
    }

    /// The name in this snapshot, never one stored in a widget configuration.
    func name(for personID: String) -> String? {
        matches.first { $0.personID == personID }?.name
    }

    /// People with a match here, by name. "Former competitor" is left out:
    /// several would look the same and none can play again.
    func suggestedPeople() -> [(id: String, name: String)] {
        var seen = Set<String>()
        return matches
            .filter { $0.name != "Former competitor" && seen.insert($0.personID).inserted }
            .map { (id: $0.personID, name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A copy without times, for deciding whether a widget needs a reload.
    var ignoringUpdatedAt: Self {
        var copy = self
        copy.matches = matches.map {
            var match = $0
            match.updatedAt = nil
            return match
        }
        return copy
    }

    /// Adds the previous matches named in `ids` that this snapshot lacks: the
    /// ones whose sync failed or was cancelled this round.
    func merging(carriedForward ids: Set<UUID>, from previous: Self?) -> Self {
        guard let previous else { return self }
        let present = Set(matches.map(\.id))
        var copy = self
        copy.matches += previous.matches.filter {
            ids.contains($0.id) && !present.contains($0.id)
        }
        return copy
    }

    /// Every future moment a widget changes on its own: day starts, ends and
    /// results leaving. iOS allows a few, so the first 12.
    func timelineDates(after date: Date) -> [Date] {
        let dates = matches.flatMap { match in
            match.dayStarts + [match.endsAt] + [match.final?.leavesAt].compactMap { $0 }
        }
        return Array(Set(dates.filter { $0 > date }).sorted().prefix(12))
    }
}

// MARK: Copy

extension CompetitionWidgetSnapshot.Match {
    var finalDigits: Int {
        final == nil
            ? 0
            : competitionFinalFractionDigits(userPoints: userPoints, opponentPoints: opponentPoints)
    }

    func userPointsText(locale: Locale = .current) -> String {
        competitionPointsText(userPoints, fractionDigits: finalDigits, locale: locale)
    }

    func opponentPointsText(locale: Locale = .current) -> String {
        competitionPointsText(opponentPoints, fractionDigits: finalDigits, locale: locale)
    }

    func weekday(_ template: String, locale: Locale) -> String {
        guard let first = dayStarts.first else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: first)
    }

    /// "Day 5 of 7", "Last day", "You won"… Compact: "Day 5", "Final".
    func status(at date: Date, compact: Bool = false, locale: Locale = .current) -> String {
        switch state(at: date) {
        case .scheduled: return "Day 1 is \(weekday("EEEE", locale: locale))"
        case .live(day: 7): return "Last day"
        case let .live(day): return compact ? "Day \(day)" : "Day \(day) of 7"
        case .finalPending: return "Final score pending"
        case let .final(outcome):
            guard !compact else { return "Final" }
            switch outcome {
            case .win: return "You won"
            case .loss: return "\(name) won"
            case .tie: return "Tied"
            }
        case .gone: return ""
        }
    }

    /// The medium header: "Sam · Day 5 of 7", "Sam · Final".
    func mediumHeader(at date: Date, locale: Locale = .current) -> String {
        "\(name) · \(mediumStatus(at: date, locale: locale))"
    }

    /// The header after the name, kept whole when a long name truncates.
    func mediumStatus(at date: Date, locale: Locale = .current) -> String {
        if case .final = state(at: date) { return "Final" }
        return status(at: date, locale: locale)
    }

    /// "You lead by 54." while live, "Won by 114 points" for a result, nil
    /// for a tie or a scheduled match.
    func leadLine(at date: Date, locale: Locale = .current) -> String? {
        switch state(at: date) {
        case .live, .finalPending:
            return competitionLeadSentence(
                userPoints: userPoints, opponentPoints: opponentPoints,
                opponentDisplayName: name, locale: locale
            )
        case .final:
            return competitionMarginText(
                userPoints: userPoints, opponentPoints: opponentPoints,
                fractionDigits: finalDigits, locale: locale
            )
        case .scheduled, .gone:
            return nil
        }
    }

    /// "Updated 9:30 AM" today, "Updated Tue 9:30 PM" before. Nil for a
    /// scheduled match or with no time.
    func updatedLine(
        at date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard state(at: date) != .scheduled, let updatedAt else { return nil }
        return "Updated \(competitionUpdatedText(updatedAt, now: date, locale: locale, timeZone: timeZone))"
    }

    /// "Today 212" under each medium number while live, "Day 7 212" while the
    /// final score is pending; nil when that side has no points for the day.
    func todayLines(at date: Date, locale: Locale = .current) -> (user: String?, opponent: String?) {
        let (label, index): (String, Int) = switch state(at: date) {
        case let .live(day): ("Today", day - 1)
        case .finalPending: ("Day 7", 6)
        default: ("", -1)
        }
        func line(_ points: [Double?]) -> String? {
            guard points.indices.contains(index), let value = points[index] else { return nil }
            return "\(label) \(competitionPointsText(value, locale: locale))"
        }
        return (line(userDayPoints), line(opponentDayPoints))
    }

    /// Lock Screen rectangle, one array per line, longest first: each line
    /// falls back to the next entry when it doesn't fit.
    func rectangularLines(
        at date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> [[String]] {
        if state(at: date) == .scheduled {
            // "Day 1 is Wednesday" doesn't fit the rectangle: "Day 1 is Wed".
            return [[name], [status(at: date, locale: locale), "Day 1 is \(weekday("EEE", locale: locale))"]]
        }
        let you = userPointsText(locale: locale)
        let them = opponentPointsText(locale: locale)
        // "Sam · Final score pending" rarely fits: "Sam · Pending" keeps the
        // match from reading as live.
        let short = state(at: date) == .finalPending ? ["\(name) · Pending"] : []
        return [
            ["\(name) · \(status(at: date, compact: true, locale: locale))"] + short + [name],
            ["You \(you) · \(name) \(them)", "You \(you) · \(them)"],
        ] + [updatedLine(at: date, locale: locale, timeZone: timeZone).map { [$0] }].compactMap { $0 }
    }

    /// The Lock Screen circle: "LEAD" over "+54", "WON" over "+114",
    /// "DAY 1" over "Mon".
    func circular(at date: Date, locale: Locale = .current) -> (caption: String, value: String) {
        let margin = competitionSignedMarginText(
            userPoints: userPoints, opponentPoints: opponentPoints,
            fractionDigits: finalDigits, locale: locale
        )
        switch state(at: date) {
        case .scheduled: return ("DAY 1", weekday("EEE", locale: locale))
        case .final(.win): return ("WON", margin)
        case .final(.loss): return ("LOST", margin)
        case .final(.tie): return ("TIED", margin)
        case .live, .finalPending, .gone: return ("LEAD", margin)
        }
    }

    /// One VoiceOver label per widget. Redacted (a locked phone) it names no
    /// one and reads no points: "HealthComp, Day 5."
    func accessibilityLabel(
        at date: Date,
        redacted: Bool,
        circular: Bool = false,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let state = state(at: date)
        guard !redacted else {
            return "HealthComp, \(status(at: date, compact: true, locale: locale))."
        }
        if state == .scheduled {
            return "\(name), \(status(at: date, locale: locale))."
        }
        if circular, state.isLiveOrPending {
            let margin = competitionDisplayedMargin(userPoints: userPoints, opponentPoints: opponentPoints)
            let points = competitionPointsAccessibilityText(abs(margin), locale: locale)
            if margin > 0 { return "You lead \(name) by \(points)" }
            if margin < 0 { return "\(name) leads by \(points)" }
            return "All square with \(name)"
        }
        let header = if case .final = state { "Final" } else { status(at: date, locale: locale) }
        let you = competitionPointsAccessibilityText(userPoints, fractionDigits: finalDigits, locale: locale)
        let them = competitionPointsAccessibilityText(opponentPoints, fractionDigits: finalDigits, locale: locale)
        let lead = leadLine(at: date, locale: locale).map { $0.hasSuffix(".") ? $0 : $0 + "." }
            ?? "Tied."
        return ["\(name), \(header).", "You \(you).", "\(name) \(them).", lead,
                updatedLine(at: date, locale: locale, timeZone: timeZone).map { $0 + "." }]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    /// The week strip at `date`; the day in progress is `.today`.
    func dayOutcomes(at date: Date) -> [CompetitionDayOutcome] {
        let current: Int? = if case let .live(day) = state(at: date) { day } else { nil }
        func points(_ values: [Double?], _ index: Int) -> Double? {
            values.indices.contains(index) ? values[index] : nil
        }
        return dayStarts.indices.map { index in
            competitionDayOutcome(
                ordinal: index + 1,
                currentDayOrdinal: current,
                hasOccurred: dayStarts[index] <= date,
                ownerPoints: points(userDayPoints, index),
                opponentPoints: points(opponentDayPoints, index)
            )
        }
    }
}

// MARK: Nothing to show

/// The text for an entry without a match to draw.
struct CompetitionWidgetEmptyText: Equatable, Sendable {
    let title: String
    let line: String?
    /// Lock Screen rectangle lines.
    let compact: [String]
    /// The title names someone, so a locked phone redacts it.
    var namesSomeone = false

#if os(watchOS)
    static let noSnapshot = Self(
        title: "HealthComp",
        line: "Open HealthComp on iPhone.",
        compact: ["HealthComp", "Open HealthComp on iPhone."]
    )
#else
    static let noSnapshot = Self(
        title: "HealthComp",
        line: "Open the app to see your matches.",
        compact: ["HealthComp", "Open the app to see your matches."]
    )
#endif

    var accessibilityLabel: String {
        [title, line].compactMap { $0 }.joined(separator: ". ")
    }

    /// For a locked phone, when the title names someone.
    var redactedAccessibilityLabel: String {
        "HealthComp, \(compact.last ?? title)."
    }
}

extension CompetitionWidgetSnapshot {
    var emptyLine: String {
        hasIncomingChallenge ? "A challenge is waiting." : "Challenge someone"
    }

    func pickedPersonEmptyText(personID: String) -> String {
        name(for: personID).map { "No match with \($0) right now." }
            ?? "No match with this person right now."
    }

    func emptyText(personID: String?) -> CompetitionWidgetEmptyText {
        guard let personID else {
#if os(watchOS)
            // The watch can't challenge anyone, so only a waiting one gets a line.
            let line = hasIncomingChallenge ? emptyLine : nil
#else
            let line: String? = emptyLine
#endif
            return CompetitionWidgetEmptyText(
                title: "Nothing live right now",
                line: line,
                compact: ["Nothing live right now"]
            )
        }
        let name = name(for: personID)
        return CompetitionWidgetEmptyText(
            title: pickedPersonEmptyText(personID: personID),
            line: nil,
            compact: [name, "No match right now"].compactMap { $0 },
            namesSomeone: name != nil
        )
    }

    /// The match to draw at `date`, or the text instead. With no snapshot a
    /// picked person is ignored.
    static func content(
        _ snapshot: Self?,
        personID: String?,
        at date: Date
    ) -> CompetitionWidgetContent {
        guard let snapshot else { return .empty(.noSnapshot) }
        if let match = snapshot.featured(personID: personID, at: date) { return .match(match) }
        return .empty(snapshot.emptyText(personID: personID))
    }
}

enum CompetitionWidgetContent: Equatable, Sendable {
    case match(CompetitionWidgetSnapshot.Match)
    case empty(CompetitionWidgetEmptyText)
}

// MARK: File

extension CompetitionWidgetSnapshot {
    /// The file in the App Group named by the `HEALTHCOMP_APP_GROUP` plist key.
    static func fileURL(bundle: Bundle = .main) -> URL? {
        guard let group = bundle.object(forInfoDictionaryKey: "HEALTHCOMP_APP_GROUP") as? String,
              !group.isEmpty,
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group
              )
        else { return nil }
        return container.appendingPathComponent(fileName)
    }

    /// Nil for a missing file, bad JSON or another version, so a future
    /// format fails closed to "Open the app…".
    static func load(from url: URL?) -> Self? {
        guard let url,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Self.self, from: data),
              snapshot.version == currentVersion
        else { return nil }
        return snapshot
    }

    /// Sam, Day 5, 1,204 to 1,150 in UTC: the widget gallery and DEBUG
    /// captures. The caller passes the url: this file can't see
    /// `CompetitionRoute`.
    static func sample(now: Date, url: URL) -> Self {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.startOfDay(for: now)
        let dayStarts = (-4...2).map { calendar.date(byAdding: .day, value: $0, to: today)! }
        return Self(
            matches: [
                Match(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                    personID: "sample:sam",
                    name: "Sam",
                    url: url,
                    timeZoneIdentifier: "UTC",
                    dayStarts: dayStarts,
                    endsAt: calendar.date(byAdding: .day, value: 3, to: today)!,
                    userPoints: 1_204,
                    opponentPoints: 1_150,
                    userDayPoints: [250, 230, 262, 250, 212, nil, nil],
                    opponentDayPoints: [230, 260, 280, 192, 188, nil, nil],
                    updatedAt: now.addingTimeInterval(-11 * 60),
                    final: nil
                ),
            ],
            hasIncomingChallenge: false
        )
    }
}

#if DEBUG
extension CompetitionWidgetSnapshot {
    /// Widget states for the Mac mini UI tests (`--widget-scenario <name>`,
    /// `--watch-scenario <name>`), in UTC days around `now`. Nil means no
    /// snapshot: the caller clears the file. The caller passes the url scheme:
    /// this file can't see `CompetitionRoute`.
    static func testLab(_ scenario: String, now: Date, scheme: String) -> Self? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        /// `currentDay` 1...7 is live; 0 starts tomorrow, -1 the day after;
        /// 8 ended at today's midnight, 9 and more ended earlier.
        func match(
            _ index: Int, _ name: String, person: String? = nil, currentDay: Int,
            you: Double = 0, them: Double = 0,
            youDays: [Double?] = [], themDays: [Double?] = [],
            updated: Bool = true, updatedAgo: TimeInterval = 11 * 60,
            final: Final.Outcome? = nil, leavesInDays: Int = 3, belt: Belt? = nil,
            chase: Chase? = nil
        ) -> Match {
            let first = day(1 - currentDay)
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012ld", index))!
            func padded(_ values: [Double?]) -> [Double?] {
                Array((values + Array(repeating: nil, count: 7)).prefix(7))
            }
            return Match(
                id: id,
                personID: person ?? "sample:\(name.lowercased())",
                name: name,
                url: URL(string: "\(scheme)://competition/\(id.uuidString.lowercased())")!,
                timeZoneIdentifier: "UTC",
                dayStarts: (0..<7).map { calendar.date(byAdding: .day, value: $0, to: first)! },
                endsAt: calendar.date(byAdding: .day, value: 7, to: first)!,
                userPoints: you,
                opponentPoints: them,
                userDayPoints: padded(youDays),
                opponentDayPoints: padded(themDays),
                updatedAt: updated ? now.addingTimeInterval(-updatedAgo) : nil,
                final: final.map {
                    Final(outcome: $0, completedAt: day(0).addingTimeInterval(3_600), leavesAt: day(leavesInDays))
                },
                belt: belt,
                chase: chase
            )
        }
        let week: [Double?] = [250, 230, 262, 250, 212, 260, 300]
        let theirs: [Double?] = [230, 260, 280, 192, 188, 250, 240]
        let sam = match(5, "Sam", currentDay: 5, you: 1_204, them: 1_150, youDays: week, themDays: theirs)
        let alex = match(6, "Alex", currentDay: 2, you: 480, them: 455, youDays: [250, 230], themDays: [230, 225])
        let matches: [Match]
        var hasIncomingChallenge = false
        switch scenario {
        case "live": matches = [sam]
        case "trailing":
            matches = [match(5, "Sam", currentDay: 3, you: 610, them: 664,
                             youDays: [200, 210, 200], themDays: [220, 224, 220],
                             chase: Chase(day: 3, points: 55))]
        case "outOfReach":
            matches = [match(5, "Sam", currentDay: 7, you: 1_700, them: 2_171, youDays: theirs,
                             themDays: week, chase: Chase(day: 7, points: nil))]
        case "square":
            matches = [match(5, "Sam", currentDay: 2, you: 480, them: 480,
                             youDays: [250, 230], themDays: [230, 250])]
        case "lastDay":
            matches = [match(5, "Sam", currentDay: 7, you: 2_190, them: 2_171, youDays: week, themDays: theirs)]
        case "pending":
            matches = [match(5, "Sam", currentDay: 8, you: 2_190, them: 2_171, youDays: week, themDays: theirs)]
        case "won":
            matches = [match(5, "Sam", currentDay: 9, you: 1_840, them: 1_726,
                             youDays: week, themDays: theirs, final: .win)]
        case "lost":
            matches = [match(5, "Sam", currentDay: 9, you: 1_700, them: 1_720,
                             youDays: theirs, themDays: week, final: .loss)]
        case "tied":
            matches = [match(5, "Sam", currentDay: 9, you: 1_650, them: 1_650,
                             youDays: week, themDays: theirs, final: .tie)]
        case "scheduled": matches = [match(5, "Sam", currentDay: -1)]
        case "empty": matches = []
        case "challenge":
            matches = []
            hasIncomingChallenge = true
        case "longName":
            matches = [match(
                5, "Maximiliana Featherstonehaugh-Worthington", person: "sample:long", currentDay: 5,
                you: 12_045, them: 11_980, youDays: [2_500, 2_300, 2_620, 2_500, 2_125],
                themDays: [2_300, 2_600, 2_800, 1_920, 2_360]
            )]
        case "former":
            matches = [match(7, "Former competitor", person: "sample:former", currentDay: 9,
                             you: 1_840, them: 1_726, youDays: week, themDays: theirs, final: .win)]
        case "several":
            matches = [
                alex, sam,
                match(8, "Riley", currentDay: 8, you: 2_190, them: 2_171, youDays: week, themDays: theirs),
                match(9, "Casey", currentDay: -2),
                match(10, "Former competitor", person: "sample:former", currentDay: 9,
                      you: 1_840, them: 1_726, final: .win),
            ]
        case "noData":
            matches = [match(5, "Sam", currentDay: 4, you: 742, them: 510,
                             youDays: [250, 230, 262], themDays: [230, 280, nil], updated: false)]
        case "samGone":
            // Sam's result has left Home; only Alex is live.
            matches = [alex, match(5, "Sam", currentDay: 12, you: 1_840, them: 1_726, final: .win, leavesInDays: -1)]
        case "noSam": matches = [alex]
        // A digit gained, for the score roll.
        case "almostThousand":
            matches = [match(5, "Sam", currentDay: 5, you: 999, them: 980, youDays: week, themDays: theirs)]
        case "thousand":
            matches = [match(5, "Sam", currentDay: 5, you: 1_000, them: 980, youDays: week, themDays: theirs)]
        case "stale":
            matches = [match(5, "Sam", currentDay: 5, you: 1_204, them: 1_150,
                             youDays: week, themDays: theirs, updatedAgo: 3 * 3_600)]
        case "closeFinal":
            matches = [match(5, "Sam", currentDay: 9, you: 1_840.25, them: 1_840.40,
                             youDays: theirs, themDays: week, final: .loss)]
        // The Watch's belt row and card.
        case "beltLive":
            matches = [match(5, "Sam", currentDay: 5, you: 1_204, them: 1_150, youDays: week, themDays: theirs,
                             belt: Belt(holder: .you, defenses: 2))]
        case "beltTrailing":
            matches = [match(5, "Sam", currentDay: 3, you: 610, them: 664, youDays: [200, 210, 200],
                             themDays: [220, 224, 220], belt: Belt(holder: .them, defenses: 1))]
        case "beltEarned":
            matches = [match(5, "Sam", currentDay: 9, you: 1_840, them: 1_726, youDays: week, themDays: theirs,
                             final: .win, belt: Belt(holder: .you, defenses: 0, card: .earned))]
        case "beltTaken":
            matches = [match(5, "Sam", currentDay: 9, you: 1_840, them: 1_726, youDays: week, themDays: theirs,
                             final: .win, belt: Belt(holder: .you, defenses: 0, card: .taken(weeks: 4, defenses: 2)))]
        case "beltLost":
            matches = [match(5, "Sam", currentDay: 9, you: 1_700, them: 1_720, youDays: theirs, themDays: week,
                             final: .loss, belt: Belt(holder: .them, defenses: 0, card: .lost(weeks: 4, defenses: 2)))]
        case "beltDefended":
            matches = [match(5, "Sam", currentDay: 9, you: 1_840, them: 1_726, youDays: week, themDays: theirs,
                             final: .win, belt: Belt(holder: .you, defenses: 3, card: .defended(3)))]
        default: return nil
        }
        return Self(matches: matches, hasIncomingChallenge: hasIncomingChallenge)
    }
}
#endif
