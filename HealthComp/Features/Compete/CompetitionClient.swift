import Dependencies
import DependenciesMacros
import Foundation
import Supabase

@DependencyClient
struct CompetitionClient: Sendable {
    var fetchActive: @Sendable () async throws -> [Competition]
    var fetchPendingInvites: @Sendable () async throws -> [Competition]
    var fetchHistory: @Sendable () async throws -> [Competition]
    var fetchParticipants: @Sendable (_ competitionId: UUID) async throws -> [CompetitionParticipant]
    var fetchDailyScores: @Sendable (_ competitionId: UUID) async throws -> [DailyScore]
    var createCompetition: @Sendable (_ type: CompetitionType, _ modeName: String, _ formula: ScoringFormula, _ duration: Int, _ opponentIds: [UUID]) async throws -> Competition
    var acceptInvite: @Sendable (_ competitionId: UUID) async throws -> Void
    var declineInvite: @Sendable (_ competitionId: UUID) async throws -> Void
}

extension CompetitionClient: TestDependencyKey {
    static let testValue = CompetitionClient()
}

extension DependencyValues {
    var competitionClient: CompetitionClient {
        get { self[CompetitionClient.self] }
        set { self[CompetitionClient.self] = newValue }
    }
}

// MARK: - Live Implementation

extension CompetitionClient: DependencyKey {
    static let liveValue: CompetitionClient = {
        let supabase = SupabaseService.shared

        return CompetitionClient(
            fetchActive: {
                try await supabase
                    .from("competitions")
                    .select()
                    .eq("status", value: "active")
                    .order("start_date", ascending: false)
                    .execute()
                    .value
            },
            fetchPendingInvites: {
                // Competitions where user is invited but hasn't accepted
                let userId = try await supabase.auth.session.user.id
                let participations: [CompetitionParticipant] = try await supabase
                    .from("competition_participants")
                    .select()
                    .eq("user_id", value: userId.uuidString)
                    .eq("status", value: "invited")
                    .execute()
                    .value

                guard !participations.isEmpty else { return [] }

                let compIds = participations.map { $0.competitionId.uuidString }
                let competitions: [Competition] = try await supabase
                    .from("competitions")
                    .select()
                    .in("id", values: compIds)
                    .execute()
                    .value

                return competitions
            },
            fetchHistory: {
                try await supabase
                    .from("competitions")
                    .select()
                    .eq("status", value: "completed")
                    .order("end_date", ascending: false)
                    .execute()
                    .value
            },
            fetchParticipants: { competitionId in
                try await supabase
                    .from("competition_participants")
                    .select()
                    .eq("competition_id", value: competitionId.uuidString)
                    .execute()
                    .value
            },
            fetchDailyScores: { competitionId in
                try await supabase
                    .from("daily_scores")
                    .select()
                    .eq("competition_id", value: competitionId.uuidString)
                    .order("date")
                    .execute()
                    .value
            },
            createCompetition: { type, modeName, formula, duration, opponentIds in
                let userId = try await supabase.auth.session.user.id
                let calendar = Calendar.current
                let startDate = calendar.date(byAdding: .day, value: 1, to: Date())!
                let endDate = calendar.date(byAdding: .day, value: duration, to: startDate)!

                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"

                struct CompPayload: Encodable {
                    let type: String
                    let mode_name: String
                    let scoring_formula: ScoringFormula
                    let status: String
                    let start_date: String
                    let end_date: String
                    let created_by: UUID
                    let handicap_enabled: Bool
                }

                let comp: Competition = try await supabase
                    .from("competitions")
                    .insert(CompPayload(
                        type: type.rawValue,
                        mode_name: modeName,
                        scoring_formula: formula,
                        status: "pending",
                        start_date: dateFormatter.string(from: startDate),
                        end_date: dateFormatter.string(from: endDate),
                        created_by: userId,
                        handicap_enabled: false
                    ))
                    .select()
                    .single()
                    .execute()
                    .value

                // Add creator as challenger (auto-accepted)
                struct ParticipantPayload: Encodable {
                    let competition_id: UUID
                    let user_id: UUID
                    let role: String
                    let status: String
                }

                try await supabase
                    .from("competition_participants")
                    .insert(ParticipantPayload(
                        competition_id: comp.id,
                        user_id: userId,
                        role: "challenger",
                        status: "accepted"
                    ))
                    .execute()

                // Add opponents as invited
                for opponentId in opponentIds {
                    try await supabase
                        .from("competition_participants")
                        .insert(ParticipantPayload(
                            competition_id: comp.id,
                            user_id: opponentId,
                            role: "opponent",
                            status: "invited"
                        ))
                        .execute()
                }

                return comp
            },
            acceptInvite: { competitionId in
                let userId = try await supabase.auth.session.user.id
                try await supabase
                    .from("competition_participants")
                    .update(["status": "accepted", "joined_at": ISO8601DateFormatter().string(from: Date())])
                    .eq("competition_id", value: competitionId.uuidString)
                    .eq("user_id", value: userId.uuidString)
                    .execute()
            },
            declineInvite: { competitionId in
                let userId = try await supabase.auth.session.user.id
                try await supabase
                    .from("competition_participants")
                    .update(["status": "declined"])
                    .eq("competition_id", value: competitionId.uuidString)
                    .eq("user_id", value: userId.uuidString)
                    .execute()
            }
        )
    }()
}
