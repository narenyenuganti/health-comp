import Foundation
import XCTest
@testable import CompetitionCore

final class MatchScoringTests: XCTestCase {
    private let ids = (1...5).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }

    private func configuration(_ count: Int = 3, doubles: Bool = false,
                               cutoffs: [UUID: Int] = [:], bot: Bool = false) throws -> MatchConfiguration {
        try MatchConfiguration(format: doubles ? .doubles : .freeForAll,
                               seats: (0..<count).map {
                                   try MatchSeat(id: ids[$0], kind: bot && $0 == count - 1 ? .bot : .human(ids[$0]),
                                                 team: doubles ? $0 / 2 : nil)
                               }, leaveCutoffs: cutoffs)
    }

    private func scores(_ points: [Int], day: Int = 1) throws -> [MatchDayScore] {
        try points.enumerated().map { try MatchDayScore(seatID: ids[$0.offset], ordinal: day, value: .centipoints($0.element)) }
    }

    func testThreeWayCompetitionRanksAndCentipointTies() throws {
        let config = try configuration()
        for (points, places) in [([101, 101, 100], [1, 1, 3]), ([101, 100, 100], [1, 2, 2]), ([0, 0, 0], [1, 1, 1])] {
            let projection = try MatchScoring.standings(configuration: config, days: scores(points), throughDay: 1)
            XCTAssertEqual(projection.standings.map(\.place), places)
            XCTAssertEqual(projection.standings.map(\.subject), ids.prefix(3).map { .seat($0) })
            XCTAssertFalse(projection.isProvisional)
        }
    }

    func testFourWayNextPlaceTargetsEverySubjectAtNearestGreaterTotal() throws {
        let config = try configuration(4)
        let projection = try MatchScoring.standings(configuration: config, days: scores([1_000, 900, 900, 800]), throughDay: 1)
        XCTAssertEqual(projection.standings.map(\.place), [1, 2, 2, 4])
        let next = MatchScoring.nextPlaceUp(for: .seat(ids[3]), in: projection.standings)
        XCTAssertEqual(next?.subjects, [.seat(ids[1]), .seat(ids[2])])
        XCTAssertEqual(next?.centipointsToTie, 100)
        XCTAssertNil(MatchScoring.nextPlaceUp(for: .seat(ids[0]), in: projection.standings))
        XCTAssertEqual(MatchScoring.lead(for: .seat(ids[0]), in: projection.standings), .unique(margin: 100))
        XCTAssertNil(MatchScoring.lead(for: .seat(ids[1]), in: projection.standings))
        XCTAssertNil(MatchScoring.lead(for: .seat(ids[4]), in: projection.standings))
        XCTAssertNil(MatchScoring.nextPlaceUp(for: .seat(ids[4]), in: projection.standings))
    }

    func testSharedLeadNeverProducesUniqueLead() throws {
        let projection = try MatchScoring.standings(configuration: configuration(), days: scores([500, 500, 400]), throughDay: 1)
        for id in ids.prefix(2) {
            XCTAssertNil(MatchScoring.nextPlaceUp(for: .seat(id), in: projection.standings))
            XCTAssertEqual(MatchScoring.lead(for: .seat(id), in: projection.standings), .shared([.seat(ids[0]), .seat(ids[1])]))
        }
    }

    func testDoublesSumAndTie() throws {
        let config = try configuration(4, doubles: true)
        let days = try scores([300, 200, 100, 400])
        let projection = try MatchScoring.standings(configuration: config, days: days, throughDay: 1)
        XCTAssertEqual(projection.standings.map(\.centipoints), [500, 500])
        XCTAssertEqual(projection.standings.map(\.place), [1, 1])
        XCTAssertEqual(MatchScoring.lead(for: .team(0), in: projection.standings), .shared([.team(0), .team(1)]))
        XCTAssertEqual(try MatchScoring.dayWinners(configuration: config, days: days, ordinal: 1, throughDay: 1), .winners([.team(0), .team(1)]))
        let unequal = try MatchScoring.standings(configuration: config, days: scores([301, 200, 100, 400]), throughDay: 1)
        XCTAssertEqual(MatchScoring.lead(for: .team(0), in: unequal.standings), .unique(margin: 1))
        XCTAssertEqual(MatchScoring.nextPlaceUp(for: .team(1), in: unequal.standings)?.subjects, [.team(0)])
    }

    func testProvisionalValuesContributeNothingAndFutureDaysAreExcluded() throws {
        let config = try configuration()
        let days = try [MatchDayScore(seatID: ids[0], ordinal: 1, value: .centipoints(123)),
                        MatchDayScore(seatID: ids[1], ordinal: 1, value: .unavailable),
                        MatchDayScore(seatID: ids[2], ordinal: 1, value: .notSynced)] + scores([60_000, 60_000, 60_000], day: 2)
        let projection = try MatchScoring.standings(configuration: config, days: days, throughDay: 1)
        XCTAssertEqual(projection.seatTotals, [ids[0]: 123, ids[1]: 0, ids[2]: 0])
        XCTAssertTrue(projection.isProvisional)
        XCTAssertEqual(try MatchScoring.dayWinners(configuration: config, days: days, ordinal: 1, throughDay: 1), .unresolved)
        XCTAssertEqual(try MatchScoring.dayWinners(configuration: config, days: days, ordinal: 2, throughDay: 1), .unresolved)
        XCTAssertTrue(try MatchScoring.standings(configuration: config, days: [], throughDay: 1).isProvisional)
    }

    func testDayWinnersIncludeAllTiesZeroTiesAndBotScores() throws {
        let config = try configuration(bot: true)
        for (points, winners) in [([1, 2, 3], [ids[2]]), ([3, 3, 2], [ids[0], ids[1]]), ([0, 0, 0], Array(ids.prefix(3)))] {
            XCTAssertEqual(try MatchScoring.dayWinners(configuration: config, days: scores(points), ordinal: 1, throughDay: 1),
                           .winners(winners.map { .seat($0) }))
        }
        XCTAssertEqual(try MatchScoring.dayWinners(configuration: config, days: scores([1, 2]), ordinal: 1, throughDay: 1), .unresolved)
    }

    func testLeaveBanksCurrentDayAndPartnerContinues() throws {
        let config = try configuration(4, doubles: true, cutoffs: [ids[0]: 1])
        let bank = try scores([123, 100, 100, 100])
        let later = try (2...7).flatMap { day in
            try (1...3).map { try MatchDayScore(seatID: ids[$0], ordinal: day, value: .centipoints(100)) }
        }
        let projection = try MatchScoring.standings(configuration: config, days: bank + later, throughDay: 7)
        XCTAssertEqual(projection.seatTotals[ids[0]], 123)
        XCTAssertEqual(projection.seatTotals[ids[1]], 700)
        XCTAssertEqual(projection.standings.map(\.centipoints), [1_400, 823])
        XCTAssertFalse(projection.isProvisional)
        let explicit = try MatchDayScore(seatID: ids[0], ordinal: 2, value: .afterLeave)
        XCTAssertEqual(try MatchScoring.standings(configuration: config, days: bank + later + [explicit], throughDay: 7), projection)
        XCTAssertEqual(try MatchScoring.dayWinners(configuration: config, days: bank + later, ordinal: 2, throughDay: 7), .winners([.team(1)]))
        let missingBank = Array(bank.dropFirst()) + later
        XCTAssertTrue(try MatchScoring.standings(configuration: config, days: missingBank, throughDay: 7).isProvisional)
    }

    func testTeamShareIsExactIncludingZeroMemberAndProvisionalTotals() throws {
        let config = try configuration(4, doubles: true)
        let days = try scores([1, 2, 0, 5])
        let share = try MatchScoring.teamShare(seat: ids[0], configuration: config, days: days, throughDay: 1)
        XCTAssertEqual(share?.numerator, 1)
        XCTAssertEqual(share?.denominator, 3)
        XCTAssertEqual(try MatchScoring.teamShare(seat: ids[2], configuration: config, days: days, throughDay: 1)?.numerator, 0)
        XCTAssertEqual(try MatchScoring.teamShare(seat: ids[0], configuration: config, days: days, throughDay: 2), share)
        XCTAssertNil(try MatchScoring.teamShare(seat: ids[0], configuration: config, days: scores([0, 0, 1, 1]), throughDay: 1))
        XCTAssertNil(try MatchScoring.teamShare(seat: ids[0], configuration: configuration(), days: scores([1, 2, 3]), throughDay: 1))
        XCTAssertThrowsError(try MatchScoring.teamShare(seat: ids[4], configuration: config, days: [], throughDay: 1))
    }

    func testTeamDailyAndWeeklyCaps() throws {
        let config = try configuration(4, doubles: true)
        let days = try (1...7).flatMap { try scores([60_000, 60_000, 60_000, 60_000], day: $0) }
        XCTAssertEqual(try MatchScoring.standings(configuration: config, days: days, throughDay: 1).standings.map(\.centipoints), [120_000, 120_000])
        let week = try MatchScoring.standings(configuration: config, days: days, throughDay: 7)
        XCTAssertEqual(week.standings.map(\.centipoints), [840_000, 840_000])
        XCTAssertTrue(week.seatTotals.values.allSatisfy { $0 == 420_000 })
    }

    func testRosterAndTeamValidation() throws {
        XCTAssertThrowsError(try configuration(2))
        XCTAssertThrowsError(try configuration(5))
        let human = try MatchSeat(id: ids[0], kind: .human(ids[0]))
        let other = try MatchSeat(id: ids[1], kind: .human(ids[0]))
        let bot = try MatchSeat(id: ids[2], kind: .bot)
        XCTAssertThrowsError(try MatchConfiguration(format: .freeForAll, seats: [human, human, bot]))
        XCTAssertThrowsError(try MatchConfiguration(format: .freeForAll, seats: [human, other, bot]))
        XCTAssertThrowsError(try MatchConfiguration(format: .freeForAll, seats: [human, bot, MatchSeat(id: ids[3], kind: .bot)]))
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        XCTAssertThrowsError(try MatchSeat(id: zero, kind: .bot))
        XCTAssertThrowsError(try MatchSeat(id: ids[0], kind: .human(zero)))
        XCTAssertThrowsError(try MatchConfiguration(format: .freeForAll, seats: configuration(4, doubles: true).seats))
        XCTAssertThrowsError(try MatchConfiguration(format: .doubles, seats: configuration(4).seats))
        let threeOne = try (0..<4).map { try MatchSeat(id: ids[$0], kind: .human(ids[$0]), team: $0 == 3 ? 1 : 0) }
        XCTAssertThrowsError(try MatchConfiguration(format: .doubles, seats: threeOne))
        for cutoffs in [[ids[0]: 0], [ids[0]: 8], [ids[4]: 1]] {
            XCTAssertThrowsError(try configuration(cutoffs: cutoffs))
        }
    }

    func testDayAndCrossRecordValidationIncludingFutureRows() throws {
        let config = try configuration(cutoffs: [ids[0]: 1])
        for ordinal in [0, 8] {
            XCTAssertThrowsError(try MatchDayScore(seatID: ids[0], ordinal: ordinal, value: .notSynced))
            XCTAssertThrowsError(try MatchScoring.standings(configuration: config, days: [], throughDay: ordinal))
            XCTAssertThrowsError(try MatchScoring.dayWinners(configuration: config, days: [], ordinal: ordinal, throughDay: 1))
        }
        for points in [-1, 60_001, Int.max] {
            XCTAssertThrowsError(try MatchDayScore(seatID: ids[0], ordinal: 1, value: .centipoints(points)))
        }
        let day = try scores([1])[0]
        XCTAssertThrowsError(try MatchScoring.standings(configuration: config, days: [day, day], throughDay: 1))
        let unknown = try MatchDayScore(seatID: ids[4], ordinal: 1, value: .centipoints(0))
        XCTAssertThrowsError(try MatchScoring.standings(configuration: config, days: [unknown], throughDay: 1))
        for (id, ordinal, value) in [(ids[0], 1, MatchDayValue.afterLeave), (ids[1], 2, .afterLeave),
                                     (ids[0], 2, .centipoints(0)), (ids[0], 2, .unavailable), (ids[0], 2, .notSynced)] {
            let invalid = try MatchDayScore(seatID: id, ordinal: ordinal, value: value)
            XCTAssertThrowsError(try MatchScoring.standings(configuration: config, days: [invalid], throughDay: 1))
        }
    }

    func testValidatedCodableRoundTripsAndRejectsInvalidPayloads() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let config = try configuration(4, doubles: true, cutoffs: [ids[0]: 2], bot: true)
        XCTAssertEqual(try decoder.decode(MatchConfiguration.self, from: encoder.encode(config)), config)
        for value in [MatchDayValue.centipoints(60_000), .notSynced, .unavailable, .afterLeave] {
            let score = try MatchDayScore(seatID: ids[0], ordinal: 3, value: value)
            XCTAssertEqual(try decoder.decode(MatchDayScore.self, from: encoder.encode(score)), score)
        }
        let valid = try encoder.encode(scores([123])[0])
        let text = String(decoding: valid, as: UTF8.self)
        XCTAssertThrowsError(try decoder.decode(MatchDayScore.self, from: Data(text.replacingOccurrences(of: "123", with: "60001").utf8)))
        XCTAssertThrowsError(try decoder.decode(MatchDayScore.self, from: Data(text.replacingOccurrences(of: "\"ordinal\":1", with: "\"ordinal\":0").utf8)))
        XCTAssertThrowsError(try decoder.decode(MatchDayValue.self, from: encoder.encode(MatchDayValue.centipoints(-1))))
        let seat = try encoder.encode(config.seats[0])
        XCTAssertThrowsError(try decoder.decode(MatchSeat.self, from: Data(String(decoding: seat, as: UTF8.self).replacingOccurrences(of: ids[0].uuidString, with: "00000000-0000-0000-0000-000000000000").utf8)))
        let roster = try encoder.encode(configuration())
        XCTAssertThrowsError(try decoder.decode(MatchConfiguration.self, from: Data(String(decoding: roster, as: UTF8.self).replacingOccurrences(of: "freeForAll", with: "doubles").utf8)))
    }
}
