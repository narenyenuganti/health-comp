import Foundation

enum MetricType: String, Codable, Equatable, Sendable, CaseIterable {
    case activeCalories = "active_calories"
    case exerciseMinutes = "exercise_minutes"
    case standHours = "stand_hours"
    case steps
    case sleepScore = "sleep_score"
    case distance
}

enum DataSource: String, Codable, Equatable, Sendable {
    case healthkit
    case fitbit
    case garmin
    case manual
}

struct HealthMetric: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let userId: UUID
    let metricType: MetricType
    let value: Double
    let date: String
    let source: DataSource
    let syncedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case metricType = "metric_type"
        case value
        case date
        case source
        case syncedAt = "synced_at"
    }
}
