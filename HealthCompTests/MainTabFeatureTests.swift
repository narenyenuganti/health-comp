import CompetitionCore
import ComposableArchitecture
import XCTest
@testable import HealthComp

final class MainTabFeatureTests: XCTestCase {
    @MainActor
    func testInitialStateOwnsLocalCompetitionChild() {
        XCTAssertEqual(
            MainTabFeature.State(),
            MainTabFeature.State(competition: CompetitionFeature.State())
        )
    }

    @MainActor
    func testTaskForwardsToCompetitionChild() async {
        let recorder = MainTabLifecycleRecorder()
        let store = TestStore(initialState: MainTabFeature.State()) {
            MainTabFeature()
        } withDependencies: {
            $0.localCompetitionClient = recorder.client
        }

        await store.send(.task)
        await store.receive(.competition(.task))
        await store.finish()

        XCTAssertEqual(recorder.startCount, 1)
    }

    @MainActor
    func testScenePhaseForwardsOnlyActiveAndNeverStopsOnBackground() async {
        let recorder = MainTabLifecycleRecorder()
        let store = TestStore(initialState: MainTabFeature.State()) {
            MainTabFeature()
        } withDependencies: {
            $0.localCompetitionClient = recorder.client
        }

        await store.send(.scenePhaseChanged(.inactive))
        await store.send(.scenePhaseChanged(.background))
        await store.send(.scenePhaseChanged(.active))
        await store.receive(.competition(.sceneBecameActive))
        await store.finish()

        XCTAssertEqual(recorder.reconcileTriggers, [.foreground])
        XCTAssertEqual(recorder.stopCount, 0)
    }

    @MainActor
    func testTimeZoneChangeForwardsExactAction() async {
        let recorder = MainTabLifecycleRecorder()
        let store = TestStore(initialState: MainTabFeature.State()) {
            MainTabFeature()
        } withDependencies: {
            $0.localCompetitionClient = recorder.client
        }

        await store.send(.timeZoneChanged)
        await store.receive(.competition(.timeZoneChanged))
        await store.finish()

        XCTAssertEqual(recorder.reconcileTriggers, [.timeZoneChange])
    }

    @MainActor
    func testStopForwardsToCompetitionChild() async {
        let recorder = MainTabLifecycleRecorder()
        let store = TestStore(initialState: MainTabFeature.State()) {
            MainTabFeature()
        } withDependencies: {
            $0.localCompetitionClient = recorder.client
        }

        await store.send(.stop)
        await store.receive(.competition(.stop))
        await store.finish()

        XCTAssertEqual(recorder.stopCount, 1)
    }

    @MainActor
    func testColdRouteParksUntilCanonicalPublicationThenConsumesOnce()
        async {
        let id = competitionID("81000000-0000-0000-0000-000000000001")
        let routing = MainTabRoutingRecorder()
        let store = TestStore(initialState: MainTabFeature.State()) {
            MainTabFeature()
        } withDependencies: {
            $0.localCompetitionClient = MainTabLifecycleRecorder().client
            $0.competitionRoutingClient = routing.client
        }

        await store.send(.task)
        await store.receive(.competition(.task))
        let envelope = routing.enqueue(.competition(id))
        await store.receive(.routeReceived(envelope)) {
            $0.pendingRoute = envelope
        }

        let publication = publication(revision: 1, visibleID: id)
        await store.send(.competition(.publication(publication))) {
            $0.competition.publication = publication
            $0.pendingRoute = nil
            $0.path = [id]
            $0.lastHandledRouteSequence = envelope.sequence
        }
        XCTAssertEqual(routing.consumedSequences, [envelope.sequence])

        await store.send(.stop)
        await store.receive(.competition(.stop))
        await store.finish()
    }

    @MainActor
    func testWarmVisibleRouteReplacesPathAndDuplicateSequenceIsIgnored()
        async {
        let oldID = competitionID("81000000-0000-0000-0000-000000000002")
        let routedID = competitionID("81000000-0000-0000-0000-000000000003")
        let routing = MainTabRoutingRecorder()
        let visible = publication(
            revision: 4,
            visibleIDs: [oldID, routedID]
        )
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(publication: visible),
                path: [oldID]
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionRoutingClient = routing.client
        }
        let envelope = CompetitionRouteEnvelope(
            sequence: 9,
            route: .competition(routedID)
        )

        await store.send(.routeReceived(envelope)) {
            $0.path = [routedID]
            $0.lastHandledRouteSequence = 9
        }
        await store.send(.routeReceived(envelope))

        XCTAssertEqual(routing.consumedSequences, [9])
        await store.finish()
    }

    @MainActor
    func testArchivedRoutesWhileUnknownConsumesAtRoot() async {
        let archivedID = competitionID(
            "81000000-0000-0000-0000-000000000004"
        )
        let unknownID = competitionID(
            "81000000-0000-0000-0000-000000000005"
        )
        let routing = MainTabRoutingRecorder()
        let archived = publication(
            revision: 5,
            visibleID: archivedID,
            lifecycle: .archived(
                outcome: .win,
                basis: .stableAcrossPostBoundaryReads,
                completedAt: Date(timeIntervalSinceReferenceDate: 10),
                archivedAt: Date(timeIntervalSinceReferenceDate: 11)
            )
        )
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(publication: archived)
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionRoutingClient = routing.client
        }

        await store.send(
            .routeReceived(
                CompetitionRouteEnvelope(
                    sequence: 1,
                    route: .competition(archivedID)
                )
            )
        ) {
            $0.path = [archivedID]
            $0.lastHandledRouteSequence = 1
        }
        await store.send(
            .routeReceived(
                CompetitionRouteEnvelope(
                    sequence: 2,
                    route: .competition(unknownID)
                )
            )
        ) {
            $0.path = []
            $0.lastHandledRouteSequence = 2
        }

        XCTAssertEqual(routing.consumedSequences, [1, 2])
        await store.finish()
    }

    @MainActor
    func testCanonicalPublicationPrunesDeletedDestination() async {
        let id = competitionID("81000000-0000-0000-0000-000000000006")
        let first = publication(revision: 1, visibleID: id)
        let second = publication(revision: 2, visibleIDs: [])
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(publication: first),
                path: [id]
            )
        ) {
            MainTabFeature()
        }

        await store.send(.competition(.publication(second))) {
            $0.competition.publication = second
            $0.path = []
        }
        await store.finish()
    }

    private func publication(
        revision: UInt64,
        visibleID: CompetitionID,
        lifecycle: LocalCompetitionLifecyclePresentation = .scheduled
    ) -> LocalCompetitionPublication {
        publication(
            revision: revision,
            visibleIDs: [visibleID],
            lifecycle: lifecycle
        )
    }

    private func publication(
        revision: UInt64,
        visibleIDs: [CompetitionID],
        lifecycle: LocalCompetitionLifecyclePresentation = .scheduled
    ) -> LocalCompetitionPublication {
        LocalCompetitionPublication(
            publicationRevision: revision,
            dashboard: LocalCompetitionDashboard(
                competitions: visibleIDs.map {
                    LocalCompetitionPresentation(
                        id: $0,
                        ownerDisplayName: "Naren",
                        opponentDisplayName: "Alex",
                        lifecycle: lifecycle,
                        acceptedConfiguration: nil,
                        userPoints: 0,
                        opponentPoints: 0,
                        days: [],
                        currentDayOrdinal: nil,
                        lastRefresh: nil,
                        tally: nil,
                        terminalResult: nil
                    )
                },
                awards: [],
                issues: [],
                hiddenTerminalCompetitionCount: 0
            )
        )
    }

    private func competitionID(_ value: String) -> CompetitionID {
        CompetitionID(UUID(uuidString: value)!)
    }
}

private final class MainTabRoutingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let hub = CompetitionRouteHub()
    private var consumed: [UInt64] = []

    var consumedSequences: [UInt64] {
        lock.withLock { consumed }
    }

    var client: CompetitionRoutingClient {
        CompetitionRoutingClient(
            routes: { [hub] in hub.stream() },
            enqueue: { [hub] route in _ = hub.enqueue(route) },
            consume: { [weak self, hub] sequence in
                self?.lock.withLock { self?.consumed.append(sequence) }
                hub.consume(sequence: sequence)
            }
        )
    }

    func enqueue(_ route: CompetitionRoute) -> CompetitionRouteEnvelope {
        hub.enqueue(route)!
    }
}

private final class MainTabLifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var triggers: [ActivityRefreshTrigger] = []

    var startCount: Int {
        lock.withLock { starts }
    }

    var stopCount: Int {
        lock.withLock { stops }
    }

    var reconcileTriggers: [ActivityRefreshTrigger] {
        lock.withLock { triggers }
    }

    var client: LocalCompetitionClient {
        let publication = LocalCompetitionPublication(
            publicationRevision: 0,
            dashboard: LocalCompetitionDashboard(
                competitions: [],
                awards: [],
                issues: [],
                hiddenTerminalCompetitionCount: 0
            )
        )
        return LocalCompetitionClient(
            start: { [weak self] in
                self?.lock.withLock { self?.starts += 1 }
                return AsyncStream { $0.finish() }
            },
            updates: { AsyncStream { $0.finish() } },
            reconcileAll: { [weak self] trigger in
                self?.lock.withLock { self?.triggers.append(trigger) }
                return publication
            },
            accept: { _ in publication },
            decline: { _ in publication },
            archive: { _ in publication },
            rematch: { _ in publication },
            reinvite: { publication },
            waitUntil: { _ in },
            stop: { [weak self] in
                self?.lock.withLock { self?.stops += 1 }
            }
        )
    }
}
