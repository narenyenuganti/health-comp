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

    func testStrictFallbackInviteURLParsesWithoutExposingTokenDescription() {
        let token = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let route = CompetitionRoute(
            url: URL(string: "healthcomp://invite/\(token)")!
        )

        guard case let .claimInvite(parsedToken) = route else {
            return XCTFail("Expected a private invite-claim route")
        }
        XCTAssertEqual(parsedToken.rawValue, token)
        XCTAssertFalse(String(describing: parsedToken).contains(token))
        XCTAssertFalse(String(reflecting: parsedToken).contains(token))
    }

    func testLinkClientBuildsFallbackInviteURLWhenExplicitlyEnabled() throws {
        let rawToken = "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"
        let token = try XCTUnwrap(
            CompetitionInviteClaimToken(rawValue: rawToken)
        )
        let configuration = CompetitionInviteLinkConfiguration(
            infoDictionary: [
                "HEALTHCOMP_INVITE_HOST": "",
                "HEALTHCOMP_ALLOW_CUSTOM_INVITE_SCHEME": "YES",
            ]
        )

        let link = try XCTUnwrap(
            CompetitionInviteLinkClient.live(configuration: configuration)
                .makeShareLink(rawToken)
        )

        XCTAssertEqual(
            link.url.absoluteString,
            "healthcomp://invite/\(rawToken)"
        )
        XCTAssertEqual(CompetitionRoute(url: link.url), .claimInvite(token))
        XCTAssertFalse(String(describing: link).contains(rawToken))
        XCTAssertFalse(String(reflecting: link).contains(rawToken))
    }

    func testLinkClientFailsClosedWithoutHostOrFallbackOptIn() {
        let rawToken = "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"
        let configuration = CompetitionInviteLinkConfiguration(
            infoDictionary: [
                "HEALTHCOMP_INVITE_HOST": "",
                "HEALTHCOMP_ALLOW_CUSTOM_INVITE_SCHEME": "NO",
            ]
        )

        XCTAssertNil(
            CompetitionInviteLinkClient.live(configuration: configuration)
                .makeShareLink(rawToken)
        )
    }

    func testFallbackInviteURLRejectsMalformedOrDataBearingTokens() {
        let token = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let invalid = [
            "healthcomp://invite/short",
            "healthcomp://invite/\(token)/extra",
            "healthcomp://invite/\(token)/",
            "healthcomp://invite/\(token)?source=message",
            "healthcomp://invite/\(token)#claim",
            "healthcomp://user@invite/\(token)",
            "healthcomp://invite:443/\(token)",
        ]

        for value in invalid {
            XCTAssertNil(CompetitionRoute(url: URL(string: value)!))
        }
    }

    func testStrictHTTPSInviteURLRequiresExactConfiguredHost() {
        let token = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let route = CompetitionRoute(
            url: URL(
                string: "https://invites.healthcomp.example/invite/\(token)"
            )!,
            allowedInviteHost: "invites.healthcomp.example"
        )

        guard case let .claimInvite(parsedToken) = route else {
            return XCTFail("Expected an HTTPS invite-claim route")
        }
        XCTAssertEqual(parsedToken.rawValue, token)
    }

    func testHTTPSInviteURLRejectsWrongAuthorityOrExtraData() {
        let token = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let invalid = [
            "http://invites.healthcomp.example/invite/\(token)",
            "https://other.healthcomp.example/invite/\(token)",
            "https://user@invites.healthcomp.example/invite/\(token)",
            "https://invites.healthcomp.example:443/invite/\(token)",
            "https://invites.healthcomp.example/Invite/\(token)",
            "https://invites.healthcomp.example/invite/\(token)/",
            "https://invites.healthcomp.example/invite/\(token)?source=text",
            "https://invites.healthcomp.example/invite/\(token)#claim",
        ]

        for value in invalid {
            XCTAssertNil(
                CompetitionRoute(
                    url: URL(string: value)!,
                    allowedInviteHost: "invites.healthcomp.example"
                )
            )
        }
    }

    func testInviteShareLinkUsesHTTPSAndRedactsEveryStringRepresentation() {
        let token = try! XCTUnwrap(
            CompetitionInviteClaimToken(
                rawValue: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            )
        )
        let link = try! XCTUnwrap(
            CompetitionInviteShareLink(
                host: "invites.healthcomp.example",
                token: token
            )
        )

        XCTAssertEqual(
            link.url.absoluteString,
            "https://invites.healthcomp.example/invite/"
                + token.rawValue
        )
        XCTAssertFalse(String(describing: link).contains(token.rawValue))
        XCTAssertFalse(String(reflecting: link).contains(token.rawValue))
        XCTAssertNil(
            CompetitionInviteShareLink(host: "", token: token)
        )
        XCTAssertNil(
            CompetitionInviteShareLink(
                host: "INVITES.healthcomp.example",
                token: token
            )
        )
    }

    func testInviteHostRejectsEmbeddedOrTrailingLineBreaks() {
        XCTAssertFalse(
            CompetitionInviteHost.isValid(
                "invites.healthcomp.example\n"
            )
        )
        XCTAssertFalse(
            CompetitionInviteHost.isValid(
                "invites.healthcomp\n.example"
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

    func testRemoteNotificationPayloadAllowsOnlyAppleAPSAddition() {
        let route = CompetitionRoute.competition(
            CompetitionID(
                UUID(
                    uuidString: "EAD172F8-531D-4327-823D-E82A4F696051"
                )!
            )
        )
        var payload = route.userInfo
        payload["aps"] = [
            "alert": [
                "title": "HealthComp",
                "body": "Open HealthComp for your competition update.",
            ],
        ]

        XCTAssertEqual(CompetitionRoute(userInfo: payload), route)

        payload["unexpected"] = "value"
        XCTAssertNil(CompetitionRoute(userInfo: payload))
        payload["unexpected"] = nil
        payload["aps"] = "not-an-aps-dictionary"
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

    func testHubKeepsClaimAndNotificationPendingIndependently() async {
        let token = try! XCTUnwrap(
            CompetitionInviteClaimToken(
                rawValue: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            )
        )
        let competition = CompetitionRoute.competition(
            CompetitionID(
                UUID(uuidString: "EAD172F8-531D-4327-823D-E82A4F696056")!
            )
        )
        let hub = CompetitionRouteHub()
        let claimEnvelope = try! XCTUnwrap(
            hub.enqueue(.claimInvite(token))
        )
        let competitionEnvelope = try! XCTUnwrap(hub.enqueue(competition))
        var iterator = hub.stream().makeAsyncIterator()

        let firstReplay = await iterator.next()
        XCTAssertEqual(firstReplay, claimEnvelope)
        guard firstReplay == claimEnvelope else { return }
        let secondReplay = await iterator.next()
        XCTAssertEqual(secondReplay, competitionEnvelope)

        hub.consume(sequence: competitionEnvelope.sequence)
        var claimOnlyIterator = hub.stream().makeAsyncIterator()
        let remainingClaim = await claimOnlyIterator.next()
        XCTAssertEqual(remainingClaim, claimEnvelope)
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
