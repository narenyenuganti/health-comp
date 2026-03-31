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
        }
        store.exhaustivity = .off

        await store.send(\.acceptRequestTapped, friendshipId)
        await store.skipReceivedActions()

        XCTAssertEqual(store.state.friends.count, 1)
        XCTAssertEqual(store.state.pendingRequests.count, 0)
    }
}
