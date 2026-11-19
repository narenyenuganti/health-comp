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

    func testStartCreatesOneScheduledV3PracticeStartingTomorrow() async throws {
        let (runtime, environment, _) = try makeRuntime(dailyPoints: 400)
        let id = try await PracticeMatch.start(.beast, runtime: runtime, environment: environment)

        let journals = await runtime.loadAll().successfulJournals
        XCTAssertEqual(journals.map(\.projection.competition.id), [id])
        let competition = try XCTUnwrap(journals.first?.projection.competition)
        XCTAssertEqual(competition.lifecycle, .scheduled)
        XCTAssertEqual(
            competition.schedule?.startDay,
            try calendar.day(after: calendar.day(containing: startedAt))
        )
        let plan = try XCTUnwrap(competition.opponentPlan)
        XCTAssertEqual(plan.generatorVersion, .v3)
        XCTAssertEqual(plan.difficulty, .beast)
        // Baseline 400: Beast is 1.25–1.50 of it.
        for day in plan.days {
            XCTAssertTrue((500...600).contains(day.finalPoints), "\(day.finalPoints)")
        }
    }

    func testEachBotNamesItsPracticeAndAStoredOldPaceStaysPacer() async throws {
        for (mode, name) in [
            (OpponentDifficulty.pacer, "Pacer"), (.chill, "Chill"), (.erratic, "Erratic"), (.beast, "Beast"),
        ] {
            let (runtime, environment, _) = try makeRuntime(dailyPoints: 300)
            _ = try await PracticeMatch.start(mode, runtime: runtime, environment: environment)
            let shown = try await presentation(runtime, environment)
            XCTAssertEqual(shown.opponentDisplayName, name)
        }

        let (runtime, environment, _) = try makeRuntime(dailyPoints: 300)
        let id = CompetitionID(UUID())
        try await runtime.create(try genesis(id))
        try await runtime.accept(
            competitionID: id,
            opponent: OpponentPlanGenerationRequest(
                seed: 42,
                generatorVersion: .v2,
                difficulty: .challenging,
                baselineDailyPoints: 300
            )
        )
        let old = try await presentation(runtime, environment)
        XCTAssertEqual(old.opponentDisplayName, "Pacer")
    }

    func testStartRefusesWhileAPracticeIsUnderwayAndReplacesAFinishedOne() async throws {
        let (runtime, environment, source) = try makeRuntime(dailyPoints: 300)
        let first = try await PracticeMatch.start(.pacer, runtime: runtime, environment: environment)
        do {
            _ = try await PracticeMatch.start(.chill, runtime: runtime, environment: environment)
            XCTFail("A second practice started")
        } catch {
            XCTAssertEqual(error as? PracticeMatchError, .alreadyUnderway)
        }

        try await finish(runtime: runtime, source: source)
        let second = try await PracticeMatch.start(.chill, runtime: runtime, environment: environment)

        XCTAssertNotEqual(first, second)
        let ids = await runtime.loadAll().successfulJournals.map(\.projection.competition.id)
        XCTAssertEqual(ids, [second])
    }

    func testStartDeletesAPendingPracticeLeftByAnInterruptedStart() async throws {
        let (runtime, environment, _) = try makeRuntime(dailyPoints: 300)
        let interrupted = CompetitionID(UUID())
        try await runtime.create(try genesis(interrupted))

        let id = try await PracticeMatch.start(.pacer, runtime: runtime, environment: environment)

        let journals = await runtime.loadAll().successfulJournals
        XCTAssertEqual(journals.map(\.projection.competition.id), [id])
        XCTAssertNotEqual(id, interrupted)
    }

    // MARK: Projection and wakes

    func testPracticePresentationsUsePacerIdentityAndHidePendingJournals() async throws {
        let (runtime, environment, _) = try makeRuntime(dailyPoints: 300)
        let id = try await PracticeMatch.start(.pacer, runtime: runtime, environment: environment)
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
        _ = try await PracticeMatch.start(.pacer, runtime: runtime, environment: environment)
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
        let id = try await PracticeMatch.start(.pacer, runtime: runtime, environment: environment)
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

    func testStartBlockerBlocksOnlyWhenAPracticeIsUnderway() async throws {
        XCTAssertNil(PracticeMatch.startBlocker(in: []))
        let realLive = MultiUserCompetitionTestLabFixtures.challengeFriendPublication.dashboard.competitions
        XCTAssertNil(PracticeMatch.startBlocker(in: realLive))

        let (runtime, environment, source) = try makeRuntime(dailyPoints: 300)
        _ = try await PracticeMatch.start(.beast, runtime: runtime, environment: environment)
        let scheduled = try await presentation(runtime, environment)
        XCTAssertEqual(
            PracticeMatch.startBlocker(in: realLive + [scheduled]),
            "In a practice match with Beast"
        )

        try await finish(runtime: runtime, source: source)
        let completed = try await presentation(runtime, environment)
        XCTAssertNil(PracticeMatch.startBlocker(in: realLive + [completed]))
    }

    // MARK: Shadow rival

    func testShadowRivalsExtractsEligibleRivalsExcludesBlockedAndFormerAndSubtractsSleepPoints() throws {
        let startDay = try CompetitionDay(era: 1, year: 2026, month: 8, day: 3, timeZoneIdentifier: "UTC")
        let window = try calendar.sevenDayWindow(startingOn: startDay)
        let schedule = CompetitionSchedule(calendar: calendar, startDay: startDay)
        let accepted = LocalCompetitionAcceptedPresentation(
            schedule: schedule,
            difficulty: .balanced
        )

        func makeMatch(
            profileID: UUID,
            name: String,
            lifecycle: LocalCompetitionLifecyclePresentation,
            currentDayOrdinal: Int?,
            points: [Double?],
            sleep: [Double?] = Array(repeating: nil, count: 7)
        ) -> LocalCompetitionPresentation {
            let days = zip(window.enumerated(), zip(points, sleep)).map { item, pair -> LocalCompetitionDayPresentation in
                let (offset, day) = item
                var row = LocalCompetitionDayPresentation(
                    day: day,
                    ordinal: offset + 1,
                    ownerAcceptedPoints: 400,
                    ownerLatestAvailability: .observed,
                    opponentRevealedPoints: pair.0
                )
                row.opponentSleepPoints = pair.1
                return row
            }
            return LocalCompetitionPresentation(
                id: CompetitionID(UUID()),
                ownerDisplayName: "Beta Alice",
                opponentDisplayName: name,
                opponentIdentity: RemoteCompetitionOpponentIdentity.identity(for: profileID),
                lifecycle: lifecycle,
                acceptedConfiguration: accepted,
                userPoints: 2_800,
                opponentPoints: 2_900,
                days: days,
                currentDayOrdinal: currentDayOrdinal,
                lastRefresh: nil,
                tally: nil,
                terminalResult: nil,
                evaluatedAt: startedAt,
                timeZoneIdentifier: "UTC",
                lastSuccessfulFullWindowRefreshAt: nil,
                opponentUpdatedAt: nil
            )
        }

        let devID = UUID(uuidString: "d1000000-0000-4000-8000-0000000000b3")!
        let mayaID = UUID(uuidString: "d1000000-0000-4000-8000-0000000000b1")!
        let blockedID = UUID(uuidString: "d1000000-0000-4000-8000-0000000000c9")!
        let sparseID = UUID(uuidString: "d1000000-0000-4000-8000-0000000000c8")!

        // Dev: Day 1 has 450 total including 80 sleep -> 370 ring points.
        let devMatch = makeMatch(
            profileID: devID,
            name: "Dev Patel",
            lifecycle: .completed(outcome: .win, basis: .stableAcrossPostBoundaryReads, completedAt: startedAt),
            currentDayOrdinal: nil,
            points: [450, 415, 340, 445, 390, 520, 420],
            sleep: [80, nil, nil, nil, nil, nil, nil]
        )
        // Maya: Active on Day 5 -> closed days 1..4 count, Day 5 (120) does not.
        let mayaMatch = makeMatch(
            profileID: mayaID,
            name: "Maya Chen",
            lifecycle: .active(dayOrdinal: 5),
            currentDayOrdinal: 5,
            points: [310, 480, 405, 530, 120, nil, nil]
        )
        let blockedMatch = makeMatch(
            profileID: blockedID,
            name: "Blocked Rival",
            lifecycle: .completed(outcome: .loss, basis: .stableAcrossPostBoundaryReads, completedAt: startedAt),
            currentDayOrdinal: nil,
            points: [400, 410, 420, 430, 440, 450, 460]
        )
        let formerMatch = makeMatch(
            profileID: UUID(),
            name: competitionFormerCompetitorName,
            lifecycle: .completed(outcome: .win, basis: .stableAcrossPostBoundaryReads, completedAt: startedAt),
            currentDayOrdinal: nil,
            points: [300, 310, 320, 330, 340, 350, 360]
        )
        let sparseMatch = makeMatch(
            profileID: sparseID,
            name: "Sparse Rival",
            lifecycle: .active(dayOrdinal: 3),
            currentDayOrdinal: 3,
            points: [350, 420, 100, nil, nil, nil, nil]
        )

        let rivals = PracticeMatch.shadowRivals(
            competitions: [devMatch, mayaMatch, blockedMatch, formerMatch, sparseMatch],
            blocked: [AuthenticatedProfile(id: blockedID, displayName: "Blocked Rival")]
        )

        XCTAssertEqual(rivals.map(\.displayName), ["Dev Patel", "Maya Chen"])
        let dev = try XCTUnwrap(rivals.first)
        XCTAssertEqual(dev.shadowDisplayName, "Dev Patel’s Shadow")
        XCTAssertEqual(dev.profile.bounds, 340...520)
        XCTAssertEqual(dev.samples.count, 7)

        let maya = try XCTUnwrap(rivals.last)
        XCTAssertEqual(maya.samples.count, 4)
        XCTAssertEqual(maya.profile.bounds, 310...530)
    }

    func testStartShadowCreatesV4PracticeNamedAfterRivalWithScoresInTheirDistribution() async throws {
        let samples = try [
            (2, 370), (3, 415), (4, 340), (5, 445), (6, 390), (7, 520), (1, 420),
        ].map { try OpponentRivalSample(weekday: $0.0, points: $0.1) }
        let rival = try PracticeShadowRival(
            id: "remote-profile:v1:d1000000-0000-4000-8000-0000000000b3",
            profileID: UUID(uuidString: "d1000000-0000-4000-8000-0000000000b3"),
            displayName: "Dev Patel",
            samples: samples
        )

        let (runtime, environment, _) = try makeRuntime(dailyPoints: 300)
        _ = try await PracticeMatch.start(.shadow(rival), runtime: runtime, environment: environment)

        let journals = await runtime.loadAll().successfulJournals
        let plan = try XCTUnwrap(journals.first?.projection.competition.opponentPlan)
        XCTAssertEqual(plan.generatorVersion, .v4)
        XCTAssertEqual(plan.difficulty, .shadow)
        XCTAssertEqual(plan.opponentName, "Dev Patel’s Shadow")
        for day in plan.days {
            XCTAssertTrue((340...520).contains(day.finalPoints), "\(day.finalPoints)")
        }

        let shown = try await presentation(runtime, environment)
        XCTAssertEqual(shown.opponentDisplayName, "Dev Patel’s Shadow")
        XCTAssertTrue(shown.isPractice)
    }

    // MARK: Helpers

    private func presentation(
        _ runtime: LocalCompetitionRuntime,
        _ environment: CompetitionEnvironmentClient
    ) async throws -> LocalCompetitionPresentation {
        let journals = await runtime.loadAll().successfulJournals
        let context = await environment.context()
        return try XCTUnwrap(
            LocalCompetitionProjector.practicePresentations(
                journals: journals,
                context: context,
                configuration: .live,
                ownerDisplayName: "Beta Alice"
            ).first
        )
    }

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
