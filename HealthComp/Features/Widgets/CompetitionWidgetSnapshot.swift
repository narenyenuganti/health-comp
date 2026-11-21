import Foundation

struct CompetitionWidgetSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 2
    static let fileName = "CompetitionWidgetSnapshot.json"

    var version = Self.currentVersion
    var matches: [Match]
    var hasIncomingChallenge: Bool

    struct Match: Codable, Equatable, Sendable {
        var id: UUID
        var personID: String
        var name: String
        var url: URL
        var timeZoneIdentifier: String
        var dayStarts: [Date]
        var endsAt: Date
        var userPoints: Double
        var opponentPoints: Double
        var userDayPoints: [Double?]
        var opponentDayPoints: [Double?]
        var updatedAt: Date?
        var final: Final?
        var belt: Belt?
        var chase: Chase?
        var group: Group?
    }

    struct Group: Codable, Equatable, Sendable {
        var title: String
        var isDoubles: Bool
        var rows: [Row]
        var lead: String?

        struct Row: Codable, Equatable, Sendable {
            var place: Int
            var name: String
            var points: Double
            var isYou: Bool

            var namesSomeone: Bool { name != "You" }
        }

        var yourPlace: Int? { rows.first(where: \.isYou)?.place }
    }

    struct Chase: Codable, Equatable, Sendable {
        var day: Int
        var points: Double?
    }

    struct Belt: Codable, Equatable, Sendable {
        enum Holder: String, Codable, Sendable { case you, them }
        enum Card: Codable, Equatable, Sendable {
            case earned
            case taken(weeks: Int, defenses: Int)
            case lost(weeks: Int, defenses: Int)
            case defended(Int)
        }

        var holder: Holder
        var defenses: Int
        var card: Card?
    }

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

    func name(for personID: String) -> String? {
        matches.first { $0.personID == personID }?.name
    }

    func suggestedPeople() -> [(id: String, name: String)] {
        var seen = Set<String>()
        return matches
            .filter { $0.group == nil && $0.name != "Former competitor" && seen.insert($0.personID).inserted }
            .map { (id: $0.personID, name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var ignoringUpdatedAt: Self {
        var copy = self
        copy.matches = matches.map {
            var match = $0
            match.updatedAt = nil
            return match
        }
        return copy
    }

    func merging(carriedForward ids: Set<UUID>, from previous: Self?) -> Self {
        guard let previous else { return self }
        let present = Set(matches.map(\.id))
        var copy = self
        copy.matches += previous.matches.filter {
            ids.contains($0.id) && !present.contains($0.id)
        }
        return copy
    }

    func timelineDates(after date: Date) -> [Date] {
        let dates = matches.flatMap { match in
            match.dayStarts + [match.endsAt] + [match.final?.leavesAt].compactMap { $0 }
        }
        return Array(Set(dates.filter { $0 > date }).sorted().prefix(12))
    }
}

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

    func mediumStatus(at date: Date, locale: Locale = .current) -> String {
        if case .final = state(at: date) { return "Final" }
        return status(at: date, locale: locale)
    }

    func leadLine(at date: Date, locale: Locale = .current) -> String? {
        if let group { return group.lead }
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

    func updatedLine(
        at date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard state(at: date) != .scheduled, let updatedAt else { return nil }
        return "Updated \(competitionUpdatedText(updatedAt, now: date, locale: locale, timeZone: timeZone))"
    }

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

    func rectangularLines(
        at date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> [[String]] {
        if let group, let header = groupHeader(at: date, locale: locale) {
            let line = [groupPlaceText, group.lead].compactMap { $0 }.joined(separator: " · ")
            return [[header, group.title], [line, groupPlaceText ?? group.lead ?? ""]]
        }
        if state(at: date) == .scheduled {
            return [[name], [status(at: date, locale: locale), "Day 1 is \(weekday("EEE", locale: locale))"]]
        }
        let you = userPointsText(locale: locale)
        let them = opponentPointsText(locale: locale)
        let short = state(at: date) == .finalPending ? ["\(name) · Pending"] : []
        return [
            ["\(name) · \(status(at: date, compact: true, locale: locale))"] + short + [name],
            ["You \(you) · \(name) \(them)", "You \(you) · \(them)"],
        ] + [updatedLine(at: date, locale: locale, timeZone: timeZone).map { [$0] }].compactMap { $0 }
    }

    func circular(at date: Date, locale: Locale = .current) -> (caption: String, value: String) {
        let margin = competitionSignedMarginText(
            userPoints: userPoints, opponentPoints: opponentPoints,
            fractionDigits: finalDigits, locale: locale
        )
        if let place = groupPlaceText {
            return (status(at: date, compact: true, locale: locale).uppercased(), place.uppercased())
        }
        switch state(at: date) {
        case .scheduled: return ("DAY 1", weekday("EEE", locale: locale))
        case .final(.win): return ("WON", margin)
        case .final(.loss): return ("LOST", margin)
        case .final(.tie): return ("TIED", margin)
        case .live, .finalPending, .gone: return ("LEAD", margin)
        }
    }

    func accessibilityLabel(
        at date: Date,
        redacted: Bool,
        circular: Bool = false,
        standings: Bool = false,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let state = state(at: date)
        if let label = groupAccessibilityLabel(at: date, redacted: redacted, standings: standings, locale: locale) {
            return label
        }
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

extension CompetitionWidgetSnapshot.Group {
    func placeText(_ place: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .ordinal
        return formatter.string(from: place as NSNumber) ?? String(place)
    }
}

extension CompetitionWidgetSnapshot.Match {
    func groupHeader(at date: Date, locale: Locale = .current) -> String? {
        group.map { "\($0.title) · \(status(at: date, compact: true, locale: locale))" }
    }

    var groupPlaceText: String? {
        guard let group, !group.isDoubles, let place = group.yourPlace else { return nil }
        return group.placeText(place)
    }

    func groupAccessibilityLabel(
        at date: Date, redacted: Bool, standings: Bool = false, locale: Locale = .current
    ) -> String? {
        guard let group, !redacted else { return nil }
        let header = "\(group.title), \(status(at: date, locale: locale))."
        if group.isDoubles {
            let teams = group.rows.map {
                "\($0.isYou ? "Your team" : $0.name) \(competitionPointsAccessibilityText($0.points, locale: locale))."
            }
            return ([header] + teams + [group.lead.map { $0 + "." }].compactMap { $0 }).joined(separator: " ")
        }
        let place = groupPlaceText.map { "You're \($0)." }
        let seats = standings ? group.rows.map {
            "\(group.placeText($0.place)), \($0.name), \(competitionPointsAccessibilityText($0.points, locale: locale))."
        } : []
        return ([header, place, group.lead.map { $0 + "." }].compactMap { $0 } + seats).joined(separator: " ")
    }
}

struct CompetitionWidgetEmptyText: Equatable, Sendable {
    let title: String
    let line: String?
    let compact: [String]
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

extension CompetitionWidgetSnapshot {
    static func fileURL(bundle: Bundle = .main) -> URL? {
        guard let group = bundle.object(forInfoDictionaryKey: "HEALTHCOMP_APP_GROUP") as? String,
              !group.isEmpty,
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group
              )
        else { return nil }
        return container.appendingPathComponent(fileName)
    }

    static func load(from url: URL?) -> Self? {
        guard let url,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Self.self, from: data),
              snapshot.version == currentVersion
        else { return nil }
        return snapshot
    }

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
    static func testLab(_ scenario: String, now: Date, scheme: String) -> Self? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
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
        var four = match(11, "Sam", person: "group:four", currentDay: 4, you: 1_664, them: 1_712,
                         youDays: [421, 437, 398, 408], themDays: [448, 402, 451, 411], updated: false)
        four.group = Group(title: "Four-Way", isDoubles: false, rows: [
            .init(place: 1, name: "Sam", points: 1_712, isYou: false),
            .init(place: 2, name: "You", points: 1_664, isYou: true),
            .init(place: 3, name: "Priya", points: 1_498, isYou: false),
            .init(place: 4, name: "Leo", points: 1_203, isYou: false),
        ], lead: "48 behind Sam")
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
        case "card":
            matches = [
                sam, four,
                match(13, "Robin", currentDay: 3, you: 325, them: 696, youDays: [142, 152, 31],
                      themDays: [388, 121, 187], chase: Chase(day: 3, points: 372)),
                match(8, "Riley", currentDay: 8, you: 2_171, them: 2_190, youDays: theirs, themDays: week),
                match(14, "Jo", currentDay: 9, you: 1_840, them: 1_726, youDays: week, themDays: theirs,
                      final: .win),
            ]
        case "noData":
            matches = [match(5, "Sam", currentDay: 4, you: 742, them: 510,
                             youDays: [250, 230, 262], themDays: [230, 280, nil], updated: false)]
        case "samGone":
            matches = [alex, match(5, "Sam", currentDay: 12, you: 1_840, them: 1_726, final: .win, leavesInDays: -1)]
        case "noSam": matches = [alex]
        case "groupFFA": matches = [four]
        case "groupDoubles":
            var doubles = match(12, "Sam + Leo", person: "group:doubles", currentDay: 4, you: 3_162, them: 2_915,
                                youDays: [801, 802, 800, 759], themDays: [758, 744, 739, 674], updated: false)
            doubles.group = Group(title: "Doubles", isDoubles: true, rows: [
                .init(place: 1, name: "You + Priya", points: 3_162, isYou: true),
                .init(place: 2, name: "Sam + Leo", points: 2_915, isYou: false),
            ], lead: "Your team up 247")
            matches = [doubles]
        case "stale":
            matches = [match(5, "Sam", currentDay: 5, you: 1_204, them: 1_150,
                             youDays: week, themDays: theirs, updatedAgo: 3 * 3_600)]
        case "closeFinal":
            matches = [match(5, "Sam", currentDay: 9, you: 1_840.25, them: 1_840.40,
                             youDays: theirs, themDays: week, final: .loss)]
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
