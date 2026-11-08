import Foundation

// Foundation only: the app and both watch targets compile this file. All the
// watch's logic lives here so HealthCompTests covers it with no watch CI lane.

/// What the iPhone sends. No `snapshot` means clear.
struct CompetitionWatchPayload: Equatable, Sendable {
    private static let sentAtKey = "sentAt"
    private static let snapshotKey = "snapshot"

    var sentAt: TimeInterval
    var snapshot: Data?

    /// `personID` is the other person's account id. The watch never uses it,
    /// so it doesn't leave the iPhone.
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

    /// Nil with no `sentAt`: a fresh session's context is empty.
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

    /// Context and user info can arrive out of order, so older data is
    /// ignored. A clear isn't: a phone clock moved back mustn't drop a sign-out
    /// wipe. A bad payload clears too, failing closed.
    func action(after seen: TimeInterval?) -> Action {
        guard let snapshot else { return sentAt == seen ? .ignore : .clear }
        if let seen, sentAt <= seen { return .ignore }
        guard let decoded = try? JSONDecoder().decode(CompetitionWidgetSnapshot.self, from: snapshot),
              decoded.version == CompetitionWidgetSnapshot.currentVersion
        else { return .clear }
        return .store(decoded)
    }
}

/// What this watch has already been told and shown, in one small file.
struct CompetitionWatchSeen: Codable, Equatable, Sendable {
    var sentAt: TimeInterval?
    /// Finals whose first reveal has played.
    var finals: Set<UUID> = []

    func isFirstSight(of match: CompetitionWidgetSnapshot.Match, at date: Date) -> Bool {
        if case .final = match.state(at: date) { !finals.contains(match.id) } else { false }
    }

    mutating func prune(keeping snapshot: CompetitionWidgetSnapshot) {
        finals.formIntersection(snapshot.matches.map(\.id))
    }
}

/// The largest scoreboard numerals that fit `width` side by side. 0.34 em per
/// character is SF Compressed's calibration knob. Never truncates: `1,840.25`
/// lands around 27 pt on 41 mm.
func competitionWatchScoreSize(you: String, them: String, width: CGFloat) -> CGFloat {
    min(56, floor((width - 8) / (0.34 * CGFloat(you.count + them.count))))
}

extension CompetitionWidgetSnapshot {
    /// One page per match, featured first, so page 1 is what the complication shows.
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

extension CompetitionWidgetSnapshot.Match {
    /// The Board's line goes after this long without an update from the phone.
    static let staleAfter: TimeInterval = 3_600

    enum Side: Equatable, Sendable { case you, square, them }

    /// From the numbers as shown, so a final decided by decimals isn't square.
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

    /// "Day 5", "Last day", "Pending", "Final".
    func boardStatus(at date: Date, locale: Locale = .current) -> String {
        switch state(at: date) {
        case .finalPending: "Pending"
        case .final: "Final"
        default: status(at: date, compact: true, locale: locale)
        }
    }

    /// "+54 · Day 5 · Sam": the number first, so a short slot cuts the name.
    /// One string redacts whole, so wrist-down it's the status alone.
    func inlineText(at date: Date, redacted: Bool = false, locale: Locale = .current) -> String {
        if redacted { return boardStatus(at: date, locale: locale) }
        if state(at: date) == .scheduled {
            return "Day 1 is \(weekday("EEE", locale: locale)) · \(name)"
        }
        return "\(circular(at: date, locale: locale).value) · \(boardStatus(at: date, locale: locale)) · \(name)"
    }

    /// "DAY 5 · SAM", "FINAL · SAM", "DAY 1 · SAM". Wrist-down, no name.
    func cornerLabel(at date: Date, redacted: Bool = false, locale: Locale = .current) -> String {
        let status = state(at: date) == .scheduled ? "Day 1" : boardStatus(at: date, locale: locale)
        return (redacted ? status : "\(status) · \(name)").uppercased()
    }

    /// The chase bar while you trail on the day the phone worked it out for:
    /// your points today against those plus what it takes ("55", "213 of 268
    /// today"), or an empty bar and "Out of reach today".
    func chase(
        at date: Date,
        locale: Locale = .current
    ) -> (fill: Double, lead: String?, line: String, spoken: String)? {
        guard let chase, side == .them, state(at: date) == .live(day: chase.day) else { return nil }
        guard let points = chase.points else {
            return (0, nil, "Out of reach today", "Out of reach today.")
        }
        let today = userDayPoints.indices.contains(chase.day - 1) ? userDayPoints[chase.day - 1] ?? 0 : 0
        let total = competitionPointsText(today + points, locale: locale)
        let line = "\(competitionPointsText(today, locale: locale)) of \(total) today"
        return (
            today / max(today + points, 1),
            competitionPointsText(points, locale: locale),
            line,
            "\(competitionPointsAccessibilityText(points, locale: locale)) to take the lead. \(line)."
        )
    }

    /// "2 defenses", or nil before the first.
    var beltDefensesText: String? {
        guard let defenses = belt?.defenses, defenses > 0 else { return nil }
        return defenses == 1 ? "1 defense" : "\(defenses) defenses"
    }

    /// VoiceOver's belt sentence for the Board.
    var beltAccessibilityText: String? {
        guard let belt else { return nil }
        let standing = belt.holder == .you ? "You hold the belt" : "\(name) holds the belt"
        return [standing, beltDefensesText].compactMap { $0 }.joined(separator: ", ") + "."
    }

    /// The words on the belt card, nil when this result doesn't earn one.
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
}
