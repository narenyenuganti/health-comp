import CompetitionCore
import Foundation
import XCTest

@testable import HealthComp

final class CompetitionTraceIntegrationTests: XCTestCase {
    func testRuntimeAdaptersMatchEachOtherAndAuthoritativeWinGolden() async throws {
        let productionCalendar = try await runTrace(
            adapter: .productionCalendar,
            transportEpoch: "production-calendar-epoch"
        )
        let accelerated = try await runTrace(
            adapter: .accelerated,
            transportEpoch: "accelerated-epoch"
        )
        let golden = try loadWinGolden()

        XCTAssertEqual(productionCalendar, accelerated)
        XCTAssertEqual(accelerated.semanticEventIDs, golden.semanticEventIDs)
        XCTAssertEqual(
            accelerated.notificationDecisionSemanticIDs,
            golden.notificationDecisionSemanticIDs
        )
        XCTAssertEqual(accelerated.terminal, golden.terminal)
    }

    private func runTrace(
        adapter: TraceAdapter,
        transportEpoch: String
    ) async throws -> RuntimeTrace {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("competition-trace-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let store = JSONCompetitionEventStore(rootDirectory: root)
        let engine = CompetitionEngine()
        let competitionID = CompetitionID(
            UUID(uuidString: "10101010-2020-3030-4040-505050505050")!
        )
        let acceptedAt = try localDate(
            year: 2026,
            month: 3,
            day: 7,
            hour: 12
        )
        let genesis = try CompetitionGenesis(
            competitionID: competitionID,
            direction: .incoming,
            createdAt: acceptedAt.addingTimeInterval(-3_600),
            expiresAt: acceptedAt.addingTimeInterval(86_400),
            scoringPolicy: .healthKitCompatibility,
            downwardRevisionPolicy: .maximumObserved
        )
        _ = try await store.create(genesis)
        let loadedInitial = try await store.load(competitionID)
        let initial = try XCTUnwrap(loadedInitial)
        let acceptance = try engine.accept(
            initial.projection.competition,
            at: acceptedAt,
            timeZoneIdentifier: "America/Los_Angeles",
            opponent: OpponentPlanGenerationRequest(
                seed: 42,
                generatorVersion: .v1,
                difficulty: .balanced
            )
        )
        _ = try await store.append(
            [.lifecycle(acceptance)],
            to: competitionID,
            expectedCursor: initial.journal.cursor
        )
        let loadedAccepted = try await store.load(competitionID)
        let accepted = try XCTUnwrap(loadedAccepted)
        let schedule = try XCTUnwrap(accepted.projection.competition.schedule)
        let opponentPlan = try XCTUnwrap(
            accepted.projection.competition.opponentPlan
        )
        let window = try CompetitionActivityWindow(
            calendar: schedule.calendar,
            startDay: schedule.startDay
        )
        let dayStarts = try window.days.map(schedule.calendar.startOfDay)
        let endBoundary = try schedule.calendar.startOfDay(
            schedule.calendar.day(after: window.days[6])
        )
        let ownerPoints = opponentPlan.days.map { min(600, $0.finalPoints + 60) }
        let dayValues = try window.days.enumerated().map { offset, day in
            FixtureActivityValue.snapshot(
                day: day,
                snapshot: try snapshot(
                    points: ownerPoints[offset],
                    revisedGoal: offset == 1
                )
            )
        }
        let fixture = try ActivityFixture(
            initialInstant: EnvironmentInstant(
                wallDate: dayStarts[0].addingTimeInterval(12 * 3_600),
                monotonic: MonotonicInstant(
                    epochID: transportEpoch,
                    nanoseconds: 1_000
                )
            ),
            timeZoneIdentifier: "America/Los_Angeles",
            initialDays: [dayValues[0]],
            changes: [
                try FixtureActivityChange(
                    at: dayStarts[3].addingTimeInterval(12 * 3_600),
                    updates: [],
                    triggers: [],
                    readState: .failure(.protectedDataUnavailable)
                ),
                try FixtureActivityChange(
                    at: dayStarts[4].addingTimeInterval(12 * 3_600),
                    updates: Array(dayValues.prefix(5)),
                    triggers: [],
                    readState: .available
                ),
                try FixtureActivityChange(
                    at: endBoundary.addingTimeInterval(60),
                    updates: [dayValues[5], .missing(day: window.days[6])],
                    triggers: []
                ),
                try FixtureActivityChange(
                    at: endBoundary.addingTimeInterval(300),
                    updates: [dayValues[6]],
                    triggers: []
                ),
            ]
        )
        let source = FixtureActivitySource(fixture: fixture)
        let environment: CompetitionEnvironmentClient
        switch adapter {
        case .productionCalendar:
            environment = .productionCalendarTestAdapter(source: source)
            XCTAssertEqual(environment.kind, .production)
        case .accelerated:
            environment = .accelerated(source: source)
            XCTAssertEqual(environment.kind, .accelerated)
        }
        let runtime = LocalCompetitionRuntime(
            environment: environment,
            store: store,
            finalizationPolicy: FinalizationPolicy(
                minimumStabilityNanoseconds: 1,
                bestAvailableDeadline: endBoundary.addingTimeInterval(3_600)
            )
        )

        _ = try await runtime.refresh(
            competitionID: competitionID,
            trigger: .foreground
        )
        try await source.advance(to: dayStarts[3].addingTimeInterval(12 * 3_600))
        _ = try await runtime.refresh(
            competitionID: competitionID,
            trigger: .protectedDataAvailable
        )
        try await source.advance(to: dayStarts[4].addingTimeInterval(12 * 3_600))
        _ = try await runtime.refresh(
            competitionID: competitionID,
            trigger: .summaryUpdate
        )
        try await source.advance(to: endBoundary.addingTimeInterval(60))
        _ = try await runtime.refresh(
            competitionID: competitionID,
            trigger: .foreground
        )
        try await source.advance(to: endBoundary.addingTimeInterval(300))
        _ = try await runtime.refresh(
            competitionID: competitionID,
            trigger: .summaryUpdate
        )
        try await source.advance(to: endBoundary.addingTimeInterval(600))
        _ = try await runtime.refresh(
            competitionID: competitionID,
            trigger: .reconciliationProbe
        )

        let beforeNotification = try await runtime.load(competitionID)
        let resultRecord = try NotificationEmissionRecorded(
            competitionID: competitionID,
            family: .result,
            episodeKey: .result,
            disposition: .emitted,
            decidedAt: endBoundary.addingTimeInterval(3_601),
            basisPublicationRevision: beforeNotification.journal.cursor.commitRevision
        )
        _ = try await runtime.commitNotificationDecisions(
            competitionID: competitionID
        ) { _ in
            [
                .emission(
                    CompetitionNotificationEmissionDecision(
                        record: resultRecord,
                        request: CompetitionImmediateNotificationRequest(
                            identifier: resultRecord.semanticEventID,
                            content: CompetitionNotificationContent(
                                title: "Result",
                                body: "Fixture"
                            ),
                            route: .competition(competitionID)
                        )
                    )
                ),
            ]
        }
        let loaded = try await runtime.load(competitionID)
        return RuntimeTrace(
            semanticEventIDs: loaded.journal.envelopes.map(\.semanticEventID),
            notificationDecisionSemanticIDs: [resultRecord.semanticEventID],
            terminal: try CompetitionSemanticTerminalProjection(
                projection: loaded.projection
            )
        )
    }

    private func loadWinGolden() throws -> GoldenReference {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/win.json")
        let url = Bundle(for: Self.self).url(
            forResource: "win",
            withExtension: "json"
        ) ?? sourceURL
        return try JSONDecoder().decode(
            GoldenReference.self,
            from: Data(contentsOf: url)
        )
    }

    private func localDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    timeZone: calendar.timeZone,
                    year: year,
                    month: month,
                    day: day,
                    hour: hour
                )
            )
        )
    }

    private func snapshot(
        points: Int,
        revisedGoal: Bool
    ) throws -> ActivitySnapshot {
        let goal = revisedGoal ? 200.0 : 100.0
        return ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(
                value: Double(points) * goal / 100,
                goal: goal
            ),
            exercise: try ActivityRingReading(value: 0, goal: 30),
            standOrRoll: try ActivityRingReading(value: 0, goal: 12),
            pauseState: .running
        )
    }
}

private struct RuntimeTrace: Equatable {
    let semanticEventIDs: [String]
    let notificationDecisionSemanticIDs: [String]
    let terminal: CompetitionSemanticTerminalProjection
}

private struct GoldenReference: Decodable {
    let semanticEventIDs: [String]
    let notificationDecisionSemanticIDs: [String]
    let terminal: CompetitionSemanticTerminalProjection
}

private enum TraceAdapter {
    case productionCalendar
    case accelerated
}
