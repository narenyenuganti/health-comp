import CompetitionCore
import ComposableArchitecture
import Foundation

/// What Create Match sends: named people and bots only, everyone but you.
/// In doubles you are on team 1.
struct GroupMatchDraft: Hashable, Sendable {
    enum Seat: Hashable, Sendable {
        case person(profileID: UUID, team: Int?)
        /// Someone named by their personal challenge link; the server resolves it.
        case challengeLink(CompetitionChallengeLinkCode, team: Int?)
        case bot(BotMode, team: Int?)
    }

    let format: GroupMatchFormat
    let seats: [Seat]
}

extension CompetitionChallengeLinkCode: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }
}

/// Everything a person can ask of a group match.
enum GroupMatchCommand: Hashable, Sendable {
    case create(GroupMatchDraft)
    case accept(CompetitionID)
    case decline(CompetitionID)
    case withdraw(CompetitionID)
    case cancel(CompetitionID)
    case leave(CompetitionID)
    /// Doubles partner only.
    case nudge(CompetitionID)
    /// Nil removes your reaction to that seat's day.
    case react(CompetitionID, seatID: UUID, ordinal: Int, CompetitionReactionKind?)
    case rematch(CompetitionID)
    /// From an invite: declines it and blocks whoever sent it.
    case block(CompetitionID)
}

/// Why a command failed, for the line under its button. Anything else
/// (offline, server error) has no reason and keeps the screen's generic line.
enum GroupMatchFailure: Hashable, Sendable {
    case recipientUnavailable
    /// The server names the first person who needs a newer app.
    case updateRequired(profileID: UUID?, displayName: String? = nil)
    case creationLimit
    /// Closed, expired or no longer yours to answer.
    case closed

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

    /// `name` is the display name of the person an update names, if known.
    func message(name: String? = nil) -> String {
        switch self {
        case .recipientUnavailable: "Someone in this lineup can’t be invited. Check the players and try again."
        case let .updateRequired(_, displayName):
            "\(name ?? displayName ?? "Someone in this lineup") needs to update HealthComp first."
        case .creationLimit: "You already have 5 group matches waiting or live. Finish or cancel one first."
        case .closed: "This match is no longer open."
        }
    }
}

/// Commands for group matches, so screens add no reducer code. The published
/// match comes back through `CompetitionFeature`.
@Reducer
struct GroupMatchFeature {
    @ObservableState
    struct State: Equatable {
        var inFlight: Set<GroupMatchCommand> = []
        var failed: Set<GroupMatchCommand> = []
        /// Why a command in `failed` failed, when the server said.
        var failureReasons: [GroupMatchCommand: GroupMatchFailure] = [:]

        /// The line under the first of `commands` that failed: the server's
        /// reason when it gave one, otherwise `generic`. Nil when none failed.
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
        /// Nil publication when the command failed, with the reason if known.
        case commandFinished(GroupMatchCommand, CompetitionPublication?, GroupMatchFailure? = nil)
        case delegate(Delegate)
    }

    @Dependency(\.competitionClient) var competitionClient

    /// `CompetitionFeature.stop` cancels these, so a sign-out drops late answers.
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
                        await send(.commandFinished(command, nil, GroupMatchFailure(error)))
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
