import ComposableArchitecture
import Foundation

@Reducer
struct FriendSettingsFeature {
    enum Field: Equatable, Sendable { case showInSearch, challengePolicy }

    enum UsernameAvailability: Equatable, Sendable { case unknown, available, taken }

    enum UsernameFailure: Equatable, Sendable { case invalid, failed }

    struct UsernameSheet: Equatable, Sendable {
        var draft = ""
        var edit = 0
        var availability = UsernameAvailability.unknown
        var isSaving = false
        var failure: UsernameFailure?

        var canContinue: Bool {
            FriendSettings.isValidUsername(draft) && availability != .taken && !isSaving
        }
    }

    struct State: Equatable {
        var saved: FriendSettings?
        var saving: FriendSettings?
        var failedField: Field?
        var sheet: UsernameSheet?

        var shown: FriendSettings? { saving ?? saved }
        var isSaving: Bool { saving != nil || sheet?.isSaving == true }
    }

    enum Action: Equatable, Sendable {
        case requested
        case loaded(FriendSettings?)
        case showInSearchChanged(Bool)
        case challengePolicyChanged(FriendChallengePolicy)
        case saveFinished(FriendSettings?)
        case usernameSheetOpened
        case usernameSheetClosed
        case usernameChanged(String)
        case usernameDebounced(edit: Int)
        case usernameChecked(edit: Int, isAvailable: Bool?)
        case usernameContinueTapped
        case usernameSaveFinished(Result<FriendSettings, CompetitionRemoteFailure>)
    }

    enum CancelID { case load, save, availability }

    static let availabilityDebounce = Duration.milliseconds(400)

    @Dependency(\.competitionClient) var competitionClient
    @Dependency(\.continuousClock) var clock

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .requested:
                guard !state.isSaving else { return .none }
                state.failedField = nil
                return .run { send in
                    await send(.loaded(try? await competitionClient.getFriendSettings()))
                }
                .cancellable(id: CancelID.load, cancelInFlight: true)

            case let .loaded(settings):
                if let settings { state.saved = settings }
                return .none

            case let .showInSearchChanged(isOn):
                guard var next = state.saved, next.showInSearch != isOn else { return .none }
                next.showInSearch = isOn
                return save(next, &state)

            case let .challengePolicyChanged(policy):
                guard var next = state.saved, next.challengePolicy != policy else { return .none }
                next.challengePolicy = policy
                return save(next, &state)

            case let .saveFinished(settings):
                guard let attempted = state.saving else { return .none }
                state.saving = nil
                if let settings {
                    state.saved = settings
                } else {
                    state.failedField = attempted.showInSearch != state.saved?.showInSearch
                        ? .showInSearch
                        : .challengePolicy
                }
                return .none

            case .usernameSheetOpened:
                guard let saved = state.saved, state.saving == nil else { return .none }
                state.failedField = nil
                state.sheet = UsernameSheet(draft: saved.username ?? "")
                return .none

            case .usernameSheetClosed:
                guard state.sheet?.isSaving != true else { return .none }
                state.sheet = nil
                return .cancel(id: CancelID.availability)

            case let .usernameChanged(draft):
                guard var sheet = state.sheet, sheet.draft != draft, !sheet.isSaving else {
                    return .none
                }
                sheet.draft = draft
                sheet.edit += 1
                sheet.availability = .unknown
                sheet.failure = nil
                state.sheet = sheet
                guard FriendSettings.isValidUsername(draft), draft != state.saved?.username else {
                    return .none
                }
                let edit: Int = sheet.edit
                return .run { send in
                    try await clock.sleep(for: Self.availabilityDebounce)
                    await send(.usernameDebounced(edit: edit))
                }
                .cancellable(id: CancelID.availability)

            case let .usernameDebounced(edit):
                guard let sheet = state.sheet, sheet.edit == edit, !sheet.isSaving else { return .none }
                let draft: String = sheet.draft
                return .run { send in
                    let isAvailable: Bool? = try? await competitionClient.usernameAvailable(draft)
                    await send(.usernameChecked(edit: edit, isAvailable: isAvailable))
                }
                .cancellable(id: CancelID.availability)

            case let .usernameChecked(edit, isAvailable):
                guard state.sheet?.edit == edit, let isAvailable else { return .none }
                state.sheet?.availability = isAvailable ? .available : .taken
                return .none

            case .usernameContinueTapped:
                guard var sheet = state.sheet, sheet.canContinue, state.saving == nil else {
                    return .none
                }
                sheet.isSaving = true
                sheet.failure = nil
                state.sheet = sheet
                let username = sheet.draft
                return .merge(
                    .cancel(id: CancelID.load),
                    .cancel(id: CancelID.availability),
                    .run { send in
                        do {
                            let settings = try await competitionClient.setUsername(username)
                            await send(.usernameSaveFinished(.success(settings)))
                        } catch {
                            await send(.usernameSaveFinished(.failure(
                                error as? CompetitionRemoteFailure ?? .operationFailed
                            )))
                        }
                    }
                    .cancellable(id: CancelID.save)
                )

            case let .usernameSaveFinished(result):
                guard state.sheet?.isSaving == true else { return .none }
                state.sheet?.isSaving = false
                switch result {
                case let .success(settings):
                    state.saved = settings
                    state.sheet = nil
                case .failure(.usernameUnavailable):
                    state.sheet?.availability = .taken
                case .failure(.invalidUsername):
                    state.sheet?.failure = .invalid
                case .failure:
                    state.sheet?.failure = .failed
                }
                return .none
            }
        }
    }

    private func save(_ next: FriendSettings, _ state: inout State) -> Effect<Action> {
        guard !state.isSaving, state.sheet == nil else { return .none }
        state.saving = next
        state.failedField = nil
        return .merge(
            .cancel(id: CancelID.load),
            .run { send in
                await send(.saveFinished(try? await competitionClient.updateFriendSettings(
                    next.showInSearch,
                    next.challengePolicy
                )))
            }
            .cancellable(id: CancelID.save)
        )
    }
}
