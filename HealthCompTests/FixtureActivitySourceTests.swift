import CompetitionCore
import XCTest
@testable import HealthComp

final class FixtureActivitySourceTests: XCTestCase {
    func testFixtureDeclaresUTCByDefaultAndRecordsSetSynchronizationNoOps() async throws {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let firstStart = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 9,
            day: 1,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let secondStart = try calendar.day(after: firstStart)
        let first = try CompetitionActivityWindow(
            calendar: calendar,
            startDay: firstStart
        )
        let second = try CompetitionActivityWindow(
            calendar: calendar,
            startDay: secondStart
        )
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: try calendar.startOfDay(firstStart),
                    monotonic: MonotonicInstant(
                        epochID: "fixture-subscriptions",
                        nanoseconds: 0
                    )
                ),
                initialDays: [],
                changes: []
            )
        )

        let timeZoneIdentifier = await source.timeZoneIdentifier()
        XCTAssertEqual(timeZoneIdentifier, "UTC")
        await source.synchronizeSummarySubscriptions(to: [first])
        await source.synchronizeSummarySubscriptions(to: [first])
        await source.synchronizeSummarySubscriptions(to: [first, second])
        await source.synchronizeSummarySubscriptions(to: [])

        let desired = await source.desiredSummarySubscriptionWindows()
        let synchronizations = await source.summarySubscriptionSynchronizations()
        XCTAssertEqual(desired, [])
        XCTAssertEqual(
            synchronizations,
            [
                .changed(to: [first]),
                .noOp(desired: [first]),
                .changed(to: [first, second]),
                .changed(to: []),
            ]
        )
    }

    func testExtremeFiniteAdvanceSaturatesMonotonicNanoseconds() async throws {
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: Date(timeIntervalSinceReferenceDate: 0),
                    monotonic: MonotonicInstant(
                        epochID: "fixture-saturation",
                        nanoseconds: 1
                    )
                ),
                initialDays: [],
                changes: []
            )
        )

        try await source.advance(to: .distantFuture)

        let instant = await source.instant()
        XCTAssertEqual(instant.wallDate, .distantFuture)
        XCTAssertEqual(instant.monotonic.nanoseconds, UInt64.max)
    }

    func testCancelledWaitDoesNotResumeAsAStaleScheduledWake() async throws {
        let initialDate = Date(timeIntervalSinceReferenceDate: 4_000)
        let wakeDate = initialDate.addingTimeInterval(60)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: initialDate,
                    monotonic: MonotonicInstant(
                        epochID: "fixture-wait",
                        nanoseconds: 0
                    )
                ),
                initialDays: [],
                changes: []
            )
        )
        let waiting = Task {
            try await source.wait(until: wakeDate)
        }
        var pendingWaiters = await source.pendingWaiterCount()
        for _ in 0..<50_000 where pendingWaiters != 1 {
            await Task.yield()
            pendingWaiters = await source.pendingWaiterCount()
        }
        XCTAssertEqual(pendingWaiters, 1)

        waiting.cancel()
        try await source.advance(to: wakeDate)

        do {
            try await waiting.value
            XCTFail("Expected cancellation instead of a stale wake")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        pendingWaiters = await source.pendingWaiterCount()
        XCTAssertEqual(pendingWaiters, 0)
    }

    func testLargeAdvanceRequiresProductionSignalCheckpointStepping() async throws {
        let initialDate = Date(timeIntervalSinceReferenceDate: 3_000)
        let firstCheckpoint = initialDate.addingTimeInterval(60)
        let secondCheckpoint = initialDate.addingTimeInterval(120)
        let thirdCheckpoint = initialDate.addingTimeInterval(180)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: initialDate,
                    monotonic: MonotonicInstant(
                        epochID: "fixture-checkpoints",
                        nanoseconds: 0
                    )
                ),
                initialDays: [],
                changes: [
                    try FixtureActivityChange(
                        at: firstCheckpoint,
                        updates: [],
                        triggers: [.summaryUpdate]
                    ),
                    try FixtureActivityChange(
                        at: secondCheckpoint,
                        updates: [],
                        triggers: [.summaryUpdate]
                    ),
                    try FixtureActivityChange(
                        at: thirdCheckpoint,
                        updates: [],
                        triggers: [.reconciliationProbe]
                    ),
                ]
            )
        )

        do {
            try await source.advance(to: thirdCheckpoint)
            XCTFail("Expected explicit checkpoint stepping")
        } catch {
            let expected: FixtureActivitySourceError? =
                .mustAdvanceThroughCheckpoint(firstCheckpoint)
            XCTAssertEqual(
                error as? FixtureActivitySourceError,
                expected
            )
        }
        let beforeStepping = await source.instant()
        XCTAssertEqual(beforeStepping.wallDate, initialDate)

        try await source.advance(to: firstCheckpoint)
        try await source.advance(to: secondCheckpoint)
        try await source.advance(to: thirdCheckpoint)
        let afterStepping = await source.instant()
        XCTAssertEqual(afterStepping.wallDate, thirdCheckpoint)
    }

    func testEpochChangeResetsMonotonicTimeWithinAtomicAdvance() async throws {
        let initialDate = Date(timeIntervalSinceReferenceDate: 2_000)
        let rebootDate = initialDate.addingTimeInterval(60)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: initialDate,
                    monotonic: MonotonicInstant(
                        epochID: "before-reboot",
                        nanoseconds: 10
                    )
                ),
                initialDays: [],
                changes: [
                    try FixtureActivityChange(
                        at: rebootDate,
                        updates: [],
                        triggers: [.reconciliationProbe],
                        epochID: "after-reboot",
                        resetMonotonicNanoseconds: 25
                    ),
                ]
            )
        )

        try await source.advance(
            to: rebootDate.addingTimeInterval(30)
        )

        let instant = await source.instant()
        XCTAssertEqual(instant.wallDate, rebootDate.addingTimeInterval(30))
        XCTAssertEqual(instant.monotonic.epochID, "after-reboot")
        XCTAssertEqual(
            instant.monotonic.nanoseconds,
            25 + 30_000_000_000
        )
    }

    func testReadFailuresAdvanceAtomicallyAndCanRecover() async throws {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let start = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 7,
            day: 1,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let window = try CompetitionActivityWindow(
            calendar: calendar,
            startDay: start
        )
        let initialDate = try calendar.startOfDay(start)
        let failureDate = initialDate.addingTimeInterval(60)
        let recoveryDate = initialDate.addingTimeInterval(120)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: initialDate,
                    monotonic: MonotonicInstant(
                        epochID: "fixture-failure",
                        nanoseconds: 0
                    )
                ),
                initialDays: [],
                changes: [
                    try FixtureActivityChange(
                        at: failureDate,
                        updates: [],
                        triggers: [.protectedDataAvailable],
                        readState: .failure(.protectedDataUnavailable)
                    ),
                    try FixtureActivityChange(
                        at: recoveryDate,
                        updates: [
                            .snapshot(
                                day: window.days[0],
                                snapshot: try snapshot(moveValue: 300)
                            ),
                        ],
                        triggers: [.foreground],
                        readState: .available
                    ),
                ]
            )
        )

        try await source.advance(to: failureDate)
        do {
            _ = try await source.read(window)
            XCTFail("Expected the fixture read failure")
        } catch {
            XCTAssertEqual(
                error as? CompetitionActivitySourceError,
                .protectedDataUnavailable
            )
        }

        try await source.advance(to: recoveryDate)
        let recovered = try await source.read(window)
        XCTAssertEqual(
            recovered.days[0],
            .snapshot(
                day: window.days[0],
                snapshot: try snapshot(moveValue: 300)
            )
        )
    }

    func testRepeatedAdvancesAccumulateOnlyActualElapsedMonotonicTime() async throws {
        let initialDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let changeDate = initialDate.addingTimeInterval(60)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: initialDate,
                    monotonic: MonotonicInstant(
                        epochID: "fixture-epoch",
                        nanoseconds: 10
                    )
                ),
                initialDays: [],
                changes: [
                    try FixtureActivityChange(
                        at: changeDate,
                        updates: [],
                        triggers: []
                    ),
                ]
            )
        )

        try await source.advance(
            to: initialDate.addingTimeInterval(90)
        )
        try await source.advance(
            to: initialDate.addingTimeInterval(100)
        )

        let instant = await source.instant()
        XCTAssertEqual(
            instant.monotonic.nanoseconds,
            10 + 100_000_000_000
        )
    }

    func testLateDaySevenRevisionAndReconciliationProbeAdvanceDataAndSignalsTogether() async throws {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let start = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 7,
            day: 1,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let window = try CompetitionActivityWindow(
            calendar: calendar,
            startDay: start
        )
        let endBoundary = try calendar.startOfDay(
            calendar.day(after: window.days[6])
        )
        let arrivalDate = endBoundary.addingTimeInterval(60)
        let revisionDate = endBoundary.addingTimeInterval(120)
        let probeDate = endBoundary.addingTimeInterval(180)
        let firstDaySeven = try snapshot(moveValue: 400)
        let revisedDaySeven = try snapshot(moveValue: 550)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: endBoundary,
                    monotonic: MonotonicInstant(
                        epochID: "fixture-epoch",
                        nanoseconds: 0
                    )
                ),
                initialDays: [],
                changes: [
                    try FixtureActivityChange(
                        at: arrivalDate,
                        updates: [
                            .snapshot(
                                day: window.days[6],
                                snapshot: firstDaySeven
                            ),
                        ],
                        triggers: [.summaryUpdate]
                    ),
                    try FixtureActivityChange(
                        at: revisionDate,
                        updates: [
                            .snapshot(
                                day: window.days[6],
                                snapshot: revisedDaySeven
                            ),
                        ],
                        triggers: [.summaryUpdate]
                    ),
                    try FixtureActivityChange(
                        at: probeDate,
                        updates: [],
                        triggers: [.reconciliationProbe]
                    ),
                ]
            )
        )
        let activation = try await source.activateSignalOwnership(
            for: UUID()
        )
        try await source.commitSignalOwnershipActivation(activation)
        let signals = await source.signals()
        let signalTask = Task { () -> [EnvironmentSignal] in
            var iterator = signals.makeAsyncIterator()
            var values: [EnvironmentSignal] = []
            while values.count < 3, let signal = await iterator.next() {
                values.append(signal)
            }
            return values
        }

        let initial = try await source.read(window)
        XCTAssertEqual(initial.days[6], .missing(day: window.days[6]))

        try await source.advance(to: arrivalDate)
        let arrived = try await source.read(window)
        XCTAssertEqual(
            arrived.days[6],
            .snapshot(day: window.days[6], snapshot: firstDaySeven)
        )

        try await source.advance(to: revisionDate)
        let revised = try await source.read(window)
        XCTAssertEqual(
            revised.days[6],
            .snapshot(day: window.days[6], snapshot: revisedDaySeven)
        )

        try await source.advance(to: probeDate)
        let emitted = await signalTask.value
        XCTAssertEqual(
            emitted.map(\.trigger),
            [.summaryUpdate, .summaryUpdate, .reconciliationProbe]
        )
    }

    func testInactiveFixtureDoesNotSubscribeOrEmitSignals() async throws {
        let initialDate = Date(timeIntervalSinceReferenceDate: 8_000)
        let signalDate = initialDate.addingTimeInterval(60)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: initialDate,
                    monotonic: MonotonicInstant(
                        epochID: "inactive-fixture-signals",
                        nanoseconds: 0
                    )
                ),
                initialDays: [],
                changes: [
                    try FixtureActivityChange(
                        at: signalDate,
                        updates: [],
                        triggers: [.summaryUpdate]
                    ),
                ]
            )
        )
        let signals = await source.signals()
        let nextSignal = Task { () -> EnvironmentSignal? in
            var iterator = signals.makeAsyncIterator()
            return await iterator.next()
        }

        try await source.advance(to: signalDate)

        let inactiveSignal = await nextSignal.value
        let inactiveSubscriberCount = await source.signalSubscriberCount()
        XCTAssertNil(inactiveSignal)
        XCTAssertEqual(inactiveSubscriberCount, 0)
    }

    func testOnlyHealthKitObserverDeliverySignalsRequireCompletion()
        async throws
    {
        let initialDate = Date(timeIntervalSinceReferenceDate: 9_000)
        let signalDate = initialDate.addingTimeInterval(60)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: initialDate,
                    monotonic: MonotonicInstant(
                        epochID: "fixture-observer-delivery-completion",
                        nanoseconds: 0
                    )
                ),
                initialDays: [],
                changes: [
                    try FixtureActivityChange(
                        at: signalDate,
                        updates: [],
                        triggers: [
                            .observerWakeupForeground,
                            .observerWakeupBackground,
                            .summaryUpdate,
                        ]
                    ),
                ]
            )
        )
        let activation = try await source.activateSignalOwnership(for: UUID())
        try await source.commitSignalOwnershipActivation(activation)
        let stream = await source.signals()
        let signals = Task { () -> [EnvironmentSignal] in
            var iterator = stream.makeAsyncIterator()
            var values: [EnvironmentSignal] = []
            while values.count < 3, let signal = await iterator.next() {
                values.append(signal)
            }
            return values
        }

        try await source.advance(to: signalDate)
        let emitted = await signals.value

        XCTAssertEqual(
            emitted.map(\.trigger),
            [
                .observerWakeupForeground,
                .observerWakeupBackground,
                .summaryUpdate,
            ]
        )
        XCTAssertEqual(emitted.map(\.requiresCompletion), [true, true, false])
    }

    private func snapshot(moveValue: Double) throws -> ActivitySnapshot {
        ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(value: moveValue, goal: 500),
            exercise: try ActivityRingReading(value: 30, goal: 30),
            standOrRoll: try ActivityRingReading(value: 12, goal: 12),
            pauseState: .running
        )
    }
}
