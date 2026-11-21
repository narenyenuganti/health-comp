import Foundation

struct CompetitionWatchPayload: Equatable, Sendable {
    private static let sentAtKey = "sentAt"
    private static let snapshotKey = "snapshot"

    var sentAt: TimeInterval
    var snapshot: Data?

    init(snapshot: CompetitionWidgetSnapshot?, sentAt: TimeInterval) {
        self.sentAt = sentAt
        self.snapshot = snapshot.flatMap { snapshot in
            var copy = snapshot
            copy.matches = snapshot.matches.map {
                var match = $0
                match.personID = ""
                return match
            }
            return try? JSONEncoder().encode(copy)
        }
    }

    init?(_ dictionary: [String: Any]) {
        guard let sentAt = dictionary[Self.sentAtKey] as? TimeInterval else { return nil }
        self.sentAt = sentAt
        snapshot = dictionary[Self.snapshotKey] as? Data
    }

    var dictionary: [String: Any] {
        var dictionary: [String: Any] = [Self.sentAtKey: sentAt]
        dictionary[Self.snapshotKey] = snapshot
        return dictionary
    }

    enum Action: Equatable {
        case ignore, clear
        case store(CompetitionWidgetSnapshot)
    }

    func action(after seen: TimeInterval?) -> Action {
        guard let snapshot else { return sentAt == seen ? .ignore : .clear }
        if let seen, sentAt <= seen { return .ignore }
        guard let decoded = try? JSONDecoder().decode(CompetitionWidgetSnapshot.self, from: snapshot),
              decoded.version == CompetitionWidgetSnapshot.currentVersion
        else { return .clear }
        return .store(decoded)
    }
}

struct CompetitionWatchSeen: Codable, Equatable, Sendable {
    var sentAt: TimeInterval?
    var finals: Set<UUID> = []

    func isFirstSight(of match: CompetitionWidgetSnapshot.Match, at date: Date) -> Bool {
        if case .final = match.state(at: date) { !finals.contains(match.id) } else { false }
    }

    mutating func prune(keeping snapshot: CompetitionWidgetSnapshot) {
        finals.formIntersection(snapshot.matches.map(\.id))
    }
}

func competitionWatchScoreSize(you: String, them: String, width: CGFloat) -> CGFloat {
    min(56, floor((width - 8) / (0.34 * CGFloat(you.count + them.count))))
}

extension CompetitionWidgetSnapshot {
    func pages(at date: Date) -> [Match] {
        var rest = self
        var pages: [Match] = []
        while let next = rest.featured(personID: nil, at: date) {
            pages.append(next)
            rest.matches.removeAll { $0.id == next.id }
        }
        return pages
    }
}

enum CompetitionWatchAlert {
    static func competitionID(_ userInfo: [AnyHashable: Any]) -> UUID? {
        guard userInfo["healthcomp.route.v"] as? Int == 1,
              userInfo["healthcomp.route.kind"] as? String == "competition",
              let id = userInfo["healthcomp.route.competitionID"] as? String
        else { return nil }
        return UUID(uuidString: id)
    }
}

struct CompetitionWatchChase: Equatable, Sendable {
    var fill: Double
    var lead: String?
    var line: String
    var suggestion: String?
    var spoken: String
}

struct CompetitionWatchPlayedDay: Equatable, Sendable {
    var day: String
    var spoken: String
    var you: Double?
    var them: Double?
    var isToday: Bool
    var isUpcoming: Bool
}

extension CompetitionWidgetSnapshot.TodayRings.RingKind {
    var displayName: String {
        switch self {
        case .move: "Move"
        case .exercise: "Exercise"
        case .stand: "Stand"
        case .sleep: "Sleep"
        }
    }
}

extension CompetitionWidgetSnapshot.Rivalry {
    var recordText: String {
        ([wins, losses] + (ties > 0 ? [ties] : [])).map(String.init).joined(separator: "–")
    }

    func accessibilityLabel(opponentName: String) -> String {
        func count(_ value: Int, _ one: String, _ many: String) -> String {
            "\(value) \(value == 1 ? one : many)"
        }
        var parts = [
            "All-time versus \(opponentName): \(count(wins, "win", "wins")), \(count(losses, "loss", "losses"))"
                + (ties > 0 ? ", \(count(ties, "tie", "ties"))" : "") + ".",
        ]
        if let formLine { parts.append(formLine.hasSuffix(".") ? formLine : formLine + ".") }
        if let edgeRing, let edgeRecord {
            parts.append("Strongest ring: \(edgeRing.displayName), \(edgeRecord).")
        }
        return parts.joined(separator: " ")
    }
}

extension CompetitionWidgetSnapshot.Match {
    static let staleAfter: TimeInterval = 3_600

    enum Side: Equatable, Sendable { case you, square, them }

    var side: Side {
        let margin = competitionDisplayedMargin(
            userPoints: userPoints, opponentPoints: opponentPoints, fractionDigits: finalDigits
        )
        return margin > 0 ? .you : margin < 0 ? .them : .square
    }

    func isStale(at date: Date) -> Bool {
        guard state(at: date).isLiveOrPending, let updatedAt else { return false }
        return date.timeIntervalSince(updatedAt) > Self.staleAfter
    }

    func boardStatus(at date: Date, locale: Locale = .current) -> String {
        switch state(at: date) {
        case .finalPending: "Pending"
        case .final: "Final"
        default: status(at: date, compact: true, locale: locale)
        }
    }

    func inlineText(at date: Date, redacted: Bool = false, locale: Locale = .current) -> String {
        if redacted { return boardStatus(at: date, locale: locale) }
        if let group {
            return "\(circular(at: date, locale: locale).value) · \(boardStatus(at: date, locale: locale)) · \(group.title)"
        }
        if state(at: date) == .scheduled {
            return "Day 1 is \(weekday("EEE", locale: locale)) · \(name)"
        }
        return "\(circular(at: date, locale: locale).value) · \(boardStatus(at: date, locale: locale)) · \(name)"
    }

    func cornerLabel(at date: Date, redacted: Bool = false, locale: Locale = .current) -> String {
        let status = state(at: date) == .scheduled ? "Day 1" : boardStatus(at: date, locale: locale)
        return (redacted ? status : "\(status) · \(group?.title ?? name)").uppercased()
    }

    func chase(
        at date: Date,
        locale: Locale = .current
    ) -> CompetitionWatchChase? {
        guard let chase, side == .them, state(at: date) == .live(day: chase.day) else { return nil }
        guard let points = chase.points else {
            return CompetitionWatchChase(
                fill: 0, lead: nil, line: "Out of reach today", suggestion: nil, spoken: "Out of reach today."
            )
        }
        let today = userDayPoints.indices.contains(chase.day - 1) ? userDayPoints[chase.day - 1] ?? 0 : 0
        let total = competitionPointsText(today + points, locale: locale)
        let line = "\(competitionPointsText(today, locale: locale)) of \(total) today"
        return CompetitionWatchChase(
            fill: today / max(today + points, 1),
            lead: competitionPointsText(points, locale: locale),
            line: line,
            suggestion: chase.suggestion,
            spoken: "\(competitionPointsAccessibilityText(points, locale: locale)) to take the lead. \(line)."
        )
    }

    func activeTodayRings(at date: Date) -> CompetitionWidgetSnapshot.TodayRings? {
        guard let todayRings, state(at: date) == .live(day: todayRings.dayOrdinal), !todayRings.rows.isEmpty
        else { return nil }
        return todayRings
    }

    func todayScores(at date: Date) -> (you: Double?, them: Double?) {
        let index: Int? = switch state(at: date) {
        case let .live(day): day - 1
        case .finalPending: 6
        default: nil
        }
        guard let index else { return (nil, nil) }
        return (
            userDayPoints.indices.contains(index) ? userDayPoints[index] : nil,
            opponentDayPoints.indices.contains(index) ? opponentDayPoints[index] : nil
        )
    }

    func playedDayPoints(at date: Date, locale: Locale = .current) -> [CompetitionWatchPlayedDay] {
        let rows = weekRows(locale: locale)
        let outcomes = dayOutcomes(at: date)
        let currentIndex: Int? = if case let .live(day) = state(at: date) { day - 1 } else { nil }
        return rows.enumerated().map { index, row in
            let upcoming = outcomes.indices.contains(index) && outcomes[index] == .upcoming
            let you = !upcoming && userDayPoints.indices.contains(index) ? userDayPoints[index] : nil
            let them = !upcoming && opponentDayPoints.indices.contains(index) ? opponentDayPoints[index] : nil
            return CompetitionWatchPlayedDay(
                day: row.day,
                spoken: row.spoken,
                you: you,
                them: them,
                isToday: index == currentIndex,
                isUpcoming: upcoming
            )
        }
    }

    func roundTally(at date: Date) -> (won: Int, lost: Int, tied: Int) {
        let outcomes = dayOutcomes(at: date)
        return (
            outcomes.filter { $0 == .won }.count,
            outcomes.filter { $0 == .lost }.count,
            outcomes.filter { $0 == .tied }.count
        )
    }

    func weekHeaderTitle(at date: Date) -> String {
        guard let group, !group.isDoubles else { return "Week rounds" }
        return group.yourPlace == 1 ? "Week vs 2nd" : "Week vs 1st"
    }

    var customMetricsAccessibilityText: String? {
        guard let customMetrics, !customMetrics.isEmpty else { return nil }
        return "Metrics: \(customMetrics.map(\.displayName).joined(separator: ", "))."
    }

    var beltDefensesText: String? {
        guard let defenses = belt?.defenses, defenses > 0 else { return nil }
        return defenses == 1 ? "1 defense" : "\(defenses) defenses"
    }

    var beltAccessibilityText: String? {
        guard let belt else { return nil }
        let standing = belt.holder == .you ? "You hold the belt" : "\(name) holds the belt"
        return [standing, beltDefensesText].compactMap { $0 }.joined(separator: ", ") + "."
    }

    var beltCardText: (headline: String, line: String, detail: [String])? {
        func reign(_ owner: String, _ weeks: Int, _ defenses: Int) -> [String] {
            let count = defenses == 1 ? "1 defense" : "\(defenses) defenses"
            return ["\(owner) reign: \(weeks) \(weeks == 1 ? "week" : "weeks")"] + (defenses > 0 ? [count] : [])
        }
        switch belt?.card {
        case .none: return nil
        case .earned: return ("AND NEW", "You took the belt", [])
        case let .taken(weeks, defenses):
            return ("AND NEW", "You took the belt from \(name)", reign("\(name)’s", weeks, defenses))
        case let .lost(weeks, defenses):
            return ("AND NEW", "\(name) took the belt", reign("Your", weeks, defenses))
        case let .defended(count):
            let formatter = NumberFormatter()
            formatter.numberStyle = .ordinal
            formatter.locale = Locale(identifier: "en_US")
            return ("AND STILL", "\(formatter.string(from: count as NSNumber) ?? "\(count)") title defense", [])
        }
    }

    func cardRow(
        at date: Date,
        firstSight: Bool,
        locale: Locale = .current
    ) -> (name: String, line: String, value: String, isYours: Bool, spoken: String) {
        let board = boardStatus(at: date, locale: locale)
        if let group {
            let place = group.yourPlace
            return (
                group.title, group.lead ?? board, place.map(group.placeText) ?? "", place == 1,
                groupAccessibilityLabel(at: date, redacted: false, locale: locale) ?? group.title
            )
        }
        let spoken = accessibilityLabel(at: date, redacted: false, locale: locale)
        switch state(at: date) {
        case .scheduled:
            return (name, status(at: date, locale: locale), "", false, spoken)
        case let .final(outcome):
            if firstSight { return (name, board, "", false, "\(name), Final.") }
            let value = switch outcome {
            case .win: "Won"
            case .loss: "Lost"
            case .tie: "Tied"
            }
            return (name, board, value, outcome == .win, spoken)
        default:
            let chasing = chase(at: date, locale: locale)
            let line = chasing.map { $0.lead.map { "\($0) to lead" } ?? $0.line } ?? board
            let lead = accessibilityLabel(at: date, redacted: false, circular: true, locale: locale)
            return (
                name, line, circular(at: date, locale: locale).value, side == .you,
                "\(lead). \(chasing?.spoken ?? board + ".")"
            )
        }
    }

    func hasWeek(at date: Date) -> Bool {
        guard group == nil else { return false }
        return switch state(at: date) {
        case .live, .finalPending, .final: true
        case .scheduled, .gone: false
        }
    }

    func weekRows(locale: Locale = .current) -> [(day: String, spoken: String, you: String?, them: String?)] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        func points(_ values: [Double?], _ index: Int) -> String? {
            guard values.indices.contains(index), let value = values[index] else { return nil }
            return competitionPointsText(value, locale: locale)
        }
        return dayStarts.enumerated().map { index, start in
            formatter.setLocalizedDateFormatFromTemplate("EEEEE")
            let day = formatter.string(from: start)
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            return (day, formatter.string(from: start), points(userDayPoints, index), points(opponentDayPoints, index))
        }
    }
}
