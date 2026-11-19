import CompetitionCore
import Foundation
import XCTest
@testable import HealthComp

final class CompetitionNotificationClientTests: XCTestCase {
    func testCommunicationPhotoRequiresCachedVisibleOpponent() throws {
        let you = UUID(), sam = UUID()
        let identity = RemoteCompetitionOpponentIdentity.identity(for: sam)
        let sender = try XCTUnwrap(CompetitionNotificationSender.judges(
            family: .opportunistic(.result), identity: identity, name: "Sam"
        ))
        let jpeg = Data([1, 2, 3])
        XCTAssertEqual(sender.permitted(ownProfileID: you, cachedJPEG: jpeg, isVisible: true)?.photoJPEG, jpeg)
        XCTAssertNil(sender.permitted(ownProfileID: you, cachedJPEG: nil, isVisible: true))
        XCTAssertNil(sender.permitted(ownProfileID: you, cachedJPEG: jpeg, isVisible: false), "Blocked or reported stays plain")
        XCTAssertNil(sender.permitted(ownProfileID: sam, cachedJPEG: jpeg, isVisible: true), "Never your own photo")
        XCTAssertNil(sender.permitted(ownProfileID: you, cachedJPEG: Data(), isVisible: true))
        XCTAssertNotNil(CompetitionNotificationSender.judges(family: .scheduled(.competitionEnded), identity: identity, name: "Sam"))
        XCTAssertNil(CompetitionNotificationSender.judges(family: .scheduled(.finalDay), identity: identity, name: "Sam"))
        XCTAssertNil(CompetitionNotificationSender.judges(family: .opportunistic(.result), identity: "local-opponent:v1:Sam", name: "Sam"))
    }

    func testPlainFallbackRetainsCopyRouteAndReactionActions() async {
        let id = CompetitionID(UUID()), recipient = UUID()
        let content = CompetitionNotificationContent(title: "The judges’ scorecards are in", body: "Open to hear the decision.")
        let request = await CompetitionNotificationClient.makeRequest(CompetitionImmediateNotificationRequest(
            identifier: "plain-fallback", content: content, route: .competition(id),
            reactionTarget: .result, recipientUserID: recipient,
            sender: CompetitionNotificationSender(profileID: UUID(), displayName: "Sam")
        ))
        XCTAssertEqual(request.content.title, content.title)
        XCTAssertEqual(request.content.body, content.body)
        XCTAssertEqual(CompetitionReactionAlert.route(userInfo: request.content.userInfo), .competition(id))
        XCTAssertEqual(request.content.categoryIdentifier, CompetitionReactionAlert.category(.result))
        XCTAssertEqual(request.content.userInfo[CompetitionReactionAlert.recipientKey] as? String, recipient.uuidString)
    }

    func testThreadIdentifierGroupsByMatch() {
        let id = CompetitionID(
            UUID(uuidString: "EAD172F8-531D-4327-823D-E82A4F696070")!
        )
        XCTAssertEqual(
            competitionNotificationThreadIdentifier(.competition(id)),
            "competition:ead172f8-531d-4327-823d-e82a4f696070"
        )
        XCTAssertEqual(competitionNotificationThreadIdentifier(nil), "competition-summary")
    }
}
