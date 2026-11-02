import Foundation

// Foundation only: the widget extension compiles this file with
// CompetitionDateFormatting.swift. Points only, never Health values.

/// What the app shares with its widgets through the App Group container.
struct CompetitionWidgetSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
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
    private var finalDigits: Int {
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

    private func weekday(_ template: String, locale: Locale) -> String {
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
        return [
            ["\(name) · \(status(at: date, compact: true, locale: locale))", name],
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

    static let noSnapshot = Self(
        title: "HealthComp",
        line: "Open the app to see your matches.",
        compact: ["HealthComp", "Open the app to see your matches."]
    )

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
            return CompetitionWidgetEmptyText(
                title: "Nothing live right now",
                line: emptyLine,
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
