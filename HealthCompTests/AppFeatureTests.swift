import ComposableArchitecture
import XCTest
@testable import HealthComp

final class AppFeatureTests: XCTestCase {
    @MainActor
    func testInitialStateBootsDirectlyIntoLocalMainTab() {
        let state = AppFeature.State()
        XCTAssertEqual(state, AppFeature.State(mainTab: MainTabFeature.State()))
        XCTAssertNil(state.mainTab.competition.publication)
    }

    @MainActor
    func testForwardsLocalCompetitionChildState() async {
        let value = LocalCompetitionPublication(
            publicationRevision: 7,
            dashboard: LocalCompetitionDashboard(
                competitions: [],
                awards: [],
                issues: [],
                hiddenTerminalCompetitionCount: 0
            )
        )
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }

        await store.send(.mainTab(.competition(.publication(value)))) {
            $0.mainTab.competition.publication = value
        }
    }

    @MainActor
    func testLocalLifecycleStartsAndStopsOnlyLocalClient() async {
        let harness = CompetitionReducerStreamHarness()
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.localCompetitionClient = harness.client
        }

        await store.send(.mainTab(.task))
        await store.receive(.mainTab(.competition(.task)))
        await harness.waitForActiveSubscriberCount(1)
        await store.send(.mainTab(.stop))
        await store.receive(.mainTab(.competition(.stop)))
        await store.finish()

        XCTAssertEqual(harness.startCount, 1)
        XCTAssertEqual(harness.stopCount, 1)
    }
}
