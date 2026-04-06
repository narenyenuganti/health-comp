import Foundation

enum CompetitionType: String, Codable, Equatable, Sendable {
    case oneVOne = "one_v_one"
    case group
    case team
}

enum CompetitionStatus: String, Codable, Equatable, Sendable {
    case pending
    case active
    case completed
    case cancelled
}

struct Competition: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let type: CompetitionType
    let modeName: String
    let scoringFormula: ScoringFormula
    var status: CompetitionStatus
    let startDate: String?
    let endDate: String?
    let createdBy: UUID
    let handicapEnabled: Bool
    let stakesText: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, type, status
        case modeName = "mode_name"
        case scoringFormula = "scoring_formula"
        case startDate = "start_date"
        case endDate = "end_date"
        case createdBy = "created_by"
        case handicapEnabled = "handicap_enabled"
        case stakesText = "stakes_text"
        case createdAt = "created_at"
    }
}

struct ScoringFormula: Codable, Equatable, Sendable {
    let metrics: [ScoringMetric]
    let dailyCap: Int?

    enum CodingKeys: String, CodingKey {
        case metrics
        case dailyCap = "daily_cap"
    }
}

struct ScoringMetric: Codable, Equatable, Sendable {
    let type: MetricType
    let weight: Double
}

// MARK: - Presets

extension ScoringFormula {
    static let activeLiving = ScoringFormula(
        metrics: [
            ScoringMetric(type: .activeCalories, weight: 0.4),
            ScoringMetric(type: .exerciseMinutes, weight: 0.35),
            ScoringMetric(type: .standHours, weight: 0.25),
        ],
        dailyCap: 600
    )

    static let totalWellness = ScoringFormula(
        metrics: [
            ScoringMetric(type: .activeCalories, weight: 0.25),
            ScoringMetric(type: .exerciseMinutes, weight: 0.25),
            ScoringMetric(type: .standHours, weight: 0.15),
            ScoringMetric(type: .sleepScore, weight: 0.2),
            ScoringMetric(type: .steps, weight: 0.15),
        ],
        dailyCap: 600
    )

    static let sleepChallenge = ScoringFormula(
        metrics: [
            ScoringMetric(type: .sleepScore, weight: 0.7),
            ScoringMetric(type: .steps, weight: 0.15),
            ScoringMetric(type: .exerciseMinutes, weight: 0.15),
        ],
        dailyCap: 600
    )

    static let stepBattle = ScoringFormula(
        metrics: [
            ScoringMetric(type: .steps, weight: 1.0),
        ],
        dailyCap: 600
    )

    static let allPresets: [(name: String, formula: ScoringFormula)] = [
        ("Active Living", .activeLiving),
        ("Total Wellness", .totalWellness),
        ("Sleep Challenge", .sleepChallenge),
        ("Step Battle", .stepBattle),
    ]
}

// MARK: - Participant

enum ParticipantRole: String, Codable, Equatable, Sendable {
    case challenger
    case opponent
    case member
}

enum ParticipantStatus: String, Codable, Equatable, Sendable {
    case invited
    case accepted
    case declined
}

struct CompetitionParticipant: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let competitionId: UUID
    let userId: UUID
    let teamId: UUID?
    let role: ParticipantRole
    var status: ParticipantStatus
    let goalSnapshot: [String: Double]?
    let handicapMult: Double
    let joinedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, role, status
        case competitionId = "competition_id"
        case userId = "user_id"
        case teamId = "team_id"
        case goalSnapshot = "goal_snapshot"
        case handicapMult = "handicap_mult"
        case joinedAt = "joined_at"
    }
}

// MARK: - Daily Score

struct DailyScore: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let competitionId: UUID
    let userId: UUID
    let date: String
    let metricScores: [String: Double]
    let totalPoints: Double
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, date
        case competitionId = "competition_id"
        case userId = "user_id"
        case metricScores = "metric_scores"
        case totalPoints = "total_points"
        case createdAt = "created_at"
    }
}
