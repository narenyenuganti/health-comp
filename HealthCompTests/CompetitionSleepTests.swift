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

    func testApplyingCustomMetricsSubsetsRescoresDaysAndVerdict() throws {
        var d1 = day(1, own: 450, theirs: 460)
        d1.ownerRingPoints = [180, 150, 120]
        d1.opponentRingPoints = [140, 140, 180]
        var match = finished(user: 450, opponent: 460)
        match.days = [d1]

        let moveSleep = match.applyingMetrics(
            [.move, .sleep],
            sleep: nights(own: 8_000, theirs: 7_000, id: match.id),
            viewer: me
        )
        XCTAssertEqual(moveSleep.metrics, [.move, .sleep])
        XCTAssertEqual(moveSleep.days[0].dailyMaximum, 300)
        XCTAssertEqual(moveSleep.userPoints, 260)
        XCTAssertEqual(moveSleep.opponentPoints, 210)
        XCTAssertEqual(moveSleep.terminalResult?.outcome, .win)

        let sleepOnly = match.applyingMetrics(
            [.sleep],
            sleep: nights(own: 7_500, theirs: 8_500, id: match.id),
            viewer: me
        )
        XCTAssertEqual(sleepOnly.days[0].dailyMaximum, 100)
        XCTAssertEqual(sleepOnly.userPoints, 75)
        XCTAssertEqual(sleepOnly.opponentPoints, 85)
        XCTAssertEqual(sleepOnly.terminalResult?.outcome, .loss)
    }

    func testRingPanelAndWhatItTakesRespectActiveMetricsOnly() throws {
        let snapshot = try ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: ActivityRingReading(value: 300, goal: 600),
            exercise: ActivityRingReading(value: 15, goal: 30),
            standOrRoll: ActivityRingReading(value: 6, goal: 12),
            pauseState: .running
        )
        var d1 = LocalCompetitionDayPresentation(
            day: try CompetitionDay(era: 1, year: 2026, month: 8, day: 10, timeZoneIdentifier: "UTC"),
            ordinal: 1,
            ownerAcceptedPoints: 130,
            ownerLatestAvailability: .observed,
            opponentRevealedPoints: 150,
            ownerAcceptedSnapshot: snapshot,
            ownerLatestSnapshot: snapshot,
            scoringPolicy: .remoteWireV1
        )
        d1.metrics = [.move, .sleep]
        d1.dailyMaximum = 300
        d1.ownerSleepPoints = 80
        let panel = try XCTUnwrap(competitionRingPanel(d1))
        XCTAssertEqual(panel.rows.map(\.metric), [.move, .sleep])

        var active = finished(user: 130, opponent: 150)
        active.lifecycle = .active(dayOrdinal: 1)
        active.metrics = [.move, .sleep]
        active.days = [d1]
        active = LocalCompetitionPresentation(
            id: active.id,
            ownerDisplayName: active.ownerDisplayName,
            opponentDisplayName: active.opponentDisplayName,
            lifecycle: .active(dayOrdinal: 1),
            acceptedConfiguration: nil,
            userPoints: 130,
            opponentPoints: 150,
            days: [d1],
            currentDayOrdinal: 1,
            lastRefresh: nil,
            tally: nil,
            terminalResult: nil
        )
        active.metrics = [.move, .sleep]
        let takes = try XCTUnwrap(competitionWhatItTakes(active))
        XCTAssertTrue(takes.suggestion.contains("Move"), takes.suggestion)
        XCTAssertFalse(takes.suggestion.contains("Exercise"), takes.suggestion)

        active.metrics = [.sleep]
        XCTAssertNil(competitionWhatItTakes(active))
    }

    func testRecordsKeepBeltAndWinLossAcrossAllMetricsButBestWeekBestDayStayThreeRingsOnly() {
        let classic = finished(user: 2_400, opponent: 2_100)
        var fourMetric = finished(user: 3_100, opponent: 2_900)
        fourMetric.metrics = .all
        fourMetric.days[0].metrics = .all
        fourMetric.days[0].dailyMaximum = 700
        fourMetric.days[0].ownerAcceptedPoints = 680

        let own = competitionOwnCareer([classic, fourMetric])
        XCTAssertEqual(own.career.wins, 2)
        XCTAssertEqual(own.career.bestWeek, 2_400)
        XCTAssertEqual(own.bestDay, 2_400)

        let sections = competitionOwnRecordSections([classic, fourMetric], now: Date())
        let scoring = sections.first { $0.title == "SCORING" }?.rows ?? []
        XCTAssertEqual(scoring.first { $0.label == "Best week" }?.value, "2,400")
        XCTAssertEqual(scoring.first { $0.label == "Best day" }?.value, "2,400")
    }
}
