import ComposableArchitecture
import XCTest
@testable import HealthComp

final class FriendsFeatureTests: XCTestCase {

    static let testUser = User(
        id: UUID(uuidString: "770e8400-e29b-41d4-a716-446655440000")!,
        username: "alex", displayName: "Alex", avatarURL: nil, bio: nil,
        cosmetics: .default, cpBalance: 100, cpLifetime: 500,
        privacy: .default, createdAt: Date()
    )

    static let testFriendship = Friendship(
        id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
        requesterId: UUID(uuidString: "660e8400-e29b-41d4-a716-446655440000")!,
        receiverId: UUID(uuidString: "770e8400-e29b-41d4-a716-446655440000")!,
        status: .accepted,
        createdAt: Date()
    )

    @MainActor
    func testLoadFriends() async {
        let friend = FriendWithProfile(friendship: Self.testFriendship, friendProfile: Self.testUser)

        let store = TestStore(initialState: FriendsFeature.State()) {
            FriendsFeature()
        } withDependencies: {
            $0.friendsClient.fetchFriends = { [friend] }
            $0.friendsClient.fetchPendingRequests = { [] }
            $0.friendsClient.fetchFriendActivity = { [] }
        }
        store.exhaustivity = .off

        await store.send(\.onAppear)
        await store.receive(\.friendsLoaded)
        await store.receive(\.pendingLoaded)

        XCTAssertEqual(store.state.friends.count, 1)
        XCTAssertEqual(store.state.friends.first?.friendProfile.username, "alex")
        XCTAssertFalse(store.state.isLoading)
    }

    @MainActor
    func testLoadFriendActivity() async {
        let friend = FriendWithProfile(friendship: Self.testFriendship, friendProfile: Self.testUser)
        let activity = FriendActivitySummary(
            friend: Self.testUser,
            latestRingSummary: ActivityRingSummary(
                id: UUID(),
                userId: Self.testUser.id,
                date: "2026-05-11",
                moveValue: 500,
                moveGoal: 500,
                exerciseValue: 30,
                exerciseGoal: 30,
                standValue: 12,
                standGoal: 12,
                source: .healthkit,
                syncedAt: Date(timeIntervalSince1970: 0)
            )
        )

        let store = TestStore(initialState: FriendsFeature.State()) {
            FriendsFeature()
        } withDependencies: {
            $0.friendsClient.fetchFriends = { [friend] }
            $0.friendsClient.fetchPendingRequests = { [] }
            $0.friendsClient.fetchFriendActivity = { [activity] }
        }
        store.exhaustivity = .off

        await store.send(\.onAppear)
        await store.receive(\.friendsLoaded)
        await store.receive(\.pendingLoaded)
        await store.receive(\.friendActivityLoaded)

        XCTAssertEqual(store.state.friendActivity.first?.friend.id, Self.testUser.id)
        XCTAssertEqual(store.state.friendActivity.first?.latestRingSummary?.appleActivityScore.points, 300)
    }

    @MainActor
    func testSearchByUsername() async {
        let store = TestStore(initialState: FriendsFeature.State()) {
            FriendsFeature()
        } withDependencies: {
            $0.friendsClient.searchByUsername = { _ in [Self.testUser] }
        }
        store.exhaustivity = .off

        await store.send(\.searchQueryChanged, "ale")
        await store.send(\.searchSubmitted)
        await store.receive(\.searchResults)

        XCTAssertEqual(store.state.searchResultUsers.count, 1)
        XCTAssertEqual(store.state.searchResultUsers.first?.username, "alex")
        XCTAssertFalse(store.state.isSearching)
    }

    @MainActor
    func testAcceptRequest() async {
        let friendshipId = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
        let friend = FriendWithProfile(friendship: Self.testFriendship, friendProfile: Self.testUser)

        var state = FriendsFeature.State()
        state.pendingRequests = [FriendWithProfile(
            friendship: Friendship(id: friendshipId, requesterId: Self.testUser.id, receiverId: UUID(), status: .pending, createdAt: Date()),
            friendProfile: Self.testUser
        )]

        let store = TestStore(initialState: state) {
            FriendsFeature()
        } withDependencies: {
            $0.friendsClient.acceptRequest = { _ in }
            $0.friendsClient.fetchFriends = { [friend] }
            $0.friendsClient.fetchPendingRequests = { [] }
            $0.friendsClient.fetchFriendActivity = { [] }
        }
        store.exhaustivity = .off

        await store.send(\.acceptRequestTapped, friendshipId)
        await store.skipReceivedActions()

        XCTAssertEqual(store.state.friends.count, 1)
        XCTAssertEqual(store.state.pendingRequests.count, 0)
    }

    @MainActor
    func testChallengeFriendCreatesSevenDayAppleActivityInvite() async {
        let competition = Competition(
            id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
            type: .oneVOne,
            modeName: "apple_activity",
            scoringFormula: .appleActivity,
            status: .pending,
            startDate: "2026-05-11",
            endDate: "2026-05-17",
            createdBy: UUID(uuidString: "660e8400-e29b-41d4-a716-446655440000")!,
            handicapEnabled: false,
            stakesText: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        var createdRequest: (
            type: CompetitionType,
            modeName: String,
            formula: ScoringFormula,
            duration: Int,
            opponentIds: [UUID]
        )?

        let store = TestStore(initialState: FriendsFeature.State()) {
            FriendsFeature()
        } withDependencies: {
            $0.competitionClient.createCompetition = { type, modeName, formula, duration, opponentIds in
                createdRequest = (type, modeName, formula, duration, opponentIds)
                return competition
            }
        }

        await store.send(\.challengeFriendTapped, Self.testUser.id) {
            $0.isCreatingChallenge = true
        }
        await store.receive(\.challengeCreated.success) {
            $0.isCreatingChallenge = false
            $0.lastCreatedCompetition = competition
        }

        XCTAssertEqual(createdRequest?.type, .oneVOne)
        XCTAssertEqual(createdRequest?.modeName, "apple_activity")
        XCTAssertEqual(createdRequest?.formula.kind, .appleActivity)
        XCTAssertEqual(createdRequest?.duration, AppleActivityScore.durationDays)
        XCTAssertEqual(createdRequest?.opponentIds, [Self.testUser.id])
    }
}
