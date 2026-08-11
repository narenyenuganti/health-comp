import CompetitionCore
import XCTest
@testable import HealthComp

final class CompetitionEnvironmentClientTests: XCTestCase {
    func testProductionDelayConversionSaturatesBeforeUInt64Conversion() {
        XCTAssertEqual(
            CompetitionEnvironmentClient.nanosecondsForDelay(-1),
            0
        )
        XCTAssertEqual(
            CompetitionEnvironmentClient.nanosecondsForDelay(1.25),
            1_250_000_000
        )
        XCTAssertEqual(
            CompetitionEnvironmentClient.nanosecondsForDelay(
                Date.distantFuture.timeIntervalSinceReferenceDate
            ),
            UInt64.max
        )
        XCTAssertEqual(
            CompetitionEnvironmentClient.nanosecondsForDelay(
                .greatestFiniteMagnitude
            ),
            UInt64.max
        )
    }

    func testProductionEpochIsStableWithinBootAndChangesAfterClockUncertainty() {
        let first = CompetitionEnvironmentClient.productionEpochID(
            wallDate: Date(timeIntervalSinceReferenceDate: 10_100.25),
            systemUptime: 100.25
        )
        let relaunched = CompetitionEnvironmentClient.productionEpochID(
            wallDate: Date(timeIntervalSinceReferenceDate: 10_160.25),
            systemUptime: 160.25
        )
        let adjustedClock = CompetitionEnvironmentClient.productionEpochID(
            wallDate: Date(timeIntervalSinceReferenceDate: 10_162.25),
            systemUptime: 160.25
        )

        XCTAssertEqual(first, relaunched)
        XCTAssertNotEqual(first, adjustedClock)
    }

    func testAcceleratedFactoryAdvancesClockAndVisibleActivityAsOneEnvironment() async throws {
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let start = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 3,
            day: 8,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let window = try CompetitionActivityWindow(
            calendar: calendar,
            startDay: start
        )
        let days = try calendar.sevenDayWindow(startingOn: start)
        let initialDate = try calendar.startOfDay(days[0])
        let lateDate = try calendar.startOfDay(days[6]).addingTimeInterval(60)
        let dayOne = try snapshot(moveValue: 200)
        let daySeven = try snapshot(moveValue: 700)
        let fixture = try ActivityFixture(
            initialInstant: EnvironmentInstant(
                wallDate: initialDate,
                monotonic: MonotonicInstant(
                    epochID: "fixture-epoch",
                    nanoseconds: 10
                )
            ),
            timeZoneIdentifier: "Pacific/Kiritimati",
            initialDays: [
                .snapshot(day: days[0], snapshot: dayOne),
            ],
            changes: [
                try FixtureActivityChange(
                    at: lateDate,
                    updates: [
                        .snapshot(day: days[6], snapshot: daySeven),
                    ],
                    triggers: []
                ),
            ]
        )
        let environment = CompetitionEnvironmentClient.accelerated(
            fixture: fixture
        )

        XCTAssertEqual(environment.kind, .accelerated)
        let context = await environment.context()
        XCTAssertEqual(context.instant.wallDate, initialDate)
        XCTAssertEqual(context.timeZoneIdentifier, "Pacific/Kiritimati")
        let before = await environment.instant()
        let beforeRead = try await environment.read(window)
        XCTAssertEqual(before.wallDate, initialDate)
        XCTAssertEqual(beforeRead.days.count, 7)
        XCTAssertEqual(beforeRead.days.map(\.day), days)
        XCTAssertEqual(beforeRead.days[0], .snapshot(day: days[0], snapshot: dayOne))
        XCTAssertEqual(beforeRead.days[6], .missing(day: days[6]))

        try await environment.advanceFixture(to: lateDate)

        let after = await environment.instant()
        let afterRead = try await environment.read(window)
        XCTAssertEqual(after.wallDate, lateDate)
        XCTAssertGreaterThan(
            after.monotonic.nanoseconds,
            before.monotonic.nanoseconds
        )
        XCTAssertEqual(
            afterRead.days[6],
            .snapshot(day: days[6], snapshot: daySeven)
        )
    }

    func testAcceleratedEnvironmentForwardsSetDrivenSummarySubscriptionSynchronization() async throws {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let start = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 1,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let window = try CompetitionActivityWindow(
            calendar: calendar,
            startDay: start
        )
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: try calendar.startOfDay(start),
                    monotonic: MonotonicInstant(
                        epochID: "environment-subscriptions",
                        nanoseconds: 0
                    )
                ),
                initialDays: [],
                changes: []
            )
        )
        let environment = CompetitionEnvironmentClient.accelerated(
            source: source
        )

        await environment.synchronizeSummarySubscriptions(to: [window])
        await environment.synchronizeSummarySubscriptions(to: [window])
        await environment.synchronizeSummarySubscriptions(to: [])

        let synchronizations = await source.summarySubscriptionSynchronizations()
        XCTAssertEqual(
            synchronizations,
            [
                .changed(to: [window]),
                .noOp(desired: [window]),
                .changed(to: []),
            ]
        )
    }

    func testCompetitionActivityWindowUsesStoredZoneAndAlwaysContainsSevenOrderedDays() throws {
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

        XCTAssertEqual(
            window.days,
            try calendar.sevenDayWindow(startingOn: start)
        )
        XCTAssertEqual(window.days.count, 7)
        XCTAssertTrue(
            window.days.allSatisfy {
                $0.timeZoneIdentifier == "Pacific/Kiritimati"
            }
        )
    }

    private func snapshot(moveValue: Double) throws -> ActivitySnapshot {
        ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(value: moveValue, goal: 500),
            exercise: try ActivityRingReading(value: 30, goal: 30),
            standOrRoll: try ActivityRingReading(value: 12, goal: 12),
            isPaused: false
        )
    }
}
