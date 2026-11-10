import ComposableArchitecture
import Foundation

/// The Friends screen, people search, adding someone, and removing,
/// blocking or reporting them from their page.
@Reducer
struct FriendsFeature {
    /// `cancel` takes back your request; `remove` ends a friendship. Both
    /// are `remove_friend`.
    enum Change: Equatable, Sendable { case add, accept, decline, cancel, remove }

    enum ChangeFailure: Equatable, Sendable { case connection, unavailable, limit }

    enum SearchFailure: Equatable, Sendable { case rateLimited, connection }

    struct PersonFailure: Equatable, Sendable {
        let id: UUID
        let failure: ChangeFailure
    }

    /// Not `@ObservableState`, as `FriendSettingsFeature.State`.
    struct State: Equatable {
        /// Nil until the server answers.
        var list: FriendsList?
        var loadFailed = false
        var query = ""
        /// Nil under 3 characters and until the first answer.
        var results: [FriendPerson]?
        var isSearching = false
        var searchFailure: SearchFailure?
        /// Everyone last seen, so their page can draw after they leave the
        /// list or the results.
        var people: [UUID: FriendPerson] = [:]
        var inFlight: Set<UUID> = []
        /// The part of `inFlight` that is a block or report: these finish
        /// even after Friends closes, as Unblock does.
        var safetyInFlight: Set<UUID> = []
        var failure: PersonFailure?
        /// Reported from this iPhone since sign-in.
        var reported: Set<UUID> = []
        /// The Challenge sheet's Search People: focus the field once Friends shows.
        var focusesSearch = false

        var requestCount: Int { list?.incoming.count ?? 0 }

        func failure(for id: UUID) -> ChangeFailure? {
            failure?.id == id ? failure?.failure : nil
        }

        mutating func fail(_ person: FriendPerson, _ failure: CompetitionRemoteFailure) {
            let reason: ChangeFailure = switch failure {
            case .recipientUnavailable, .requestUnavailable: .unavailable
            case .friendRequestLimit: .limit
            default: .connection
            }
            self.failure = PersonFailure(id: person.id, failure: reason)
        }

        /// One person's answer, everywhere they're drawn.
        mutating func apply(_ relationship: FriendRelationship, to person: FriendPerson) {
            var person = person
            person.relationship = relationship
            people[person.id] = person
            results = results?.map { $0.id == person.id ? person : $0 }
            guard var list else { return }
            list.friends.removeAll { $0.id == person.id }
            list.incoming.removeAll { $0.id == person.id }
            list.outgoing.removeAll { $0.id == person.id }
            switch relationship {
            case .friend:
                let index = list.friends.firstIndex {
                    $0.displayName.localizedCaseInsensitiveCompare(person.displayName) == .orderedDescending
                }
                list.friends.insert(person, at: index ?? list.friends.count)
            case .incoming:
                list.incoming.insert(person, at: 0)
            case .requested:
                list.outgoing.insert(person, at: 0)
            case .none:
                break
            }
            self.list = list
        }

        /// The list says who is what; anyone else is no longer anything to you.
        mutating func merge(_ list: FriendsList) {
            self.list = list
            loadFailed = false
            let listed = Dictionary(
                (list.friends + list.incoming + list.outgoing).map { ($0.id, $0) }
            ) { first, _ in first }
            for id in people.keys where listed[id] == nil {
                people[id]?.relationship = FriendRelationship.none
            }
            people.merge(listed) { _, new in new }
            results = results?.map { listed[$0.id] ?? people[$0.id] ?? $0 }
        }
    }

    enum Action: Equatable, Sendable {
        case requested
        case loaded(FriendsList?)
        case queryChanged(String)
        case searchFinished(String, Result<[FriendPerson], CompetitionRemoteFailure>)
        case changeTapped(FriendPerson, Change)
        case changeFinished(FriendPerson, Result<FriendRelationship, CompetitionRemoteFailure>)
        /// The screen left the stack.
        case closed
        case blockTapped(FriendPerson)
        case blockFinished(FriendPerson, Result<AuthenticatedProfile, CompetitionRemoteFailure>)
        /// Report, then block when asked: once blocked they can't be reported.
        case reportTapped(FriendPerson, andBlock: Bool)
        /// Nil when the report was saved.
        case reportFinished(FriendPerson, andBlock: Bool, failure: CompetitionRemoteFailure?)
        case searchFocusRequested(Bool)
    }

    /// `safety` is Block and Report: sign-out cancels it, closing doesn't.
    enum CancelID { case load, search, change, safety }

    static let searchDebounce = Duration.milliseconds(300)

    /// What is sent, or nil under the server's 3 characters: trimmed, and a
    /// leading @ (usernames only) doesn't count. Code points, as the server does.
    static func searchableQuery(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let counted = trimmed.hasPrefix("@") ? trimmed.dropFirst() : Substring(trimmed)
        return counted.unicodeScalars.count >= 3 ? trimmed : nil
    }

    @Dependency(\.competitionClient) var competitionClient
    @Dependency(\.continuousClock) var clock

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .requested:
                // A load could read before a change; the last change reloads.
                guard state.inFlight.isEmpty else { return .none }
                return .run { send in
                    await send(.loaded(try? await competitionClient.listFriends()))
                }
                .cancellable(id: CancelID.load, cancelInFlight: true)

            case let .loaded(list):
                if let list {
                    state.merge(list)
                } else if state.list == nil {
                    // A failed refresh keeps whatever was shown.
                    state.loadFailed = true
                }
                return .none

            case let .queryChanged(query):
                guard query != state.query else { return .none }
                state.query = query
                state.searchFailure = nil
                guard let searchable = Self.searchableQuery(query) else {
                    state.results = nil
                    state.isSearching = false
                    return .cancel(id: CancelID.search)
                }
                state.isSearching = true
                return .run { send in
                    try await clock.sleep(for: Self.searchDebounce)
                    do {
                        let people = try await competitionClient.searchPeople(searchable)
                        await send(.searchFinished(searchable, .success(people)))
                    } catch {
                        await send(.searchFinished(searchable, .failure(
                            error as? CompetitionRemoteFailure ?? .operationFailed
                        )))
                    }
                }
                .cancellable(id: CancelID.search, cancelInFlight: true)

            case let .searchFinished(query, result):
                guard Self.searchableQuery(state.query) == query else { return .none }
                state.isSearching = false
                switch result {
                case let .success(people):
                    state.results = people
                    state.people.merge(people.map { ($0.id, $0) }) { _, new in new }
                case .failure(.invalidQuery):
                    // Over 40 characters, or something search can't take.
                    state.results = []
                case .failure(.searchRateLimited):
                    state.results = nil
                    state.searchFailure = .rateLimited
                case .failure:
                    state.results = nil
                    state.searchFailure = .connection
                }
                return .none

            case let .changeTapped(person, change):
                guard state.inFlight.insert(person.id).inserted else { return .none }
                state.failure = nil
                return .merge(
                    .cancel(id: CancelID.load),
                    .run { send in
                        do {
                            let relationship = switch change {
                            case .add: try await competitionClient.sendFriendRequest(person.id)
                            case .accept: try await competitionClient.respondToFriendRequest(person.id, true)
                            case .decline: try await competitionClient.respondToFriendRequest(person.id, false)
                            case .cancel, .remove: try await competitionClient.removeFriend(person.id)
                            }
                            await send(.changeFinished(person, .success(relationship)))
                        } catch {
                            await send(.changeFinished(person, .failure(
                                error as? CompetitionRemoteFailure ?? .operationFailed
                            )))
                        }
                    }
                    .cancellable(id: CancelID.change)
                )

            case let .changeFinished(person, result):
                // stop empties this, so a late answer never reaches the next account.
                guard state.inFlight.remove(person.id) != nil else { return .none }
                switch result {
                case let .success(relationship):
                    state.apply(relationship, to: person)
                case let .failure(failure):
                    state.fail(person, failure)
                }
                return state.inFlight.isEmpty ? .send(.requested) : .none

            case .closed:
                // A cancelled change may still have landed, so Home's badge
                // reloads after one; reopening reloads anyway.
                // A block or report finishes and reloads by itself.
                let interrupted: Bool = !state.inFlight.subtracting(state.safetyInFlight).isEmpty
                state.query = ""
                state.results = nil
                state.isSearching = false
                state.searchFailure = nil
                state.inFlight = state.safetyInFlight
                state.failure = nil
                return .merge(
                    .cancel(id: CancelID.search),
                    .cancel(id: CancelID.change),
                    interrupted ? .send(.requested) : .cancel(id: CancelID.load)
                )

            case let .blockTapped(person):
                guard state.inFlight.insert(person.id).inserted else { return .none }
                state.safetyInFlight.insert(person.id)
                state.failure = nil
                // Once sent, the server may apply it, so its answer must land
                // wherever the user has gone: only sign-out cancels it.
                return .merge(
                    .cancel(id: CancelID.load),
                    .run { send in
                        do {
                            let profile = try await competitionClient.blockProfile(person.id)
                            await send(.blockFinished(person, .success(profile)))
                        } catch {
                            await send(.blockFinished(person, .failure(
                                error as? CompetitionRemoteFailure ?? .operationFailed
                            )))
                        }
                    }
                    .cancellable(id: CancelID.safety)
                )

            case let .blockFinished(person, result):
                guard state.inFlight.remove(person.id) != nil else { return .none }
                state.safetyInFlight.remove(person.id)
                switch result {
                case .success:
                    // Blocking ends the friendship and any request, and drops
                    // them from search.
                    state.apply(.none, to: person)
                    state.results?.removeAll { $0.id == person.id }
                case let .failure(failure):
                    state.fail(person, failure)
                }
                return state.inFlight.isEmpty ? .send(.requested) : .none

            case let .reportTapped(person, andBlock):
                guard state.inFlight.insert(person.id).inserted else { return .none }
                state.safetyInFlight.insert(person.id)
                state.failure = nil
                // As a block: Report and Block goes on to the block after
                // Friends closes.
                return .run { send in
                    do {
                        try await competitionClient.reportProfile(person.id)
                        await send(.reportFinished(person, andBlock: andBlock, failure: nil))
                    } catch {
                        await send(.reportFinished(
                            person,
                            andBlock: andBlock,
                            failure: error as? CompetitionRemoteFailure ?? .operationFailed
                        ))
                    }
                }
                .cancellable(id: CancelID.safety)

            case let .reportFinished(person, andBlock, failure):
                guard state.inFlight.remove(person.id) != nil else { return .none }
                state.safetyInFlight.remove(person.id)
                if let failure {
                    // Not blocked either: the report comes first, so Try Again
                    // does both.
                    state.fail(person, failure)
                    return .none
                }
                state.reported.insert(person.id)
                return andBlock ? .send(.blockTapped(person)) : .none

            case let .searchFocusRequested(focuses):
                state.focusesSearch = focuses
                return .none
            }
        }
    }
}
