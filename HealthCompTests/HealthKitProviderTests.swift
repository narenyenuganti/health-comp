import XCTest
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
}
