import CompetitionCore
import ComposableArchitecture
import Foundation

/// What Create Match sends: named people and bots only.
struct GroupMatchDraft: Hashable, Sendable {
    enum Seat: Hashable, Sendable {
        case person(profileID: UUID, team: Int?)
        case bot(BotMode, team: Int?)
    }

    let format: GroupMatchFormat
    let seats: [Seat]
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
}

/// Commands for group matches, so screens add no reducer code. The published
/// match comes back through `CompetitionFeature`.
@Reducer
struct GroupMatchFeature {
    @ObservableState
    struct State: Equatable {
        var inFlight: Set<GroupMatchCommand> = []
        var failed: Set<GroupMatchCommand> = []
    }

    enum Action: Equatable, Sendable {
        enum Delegate: Equatable, Sendable {
            case published(CompetitionPublication)
        }

        case commandTapped(GroupMatchCommand)
        /// Nil when the command failed.
        case commandFinished(GroupMatchCommand, CompetitionPublication?)
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
                return .run { send in
                    let published = try? await competitionClient.groupMatchCommand(command)
                    await send(.commandFinished(command, published))
                }
                .cancellable(id: CancelID.commands)

            case let .commandFinished(command, published):
                state.inFlight.remove(command)
                guard let published else {
                    state.failed.insert(command)
                    return .none
                }
                return .send(.delegate(.published(published)))

            case .delegate:
                return .none
            }
        }
    }
}
