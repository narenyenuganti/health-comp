import ComposableArchitecture
import Foundation

@Reducer
struct CompeteFeature {
    @ObservableState
    struct State: Equatable {
        var currentUserId: UUID?
        var activeCompetitions: [Competition] = []
        var pendingInvites: [Competition] = []
        var historyCompetitions: [Competition] = []
        var selectedCompetition: Competition?
        var selectedParticipants: [CompetitionParticipant] = []
        var selectedDailyScores: [DailyScore] = []
        var selectedSummary: CompetitionScoreSummary?
        var notifiedInviteIds: Set<UUID> = []
        var notifiedActiveCompetitionIds: Set<UUID> = []
        var notifiedEndingSoonCompetitionIds: Set<UUID> = []
        var notifiedDailyProgressKeys: Set<String> = []
        var notifiedResultCompetitionIds: Set<UUID> = []
        var isLoading = false
        var isDetailLoading = false
        var errorMessage: String?
    }

    enum Action: Equatable, Sendable {
        case onAppear
        case activeLoaded(Result<[Competition], CompetitionError>)
        case invitesLoaded(Result<[Competition], CompetitionError>)
        case historyLoaded(Result<[Competition], CompetitionError>)
        case competitionTapped(UUID)
        case detailLoaded(Result<CompetitionDetailPayload, CompetitionError>)
        case dismissDetail
        case acceptInviteTapped(UUID)
        case inviteAccepted(Result<Bool, CompetitionError>)
        case declineInviteTapped(UUID)
        case inviteDeclined(Result<Bool, CompetitionError>)
    }

    @Dependency(\.competitionClient) var competitionClient
    @Dependency(\.competitionNotificationClient) var competitionNotificationClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                state.isLoading = true
                return .run { send in
                    do {
                        let active = try await competitionClient.fetchActive()
                        await send(.activeLoaded(.success(active)))
                    } catch {
                        await send(.activeLoaded(.failure(.networkError(error.localizedDescription))))
                    }
                    do {
                        let invites = try await competitionClient.fetchPendingInvites()
                        await send(.invitesLoaded(.success(invites)))
                    } catch {
                        await send(.invitesLoaded(.failure(.networkError(error.localizedDescription))))
                    }
                    do {
                        let history = try await competitionClient.fetchHistory()
                        await send(.historyLoaded(.success(history)))
                    } catch {
                        await send(.historyLoaded(.failure(.networkError(error.localizedDescription))))
                    }
                }

            case .activeLoaded(.success(let competitions)):
                state.isLoading = false
                state.activeCompetitions = competitions
                let startedAlerts = competitions
                    .filter { state.notifiedActiveCompetitionIds.insert($0.id).inserted }
                    .map {
                        CompetitionAlert(
                            kind: .competitionStarted,
                            modeName: $0.displayModeName
                        )
                    }
                let endingSoonAlerts = competitions
                    .filter {
                        $0.isEndingSoon()
                            && state.notifiedEndingSoonCompetitionIds.insert($0.id).inserted
                    }
                    .map {
                        CompetitionAlert(
                            kind: .endingSoon(daysRemaining: $0.daysRemaining() ?? 0),
                            modeName: $0.displayModeName
                        )
                    }
                return scheduleAlerts(startedAlerts + endingSoonAlerts)

            case .activeLoaded(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                return .none

            case .invitesLoaded(.success(let invites)):
                state.pendingInvites = invites
                let alerts = invites
                    .filter { state.notifiedInviteIds.insert($0.id).inserted }
                    .map {
                        CompetitionAlert(
                            kind: .inviteReceived(challengerName: "A friend"),
                            modeName: $0.displayModeName
                        )
                    }
                return scheduleAlerts(alerts)

            case .invitesLoaded(.failure):
                return .none

            case .historyLoaded(.success(let competitions)):
                state.historyCompetitions = competitions
                return .none

            case .historyLoaded(.failure):
                return .none

            case .competitionTapped(let competitionId):
                guard let competition = (
                    state.activeCompetitions + state.historyCompetitions + state.pendingInvites
                ).first(where: { $0.id == competitionId }) else {
                    return .none
                }
                state.selectedCompetition = competition
                state.selectedParticipants = []
                state.selectedDailyScores = []
                state.selectedSummary = nil
                state.isDetailLoading = true
                return .run { send in
                    do {
                        async let participants = competitionClient.fetchParticipants(competitionId)
                        async let scores = competitionClient.fetchDailyScores(competitionId)
                        let loadedParticipants = try await participants
                        let loadedScores = try await scores
                        let payload = CompetitionDetailPayload(
                            competition: competition,
                            participants: loadedParticipants,
                            dailyScores: loadedScores
                        )
                        await send(.detailLoaded(.success(payload)))
                    } catch {
                        await send(.detailLoaded(.failure(.networkError(error.localizedDescription))))
                    }
                }

            case .detailLoaded(.success(let payload)):
                state.isDetailLoading = false
                state.selectedCompetition = payload.competition
                state.selectedParticipants = payload.participants
                state.selectedDailyScores = payload.dailyScores
                if
                    let currentUserId = state.currentUserId,
                    let opponent = payload.participants.first(where: { $0.userId != currentUserId })
                {
                    let summary = CompetitionScoreSummary(
                        competition: payload.competition,
                        currentUserId: currentUserId,
                        opponentUserId: opponent.userId,
                        dailyScores: payload.dailyScores
                    )
                    state.selectedSummary = summary
                    var alerts: [CompetitionAlert] = []
                    if let latestDay = summary.dailyHistory.last {
                        let key = "\(payload.competition.id.uuidString.lowercased())-\(latestDay.date)"
                        if state.notifiedDailyProgressKeys.insert(key).inserted {
                            alerts.append(CompetitionAlert(
                                kind: .dailyProgress(
                                    points: latestDay.currentUserPoints,
                                    standing: summary.standing
                                ),
                                modeName: payload.competition.displayModeName
                            ))
                        }
                    }
                    if
                        let finalResult = summary.finalResult,
                        state.notifiedResultCompetitionIds.insert(payload.competition.id).inserted
                    {
                        alerts.append(CompetitionAlert(
                            kind: .competitionCompleted(finalResult),
                            modeName: payload.competition.displayModeName
                        ))
                    }
                    return scheduleAlerts(alerts)
                }
                return .none

            case .detailLoaded(.failure(let error)):
                state.isDetailLoading = false
                state.errorMessage = error.localizedDescription
                return .none

            case .dismissDetail:
                state.selectedCompetition = nil
                state.selectedParticipants = []
                state.selectedDailyScores = []
                state.selectedSummary = nil
                state.isDetailLoading = false
                return .none

            case .acceptInviteTapped(let competitionId):
                return .run { send in
                    do {
                        try await competitionClient.acceptInvite(competitionId)
                        await send(.inviteAccepted(.success(true)))
                    } catch {
                        await send(.inviteAccepted(.failure(.networkError(error.localizedDescription))))
                    }
                }

            case .inviteAccepted(.success):
                return .send(.onAppear)

            case .inviteAccepted(.failure):
                return .none

            case .declineInviteTapped(let competitionId):
                return .run { send in
                    do {
                        try await competitionClient.declineInvite(competitionId)
                        await send(.inviteDeclined(.success(true)))
                    } catch {
                        await send(.inviteDeclined(.failure(.networkError(error.localizedDescription))))
                    }
                }

            case .inviteDeclined(.success):
                return .send(.onAppear)

            case .inviteDeclined(.failure):
                return .none
            }
        }
    }

    private func scheduleAlerts(_ alerts: [CompetitionAlert]) -> Effect<Action> {
        guard !alerts.isEmpty else { return .none }
        return .run { _ in
            guard (try? await competitionNotificationClient.requestAuthorization()) == true else { return }
            for alert in alerts {
                try? await competitionNotificationClient.schedule(alert)
            }
        }
    }
}

struct CompetitionDetailPayload: Equatable, Sendable {
    let competition: Competition
    let participants: [CompetitionParticipant]
    let dailyScores: [DailyScore]
}

enum CompetitionError: Error, Equatable, LocalizedError {
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .networkError(let msg): return msg
        }
    }
}
