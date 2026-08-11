import CompetitionCore
import Foundation
import XCTest
@testable import HealthComp

final class CompetitionRoutingTests: XCTestCase {
    func testStrictCanonicalURLParses() {
        let route = CompetitionRoute(
            url: URL(
                string: "healthcomp://competition/ead172f8-531d-4327-823d-e82a4f696050"
            )!
        )

        XCTAssertEqual(
            route,
            .competition(
                CompetitionID(
                    UUID(
                        uuidString: "EAD172F8-531D-4327-823D-E82A4F696050"
                    )!
                )
            )
        )
    }

    func testURLParserRejectsNonCanonicalOrDataBearingRoutes() {
        let invalid = [
            "healthcomp://competition/EAD172F8-531D-4327-823D-E82A4F696050",
            "healthcomp://competition/ead172f8-531d-4327-823d-e82a4f696050/extra",
            "healthcomp://competition/ead172f8-531d-4327-823d-e82a4f696050/",
            "healthcomp://competition/ead172f8-531d-4327-823d-e82a4f696050?score=600",
            "healthcomp://competition/ead172f8-531d-4327-823d-e82a4f696050#result",
            "healthcomp://user@competition/ead172f8-531d-4327-823d-e82a4f696050",
            "healthcomp://user:secret@competition/ead172f8-531d-4327-823d-e82a4f696050",
            "healthcomp://competition:443/ead172f8-531d-4327-823d-e82a4f696050",
            "https://competition/ead172f8-531d-4327-823d-e82a4f696050",
        ]

        for value in invalid {
            XCTAssertNil(CompetitionRoute(url: URL(string: value)!))
        }
    }

    func testNotificationPayloadContainsOnlyVersionedRouteFields() {
        let id = CompetitionID(
            UUID(uuidString: "EAD172F8-531D-4327-823D-E82A4F696051")!
        )
        let route = CompetitionRoute.competition(id)

        XCTAssertEqual(
            route.userInfo as NSDictionary,
            [
                "healthcomp.route.v": 1,
                "healthcomp.route.kind": "competition",
                "healthcomp.route.competitionID":
                    "ead172f8-531d-4327-823d-e82a4f696051",
            ] as NSDictionary
        )
        XCTAssertEqual(CompetitionRoute(userInfo: route.userInfo), route)
    }

    func testNotificationPayloadRejectsAnyExtraKeyIncludingNonStringKeys() {
        var payload: [AnyHashable: Any] = [
            "healthcomp.route.v": 1,
            "healthcomp.route.kind": "competition",
            "healthcomp.route.competitionID":
                "ead172f8-531d-4327-823d-e82a4f696051",
        ]
        payload[AnyHashable(7)] = "unexpected"

        XCTAssertNil(CompetitionRoute(userInfo: payload))
    }

    func testHubBuffersReplaysAndConsumesOnlyMatchingSequence() async {
        let hub = CompetitionRouteHub()
        let firstRoute = CompetitionRoute.competition(
            CompetitionID(
                UUID(uuidString: "EAD172F8-531D-4327-823D-E82A4F696052")!
            )
        )
        let secondRoute = CompetitionRoute.competition(
            CompetitionID(
                UUID(uuidString: "EAD172F8-531D-4327-823D-E82A4F696053")!
            )
        )
        let first = try! XCTUnwrap(hub.enqueue(firstRoute))
        let stream = hub.stream()
        var iterator = stream.makeAsyncIterator()

        let initiallyReplayed = await iterator.next()
        XCTAssertEqual(initiallyReplayed, first)
        hub.consume(sequence: first.sequence + 1)
        let replay = hub.stream()
        var replayIterator = replay.makeAsyncIterator()
        let replayedAfterMismatchedConsume = await replayIterator.next()
        XCTAssertEqual(replayedAfterMismatchedConsume, first)

        hub.consume(sequence: first.sequence)
        let second = try! XCTUnwrap(hub.enqueue(secondRoute))
        XCTAssertGreaterThan(second.sequence, first.sequence)
        let deliveredSecond = await iterator.next()
        XCTAssertEqual(deliveredSecond, second)
    }

    func testHubFailsClosedAtSequenceOverflowAndFinishesSubscribers() async {
        let hub = CompetitionRouteHub(initialSequence: UInt64.max - 1)
        let route = CompetitionRoute.competition(
            CompetitionID(
                UUID(uuidString: "EAD172F8-531D-4327-823D-E82A4F696054")!
            )
        )
        var iterator = hub.stream().makeAsyncIterator()

        let last = try! XCTUnwrap(hub.enqueue(route))
        XCTAssertEqual(last.sequence, UInt64.max)
        let deliveredLast = await iterator.next()
        XCTAssertEqual(deliveredLast, last)
        hub.consume(sequence: last.sequence)
        XCTAssertNil(hub.enqueue(route))
        let terminalValue = await iterator.next()
        XCTAssertNil(terminalValue)

        var lateIterator = hub.stream().makeAsyncIterator()
        let lateValue = await lateIterator.next()
        XCTAssertNil(lateValue)
    }

    func testExplicitFinishRejectsNewRoutesAndTerminatesStream() async {
        let hub = CompetitionRouteHub()
        var iterator = hub.stream().makeAsyncIterator()

        hub.finish()

        let terminalValue = await iterator.next()
        XCTAssertNil(terminalValue)
        XCTAssertNil(
            hub.enqueue(
                .competition(
                    CompetitionID(
                        UUID(
                            uuidString: "EAD172F8-531D-4327-823D-E82A4F696055"
                        )!
                    )
                )
            )
        )
    }

    func testRoutingEnvironmentKeepsLiveStateProcessRootedAndLabsIsolated() {
        let firstLab = CompetitionRoutingEnvironment.makeLab()
        let secondLab = CompetitionRoutingEnvironment.makeLab()

        XCTAssertTrue(
            CompetitionRoutingEnvironment.liveHub
                === CompetitionRoutingEnvironment.liveHub
        )
        XCTAssertFalse(firstLab.hub === secondLab.hub)
        XCTAssertFalse(firstLab.hub === CompetitionRoutingEnvironment.liveHub)
        XCTAssertFalse(secondLab.hub === CompetitionRoutingEnvironment.liveHub)
    }
}
