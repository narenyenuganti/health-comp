import CompetitionCore
import XCTest
@testable import HealthComp

final class CompetitionSleepTests: XCTestCase {
    private let me = UUID()
    private let them = UUID()

    private func day(_ ordinal: Int, own: Double?, theirs: Double?) -> LocalCompetitionDayPresentation {
        LocalCompetitionDayPresentation(
            day: try! CompetitionDay(era: 1, year: 2026, month: 8, day: 9 + ordinal, timeZoneIdentifier: "UTC"),
            ordinal: ordinal,
            ownerAcceptedPoints: own,
            ownerLatestAvailability: .observed,
            opponentRevealedPoints: theirs
        )
    }

    private func finished(user: Double, opponent: Double) -> LocalCompetitionPresentation {
        let completedAt = Date(timeIntervalSince1970: 1_786_867_200)
        return LocalCompetitionPresentation(
            id: CompetitionID(UUID()),
            ownerDisplayName: "Naren",
            opponentDisplayName: "Alex",
            lifecycle: .completed(outcome: user > opponent ? .win : .loss, basis: .stableAcrossPostBoundaryReads, completedAt: completedAt),
            acceptedConfiguration: nil,
            userPoints: user,
            opponentPoints: opponent,
            days: [day(1, own: user, theirs: opponent)],
            currentDayOrdinal: nil,
            lastRefresh: nil,
            tally: nil,
            terminalResult: LocalCompetitionTerminalPresentation(
                userPoints: user, opponentPoints: opponent,
                outcome: user > opponent ? .win : .loss,
                basis: .stableAcrossPostBoundaryReads, completedAt: completedAt
            ),
            evaluatedAt: completedAt
        )
    }

    private func nights(own: Int?, theirs: Int?, id: CompetitionID) -> CompetitionSleepMatch {
        CompetitionSleepMatch(competitionID: id.rawValue, nights: [
            own.map { CompetitionSleepNight(profileID: me, dayOrdinal: 1, basisPoints: $0) },
            theirs.map { CompetitionSleepNight(profileID: them, dayOrdinal: 1, basisPoints: $0) },
        ].compactMap { $0 })
    }

    func testSleepAddsToDaysTotalsAndCanFlipTheVerdict() {
        let rings = finished(user: 500, opponent: 450)
        let merged = rings.addingSleep(nights(own: 0, theirs: 10_000, id: rings.id), viewer: me)
        XCTAssertEqual(merged.userPoints, 500)
        XCTAssertEqual(merged.opponentPoints, 550)
        XCTAssertEqual(merged.days[0].ownerAcceptedPoints, 500)
        XCTAssertEqual(merged.days[0].opponentRevealedPoints, 550)
        XCTAssertEqual(merged.days[0].opponentSleepPoints, 100)
        XCTAssertEqual(merged.days[0].dailyMaximum, 700)
        XCTAssertEqual(merged.terminalResult?.outcome, .loss)
        guard case .completed(.loss, _, _) = merged.lifecycle else {
            return XCTFail("\(merged.lifecycle)")
        }
    }

    func testEqualCombinedTotalsTie() {
        let rings = finished(user: 500, opponent: 450.5)
        let merged = rings.addingSleep(nights(own: 0, theirs: 4_950, id: rings.id), viewer: me)
        XCTAssertEqual(merged.terminalResult?.outcome, .tie)
    }

    func testAMissingNightAddsNothingAndRingsSegmentsKeepTheirShare() {
        let rings = finished(user: 500, opponent: 450)
        let merged = rings.addingSleep(nights(own: 9_125, theirs: nil, id: rings.id), viewer: me)
        XCTAssertEqual(merged.days[0].ownerAcceptedPoints, 591.25)
        XCTAssertNil(merged.days[0].opponentSleepPoints)
        XCTAssertEqual(merged.opponentPoints, 450)
        let segments = ringSegments(merged.days[0])
        XCTAssertEqual(segments.last?.points, 91.25)
        XCTAssertEqual(segments.map(\.points).reduce(0, +), 591.25, accuracy: 0.001)
    }

    func testSleepRowReadsTimeAsleepAndTheNightsScore() {
        var night = day(1, own: 591.25, theirs: nil)
        night.ownerSleepReading = CompetitionSleepReading(
            night: SleepNight(
                minutesAsleep: 438, awakeMinutes: 12, onsetMinutes: 305, source: .oura,
                durationPoints: 45.625, bedtimePoints: 30, interruptionPoints: 19.333, basisPoints: 9_496
            ),
            windowStart: .distantPast, usualOnsetMinutes: 310, readAt: .distantPast
        )
        XCTAssertEqual(competitionSleepRow(night).detail, "7h 18m asleep")
        XCTAssertEqual(competitionSleepRow(night).points, 94.96, "unsynced: this phone's score")
        night.ownerSleepPoints = 91.25
        XCTAssertEqual(competitionSleepRow(night).points, 91.25, "synced points win")
        night.ownerSleepReading = nil
        night.ownerSleepPoints = nil
        XCTAssertEqual(competitionSleepRow(night).detail, "No night yet")
        XCTAssertNil(competitionSleepRow(night).points)
    }
}
