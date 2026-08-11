import Foundation
import XCTest

@testable import CompetitionCore

final class CompetitionTraceTests: XCTestCase {
    func testTerminalContractDetectsSemanticDifferencesWithEqualTotals() throws {
        let baselineObject: [String: Any] = [
            "lifecycle": "completed",
            "competitionID": "10101010-2020-3030-4040-505050505050",
            "scheduleTimeZoneIdentifier": "America/Los_Angeles",
            "startDay": [
                "era": 1,
                "year": 2026,
                "month": 3,
                "day": 8,
                "timeZoneIdentifier": "America/Los_Angeles",
            ],
            "opponentPlanContentIdentity": "opponent-plan:v1:fixture",
            "opponentPlanCommitmentHex": "aaaa",
            "completedAt": 1_000.0,
            "outcome": "win",
            "basis": "stableAcrossPostBoundaryReads",
            "userPoints": 2_797.0,
            "opponentPoints": 2_377.0,
            "ledgerIsFrozen": true,
            "scoringPolicyIdentity": "activity-scoring-policy:v1:fixture",
            "downwardRevisionPolicy": "maximumObserved",
            "days": (1...7).map { ordinal in
                [
                    "ordinal": ordinal,
                    "acceptedPoints": 300.0,
                    "acceptedActivityContentFingerprint": "fingerprint-\(ordinal)",
                ] as [String: Any]
            },
        ]
        let baseline = try decodeTerminal(baselineObject)

        var changedCompletion = baselineObject
        changedCompletion["completedAt"] = 1_001.0
        XCTAssertNotEqual(baseline, try decodeTerminal(changedCompletion))

        var changedPlan = baselineObject
        changedPlan["opponentPlanCommitmentHex"] = "bbbb"
        XCTAssertNotEqual(baseline, try decodeTerminal(changedPlan))

        var changedLedger = baselineObject
        var changedDays = try XCTUnwrap(
            changedLedger["days"] as? [[String: Any]]
        )
        changedDays[3]["acceptedActivityContentFingerprint"] = "revised-day-4"
        changedLedger["days"] = changedDays
        XCTAssertNotEqual(baseline, try decodeTerminal(changedLedger))
    }

    func testLateWatchSyncMatchesProductionCalendarAndGolden() throws {
        try assertEquivalent(.lateWatchSync)
    }

    func testWinMatchesProductionCalendarAndGolden() throws {
        try assertEquivalent(.win)
    }

    func testLossMatchesProductionCalendarAndGolden() throws {
        try assertEquivalent(.loss)
    }

    func testTieMatchesProductionCalendarAndGolden() throws {
        try assertEquivalent(.tie)
    }

    private func assertEquivalent(
        _ scenario: TraceScenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let production = try CompetitionTraceRunner(
            scenario: scenario,
            evaluation: .productionCalendar
        ).run()
        let accelerated = try CompetitionTraceRunner(
            scenario: scenario,
            evaluation: .accelerated
        ).run()

        XCTAssertEqual(accelerated, production, file: file, line: line)
        XCTAssertEqual(
            accelerated,
            try loadGolden(scenario.goldenName),
            file: file,
            line: line
        )
        XCTAssertEqual(accelerated.payloadVersion, 4, file: file, line: line)
        XCTAssertTrue(
            accelerated.coverage.contains("dst-boundary"),
            file: file,
            line: line
        )
        XCTAssertTrue(
            accelerated.coverage.contains("goal-revision"),
            file: file,
            line: line
        )
        XCTAssertTrue(
            accelerated.coverage.contains("unavailable-data"),
            file: file,
            line: line
        )
    }

    private func loadGolden(_ name: String) throws -> CompetitionGoldenTrace {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CompetitionCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // CompetitionCore
            .deletingLastPathComponent() // Modules
            .deletingLastPathComponent() // repository root
        let url = repositoryRoot
            .appendingPathComponent("HealthCompTests/Fixtures", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TraceError.missingGolden(url.path)
        }
        return try JSONDecoder().decode(
            CompetitionGoldenTrace.self,
            from: Data(contentsOf: url)
        )
    }

    private func decodeTerminal(
        _ object: [String: Any]
    ) throws -> CompetitionGoldenTrace.Terminal {
        try JSONDecoder().decode(
            CompetitionGoldenTrace.Terminal.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}

private enum TraceScenario: String {
    case lateWatchSync = "late-watch-sync"
    case win
    case loss
    case tie

    var goldenName: String { rawValue }
}

private enum TraceEvaluation {
    case productionCalendar
    case accelerated
}

private struct CompetitionGoldenTrace: Codable, Equatable {
    typealias Terminal = CompetitionSemanticTerminalProjection

    let schema: String
    let payloadVersion: UInt32
    let scenario: String
    let seed: UInt64
    let timeZoneIdentifier: String
    let semanticEventIDs: [String]
    let notificationDecisionSemanticIDs: [String]
    let terminal: Terminal
    let normalizedTransportMetadata: [String]
    let coverage: [String]
}

private struct CompetitionTraceRunner {
    private let scenario: TraceScenario
    private let evaluation: TraceEvaluation
    private let engine = CompetitionEngine()
    private let competitionID = CompetitionID(
        UUID(uuidString: "10101010-2020-3030-4040-505050505050")!
    )
    private let seed: UInt64 = 42
    private let timeZoneIdentifier = "America/Los_Angeles"

    init(scenario: TraceScenario, evaluation: TraceEvaluation) {
        self.scenario = scenario
        self.evaluation = evaluation
    }

    func run() throws -> CompetitionGoldenTrace {
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: timeZoneIdentifier
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
        var journal = try CompetitionJournal(genesis: genesis)
        let accepted = try engine.accept(
            genesis.makeCompetition(),
            at: acceptedAt,
            timeZoneIdentifier: timeZoneIdentifier,
            opponent: OpponentPlanGenerationRequest(
                seed: seed,
                generatorVersion: .v1,
                difficulty: .balanced
            )
        )
        try append([.lifecycle(accepted)], to: &journal)

        let acceptedProjection = try CompetitionReplayer.replay(journal)
        let schedule = try required(acceptedProjection.competition.schedule)
        let opponentPlan = try required(acceptedProjection.competition.opponentPlan)
        let days = try calendar.sevenDayWindow(startingOn: schedule.startDay)
        let dayStarts = try days.map(calendar.startOfDay)
        let endBoundary = try calendar.startOfDay(calendar.day(after: days[6]))
        let finalPoints = opponentPlan.days.map(\.finalPoints)
        let targetPoints = ownerPoints(opponentPoints: finalPoints)

        // Day 1 crosses the America/Los_Angeles spring DST transition. The
        // production path observes calendar boundaries incrementally; the
        // accelerated path jumps directly between the same logical dates.
        try recordRefresh(
            at: dayStarts[0].addingTimeInterval(12 * 3_600),
            trigger: .foreground,
            observedPoints: Array(targetPoints.prefix(1)),
            revisedGoalOrdinal: nil,
            failure: false,
            missingDaySeven: false,
            duplicateCallback: false,
            journal: &journal
        )

        if evaluation == .productionCalendar {
            for boundary in dayStarts[1...2] {
                try observeClock(at: boundary, journal: &journal)
            }
        }
        try recordRefresh(
            at: dayStarts[3].addingTimeInterval(12 * 3_600),
            trigger: .protectedDataAvailable,
            observedPoints: Array(targetPoints.prefix(4)),
            revisedGoalOrdinal: nil,
            failure: true,
            missingDaySeven: false,
            duplicateCallback: true,
            journal: &journal
        )

        try recordRefresh(
            at: dayStarts[4].addingTimeInterval(12 * 3_600),
            trigger: .summaryUpdate,
            observedPoints: Array(targetPoints.prefix(5)),
            revisedGoalOrdinal: 2,
            failure: false,
            missingDaySeven: false,
            duplicateCallback: false,
            journal: &journal
        )

        if evaluation == .productionCalendar {
            try observeClock(at: dayStarts[5], journal: &journal)
            try observeClock(at: dayStarts[6], journal: &journal)
        }
        try recordRefresh(
            at: endBoundary.addingTimeInterval(60),
            trigger: .foreground,
            observedPoints: targetPoints,
            revisedGoalOrdinal: 2,
            failure: false,
            missingDaySeven: true,
            duplicateCallback: false,
            journal: &journal
        )
        try recordRefresh(
            at: endBoundary.addingTimeInterval(300),
            trigger: .summaryUpdate,
            observedPoints: targetPoints,
            revisedGoalOrdinal: 2,
            failure: false,
            missingDaySeven: false,
            duplicateCallback: false,
            journal: &journal
        )

        if scenario == .lateWatchSync {
            try finalize(
                at: endBoundary.addingTimeInterval(3_600),
                minimumStabilityNanoseconds: 120_000_000_000,
                bestAvailableDeadline: endBoundary.addingTimeInterval(3_600),
                journal: &journal
            )
        } else {
            try recordRefresh(
                at: endBoundary.addingTimeInterval(600),
                trigger: .reconciliationProbe,
                observedPoints: targetPoints,
                revisedGoalOrdinal: 2,
                failure: false,
                missingDaySeven: false,
                duplicateCallback: false,
                journal: &journal
            )
            try finalize(
                at: endBoundary.addingTimeInterval(600),
                minimumStabilityNanoseconds: 120_000_000_000,
                bestAvailableDeadline: endBoundary.addingTimeInterval(3_600),
                journal: &journal
            )
        }

        let resultRecord = try NotificationEmissionRecorded(
            competitionID: competitionID,
            family: .result,
            episodeKey: .result,
            disposition: .emitted,
            decidedAt: endBoundary.addingTimeInterval(3_601),
            basisPublicationRevision: max(1, journal.cursor.commitRevision)
        )
        try append(
            [.notificationEmissionRecorded(resultRecord)],
            to: &journal
        )

        let projection = try CompetitionReplayer.replay(journal)
        let terminal = try CompetitionSemanticTerminalProjection(
            projection: projection
        )
        XCTAssertTrue(journal.envelopes.allSatisfy { $0.payloadVersion == 4 })

        let notificationIDs = journal.envelopes.compactMap { envelope in
            envelope.semanticEventID.hasPrefix("competition-notification:")
                ? envelope.semanticEventID
                : nil
        }
        return CompetitionGoldenTrace(
            schema: "healthcomp-competition-trace-v1",
            payloadVersion: CompetitionJournalEnvelope.currentPayloadVersion,
            scenario: scenario.rawValue,
            seed: seed,
            timeZoneIdentifier: timeZoneIdentifier,
            semanticEventIDs: journal.envelopes.map(\.semanticEventID),
            notificationDecisionSemanticIDs: notificationIDs,
            terminal: terminal,
            normalizedTransportMetadata: [
                "attemptID is deterministic logical identity; monotonicInstant is transport timing and is not serialized into this trace",
                "OS notification delivery state is excluded; durable notification decision semantic IDs are included separately",
            ],
            coverage: [
                "late-day-7-arrival",
                "missed-foreground-boundaries",
                "duplicate-callback",
                "dst-boundary",
                "goal-revision",
                "unavailable-data",
                scenario == .lateWatchSync
                    ? "best-available-fallback"
                    : "stable-post-boundary-finalization",
            ]
        )
    }

    private func observeClock(
        at date: Date,
        journal: inout CompetitionJournal
    ) throws {
        let projection = try CompetitionReplayer.replay(journal)
        let events = try engine.observeClock(
            projection.competition,
            at: date
        ).map(CompetitionDomainEvent.lifecycle)
        try append(events, to: &journal)
    }

    private func recordRefresh(
        at date: Date,
        trigger: ActivityRefreshTrigger,
        observedPoints: [Int],
        revisedGoalOrdinal: Int?,
        failure: Bool,
        missingDaySeven: Bool,
        duplicateCallback: Bool,
        journal: inout CompetitionJournal
    ) throws {
        let beforeCursor = journal.cursor
        let projection = try CompetitionReplayer.replay(journal)
        let clock = try engine.observeClock(
            projection.competition,
            at: date
        ).map(CompetitionDomainEvent.lifecycle)
        var candidate = journal
        try append(clock, to: &candidate)
        let afterClock = try CompetitionReplayer.replay(candidate)
        let schedule = try required(afterClock.competition.schedule)
        let days = try schedule.calendar.sevenDayWindow(
            startingOn: schedule.startDay
        )
        let ordinal = afterClock.activityRefresh.nextAttemptOrdinal
        let refresh = try ActivityRefreshAttemptRecorded(
            attemptID: [
                "runtime",
                competitionID.rawValue.uuidString.lowercased(),
                "attempt",
                String(ordinal),
            ].joined(separator: "-"),
            competitionID: competitionID,
            attemptOrdinal: ordinal,
            trigger: trigger,
            attemptedAt: date,
            readAt: date,
            monotonicInstant: MonotonicInstant(
                epochID: evaluation == .productionCalendar
                    ? "production-transport"
                    : "accelerated-transport",
                nanoseconds: ordinal * 180_000_000_000
            ),
            readStatus: failure
                ? .failed(reason: .protectedDataUnavailable)
                : .completed,
            days: try days.enumerated().map { offset, day in
                let dayOrdinal = offset + 1
                let availability: ActivityDayAvailability
                if failure {
                    let start = try schedule.calendar.startOfDay(day)
                    availability = start <= date
                        ? .unavailable(reason: .sourceDataUnavailable)
                        : .notYetOccurred
                } else if missingDaySeven && dayOrdinal == 7 {
                    availability = .missing
                } else if dayOrdinal <= observedPoints.count {
                    availability = .observed(
                        try snapshot(
                            points: observedPoints[offset],
                            revisedGoal: revisedGoalOrdinal == dayOrdinal
                        )
                    )
                } else {
                    availability = .notYetOccurred
                }
                return ActivityDayObservation(
                    day: day,
                    ordinal: dayOrdinal,
                    availability: availability
                )
            }
        )
        var batch = clock + [CompetitionDomainEvent.activityRefreshAttemptRecorded(refresh)]
        if case .tallying = afterClock.competition.lifecycle {
            let evidence = try afterClock.finalReadEvidence(after: refresh)
            batch.append(
                .lifecycle(
                    try engine.recordFinalRead(
                        afterClock.competition,
                        evidence: evidence
                    )
                )
            )
        }
        try append(batch, to: &journal)
        if duplicateCallback {
            _ = try journal.append(batch, expectedCursor: beforeCursor)
        }
    }

    private func finalize(
        at date: Date,
        minimumStabilityNanoseconds: UInt64,
        bestAvailableDeadline: Date,
        journal: inout CompetitionJournal
    ) throws {
        let projection = try CompetitionReplayer.replay(journal)
        let policy = FinalizationPolicy(
            minimumStabilityNanoseconds: minimumStabilityNanoseconds,
            bestAvailableDeadline: bestAvailableDeadline
        )
        guard case let .finalize(authorization) = policy.decision(
            for: projection.competition,
            at: date
        ) else {
            throw TraceError.notReadyToFinalize
        }
        try append(
            [
                .lifecycle(
                    try engine.finalize(
                        projection.competition,
                        authorization: authorization,
                        at: date
                    )
                ),
            ],
            to: &journal
        )
    }

    private func append(
        _ events: [CompetitionDomainEvent],
        to journal: inout CompetitionJournal
    ) throws {
        guard !events.isEmpty else { return }
        _ = try journal.append(events, expectedCursor: journal.cursor)
    }

    private func ownerPoints(opponentPoints: [Int]) -> [Int] {
        switch scenario {
        case .lateWatchSync, .win:
            return opponentPoints.map { min(600, $0 + 60) }
        case .loss:
            return opponentPoints.map { max(0, $0 - 60) }
        case .tie:
            return opponentPoints
        }
    }

    private func snapshot(points: Int, revisedGoal: Bool) throws -> ActivitySnapshot {
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

    private func localDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try required(TimeZone(identifier: timeZoneIdentifier))
        return try required(
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

    private func required<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw TraceError.missingFixtureValue }
        return value
    }

}

private enum TraceError: Error {
    case missingGolden(String)
    case missingFixtureValue
    case notReadyToFinalize
    case notCompleted
}
