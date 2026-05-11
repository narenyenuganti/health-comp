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

struct ActivityRingSummary: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let userId: UUID
    let date: String
    let moveValue: Double
    let moveGoal: Double
    let exerciseValue: Double
    let exerciseGoal: Double
    let standValue: Double
    let standGoal: Double
    let source: DataSource
    let syncedAt: Date

    var movePercent: Double {
        percent(value: moveValue, goal: moveGoal)
    }

    var exercisePercent: Double {
        percent(value: exerciseValue, goal: exerciseGoal)
    }

    var standPercent: Double {
        percent(value: standValue, goal: standGoal)
    }

    var appleActivityScore: AppleActivityScore {
        AppleActivityScore(
            movePercent: movePercent,
            exercisePercent: exercisePercent,
            standPercent: standPercent
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case date
        case moveValue = "move_value"
        case moveGoal = "move_goal"
        case exerciseValue = "exercise_value"
        case exerciseGoal = "exercise_goal"
        case standValue = "stand_value"
        case standGoal = "stand_goal"
        case source
        case syncedAt = "synced_at"
    }

    private func percent(value: Double, goal: Double) -> Double {
        guard goal > 0 else { return 0 }
        return (value / goal) * 100
    }
}
