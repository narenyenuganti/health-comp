import CompetitionCore
import XCTest
@testable import HealthComp

final class PracticeMatchTests: XCTestCase {
    private let calendar = try! CompetitionCalendar(timeZoneIdentifier: "UTC")
    /// Fri May 1 2026, noon UTC.
    private let startedAt = Date(timeIntervalSince1970: 1_777_636_800)

    // MARK: Baseline

    func testBaselineAveragesScoredDaysOverTwoWeeks() throws {
        let first = try read(startingDaysBefore: 14, points: [100, 200, 300, 400, 500, 600, nil])
        let second = try read(startingDaysBefore: 7, points: [nil, nil, 250, 350, nil, nil, nil])
        // (100 + 200 + 300 + 400 + 500 + 600 + 250 + 350) / 8 = 337.5
        XCTAssertEqual(PracticeMatch.baselineDailyPoints([first, second]), 338)
    }

    func testBaselineFallsBackTo300WithFewerThanThreeScoredDays() throws {
        XCTAssertEqual(PracticeMatch.baselineDailyPoints([]), 300)
        let sparse = try read(startingDaysBefore: 7, points: [550, nil, 590, nil, nil, nil, nil])
        XCTAssertEqual(PracticeMatch.baselineDailyPoints([sparse]), 300)
    }

    func testBaselineClampsTo100And600() throws {
        let low = try read(startingDaysBefore: 7, points: [10, 20, 30, nil, nil, nil, nil])
        XCTAssertEqual(PracticeMatch.baselineDailyPoints([low]), 100)
        // A 900-point day counts as 600.
        let high = try read(startingDaysBefore: 7, points: [900, 900, 600, nil, nil, nil, nil])
        XCTAssertEqual(PracticeMatch.baselineDailyPoints([high]), 600)
    }

    // MARK: Start

    func testStartCreatesOneScheduledV2PracticeStartingTomorrow() async throws {
        let (runtime, environment, _) = try makeRuntime(dailyPoints: 400)
        let id = try await PracticeMatch.start(.challenging, runtime: runtime, environment: environment)

        let journals = await runtime.loadAll().successfulJournals
        XCTAssertEqual(journals.map(\.projection.competition.id), [id])
        let competition = try XCTUnwrap(journals.first?.projection.competition)
        XCTAssertEqual(competition.lifecycle, .scheduled)
        XCTAssertEqual(
            competition.schedule?.startDay,
            try calendar.day(after: calendar.day(containing: startedAt))
        )
        let plan = try XCTUnwrap(competition.opponentPlan)
        XCTAssertEqual(plan.generatorVersion, .v2)
        XCTAssertEqual(plan.difficulty, .challenging)
        // Baseline 400: challenging is 1.10–1.30 of it.
        for day in plan.days {
            XCTAssertTrue((440...520).contains(day.finalPoints), "\(day.finalPoints)")
        }
    }

    func testStartRefusesWhileAPracticeIsUnderwayAndReplacesAFinishedOne() async throws {
        let (runtime, environment, source) = try makeRuntime(dailyPoints: 300)
        let first = try await PracticeMatch.start(.balanced, runtime: runtime, environment: environment)
        do {
            _ = try await PracticeMatch.start(.relaxed, runtime: runtime, environment: environment)
            XCTFail("A second practice started")
        } catch {
            XCTAssertEqual(error as? PracticeMatchError, .alreadyUnderway)
        }

        try await finish(runtime: runtime, source: source)
        let second = try await PracticeMatch.start(.relaxed, runtime: runtime, environment: environment)

        XCTAssertNotEqual(first, second)
        let ids = await runtime.loadAll().successfulJournals.map(\.projection.competition.id)
        XCTAssertEqual(ids, [second])
    }

    func testStartDeletesAPendingPracticeLeftByAnInterruptedStart() async throws {
        let (runtime, environment, _) = try makeRuntime(dailyPoints: 300)
        let interrupted = CompetitionID(UUID())
        try await runtime.create(try genesis(interrupted))

        let id = try await PracticeMatch.start(.balanced, runtime: runtime, environment: environment)

        let journals = await runtime.loadAll().successfulJournals
        XCTAssertEqual(journals.map(\.projection.competition.id), [id])
        XCTAssertNotEqual(id, interrupted)
    }

    // MARK: Projection and wakes

    func testPracticePresentationsUsePacerIdentityAndHidePendingJournals() async throws {
        let (runtime, environment, _) = try makeRuntime(dailyPoints: 300)
        let id = try await PracticeMatch.start(.balanced, runtime: runtime, environment: environment)
        try await runtime.create(try genesis(CompetitionID(UUID())))
        let journals = await runtime.loadAll().successfulJournals
        XCTAssertEqual(journals.count, 2)

        let presentations = LocalCompetitionProjector.practicePresentations(
            journals: journals,
            context: await environment.context(),
            configuration: .live,
            ownerDisplayName: "Beta Alice"
        )

        XCTAssertEqual(presentations.map(\.id), [id])
        let practice = try XCTUnwrap(presentations.first)
        XCTAssertTrue(practice.isPractice)
        XCTAssertEqual(practice.opponentDisplayName, "Pacer")
        XCTAssertEqual(practice.opponentIdentity, "practice-pacer:v1")
        XCTAssertEqual(practice.ownerDisplayName, "Beta Alice")
        XCTAssertEqual(practice.lifecycle, .scheduled)
    }

    func testNextPacerRevealIsTheNextCheckpointAndAtLeastFiveMinutesOut() async throws {
        let (runtime, environment, source) = try makeRuntime(dailyPoints: 300)
        _ = try await PracticeMatch.start(.balanced, runtime: runtime, environment: environment)
        let scheduled = await runtime.loadAll().successfulJournals
        XCTAssertNil(PracticeMatch.nextPacerReveal(journals: scheduled, now: startedAt))

        let schedule = try XCTUnwrap(scheduled.first?.projection.competition.schedule)
        let dayStart = try schedule.calendar.startOfDay(schedule.startDay)
        let noon = dayStart.addingTimeInterval(12 * 3_600)
        try await source.advance(to: noon)
        _ = await runtime.refreshAll(trigger: .reconciliationProbe)
        let journals = await runtime.loadAll().successfulJournals
        let plan = try XCTUnwrap(journals.first?.projection.competition.opponentPlan)
        let checkpointTimes = plan.days[0].checkpoints.map {
            dayStart.addingTimeInterval(Double($0.progressBasisPoints) / 10_000 * 86_400)
        }
        let next = try XCTUnwrap(checkpointTimes.first { $0 > noon })

        XCTAssertEqual(
            PracticeMatch.nextPacerReveal(journals: journals, now: noon),
            max(next, noon.addingTimeInterval(300))
        )
        // Just before a checkpoint, the pacer still waits 5 minutes.
        let justBefore = next.addingTimeInterval(-10)
        XCTAssertEqual(
            PracticeMatch.nextPacerReveal(journals: journals, now: justBefore),
            justBefore.addingTimeInterval(300)
        )
    }

    func testExpiredResultsListsACompletedPracticePastItsLeaveHomeTime() async throws {
        let (runtime, environment, source) = try makeRuntime(dailyPoints: 300)
        let id = try await PracticeMatch.start(.balanced, runtime: runtime, environment: environment)
        try await finish(runtime: runtime, source: source)
        let journals = await runtime.loadAll().successfulJournals
        let competition = try XCTUnwrap(journals.first?.projection.competition)
        guard case let .completed(completed) = competition.lifecycle else {
            return XCTFail("Not completed: \(competition.lifecycle)")
        }
        let leaves = try XCTUnwrap(
            competitionResultLeavesHome(
                schedule: XCTUnwrap(competition.schedule),
                completedAt: completed.completedAt
            )?.at
        )

        XCTAssertEqual(
            PracticeMatch.expiredResults(journals: journals, now: leaves.addingTimeInterval(-1)),
            []
        )
        XCTAssertEqual(PracticeMatch.expiredResults(journals: journals, now: leaves), [id])
    }

    // MARK: Helpers

    private func makeRuntime(
        dailyPoints: Double
    ) throws -> (LocalCompetitionRuntime, CompetitionEnvironmentClient, FixtureActivitySource) {
        let today = try calendar.day(containing: startedAt)
        var days: [CompetitionDay] = []
        var day = today
        for _ in 0..<14 {
            day = try dayBefore(day)
            days.append(day)
        }
        // The practice week itself, so it can finish: the local engine never
        // finalizes a week with a day of no data.
        days += try calendar.sevenDayWindow(startingOn: calendar.day(after: today))
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: startedAt,
                    monotonic: MonotonicInstant(epochID: "practice-match", nanoseconds: 1)
                ),
                timeZoneIdentifier: "UTC",
                initialDays: try days.map { day -> FixtureActivityValue in
                    .snapshot(day: day, snapshot: try snapshot(dailyPoints))
                },
                changes: []
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let environment = CompetitionEnvironmentClient.accelerated(source: source)
        let runtime = LocalCompetitionRuntime(
            environment: environment,
            store: JSONCompetitionEventStore(rootDirectory: root),
            configuration: .testing
        )
        return (runtime, environment, source)
    }

    /// Past the week and its 60 s best-available grace.
    private func finish(runtime: LocalCompetitionRuntime, source: FixtureActivitySource) async throws {
        let loaded = await runtime.loadAll().successfulJournals
        let journal = try XCTUnwrap(loaded.first)
        let schedule = try XCTUnwrap(journal.projection.competition.schedule)
        let last = try schedule.calendar.sevenDayWindow(startingOn: schedule.startDay)[6]
        let end = try schedule.calendar.startOfDay(schedule.calendar.day(after: last))
        try await source.advance(to: end.addingTimeInterval(1))
        _ = await runtime.refreshAll(trigger: .reconciliationProbe)
        try await source.advance(to: end.addingTimeInterval(120))
        _ = await runtime.refreshAll(trigger: .reconciliationProbe)
        let finished = await runtime.loadAll().successfulJournals
        let lifecycle = try XCTUnwrap(finished.first?.projection.competition.lifecycle)
        guard case .completed = lifecycle else {
            return XCTFail("Not completed: \(lifecycle)")
        }
    }

    private func genesis(_ id: CompetitionID) throws -> CompetitionGenesis {
        try CompetitionGenesis(
            competitionID: id,
            direction: .outgoing,
            createdAt: startedAt,
            expiresAt: nil,
            scoringPolicy: .healthKitCompatibility,
            downwardRevisionPolicy: .maximumObserved
        )
    }

    private func read(startingDaysBefore count: Int, points: [Double?]) throws -> ActivityWindowRead {
        var start = try calendar.day(containing: startedAt)
        for _ in 0..<count { start = try dayBefore(start) }
        let window = try CompetitionActivityWindow(calendar: calendar, startDay: start)
        return try ActivityWindowRead(
            window: window,
            days: zip(window.days, points).map { day, value -> ActivityDayReadResult in
                guard let value else { return .missing(day: day) }
                return .snapshot(day: day, snapshot: try snapshot(value))
            }
        )
    }

    private func dayBefore(_ day: CompetitionDay) throws -> CompetitionDay {
        try calendar.day(containing: calendar.startOfDay(day).addingTimeInterval(-3_600))
    }

    /// Move alone scores the points: value/goal as a percentage.
    private func snapshot(_ points: Double) throws -> ActivitySnapshot {
        ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(value: points, goal: 100),
            exercise: try ActivityRingReading(value: 0, goal: 30),
            standOrRoll: try ActivityRingReading(value: 0, goal: 12),
            pauseState: .running
        )
    }
}
