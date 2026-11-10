#if DEBUG
import CompetitionCore
import ComposableArchitecture
import XCTest
@testable import HealthComp

@MainActor
final class GroupMatchResultTests: XCTestCase {
    func testRematchEveryoneAsksTheParentForTheSameLineup() async {
        let id = GroupMatchFixtures.routed(.resultFFAWon)!.id
        let store = TestStore(initialState: GroupMatchFeature.State()) {
            GroupMatchFeature()
        }
        await store.send(.rematchEveryoneTapped(id))
        await store.receive(.delegate(.rematchEveryone(id)))
    }

    func testDoublesCanTieOnTheServersPlaces() {
        let match = GroupMatchFixtures.routed(.resultDoublesTied)!
        XCTAssertEqual(match.standingRows.map(\.place), [1, 1])
        XCTAssertEqual(Set(match.standingRows.map(\.centipoints)), [555_100])
    }

    func testHistoryListsOnlyFinishedGroupMatchesNewestFirst() {
        let live = GroupMatchFixtures.routed(.liveFFA)!
        let history = GroupMatchFixtures.history
        let finished = GroupMatchRecord.finished([live] + history.reversed())
        XCTAssertEqual(finished.map(\.id), history.map(\.id))
    }
}
#endif
