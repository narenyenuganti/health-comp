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
}
