import ComposableArchitecture
import Foundation

/// Account → Privacy's server-held rows and the username sheet.
@Reducer
struct FriendSettingsFeature {
    enum Field: Equatable, Sendable { case showInSearch, challengePolicy }

    enum UsernameAvailability: Equatable, Sendable { case unknown, available, taken }

    enum UsernameFailure: Equatable, Sendable { case invalid, failed }

    struct UsernameSheet: Equatable, Sendable {
        var draft = ""
        /// Counts edits, so a wait or answer from an earlier edit is dropped
        /// even when you've typed your way back to the same name.
        var edit = 0
        var availability = UsernameAvailability.unknown
        var isSaving = false
        var failure: UsernameFailure?

        /// A name the check found taken can't be sent; an unanswered check
        /// doesn't hold you up, because saving asks the server anyway.
        var canContinue: Bool {
            FriendSettings.isValidUsername(draft) && availability != .taken && !isSaving
        }
    }

    /// Not `@ObservableState`: Account takes this by value, so a change has
    /// to reach it through the parent's `friendSettings`.
    struct State: Equatable {
        /// Nil until the server answers, which hides the rows.
        var saved: FriendSettings?
        /// The change being saved.
        var saving: FriendSettings?
        var failedField: Field?
        /// Non-nil while the username sheet is open.
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
                // A failed refresh keeps whatever was shown.
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
                // stop clears `saving`, so a late result never marks the next account.
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
                // Your own name needs no check, and checks count against
                // the search limit.
                guard FriendSettings.isValidUsername(draft), draft != state.saved?.username else {
                    return .none
                }
                // No cancelInFlight: it cancels when the new effect starts,
                // and on a busy main thread an older edit's effect can start
                // later and cancel the newest one, so no check would ever
                // answer the name shown. Every edit waits; only the latest
                // edit, if nothing followed it, asks.
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
                // A load already running may have read before this save.
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

    /// Sends the whole row: the server takes both values together.
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
