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
        await store.send(.queryChanged("ma")) {
            $0.query = "ma"
            $0.searchGeneration = 1
        }
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
            $0.searchGeneration = 1
            $0.isSearching = true
        }
        await clock.advance(by: .milliseconds(200))
        await store.send(.queryChanged("mara")) {
            $0.query = "mara"
            $0.searchGeneration = 2
        }
        await clock.advance(by: Feature.searchDebounce)
        // The wait for "mar" ends after "mara" was typed, so it's never sent.
        await store.receive(.searchDebounced("mar", generation: 1))
        await store.receive(.searchDebounced("mara", generation: 2))
        await store.receive(.searchFinished("mara", generation: 2, .success([mara]))) {
            $0.isSearching = false
            $0.results = [mara]
            $0.people = [mara.id: mara]
        }
        XCTAssertEqual(searched.value, ["mara"])

        // An answer for what's no longer typed changes nothing.
        await store.send(.queryChanged("mat")) {
            $0.query = "mat"
            $0.searchGeneration = 3
            $0.isSearching = true
        }
        await store.send(.searchFinished("mara", generation: 2, .success([])))
        await store.send(.queryChanged("ma")) {
            $0.query = "ma"
            $0.searchGeneration = 4
            $0.isSearching = false
            $0.results = nil
        }
    }

    func testAStaleDebounceSearchesNothing() async {
        // The test client fails the test if search is called.
        let store = makeStore(Feature.State(query: "mara", searchGeneration: 2, isSearching: true))
        await store.send(.searchDebounced("mar", generation: 1))
        await store.send(.queryChanged("ma")) {
            $0.query = "ma"
            $0.searchGeneration = 3
            $0.isSearching = false
        }
        await store.send(.searchDebounced("mar", generation: 1))
    }

    /// mar → marc → mar inside one wait: only the last edit searches, once,
    /// and an answer for the first visit to "mar" is never applied.
    func testReturningToEarlierTextSearchesOnceForTheLatestEdit() async {
        let clock = TestClock()
        let searched = LockIsolated<[String]>([])
        let mara = person(1, "Mara")
        let store = makeStore(clock: clock) { client in
            client.searchPeople = { query in
                searched.withValue { $0.append(query) }
                return [mara]
            }
        }
        store.exhaustivity = .off
        await store.send(.queryChanged("mar"))
        await clock.advance(by: .milliseconds(100))
        await store.send(.queryChanged("marc"))
        await clock.advance(by: .milliseconds(100))
        await store.send(.queryChanged("mar"))
        XCTAssertEqual(store.state.searchGeneration, 3)
        await clock.advance(by: Feature.searchDebounce)
        await store.skipReceivedActions()
        XCTAssertEqual(searched.value, ["mar"])
        XCTAssertFalse(store.state.isSearching)
        XCTAssertEqual(store.state.results, [mara])
    }

    func testAnAnswerFromAnEarlierEditOfTheSameTextChangesNothing() async {
        let store = makeStore(Feature.State(query: "mar", searchGeneration: 3, isSearching: true))
        await store.send(.searchFinished("mar", generation: 1, .success([person(1, "Mara")])))
        await store.send(.searchFinished("mar", generation: 1, .failure(.searchRateLimited)))
    }

    /// CI saw this: the field read "marc", the server only got "mar", and
    /// the spinner never stopped. An older keystroke's effect started after
    /// the newest one's, as a busy main thread allows, and cancelled it.
    func testAnOlderKeystrokeStartingLateStillSearchesWhatsTyped() async {
        let clock = TestClock()
        let searched = LockIsolated<[String]>([])
        let marcus = person(1, "Marcus")
        var client = CompetitionClient.testValue
        client.searchPeople = { query in
            searched.withValue { $0.append(query) }
            return [marcus]
        }
        let store = TestStore(initialState: Feature.State()) {
            StartsLate(late: .queryChanged("mar"), lag: .milliseconds(100))
        } withDependencies: {
            $0.competitionClient = client
            $0.continuousClock = clock
        }
        store.exhaustivity = .off
        await store.send(.queryChanged("mar"))
        await store.send(.queryChanged("marc"))
        await clock.advance(by: .milliseconds(100) + Feature.searchDebounce)
        await store.skipReceivedActions()
        XCTAssertEqual(searched.value, ["marc"])
        XCTAssertFalse(store.state.isSearching)
        XCTAssertEqual(store.state.results, [marcus])
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
            $0.searchGeneration = 1
            $0.isSearching = true
        }
        await store.receive(.searchDebounced("abc", generation: 1))
        await store.receive(.searchFinished("abc", generation: 1, .failure(.searchRateLimited))) {
            $0.isSearching = false
            $0.searchFailure = .rateLimited
        }
        await store.send(.queryChanged("abcd")) {
            $0.query = "abcd"
            $0.searchGeneration = 2
            $0.isSearching = true
            $0.searchFailure = nil
        }
        await store.receive(.searchDebounced("abcd", generation: 2))
        await store.receive(.searchFinished("abcd", generation: 2, .failure(.invalidQuery))) {
            $0.isSearching = false
            $0.results = []
        }
        await store.send(.queryChanged("abcde")) {
            $0.query = "abcde"
            $0.searchGeneration = 3
            $0.isSearching = true
        }
        await store.receive(.searchDebounced("abcde", generation: 3))
        await store.receive(.searchFinished("abcde", generation: 3, .failure(.retryableTransport))) {
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

    func testRemoveFriendEndsTheFriendship() async {
        let dev = person(1, "Dev", .friend)
        var devNone = dev
        devNone.relationship = .none
        let removed = LockIsolated<[UUID]>([])
        let store = makeStore(.init(list: FriendsList(friends: [dev]))) { client in
            client.removeFriend = { id in
                removed.withValue { $0.append(id) }
                return .none
            }
            client.listFriends = { FriendsList() }
        }
        await store.send(.changeTapped(dev, .remove)) { $0.inFlight = [dev.id] }
        await store.receive(.changeFinished(dev, .success(.none))) {
            $0.inFlight = []
            $0.people[dev.id] = devNone
            $0.list = FriendsList()
        }
        await store.receive(.requested)
        await store.receive(.loaded(FriendsList()))
        XCTAssertEqual(removed.value, [dev.id])
    }

    func testBlockByProfileDropsThemFromTheListsAndSearch() async {
        let dev = person(1, "Dev", .friend)
        var devNone = dev
        devNone.relationship = .none
        let blocked = LockIsolated<[UUID]>([])
        var state = Feature.State(list: FriendsList(friends: [dev]), results: [dev])
        state.people = [dev.id: dev]
        let store = makeStore(state) { client in
            client.blockProfile = { id in
                blocked.withValue { $0.append(id) }
                return AuthenticatedProfile(id: id, displayName: "Dev")
            }
            client.listFriends = { FriendsList() }
        }
        await store.send(.blockTapped(dev)) {
            $0.inFlight = [dev.id]
            $0.safetyInFlight = [dev.id]
        }
        await store.receive(.blockFinished(dev, .success(AuthenticatedProfile(id: dev.id, displayName: "Dev")))) {
            $0.inFlight = []
            $0.safetyInFlight = []
            $0.people[dev.id] = devNone
            $0.list = FriendsList()
            $0.results = []
        }
        await store.receive(.requested)
        await store.receive(.loaded(FriendsList()))
        XCTAssertEqual(blocked.value, [dev.id])
    }

    func testAFailedBlockKeepsThemAndSaysWhy() async {
        let dev = person(1, "Dev", .friend)
        for (error, expected) in [
            (CompetitionRemoteFailure.retryableTransport, Feature.ChangeFailure.connection),
            (.recipientUnavailable, .unavailable),
        ] {
            let store = makeStore(.init(list: FriendsList(friends: [dev]))) { client in
                client.blockProfile = { _ in throw error }
                client.listFriends = { FriendsList(friends: [dev]) }
            }
            await store.send(.blockTapped(dev)) {
                $0.inFlight = [dev.id]
                $0.safetyInFlight = [dev.id]
            }
            await store.receive(.blockFinished(dev, .failure(error))) {
                $0.inFlight = []
                $0.safetyInFlight = []
                $0.failure = Feature.PersonFailure(id: dev.id, failure: expected)
            }
            await store.receive(.requested)
            await store.receive(.loaded(FriendsList(friends: [dev]))) {
                $0.people = [dev.id: dev]
            }
        }
    }

    func testReportOnlyReportsAndIsRemembered() async {
        let dev = person(1, "Dev", .friend)
        let calls = LockIsolated<[String]>([])
        let store = makeStore(.init(list: FriendsList(friends: [dev]))) { client in
            client.reportProfile = { _ in calls.withValue { $0.append("report") } }
        }
        await store.send(.reportTapped(dev, andBlock: false)) {
            $0.inFlight = [dev.id]
            $0.safetyInFlight = [dev.id]
        }
        await store.receive(.reportFinished(dev, andBlock: false, failure: nil)) {
            $0.inFlight = []
            $0.safetyInFlight = []
            $0.reported = [dev.id]
        }
        XCTAssertEqual(calls.value, ["report"])
    }

    func testReportAndBlockReportsFirstThenBlocks() async {
        let dev = person(1, "Dev", .friend)
        var devNone = dev
        devNone.relationship = .none
        let profile = AuthenticatedProfile(id: dev.id, displayName: "Dev")
        let calls = LockIsolated<[String]>([])
        let store = makeStore(.init(list: FriendsList(friends: [dev]))) { client in
            client.reportProfile = { _ in calls.withValue { $0.append("report") } }
            client.blockProfile = { id in
                calls.withValue { $0.append("block") }
                return AuthenticatedProfile(id: id, displayName: "Dev")
            }
            client.listFriends = { FriendsList() }
        }
        await store.send(.reportTapped(dev, andBlock: true)) {
            $0.inFlight = [dev.id]
            $0.safetyInFlight = [dev.id]
        }
        await store.receive(.reportFinished(dev, andBlock: true, failure: nil)) {
            $0.inFlight = []
            $0.safetyInFlight = []
            $0.reported = [dev.id]
        }
        await store.receive(.blockTapped(dev)) {
            $0.inFlight = [dev.id]
            $0.safetyInFlight = [dev.id]
        }
        await store.receive(.blockFinished(dev, .success(profile))) {
            $0.inFlight = []
            $0.safetyInFlight = []
            $0.people[dev.id] = devNone
            $0.list = FriendsList()
        }
        await store.receive(.requested)
        await store.receive(.loaded(FriendsList()))
        XCTAssertEqual(calls.value, ["report", "block"])
    }

    func testAFailedReportDoesNotBlock() async {
        let dev = person(1, "Dev", .friend)
        let store = makeStore(.init(list: FriendsList(friends: [dev]))) { client in
            client.reportProfile = { _ in throw CompetitionRemoteFailure.retryableTransport }
            // blockProfile stays unimplemented: a call would fail the test.
        }
        await store.send(.reportTapped(dev, andBlock: true)) {
            $0.inFlight = [dev.id]
            $0.safetyInFlight = [dev.id]
        }
        await store.receive(.reportFinished(dev, andBlock: true, failure: .retryableTransport)) {
            $0.inFlight = []
            $0.safetyInFlight = []
            $0.failure = Feature.PersonFailure(id: dev.id, failure: .connection)
        }
    }

    // The server applies each call a second before its answer arrives, so
    // closing Friends in between is the case that loses a receipt.
    private func makeSlowSafetyStore(
        _ dev: FriendPerson,
        clock: TestClock<Duration>,
        calls: LockIsolated<[String]>,
        reportFails: Bool = false,
        blockFailures: Int = 0
    ) -> TestStoreOf<Feature> {
        let blockFailuresLeft = LockIsolated<Int>(blockFailures)
        let isBlocked = LockIsolated<Bool>(false)
        return makeStore(.init(list: FriendsList(friends: [dev])), clock: clock) { client in
            client.reportProfile = { _ in
                if !reportFails { calls.withValue { $0.append("report") } }
                try await clock.sleep(for: .seconds(1))
                if reportFails { throw CompetitionRemoteFailure.retryableTransport }
            }
            client.blockProfile = { id in
                let fails: Bool = blockFailuresLeft.withValue { left in
                    defer { left -= 1 }
                    return left > 0
                }
                if !fails {
                    calls.withValue { $0.append("block") }
                    isBlocked.setValue(true)
                }
                try await clock.sleep(for: .seconds(1))
                if fails { throw CompetitionRemoteFailure.retryableTransport }
                return AuthenticatedProfile(id: id, displayName: dev.displayName)
            }
            client.listFriends = {
                isBlocked.value ? FriendsList() : FriendsList(friends: [dev])
            }
        }
    }

    func testClosingDuringReportAndBlockStillReportsThenBlocks() async {
        let clock = TestClock()
        let dev = person(1, "Dev", .friend)
        var devNone = dev
        devNone.relationship = .none
        let profile = AuthenticatedProfile(id: dev.id, displayName: "Dev")
        let calls = LockIsolated<[String]>([])
        let store = makeSlowSafetyStore(dev, clock: clock, calls: calls)
        await store.send(.reportTapped(dev, andBlock: true)) {
            $0.inFlight = [dev.id]
            $0.safetyInFlight = [dev.id]
        }
        // Closing keeps the report's in-flight mark and its effect.
        await store.send(.closed)
        await clock.advance(by: .seconds(1))
        await store.receive(.reportFinished(dev, andBlock: true, failure: nil)) {
            $0.inFlight = []
            $0.safetyInFlight = []
            $0.reported = [dev.id]
        }
        await store.receive(.blockTapped(dev)) {
            $0.inFlight = [dev.id]
            $0.safetyInFlight = [dev.id]
        }
        await clock.advance(by: .seconds(1))
        await store.receive(.blockFinished(dev, .success(profile))) {
            $0.inFlight = []
            $0.safetyInFlight = []
            $0.people[dev.id] = devNone
            $0.list = FriendsList()
        }
        await store.receive(.requested)
        await store.receive(.loaded(FriendsList()))
        XCTAssertEqual(calls.value, ["report", "block"])
    }

    func testClosingDuringABlockKeepsItsAnswer() async {
        let clock = TestClock()
        let dev = person(1, "Dev", .friend)
        var devNone = dev
        devNone.relationship = .none
        let profile = AuthenticatedProfile(id: dev.id, displayName: "Dev")
        let calls = LockIsolated<[String]>([])
        let store = makeSlowSafetyStore(dev, clock: clock, calls: calls)
        await store.send(.blockTapped(dev)) {
            $0.inFlight = [dev.id]
            $0.safetyInFlight = [dev.id]
        }
        await store.send(.closed)
        await clock.advance(by: .seconds(1))
        await store.receive(.blockFinished(dev, .success(profile))) {
            $0.inFlight = []
            $0.safetyInFlight = []
            $0.people[dev.id] = devNone
            $0.list = FriendsList()
        }
        await store.receive(.requested)
        await store.receive(.loaded(FriendsList()))
        XCTAssertEqual(calls.value, ["block"])
    }

    func testReportSavedThenBlockFailsKeepsTheReportAndBlockCanBeRetried() async {
        let clock = TestClock()
        let dev = person(1, "Dev", .friend)
        var devNone = dev
        devNone.relationship = .none
        let profile = AuthenticatedProfile(id: dev.id, displayName: "Dev")
        let calls = LockIsolated<[String]>([])
        let store = makeSlowSafetyStore(dev, clock: clock, calls: calls, blockFailures: 1)
        await store.send(.reportTapped(dev, andBlock: true)) {
            $0.inFlight = [dev.id]
            $0.safetyInFlight = [dev.id]
        }
        await store.send(.closed)
        await clock.advance(by: .seconds(1))
        await store.receive(.reportFinished(dev, andBlock: true, failure: nil)) {
            $0.inFlight = []
            $0.safetyInFlight = []
            $0.reported = [dev.id]
        }
        await store.receive(.blockTapped(dev)) {
            $0.inFlight = [dev.id]
            $0.safetyInFlight = [dev.id]
        }
        await clock.advance(by: .seconds(1))
        await store.receive(.blockFinished(dev, .failure(.retryableTransport))) {
            $0.inFlight = []
            $0.safetyInFlight = []
            $0.failure = Feature.PersonFailure(id: dev.id, failure: .connection)
        }
        // Still a friend, still reported.
        await store.receive(.requested)
        await store.receive(.loaded(FriendsList(friends: [dev]))) {
            $0.people = [dev.id: dev]
        }

        await store.send(.blockTapped(dev)) {
            $0.inFlight = [dev.id]
            $0.safetyInFlight = [dev.id]
            $0.failure = nil
        }
        await clock.advance(by: .seconds(1))
        await store.receive(.blockFinished(dev, .success(profile))) {
            $0.inFlight = []
            $0.safetyInFlight = []
            $0.people[dev.id] = devNone
            $0.list = FriendsList()
        }
        await store.receive(.requested)
        await store.receive(.loaded(FriendsList()))
        XCTAssertEqual(calls.value, ["report", "block"])
    }

    func testAReportThatFailsAfterClosingNeverBlocks() async {
        let clock = TestClock()
        let dev = person(1, "Dev", .friend)
        let calls = LockIsolated<[String]>([])
        let store = makeSlowSafetyStore(dev, clock: clock, calls: calls, reportFails: true)
        await store.send(.reportTapped(dev, andBlock: true)) {
            $0.inFlight = [dev.id]
            $0.safetyInFlight = [dev.id]
        }
        await store.send(.closed)
        await clock.advance(by: .seconds(1))
        await store.receive(.reportFinished(dev, andBlock: true, failure: .retryableTransport)) {
            $0.inFlight = []
            $0.safetyInFlight = []
            $0.failure = Feature.PersonFailure(id: dev.id, failure: .connection)
        }
        await clock.run()
        XCTAssertEqual(calls.value, [])
    }

    func testAFailedBlockAsksTheServerWhoIsBlocked() async {
        let dev = person(1, "Dev", .friend)
        let profile = AuthenticatedProfile(id: dev.id, displayName: "Dev")
        var initial = CompetitionFeature.State()
        initial.friends = Feature.State(list: FriendsList(friends: [dev]))
        initial.blockedPeople = []
        let store = TestStore(initialState: initial) { CompetitionFeature() } withDependencies: {
            $0.competitionClient = CompetitionClient.testValue
            // The block landed; only its answer was lost.
            $0.competitionClient.blockProfile = { _ in throw CompetitionRemoteFailure.retryableTransport }
            $0.competitionClient.loadBlockedProfiles = { [profile] }
            $0.competitionClient.listFriends = { FriendsList() }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.friends(.blockTapped(dev)))
        await store.receive(.blockedPeopleResponse([profile])) {
            $0.blockedPeople = [profile]
        }
        await store.finish()
    }

    func testTheMenuOffersCancelRequestAlwaysAndAddFriendOnlyOncePlayed() {
        typealias Menu = PersonFriendMenuItems
        XCTAssertEqual(Menu.requestItem(.requested, hasPlayed: false), .cancel)
        XCTAssertEqual(Menu.requestItem(.requested, hasPlayed: true), .cancel)
        XCTAssertEqual(Menu.requestItem(FriendRelationship.none, hasPlayed: true), .add)
        XCTAssertNil(Menu.requestItem(FriendRelationship.none, hasPlayed: false))
        XCTAssertNil(Menu.requestItem(.friend, hasPlayed: true))
        XCTAssertNil(Menu.requestItem(.incoming, hasPlayed: true))
        // Before the list loads, neither.
        XCTAssertNil(Menu.requestItem(nil, hasPlayed: true))
    }

    func testSearchPeopleFromTheChallengeSheetFocusesTheFieldOnce() async {
        let store = makeStore()
        await store.send(.searchFocusRequested(true)) { $0.focusesSearch = true }
        await store.send(.searchFocusRequested(false)) { $0.focusesSearch = false }
    }

    func testALateAnswerAfterSignOutIsIgnored() async {
        let marcus = person(1, "Marcus")
        let store = makeStore()
        await store.send(.changeFinished(marcus, .success(.requested)))
        await store.send(.blockFinished(marcus, .success(AuthenticatedProfile(id: marcus.id, displayName: "Marcus"))))
        await store.send(.reportFinished(marcus, andBlock: true, failure: nil))
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

        // A claim's sender joins after everyone else is counted, still capped.
        let sender = UUID()
        let withSender = state.photoOwners(claimSender: sender)
        XCTAssertEqual(withSender.count, CompetitionFeature.maxPhotoOwners)
        XCTAssertTrue(withSender.contains(sender), "On screen, so kept")
        XCTAssertTrue(withSender.contains(own.id))
        XCTAssertTrue(withSender.contains(requester.id))
        XCTAssertEqual(state.photoOwners(claimSender: own.id), state.photoOwners, "Each owner once")
        XCTAssertEqual(CompetitionFeature.State().photoOwners(claimSender: sender), [sender])
    }

    private func publication(_ revision: UInt64, _ source: CompetitionPublicationSource) -> LocalCompetitionPublication {
        LocalCompetitionPublication(
            publicationRevision: revision,
            dashboard: LocalCompetitionDashboard(
                competitions: [],
                awards: [],
                issues: [],
                hiddenTerminalCompetitionCount: 0
            ),
            source: source
        )
    }

    func testARealtimePublicationRefreshesFriendsOnceTheyreInUse() async {
        let jordan = person(1, "Jordan", .incoming)
        let list = FriendsList(incoming: [jordan])
        var initial = CompetitionFeature.State()
        initial.friends.list = FriendsList()
        let store = TestStore(initialState: initial) { CompetitionFeature() } withDependencies: {
            $0.competitionClient = CompetitionClient.testValue
            $0.competitionClient.listFriends = { list }
        }
        // A wakeup in the foreground: no navigation, no scene change.
        let first = publication(1, .remoteParticipants)
        await store.send(.publication(first)) { $0.publication = first }
        await store.receive(.friends(.requested))
        await store.receive(.friends(.loaded(list))) {
            $0.friends.list = list
            $0.friends.people = [jordan.id: jordan]
        }
        XCTAssertEqual(store.state.friends.requestCount, 1)
    }

    func testAPublicationLeavesFriendsAloneUntilTheyAreUsed() async {
        let store = TestStore(initialState: CompetitionFeature.State()) { CompetitionFeature() } withDependencies: {
            $0.competitionClient = CompetitionClient.testValue
        }
        let first = publication(1, .remoteParticipants)
        await store.send(.publication(first)) { $0.publication = first }
    }

    func testClosingStopsSearchAndChangesThenReloadsForTheBadge() async {
        let clock = TestClock()
        let marcus = person(1, "Marcus")
        let store = makeStore(clock: clock) { client in
            client.searchPeople = { _ in [marcus] }
            client.sendFriendRequest = { _ in try await Task.never() }
            client.listFriends = { FriendsList() }
        }
        await store.send(.queryChanged("mar")) {
            $0.query = "mar"
            $0.searchGeneration = 1
            $0.isSearching = true
        }
        await store.send(.changeTapped(marcus, .add)) { $0.inFlight = [marcus.id] }
        await store.send(.closed) {
            $0.query = ""
            $0.isSearching = false
            $0.inFlight = []
        }
        // The add may have landed before it was cancelled.
        await store.receive(.requested)
        await store.receive(.loaded(FriendsList())) { $0.list = FriendsList() }
        // The search never answers a closed screen.
        await clock.run()
    }

    func testClosingWithNothingChangingCancelsTheLoad() async {
        let store = makeStore { client in
            client.listFriends = { try await Task.never() }
        }
        await store.send(.requested)
        await store.send(.closed)
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

/// Friends, with the effect of one action starting only after the clock
/// moves `lag`.
private struct StartsLate: Reducer {
    let late: FriendsFeature.Action
    let lag: Duration
    @Dependency(\.continuousClock) var clock

    var body: some ReducerOf<FriendsFeature> {
        Reduce { state, action in
            let effect: Effect<FriendsFeature.Action> = FriendsFeature().reduce(into: &state, action: action)
            guard action == late else { return effect }
            let wait: Effect<FriendsFeature.Action> = .run { [clock, lag] _ in try? await clock.sleep(for: lag) }
            return .concatenate(wait, effect)
        }
    }
}
