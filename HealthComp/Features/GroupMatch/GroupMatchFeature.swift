import CompetitionCore
import ComposableArchitecture
import Foundation

struct GroupMatchDraft: Hashable, Sendable {
    enum Seat: Hashable, Sendable {
        case person(profileID: UUID, team: Int?)
        case challengeLink(CompetitionChallengeLinkCode, team: Int?)
        case bot(BotMode, team: Int?)
    }

    let format: GroupMatchFormat
    let seats: [Seat]
    var metrics: CompetitionMetrics = .threeRings
}

extension CompetitionChallengeLinkCode: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }
}

enum GroupMatchCommand: Hashable, Sendable {
    case create(GroupMatchDraft)
    case accept(CompetitionID)
    case decline(CompetitionID)
    case withdraw(CompetitionID)
    case cancel(CompetitionID)
    case leave(CompetitionID)
    case nudge(CompetitionID)
    case react(CompetitionID, seatID: UUID, ordinal: Int, CompetitionReactionKind?)
    case rematch(CompetitionID)
    case block(CompetitionID)
}

enum GroupMatchFailure: Hashable, Sendable {
    case recipientUnavailable
    case updateRequired(profileID: UUID?, displayName: String? = nil)
    case creationLimit
    case closed
    case nudgeNotNeeded

    init?(_ error: Error) {
        switch error as? CompetitionRemoteFailure {
        case .recipientUnavailable?: self = .recipientUnavailable
        case let .groupUpdateRequired(profileID, displayName)?:
            self = .updateRequired(profileID: profileID, displayName: displayName)
        case .groupCreationLimit?: self = .creationLimit
        case .inviteUnavailable?: self = .closed
        default: return nil
        }
    }

    func message(name: String? = nil) -> String {
        switch self {
        case .recipientUnavailable: "Someone in this lineup can’t be invited. Check the players and try again."
        case let .updateRequired(_, displayName):
            "\(name ?? displayName ?? "Someone in this lineup") needs to update HealthComp first."
        case .creationLimit: "You already have 5 group matches waiting or live. Finish or cancel one first."
        case .closed: "This match is no longer open."
        case .nudgeNotNeeded: "Your partner doesn’t need a nudge right now."
        }
    }
}

@Reducer
struct GroupMatchFeature {
    @ObservableState
    struct State: Equatable {
        var inFlight: Set<GroupMatchCommand> = []
        var failed: Set<GroupMatchCommand> = []
        var failureReasons: [GroupMatchCommand: GroupMatchFailure] = [:]

        func failureLine(
            _ commands: [GroupMatchCommand], otherwise generic: String, name: (UUID) -> String? = { _ in nil }
        ) -> String? {
            guard let command = commands.first(where: failed.contains) else { return nil }
            guard let reason = failureReasons[command] else { return generic }
            if case let .updateRequired(profileID?, _) = reason { return reason.message(name: name(profileID)) }
            return reason.message()
        }
    }

    enum Action: Equatable, Sendable {
        enum Delegate: Equatable, Sendable {
            case published(CompetitionPublication)
        }

        case commandTapped(GroupMatchCommand)
        case commandFinished(GroupMatchCommand, CompetitionPublication?, GroupMatchFailure? = nil)
        case delegate(Delegate)
    }

    @Dependency(\.competitionClient) var competitionClient

    enum CancelID { case commands }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .commandTapped(command):
                guard state.inFlight.insert(command).inserted else { return .none }
                state.failed.remove(command)
                state.failureReasons[command] = nil
                return .run { send in
                    do {
                        let published = try await competitionClient.groupMatchCommand(command)
                        await send(.commandFinished(command, published))
                    } catch {
                        var reason = GroupMatchFailure(error)
                        if case .nudge = command, error as? CompetitionRemoteFailure == .forbidden { reason = .nudgeNotNeeded }
                        await send(.commandFinished(command, nil, reason))
                    }
                }
                .cancellable(id: CancelID.commands)

            case let .commandFinished(command, published, reason):
                state.inFlight.remove(command)
                guard let published else {
                    state.failed.insert(command)
                    state.failureReasons[command] = reason
                    return .none
                }
                return .send(.delegate(.published(published)))

            case .delegate:
                return .none
            }
        }
    }
}
