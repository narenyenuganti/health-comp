import Foundation

/// One banter line for a match day, or nothing.
///
/// The same scores and match day always produce the same line. Phones with
/// different sync states can disagree. At most one line, in this order:
/// team imbalance, then far off the lead, then a bot ahead of a person.
public enum MatchBanter {
    /// Hard carry and deadweight are one imbalance event. The match-day hash
    /// picks the phrasing when both describe legal human subjects.
    public enum Phrasing: Equatable, Sendable {
        case hardCarry, deadweight
    }

    public enum Kind: Equatable, Sendable {
        case teamImbalance(Phrasing)
        case farOffLead
        /// `mode` is the caller's bot mode name: pacer, chill, erratic, or beast.
        case botAhead(String)
    }

    public struct Template: Equatable, Sendable {
        public let thirdPerson: String
        public let secondPerson: String
    }

    public struct Line: Equatable, Sendable {
        public let kind: Kind
        /// Subject first. Imbalance then names the partner. Far off the lead then names the leader.
        public let subjectSeatIDs: [UUID]
        public let templateIndex: Int
        /// Subject's whole-percent team share, truncating. Set for team imbalance.
        public let percent: Int?
        /// Whole-point gap, truncating centipoints / 100. Set for far off the lead and a bot ahead.
        public let points: Int?
    }

    public static func line(matchID: UUID, configuration: MatchConfiguration, dayOrdinal: Int,
                            days: [MatchDayScore], botModes: [UUID: String] = [:]) throws -> Line? {
        guard (1...7).contains(dayOrdinal) else { throw MatchScoringError.invalidDay }
        let projection = try MatchScoring.standings(configuration: configuration, days: days, throughDay: dayOrdinal)
        if dayOrdinal < 3 { return nil }
        let hash = selectionHash(matchID: matchID, dayOrdinal: dayOrdinal)
        if let imbalance = try teamImbalance(configuration: configuration, days: days, dayOrdinal: dayOrdinal, hash: hash) {
            return imbalance
        }
        if let trailing = farOffLead(configuration: configuration, projection: projection, days: days,
                                    dayOrdinal: dayOrdinal, hash: hash) {
            return trailing
        }
        return botAhead(configuration: configuration, projection: projection, days: days,
                        dayOrdinal: dayOrdinal, botModes: botModes, hash: hash)
    }

    /// Second person when the viewer is the subject. Everyone else, including a bot seat, gets third person.
    public static func render(_ line: Line, names: [UUID: String], viewerSeatID: UUID) -> String {
        let bank = templates(for: line.kind)
        precondition(line.subjectSeatIDs.isEmpty == false && bank.indices.contains(line.templateIndex))
        let subject = line.subjectSeatIDs[0]
        var text = viewerSeatID == subject ? bank[line.templateIndex].secondPerson : bank[line.templateIndex].thirdPerson
        if let percent = line.percent { text = text.replacingOccurrences(of: "{percent}", with: String(percent)) }
        if let points = line.points { text = text.replacingOccurrences(of: "{points}", with: String(points)) }
        text = text.replacingOccurrences(of: "{subject}", with: names[subject] ?? "")
        if line.subjectSeatIDs.count > 1 {
            let other = names[line.subjectSeatIDs[1]] ?? ""
            text = text.replacingOccurrences(of: "{partner}", with: other)
            text = text.replacingOccurrences(of: "{leader}", with: other)
        }
        return text
    }

    public static func templates(for kind: Kind) -> [Template] {
        switch kind {
        case .teamImbalance(.hardCarry): return MatchBanterCopy.hardCarry
        case .teamImbalance(.deadweight): return MatchBanterCopy.deadweight
        case .farOffLead: return MatchBanterCopy.farOffLead
        case let .botAhead(mode): return MatchBanterCopy.bots[mode] ?? []
        }
    }

    /// FNV-1a 64 over the UUID's RFC 4122 bytes (the hex pairs of `uuidString`, hyphens dropped)
    /// followed by the day ordinal as one byte. Bit 0 picks a phrasing: even is hard carry.
    /// Template index is `(hash >> 1) % count`. This is not `Swift.Hasher`.
    static func selectionHash(matchID: UUID, dayOrdinal: Int) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let hex = matchID.uuidString.replacingOccurrences(of: "-", with: "")
        var cursor = hex.startIndex
        for _ in 0..<16 {
            let next = hex.index(cursor, offsetBy: 2)
            hash ^= UInt64(UInt8(hex[cursor..<next], radix: 16)!)
            hash &*= 1_099_511_628_211
            cursor = next
        }
        hash ^= UInt64(dayOrdinal)
        hash &*= 1_099_511_628_211
        return hash
    }

    /// Lower team number wins when both doubles teams are imbalanced.
    /// A bot is never the subject. Both humans on the team need an accepted score today,
    /// because some lines in the chosen phrasing name the partner.
    private static func teamImbalance(configuration: MatchConfiguration, days: [MatchDayScore],
                                      dayOrdinal: Int, hash: UInt64) throws -> Line? {
        guard configuration.format == .doubles else { return nil }
        var byTeam: [Int: [MatchSeat]] = [:]
        for seat in configuration.seats {
            guard let team = seat.team else { continue }
            byTeam[team, default: []].append(seat)
        }
        for team in byTeam.keys.sorted() {
            let seats = byTeam[team]!
            let humans = seats.filter(isHuman)
            guard humans.isEmpty == false, humans.allSatisfy({ hasAcceptedScore(days, seatID: $0.id, ordinal: dayOrdinal) }) else {
                continue
            }
            var hardCarry: (UUID, Int)?
            var deadweight: (UUID, Int)?
            for human in humans {
                guard let share = try MatchScoring.teamShare(seat: human.id, configuration: configuration,
                                                            days: days, throughDay: dayOrdinal) else { continue }
                let percent = (100 * share.numerator) / share.denominator
                if 100 * share.numerator > 65 * share.denominator {
                    hardCarry = (human.id, percent)
                } else if 100 * share.numerator < 35 * share.denominator {
                    deadweight = (human.id, percent)
                }
            }
            let picked: (Phrasing, UUID, Int)?
            switch (hardCarry, deadweight) {
            case let (hard?, dead?):
                picked = (hash & 1) == 0 ? (.hardCarry, hard.0, hard.1) : (.deadweight, dead.0, dead.1)
            case let (hard?, nil):
                picked = (.hardCarry, hard.0, hard.1)
            case let (nil, dead?):
                picked = (.deadweight, dead.0, dead.1)
            case (nil, nil):
                picked = nil
            }
            guard let (phrasing, subject, percent) = picked,
                  let partner = seats.first(where: { $0.id != subject }) else { continue }
            let kind = Kind.teamImbalance(phrasing)
            return Line(kind: kind, subjectSeatIDs: [subject, partner.id],
                        templateIndex: templateIndex(hash, count: templates(for: kind).count),
                        percent: percent, points: nil)
        }
        return nil
    }

    /// Free-for-all only. Last place must be a human more than 400 points (40,000 centipoints) behind first.
    /// Equality does not fire. A bot may be the named leader. Tied seats break by ascending seat id.
    private static func farOffLead(configuration: MatchConfiguration, projection: MatchScoreProjection,
                                   days: [MatchDayScore], dayOrdinal: Int, hash: UInt64) -> Line? {
        guard configuration.format == .freeForAll,
              let lead = projection.standings.first(where: { $0.place == 1 })?.centipoints,
              let lastPlace = projection.standings.map(\.place).max() else { return nil }
        let leaders = projection.standings.compactMap { standing -> UUID? in
            guard standing.place == 1, case let .seat(id) = standing.subject else { return nil }
            if isHuman(configuration.seats, id), hasAcceptedScore(days, seatID: id, ordinal: dayOrdinal) == false {
                return nil
            }
            return id
        }
        let trailing = projection.standings.compactMap { standing -> (UUID, Int)? in
            guard standing.place == lastPlace, case let .seat(id) = standing.subject else { return nil }
            guard isHuman(configuration.seats, id), hasAcceptedScore(days, seatID: id, ordinal: dayOrdinal) else { return nil }
            guard lead - standing.centipoints > 40_000 else { return nil }
            return (id, standing.centipoints)
        }
        guard let leader = leaders.min(by: { $0.uuidString < $1.uuidString }),
              let subject = trailing.min(by: { $0.0.uuidString < $1.0.uuidString }) else { return nil }
        return Line(kind: .farOffLead, subjectSeatIDs: [subject.0, leader],
                    templateIndex: templateIndex(hash, count: templates(for: .farOffLead).count),
                    percent: nil, points: (lead - subject.1) / 100)
    }

    /// Strictly ahead on week-to-date seat totals. Tied pairs break by bot seat id, then the human's.
    private static func botAhead(configuration: MatchConfiguration, projection: MatchScoreProjection,
                                 days: [MatchDayScore], dayOrdinal: Int, botModes: [UUID: String], hash: UInt64) -> Line? {
        var pairs: [(bot: UUID, human: UUID, mode: String, points: Int)] = []
        for seat in configuration.seats {
            guard case .bot = seat.kind, let mode = botModes[seat.id], templates(for: .botAhead(mode)).isEmpty == false,
                  let botTotal = projection.seatTotals[seat.id] else { continue }
            for human in configuration.seats where isHuman(human) && hasAcceptedScore(days, seatID: human.id, ordinal: dayOrdinal) {
                guard let humanTotal = projection.seatTotals[human.id], botTotal > humanTotal else { continue }
                pairs.append((seat.id, human.id, mode, (botTotal - humanTotal) / 100))
            }
        }
        guard let pair = pairs.min(by: { lhs, rhs in
            if lhs.bot.uuidString != rhs.bot.uuidString { return lhs.bot.uuidString < rhs.bot.uuidString }
            return lhs.human.uuidString < rhs.human.uuidString
        }) else { return nil }
        let kind = Kind.botAhead(pair.mode)
        return Line(kind: kind, subjectSeatIDs: [pair.human],
                    templateIndex: templateIndex(hash, count: templates(for: kind).count),
                    percent: nil, points: pair.points)
    }

    private static func templateIndex(_ hash: UInt64, count: Int) -> Int {
        Int((hash >> 1) % UInt64(count))
    }

    private static func isHuman(_ seat: MatchSeat) -> Bool {
        if case .human = seat.kind { return true }
        return false
    }

    private static func isHuman(_ seats: [MatchSeat], _ id: UUID) -> Bool {
        guard let seat = seats.first(where: { $0.id == id }) else { return false }
        return isHuman(seat)
    }

    /// An accepted available score is centipoints for that day, including zero. Missing, not synced,
    /// unavailable, and after-leave do not qualify.
    private static func hasAcceptedScore(_ days: [MatchDayScore], seatID: UUID, ordinal: Int) -> Bool {
        for day in days where day.seatID == seatID && day.ordinal == ordinal {
            if case .centipoints = day.value { return true }
            return false
        }
        return false
    }
}

/// Line bank. Edit the copy here. Selection does not read the words.
/// Placeholders: {subject} {partner} {leader} {percent} {points}.
private enum MatchBanterCopy {
    static let hardCarry: [MatchBanter.Template] = [
        .init(thirdPerson: "{subject} has {percent}% of the team's points. A permit may be required.",
              secondPerson: "You have {percent}% of your team's points. A permit may be required."),
        .init(thirdPerson: "{subject} has {percent}% of the team's points. {partner} is here in spirit.",
              secondPerson: "You have {percent}% of your team's points. {partner} is here in spirit."),
        .init(thirdPerson: "{subject} has {percent}% of the team's points. Solo, with a plus-one.",
              secondPerson: "You have {percent}% of your team's points. Solo, with a plus-one."),
        .init(thirdPerson: "{subject} has {percent}% of the team's points. The trophy fits one name.",
              secondPerson: "You have {percent}% of your team's points. The trophy fits one name."),
        .init(thirdPerson: "{subject} has {percent}% of the team's points. {partner} is on mute.",
              secondPerson: "You have {percent}% of your team's points. {partner} is on mute."),
        .init(thirdPerson: "{subject} has {percent}% of the team's points. {partner} brought a camera.",
              secondPerson: "You have {percent}% of your team's points. {partner} brought a camera."),
        .init(thirdPerson: "{subject} has {percent}% of the team's points. {partner} is nearby, allegedly.",
              secondPerson: "You have {percent}% of your team's points. {partner} is nearby, allegedly."),
        .init(thirdPerson: "{subject} has {percent}% of the team's points. Special thanks to {partner}.",
              secondPerson: "You have {percent}% of your team's points. Special thanks to {partner}."),
        .init(thirdPerson: "{subject} has {percent}% of the team's points. {partner} is on the sideline.",
              secondPerson: "You have {percent}% of your team's points. {partner} is on the sideline."),
    ]

    static let deadweight: [MatchBanter.Template] = [
        .init(thirdPerson: "{subject} has {percent}% of the team's points. {partner} did not agree to this.",
              secondPerson: "You have {percent}% of your team's points. {partner} did not agree to this."),
        .init(thirdPerson: "{subject} has {percent}% of the team's points. The pie chart is rude.",
              secondPerson: "You have {percent}% of your team's points. The pie chart is rude."),
        .init(thirdPerson: "{subject} has {percent}% of the team's points. A cameo, at best.",
              secondPerson: "You have {percent}% of your team's points. A cameo, at best."),
        .init(thirdPerson: "{subject} has {percent}% of the team's points. {partner} requested a recount.",
              secondPerson: "You have {percent}% of your team's points. {partner} requested a recount."),
        .init(thirdPerson: "{subject} has {percent}% of the team's points. Blink and it is gone.",
              secondPerson: "You have {percent}% of your team's points. Blink and it is gone."),
        .init(thirdPerson: "{subject} has {percent}% of the team's points. Credits list {subject} last.",
              secondPerson: "You have {percent}% of your team's points. Credits list you last."),
        .init(thirdPerson: "{subject} has {percent}% of the team's points. {partner} has the highlights.",
              secondPerson: "You have {percent}% of your team's points. {partner} has the highlights."),
        .init(thirdPerson: "{subject} has {percent}% of the team's points. {partner} has questions.",
              secondPerson: "You have {percent}% of your team's points. {partner} has questions."),
        .init(thirdPerson: "{subject} has {percent}% of the team's points. {partner} took a victory lap.",
              secondPerson: "You have {percent}% of your team's points. {partner} took a victory lap."),
        .init(thirdPerson: "{subject} has {percent}% of the team's points. {partner} has the wheel.",
              secondPerson: "You have {percent}% of your team's points. {partner} has the wheel."),
    ]

    static let farOffLead: [MatchBanter.Template] = [
        .init(thirdPerson: "{subject} is {points} off the lead. Thoughts and prayers.",
              secondPerson: "You are {points} off the lead. Thoughts and prayers."),
        .init(thirdPerson: "{subject} is {points} off the lead. Send a postcard.",
              secondPerson: "You are {points} off the lead. Send a postcard."),
        .init(thirdPerson: "{subject} is {points} off the lead. Bring binoculars.",
              secondPerson: "You are {points} off the lead. Bring binoculars."),
        .init(thirdPerson: "{subject} is {points} off the lead. {leader} is in a different week.",
              secondPerson: "You are {points} off the lead. {leader} is in a different week."),
        .init(thirdPerson: "{subject} is {points} off the lead. The map gave up.",
              secondPerson: "You are {points} off the lead. The map gave up."),
        .init(thirdPerson: "{subject} is {points} off the lead. Still on the same app, somehow.",
              secondPerson: "You are {points} off the lead. Still on the same app, somehow."),
        .init(thirdPerson: "{subject} is {points} off the lead. {leader} cannot hear {subject}.",
              secondPerson: "You are {points} off the lead. {leader} cannot hear you."),
        .init(thirdPerson: "{subject} is {points} off the lead. That is a valley, not a gap.",
              secondPerson: "You are {points} off the lead. That is a valley, not a gap."),
        .init(thirdPerson: "{subject} is {points} off the lead. {leader} is a rumor from here.",
              secondPerson: "You are {points} off the lead. {leader} is a rumor from here."),
        .init(thirdPerson: "{subject} is {points} off the lead. Someone check the units.",
              secondPerson: "You are {points} off the lead. Someone check the units."),
    ]

    static let bots: [String: [MatchBanter.Template]] = [
        "chill": [
            .init(thirdPerson: "{subject} is losing to Chill. Chill.",
                  secondPerson: "You're losing to Chill. Chill."),
            .init(thirdPerson: "Chill is up {points} on {subject}. Chill took a long lunch.",
                  secondPerson: "Chill is up {points} on you. Chill took a long lunch."),
            .init(thirdPerson: "Chill leads {subject} by {points}. Chill has not noticed.",
                  secondPerson: "Chill leads you by {points}. Chill has not noticed."),
        ],
        "beast": [
            .init(thirdPerson: "Beast is up {points} on {subject}. It doesn't even have legs.",
                  secondPerson: "Beast is up {points} on you. It doesn't even have legs."),
            .init(thirdPerson: "Beast leads {subject} by {points}. It has no off switch.",
                  secondPerson: "Beast leads you by {points}. It has no off switch."),
            .init(thirdPerson: "Beast is up {points} on {subject}. It does not negotiate.",
                  secondPerson: "Beast is up {points} on you. It does not negotiate."),
        ],
        "erratic": [
            .init(thirdPerson: "Erratic is up {points} on {subject}. Nobody knows why, including Erratic.",
                  secondPerson: "Erratic is up {points} on you. Nobody knows why, including Erratic."),
            .init(thirdPerson: "{subject} is {points} behind Erratic. The off day is running late.",
                  secondPerson: "You are {points} behind Erratic. The off day is running late."),
            .init(thirdPerson: "Erratic leads {subject} by {points}. The big day picked itself.",
                  secondPerson: "Erratic leads you by {points}. The big day picked itself."),
        ],
        "pacer": [
            .init(thirdPerson: "Pacer is up {points} on {subject}. A normal week did this.",
                  secondPerson: "Pacer is up {points} on you. A normal week did this."),
            .init(thirdPerson: "{subject} is losing to Pacer by {points}. Pacer did not improvise.",
                  secondPerson: "You are losing to Pacer by {points}. Pacer did not improvise."),
            .init(thirdPerson: "Pacer is up {points} on {subject}. Right on time, unfortunately.",
                  secondPerson: "Pacer is up {points} on you. Right on time, unfortunately."),
        ],
    ]
}
