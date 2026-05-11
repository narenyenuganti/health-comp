import XCTest
import HealthKit
@testable import HealthComp

final class HealthKitProviderTests: XCTestCase {

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
        XCTAssertEqual(summary.appleActivityScore.points, 450)
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
        XCTAssertEqual(summary.appleActivityScore.points, 400)
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
}
