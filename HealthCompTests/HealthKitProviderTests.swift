import XCTest
import HealthKit
import CompetitionCore
import Dispatch
@testable import HealthComp

final class HealthKitProviderTests: XCTestCase {
    func testLegacyAuthorizationIncludesMetricAndCompetitionReadTypes() async throws {
        let capturedTypes = LockedObjectTypeSet()
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: HealthKitCompetitionDependencies(
                isHealthDataAvailable: { true },
                requestAuthorization: { capturedTypes.set($0) },
                readActivitySummaries: { _ in [] },
                resolveStandMode: { .unknown },
                summaryUpdates: { _ in AsyncStream { $0.finish() } },
                observerUpdates: { AsyncStream { $0.finish() } },
                stopObserverUpdates: {}
            )
        )

        try await provider.requestAuthorization()

        let requested = capturedTypes.value
        XCTAssertTrue(requested.contains(HKQuantityType(.stepCount)))
        XCTAssertTrue(
            requested.contains(HKQuantityType(.distanceWalkingRunning))
        )
        XCTAssertTrue(requested.contains(HKCategoryType(.sleepAnalysis)))
        XCTAssertTrue(requested.contains(HKObjectType.activitySummaryType()))
        XCTAssertTrue(requested.contains(HKCharacteristicType(.wheelchairUse)))
        XCTAssertTrue(requested.contains(HKQuantityType(.appleMoveTime)))
        XCTAssertTrue(requested.contains(HKWorkoutType.workoutType()))
    }

    func testBackgroundDeliveryRetriesOnlyFailedTypesAfterAuthorization() async throws {
        let attempts = LockedStringCounts()
        let failedType = HKQuantityType(.activeEnergyBurned)
        let standHourType = HKCategoryType(.appleStandHour)
        let dependencies = HealthKitCompetitionDependencies(
            isHealthDataAvailable: { true },
            requestAuthorization: { _ in },
            readActivitySummaries: { _ in [] },
            resolveStandMode: { .unknown },
            summaryUpdates: { _ in AsyncStream { $0.finish() } },
            observerUpdates: { AsyncStream { $0.finish() } },
            stopObserverUpdates: {},
            enableBackgroundDelivery: { type in
                let attempt = attempts.increment(type.identifier)
                if type == failedType, attempt == 1 {
                    throw TestProviderError.unavailable
                }
            }
        )
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: dependencies
        )
        _ = try await activateOwner(provider)

        _ = await provider.signals()
        XCTAssertEqual(attempts.count(for: failedType.identifier), 1)
        XCTAssertEqual(attempts.count(for: standHourType.identifier), 1)

        try await provider.requestReadAuthorization()
        XCTAssertEqual(attempts.count(for: failedType.identifier), 2)
        XCTAssertEqual(attempts.count(for: standHourType.identifier), 1)

        _ = await provider.signals()
        XCTAssertEqual(attempts.count(for: failedType.identifier), 2)
        XCTAssertEqual(attempts.count(for: standHourType.identifier), 1)
    }

    func testAuthorizationWaitsForAndRetriesOverlappingFailedRegistration() async throws {
        let targetType = HKQuantityType(.activeEnergyBurned)
        let gate = BackgroundDeliveryOverlapGate(
            targetIdentifier: targetType.identifier
        )
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: HealthKitCompetitionDependencies(
                isHealthDataAvailable: { true },
                requestAuthorization: { _ in
                    await gate.authorizationWasRequested()
                },
                readActivitySummaries: { _ in [] },
                resolveStandMode: { .unknown },
                summaryUpdates: { _ in AsyncStream { $0.finish() } },
                observerUpdates: { AsyncStream { $0.finish() } },
                stopObserverUpdates: {},
                enableBackgroundDelivery: { type in
                    try await gate.enable(type.identifier)
                }
            )
        )
        _ = try await activateOwner(provider)
        let initialRegistration = Task { await provider.signals() }
        await gate.waitUntilFirstAttemptIsBlocked()
        let authorization = Task {
            try await provider.requestReadAuthorization()
        }
        await gate.waitUntilAuthorizationWasRequested()
        for _ in 0..<100 { await Task.yield() }

        await gate.releaseFirstAttempt()
        _ = await initialRegistration.value
        try await authorization.value

        let attempts = await gate.attemptCount(for: targetType.identifier)
        XCTAssertEqual(attempts, 2)
    }

    func testReadDoesNotCreateSummarySubscriptionAndRepeatedDesiredSetStartsOnce() async throws {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let start = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 6,
            day: 2,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let window = try CompetitionActivityWindow(
            calendar: calendar,
            startDay: start
        )
        let streamStarts = LockedCounter()
        let updates = TestAsyncStream<[HKActivitySummary]>()
        let dependencies = HealthKitCompetitionDependencies(
            isHealthDataAvailable: { true },
            requestAuthorization: { _ in },
            readActivitySummaries: { _ in [] },
            resolveStandMode: { .unknown },
            summaryUpdates: { _ in
                streamStarts.increment()
                return updates.stream
            },
            observerUpdates: { AsyncStream { $0.finish() } },
            stopObserverUpdates: {}
        )
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: dependencies
        )
        _ = try await activateOwner(provider)

        _ = try await provider.read(window)
        XCTAssertEqual(streamStarts.value, 0)

        await provider.synchronizeSummarySubscriptions(to: [window])
        await provider.synchronizeSummarySubscriptions(to: [window])

        XCTAssertEqual(streamStarts.value, 1)
    }

    func testFinishedSummarySubscriptionRestartsOnEqualDesiredSetReconciliation() async throws {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let start = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 6,
            day: 2,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let window = try CompetitionActivityWindow(
            calendar: calendar,
            startDay: start
        )
        let starts = LockedWindowCounts()
        let streams = LockedWindowStreams()
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: HealthKitCompetitionDependencies(
                isHealthDataAvailable: { true },
                requestAuthorization: { _ in },
                readActivitySummaries: { _ in [] },
                resolveStandMode: { .unknown },
                summaryUpdates: { requestedWindow in
                    starts.increment(requestedWindow)
                    return streams.makeStream(for: requestedWindow)
                },
                observerUpdates: { AsyncStream { $0.finish() } },
                stopObserverUpdates: {}
            )
        )
        _ = try await activateOwner(provider)

        await provider.synchronizeSummarySubscriptions(to: [window])
        XCTAssertEqual(starts.count(window), 1)
        streams.finish(window)

        for _ in 0..<100 where starts.count(window) == 1 {
            await Task.yield()
            await provider.synchronizeSummarySubscriptions(to: [window])
        }

        XCTAssertEqual(starts.count(window), 2)
        await provider.synchronizeSummarySubscriptions(to: [window])
        XCTAssertEqual(starts.count(window), 2)
    }

    func testSummarySubscriptionReleaseStaleGenerationAndReAdd() async throws {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let firstStart = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 6,
            day: 2,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let secondStart = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 6,
            day: 9,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let firstWindow = try CompetitionActivityWindow(
            calendar: calendar,
            startDay: firstStart
        )
        let secondWindow = try CompetitionActivityWindow(
            calendar: calendar,
            startDay: secondStart
        )
        let starts = LockedWindowCounts()
        let streams = LockedWindowStreams()
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: HealthKitCompetitionDependencies(
                isHealthDataAvailable: { true },
                requestAuthorization: { _ in },
                readActivitySummaries: { _ in [] },
                resolveStandMode: { .unknown },
                summaryUpdates: { window in
                    starts.increment(window)
                    return streams.makeStream(for: window)
                },
                observerUpdates: { AsyncStream { $0.finish() } },
                stopObserverUpdates: {}
            )
        )
        _ = try await activateOwner(provider)
        await provider.synchronizeSummarySubscriptions(
            to: [firstWindow, secondWindow]
        )
        await provider.synchronizeSummarySubscriptions(
            to: [firstWindow, secondWindow]
        )
        XCTAssertEqual(starts.count(firstWindow), 1)
        XCTAssertEqual(starts.count(secondWindow), 1)

        streams.finish(firstWindow)
        await provider.synchronizeSummarySubscriptions(to: [secondWindow])
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(starts.count(firstWindow), 1)
        XCTAssertEqual(starts.count(secondWindow), 1)

        await provider.synchronizeSummarySubscriptions(
            to: [firstWindow, secondWindow]
        )
        XCTAssertEqual(starts.count(firstWindow), 2)
        XCTAssertEqual(starts.count(secondWindow), 1)
    }

    func testReleasingSummaryDescriptorsDoesNotCompletePendingObserverCallback() async throws {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let start = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 6,
            day: 2,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let window = try CompetitionActivityWindow(
            calendar: calendar,
            startDay: start
        )
        let observerUpdates = TestAsyncStream<HealthKitObserverWakeup>()
        let completion = LockedFlag()
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: HealthKitCompetitionDependencies(
                isHealthDataAvailable: { true },
                requestAuthorization: { _ in },
                readActivitySummaries: { _ in [] },
                resolveStandMode: { .unknown },
                summaryUpdates: { _ in TestAsyncStream<[HKActivitySummary]>().stream },
                observerUpdates: { observerUpdates.stream },
                stopObserverUpdates: { observerUpdates.finish() }
            )
        )
        _ = try await activateOwner(provider)
        let signals = await provider.signals()
        let received = expectation(
            description: "observer callback signal received"
        )
        let captured = LockedSignalBox()
        let reader = Task {
            var iterator = signals.makeAsyncIterator()
            if let signal = await iterator.next() {
                captured.set(signal)
                received.fulfill()
            }
        }
        await provider.synchronizeSummarySubscriptions(to: [window])
        observerUpdates.yield(
            HealthKitObserverWakeup(
                trigger: .observerWakeupBackground,
                completion: { completion.setTrue() }
            )
        )
        await fulfillment(of: [received], timeout: 1)
        let signal = try XCTUnwrap(captured.value)

        await provider.synchronizeSummarySubscriptions(to: [])

        XCTAssertFalse(completion.value)
        await provider.completeSignal(signal.id)
        XCTAssertTrue(completion.value)
        reader.cancel()
    }

    func testCancelledOneShotReadRemainsCancellation() async throws {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let start = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 6,
            day: 3,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let window = try CompetitionActivityWindow(
            calendar: calendar,
            startDay: start
        )
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: HealthKitCompetitionDependencies(
                isHealthDataAvailable: { true },
                requestAuthorization: { _ in },
                readActivitySummaries: { _ in throw CancellationError() },
                resolveStandMode: { .unknown },
                summaryUpdates: { _ in AsyncStream { $0.finish() } },
                observerUpdates: { AsyncStream { $0.finish() } },
                stopObserverUpdates: {}
            )
        )

        do {
            _ = try await provider.read(window)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }


    func testAvailableMetricTypes() {
        let provider = HealthKitProvider(userId: UUID())
        let types = provider.availableMetricTypes()
        XCTAssertTrue(types.contains(.activeCalories))
        XCTAssertTrue(types.contains(.exerciseMinutes))
        XCTAssertTrue(types.contains(.standHours))
        XCTAssertTrue(types.contains(.steps))
        XCTAssertTrue(types.contains(.sleepScore))
        XCTAssertTrue(types.contains(.distance))
    }

    func testMetricTypeToHKQuantityTypeMapping() {
        XCTAssertNotNil(HealthKitProvider.hkQuantityType(for: .activeCalories))
        XCTAssertNotNil(HealthKitProvider.hkQuantityType(for: .exerciseMinutes))
        XCTAssertNotNil(HealthKitProvider.hkQuantityType(for: .standHours))
        XCTAssertNotNil(HealthKitProvider.hkQuantityType(for: .steps))
        XCTAssertNotNil(HealthKitProvider.hkQuantityType(for: .distance))
        XCTAssertNil(HealthKitProvider.hkQuantityType(for: .sleepScore))
    }

    func testDateRangeToday() {
        let range = DateRange.today()
        let calendar = Calendar.current
        XCTAssertEqual(
            calendar.startOfDay(for: range.start),
            calendar.startOfDay(for: Date())
        )
        XCTAssertTrue(range.end > range.start)
    }

    func testDateRangeLastNDays() {
        let range = DateRange.lastNDays(7)
        let calendar = Calendar.current
        let daysBetween = calendar.dateComponents([.day], from: range.start, to: range.end).day!
        XCTAssertEqual(daysBetween, 8)
    }

    func testActivitySummaryConvertsToActivityRingSummary() throws {
        let userId = UUID(uuidString: "660e8400-e29b-41d4-a716-446655440000")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let activitySummary = HKActivitySummary()
        activitySummary.setValue(DateComponents(calendar: calendar, year: 2026, month: 5, day: 11), forKey: "dateComponents")
        activitySummary.activeEnergyBurned = HKQuantity(unit: .kilocalorie(), doubleValue: 750)
        activitySummary.activeEnergyBurnedGoal = HKQuantity(unit: .kilocalorie(), doubleValue: 500)
        activitySummary.appleExerciseTime = HKQuantity(unit: .minute(), doubleValue: 45)
        activitySummary.exerciseTimeGoal = HKQuantity(unit: .minute(), doubleValue: 30)
        activitySummary.appleStandHours = HKQuantity(unit: .count(), doubleValue: 18)
        activitySummary.standHoursGoal = HKQuantity(unit: .count(), doubleValue: 12)

        let summary = try HealthKitProvider.activityRingSummary(
            from: activitySummary,
            userId: userId,
            calendar: calendar,
            syncedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(summary.userId, userId)
        XCTAssertEqual(summary.date, "2026-05-11")
        XCTAssertEqual(summary.moveValue, 750)
        XCTAssertEqual(summary.moveGoal, 500)
        XCTAssertEqual(summary.exerciseValue, 45)
        XCTAssertEqual(summary.exerciseGoal, 30)
        XCTAssertEqual(summary.standValue, 18)
        XCTAssertEqual(summary.standGoal, 12)
        XCTAssertEqual(summary.source, .healthkit)
        XCTAssertEqual(summary.syncedAt, Date(timeIntervalSince1970: 0))
    }

    func testActivitySummaryUsesMoveTimeWhenMoveModeRequiresIt() throws {
        let userId = UUID()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let activitySummary = HKActivitySummary()
        activitySummary.activityMoveMode = .appleMoveTime
        activitySummary.setValue(DateComponents(calendar: calendar, year: 2026, month: 5, day: 12), forKey: "dateComponents")
        activitySummary.activeEnergyBurned = HKQuantity(unit: .kilocalorie(), doubleValue: 750)
        activitySummary.activeEnergyBurnedGoal = HKQuantity(unit: .kilocalorie(), doubleValue: 500)
        activitySummary.appleMoveTime = HKQuantity(unit: .minute(), doubleValue: 80)
        activitySummary.appleMoveTimeGoal = HKQuantity(unit: .minute(), doubleValue: 40)
        activitySummary.appleExerciseTime = HKQuantity(unit: .minute(), doubleValue: 30)
        activitySummary.exerciseTimeGoal = HKQuantity(unit: .minute(), doubleValue: 30)
        activitySummary.appleStandHours = HKQuantity(unit: .count(), doubleValue: 12)
        activitySummary.standHoursGoal = HKQuantity(unit: .count(), doubleValue: 12)

        let summary = try HealthKitProvider.activityRingSummary(
            from: activitySummary,
            userId: userId,
            calendar: calendar,
            syncedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(summary.moveValue, 80)
        XCTAssertEqual(summary.moveGoal, 40)
        XCTAssertEqual(summary.movePercent, 200)
    }

    func testActivitySummaryDateBoundsTreatDateRangeEndAsExclusive() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let range = DateRange(
            start: calendar.date(from: DateComponents(year: 2026, month: 5, day: 1))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 5, day: 8))!
        )

        let components = HealthKitProvider.activitySummaryDateComponents(for: range, calendar: calendar)

        XCTAssertEqual(components.start.year, 2026)
        XCTAssertEqual(components.start.month, 5)
        XCTAssertEqual(components.start.day, 1)
        XCTAssertEqual(components.end.year, 2026)
        XCTAssertEqual(components.end.month, 5)
        XCTAssertEqual(components.end.day, 7)
    }

    func testCompetitionReadUsesStoredZoneAndReturnsExactlySevenOrderedDays() async throws {
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: "Pacific/Kiritimati"
        )
        let start = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 12,
            day: 29,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let window = try CompetitionActivityWindow(
            calendar: calendar,
            startDay: start
        )
        let summaries = try window.days.reversed().map {
            try makeActivitySummary(day: $0, moveValue: Double($0.day))
        }
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: .test(summaries: summaries)
        )

        let read = try await provider.read(window)

        XCTAssertEqual(read.days.count, 7)
        XCTAssertEqual(read.days.map(\.day), window.days)
        for (index, result) in read.days.enumerated() {
            guard case let .snapshot(day, snapshot) = result else {
                return XCTFail("Expected a snapshot for ordinal \(index + 1)")
            }
            XCTAssertEqual(day, window.days[index])
            XCTAssertEqual(snapshot.move.value, Double(day.day))
        }
    }

    func testCompetitionReadRejectsDuplicateAndOutOfWindowSummaries() async throws {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let start = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 5,
            day: 1,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let window = try CompetitionActivityWindow(
            calendar: calendar,
            startDay: start
        )
        let duplicate = try makeActivitySummary(
            day: window.days[0],
            moveValue: 100
        )
        let duplicateProvider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: .test(
                summaries: [duplicate, duplicate]
            )
        )

        do {
            _ = try await duplicateProvider.read(window)
            XCTFail("Expected a duplicate-day response to be rejected")
        } catch {
            XCTAssertEqual(
                error as? CompetitionActivitySourceError,
                .invalidResponse
            )
        }

        let outsideDay = try calendar.day(after: window.days[6])
        let outsideProvider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: .test(
                summaries: [
                    try makeActivitySummary(day: outsideDay, moveValue: 100),
                ]
            )
        )
        do {
            _ = try await outsideProvider.read(window)
            XCTFail("Expected an out-of-window response to be rejected")
        } catch {
            XCTAssertEqual(
                error as? CompetitionActivitySourceError,
                .invalidResponse
            )
        }
    }

    func testCompetitionMappingPreservesNilAndZeroGoalsWithoutFabricatingScores() throws {
        let day = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 5,
            day: 11,
            timeZoneIdentifier: "UTC"
        )
        let summary = try makeActivitySummary(day: day, moveValue: 250)
        summary.exerciseTimeGoal = nil
        summary.standHoursGoal = HKQuantity(unit: .count(), doubleValue: 0)

        let mapped = try HealthKitProvider.competitionSnapshot(
            from: summary,
            calendar: try CompetitionCalendar(timeZoneIdentifier: "UTC"),
            standMode: .standHours
        )

        XCTAssertEqual(mapped.day, day)
        XCTAssertNil(mapped.snapshot.exercise.goal)
        XCTAssertEqual(mapped.snapshot.standOrRoll.goal, 0)
        XCTAssertEqual(
            ActivityScoreCalculator.score(
                mapped.snapshot,
                policy: .appleCompatibility
            ).availableScore,
            nil
        )
    }

    func testCompetitionMappingPreservesMoveTimeRollAndUnknownPauseOnIOS17() throws {
        let day = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 5,
            day: 12,
            timeZoneIdentifier: "UTC"
        )
        let summary = try makeActivitySummary(day: day, moveValue: 750)
        summary.activityMoveMode = .appleMoveTime
        summary.appleMoveTime = HKQuantity(unit: .minute(), doubleValue: 80)
        summary.appleMoveTimeGoal = HKQuantity(unit: .minute(), doubleValue: 40)

        let mapped = try HealthKitProvider.competitionSnapshot(
            from: summary,
            calendar: try CompetitionCalendar(timeZoneIdentifier: "UTC"),
            standMode: .rollHours,
            supportsPausedState: false
        )

        XCTAssertEqual(mapped.snapshot.moveMode, .moveMinutes)
        XCTAssertEqual(mapped.snapshot.move.value, 80)
        XCTAssertEqual(mapped.snapshot.move.goal, 40)
        XCTAssertEqual(mapped.snapshot.standMode, .rollHours)
        XCTAssertEqual(mapped.snapshot.pauseState, .unknown)
        XCTAssertNotNil(
            ActivityScoreCalculator.score(
                mapped.snapshot,
                policy: .healthKitCompatibility
            ).availableScore
        )
        XCTAssertNil(
            ActivityScoreCalculator.score(
                mapped.snapshot,
                policy: .appleCompatibility
            ).availableScore
        )
    }

    func testUnavailableWheelchairCharacteristicPreservesUnknownStandMode() async throws {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let start = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 5,
            day: 13,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let window = try CompetitionActivityWindow(
            calendar: calendar,
            startDay: start
        )
        let summary = try makeActivitySummary(
            day: window.days[0],
            moveValue: 400
        )
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: HealthKitCompetitionDependencies(
                isHealthDataAvailable: { true },
                requestAuthorization: { _ in },
                readActivitySummaries: { _ in [summary] },
                resolveStandMode: { throw TestProviderError.unavailable },
                summaryUpdates: { _ in AsyncStream { $0.finish() } },
                observerUpdates: { AsyncStream { $0.finish() } },
                stopObserverUpdates: {}
            )
        )

        let read = try await provider.read(window)

        guard case let .snapshot(_, snapshot) = read.days[0] else {
            return XCTFail("Expected an observed summary")
        }
        XCTAssertEqual(snapshot.standMode, .unknown)
        XCTAssertEqual(snapshot.standOrRoll.value, 12)
    }

    func testSummaryAndObserverPayloadsAreSignalsUntilAOneShotReread() async throws {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let start = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 6,
            day: 1,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let window = try CompetitionActivityWindow(
            calendar: calendar,
            startDay: start
        )
        let authoritative = try makeActivitySummary(
            day: window.days[0],
            moveValue: 321
        )
        let untrustedPayload = try makeActivitySummary(
            day: window.days[0],
            moveValue: 999
        )
        let summaryUpdates = TestAsyncStream<[HKActivitySummary]>()
        let observerUpdates = TestAsyncStream<HealthKitObserverWakeup>()
        let oneShotReads = LockedCounter()
        let completion = LockedFlag()
        let dependencies = HealthKitCompetitionDependencies(
            isHealthDataAvailable: { true },
            requestAuthorization: { _ in },
            readActivitySummaries: { _ in
                oneShotReads.increment()
                return [authoritative]
            },
            resolveStandMode: { .standHours },
            summaryUpdates: { _ in summaryUpdates.stream },
            observerUpdates: { observerUpdates.stream },
            stopObserverUpdates: { observerUpdates.finish() }
        )
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: dependencies
        )
        _ = try await activateOwner(provider)
        let stream = await provider.signals()
        let received = expectation(description: "two environment signals")
        received.expectedFulfillmentCount = 2
        let signalBox = LockedSignalsBox()
        let signalReader = Task {
            var iterator = stream.makeAsyncIterator()
            for _ in 0..<2 {
                if let signal = await iterator.next() {
                    signalBox.append(signal)
                    received.fulfill()
                }
            }
        }

        await provider.synchronizeSummarySubscriptions(to: [window])
        _ = try await provider.read(window)
        summaryUpdates.yield([untrustedPayload])
        observerUpdates.yield(
            HealthKitObserverWakeup(
                trigger: .observerWakeupBackground,
                completion: { completion.setTrue() }
            )
        )
        await fulfillment(of: [received], timeout: 1)
        signalReader.cancel()
        _ = await signalReader.result
        let signals = signalBox.value

        XCTAssertEqual(
            signals.map(\.trigger.rawValue).sorted(),
            [
                ActivityRefreshTrigger.summaryUpdate.rawValue,
                ActivityRefreshTrigger.observerWakeupBackground.rawValue,
            ].sorted()
        )
        let summarySignal = try XCTUnwrap(
            signals.first { $0.trigger == .summaryUpdate }
        )
        let backgroundSignal = try XCTUnwrap(
            signals.first { $0.trigger == .observerWakeupBackground }
        )
        XCTAssertFalse(summarySignal.requiresCompletion)
        XCTAssertTrue(backgroundSignal.requiresCompletion)
        XCTAssertFalse(completion.value)
        await provider.completeSignal(backgroundSignal.id)
        XCTAssertTrue(completion.value)

        let reread = try await provider.read(window)
        XCTAssertEqual(oneShotReads.value, 2)
        guard case let .snapshot(_, snapshot) = reread.days[0] else {
            return XCTFail("Expected the one-shot read to remain authoritative")
        }
        XCTAssertEqual(snapshot.move.value, 321)
    }

    func testCancellingSignalConsumerDoesNotPrematurelyCompleteBackgroundWork() async throws {
        let observerUpdates = TestAsyncStream<HealthKitObserverWakeup>()
        let completion = LockedFlag()
        let dependencies = HealthKitCompetitionDependencies(
            isHealthDataAvailable: { true },
            requestAuthorization: { _ in },
            readActivitySummaries: { _ in [] },
            resolveStandMode: { .standHours },
            summaryUpdates: { _ in AsyncStream { $0.finish() } },
            observerUpdates: { observerUpdates.stream },
            stopObserverUpdates: { observerUpdates.finish() }
        )
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: dependencies
        )
        _ = try await activateOwner(provider)
        let stream = await provider.signals()
        let captured = expectation(description: "observer signal captured")
        let signalBox = LockedSignalBox()
        let reader = Task {
            var iterator = stream.makeAsyncIterator()
            if let signal = await iterator.next() {
                signalBox.set(signal)
                captured.fulfill()
            }
            _ = await iterator.next()
        }

        observerUpdates.yield(
            HealthKitObserverWakeup(
                trigger: .observerWakeupBackground,
                completion: { completion.setTrue() }
            )
        )
        await fulfillment(of: [captured], timeout: 1)
        let signal = try XCTUnwrap(signalBox.value)
        reader.cancel()
        _ = await reader.result
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(completion.value)
        await provider.completeSignal(signal.id)
        XCTAssertTrue(completion.value)
    }

    func testCancellingReplacedSignalStreamDoesNotStopCurrentSubscription() async throws {
        let observerStopped = LockedFlag()
        let observerUpdates = TestAsyncStream<HealthKitObserverWakeup>(
            onTermination: { observerStopped.setTrue() }
        )
        let dependencies = HealthKitCompetitionDependencies(
            isHealthDataAvailable: { true },
            requestAuthorization: { _ in },
            readActivitySummaries: { _ in [] },
            resolveStandMode: { .unknown },
            summaryUpdates: { _ in AsyncStream { $0.finish() } },
            observerUpdates: { observerUpdates.stream },
            stopObserverUpdates: { observerUpdates.finish() }
        )
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: dependencies
        )
        _ = try await activateOwner(provider)
        let firstStream = await provider.signals()
        let firstReader = Task {
            var iterator = firstStream.makeAsyncIterator()
            return await iterator.next()
        }
        let secondStream = await provider.signals()
        let received = expectation(description: "current signal stream receives observer wakeup")
        let receivedSignal = LockedSignalBox()
        let secondReader = Task {
            var iterator = secondStream.makeAsyncIterator()
            let signal = await iterator.next()
            if signal?.trigger == .observerWakeupBackground {
                receivedSignal.set(signal)
                received.fulfill()
            }
        }

        firstReader.cancel()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(observerStopped.value)

        observerUpdates.yield(
            HealthKitObserverWakeup(
                trigger: .observerWakeupBackground,
                completion: {}
            )
        )
        await fulfillment(of: [received], timeout: 1)
        firstReader.cancel()
        secondReader.cancel()
        if let signal = receivedSignal.value {
            await provider.completeSignal(signal.id)
        }
    }

    func testCurrentStreamCancellationReplaysPendingObserverCompletion() async throws {
        let observerStopped = LockedFlag()
        let observerUpdates = TestAsyncStream<HealthKitObserverWakeup>(
            onTermination: { observerStopped.setTrue() }
        )
        let completion = LockedFlag()
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: HealthKitCompetitionDependencies(
                isHealthDataAvailable: { true },
                requestAuthorization: { _ in },
                readActivitySummaries: { _ in [] },
                resolveStandMode: { .unknown },
                summaryUpdates: { _ in AsyncStream { $0.finish() } },
                observerUpdates: { observerUpdates.stream },
                stopObserverUpdates: { observerUpdates.finish() }
            )
        )
        _ = try await activateOwner(provider)
        let firstStream = await provider.signals()
        let firstCaptured = expectation(
            description: "first observer signal captured"
        )
        let firstSignalBox = LockedSignalBox()
        let firstReader = Task {
            var iterator = firstStream.makeAsyncIterator()
            if let signal = await iterator.next() {
                firstSignalBox.set(signal)
                firstCaptured.fulfill()
            }
            _ = await iterator.next()
        }
        observerUpdates.yield(
            HealthKitObserverWakeup(
                trigger: .observerWakeupBackground,
                completion: { completion.setTrue() }
            )
        )
        await fulfillment(of: [firstCaptured], timeout: 1)
        let firstSignal = try XCTUnwrap(firstSignalBox.value)

        firstReader.cancel()
        _ = await firstReader.result
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(completion.value)
        XCTAssertFalse(observerStopped.value)

        let replacementStream = await provider.signals()
        let replayed = expectation(
            description: "pending HealthKit completion signal is replayed"
        )
        let replacementSignal = LockedSignalBox()
        let replacementReader = Task {
            var iterator = replacementStream.makeAsyncIterator()
            let signal = await iterator.next()
            replacementSignal.set(signal)
            replayed.fulfill()
        }
        await fulfillment(of: [replayed], timeout: 1)

        XCTAssertEqual(replacementSignal.value?.id, firstSignal.id)
        if let signal = replacementSignal.value {
            await provider.completeSignal(signal.id)
        }
        XCTAssertTrue(completion.value)
        replacementReader.cancel()
    }

    func testPendingObserverSignalRetainsEmissionOwnershipScope()
        async throws
    {
        let observerUpdates = TestAsyncStream<HealthKitObserverWakeup>()
        let completionCount = LockedCounter()
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: HealthKitCompetitionDependencies(
                isHealthDataAvailable: { true },
                requestAuthorization: { _ in },
                readActivitySummaries: { _ in [] },
                resolveStandMode: { .unknown },
                summaryUpdates: { _ in AsyncStream { $0.finish() } },
                observerUpdates: { observerUpdates.stream },
                stopObserverUpdates: { observerUpdates.finish() }
            )
        )
        let originProfileID = UUID()
        let replacementProfileID = UUID()
        let originActivation = try await provider.activateSignalOwnership(
            for: originProfileID
        )
        try await provider.commitSignalOwnershipActivation(originActivation)
        let originScope = originActivation.scope
        let originStream = await provider.signals()
        let capturedWakeup = provider.captureObserverWakeup(
            trigger: .observerWakeupBackground
        ) {
            completionCount.increment()
        }

        observerUpdates.yield(capturedWakeup)
        let originSignal = try await firstSignal(
            from: originStream,
            description: "origin-owned observer signal"
        )
        XCTAssertEqual(originSignal.ownershipScope, originScope)
        XCTAssertEqual(completionCount.value, 0)

        do {
            _ = try await provider.activateSignalOwnership(
                for: replacementProfileID
            )
            XCTFail("replacement activated before origin retirement")
        } catch let error as EnvironmentSignalOwnershipError {
            XCTAssertEqual(error, .activeOwnerNotRetired)
        }

        let firstCompletionAccepted = await provider.completeSignal(
            originSignal.id
        )
        XCTAssertTrue(firstCompletionAccepted)
        XCTAssertEqual(completionCount.value, 1)
        let duplicateCompletionAccepted = await provider.completeSignal(
            originSignal.id
        )
        XCTAssertFalse(duplicateCompletionAccepted)
        XCTAssertEqual(completionCount.value, 1)

        let drained = try await provider.quiesceSignalOwnership(
            for: originProfileID
        )
        XCTAssertEqual(drained, [])
        try await provider.retireSignalOwnership(for: originProfileID)
        let replacementActivation = try await activateOwner(
            provider,
            profileID: replacementProfileID
        )
        XCTAssertNotEqual(replacementActivation.scope, originScope)
        let replacementCompletionAccepted = await provider.completeSignal(
            originSignal.id
        )
        XCTAssertFalse(replacementCompletionAccepted)
        XCTAssertEqual(completionCount.value, 1)
    }

    func testStaleSameProfileLeaseCannotQuiesceReplacementOwner()
        async throws
    {
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: HealthKitCompetitionDependencies(
                isHealthDataAvailable: { true },
                requestAuthorization: { _ in },
                readActivitySummaries: { _ in [] },
                resolveStandMode: { .unknown },
                summaryUpdates: { _ in AsyncStream { $0.finish() } },
                observerUpdates: { AsyncStream { $0.finish() } },
                stopObserverUpdates: {}
            )
        )
        let profileID = UUID()
        let origin = try await activateOwner(
            provider,
            profileID: profileID
        )
        let replacement = try await activateOwner(
            provider,
            profileID: profileID
        )

        do {
            _ = try await provider.quiesceSignalOwnership(origin.lease)
            XCTFail("stale same-profile owner quiesced its replacement")
        } catch let error as EnvironmentSignalOwnershipError {
            XCTAssertEqual(error, .inactiveOwner)
        }

        let drained = try await provider.quiesceSignalOwnership(
            replacement.lease
        )
        XCTAssertEqual(drained, [])
        try await provider.retireSignalOwnership(replacement.lease)
    }

    func testProfileConvenienceLookupRejectsDifferentActiveOwner()
        async throws
    {
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: HealthKitCompetitionDependencies(
                isHealthDataAvailable: { true },
                requestAuthorization: { _ in },
                readActivitySummaries: { _ in [] },
                resolveStandMode: { .unknown },
                summaryUpdates: { _ in AsyncStream { $0.finish() } },
                observerUpdates: { AsyncStream { $0.finish() } },
                stopObserverUpdates: {}
            )
        )
        let owner = try await activateOwner(provider)

        do {
            _ = try await provider.quiesceSignalOwnership(for: UUID())
            XCTFail("different profile quiesced the active owner")
        } catch let error as EnvironmentSignalOwnershipError {
            XCTAssertEqual(error, .inactiveOwner)
        }

        let drained = try await provider.quiesceSignalOwnership(owner.lease)
        XCTAssertEqual(drained, [])
        try await provider.retireSignalOwnership(owner.lease)
    }

    func testCompletionBearingObserverWakeupBindsToActiveOwnershipScope()
        async throws
    {
        let observerUpdates = TestAsyncStream<HealthKitObserverWakeup>()
        let completion = LockedFlag()
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: HealthKitCompetitionDependencies(
                isHealthDataAvailable: { true },
                requestAuthorization: { _ in },
                readActivitySummaries: { _ in [] },
                resolveStandMode: { .unknown },
                summaryUpdates: { _ in AsyncStream { $0.finish() } },
                observerUpdates: { observerUpdates.stream },
                stopObserverUpdates: { observerUpdates.finish() }
            )
        )
        let activation = try await activateOwner(provider)
        let stream = await provider.signals()

        observerUpdates.yield(
            HealthKitObserverWakeup(
                trigger: .observerWakeupBackground
            ) {
                completion.setTrue()
            }
        )
        let signal = try await firstSignal(
            from: stream,
            description: "completion-bearing observer wakeup"
        )

        XCTAssertEqual(signal.ownershipScope, activation.scope)
        let completionAccepted = await provider.completeSignal(signal.id)
        XCTAssertTrue(completionAccepted)
        XCTAssertTrue(completion.value)
    }

    func testQuiesceUsesObserverStopHookToFinishOpenStream()
        async throws
    {
        let observerUpdates = TestAsyncStream<HealthKitObserverWakeup>()
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: HealthKitCompetitionDependencies(
                isHealthDataAvailable: { true },
                requestAuthorization: { _ in },
                readActivitySummaries: { _ in [] },
                resolveStandMode: { .unknown },
                summaryUpdates: { _ in AsyncStream { $0.finish() } },
                observerUpdates: { observerUpdates.stream },
                stopObserverUpdates: { observerUpdates.finish() }
            )
        )
        let activation = try await activateOwner(provider)
        _ = await provider.signals()
        let quiesced = expectation(description: "observer stream quiesced")
        let task = Task {
            _ = try await provider.quiesceSignalOwnership(
                activation.lease
            )
            quiesced.fulfill()
        }

        await fulfillment(of: [quiesced], timeout: 0.1)
        observerUpdates.finish()
        _ = try await task.value
        try await provider.retireSignalOwnership(activation.lease)
    }

    func testQueuedSummaryUpdateRetainsSubscriptionOwnershipScope()
        async throws
    {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let startDay = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 30,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let window = try CompetitionActivityWindow(
            calendar: calendar,
            startDay: startDay
        )
        let summaryUpdates = TestAsyncStream<[HKActivitySummary]>()
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: HealthKitCompetitionDependencies(
                isHealthDataAvailable: { true },
                requestAuthorization: { _ in },
                readActivitySummaries: { _ in [] },
                resolveStandMode: { .unknown },
                summaryUpdates: { _ in summaryUpdates.stream },
                observerUpdates: { AsyncStream { $0.finish() } },
                stopObserverUpdates: {}
            )
        )
        let originProfileID = UUID()
        let originActivation = try await provider.activateSignalOwnership(
            for: originProfileID
        )
        try await provider.commitSignalOwnershipActivation(originActivation)
        let originScope = originActivation.scope
        await provider.synchronizeSummarySubscriptions(to: [window])
        let signals = await provider.signals()

        summaryUpdates.yield([])
        let signal = try await firstSignal(
            from: signals,
            description: "queued origin-owned summary signal"
        )

        XCTAssertEqual(signal.trigger, .summaryUpdate)
        XCTAssertEqual(signal.ownershipScope, originScope)
        let replacementProfileID = UUID()
        do {
            _ = try await provider.activateSignalOwnership(
                for: replacementProfileID
            )
            XCTFail("replacement activated before origin retirement")
        } catch let error as EnvironmentSignalOwnershipError {
            XCTAssertEqual(error, .activeOwnerNotRetired)
        }
        let drained = try await provider.quiesceSignalOwnership(
            for: originProfileID
        )
        XCTAssertEqual(drained, [])
        try await provider.retireSignalOwnership(for: originProfileID)
        let replacementActivation = try await activateOwner(
            provider,
            profileID: replacementProfileID
        )
        XCTAssertNotEqual(signal.ownershipScope, replacementActivation.scope)
    }

    func testSameWindowSummarySubscriptionRestartsForReplacementOwnership()
        async throws
    {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let startDay = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 30,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let window = try CompetitionActivityWindow(
            calendar: calendar,
            startDay: startDay
        )
        let originTerminated = expectation(
            description: "origin summary subscription terminated"
        )
        let originUpdates = TestAsyncStream<[HKActivitySummary]> {
            originTerminated.fulfill()
        }
        let replacementUpdates = TestAsyncStream<[HKActivitySummary]>()
        let updates = LockedStreamSequence(
            streams: [originUpdates.stream, replacementUpdates.stream]
        )
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: HealthKitCompetitionDependencies(
                isHealthDataAvailable: { true },
                requestAuthorization: { _ in },
                readActivitySummaries: { _ in [] },
                resolveStandMode: { .unknown },
                summaryUpdates: { _ in updates.next() },
                observerUpdates: { AsyncStream { $0.finish() } },
                stopObserverUpdates: {}
            )
        )

        let originProfileID = UUID()
        let originActivation = try await provider.activateSignalOwnership(
            for: originProfileID
        )
        try await provider.commitSignalOwnershipActivation(originActivation)
        let originScope = originActivation.scope
        await provider.synchronizeSummarySubscriptions(to: [window])
        XCTAssertEqual(updates.requestCount, 1)

        let drained = try await provider.quiesceSignalOwnership(
            for: originProfileID
        )
        XCTAssertEqual(drained, [])
        await fulfillment(of: [originTerminated], timeout: 1)
        try await provider.retireSignalOwnership(for: originProfileID)

        let replacementActivation = try await activateOwner(
            provider,
            profileID: UUID()
        )
        let replacementScope = replacementActivation.scope
        await provider.synchronizeSummarySubscriptions(to: [window])
        XCTAssertEqual(updates.requestCount, 2)

        await provider.synchronizeSummarySubscriptions(to: [window])
        XCTAssertEqual(updates.requestCount, 2)

        let signals = await provider.signals()
        originUpdates.yield([])
        replacementUpdates.yield([])
        let signal = try await firstSignal(
            from: signals,
            description: "replacement-owned summary signal"
        )
        XCTAssertEqual(signal.trigger, .summaryUpdate)
        XCTAssertEqual(signal.ownershipScope, replacementScope)
        XCTAssertNotEqual(signal.ownershipScope, originScope)
    }

    func testObserverIngressSnapshotsTriggerBeforeIngressHookAndAsyncConsumption()
        async throws
    {
        let ingressHookEntered = expectation(
            description: "observer ingress hook entered"
        )
        let wakeupReceived = expectation(
            description: "classified observer wakeup received"
        )
        let releaseIngressHook = DispatchSemaphore(value: 0)
        let triggerSource = LockedActivityRefreshTrigger(
            .observerWakeupBackground
        )
        let completionCount = LockedCounter()
        let driver = TestHealthKitObserverUpdateDriver(onStop: {})
        let registry = HealthKitSignalOwnershipRegistry()
        let controller = HealthKitObserverUpdateController(
            driver: driver.driver,
            ownershipRegistry: registry,
            triggerSnapshot: { triggerSource.value },
            didRegisterIngress: {
                ingressHookEntered.fulfill()
                releaseIngressHook.wait()
            }
        )
        let profileID = UUID()
        let activation = try registry.activate(for: profileID)
        try registry.commit(activation)
        let stream = controller.stream()
        let wakeupBox = LockedObserverWakeupBox()
        let reader = Task {
            var iterator = stream.makeAsyncIterator()
            wakeupBox.set(await iterator.next())
            wakeupReceived.fulfill()
        }
        let fireTask = Task.detached {
            driver.fire(at: 0) {
                completionCount.increment()
            }
        }
        await fulfillment(of: [ingressHookEntered], timeout: 1)

        triggerSource.set(.observerWakeupForeground)
        releaseIngressHook.signal()

        await fulfillment(of: [wakeupReceived], timeout: 1)
        await fireTask.value
        let wakeup = try XCTUnwrap(wakeupBox.value)
        XCTAssertEqual(wakeup.trigger, .observerWakeupBackground)
        XCTAssertEqual(completionCount.value, 0)
        wakeup.completion()
        XCTAssertEqual(completionCount.value, 1)

        _ = try registry.beginQuiescence(for: profileID)
        controller.stop()
        try registry.retire(profileID: profileID)
        reader.cancel()
    }

    func testForegroundAndBackgroundObserverWakeupsPreserveTriggersAndCompletionOwnership()
        async throws
    {
        let observerUpdates = TestAsyncStream<HealthKitObserverWakeup>()
        let completionCount = LockedCounter()
        let provider = HealthKitProvider(
            userId: UUID(),
            competitionDependencies: HealthKitCompetitionDependencies(
                isHealthDataAvailable: { true },
                requestAuthorization: { _ in },
                readActivitySummaries: { _ in [] },
                resolveStandMode: { .unknown },
                summaryUpdates: { _ in AsyncStream { $0.finish() } },
                observerUpdates: { observerUpdates.stream },
                stopObserverUpdates: { observerUpdates.finish() }
            )
        )
        let activation = try await activateOwner(provider)
        let stream = await provider.signals()
        let received = expectation(description: "two observer signals received")
        received.expectedFulfillmentCount = 2
        let signalBox = LockedSignalsBox()
        let reader = Task {
            var iterator = stream.makeAsyncIterator()
            for _ in 0..<2 {
                if let signal = await iterator.next() {
                    signalBox.append(signal)
                    received.fulfill()
                }
            }
        }

        observerUpdates.yield(
            HealthKitObserverWakeup(
                trigger: .observerWakeupForeground,
                completion: { completionCount.increment() }
            )
        )
        observerUpdates.yield(
            HealthKitObserverWakeup(
                trigger: .observerWakeupBackground,
                completion: { completionCount.increment() }
            )
        )

        await fulfillment(of: [received], timeout: 1)
        let signals = signalBox.value
        XCTAssertEqual(
            signals.map(\.trigger),
            [.observerWakeupForeground, .observerWakeupBackground]
        )
        XCTAssertTrue(signals.allSatisfy(\.requiresCompletion))
        XCTAssertEqual(completionCount.value, 0)
        for signal in signals {
            let accepted = await provider.completeSignal(signal.id)
            XCTAssertTrue(accepted)
        }
        XCTAssertEqual(completionCount.value, 2)

        _ = try await provider.quiesceSignalOwnership(activation.lease)
        try await provider.retireSignalOwnership(activation.lease)
        reader.cancel()
    }

    func testObserverIngressDrainsOriginEpochBeforeReplacementStarts()
        async throws
    {
        let originIngressEntered = expectation(
            description: "origin observer ingress registered"
        )
        let stopStarted = expectation(
            description: "origin observer queries stopped"
        )
        let stopFinished = expectation(
            description: "origin observer ingress drained"
        )
        let releaseOriginIngress = DispatchSemaphore(value: 0)
        let ingressCount = LockedCounter()
        let originCompletionCount = LockedCounter()
        let lateOriginCompletionCount = LockedCounter()
        let replacementCompletionCount = LockedCounter()
        let driver = TestHealthKitObserverUpdateDriver(
            onStop: { stopStarted.fulfill() }
        )
        let registry = HealthKitSignalOwnershipRegistry()
        let controller = HealthKitObserverUpdateController(
            driver: driver.driver,
            ownershipRegistry: registry,
            triggerSnapshot: { .observerWakeupBackground },
            didRegisterIngress: {
                guard ingressCount.incrementAndGet() == 1 else { return }
                originIngressEntered.fulfill()
                releaseOriginIngress.wait()
            }
        )
        let originProfileID = UUID()
        let originActivation = try registry.activate(for: originProfileID)
        try registry.commit(originActivation)
        let originStream = controller.stream()
        let originSignalReceived = expectation(
            description: "origin observer wakeup received"
        )
        let originWakeup = LockedObserverWakeupBox()
        let originReader = Task {
            var iterator = originStream.makeAsyncIterator()
            originWakeup.set(await iterator.next())
            originSignalReceived.fulfill()
        }
        let originCallback = Task.detached {
            driver.fire(at: 0) {
                originCompletionCount.increment()
            }
        }
        await fulfillment(of: [originIngressEntered], timeout: 1)

        _ = try registry.beginQuiescence(for: originProfileID)
        let stopCompleted = LockedFlag()
        let stopTask = Task.detached {
            controller.stop()
            stopCompleted.setTrue()
            stopFinished.fulfill()
        }
        await fulfillment(of: [stopStarted], timeout: 1)
        XCTAssertFalse(stopCompleted.value)
        do {
            _ = try registry.activate(for: UUID())
            XCTFail("replacement activated before origin ingress drained")
        } catch let error as EnvironmentSignalOwnershipError {
            XCTAssertEqual(error, .activeOwnerNotRetired)
        }

        releaseOriginIngress.signal()
        await fulfillment(
            of: [originSignalReceived, stopFinished],
            timeout: 1
        )
        await originCallback.value
        await stopTask.value
        let capturedOriginWakeup = try XCTUnwrap(originWakeup.value)
        XCTAssertEqual(
            capturedOriginWakeup.ownershipScope,
            originActivation.scope
        )
        XCTAssertEqual(originCompletionCount.value, 0)
        capturedOriginWakeup.completion()
        XCTAssertEqual(originCompletionCount.value, 1)

        try registry.retire(profileID: originProfileID)
        let replacementProfileID = UUID()
        let replacementActivation = try registry.activate(
            for: replacementProfileID
        )
        try registry.commit(replacementActivation)
        let replacementStream = controller.stream()
        let replacementSignalReceived = expectation(
            description: "replacement observer wakeup received"
        )
        let replacementWakeup = LockedObserverWakeupBox()
        let replacementReader = Task {
            var iterator = replacementStream.makeAsyncIterator()
            replacementWakeup.set(await iterator.next())
            replacementSignalReceived.fulfill()
        }
        driver.fire(at: 0) {
            lateOriginCompletionCount.increment()
        }
        driver.fire(at: 1) {
            replacementCompletionCount.increment()
        }
        await fulfillment(of: [replacementSignalReceived], timeout: 1)
        let capturedReplacementWakeup = try XCTUnwrap(
            replacementWakeup.value
        )
        XCTAssertEqual(
            capturedReplacementWakeup.ownershipScope,
            replacementActivation.scope
        )
        XCTAssertEqual(lateOriginCompletionCount.value, 0)
        XCTAssertEqual(replacementCompletionCount.value, 0)
        capturedReplacementWakeup.completion()
        XCTAssertEqual(replacementCompletionCount.value, 1)

        _ = try registry.beginQuiescence(for: replacementProfileID)
        controller.stop()
        try registry.retire(profileID: replacementProfileID)
        originReader.cancel()
        replacementReader.cancel()
    }

    func testBackgroundSignalIDsAreDistinctAcrossProviderStates()
        async throws
    {
        let firstUpdates = TestAsyncStream<HealthKitObserverWakeup>()
        let secondUpdates = TestAsyncStream<HealthKitObserverWakeup>()
        let firstCompletion = LockedFlag()
        let secondCompletion = LockedFlag()
        let firstProvider = HealthKitProvider(
            userId: UUID(
                uuidString: "71000000-0000-4000-8000-000000000001"
            )!,
            competitionDependencies: signalIdentityDependencies(
                observerUpdates: firstUpdates
            )
        )
        let secondProvider = HealthKitProvider(
            userId: UUID(
                uuidString: "72000000-0000-4000-8000-000000000002"
            )!,
            competitionDependencies: signalIdentityDependencies(
                observerUpdates: secondUpdates
            )
        )
        _ = try await activateOwner(firstProvider)
        _ = try await activateOwner(secondProvider)
        let firstReceived = expectation(description: "first provider signal")
        let secondReceived = expectation(description: "second provider signal")
        let firstCapture = LockedSignalBox()
        let secondCapture = LockedSignalBox()
        let firstReader = Task {
            var iterator = await firstProvider.signals()
                .makeAsyncIterator()
            if let signal = await iterator.next() {
                firstCapture.set(signal)
                firstReceived.fulfill()
            }
        }
        let secondReader = Task {
            var iterator = await secondProvider.signals()
                .makeAsyncIterator()
            if let signal = await iterator.next() {
                secondCapture.set(signal)
                secondReceived.fulfill()
            }
        }

        firstUpdates.yield(
            HealthKitObserverWakeup(
                trigger: .observerWakeupBackground
            ) {
                firstCompletion.setTrue()
            }
        )
        secondUpdates.yield(
            HealthKitObserverWakeup(
                trigger: .observerWakeupBackground
            ) {
                secondCompletion.setTrue()
            }
        )
        await fulfillment(of: [firstReceived, secondReceived], timeout: 1)
        let firstSignal = try XCTUnwrap(firstCapture.value)
        let secondSignal = try XCTUnwrap(secondCapture.value)

        XCTAssertEqual(firstSignal.trigger, .observerWakeupBackground)
        XCTAssertEqual(secondSignal.trigger, .observerWakeupBackground)
        XCTAssertNotEqual(firstSignal.id, secondSignal.id)
        XCTAssertFalse(firstCompletion.value)
        XCTAssertFalse(secondCompletion.value)
        await firstProvider.completeSignal(firstSignal.id)
        await secondProvider.completeSignal(secondSignal.id)
        XCTAssertTrue(firstCompletion.value)
        XCTAssertTrue(secondCompletion.value)
        firstReader.cancel()
        secondReader.cancel()
    }

    @discardableResult
    private func activateOwner(
        _ provider: HealthKitProvider,
        profileID: UUID = UUID()
    ) async throws -> EnvironmentSignalOwnershipActivation {
        let activation = try await provider.activateSignalOwnership(
            for: profileID
        )
        try await provider.commitSignalOwnershipActivation(activation)
        return activation
    }

    private func signalIdentityDependencies(
        observerUpdates: TestAsyncStream<HealthKitObserverWakeup>
    ) -> HealthKitCompetitionDependencies {
        HealthKitCompetitionDependencies(
            isHealthDataAvailable: { true },
            requestAuthorization: { _ in },
            readActivitySummaries: { _ in [] },
            resolveStandMode: { .unknown },
            summaryUpdates: { _ in AsyncStream { $0.finish() } },
            observerUpdates: { observerUpdates.stream },
            stopObserverUpdates: { observerUpdates.finish() }
        )
    }

    private func firstSignal(
        from stream: AsyncStream<EnvironmentSignal>,
        description: String
    ) async throws -> EnvironmentSignal {
        let received = expectation(description: description)
        let box = LockedSignalBox()
        let reader = Task {
            var iterator = stream.makeAsyncIterator()
            box.set(await iterator.next())
            received.fulfill()
        }
        await fulfillment(of: [received], timeout: 1)
        reader.cancel()
        _ = await reader.result
        return try XCTUnwrap(box.value)
    }

    private func makeActivitySummary(
        day: CompetitionDay,
        moveValue: Double
    ) throws -> HKActivitySummary {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: day.timeZoneIdentifier)!
        let summary = HKActivitySummary()
        summary.setValue(
            DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                era: day.era,
                year: day.year,
                month: day.month,
                day: day.day
            ),
            forKey: "dateComponents"
        )
        summary.activeEnergyBurned = HKQuantity(
            unit: .kilocalorie(),
            doubleValue: moveValue
        )
        summary.activeEnergyBurnedGoal = HKQuantity(
            unit: .kilocalorie(),
            doubleValue: 500
        )
        summary.appleExerciseTime = HKQuantity(
            unit: .minute(),
            doubleValue: 30
        )
        summary.exerciseTimeGoal = HKQuantity(
            unit: .minute(),
            doubleValue: 30
        )
        summary.appleStandHours = HKQuantity(
            unit: .count(),
            doubleValue: 12
        )
        summary.standHoursGoal = HKQuantity(
            unit: .count(),
            doubleValue: 12
        )
        return summary
    }
}

private final class TestAsyncStream<Element>: @unchecked Sendable {
    let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation

    init(onTermination: (@Sendable () -> Void)? = nil) {
        var continuation: AsyncStream<Element>.Continuation!
        self.stream = AsyncStream {
            continuation = $0
            $0.onTermination = { _ in onTermination?() }
        }
        self.continuation = continuation
    }

    func yield(_ value: Element) {
        continuation.yield(value)
    }

    func finish() {
        continuation.finish()
    }
}

private final class LockedStreamSequence<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private let streams: [AsyncStream<Element>]
    private var nextIndex = 0

    init(streams: [AsyncStream<Element>]) {
        self.streams = streams
    }

    var requestCount: Int {
        lock.withLock { nextIndex }
    }

    func next() -> AsyncStream<Element> {
        lock.withLock {
            guard nextIndex < streams.count else {
                return AsyncStream { $0.finish() }
            }
            defer { nextIndex += 1 }
            return streams[nextIndex]
        }
    }
}

private final class LockedWindowCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CompetitionActivityWindow: Int] = [:]

    func increment(_ window: CompetitionActivityWindow) {
        lock.withLock { storage[window, default: 0] += 1 }
    }

    func count(_ window: CompetitionActivityWindow) -> Int {
        lock.withLock { storage[window, default: 0] }
    }
}

private final class LockedWindowStreams: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [
        CompetitionActivityWindow: [TestAsyncStream<[HKActivitySummary]>]
    ] = [:]

    func makeStream(
        for window: CompetitionActivityWindow
    ) -> AsyncStream<[HKActivitySummary]> {
        lock.withLock {
            let stream = TestAsyncStream<[HKActivitySummary]>()
            storage[window, default: []].append(stream)
            return stream.stream
        }
    }

    func finish(_ window: CompetitionActivityWindow) {
        lock.withLock { storage[window]?.last }.map { $0.finish() }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }

    func incrementAndGet() -> Int {
        lock.withLock {
            storage += 1
            return storage
        }
    }
}

private final class LockedObserverWakeupBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: HealthKitObserverWakeup?

    var value: HealthKitObserverWakeup? {
        lock.withLock { storage }
    }

    func set(_ value: HealthKitObserverWakeup?) {
        lock.withLock { storage = value }
    }
}

private final class LockedActivityRefreshTrigger: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: ActivityRefreshTrigger

    init(_ value: ActivityRefreshTrigger) {
        self.storage = value
    }

    var value: ActivityRefreshTrigger {
        lock.withLock { storage }
    }

    func set(_ value: ActivityRefreshTrigger) {
        lock.withLock { storage = value }
    }
}

private final class TestHealthKitObserverUpdateDriver: @unchecked Sendable {
    private let lock = NSLock()
    private let onStop: @Sendable () -> Void
    private var handlers: [HealthKitObserverUpdateDriver.Handler] = []
    private var stopCount = 0

    init(onStop: @escaping @Sendable () -> Void) {
        self.onStop = onStop
    }

    var driver: HealthKitObserverUpdateDriver {
        HealthKitObserverUpdateDriver { [weak self] handler in
            guard let self else { return [] }
            self.lock.withLock { self.handlers.append(handler) }
            return [{ [weak self] in
                guard let self else { return }
                let isFirst = self.lock.withLock {
                    self.stopCount += 1
                    return self.stopCount == 1
                }
                if isFirst { self.onStop() }
            }]
        }
    }

    func fire(
        at index: Int,
        completion: @escaping () -> Void
    ) {
        let handler = lock.withLock { handlers[index] }
        handler(completion)
    }
}

private actor BackgroundDeliveryOverlapGate {
    private let targetIdentifier: String
    private var attemptCounts: [String: Int] = [:]
    private var firstAttemptContinuation: CheckedContinuation<Void, Never>?
    private var firstAttemptWaiters: [CheckedContinuation<Void, Never>] = []
    private var authorizationRequested = false
    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []

    init(targetIdentifier: String) {
        self.targetIdentifier = targetIdentifier
    }

    func enable(_ identifier: String) async throws {
        attemptCounts[identifier, default: 0] += 1
        guard identifier == targetIdentifier,
              attemptCounts[identifier] == 1
        else {
            return
        }
        for waiter in firstAttemptWaiters { waiter.resume() }
        firstAttemptWaiters.removeAll()
        await withCheckedContinuation { continuation in
            firstAttemptContinuation = continuation
        }
        throw TestProviderError.unavailable
    }

    func waitUntilFirstAttemptIsBlocked() async {
        if firstAttemptContinuation != nil { return }
        await withCheckedContinuation { continuation in
            firstAttemptWaiters.append(continuation)
        }
    }

    func releaseFirstAttempt() {
        firstAttemptContinuation?.resume()
        firstAttemptContinuation = nil
    }

    func authorizationWasRequested() {
        authorizationRequested = true
        for waiter in authorizationWaiters { waiter.resume() }
        authorizationWaiters.removeAll()
    }

    func waitUntilAuthorizationWasRequested() async {
        if authorizationRequested { return }
        await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
        }
    }

    func attemptCount(for identifier: String) -> Int {
        attemptCounts[identifier, default: 0]
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func setTrue() {
        lock.withLock { storage = true }
    }
}

private final class LockedObjectTypeSet: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Set<HKObjectType>()

    var value: Set<HKObjectType> {
        lock.withLock { storage }
    }

    func set(_ value: Set<HKObjectType>) {
        lock.withLock { storage = value }
    }
}

private enum TestProviderError: Error {
    case unavailable
}

private final class LockedSignalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: EnvironmentSignal?

    var value: EnvironmentSignal? {
        lock.withLock { storage }
    }

    func set(_ value: EnvironmentSignal?) {
        lock.withLock { storage = value }
    }
}

private final class LockedSignalsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [EnvironmentSignal] = []

    var value: [EnvironmentSignal] {
        lock.withLock { storage }
    }

    func append(_ signal: EnvironmentSignal) {
        lock.withLock { storage.append(signal) }
    }
}

private final class LockedStringCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Int] = [:]

    @discardableResult
    func increment(_ key: String) -> Int {
        lock.withLock {
            storage[key, default: 0] += 1
            return storage[key, default: 0]
        }
    }

    func count(for key: String) -> Int {
        lock.withLock { storage[key, default: 0] }
    }
}
