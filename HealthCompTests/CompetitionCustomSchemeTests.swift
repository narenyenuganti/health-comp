import CompetitionCore
import Foundation
import XCTest
@testable import HealthComp

final class CompetitionCustomSchemeTests: XCTestCase {
    #if HEALTHCOMP_STAGING
    private let ownScheme = "healthcomp-staging"
    private let otherScheme = "healthcomp"
    #else
    private let ownScheme = "healthcomp"
    private let otherScheme = "healthcomp-staging"
    #endif

    func testInviteURLsOnlyRouteToTheirOwnEnvironment() throws {
        let rawToken = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let token = try XCTUnwrap(
            CompetitionInviteClaimToken(rawValue: rawToken)
        )

        XCTAssertEqual(
            CompetitionRoute(url: URL(string: "\(ownScheme)://invite/\(rawToken)")!),
            .claimInvite(token)
        )
        XCTAssertNil(
            CompetitionRoute(url: URL(string: "\(otherScheme)://invite/\(rawToken)")!)
        )
    }

    func testFallbackShareLinkUsesItsOwnEnvironmentScheme() throws {
        let rawToken = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
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

        XCTAssertEqual(link.url.absoluteString, "\(ownScheme)://invite/\(rawToken)")
        XCTAssertEqual(
            CompetitionRoute(url: link.url),
            .claimInvite(try XCTUnwrap(CompetitionInviteClaimToken(rawValue: rawToken)))
        )
        XCTAssertFalse(String(describing: link).contains(rawToken))
    }

    func testCompetitionLinksAndNotificationPayloadStayInTheirEnvironment() throws {
        let rawID = "ead172f8-531d-4327-823d-e82a4f696050"
        let route = CompetitionRoute.competition(
            CompetitionID(try XCTUnwrap(UUID(uuidString: rawID)))
        )

        XCTAssertEqual(
            CompetitionRoute(url: URL(string: "\(ownScheme)://competition/\(rawID)")!),
            route
        )
        XCTAssertNil(
            CompetitionRoute(url: URL(string: "\(otherScheme)://competition/\(rawID)")!)
        )
        XCTAssertEqual(CompetitionRoute(userInfo: route.userInfo), route)
    }

    func testMalformedEnvironmentInviteLinksAreRejected() {
        let token = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        for value in [
            "\(ownScheme)://invite/\(token)?score=600",
            "\(ownScheme)://invite/\(token)#extra",
            "\(ownScheme)://invite/\(token)/extra",
            "\(ownScheme)://user@invite/\(token)",
            "\(ownScheme)://invite:443/\(token)",
            "\(ownScheme)://invite/short",
        ] {
            XCTAssertNil(CompetitionRoute(url: URL(string: value)!))
        }
    }
}
