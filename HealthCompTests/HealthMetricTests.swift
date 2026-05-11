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

    func testActivityRingSummaryComputesRingPercentages() {
        let summary = ActivityRingSummary(
            id: UUID(),
            userId: UUID(),
            date: "2026-05-11",
            moveValue: 750,
            moveGoal: 500,
            exerciseValue: 45,
            exerciseGoal: 30,
            standValue: 18,
            standGoal: 12,
            source: .healthkit,
            syncedAt: Date()
        )

        XCTAssertEqual(summary.movePercent, 150)
        XCTAssertEqual(summary.exercisePercent, 150)
        XCTAssertEqual(summary.standPercent, 150)
    }

    func testActivityRingSummaryTreatsZeroGoalsAsZeroPercent() {
        let summary = ActivityRingSummary(
            id: UUID(),
            userId: UUID(),
            date: "2026-05-11",
            moveValue: 750,
            moveGoal: 0,
            exerciseValue: 45,
            exerciseGoal: 0,
            standValue: 18,
            standGoal: 0,
            source: .healthkit,
            syncedAt: Date()
        )

        XCTAssertEqual(summary.movePercent, 0)
        XCTAssertEqual(summary.exercisePercent, 0)
        XCTAssertEqual(summary.standPercent, 0)
    }

    func testActivityRingSummaryCreatesAppleActivityScore() {
        let summary = ActivityRingSummary(
            id: UUID(),
            userId: UUID(),
            date: "2026-05-11",
            moveValue: 500,
            moveGoal: 500,
            exerciseValue: 30,
            exerciseGoal: 30,
            standValue: 12,
            standGoal: 12,
            source: .healthkit,
            syncedAt: Date()
        )

        XCTAssertEqual(summary.appleActivityScore.points, 300)
    }
}
