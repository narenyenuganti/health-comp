import Foundation
import XCTest
@testable import CompetitionCore

final class MatchBanterTests: XCTestCase {
    private let matchID = UUID(uuidString: "12345678-9ABC-DEF0-1234-56789ABCDEF0")!
    private let ids = (1...4).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
    private var names: [UUID: String] { [ids[0]: "Sam", ids[1]: "Priya", ids[2]: "Leo", ids[3]: "Noor"] }

    private func doubles(_ kinds: [MatchSeat.Kind], cutoffs: [UUID: Int] = [:]) throws -> MatchConfiguration {
        try MatchConfiguration(format: .doubles, seats: (0..<4).map {
            try MatchSeat(id: ids[$0], kind: kinds[$0], team: $0 / 2)
        }, leaveCutoffs: cutoffs)
    }

    private func freeForAll(_ count: Int, bots: Set<Int> = [], cutoffs: [UUID: Int] = [:]) throws -> MatchConfiguration {
        try MatchConfiguration(format: .freeForAll, seats: (0..<count).map {
            try MatchSeat(id: ids[$0], kind: bots.contains($0) ? .bot : .human(ids[$0]))
        }, leaveCutoffs: cutoffs)
    }

    /// nil omits the seat that day, which scoring treats as not synced.
    private func points(_ ordinal: Int, _ values: [Int?]) throws -> [MatchDayScore] {
        try values.enumerated().compactMap { index, value in
            guard let value else { return nil }
            return try MatchDayScore(seatID: ids[index], ordinal: ordinal, value: .centipoints(value))
        }
    }

    private func evaluate(_ configuration: MatchConfiguration, day: Int, days: [MatchDayScore],
                          modes: [UUID: String] = [:]) throws -> MatchBanter.Line? {
        try MatchBanter.line(matchID: matchID, configuration: configuration, dayOrdinal: day, days: days, botModes: modes)
    }

    func testTriggerBoundaries() throws {
        let evenTeams = try doubles([.human(ids[0]), .human(ids[1]), .human(ids[2]), .human(ids[3])])
        XCTAssertNil(try evaluate(evenTeams, day: 3, days: points(3, [6_500, 3_500, 5_000, 5_000])))
        let justOver = try evaluate(evenTeams, day: 3, days: points(3, [6_501, 3_499, 5_000, 5_000]))
        XCTAssertEqual(justOver?.kind, .teamImbalance(.hardCarry))
        XCTAssertEqual(justOver?.percent, 65)

        let field = try freeForAll(3)
        XCTAssertNil(try evaluate(field, day: 3, days: points(3, [50_000, 20_000, 10_000])))
        let overLead = try evaluate(field, day: 3, days: points(3, [50_001, 20_000, 10_000]))
        XCTAssertEqual(overLead?.kind, .farOffLead)
        XCTAssertEqual(overLead?.points, 400)
        XCTAssertEqual(overLead?.subjectSeatIDs, [ids[2], ids[0]])

        let paced = try freeForAll(3, bots: [2])
        let modes = [ids[2]: "chill"]
        XCTAssertNil(try evaluate(paced, day: 3, days: points(3, [10_000, 10_000, 10_000]), modes: modes))
        XCTAssertNil(try evaluate(paced, day: 3, days: points(3, [10_000, 12_000, 10_099]), modes: modes))
        let ahead = try evaluate(paced, day: 3, days: points(3, [10_000, 12_000, 10_100]), modes: modes)
        XCTAssertEqual(ahead?.kind, .botAhead("chill"))
        XCTAssertEqual(ahead?.subjectSeatIDs, [ids[0]])
        XCTAssertEqual(ahead?.points, 1)
        XCTAssertNil(try evaluate(paced, day: 3, days: points(3, [10_000, 12_000, 11_000]), modes: [ids[2]: "Pacer"]))
    }

    func testPriorityOrder() throws {
        let sides = try doubles([.human(ids[0]), .human(ids[1]), .human(ids[2]), .bot])
        let carried = try evaluate(sides, day: 3, days: points(3, [8_000, 2_000, 1_000, 9_000]), modes: [ids[3]: "beast"])
        XCTAssertEqual(carried, MatchBanter.Line(kind: .teamImbalance(.hardCarry), subjectSeatIDs: [ids[0], ids[1]],
                                                 templateIndex: 5, percent: 80, points: nil))

        let field = try freeForAll(3, bots: [2])
        let buried = try evaluate(field, day: 3, days: points(3, [60_000, 10_000, 50_000]), modes: [ids[2]: "beast"])
        XCTAssertEqual(buried?.kind, .farOffLead)
        XCTAssertEqual(buried?.subjectSeatIDs, [ids[1], ids[0]])
        XCTAssertEqual(buried?.points, 500)

        let close = try evaluate(field, day: 3, days: points(3, [30_000, 20_000, 25_000]), modes: [ids[2]: "beast"])
        XCTAssertEqual(close?.kind, .botAhead("beast"))
        XCTAssertEqual(close?.subjectSeatIDs, [ids[1]])
    }

    func testQuietDays() throws {
        let sides = try doubles([.human(ids[0]), .human(ids[1]), .human(ids[2]), .human(ids[3])])
        for day in 1...2 {
            XCTAssertNil(try evaluate(sides, day: day, days: points(day, [8_000, 2_000, 5_000, 5_000])))
        }
        XCTAssertNotNil(try evaluate(sides, day: 3, days: points(3, [8_000, 2_000, 5_000, 5_000])))
        XCTAssertNotNil(try evaluate(sides, day: 7, days: points(7, [8_000, 2_000, 5_000, 5_000])))
        XCTAssertThrowsError(try evaluate(sides, day: 0, days: []))
        XCTAssertThrowsError(try evaluate(sides, day: 8, days: []))
    }

    func testUnsyncedSubjectSuppressesAndLowerTriggerCanFire() throws {
        let sides = try doubles([.human(ids[0]), .human(ids[1]), .human(ids[2]), .human(ids[3])])
        XCTAssertNil(try evaluate(sides, day: 3, days: points(3, [8_000, nil, 5_000, 5_000])))

        let field = try freeForAll(3)
        XCTAssertNil(try evaluate(field, day: 3, days: points(3, [50_000, 20_000, nil])))
        let unavailable = try MatchDayScore(seatID: ids[2], ordinal: 3, value: .unavailable)
        XCTAssertNil(try evaluate(field, day: 3, days: try points(3, [50_000, 20_000]) + [unavailable]))
        let earlyLead = try points(1, [60_000, 1_000, 1_000]) + points(3, [nil, 0, 0])
        XCTAssertNil(try evaluate(field, day: 3, days: earlyLead))

        let paced = try freeForAll(3, bots: [2])
        XCTAssertNil(try evaluate(paced, day: 3, days: points(3, [20_000, nil, 15_000]), modes: [ids[2]: "pacer"]))

        let crowded = try freeForAll(4, bots: [3])
        let fallenThrough = try evaluate(crowded, day: 3, days: points(3, [60_000, 20_000, nil, 50_000]),
                                         modes: [ids[3]: "beast"])
        XCTAssertEqual(fallenThrough, MatchBanter.Line(kind: .botAhead("beast"), subjectSeatIDs: [ids[1]],
                                                       templateIndex: 2, percent: nil, points: 300))
    }

    func testGoldenValuesAndRepeatedCalls() throws {
        // FNV-1a 64 of the UUID's RFC 4122 bytes plus the day byte. Not Swift.Hasher.
        XCTAssertEqual(MatchBanter.selectionHash(matchID: matchID, dayOrdinal: 3), 5_396_351_818_893_131_890)
        XCTAssertEqual(MatchBanter.selectionHash(matchID: matchID, dayOrdinal: 4), 5_396_346_321_334_990_835)

        let sides = try doubles([.human(ids[0]), .human(ids[1]), .human(ids[2]), .human(ids[3])])
        let scores = try points(3, [6_600, 3_400, 5_000, 5_000])
        let first = try evaluate(sides, day: 3, days: scores)
        XCTAssertEqual(first, try evaluate(sides, day: 3, days: scores))
        XCTAssertEqual(first, MatchBanter.Line(kind: .teamImbalance(.hardCarry), subjectSeatIDs: [ids[0], ids[1]],
                                               templateIndex: 5, percent: 66, points: nil))
        let nextDay = try evaluate(sides, day: 4, days: points(4, [6_600, 3_400, 5_000, 5_000]))
        XCTAssertEqual(nextDay, MatchBanter.Line(kind: .teamImbalance(.deadweight), subjectSeatIDs: [ids[1], ids[0]],
                                                 templateIndex: 7, percent: 34, points: nil))

        let field = try freeForAll(3)
        XCTAssertEqual(try evaluate(field, day: 3, days: points(3, [60_000, 20_000, 10_000])),
                       MatchBanter.Line(kind: .farOffLead, subjectSeatIDs: [ids[2], ids[0]],
                                        templateIndex: 5, percent: nil, points: 500))
        let paced = try freeForAll(3, bots: [2])
        XCTAssertEqual(try evaluate(paced, day: 3, days: points(3, [10_000, 15_000, 20_000]), modes: [ids[2]: "beast"]),
                       MatchBanter.Line(kind: .botAhead("beast"), subjectSeatIDs: [ids[0]],
                                        templateIndex: 2, percent: nil, points: 100))
    }

    func testSameLineForEveryViewerExceptYou() throws {
        let sides = try doubles([.human(ids[0]), .human(ids[1]), .human(ids[2]), .human(ids[3])])
        let line = try XCTUnwrap(evaluate(sides, day: 3, days: points(3, [6_600, 3_400, 5_000, 5_000])))
        let third = "Sam has 66% of the team's points. Priya brought a camera."
        let second = "You have 66% of your team's points. Priya brought a camera."
        let partner = "Sam has 66% of the team's points. You brought a camera."
        XCTAssertEqual(MatchBanter.render(line, names: names, viewerSeatID: ids[0]), second)
        XCTAssertEqual(MatchBanter.render(line, names: names, viewerSeatID: ids[1]), partner)
        for viewer in [ids[2], ids[3], UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!] {
            XCTAssertEqual(MatchBanter.render(line, names: names, viewerSeatID: viewer), third)
        }

        let leaderMatch = UUID(uuidString: "00000000-0000-0000-0000-000000000904")!
        let field = try freeForAll(3)
        let trailing = try MatchBanter.line(matchID: leaderMatch, configuration: field, dayOrdinal: 3,
                                            days: points(3, [60_000, 20_000, 10_000]))
        XCTAssertEqual(trailing?.templateIndex, 6)
        XCTAssertEqual(MatchBanter.render(try XCTUnwrap(trailing), names: names, viewerSeatID: ids[0]),
                       "Leo is 500 off the lead. You cannot hear Leo.")
    }

    func testViewerNeverSeesTheirOwnName() {
        let kinds: [MatchBanter.Kind] = [
            .teamImbalance(.hardCarry), .teamImbalance(.deadweight), .farOffLead,
            .botAhead("pacer"), .botAhead("chill"), .botAhead("erratic"), .botAhead("beast"),
        ]
        let templates = kinds.flatMap { MatchBanter.templates(for: $0) }
        XCTAssertEqual(templates.count, 41)
        XCTAssertEqual(MatchBanter.templates(for: .botAhead("chill"))[0].secondPerson, "You're losing to Chill. Chill.")
        XCTAssertEqual(MatchBanter.templates(for: .farOffLead)[0].thirdPerson,
                       "{subject} is {points} off the lead. Thoughts and prayers.")
        let viewers = [ids[0], ids[1], ids[2], ids[3]]
        var seen = ""
        for kind in kinds {
            for (index, template) in MatchBanter.templates(for: kind).enumerated() {
                let mentionsOther = [template.thirdPerson, template.secondPerson].contains { text in
                    text.contains("{partner}") || text.contains("{leader}")
                }
                XCTAssertEqual(template.namedViewer != nil, mentionsOther)
                let line = MatchBanter.Line(kind: kind, subjectSeatIDs: [ids[0], ids[1]],
                                            templateIndex: index, percent: 68, points: 509)
                for viewer in viewers {
                    let rendered = MatchBanter.render(line, names: names, viewerSeatID: viewer)
                    XCTAssertFalse(rendered.contains("{"), rendered)
                    XCTAssertFalse(rendered.contains("}"), rendered)
                    XCTAssertFalse(rendered.contains(names[viewer]!), rendered)
                    if viewer == ids[1], mentionsOther {
                        XCTAssertTrue(rendered.lowercased().contains("you"), rendered)
                    }
                }
                let subjectLine = MatchBanter.render(line, names: names, viewerSeatID: ids[0])
                let otherLine = MatchBanter.render(line, names: names, viewerSeatID: ids[2])
                XCTAssertTrue(otherLine.contains("Sam"), otherLine)
                XCTAssertFalse(subjectLine.contains("Sam"), subjectLine)
                XCTAssertNotEqual(subjectLine, otherLine)
                seen += subjectLine + "\n" + otherLine + "\n"
            }
        }
        for cut in ["brought snacks", "will clap later", "just visiting", "The graph is mostly",
                    "Attendance will be recorded", "has not looked back", "A shout will not carry"] {
            XCTAssertFalse(seen.contains(cut), cut)
        }
    }

    func testLeaversNeedAnAcceptedScore() throws {
        let humans = [MatchSeat.Kind.human(ids[0]), .human(ids[1]), .human(ids[2]), .human(ids[3])]
        let imbalanced = try points(3, [8_000, 2_000, 5_000, 5_000])
        let afterCutoff = try doubles(humans, cutoffs: [ids[0]: 3])
        XCTAssertNil(try evaluate(afterCutoff, day: 4, days: imbalanced + points(4, [nil, 100, 100, 100])))
        let partnerLeft = try doubles(humans, cutoffs: [ids[1]: 3])
        XCTAssertNil(try evaluate(partnerLeft, day: 4, days: imbalanced + points(4, [100, nil, 100, 100])))
        let explicit = try MatchDayScore(seatID: ids[0], ordinal: 4, value: .afterLeave)
        XCTAssertNil(try evaluate(afterCutoff, day: 4, days: imbalanced + points(4, [nil, 100, 100, 100]) + [explicit]))

        let early = try points(1, [8_000, 2_000, 1_000, 1_000])
        let sealed = try doubles(humans, cutoffs: [ids[0]: 3])
        XCTAssertNil(try evaluate(sealed, day: 3, days: early + points(3, [nil, 0, 0, 0])))
        for value in [MatchDayValue.notSynced, .unavailable] {
            let row = try MatchDayScore(seatID: ids[0], ordinal: 3, value: value)
            XCTAssertNil(try evaluate(sealed, day: 3, days: early + points(3, [nil, 0, 0, 0]) + [row]))
        }

        let banked = try doubles(humans, cutoffs: [ids[0]: 3])
        XCTAssertEqual(try evaluate(banked, day: 3, days: points(3, [6_600, 3_400, 5_000, 5_000])),
                       MatchBanter.Line(kind: .teamImbalance(.hardCarry), subjectSeatIDs: [ids[0], ids[1]],
                                        templateIndex: 5, percent: 66, points: nil))

        let field = try freeForAll(3, cutoffs: [ids[2]: 3])
        XCTAssertNil(try evaluate(field, day: 4, days: points(3, [60_000, 20_000, 10_000]) + points(4, [0, 0, nil])))
        XCTAssertNil(try evaluate(field, day: 3, days: points(1, [60_000, 20_000, 10_000]) + points(3, [0, 0, nil])))
        let unavailable = try MatchDayScore(seatID: ids[2], ordinal: 3, value: .unavailable)
        XCTAssertNil(try evaluate(field, day: 3, days: points(1, [60_000, 20_000, 10_000]) + points(3, [0, 0, nil]) + [unavailable]))
        XCTAssertEqual(try evaluate(field, day: 3, days: points(3, [60_000, 20_000, 10_000]))?.subjectSeatIDs, [ids[2], ids[0]])
    }

    func testBotIsNeverAnImbalanceSubject() throws {
        let carryingBot = try doubles([.human(ids[0]), .bot, .human(ids[2]), .human(ids[3])])
        let dragged = try evaluate(carryingBot, day: 3, days: points(3, [2_000, 8_000, 1_000, 1_000]), modes: [ids[1]: "beast"])
        XCTAssertEqual(dragged, MatchBanter.Line(kind: .teamImbalance(.deadweight), subjectSeatIDs: [ids[0], ids[1]],
                                                 templateIndex: 5, percent: 20, points: nil))

        let carriedHuman = try doubles([.human(ids[0]), .bot, .human(ids[2]), .human(ids[3])])
        let carried = try evaluate(carriedHuman, day: 4, days: points(4, [8_000, 2_000, 1_000, 1_000]), modes: [ids[1]: "pacer"])
        XCTAssertEqual(carried?.kind, .teamImbalance(.hardCarry))
        XCTAssertEqual(carried?.subjectSeatIDs, [ids[0], ids[1]])
        XCTAssertEqual(carried?.templateIndex, 2)
        XCTAssertEqual(carried?.percent, 80)
    }

    func testWeekToDateTotalsNotJustToday() throws {
        let sides = try doubles([.human(ids[0]), .human(ids[1]), .human(ids[2]), .human(ids[3])])
        let todayOnlyWouldCarry = try points(1, [3_400, 6_600, 1_000, 1_000]) + points(3, [6_600, 0, 1_000, 1_000])
        XCTAssertNil(try evaluate(sides, day: 3, days: todayOnlyWouldCarry))
    }

    func testSeatIDBreaksTies() throws {
        let reverse = try MatchConfiguration(format: .freeForAll, seats: [2, 1, 0].map {
            try MatchSeat(id: ids[$0], kind: .human(ids[$0]))
        })
        let tiedLast = try evaluate(reverse, day: 3, days: points(3, [10_000, 10_000, 60_000]))
        XCTAssertEqual(tiedLast?.subjectSeatIDs, [ids[0], ids[2]])
        let tiedLead = try evaluate(reverse, day: 3, days: points(3, [60_000, 60_000, 10_000]))
        XCTAssertEqual(tiedLead?.subjectSeatIDs, [ids[2], ids[0]])

        let botsFirst = try MatchConfiguration(format: .freeForAll, seats: [3, 2, 1, 0].map {
            try MatchSeat(id: ids[$0], kind: $0 >= 2 ? .bot : .human(ids[$0]))
        })
        let pair = try evaluate(botsFirst, day: 3, days: points(3, [30_000, 20_000, 25_000, 28_000]),
                                modes: [ids[2]: "pacer", ids[3]: "beast"])
        XCTAssertEqual(pair?.kind, .botAhead("pacer"))
        XCTAssertEqual(pair?.subjectSeatIDs, [ids[1]])
        XCTAssertEqual(pair?.points, 50)

        let bothTeams = try doubles([.human(ids[0]), .human(ids[1]), .human(ids[2]), .human(ids[3])])
        let lowerTeam = try evaluate(bothTeams, day: 3, days: points(3, [8_000, 2_000, 9_000, 1_000]))
        XCTAssertEqual(lowerTeam?.subjectSeatIDs, [ids[0], ids[1]])
    }
}
