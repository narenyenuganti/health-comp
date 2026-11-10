import ComposableArchitecture
import XCTest

@testable import HealthComp

@MainActor
final class FriendsFeatureTests: XCTestCase {
    private typealias Feature = FriendsFeature

    private func person(
        _ byte: UInt8,
        _ name: String,
        _ relationship: FriendRelationship = .none
    ) -> FriendPerson {
        FriendPerson(
            id: UUID(uuidString: String(format: "aa000000-0000-4000-8000-0000000000%02x", byte))!,
            displayName: name,
            username: name.lowercased(),
            relationship: relationship
        )
    }

    private func makeStore(
        _ state: Feature.State = .init(),
        clock: any Clock<Duration> = ImmediateClock(),
        client configure: (inout CompetitionClient) -> Void = { _ in }
    ) -> TestStoreOf<Feature> {
        var client = CompetitionClient.testValue
        configure(&client)
        return TestStore(initialState: state) { Feature() } withDependencies: {
            $0.competitionClient = client
            $0.continuousClock = clock
        }
    }

    func testSearchableQueryMatchesTheServersRule() {
        XCTAssertNil(Feature.searchableQuery(""))
        XCTAssertNil(Feature.searchableQuery("ma"))
        XCTAssertNil(Feature.searchableQuery("  ma  "))
        XCTAssertNil(Feature.searchableQuery("@ma"))
        XCTAssertEqual(Feature.searchableQuery(" mar "), "mar")
        XCTAssertEqual(Feature.searchableQuery("@mar"), "@mar")
        // The server counts code points; this flag is two.
        XCTAssertEqual(Feature.searchableQuery("🇯🇵a"), "🇯🇵a")
    }

    func testLoadKeepsTheListOnAFailedRefresh() async {
        let list = FriendsList(incoming: [person(1, "Jordan", .incoming)])
        let answers = LockIsolated<[Result<FriendsList, CompetitionRemoteFailure>]>([
            .failure(.notFound), .success(list), .failure(.retryableTransport),
        ])
        let store = makeStore { client in
            client.listFriends = { try answers.withValue { $0.removeFirst() }.get() }
        }
        await store.send(.requested)
        await store.receive(.loaded(nil)) { $0.loadFailed = true }
        await store.send(.requested)
        await store.receive(.loaded(list)) {
            $0.list = list
            $0.loadFailed = false
            $0.people = [list.incoming[0].id: list.incoming[0]]
        }
        XCTAssertEqual(store.state.requestCount, 1)
        await store.send(.requested)
        await store.receive(.loaded(nil))
    }

    func testALoadDemotesAnyoneNoLongerOnTheLists() async {
        let friend = person(1, "Jordan", .friend)
        var demoted = friend
        demoted.relationship = .none
        var state = Feature.State(results: [friend])
        state.people = [friend.id: friend]
        let store = makeStore(state) { client in
            client.listFriends = { FriendsList() }
        }
        await store.send(.requested)
        await store.receive(.loaded(FriendsList())) {
            $0.list = FriendsList()
            $0.people = [friend.id: demoted]
            $0.results = [demoted]
        }
    }

    func testUnderThreeCharactersSearchesNothing() async {
        let store = makeStore()
        await store.send(.queryChanged("ma")) { $0.query = "ma" }
    }

    func testSearchWaitsForTheDebounceAndDropsStaleAnswers() async {
        let clock = TestClock()
        let searched = LockIsolated<[String]>([])
        let mara = person(1, "Mara")
        let store = makeStore(clock: clock) { client in
            client.searchPeople = { query in
                searched.withValue { $0.append(query) }
                return [mara]
            }
        }
        await store.send(.queryChanged("mar")) {
            $0.query = "mar"
            $0.isSearching = true
        }
        await clock.advance(by: .milliseconds(200))
        // Typing on cancels the wait, so "mar" is never sent.
        await store.send(.queryChanged("mara")) { $0.query = "mara" }
        await clock.advance(by: Feature.searchDebounce)
        await store.receive(.searchFinished("mara", .success([mara]))) {
            $0.isSearching = false
            $0.results = [mara]
            $0.people = [mara.id: mara]
        }
        XCTAssertEqual(searched.value, ["mara"])

        // An answer for what's no longer typed changes nothing.
        await store.send(.queryChanged("mat")) {
            $0.query = "mat"
            $0.isSearching = true
        }
        await store.send(.searchFinished("mara", .success([])))
        await store.send(.queryChanged("ma")) {
            $0.query = "ma"
            $0.isSearching = false
            $0.results = nil
        }
    }

    func testSearchFailuresReadAsTheirOwnStates() async {
        let answers = LockIsolated<[CompetitionRemoteFailure]>([
            .searchRateLimited, .invalidQuery, .retryableTransport,
        ])
        let store = makeStore { client in
            client.searchPeople = { _ in throw answers.withValue { $0.removeFirst() } }
        }
        await store.send(.queryChanged("abc")) {
            $0.query = "abc"
            $0.isSearching = true
        }
        await store.receive(.searchFinished("abc", .failure(.searchRateLimited))) {
            $0.isSearching = false
            $0.searchFailure = .rateLimited
        }
        await store.send(.queryChanged("abcd")) {
            $0.query = "abcd"
            $0.isSearching = true
            $0.searchFailure = nil
        }
        await store.receive(.searchFinished("abcd", .failure(.invalidQuery))) {
            $0.isSearching = false
            $0.results = []
        }
        await store.send(.queryChanged("abcde")) {
            $0.query = "abcde"
            $0.isSearching = true
        }
        await store.receive(.searchFinished("abcde", .failure(.retryableTransport))) {
            $0.isSearching = false
            $0.results = nil
            $0.searchFailure = .connection
        }
    }

    func testAddShowsRequestedEverywhereThenReloads() async {
        let marcus = person(1, "Marcus")
        var requested = marcus
        requested.relationship = .requested
        var state = Feature.State(list: FriendsList(), results: [marcus])
        state.people = [marcus.id: marcus]
        let sent = LockIsolated<[UUID]>([])
        let reloaded = FriendsList(outgoing: [requested])
        let store = makeStore(state) { client in
            client.sendFriendRequest = { id in
                sent.withValue { $0.append(id) }
                return .requested
            }
            client.listFriends = { reloaded }
        }
        await store.send(.changeTapped(marcus, .add)) { $0.inFlight = [marcus.id] }
        await store.receive(.changeFinished(marcus, .success(.requested))) {
            $0.inFlight = []
            $0.people = [marcus.id: requested]
            $0.results = [requested]
            $0.list = reloaded
        }
        await store.receive(.requested)
        await store.receive(.loaded(reloaded))
        XCTAssertEqual(sent.value, [marcus.id])
    }

    func testASecondTapWhileBusyIsIgnored() async {
        let marcus = person(1, "Marcus")
        var state = Feature.State(list: FriendsList())
        state.inFlight = [marcus.id]
        let store = makeStore(state)
        await store.send(.changeTapped(marcus, .add))
    }

    func testAcceptSortsThemIntoFriendsAndDropsTheRequest() async {
        let jordan = person(1, "Jordan", .incoming)
        let alex = person(2, "Alex", .friend), zoe = person(3, "Zoe", .friend)
        var accepted = jordan
        accepted.relationship = .friend
        let after = FriendsList(friends: [alex, accepted, zoe])
        let answers = LockIsolated<[(UUID, Bool)]>([])
        let store = makeStore(.init(list: FriendsList(friends: [alex, zoe], incoming: [jordan]))) { client in
            client.respondToFriendRequest = { id, accept in
                answers.withValue { $0.append((id, accept)) }
                return .friend
            }
            client.listFriends = { after }
        }
        await store.send(.changeTapped(jordan, .accept)) { $0.inFlight = [jordan.id] }
        await store.receive(.changeFinished(jordan, .success(.friend))) {
            $0.inFlight = []
            $0.people = [jordan.id: accepted]
            $0.list = after
        }
        await store.receive(.requested)
        await store.receive(.loaded(after)) {
            $0.people = [jordan.id: accepted, alex.id: alex, zoe.id: zoe]
        }
        XCTAssertEqual(answers.value.map(\.0), [jordan.id])
        XCTAssertEqual(answers.value.map(\.1), [true])
    }

    func testDeclineAndCancelBothLeaveNoRelationship() async {
        let jordan = person(1, "Jordan", .incoming)
        let mateo = person(2, "Mateo", .requested)
        var jordanNone = jordan
        jordanNone.relationship = .none
        var mateoNone = mateo
        mateoNone.relationship = .none
        let declined = LockIsolated<[Bool]>([])
        let removed = LockIsolated<[UUID]>([])
        let store = makeStore(.init(list: FriendsList(incoming: [jordan], outgoing: [mateo]))) { client in
            client.respondToFriendRequest = { _, accept in
                declined.withValue { $0.append(accept) }
                return .none
            }
            client.removeFriend = { id in
                removed.withValue { $0.append(id) }
                return .none
            }
            client.listFriends = { FriendsList() }
        }
        await store.send(.changeTapped(jordan, .decline)) { $0.inFlight = [jordan.id] }
        await store.receive(.changeFinished(jordan, .success(.none))) {
            $0.inFlight = []
            $0.people[jordan.id] = jordanNone
            $0.list = FriendsList(outgoing: [mateo])
        }
        await store.receive(.requested)
        await store.receive(.loaded(FriendsList())) {
            $0.list = FriendsList()
        }
        await store.send(.changeTapped(mateo, .cancel)) { $0.inFlight = [mateo.id] }
        await store.receive(.changeFinished(mateo, .success(.none))) {
            $0.inFlight = []
            $0.people[mateo.id] = mateoNone
        }
        await store.receive(.requested)
        await store.receive(.loaded(FriendsList()))
        XCTAssertEqual(declined.value, [false])
        XCTAssertEqual(removed.value, [mateo.id])
    }

    func testAFailedChangeLeavesThePersonAndSaysWhy() async {
        let cases: [(CompetitionRemoteFailure, Feature.ChangeFailure)] = [
            (.retryableTransport, .connection),
            (.recipientUnavailable, .unavailable),
            (.requestUnavailable, .unavailable),
            (.friendRequestLimit, .limit),
        ]
        let marcus = person(1, "Marcus")
        for (error, expected) in cases {
            var state = Feature.State(list: FriendsList(), results: [marcus])
            state.people = [marcus.id: marcus]
            let store = makeStore(state) { client in
                client.sendFriendRequest = { _ in throw error }
                client.listFriends = { FriendsList() }
            }
            await store.send(.changeTapped(marcus, .add)) { $0.inFlight = [marcus.id] }
            await store.receive(.changeFinished(marcus, .failure(error))) {
                $0.inFlight = []
                $0.failure = Feature.PersonFailure(id: marcus.id, failure: expected)
            }
            await store.receive(.requested)
            await store.receive(.loaded(FriendsList()))
            XCTAssertEqual(store.state.results, [marcus], "Rolled back")
            XCTAssertEqual(store.state.failure(for: marcus.id), expected)
            XCTAssertNil(store.state.failure(for: UUID()))
        }
    }

    func testALateAnswerAfterSignOutIsIgnored() async {
        let marcus = person(1, "Marcus")
        let store = makeStore()
        await store.send(.changeFinished(marcus, .success(.requested)))
    }

    func testPhotoOwnersAreYouTheListsAndTheResultsCappedForTheServer() {
        let own = AuthenticatedProfile(id: UUID(), displayName: "Alice")
        let friend = person(1, "Jordan", .friend)
        let requester = person(2, "Priya", .incoming)
        let result = person(3, "Marcus")
        var state = CompetitionFeature.State(publication: LocalCompetitionPublication(
            publicationRevision: 1,
            dashboard: LocalCompetitionDashboard(
                competitions: [],
                awards: [],
                issues: [],
                hiddenTerminalCompetitionCount: 0
            ),
            source: .remoteParticipants
        ))
        state.ownProfile = own
        state.friends.list = FriendsList(friends: [friend], incoming: [requester])
        state.friends.results = [result, friend]
        XCTAssertEqual(Set(state.photoOwners), [own.id, friend.id, requester.id, result.id])
        XCTAssertEqual(state.photoOwners.count, 4, "Each owner once")

        state.friends.list?.friends = (0..<300).map { _ in
            FriendPerson(id: UUID(), displayName: "F", username: nil, relationship: .friend)
        }
        XCTAssertEqual(state.photoOwners.count, CompetitionFeature.maxPhotoOwners)
        XCTAssertTrue(state.photoOwners.contains(own.id))
        XCTAssertTrue(state.photoOwners.contains(requester.id), "On screen before the long list")
        XCTAssertTrue(state.photoOwners.contains(result.id))
    }

    func testSignOutForgetsEveryone() async {
        let friend = person(1, "Jordan", .friend)
        var initial = CompetitionFeature.State()
        initial.friends = Feature.State(list: FriendsList(friends: [friend]), query: "jor", results: [friend])
        let store = TestStore(initialState: initial) { CompetitionFeature() } withDependencies: {
            $0.competitionClient = CompetitionClient.testValue
            $0.competitionClient.stop = {}
        }
        await store.send(.stop) {
            $0.friends = Feature.State()
        }
    }
}
