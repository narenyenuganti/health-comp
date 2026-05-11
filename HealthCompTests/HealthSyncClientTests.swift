import XCTest
@testable import HealthComp

final class HealthSyncClientTests: XCTestCase {

    func testFetchTodayReturnsMetrics() async throws {
        var fetchedTypes: [MetricType]?

        let client = HealthSyncClient(
            requestAuthorization: {},
            authorizationStatus: { .authorized },
            fetchToday: { types in
                fetchedTypes = types
                return [
                    HealthMetric(
                        id: UUID(),
                        userId: UUID(),
                        metricType: .steps,
                        value: 8500,
                        date: "2026-03-31",
                        source: .healthkit,
                        syncedAt: Date()
                    )
                ]
            },
            fetchRange: { _, _ in [] },
            fetchActivityRingSummaries: { _ in [] },
            uploadMetrics: { _ in },
            uploadActivityRingSummaries: { _ in }
        )

        let metrics = try await client.fetchToday([.steps])
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics.first?.metricType, .steps)
        XCTAssertEqual(fetchedTypes, [.steps])
    }

    func testUploadMetricsCalled() async throws {
        var uploadedMetrics: [HealthMetric]?

        let client = HealthSyncClient(
            requestAuthorization: {},
            authorizationStatus: { .authorized },
            fetchToday: { _ in [] },
            fetchRange: { _, _ in [] },
            fetchActivityRingSummaries: { _ in [] },
            uploadMetrics: { metrics in
                uploadedMetrics = metrics
            },
            uploadActivityRingSummaries: { _ in }
        )

        let metric = HealthMetric(
            id: UUID(),
            userId: UUID(),
            metricType: .activeCalories,
            value: 450,
            date: "2026-03-31",
            source: .healthkit,
            syncedAt: Date()
        )

        try await client.uploadMetrics([metric])
        XCTAssertEqual(uploadedMetrics?.count, 1)
        XCTAssertEqual(uploadedMetrics?.first?.metricType, .activeCalories)
    }

    func testUploadActivityRingSummariesCalled() async throws {
        var uploadedSummaries: [ActivityRingSummary]?

        let client = HealthSyncClient(
            requestAuthorization: {},
            authorizationStatus: { .authorized },
            fetchToday: { _ in [] },
            fetchRange: { _, _ in [] },
            fetchActivityRingSummaries: { _ in [] },
            uploadMetrics: { _ in },
            uploadActivityRingSummaries: { summaries in
                uploadedSummaries = summaries
            }
        )

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

        try await client.uploadActivityRingSummaries([summary])
        XCTAssertEqual(uploadedSummaries?.count, 1)
        XCTAssertEqual(uploadedSummaries?.first?.appleActivityScore.points, 300)
    }
}
