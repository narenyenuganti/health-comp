import XCTest
@testable import HealthComp

final class HealthMetricTests: XCTestCase {

    func testMetricTypeRawValues() {
        XCTAssertEqual(MetricType.activeCalories.rawValue, "active_calories")
        XCTAssertEqual(MetricType.exerciseMinutes.rawValue, "exercise_minutes")
        XCTAssertEqual(MetricType.standHours.rawValue, "stand_hours")
        XCTAssertEqual(MetricType.steps.rawValue, "steps")
        XCTAssertEqual(MetricType.sleepScore.rawValue, "sleep_score")
        XCTAssertEqual(MetricType.distance.rawValue, "distance")
    }

    func testDataSourceRawValues() {
        XCTAssertEqual(DataSource.healthkit.rawValue, "healthkit")
        XCTAssertEqual(DataSource.fitbit.rawValue, "fitbit")
        XCTAssertEqual(DataSource.garmin.rawValue, "garmin")
        XCTAssertEqual(DataSource.manual.rawValue, "manual")
    }

    func testHealthMetricDecodesFromSupabase() throws {
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "user_id": "660e8400-e29b-41d4-a716-446655440000",
            "metric_type": "active_calories",
            "value": 523.5,
            "date": "2026-03-31",
            "source": "healthkit",
            "synced_at": "2026-03-31T12:00:00Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metric = try decoder.decode(HealthMetric.self, from: json)

        XCTAssertEqual(metric.metricType, .activeCalories)
        XCTAssertEqual(metric.value, 523.5)
        XCTAssertEqual(metric.source, .healthkit)
    }

    func testHealthMetricEncodesToSupabase() throws {
        let metric = HealthMetric(
            id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
            userId: UUID(uuidString: "660e8400-e29b-41d4-a716-446655440000")!,
            metricType: .steps,
            value: 8500,
            date: "2026-03-31",
            source: .healthkit,
            syncedAt: Date(timeIntervalSince1970: 0)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metric)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["metric_type"] as? String, "steps")
        XCTAssertEqual(dict["value"] as? Double, 8500)
        XCTAssertEqual(dict["source"] as? String, "healthkit")
        XCTAssertEqual(dict["date"] as? String, "2026-03-31")
    }

    func testAllMetricTypesExist() {
        let allTypes: [MetricType] = [
            .activeCalories, .exerciseMinutes, .standHours,
            .steps, .sleepScore, .distance
        ]
        XCTAssertEqual(allTypes.count, 6)
    }
}
