import XCTest
@testable import HealthComp

final class CompetitionTests: XCTestCase {

    func testScoringFormulaPresets() {
        let al = ScoringFormula.activeLiving
        XCTAssertEqual(al.metrics.count, 3)
        XCTAssertEqual(al.dailyCap, 600)

        let tw = ScoringFormula.totalWellness
        XCTAssertEqual(tw.metrics.count, 5)

        let sc = ScoringFormula.sleepChallenge
        XCTAssertEqual(sc.metrics.first?.type, .sleepScore)
        XCTAssertEqual(sc.metrics.first?.weight, 0.7)

        let sb = ScoringFormula.stepBattle
        XCTAssertEqual(sb.metrics.count, 1)
        XCTAssertEqual(sb.metrics.first?.type, .steps)
    }

    func testAppleActivityPresetIsSeparateFromHealthCompWeightedModes() {
        let apple = ScoringFormula.appleActivity

        XCTAssertEqual(apple.kind, .appleActivity)
        XCTAssertEqual(apple.metrics.count, 3)
        XCTAssertEqual(apple.dailyCap, AppleActivityScore.dailyCap)
        XCTAssertNotEqual(apple, .activeLiving)
        XCTAssertFalse(ScoringFormula.allPresets.contains { $0.name == "Apple Activity" })
        XCTAssertTrue(ScoringFormula.appleParityModes.contains { $0.name == "Apple Activity" })
    }

    func testLegacyScoringFormulaDecodesAsWeightedKind() throws {
        let json = """
        {
            "metrics": [
                {"type": "active_calories", "weight": 0.4},
                {"type": "exercise_minutes", "weight": 0.35},
                {"type": "stand_hours", "weight": 0.25}
            ],
            "daily_cap": 600
        }
        """.data(using: .utf8)!

        let formula = try JSONDecoder().decode(ScoringFormula.self, from: json)
        XCTAssertEqual(formula.kind, .weighted)
    }

    func testAppleActivityScoresRingPercentagesAdditively() {
        let score = AppleActivityScore(
            movePercent: 100,
            exercisePercent: 100,
            standPercent: 100
        )

        XCTAssertEqual(score.uncappedPoints, 300)
        XCTAssertEqual(score.points, 300)
    }

    func testAppleActivityCapsDailyScoreAtSixHundredPoints() {
        let score = AppleActivityScore(
            movePercent: 250,
            exercisePercent: 220,
            standPercent: 200
        )

        XCTAssertEqual(score.uncappedPoints, 670)
        XCTAssertEqual(score.points, 600)
    }

    func testAppleActivityCapsSevenPerfectDaysAtFourThousandTwoHundredPoints() {
        let perfectDays = Array(
            repeating: AppleActivityScore(movePercent: 200, exercisePercent: 200, standPercent: 200),
            count: AppleActivityScore.durationDays
        )

        XCTAssertEqual(AppleActivityScore.totalPoints(for: perfectDays), AppleActivityScore.competitionCap)
    }

    func testCompetitionScoreSummaryShowsAheadBehindAndDailyHistory() {
        let currentUser = UUID(uuidString: "770e8400-e29b-41d4-a716-446655440000")!
        let opponent = UUID(uuidString: "880e8400-e29b-41d4-a716-446655440000")!
        let competition = makeCompetition(status: .active, scoringFormula: .appleActivity)
        let summary = CompetitionScoreSummary(
            competition: competition,
            currentUserId: currentUser,
            opponentUserId: opponent,
            dailyScores: [
                makeDailyScore(userId: currentUser, date: "2026-05-11", points: 300),
                makeDailyScore(userId: opponent, date: "2026-05-11", points: 280),
                makeDailyScore(userId: currentUser, date: "2026-05-12", points: 275),
                makeDailyScore(userId: opponent, date: "2026-05-12", points: 300),
            ]
        )

        XCTAssertEqual(summary.currentUserTotal, 575)
        XCTAssertEqual(summary.opponentTotal, 580)
        XCTAssertEqual(summary.standing, .behind(points: 5))
        XCTAssertEqual(summary.dailyHistory.count, 2)
        XCTAssertEqual(summary.dailyHistory[0].date, "2026-05-11")
        XCTAssertEqual(summary.dailyHistory[0].currentUserPoints, 300)
        XCTAssertEqual(summary.dailyHistory[0].opponentPoints, 280)
        XCTAssertEqual(summary.dailyHistory[0].standing, .ahead(points: 20))
    }

    func testCompetitionScoreSummaryReportsCompletedTie() {
        let currentUser = UUID(uuidString: "770e8400-e29b-41d4-a716-446655440000")!
        let opponent = UUID(uuidString: "880e8400-e29b-41d4-a716-446655440000")!
        let competition = makeCompetition(status: .completed, scoringFormula: .appleActivity)
        let summary = CompetitionScoreSummary(
            competition: competition,
            currentUserId: currentUser,
            opponentUserId: opponent,
            dailyScores: [
                makeDailyScore(userId: currentUser, date: "2026-05-11", points: 300),
                makeDailyScore(userId: opponent, date: "2026-05-11", points: 300),
            ]
        )

        XCTAssertEqual(summary.standing, .tied)
        XCTAssertEqual(summary.finalResult, .tied)
    }

    func testAppleActivityCompetitionSummaryCapsTotalsAtFourThousandTwoHundred() {
        let currentUser = UUID(uuidString: "770e8400-e29b-41d4-a716-446655440000")!
        let opponent = UUID(uuidString: "880e8400-e29b-41d4-a716-446655440000")!
        let competition = makeCompetition(status: .completed, scoringFormula: .appleActivity)
        let currentScores = (1...8).map {
            makeDailyScore(userId: currentUser, date: "2026-05-\(String(format: "%02d", $0))", points: 600)
        }
        let opponentScores = (1...8).map {
            makeDailyScore(userId: opponent, date: "2026-05-\(String(format: "%02d", $0))", points: 500)
        }

        let summary = CompetitionScoreSummary(
            competition: competition,
            currentUserId: currentUser,
            opponentUserId: opponent,
            dailyScores: currentScores + opponentScores
        )

        XCTAssertEqual(summary.currentUserTotal, 4_200)
        XCTAssertEqual(summary.opponentTotal, 3_500)
        XCTAssertEqual(summary.finalResult, .won)
    }

    func testAppleActivityDailyHistoryCapsDailyPoints() {
        let currentUser = UUID(uuidString: "770e8400-e29b-41d4-a716-446655440000")!
        let opponent = UUID(uuidString: "880e8400-e29b-41d4-a716-446655440000")!
        let competition = makeCompetition(status: .active, scoringFormula: .appleActivity)
        let summary = CompetitionScoreSummary(
            competition: competition,
            currentUserId: currentUser,
            opponentUserId: opponent,
            dailyScores: [
                makeDailyScore(userId: currentUser, date: "2026-05-11", points: 900),
                makeDailyScore(userId: opponent, date: "2026-05-11", points: 700),
            ]
        )

        XCTAssertEqual(summary.dailyHistory[0].currentUserPoints, 600)
        XCTAssertEqual(summary.dailyHistory[0].opponentPoints, 600)
        XCTAssertEqual(summary.dailyHistory[0].standing, .tied)
    }

    func testAppleActivityDailyHistoryShowsOnlySevenCompetitionDays() {
        let currentUser = UUID(uuidString: "770e8400-e29b-41d4-a716-446655440000")!
        let opponent = UUID(uuidString: "880e8400-e29b-41d4-a716-446655440000")!
        let competition = makeCompetition(status: .active, scoringFormula: .appleActivity)
        let currentScores = (1...8).map {
            makeDailyScore(userId: currentUser, date: "2026-05-\(String(format: "%02d", $0))", points: 300)
        }
        let opponentScores = (1...8).map {
            makeDailyScore(userId: opponent, date: "2026-05-\(String(format: "%02d", $0))", points: 300)
        }

        let summary = CompetitionScoreSummary(
            competition: competition,
            currentUserId: currentUser,
            opponentUserId: opponent,
            dailyScores: currentScores + opponentScores
        )

        XCTAssertEqual(summary.dailyHistory.count, 7)
        XCTAssertEqual(summary.dailyHistory.last?.date, "2026-05-07")
    }

    func testCompetitionDateWindowUsesInclusiveSevenDayEndDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let startDate = calendar.date(from: DateComponents(year: 2026, month: 5, day: 11))!

        let window = CompetitionDateWindow(
            starting: startDate,
            durationDays: AppleActivityScore.durationDays,
            calendar: calendar
        )

        XCTAssertEqual(window.startDate, "2026-05-11")
        XCTAssertEqual(window.endDate, "2026-05-17")
    }

    func testCompetitionAlertsCoverAppleParityEvents() {
        let alerts = [
            CompetitionAlert(kind: .inviteReceived(challengerName: "Alex"), modeName: "Apple Activity"),
            CompetitionAlert(kind: .inviteAccepted(opponentName: "Alex"), modeName: "Apple Activity"),
            CompetitionAlert(kind: .inviteDeclined(opponentName: "Alex"), modeName: "Apple Activity"),
            CompetitionAlert(kind: .competitionStarted, modeName: "Apple Activity"),
            CompetitionAlert(kind: .dailyProgress(points: 300, standing: .ahead(points: 25)), modeName: "Apple Activity"),
            CompetitionAlert(kind: .standingChanged(.behind(points: 10)), modeName: "Apple Activity"),
            CompetitionAlert(kind: .endingSoon(daysRemaining: 1), modeName: "Apple Activity"),
            CompetitionAlert(kind: .competitionCompleted(.won), modeName: "Apple Activity"),
            CompetitionAlert(kind: .competitionCompleted(.lost), modeName: "Apple Activity"),
            CompetitionAlert(kind: .competitionCompleted(.tied), modeName: "Apple Activity"),
        ]

        XCTAssertEqual(alerts[0].title, "Competition Invite")
        XCTAssertEqual(alerts[4].body, "You scored 300 points today and are ahead by 25.")
        XCTAssertEqual(alerts[7].body, "Apple Activity is complete. You won.")
        XCTAssertEqual(alerts[9].body, "Apple Activity is complete. You tied.")
    }

    func testWeightsSumToOne() {
        for (name, formula) in ScoringFormula.allPresets {
            let sum = formula.metrics.reduce(0) { $0 + $1.weight }
            XCTAssertEqual(sum, 1.0, accuracy: 0.001, "Weights don't sum to 1.0 for \(name)")
        }
    }

    func testCompetitionDecodes() throws {
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "type": "one_v_one",
            "mode_name": "active_living",
            "scoring_formula": {
                "metrics": [
                    {"type": "active_calories", "weight": 0.4},
                    {"type": "exercise_minutes", "weight": 0.35},
                    {"type": "stand_hours", "weight": 0.25}
                ],
                "daily_cap": 600
            },
            "status": "active",
            "start_date": "2026-04-01",
            "end_date": "2026-04-07",
            "created_by": "660e8400-e29b-41d4-a716-446655440000",
            "handicap_enabled": false,
            "stakes_text": "Loser buys coffee",
            "created_at": "2026-03-31T12:00:00Z"
        }
        """.data(using: .utf8)!

        let comp = try JSONDecoder.supabase.decode(Competition.self, from: json)
        XCTAssertEqual(comp.type, .oneVOne)
        XCTAssertEqual(comp.status, .active)
        XCTAssertEqual(comp.scoringFormula.metrics.count, 3)
        XCTAssertEqual(comp.stakesText, "Loser buys coffee")
    }

    func testDailyScoreDecodes() throws {
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "competition_id": "660e8400-e29b-41d4-a716-446655440000",
            "user_id": "770e8400-e29b-41d4-a716-446655440000",
            "date": "2026-04-01",
            "metric_scores": {"active_calories": 85.2, "exercise_minutes": 100.0, "stand_hours": 66.7},
            "total_points": 251.9,
            "created_at": "2026-04-01T23:59:00Z"
        }
        """.data(using: .utf8)!

        let score = try JSONDecoder.supabase.decode(DailyScore.self, from: json)
        XCTAssertEqual(score.totalPoints, 251.9)
        XCTAssertEqual(score.metricScores["active_calories"], 85.2)
    }

    func testParticipantDecodes() throws {
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "competition_id": "660e8400-e29b-41d4-a716-446655440000",
            "user_id": "770e8400-e29b-41d4-a716-446655440000",
            "team_id": null,
            "role": "challenger",
            "status": "accepted",
            "goal_snapshot": {"active_calories": 500, "exercise_minutes": 30, "stand_hours": 12},
            "handicap_mult": 1.0,
            "joined_at": "2026-03-31T12:00:00Z"
        }
        """.data(using: .utf8)!

        let p = try JSONDecoder.supabase.decode(CompetitionParticipant.self, from: json)
        XCTAssertEqual(p.role, .challenger)
        XCTAssertEqual(p.status, .accepted)
        XCTAssertEqual(p.goalSnapshot?["active_calories"], 500)
    }

    private func makeCompetition(
        status: CompetitionStatus,
        scoringFormula: ScoringFormula
    ) -> Competition {
        Competition(
            id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
            type: .oneVOne,
            modeName: "apple_activity",
            scoringFormula: scoringFormula,
            status: status,
            startDate: "2026-05-11",
            endDate: "2026-05-17",
            createdBy: UUID(uuidString: "660e8400-e29b-41d4-a716-446655440000")!,
            handicapEnabled: false,
            stakesText: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeDailyScore(
        userId: UUID,
        date: String,
        points: Double
    ) -> DailyScore {
        DailyScore(
            id: UUID(),
            competitionId: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
            userId: userId,
            date: date,
            metricScores: [:],
            totalPoints: points,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}
