import ComposableArchitecture
import Foundation

@Reducer
struct FriendsFeature {
    enum Change: Equatable, Sendable { case add, accept, decline, cancel, remove }

    enum ChangeFailure: Equatable, Sendable { case connection, unavailable, limit }

    enum SearchFailure: Equatable, Sendable { case rateLimited, connection }

    struct PersonFailure: Equatable, Sendable {
        let id: UUID
        let failure: ChangeFailure
    }

    struct State: Equatable {
        var list: FriendsList?
        var loadFailed = false
        var query = ""
        var searchGeneration = 0
        var results: [FriendPerson]?
        var isSearching = false
        var searchFailure: SearchFailure?
        var people: [UUID: FriendPerson] = [:]
        var inFlight: Set<UUID> = []
        var safetyInFlight: Set<UUID> = []
        var failure: PersonFailure?
        var reported: Set<UUID> = []
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
        case searchDebounced(String, generation: Int)
        case searchFinished(String, generation: Int, Result<[FriendPerson], CompetitionRemoteFailure>)
        case changeTapped(FriendPerson, Change)
        case changeFinished(FriendPerson, Result<FriendRelationship, CompetitionRemoteFailure>)
        case closed
        case blockTapped(FriendPerson)
        case blockFinished(FriendPerson, Result<AuthenticatedProfile, CompetitionRemoteFailure>)
        case reportTapped(FriendPerson, andBlock: Bool)
        case reportFinished(FriendPerson, andBlock: Bool, failure: CompetitionRemoteFailure?)
        case searchFocusRequested(Bool)
    }

    enum CancelID { case load, search, change, safety }

    static let searchDebounce = Duration.milliseconds(300)

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
                guard state.inFlight.isEmpty else { return .none }
                return .run { send in
                    await send(.loaded(try? await competitionClient.listFriends()))
                }
                .cancellable(id: CancelID.load, cancelInFlight: true)

            case let .loaded(list):
                if let list {
                    state.merge(list)
                } else if state.list == nil {
                    state.loadFailed = true
                }
                return .none

            case let .queryChanged(query):
                guard query != state.query else { return .none }
                state.query = query
                state.searchGeneration += 1
                state.searchFailure = nil
                guard let searchable = Self.searchableQuery(query) else {
                    state.results = nil
                    state.isSearching = false
                    return .cancel(id: CancelID.search)
                }
                state.isSearching = true
                let generation: Int = state.searchGeneration
                return .run { send in
                    try await clock.sleep(for: Self.searchDebounce)
                    await send(.searchDebounced(searchable, generation: generation))
                }
                .cancellable(id: CancelID.search)

            case let .searchDebounced(searchable, generation):
                guard generation == state.searchGeneration else { return .none }
                return .run { send in
                    do {
                        let people = try await competitionClient.searchPeople(searchable)
                        await send(.searchFinished(searchable, generation: generation, .success(people)))
                    } catch {
                        await send(.searchFinished(searchable, generation: generation, .failure(
                            error as? CompetitionRemoteFailure ?? .operationFailed
                        )))
                    }
                }
                .cancellable(id: CancelID.search)

            case let .searchFinished(_, generation, result):
                guard generation == state.searchGeneration else { return .none }
                state.isSearching = false
                switch result {
                case let .success(people):
                    state.results = people
                    state.people.merge(people.map { ($0.id, $0) }) { _, new in new }
                case .failure(.invalidQuery):
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
                guard state.inFlight.remove(person.id) != nil else { return .none }
                switch result {
                case let .success(relationship):
                    state.apply(relationship, to: person)
                case let .failure(failure):
                    state.fail(person, failure)
                }
                return state.inFlight.isEmpty ? .send(.requested) : .none

            case .closed:
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
