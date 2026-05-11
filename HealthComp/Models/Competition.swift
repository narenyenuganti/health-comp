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

    var displayModeName: String {
        modeName
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    func daysRemaining(asOf date: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let endDate else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let parsedEndDate = formatter.date(from: endDate) else { return nil }

        let today = calendar.startOfDay(for: date)
        let end = calendar.startOfDay(for: parsedEndDate)
        return calendar.dateComponents([.day], from: today, to: end).day
    }

    func isEndingSoon(asOf date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let daysRemaining = daysRemaining(asOf: date, calendar: calendar) else { return false }
        return daysRemaining >= 0 && daysRemaining <= 1
    }
}

struct CompetitionDateWindow: Equatable, Sendable {
    let startDate: String
    let endDate: String

    init(starting start: Date, durationDays: Int, calendar: Calendar = .current) {
        let clampedDuration = max(1, durationDays)
        let inclusiveEnd = calendar.date(
            byAdding: .day,
            value: clampedDuration - 1,
            to: start
        ) ?? start
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        self.startDate = formatter.string(from: start)
        self.endDate = formatter.string(from: inclusiveEnd)
    }
}

enum ScoringFormulaKind: String, Codable, Equatable, Sendable {
    case weighted
    case appleActivity = "apple_activity"
}

struct ScoringFormula: Codable, Equatable, Sendable {
    let kind: ScoringFormulaKind
    let metrics: [ScoringMetric]
    let dailyCap: Int?

    enum CodingKeys: String, CodingKey {
        case kind
        case metrics
        case dailyCap = "daily_cap"
    }

    init(kind: ScoringFormulaKind = .weighted, metrics: [ScoringMetric], dailyCap: Int?) {
        self.kind = kind
        self.metrics = metrics
        self.dailyCap = dailyCap
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decodeIfPresent(ScoringFormulaKind.self, forKey: .kind) ?? .weighted
        self.metrics = try container.decode([ScoringMetric].self, forKey: .metrics)
        self.dailyCap = try container.decodeIfPresent(Int.self, forKey: .dailyCap)
    }
}

struct ScoringMetric: Codable, Equatable, Sendable {
    let type: MetricType
    let weight: Double
}

struct AppleActivityScore: Equatable, Sendable {
    static let dailyCap = 600
    static let durationDays = 7
    static let competitionCap = 4_200.0

    let movePercent: Double
    let exercisePercent: Double
    let standPercent: Double

    var uncappedPoints: Double {
        movePercent + exercisePercent + standPercent
    }

    var points: Double {
        min(Double(Self.dailyCap), max(0, uncappedPoints))
    }

    static func totalPoints(for days: [AppleActivityScore]) -> Double {
        min(
            competitionCap,
            days.prefix(durationDays).reduce(0) { total, day in
                total + day.points
            }
        )
    }
}

enum CompetitionStanding: Equatable, Sendable {
    case tied
    case ahead(points: Double)
    case behind(points: Double)

    static func compare(currentUserPoints: Double, opponentPoints: Double) -> CompetitionStanding {
        let difference = currentUserPoints - opponentPoints
        guard abs(difference) > 0.0001 else { return .tied }
        return difference > 0 ? .ahead(points: difference) : .behind(points: abs(difference))
    }
}

enum CompetitionFinalResult: Equatable, Sendable {
    case won
    case lost
    case tied
}

struct CompetitionDayScore: Equatable, Identifiable, Sendable {
    var id: String { date }

    let date: String
    let currentUserPoints: Double
    let opponentPoints: Double
    let standing: CompetitionStanding
}

struct CompetitionScoreSummary: Equatable, Sendable {
    let competition: Competition
    let currentUserId: UUID
    let opponentUserId: UUID
    let dailyScores: [DailyScore]

    var currentUserTotal: Double {
        total(for: currentUserId)
    }

    var opponentTotal: Double {
        total(for: opponentUserId)
    }

    var totalsByUser: [UUID: Double] {
        Set(dailyScores.map(\.userId)).reduce(into: [:]) { totals, userId in
            totals[userId] = total(for: userId)
        }
    }

    var standing: CompetitionStanding {
        CompetitionStanding.compare(
            currentUserPoints: currentUserTotal,
            opponentPoints: opponentTotal
        )
    }

    var finalResult: CompetitionFinalResult? {
        guard competition.status == .completed else { return nil }
        switch standing {
        case .tied:
            return .tied
        case .ahead:
            return .won
        case .behind:
            return .lost
        }
    }

    var dailyHistory: [CompetitionDayScore] {
        let sortedDates = Set(dailyScores.map(\.date)).sorted()
        let dates = competition.scoringFormula.kind == .appleActivity
            ? Array(sortedDates.prefix(AppleActivityScore.durationDays))
            : sortedDates
        return dates.map { date in
            let currentPoints = dailyPoints(for: currentUserId, on: date)
            let opponentPoints = dailyPoints(for: opponentUserId, on: date)
            return CompetitionDayScore(
                date: date,
                currentUserPoints: currentPoints,
                opponentPoints: opponentPoints,
                standing: CompetitionStanding.compare(
                    currentUserPoints: currentPoints,
                    opponentPoints: opponentPoints
                )
            )
        }
    }

    private func total(for userId: UUID) -> Double {
        let userScores = dailyScores
            .filter { $0.userId == userId }
            .sorted { $0.date < $1.date }

        if competition.scoringFormula.kind == .appleActivity {
            let total = userScores
                .prefix(AppleActivityScore.durationDays)
                .reduce(0.0) { total, score in
                    total + min(Double(AppleActivityScore.dailyCap), max(0, score.totalPoints))
                }
            return min(AppleActivityScore.competitionCap, total)
        }

        return userScores.reduce(0.0) { $0 + $1.totalPoints }
    }

    private func dailyPoints(for userId: UUID, on date: String) -> Double {
        let points = dailyScores
            .filter { $0.userId == userId && $0.date == date }
            .reduce(0.0) { $0 + $1.totalPoints }
        if competition.scoringFormula.kind == .appleActivity {
            return min(Double(AppleActivityScore.dailyCap), max(0, points))
        }
        return points
    }
}

enum CompetitionAlertKind: Equatable, Sendable {
    case inviteReceived(challengerName: String)
    case inviteAccepted(opponentName: String)
    case inviteDeclined(opponentName: String)
    case competitionStarted
    case dailyProgress(points: Double, standing: CompetitionStanding)
    case standingChanged(CompetitionStanding)
    case endingSoon(daysRemaining: Int)
    case competitionCompleted(CompetitionFinalResult)
}

struct CompetitionAlert: Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let body: String

    init(id: UUID = UUID(), kind: CompetitionAlertKind, modeName: String) {
        self.id = id
        switch kind {
        case .inviteReceived(let challengerName):
            self.title = "Competition Invite"
            self.body = "\(challengerName) challenged you to \(modeName)."
        case .inviteAccepted(let opponentName):
            self.title = "Challenge Accepted"
            self.body = "\(opponentName) accepted your \(modeName) challenge."
        case .inviteDeclined(let opponentName):
            self.title = "Challenge Declined"
            self.body = "\(opponentName) declined your \(modeName) challenge."
        case .competitionStarted:
            self.title = "Competition Started"
            self.body = "\(modeName) has started."
        case .dailyProgress(let points, let standing):
            self.title = "Daily Progress"
            self.body = "You scored \(Self.format(points)) points today and are \(Self.standingText(standing))."
        case .standingChanged(let standing):
            self.title = "Competition Update"
            self.body = "You are now \(Self.standingText(standing))."
        case .endingSoon(let daysRemaining):
            self.title = "Competition Ending Soon"
            self.body = "\(modeName) ends in \(daysRemaining) day\(daysRemaining == 1 ? "" : "s")."
        case .competitionCompleted(let result):
            self.title = "Competition Complete"
            self.body = "\(modeName) is complete. You \(Self.finalResultText(result))."
        }
    }

    private static func standingText(_ standing: CompetitionStanding) -> String {
        switch standing {
        case .tied:
            return "tied"
        case .ahead(let points):
            return "ahead by \(format(points))"
        case .behind(let points):
            return "behind by \(format(points))"
        }
    }

    private static func finalResultText(_ result: CompetitionFinalResult) -> String {
        switch result {
        case .won:
            return "won"
        case .lost:
            return "lost"
        case .tied:
            return "tied"
        }
    }

    private static func format(_ points: Double) -> String {
        points.formatted(.number.precision(.fractionLength(0)))
    }
}

// MARK: - Presets

extension ScoringFormula {
    static let appleActivity = ScoringFormula(
        kind: .appleActivity,
        metrics: [
            ScoringMetric(type: .activeCalories, weight: 1.0),
            ScoringMetric(type: .exerciseMinutes, weight: 1.0),
            ScoringMetric(type: .standHours, weight: 1.0),
        ],
        dailyCap: AppleActivityScore.dailyCap
    )

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

    static let appleParityModes: [(name: String, formula: ScoringFormula)] = [
        ("Apple Activity", .appleActivity),
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
