import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct HealthSyncClient: Sendable {
    var requestAuthorization: @Sendable () async throws -> Void
    var authorizationStatus: @Sendable () -> AuthorizationStatus = { .notDetermined }
    var fetchToday: @Sendable (_ types: [MetricType]) async throws -> [HealthMetric]
    var fetchRange: @Sendable (_ range: DateRange, _ types: [MetricType]) async throws -> [HealthMetric]
    var uploadMetrics: @Sendable (_ metrics: [HealthMetric]) async throws -> Void
}

extension HealthSyncClient: TestDependencyKey {
    static let testValue = HealthSyncClient()
}

extension DependencyValues {
    var healthSyncClient: HealthSyncClient {
        get { self[HealthSyncClient.self] }
        set { self[HealthSyncClient.self] = newValue }
    }
}

// MARK: - Live Implementation

import Supabase

extension HealthSyncClient: DependencyKey {
    static let liveValue: HealthSyncClient = {
        let supabase = SupabaseService.shared

        return HealthSyncClient(
            requestAuthorization: {
                // Will be configured per-user at runtime
            },
            authorizationStatus: {
                .notDetermined
            },
            fetchToday: { types in
                // Will be configured per-user at runtime
                return []
            },
            fetchRange: { range, types in
                return []
            },
            uploadMetrics: { metrics in
                guard !metrics.isEmpty else { return }
                try await supabase
                    .from("health_metrics")
                    .upsert(metrics, onConflict: "user_id,metric_type,date,source")
                    .execute()
            }
        )
    }()
}
