import ComposableArchitecture
import Foundation

@Reducer
struct CompeteFeature {
    @ObservableState
    struct State: Equatable {
        var activeCompetitions: [Competition] = []
        var pendingInvites: [Competition] = []
        var isLoading = false
        var errorMessage: String?
    }

    enum Action: Equatable, Sendable {
        case onAppear
        case activeLoaded(Result<[Competition], CompetitionError>)
        case invitesLoaded(Result<[Competition], CompetitionError>)
        case acceptInviteTapped(UUID)
        case inviteAccepted(Result<Bool, CompetitionError>)
        case declineInviteTapped(UUID)
    }

    @Dependency(\.competitionClient) var competitionClient

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
                }

            case .activeLoaded(.success(let competitions)):
                state.isLoading = false
                state.activeCompetitions = competitions
                return .none

            case .activeLoaded(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                return .none

            case .invitesLoaded(.success(let invites)):
                state.pendingInvites = invites
                return .none

            case .invitesLoaded(.failure):
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
                return .run { _ in
                    try await competitionClient.declineInvite(competitionId)
                }
            }
        }
    }
}

enum CompetitionError: Error, Equatable, LocalizedError {
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .networkError(let msg): return msg
        }
    }
}
