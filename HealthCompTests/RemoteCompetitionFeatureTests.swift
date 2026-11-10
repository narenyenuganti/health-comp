import CompetitionCore
import ComposableArchitecture
import Foundation
import XCTest
@testable import HealthComp

final class RemoteCompetitionFeatureTests: XCTestCase {
    private typealias Creation = CompetitionFeature.InviteCreation

    private static let recipient = AuthenticatedProfile(
        id: UUID(uuidString: "82000000-0000-4000-8000-000000000099")!,
        displayName: "Alexandria Catherine Montgomery-Wellington"
    )
    private static let host = "invites.healthcomp.example"

    @MainActor
    func testInvitationRequiresExplicitAccountResolutionAndClearsSelectionWhenCodeChanges() async {
        let recipient = Self.recipient
        var client = InviteCreationRecorder(results: []).client
        client.resolveInviteRecipient = { _ in recipient }
        let store = TestStore(initialState: CompetitionFeature.State()) { CompetitionFeature() }
            withDependencies: { $0.competitionClient = client }
        await store.send(.createInviteTapped)
        await store.send(.inviteRecipientCodeChanged(recipient.id.uuidString)) {
            $0.inviteRecipientCode = recipient.id.uuidString
        }
        await store.send(.findInviteRecipientTapped) { $0.inviteRecipientStatus = .lookingUp }
        await store.receive(.inviteRecipientResponse(recipient.id.uuidString, .success(.init(recipient)))) {
            $0.inviteRecipientStatus = .idle
            $0.inviteRecipient = .init(recipient)
        }
        // Native fields may send their unchanged value again when focus ends.
        await store.send(.inviteRecipientCodeChanged(recipient.id.uuidString))
        await store.send(.inviteRecipientCodeChanged("another code")) {
            $0.inviteRecipientCode = "another code"
            $0.inviteRecipient = nil
        }
        await store.send(.inviteRecipientResponse(recipient.id.uuidString, .success(.init(recipient))))
        await store.send(.createInviteTapped)
        await store.finish()
    }

    @MainActor
    func testInvalidAccountCodeNeverCreatesAnInvitation() async {
        let store = TestStore(initialState: CompetitionFeature.State()) { CompetitionFeature() }
        // An empty code does nothing.
        await store.send(.findInviteRecipientTapped)
        await store.send(.inviteRecipientCodeChanged("not-an-account-code")) {
            $0.inviteRecipientCode = "not-an-account-code"
        }
        await store.send(.findInviteRecipientTapped) { $0.inviteRecipientStatus = .invalidCode }
        await store.send(.inviteRecipientCodeChanged("00000000-0000-0000-0000-000000000000")) {
            $0.inviteRecipientCode = "00000000-0000-0000-0000-000000000000"
            $0.inviteRecipientStatus = .idle
        }
        await store.send(.findInviteRecipientTapped) { $0.inviteRecipientStatus = .invalidCode }
        await store.send(.createInviteTapped)
        await store.finish()
    }

    @MainActor
    func testOwnCodeRejectedWithoutLookup() async {
        let own = AuthenticatedProfile(
            id: UUID(uuidString: "82000000-0000-4000-8000-0000000000aa")!,
            displayName: "Naren"
        )
        let lookups = LockIsolated(0)
        var client = InviteCreationRecorder(results: []).client
        client.resolveInviteRecipient = { _ in
            lookups.withValue { $0 += 1 }
            return own
        }
        let store = TestStore(initialState: CompetitionFeature.State(ownProfile: own)) {
            CompetitionFeature()
        } withDependencies: { $0.competitionClient = client }
        let typed = own.id.uuidString.uppercased()
        await store.send(.inviteRecipientCodeChanged(typed)) { $0.inviteRecipientCode = typed }
        await store.send(.findInviteRecipientTapped) { $0.inviteRecipientStatus = .ownCode }
        XCTAssertEqual(lookups.value, 0)
        await store.finish()
    }

    @MainActor
    func testLookupFailureMapping() async {
        for (failure, expected) in [
            (CompetitionRemoteFailure.recipientUnavailable, CompetitionFeature.InviteRecipientStatus.notFound),
            (.notFound, .notFound),
            (.retryableTransport, .connectionFailed),
        ] {
            var client = InviteCreationRecorder(results: []).client
            client.resolveInviteRecipient = { _ in throw failure }
            let store = TestStore(initialState: CompetitionFeature.State()) { CompetitionFeature() }
                withDependencies: { $0.competitionClient = client }
            let code = Self.recipient.id.uuidString
            await store.send(.inviteRecipientCodeChanged(code)) { $0.inviteRecipientCode = code }
            await store.send(.findInviteRecipientTapped) { $0.inviteRecipientStatus = .lookingUp }
            await store.receive(.inviteRecipientResponse(Self.recipient.id.uuidString, .failure(failure))) {
                $0.inviteRecipientStatus = expected
            }
            await store.finish()
        }
    }

    @MainActor
    func testAcceptedCreationRetryDoesNotOfferConsumedInvitationLink() async throws {
        let id = CompetitionID(UUID())
        let key = UUID()
        let link = try Self.link("A")
        let store = TestStore(initialState: CompetitionFeature.State(
            publication: .remote(revision: 4, competitions: [Self.presentation(id)]),
            inviteCreations: [.sheet: Creation(recipient: .profile(Self.recipient.id), idempotencyKey: key, status: .creating)],
            inviteRecipient: .init(Self.recipient)
        )) { CompetitionFeature() }
        await store.send(.createInviteResponse(.sheet, idempotencyKey: key, .success(
            link: link, competitionID: id, expectedRevision: 4
        ))) {
            $0.inviteCreations[.sheet]?.status = .sent(id)
        }
        XCTAssertNil(store.state.inviteLinks[id])
        XCTAssertEqual(
            store.state.challengeSheetStatus,
            .sent(challengeID: id, challenge: Self.presentation(id), link: nil)
        )
        await store.finish()
    }

    @MainActor
    func testExpiredInvitationMissingFromNextDashboardClearsShareLink() async throws {
        let id = CompetitionID(UUID())
        let key = UUID()
        let link = try Self.link("B")
        let store = TestStore(initialState: CompetitionFeature.State(
            inviteCreations: [.sheet: Creation(recipient: .profile(Self.recipient.id), idempotencyKey: key, status: .creating)],
            inviteRecipient: .init(Self.recipient)
        )) { CompetitionFeature() }
        await store.send(.createInviteResponse(.sheet, idempotencyKey: key, .success(link: link, competitionID: id, expectedRevision: 4))) {
            $0.inviteLinks[id] = .ready(link, minimumRevision: 4)
            $0.inviteCreations[.sheet]?.status = .sent(id)
        }
        await store.send(.publication(.remote(revision: 3))) { $0.publication = .remote(revision: 3) }
        await store.send(.publication(.remote(revision: 4))) {
            $0.publication = .remote(revision: 4)
            $0.inviteLinks = [:]
        }
        await store.finish()
    }

    @MainActor
    func testPendingConflictRefreshesAndOffersExistingChallenge() async {
        let key = UUID()
        let recorder = InviteCreationRecorder(results: [.failure(.pendingInvitationExists)])
        let store = TestStore(initialState: CompetitionFeature.State(inviteRecipient: .init(Self.recipient))) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: [key])
        }
        await store.send(.createInviteTapped) {
            $0.inviteCreations[.sheet] = Creation(recipient: .profile(Self.recipient.id), idempotencyKey: key, status: .creating)
        }
        await store.receive(.createInviteResponse(.sheet, idempotencyKey: key, .failure(.pendingInvitationExists))) {
            $0.inviteCreations[.sheet]?.status = .failed(.alreadyPending)
        }
        await store.finish()
        XCTAssertEqual(recorder.requestCount, 1)
        XCTAssertEqual(recorder.reconcileTriggers, [.pullToRefresh])
        XCTAssertEqual(store.state.challengeSheetStatus, .failed(.alreadyPending))

        let existing = Self.pending(CompetitionID(UUID()), identity: Self.recipientIdentity)
        let publication = CompetitionPublication.remote(revision: 1, competitions: [existing])
        await store.send(.publication(publication)) { $0.publication = publication }
        XCTAssertEqual(store.state.challengeSheetStatus, .alreadyChallenged(existing))
        // Create isn't offered, so it can't send a second request.
        await store.send(.createInviteTapped)
        XCTAssertEqual(recorder.requestCount, 1)
    }

    @MainActor
    func testLinkRecipientCreatesByCodeAndAResetLinkIsNotFound() async throws {
        let key = UUID()
        let code = try XCTUnwrap(CompetitionChallengeLinkCode(rawValue: "Xb3kP9qL2mN8vR4tY6wZ1a"))
        let maya = CompetitionFeature.InviteRecipient(link: code, displayName: "Maya")
        let recorder = InviteCreationRecorder(results: [.failure(.recipientUnavailable)])
        let store = TestStore(initialState: CompetitionFeature.State(inviteRecipient: maya)) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: [key])
        }
        await store.send(.createInviteTapped) {
            $0.inviteCreations[.sheet] = Creation(recipient: .challengeLink(code), idempotencyKey: key, status: .creating)
        }
        // Reset since it was opened: the same answer as any unknown link.
        await store.receive(.createInviteResponse(.sheet, idempotencyKey: key, .failure(.recipientUnavailable))) {
            $0.inviteCreations[.sheet] = nil
            $0.inviteRecipient = nil
            $0.inviteRecipientStatus = .notFound
        }
        await store.finish()
        XCTAssertEqual(recorder.requests.first?.recipient, .challengeLink(code))
        XCTAssertNil(recorder.requests.first?.recipientProfileID)
        XCTAssertNil(recorder.requests.first?.rematchParentID)
    }

    @MainActor
    func testChallengeAgainRefusedSaysTheyCantBeChallengedNotThatNoAccountHasALink() async throws {
        let key = UUID()
        let closed = CompetitionID(UUID())
        let recorder = InviteCreationRecorder(results: [.failure(.recipientUnavailable)])
        let store = TestStore(initialState: CompetitionFeature.State(
            publication: .remote(revision: 1, competitions: [Self.presentation(closed)])
        )) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: [key])
        }
        await store.send(.challengeAgainTapped(closed)) {
            $0.inviteRecipient = .init(Self.recipient)
            $0.inviteRecipientCode = Self.recipient.id.uuidString.lowercased()
        }
        await store.send(.createInviteTapped) {
            $0.inviteCreations[.sheet] = Creation(recipient: .profile(Self.recipient.id), idempotencyKey: key, status: .creating)
        }
        // The server refuses an id learned through a link that was reset.
        // No link is on screen, so the sheet keeps them and says so, giving
        // no reason.
        await store.receive(.createInviteResponse(.sheet, idempotencyKey: key, .failure(.recipientUnavailable))) {
            $0.inviteCreations[.sheet]?.status = .failed(.recipientGone)
        }
        await store.finish()
        XCTAssertEqual(recorder.requests.first?.recipient, .profile(Self.recipient.id))
        XCTAssertEqual(store.state.challengeSheetStatus, .failed(.recipientGone))
        XCTAssertNil(competitionRecipientErrorText(store.state.inviteRecipientStatus))
    }

    @MainActor
    func testAFriendChosenFromTheSheetAndRefusedStaysChosen() async throws {
        let friend = FriendPerson(id: Self.recipient.id, displayName: "Maya", username: "maya", relationship: .friend)
        for failure in [CompetitionRemoteFailure.recipientUnavailable, .forbidden] {
            let key = UUID()
            let recorder = InviteCreationRecorder(results: [.failure(failure)])
            let store = TestStore(initialState: CompetitionFeature.State()) {
                CompetitionFeature()
            } withDependencies: {
                $0.competitionClient = recorder.client
                $0.competitionInviteLinkClient = .fixture(host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: [key])
            }
            let chosen = CompetitionFeature.InviteRecipient(
                AuthenticatedProfile(id: friend.id, displayName: friend.displayName)
            )
            await store.send(.challengeRecipientChosen(chosen)) {
                $0.inviteRecipient = chosen
                $0.inviteRecipientCode = friend.id.uuidString.lowercased()
            }
            await store.send(.createInviteTapped) {
                $0.inviteCreations[.sheet] = Creation(recipient: .profile(friend.id), idempotencyKey: key, status: .creating)
            }
            await store.receive(.createInviteResponse(.sheet, idempotencyKey: key, .failure(failure))) {
                $0.inviteCreations[.sheet]?.status = .failed(.recipientGone)
            }
            await store.finish()
            XCTAssertEqual(recorder.requests.first?.recipientProfileID, friend.id)
            XCTAssertNil(recorder.requests.first?.rematchParentID)
            XCTAssertEqual(store.state.challengeSheetStatus, .failed(.recipientGone))
        }
    }

    @MainActor
    func testBlockingSomeoneFromTheirPageListsThemAsBlockedAndRefreshesMatches() async {
        let dev = FriendPerson(id: Self.recipient.id, displayName: "Dev", username: "devp", relationship: .friend)
        var devNone = dev
        devNone.relationship = .none
        let profile = AuthenticatedProfile(id: dev.id, displayName: "Dev")
        let earlier = AuthenticatedProfile(id: UUID(), displayName: "Sam")
        let recorder = InviteCreationRecorder(results: [])
        var client = recorder.client
        client.blockProfile = { _ in profile }
        client.listFriends = { FriendsList() }
        var initial = CompetitionFeature.State()
        initial.blockedPeople = [earlier]
        initial.friends.list = FriendsList(friends: [dev])
        let store = TestStore(initialState: initial) { CompetitionFeature() } withDependencies: {
            $0.competitionClient = client
        }
        await store.send(.friends(.blockTapped(dev))) { $0.friends.inFlight = [dev.id] }
        await store.receive(.friends(.blockFinished(dev, .success(profile)))) {
            $0.friends.inFlight = []
            $0.friends.people = [dev.id: devNone]
            $0.friends.list = FriendsList()
            $0.blockedPeople = [profile, earlier]
        }
        await store.receive(.friends(.requested))
        await store.receive(.friends(.loaded(FriendsList())))
        await store.finish()
        // Their pending challenge to you, or yours to them, was cancelled.
        XCTAssertEqual(recorder.reconcileTriggers, [.pullToRefresh])
    }

    @MainActor
    func testFailedDiscoveryAfterSuccessfulCreationPreservesShareLinkAndRetryKey() async throws {
        let id = CompetitionID(UUID())
        let key = UUID()
        let link = try Self.link("C")
        for issue in [CompetitionClientIssue.remoteUnavailable, .storageUnavailable, .competitionFailures([id])] {
            let failed = CompetitionPublication.remote(revision: 4, issues: [issue])
            let store = TestStore(initialState: CompetitionFeature.State(
                publication: failed,
                inviteCreations: [.sheet: Creation(recipient: .profile(Self.recipient.id), idempotencyKey: key, status: .creating)],
                inviteRecipient: .init(Self.recipient)
            )) { CompetitionFeature() }
            await store.send(.createInviteResponse(.sheet, idempotencyKey: key, .success(link: link, competitionID: id, expectedRevision: 4))) {
                $0.inviteLinks[id] = .ready(link, minimumRevision: 4)
                $0.inviteCreations[.sheet]?.status = .sent(id)
            }
            await store.send(.publication(.remote(revision: 5))) {
                $0.publication = .remote(revision: 5)
                $0.inviteLinks = [:]
            }
            await store.finish()
        }
    }

    @MainActor
    func testUnrelatedDashboardIssuesDoNotKeepRetiredInvitationReady() async throws {
        let id = CompetitionID(UUID())
        let otherID = CompetitionID(UUID())
        let key = UUID()
        let link = try Self.link("D")
        for issue in [CompetitionClientIssue.authorizationUnavailable, .activityFailures([id]), .competitionFailures([otherID]), .commandRejected(otherID)] {
            let publication = CompetitionPublication.remote(revision: 4, issues: [issue])
            let store = TestStore(initialState: CompetitionFeature.State(
                publication: publication,
                inviteCreations: [.sheet: Creation(recipient: .profile(Self.recipient.id), idempotencyKey: key, status: .creating)],
                inviteRecipient: .init(Self.recipient)
            )) { CompetitionFeature() }
            await store.send(.createInviteResponse(.sheet, idempotencyKey: key, .success(link: link, competitionID: id, expectedRevision: 4))) {
                $0.inviteCreations[.sheet]?.status = .sent(id)
            }
            await store.finish()
        }
    }

    @MainActor
    func testPruneKeepsLinksOnIncompleteDiscovery() async throws {
        let parentID = CompetitionID(UUID())
        let childID = CompetitionID(UUID())
        let link = try Self.link("K")
        for issue in [CompetitionClientIssue.remoteUnavailable, .storageUnavailable, .competitionFailures([childID])] {
            let store = TestStore(initialState: CompetitionFeature.State(
                inviteCreations: [.rematch(of: parentID): Creation(recipient: .profile(Self.recipient.id), idempotencyKey: UUID(), status: .sent(childID))],
                inviteLinks: [childID: .ready(link, minimumRevision: 2)]
            )) { CompetitionFeature() }
            let incomplete = CompetitionPublication.remote(revision: 3, issues: [issue])
            await store.send(.publication(incomplete)) { $0.publication = incomplete }
            await store.finish()
        }
    }

    @MainActor
    func testPruneRemovesLinksAndRematchSentSlots() async throws {
        let parentID = CompetitionID(UUID())
        let link = try Self.link("P")
        let accepted = CompetitionID(UUID())
        let expired = CompetitionID(UUID())
        let missing = CompetitionID(UUID())
        let stillPending = CompetitionID(UUID())
        let otherParent = CompetitionID(UUID())
        let thirdParent = CompetitionID(UUID())
        let store = TestStore(initialState: CompetitionFeature.State(
            inviteCreations: [
                .sheet: Creation(recipient: .profile(Self.recipient.id), idempotencyKey: UUID(), status: .sent(accepted)),
                .rematch(of: parentID): Creation(recipient: .profile(Self.recipient.id), idempotencyKey: UUID(), status: .sent(expired)),
                .rematch(of: otherParent): Creation(recipient: .profile(Self.recipient.id), idempotencyKey: UUID(), status: .sent(missing)),
                .rematch(of: thirdParent): Creation(recipient: .profile(Self.recipient.id), idempotencyKey: UUID(), status: .sent(stillPending)),
            ],
            inviteLinks: [
                accepted: .ready(link, minimumRevision: 1),
                expired: .ready(link, minimumRevision: 1),
                missing: .notOnThisPhone,
                stillPending: .ready(link, minimumRevision: 1),
            ]
        )) { CompetitionFeature() }
        let publication = CompetitionPublication.remote(revision: 2, competitions: [
            Self.presentation(accepted, lifecycle: .scheduled),
            Self.presentation(expired, lifecycle: .expired(at: .distantPast, direction: .outgoing)),
            Self.pending(stillPending, identity: Self.recipientIdentity),
        ])
        await store.send(.publication(publication)) {
            $0.publication = publication
            $0.inviteLinks = [stillPending: .ready(link, minimumRevision: 1)]
            // The sheet keeps its slot until it closes.
            $0.inviteCreations[.rematch(of: parentID)] = nil
            $0.inviteCreations[.rematch(of: otherParent)] = nil
        }
        await store.finish()
    }

    @MainActor
    func testStopClearsInviteCreationStateAndShareLink() async throws {
        let parentID = CompetitionID(UUID(uuidString: "82000000-0000-0000-0000-000000000011")!)
        let link = try Self.link("Z")
        var initial = CompetitionFeature.State(
            inviteCreations: [
                .sheet: Creation(recipient: .profile(Self.recipient.id), idempotencyKey: UUID(), status: .creating),
                .rematch(of: parentID): Creation(recipient: .profile(Self.recipient.id), idempotencyKey: UUID(), status: .sent(parentID)),
            ],
            inviteLinks: [parentID: .ready(link, minimumRevision: 1)],
            inviteRecipient: .init(Self.recipient)
        )
        initial.inviteRecipientCode = Self.recipient.id.uuidString
        let store = TestStore(initialState: initial) { CompetitionFeature() }

        await store.send(.stop) {
            $0.inviteCreations = [:]
            $0.inviteLinks = [:]
            $0.inviteRecipient = nil
            $0.inviteRecipientCode = ""
        }
        await store.finish()
    }

    @MainActor
    func testLinkSurvivesSheetDismissAndCodeEdits() async throws {
        let key = UUID()
        let id = CompetitionID(UUID())
        let rawToken = String(repeating: "L", count: 43)
        let link = try Self.link("L")
        let recorder = InviteCreationRecorder(results: [.success(id, token: rawToken, expectedRevision: 3)])
        var initial = CompetitionFeature.State(inviteRecipient: .init(Self.recipient))
        initial.inviteRecipientCode = Self.recipient.id.uuidString
        let store = TestStore(initialState: initial) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: [key])
        }
        await store.send(.createInviteTapped) {
            $0.inviteCreations[.sheet] = Creation(recipient: .profile(Self.recipient.id), idempotencyKey: key, status: .creating)
        }
        await store.receive(.createInviteResponse(.sheet, idempotencyKey: key, .success(link: link, competitionID: id, expectedRevision: 3))) {
            $0.inviteLinks[id] = .ready(link, minimumRevision: 3)
            $0.inviteCreations[.sheet]?.status = .sent(id)
        }
        await store.send(.challengeSheetDismissed) {
            $0.inviteCreations = [:]
            $0.inviteRecipient = nil
            $0.inviteRecipientCode = ""
        }
        await store.send(.inviteRecipientCodeChanged("x")) { $0.inviteRecipientCode = "x" }
        XCTAssertEqual(store.state.inviteLinks[id], .ready(link, minimumRevision: 3))
        XCTAssertFalse(String(reflecting: store.state).contains(rawToken))
        await store.finish()
    }

    @MainActor
    func testFindAccountAndCodeEditsIgnoredOnceSent() async {
        let id = CompetitionID(UUID())
        var initial = CompetitionFeature.State(
            inviteCreations: [.sheet: Creation(recipient: .profile(Self.recipient.id), idempotencyKey: UUID(), status: .sent(id))],
            inviteRecipient: .init(Self.recipient)
        )
        initial.inviteRecipientCode = Self.recipient.id.uuidString
        let store = TestStore(initialState: initial) { CompetitionFeature() }
        await store.send(.findInviteRecipientTapped)
        await store.send(.inviteRecipientCodeChanged("edited"))
        await store.send(.createInviteTapped)
        await store.finish()
    }

    @MainActor
    func testResponseAfterSheetDismissStillKeepsLink() async throws {
        let key = UUID()
        let id = CompetitionID(UUID())
        let link = try Self.link("R")
        let store = TestStore(initialState: CompetitionFeature.State(
            inviteCreations: [.sheet: Creation(recipient: .profile(Self.recipient.id), idempotencyKey: key, status: .creating)],
            inviteRecipient: .init(Self.recipient)
        )) { CompetitionFeature() }
        await store.send(.challengeSheetDismissed) {
            $0.inviteCreations = [:]
            $0.inviteRecipient = nil
        }
        await store.send(.createInviteResponse(.sheet, idempotencyKey: key, .success(link: link, competitionID: id, expectedRevision: 2))) {
            $0.inviteLinks[id] = .ready(link, minimumRevision: 2)
        }
        await store.finish()
    }

    @MainActor
    func testRemoteRematchCreatesShareableInviteAgainstCompletedParent() async throws {
        let idempotencyKey = UUID(uuidString: "82000000-0000-0000-0000-000000000005")!
        let parentID = CompetitionID(UUID(uuidString: "82000000-0000-0000-0000-000000000006")!)
        let childID = CompetitionID(UUID(uuidString: "82000000-0000-0000-0000-000000000007")!)
        let rawToken = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
        let link = try Self.link("C")
        let recorder = InviteCreationRecorder(results: [.success(childID, token: rawToken, expectedRevision: 8)])
        let store = TestStore(
            initialState: CompetitionFeature.State(
                publication: .remote(revision: 7, competitions: [Self.presentation(parentID)])
            )
        ) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(
                host: Self.host,
                timeZoneIdentifier: "America/New_York",
                idempotencyKeys: [idempotencyKey]
            )
        }

        await store.send(.rematchTapped(parentID)) {
            $0.inviteCreations[.rematch(of: parentID)] = Creation(
                recipient: .profile(Self.recipient.id), idempotencyKey: idempotencyKey, status: .creating
            )
        }
        XCTAssertEqual(store.state.rematchState(for: Self.presentation(parentID)), .sending)
        await store.receive(
            .createInviteResponse(
                .rematch(of: parentID),
                idempotencyKey: idempotencyKey,
                .success(link: link, competitionID: childID, expectedRevision: 8)
            )
        ) {
            $0.inviteLinks[childID] = .ready(link, minimumRevision: 8)
            $0.inviteCreations[.rematch(of: parentID)]?.status = .sent(childID)
        }

        XCTAssertEqual(
            store.state.rematchState(for: Self.presentation(parentID)),
            .sent(challengeID: childID, expiresAt: nil, link: .ready(link, minimumRevision: 8))
        )
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.rematchParentID, parentID.rawValue)
        XCTAssertEqual(recorder.requests.first?.recipientProfileID, Self.recipient.id)
        XCTAssertEqual(recorder.requests.first?.timeZoneIdentifier, "America/New_York")
        XCTAssertFalse(String(reflecting: store.state).contains(rawToken))
        await store.finish()
    }

    @MainActor
    func testRematchesKeepSeparateSlotsAndLinks() async throws {
        let parentA = CompetitionID(UUID())
        let parentB = CompetitionID(UUID())
        let childA = CompetitionID(UUID())
        let childB = CompetitionID(UUID())
        let keyA = UUID()
        let keyB = UUID()
        let linkA = try Self.link("E")
        let linkB = try Self.link("F")
        let recorder = InviteCreationRecorder(results: [
            .success(childA, token: String(repeating: "E", count: 43), expectedRevision: 3),
            .success(childB, token: String(repeating: "F", count: 43), expectedRevision: 4),
        ])
        let sheetPerson = AuthenticatedProfile(id: UUID(), displayName: "Sheet")
        var initial = CompetitionFeature.State(
            publication: .remote(revision: 2, competitions: [Self.presentation(parentA), Self.presentation(parentB)]),
            inviteRecipient: .init(sheetPerson)
        )
        initial.inviteRecipientCode = sheetPerson.id.uuidString
        let store = TestStore(initialState: initial) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: [keyA, keyB])
        }
        await store.send(.rematchTapped(parentA)) {
            $0.inviteCreations[.rematch(of: parentA)] = Creation(recipient: .profile(Self.recipient.id), idempotencyKey: keyA, status: .creating)
        }
        await store.receive(.createInviteResponse(.rematch(of: parentA), idempotencyKey: keyA, .success(link: linkA, competitionID: childA, expectedRevision: 3))) {
            $0.inviteLinks[childA] = .ready(linkA, minimumRevision: 3)
            $0.inviteCreations[.rematch(of: parentA)]?.status = .sent(childA)
        }
        await store.send(.rematchTapped(parentB)) {
            $0.inviteCreations[.rematch(of: parentB)] = Creation(recipient: .profile(Self.recipient.id), idempotencyKey: keyB, status: .creating)
        }
        await store.receive(.createInviteResponse(.rematch(of: parentB), idempotencyKey: keyB, .success(link: linkB, competitionID: childB, expectedRevision: 4))) {
            $0.inviteLinks[childB] = .ready(linkB, minimumRevision: 4)
            $0.inviteCreations[.rematch(of: parentB)]?.status = .sent(childB)
        }
        XCTAssertEqual(store.state.challengeSheetStatus, .ready)
        await store.finish()
    }

    @MainActor
    func testRematchAccountGoneShowsRecipientGone() async {
        let parentID = CompetitionID(UUID())
        let key = UUID()
        let recorder = InviteCreationRecorder(results: [.failure(.recipientUnavailable)])
        let store = TestStore(initialState: CompetitionFeature.State(
            publication: .remote(revision: 1, competitions: [Self.presentation(parentID)])
        )) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: [key])
        }
        await store.send(.rematchTapped(parentID)) {
            $0.inviteCreations[.rematch(of: parentID)] = Creation(recipient: .profile(Self.recipient.id), idempotencyKey: key, status: .creating)
        }
        await store.receive(.createInviteResponse(.rematch(of: parentID), idempotencyKey: key, .failure(.recipientUnavailable))) {
            $0.inviteCreations[.rematch(of: parentID)]?.status = .failed(.recipientGone)
        }
        XCTAssertEqual(store.state.rematchState(for: Self.presentation(parentID)), .failed(.recipientGone))
        // No button, and a stray tap sends nothing.
        await store.send(.rematchTapped(parentID))
        XCTAssertEqual(recorder.requestCount, 1)
        await store.finish()
    }

    @MainActor
    func testSheetAccountGoneKeepsAKnownPersonAndSaysTheyCantBeChallenged() async {
        let key = UUID()
        let recorder = InviteCreationRecorder(results: [.failure(.recipientUnavailable)])
        let store = TestStore(initialState: CompetitionFeature.State(inviteRecipient: .init(Self.recipient))) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: [key])
        }
        await store.send(.createInviteTapped) {
            $0.inviteCreations[.sheet] = Creation(recipient: .profile(Self.recipient.id), idempotencyKey: key, status: .creating)
        }
        await store.receive(.createInviteResponse(.sheet, idempotencyKey: key, .failure(.recipientUnavailable))) {
            $0.inviteCreations[.sheet]?.status = .failed(.recipientGone)
        }
        await store.finish()
    }

    @MainActor
    func testRematchStateFollowsChild() {
        let parent = Self.presentation(CompetitionID(UUID()))
        func state(
            _ others: [CompetitionPresentation],
            source: CompetitionPublicationSource = .remoteParticipants
        ) -> CompetitionFeature.State {
            CompetitionFeature.State(publication: CompetitionPublication(
                publicationRevision: 1,
                dashboard: CompetitionDashboard(
                    competitions: [parent] + others, awards: [], issues: [],
                    hiddenTerminalCompetitionCount: 0
                ),
                source: source
            ))
        }
        let expiresAt = Date(timeIntervalSince1970: 1_000)
        let pendingChild = Self.pending(
            CompetitionID(UUID()), identity: Self.recipientIdentity,
            expiresAt: expiresAt, rematchParentID: parent.id
        )
        XCTAssertEqual(
            state([pendingChild]).rematchState(for: parent),
            .sent(challengeID: pendingChild.id, expiresAt: expiresAt, link: nil)
        )
        let incomingChild = Self.presentation(
            CompetitionID(UUID()),
            lifecycle: .pending(direction: .incoming, createdAt: .distantPast, expiresAt: expiresAt),
            rematchParentID: parent.id
        )
        XCTAssertEqual(state([incomingChild]).rematchState(for: parent), .received(incomingChild))
        XCTAssertEqual(
            state([incomingChild, pendingChild]).rematchState(for: parent),
            .sent(challengeID: pendingChild.id, expiresAt: expiresAt, link: nil)
        )
        let scheduledChild = Self.presentation(CompetitionID(UUID()), lifecycle: .scheduled, rematchParentID: parent.id)
        XCTAssertEqual(state([scheduledChild]).rematchState(for: parent), .next(scheduledChild))
        let expiredChild = Self.presentation(
            CompetitionID(UUID()), lifecycle: .expired(at: .distantPast, direction: .outgoing), rematchParentID: parent.id
        )
        XCTAssertEqual(state([expiredChild]).rematchState(for: parent), .available)
        let declinedChild = Self.presentation(
            CompetitionID(UUID()), lifecycle: .declined(at: .distantPast, direction: .outgoing), rematchParentID: parent.id
        )
        XCTAssertEqual(state([declinedChild]).rematchState(for: parent), .available)
        let unrelatedPending = Self.pending(CompetitionID(UUID()), identity: Self.recipientIdentity)
        XCTAssertEqual(state([unrelatedPending]).rematchState(for: parent), .alreadyChallenged(unrelatedPending))
        var local = state([], source: .simulatedFixture)
        XCTAssertEqual(local.rematchState(for: parent), .available)
        local.commandIDsInFlight = [parent.id]
        XCTAssertEqual(local.rematchState(for: parent), .sending)
    }

    @MainActor
    func testIncomingRematchIsNotTreatedAsSent() async {
        let parent = Self.presentation(CompetitionID(UUID()))
        let incoming = Self.presentation(
            CompetitionID(UUID()),
            lifecycle: .pending(direction: .incoming, createdAt: .distantPast, expiresAt: nil),
            rematchParentID: parent.id
        )
        let recorder = InviteCreationRecorder(results: [])
        let store = TestStore(initialState: CompetitionFeature.State(
            publication: .remote(revision: 1, competitions: [parent, incoming])
        )) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
        }
        XCTAssertEqual(store.state.rematchState(for: parent), .received(incoming))
        // Their challenge waits for an answer; a rematch of your own isn't sent.
        await store.send(.rematchTapped(parent.id))
        XCTAssertEqual(recorder.requestCount, 0)
        XCTAssertNil(store.state.inviteLinks[incoming.id])
        await store.finish()
    }

    @MainActor
    func testChallengeSheetStatusOrdering() throws {
        let id = CompetitionID(UUID())
        let link = try Self.link("S")
        let existing = Self.pending(CompetitionID(UUID()), identity: Self.recipientIdentity)
        var state = CompetitionFeature.State(
            publication: .remote(revision: 1, competitions: [existing]),
            inviteRecipient: .init(Self.recipient)
        )
        func slot(_ status: Creation.Status) -> Creation {
            Creation(recipient: .profile(Self.recipient.id), idempotencyKey: UUID(), status: status)
        }
        state.inviteCreations[.sheet] = slot(.creating)
        XCTAssertEqual(state.challengeSheetStatus, .creating)
        state.inviteCreations[.sheet] = slot(.sent(id))
        state.inviteLinks[id] = .ready(link, minimumRevision: 0)
        XCTAssertEqual(state.challengeSheetStatus, .sent(challengeID: id, challenge: nil, link: link))
        state.inviteCreations[.sheet] = slot(.failed(.connection))
        XCTAssertEqual(state.challengeSheetStatus, .alreadyChallenged(existing))
        state.publication = .remote(revision: 2)
        XCTAssertEqual(state.challengeSheetStatus, .failed(.connection))
        state.inviteCreations = [:]
        XCTAssertEqual(state.challengeSheetStatus, .ready)
    }

    /// Motion keys on these, so a new publication must not change them and
    /// a real change must.
    func testControlPhaseAndScreenKindKeys() {
        typealias Status = CompetitionFeature.ChallengeSheetStatus
        let id = CompetitionID(UUID())
        let waiting = Self.pending(id, identity: "them")
        let accepted = Self.presentation(id, lifecycle: .scheduled, identity: "them")

        XCTAssertEqual(Status.creating.controlPhase, Status.ready.controlPhase)
        XCTAssertEqual(
            Status.alreadyChallenged(waiting).controlPhase,
            Status.inMatch(accepted).controlPhase
        )
        XCTAssertEqual(
            Status.sent(challengeID: id, challenge: nil, link: nil).controlPhase, .sent
        )
        XCTAssertEqual(
            Status.sent(challengeID: id, challenge: waiting, link: nil).controlPhase, .sent
        )
        XCTAssertEqual(
            Status.sent(challengeID: id, challenge: accepted, link: nil).controlPhase, .accepted
        )

        XCTAssertEqual(
            competitionScreenKind(waiting, source: .remoteParticipants),
            .invite(waitsOnThem: true)
        )
        XCTAssertEqual(
            competitionScreenKind(waiting, source: .simulatedFixture),
            .invite(waitsOnThem: false)
        )
        let incoming = Self.presentation(
            id,
            lifecycle: .pending(direction: .incoming, createdAt: .distantPast, expiresAt: nil),
            identity: "them"
        )
        XCTAssertEqual(
            competitionScreenKind(incoming, source: .remoteParticipants),
            .invite(waitsOnThem: false)
        )
        XCTAssertEqual(competitionScreenKind(accepted, source: .remoteParticipants), .underway)
        XCTAssertEqual(
            competitionScreenKind(Self.presentation(id), source: .remoteParticipants), .result
        )
        XCTAssertEqual(
            competitionScreenKind(
                Self.pending(id, identity: PracticeMatch.opponentIdentity),
                source: .remoteParticipants
            ),
            .underway
        )
    }

    @MainActor
    func testDivergentDuplicateRotatesKey() async {
        let first = UUID()
        let rotated = UUID()
        let recorder = InviteCreationRecorder(results: [.failure(.divergentDuplicate), .failure(.retryableTransport)])
        let store = TestStore(initialState: CompetitionFeature.State(inviteRecipient: .init(Self.recipient))) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: [first, rotated])
        }
        await store.send(.createInviteTapped) {
            $0.inviteCreations[.sheet] = Creation(recipient: .profile(Self.recipient.id), idempotencyKey: first, status: .creating)
        }
        await store.receive(.createInviteResponse(.sheet, idempotencyKey: first, .failure(.divergentDuplicate))) {
            $0.inviteCreations[.sheet] = Creation(recipient: .profile(Self.recipient.id), idempotencyKey: rotated, status: .failed(.connection))
        }
        await store.send(.createInviteTapped) {
            $0.inviteCreations[.sheet]?.status = .creating
        }
        await store.receive(.createInviteResponse(.sheet, idempotencyKey: rotated, .failure(.retryableTransport))) {
            $0.inviteCreations[.sheet]?.status = .failed(.connection)
        }
        XCTAssertEqual(recorder.requests.map(\.idempotencyKey), [first, rotated])
        await store.finish()
    }

    @MainActor
    func testInviteLinkRestore() async throws {
        let id = CompetitionID(UUID())
        let rawToken = String(repeating: "Q", count: 43)
        let link = try Self.link("Q")
        let results = LockIsolated<[Result<String, CompetitionRemoteFailure>]>([
            .success(rawToken), .failure(.notFound), .failure(.retryableTransport), .success(rawToken),
        ])
        var client = InviteCreationRecorder(results: []).client
        client.restoreInvite = { requested in
            let next = results.withValue { $0.removeFirst() }
            return CompetitionInviteCreationOutcome(
                invite: try CompetitionInvite(competitionID: requested.rawValue, token: try next.get()),
                expectedPublicationRevision: 6
            )
        }
        let store = TestStore(initialState: CompetitionFeature.State(publication: .remote(revision: 5))) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = client
            $0.competitionInviteLinkClient = .fixture(host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: [])
        }
        await store.send(.inviteLinkNeeded(id)) { $0.inviteLinks[id] = .loading }
        await store.receive(.inviteLinkResponse(id, .ready(link, minimumRevision: 6))) {
            $0.inviteLinks[id] = .ready(link, minimumRevision: 6)
        }
        XCTAssertFalse(String(reflecting: store.state).contains(rawToken))
        // A link in memory isn't asked for again.
        await store.send(.inviteLinkNeeded(id))

        let missing = CompetitionID(UUID())
        await store.send(.inviteLinkNeeded(missing)) { $0.inviteLinks[missing] = .loading }
        await store.receive(.inviteLinkResponse(missing, .notOnThisPhone)) {
            $0.inviteLinks[missing] = .notOnThisPhone
        }

        let offline = CompetitionID(UUID())
        await store.send(.inviteLinkNeeded(offline)) { $0.inviteLinks[offline] = .loading }
        await store.receive(.inviteLinkResponse(offline, .failed)) { $0.inviteLinks[offline] = .failed }
        await store.send(.inviteLinkNeeded(offline)) { $0.inviteLinks[offline] = .loading }
        await store.receive(.inviteLinkResponse(offline, .ready(link, minimumRevision: 6))) {
            $0.inviteLinks[offline] = .ready(link, minimumRevision: 6)
        }
        await store.finish()
    }

    @MainActor
    func testLateRestoreAfterStopIsDropped() async throws {
        let id = CompetitionID(UUID())
        let link = try Self.link("T")
        let store = TestStore(initialState: CompetitionFeature.State(
            publication: .remote(revision: 1),
            inviteLinks: [id: .loading]
        )) { CompetitionFeature() } withDependencies: {
            $0.competitionClient = InviteCreationRecorder(results: []).client
        }
        await store.send(.stop) { $0.inviteLinks = [:] }
        await store.send(.inviteLinkResponse(id, .ready(link, minimumRevision: 1)))
        await store.finish()
    }

    @MainActor
    func testCreateInviteBuildsRedactedHTTPSLinkFromServerToken() async throws {
        let idempotencyKey = UUID(uuidString: "82000000-0000-0000-0000-000000000001")!
        let competitionID = CompetitionID(UUID(uuidString: "82000000-0000-0000-0000-000000000002")!)
        let rawToken = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let link = try Self.link("A")
        let recorder = InviteCreationRecorder(results: [.success(competitionID, token: rawToken, expectedRevision: 4)])
        let store = TestStore(initialState: CompetitionFeature.State(inviteRecipient: .init(Self.recipient))) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(
                host: Self.host,
                timeZoneIdentifier: "America/Los_Angeles",
                idempotencyKeys: [idempotencyKey]
            )
        }

        await store.send(.createInviteTapped) {
            $0.inviteCreations[.sheet] = Creation(recipient: .profile(Self.recipient.id), idempotencyKey: idempotencyKey, status: .creating)
        }
        await store.receive(
            .createInviteResponse(.sheet, idempotencyKey: idempotencyKey, .success(
                link: link, competitionID: competitionID, expectedRevision: 4
            ))
        ) {
            $0.inviteLinks[competitionID] = .ready(link, minimumRevision: 4)
            $0.inviteCreations[.sheet]?.status = .sent(competitionID)
        }

        XCTAssertEqual(recorder.requestCount, 1)
        XCTAssertEqual(recorder.requests.first?.timeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(recorder.requests.first?.idempotencyKey, idempotencyKey)
        XCTAssertEqual(link.url.absoluteString, "https://\(Self.host)/invite/\(rawToken)")
        XCTAssertFalse(String(reflecting: store.state).contains(rawToken))
        await store.finish()
    }

    @MainActor
    func testCreateInviteWithoutLinkConfigurationFailsBeforeServerWrite() async {
        let idempotencyKey = UUID(uuidString: "82000000-0000-4000-8000-000000000020")!
        let competitionID = CompetitionID(UUID(uuidString: "82000000-0000-4000-8000-000000000021")!)
        let recorder = InviteCreationRecorder(results: [
            .success(competitionID, token: "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG", expectedRevision: 1),
        ])
        let store = TestStore(initialState: CompetitionFeature.State(inviteRecipient: .init(Self.recipient))) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = CompetitionInviteLinkClient(
                makeShareLink: { _ in nil },
                currentTimeZoneIdentifier: { "UTC" },
                makeIdempotencyKey: { idempotencyKey }
            )
        }

        await store.send(.createInviteTapped) {
            $0.inviteCreations[.sheet] = Creation(
                recipient: .profile(Self.recipient.id), idempotencyKey: idempotencyKey, status: .failed(.unavailable)
            )
        }

        XCTAssertEqual(recorder.requestCount, 0)
        await store.finish()
    }

    @MainActor
    func testFailedConnectionRetryUsesTheSlotsStoredKey() async throws {
        let idempotencyKey = UUID(uuidString: "82000000-0000-0000-0000-000000000012")!
        let competitionID = CompetitionID(UUID(uuidString: "82000000-0000-0000-0000-000000000013")!)
        let rawToken = "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"
        let link = try Self.link("D")
        let recorder = InviteCreationRecorder(results: [.success(competitionID, token: rawToken, expectedRevision: 9)])
        let store = TestStore(
            initialState: CompetitionFeature.State(
                inviteCreations: [.sheet: Creation(
                    recipient: .profile(Self.recipient.id), idempotencyKey: idempotencyKey, status: .failed(.connection)
                )],
                inviteRecipient: .init(Self.recipient)
            )
        ) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: [UUID()])
        }

        await store.send(.createInviteTapped) {
            $0.inviteCreations[.sheet]?.status = .creating
        }
        await store.receive(
            .createInviteResponse(.sheet, idempotencyKey: idempotencyKey, .success(
                link: link, competitionID: competitionID, expectedRevision: 9
            ))
        ) {
            $0.inviteLinks[competitionID] = .ready(link, minimumRevision: 9)
            $0.inviteCreations[.sheet]?.status = .sent(competitionID)
        }

        XCTAssertEqual(recorder.requests.map(\.idempotencyKey), [idempotencyKey])
        await store.finish()
    }

    @MainActor
    func testRetryableCreateReusesIdempotencyKey() async throws {
        let idempotencyKey = UUID(uuidString: "82000000-0000-0000-0000-000000000003")!
        let competitionID = CompetitionID(UUID(uuidString: "82000000-0000-0000-0000-000000000004")!)
        let rawToken = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
        let link = try Self.link("B")
        let recorder = InviteCreationRecorder(results: [
            .failure(.retryableTransport),
            .success(competitionID, token: rawToken, expectedRevision: 2),
        ])
        let store = TestStore(initialState: CompetitionFeature.State(inviteRecipient: .init(Self.recipient))) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: [idempotencyKey, UUID()])
        }

        await store.send(.createInviteTapped) {
            $0.inviteCreations[.sheet] = Creation(recipient: .profile(Self.recipient.id), idempotencyKey: idempotencyKey, status: .creating)
        }
        await store.receive(.createInviteResponse(.sheet, idempotencyKey: idempotencyKey, .failure(.retryableTransport))) {
            $0.inviteCreations[.sheet]?.status = .failed(.connection)
        }
        await store.send(.createInviteTapped) {
            $0.inviteCreations[.sheet]?.status = .creating
        }
        await store.receive(
            .createInviteResponse(.sheet, idempotencyKey: idempotencyKey, .success(
                link: link, competitionID: competitionID, expectedRevision: 2
            ))
        ) {
            $0.inviteLinks[competitionID] = .ready(link, minimumRevision: 2)
            $0.inviteCreations[.sheet]?.status = .sent(competitionID)
        }

        XCTAssertEqual(recorder.requests.map(\.idempotencyKey), [idempotencyKey, idempotencyKey])
        await store.finish()
    }

    private static var recipientIdentity: String {
        RemoteCompetitionOpponentIdentity.identity(for: recipient.id)
    }

    @MainActor
    func testCancelTappedRunsCommand() async {
        let id = CompetitionID(UUID())
        let cancelled = LockIsolated<[CompetitionID]>([])
        var client = InviteCreationRecorder(results: []).client
        client.cancel = { id in
            cancelled.withValue { $0.append(id) }
            return .remote(revision: 0)
        }
        let store = TestStore(initialState: CompetitionFeature.State(
            publication: .remote(revision: 1)
        )) { CompetitionFeature() } withDependencies: { $0.competitionClient = client }
        await store.send(.cancelTapped(id)) { $0.commandIDsInFlight = [id] }
        await store.receive(.commandFinished(id, expectedRevision: 0)) {
            $0.commandIDsInFlight = []
        }
        XCTAssertEqual(cancelled.value, [id])
        await store.finish()
    }

    private static func nudgeState(_ id: CompetitionID, evaluatedAt: Date) -> CompetitionFeature.State {
        CompetitionFeature.State(publication: .remote(revision: 1, competitions: [
            CompetitionPresentation(
                id: id, ownerDisplayName: "Sender", opponentDisplayName: recipient.displayName,
                lifecycle: .active(dayOrdinal: 2),
                acceptedConfiguration: nil, userPoints: 0, opponentPoints: 0, days: [],
                currentDayOrdinal: 2, lastRefresh: nil, tally: nil, terminalResult: nil,
                evaluatedAt: evaluatedAt
            ),
        ]))
    }

    @MainActor
    func testNudgeTappedSendsOnceAndShowsWhenItWasSent() async {
        let id = CompetitionID(UUID())
        let now = Date(timeIntervalSince1970: 1_786_979_520)
        let nudgedAt = now.addingTimeInterval(2)
        let sent = LockIsolated<[CompetitionID]>([])
        let gate = AsyncStream<Void>.makeStream()
        var client = InviteCreationRecorder(results: []).client
        client.nudge = { id in
            sent.withValue { $0.append(id) }
            for await _ in gate.stream { break }
            return nudgedAt
        }
        let store = TestStore(initialState: Self.nudgeState(id, evaluatedAt: now)) {
            CompetitionFeature()
        } withDependencies: { $0.competitionClient = client }
        await store.send(.nudgeTapped(id)) { $0.nudges[id] = .sending }
        // A second tap while sending sends nothing.
        await store.send(.nudgeTapped(id))
        gate.continuation.yield()
        await store.receive(.nudgeResponse(id, tappedAt: now, .success(nudgedAt))) {
            $0.nudges[id] = .sent(nudgedAt)
        }
        XCTAssertEqual(sent.value, [id])
        await store.finish()
    }

    @MainActor
    func testNudgeRefusedByServerShowsNotNeededAndRefreshes() async {
        for failure in [CompetitionRemoteFailure.forbidden, .notFound] {
            let id = CompetitionID(UUID())
            let now = Date(timeIntervalSince1970: 1_786_979_520)
            let recorder = InviteCreationRecorder(results: [])
            var client = recorder.client
            client.nudge = { _ in throw failure }
            let store = TestStore(initialState: Self.nudgeState(id, evaluatedAt: now)) {
                CompetitionFeature()
            } withDependencies: { $0.competitionClient = client }
            await store.send(.nudgeTapped(id)) { $0.nudges[id] = .sending }
            await store.receive(.nudgeResponse(id, tappedAt: now, .failure(failure))) {
                $0.nudges[id] = .notNeeded(now)
            }
            await store.finish()
            XCTAssertEqual(recorder.reconcileTriggers, [.foreground], "\(failure)")
        }
    }

    @MainActor
    func testNudgeConnectionFailureKeepsTheButton() async {
        let id = CompetitionID(UUID())
        let now = Date(timeIntervalSince1970: 1_786_979_520)
        let recorder = InviteCreationRecorder(results: [])
        var client = recorder.client
        client.nudge = { _ in throw CompetitionRemoteFailure.retryableTransport }
        let store = TestStore(initialState: Self.nudgeState(id, evaluatedAt: now)) {
            CompetitionFeature()
        } withDependencies: { $0.competitionClient = client }
        await store.send(.nudgeTapped(id)) { $0.nudges[id] = .sending }
        await store.receive(.nudgeResponse(id, tappedAt: now, .failure(.retryableTransport))) {
            $0.nudges[id] = .failed
        }
        await store.finish()
        XCTAssertEqual(recorder.reconcileTriggers, [])
    }

    private static func reactionPublication(
        _ id: CompetitionID,
        revision: UInt64,
        own: CompetitionReactionKind?
    ) -> CompetitionPublication {
        var match = CompetitionPresentation(
            id: id, ownerDisplayName: "Sender", opponentDisplayName: recipient.displayName,
            lifecycle: .active(dayOrdinal: 3),
            acceptedConfiguration: nil, userPoints: 0, opponentPoints: 0, days: [],
            currentDayOrdinal: 3, lastRefresh: nil, tally: nil, terminalResult: nil,
            evaluatedAt: Date(timeIntervalSince1970: 1_786_979_520)
        )
        match.reactions = own.map {
            [CompetitionReaction(
                target: .day(2), kind: $0, isFromYou: true,
                updatedAt: Date(timeIntervalSince1970: 1_786_979_520)
            )]
        } ?? []
        return .remote(revision: revision, competitions: [match])
    }

    @MainActor
    func testReactionTapSetsTogglesAndClears() async {
        let id = CompetitionID(UUID())
        let key = CompetitionReactionKey(competitionID: id, target: .day(2))
        let sent = LockIsolated<[CompetitionReactionKind?]>([])
        var client = InviteCreationRecorder(results: []).client
        client.setReaction = { id, _, kind in
            let revision = UInt64(sent.withValue { $0.append(kind); return $0.count }) + 1
            return Self.reactionPublication(id, revision: revision, own: kind)
        }
        let store = TestStore(
            initialState: CompetitionFeature.State(
                publication: Self.reactionPublication(id, revision: 1, own: nil)
            )
        ) { CompetitionFeature() } withDependencies: { $0.competitionClient = client }

        // Fire sets it; fire again removes it.
        await store.send(.reactionTapped(id, .day(2), .fire)) {
            $0.pendingReactions[key] = .some(.fire)
        }
        await store.receive(.publication(Self.reactionPublication(id, revision: 2, own: .fire))) {
            $0.publication = Self.reactionPublication(id, revision: 2, own: .fire)
        }
        await store.receive(.reactionFinished(key, succeeded: true)) {
            $0.pendingReactions = [:]
        }
        await store.send(.reactionTapped(id, .day(2), .fire)) {
            $0.pendingReactions[key] = .some(nil)
        }
        await store.receive(.publication(Self.reactionPublication(id, revision: 3, own: nil))) {
            $0.publication = Self.reactionPublication(id, revision: 3, own: nil)
        }
        await store.receive(.reactionFinished(key, succeeded: true)) {
            $0.pendingReactions = [:]
        }
        XCTAssertEqual(sent.value, [.fire, nil])
        await store.finish()
    }

    @MainActor
    func testReactionFailureMarksTheTargetAndClearsPending() async {
        let id = CompetitionID(UUID())
        let key = CompetitionReactionKey(competitionID: id, target: .day(2))
        var client = InviteCreationRecorder(results: []).client
        client.setReaction = { _, _, _ in throw CompetitionRemoteFailure.forbidden }
        let store = TestStore(
            initialState: CompetitionFeature.State(
                publication: Self.reactionPublication(id, revision: 1, own: nil)
            )
        ) { CompetitionFeature() } withDependencies: { $0.competitionClient = client }

        await store.send(.reactionTapped(id, .day(2), .clap)) {
            $0.pendingReactions[key] = .some(.clap)
        }
        await store.receive(.reactionFinished(key, succeeded: false)) {
            $0.pendingReactions = [:]
            $0.reactionFailures = [key]
        }
        let control = store.state.reactionControl(for: id) { _ in }
        XCTAssertEqual(control.failed, [.day(2)])
        XCTAssertNil(control.selection(.day(2), in: store.state.publication!.dashboard.competitions[0]))
        // Tapping again retries and clears the error line.
        await store.send(.reactionTapped(id, .day(2), .clap)) {
            $0.pendingReactions[key] = .some(.clap)
            $0.reactionFailures = []
        }
        await store.receive(.reactionFinished(key, succeeded: false)) {
            $0.pendingReactions = [:]
            $0.reactionFailures = [key]
        }
        await store.finish()
    }

    @MainActor
    func testReactionTapWhilePendingIsIgnored() async {
        let id = CompetitionID(UUID())
        let key = CompetitionReactionKey(competitionID: id, target: .day(2))
        let calls = LockIsolated(0)
        let gate = AsyncStream<Void>.makeStream()
        var client = InviteCreationRecorder(results: []).client
        client.setReaction = { id, _, kind in
            calls.withValue { $0 += 1 }
            for await _ in gate.stream { break }
            return Self.reactionPublication(id, revision: 2, own: kind)
        }
        let store = TestStore(
            initialState: CompetitionFeature.State(
                publication: Self.reactionPublication(id, revision: 1, own: nil)
            )
        ) { CompetitionFeature() } withDependencies: { $0.competitionClient = client }

        await store.send(.reactionTapped(id, .day(2), .fire)) {
            $0.pendingReactions[key] = .some(.fire)
        }
        XCTAssertEqual(
            store.state.reactionControl(for: id) { _ in }
                .selection(.day(2), in: store.state.publication!.dashboard.competitions[0]),
            .fire,
            "The chip shows the pending choice"
        )
        await store.send(.reactionTapped(id, .day(2), .salute))
        gate.continuation.yield()
        await store.receive(.publication(Self.reactionPublication(id, revision: 2, own: .fire))) {
            $0.publication = Self.reactionPublication(id, revision: 2, own: .fire)
        }
        await store.receive(.reactionFinished(key, succeeded: true)) {
            $0.pendingReactions = [:]
        }
        XCTAssertEqual(calls.value, 1)
        await store.finish()
    }

    @MainActor
    func testStopClearsAndCancelsNudges() async {
        let id = CompetitionID(UUID())
        let now = Date(timeIntervalSince1970: 1_786_979_520)
        let started = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        var client = InviteCreationRecorder(results: []).client
        client.nudge = { _ in
            started.continuation.yield()
            for await _ in gate.stream { break }
            return now
        }
        let store = TestStore(initialState: Self.nudgeState(id, evaluatedAt: now)) {
            CompetitionFeature()
        } withDependencies: { $0.competitionClient = client }
        await store.send(.nudgeTapped(id)) { $0.nudges[id] = .sending }
        for await _ in started.stream { break }
        await store.send(.stop) { $0.nudges = [:] }
        // The suspended request finishing after sign-out changes nothing.
        gate.continuation.yield()
        await store.finish()
        XCTAssertEqual(store.state.nudges, [:])
    }

    @MainActor
    func testBlockTappedRunsBlockCommand() async {
        let id = CompetitionID(UUID())
        let blocked = LockIsolated<[CompetitionID]>([])
        var client = InviteCreationRecorder(results: []).client
        client.block = { id in
            blocked.withValue { $0.append(id) }
            return .remote(revision: 0)
        }
        let store = TestStore(initialState: CompetitionFeature.State(
            publication: .remote(revision: 1)
        )) { CompetitionFeature() } withDependencies: { $0.competitionClient = client }
        await store.send(.blockTapped(id)) { $0.commandIDsInFlight = [id] }
        await store.receive(.commandFinished(id, expectedRevision: 0)) {
            $0.commandIDsInFlight = []
        }
        XCTAssertEqual(blocked.value, [id])
        await store.finish()
    }

    @MainActor
    func testBlockLooksPhotosUpAgainSoTheirsGoes() async throws {
        let id = CompetitionID(UUID())
        let sam = Self.recipient.id
        var client = InviteCreationRecorder(results: []).client
        client.block = { _ in .remote(revision: 0) }
        // The server no longer lists the photo of someone you blocked.
        client.loadProfilePhotos = { _ in [] }
        var initial = CompetitionFeature.State(
            publication: .remote(revision: 1, competitions: [Self.presentation(id)])
        )
        initial.profilePhotos[sam] = try XCTUnwrap(ProfilePhoto(
            jpeg: ProfilePhotoTestLabServer.fixtureJPEG(red: 0.2, green: 0.4, blue: 0.6), version: UUID()
        ))
        let store = TestStore(initialState: initial) { CompetitionFeature() }
            withDependencies: { $0.competitionClient = client }
        await store.send(.blockTapped(id)) { $0.commandIDsInFlight = [id] }
        await store.receive(.commandFinished(id, expectedRevision: 0)) {
            $0.commandIDsInFlight = []
        }
        await store.receive(.profilePhotosNeeded([sam]))
        await store.receive(\.profilePhotosListed) { $0.profilePhotos[sam] = nil }
        await store.finish()
    }

    @MainActor
    func testBlockedPeopleLoadKeepsListOnFailedRefresh() async {
        let alex = AuthenticatedProfile(id: UUID(), displayName: "Alex")
        let answers = LockIsolated<[Result<[AuthenticatedProfile], CompetitionRemoteFailure>]>([
            .failure(.retryableTransport), .success([alex]), .failure(.retryableTransport),
        ])
        var client = InviteCreationRecorder(results: []).client
        client.loadBlockedProfiles = { try answers.withValue { $0.removeFirst() }.get() }
        let store = TestStore(initialState: CompetitionFeature.State()) { CompetitionFeature() }
            withDependencies: { $0.competitionClient = client }
        // A first-load failure leaves the section hidden.
        await store.send(.blockedPeopleRequested)
        await store.receive(.blockedPeopleResponse(nil))
        await store.send(.blockedPeopleRequested)
        await store.receive(.blockedPeopleResponse([alex])) { $0.blockedPeople = [alex] }
        // A failed refresh keeps the list shown.
        await store.send(.blockedPeopleRequested)
        await store.receive(.blockedPeopleResponse(nil))
        await store.finish()
    }

    @MainActor
    func testUnblockRemovesPersonOrShowsError() async {
        let alex = AuthenticatedProfile(id: UUID(), displayName: "Alex")
        let sam = AuthenticatedProfile(id: UUID(), displayName: "Sam")
        let unblocked = LockIsolated<[UUID]>([])
        var client = InviteCreationRecorder(results: []).client
        client.unblock = { id in
            guard id == alex.id else { throw CompetitionRemoteFailure.retryableTransport }
            unblocked.withValue { $0.append(id) }
        }
        client.loadBlockedProfiles = { [sam] }
        var initial = CompetitionFeature.State()
        initial.blockedPeople = [alex, sam]
        let store = TestStore(initialState: initial) { CompetitionFeature() }
            withDependencies: { $0.competitionClient = client }
        await store.send(.unblockTapped(alex.id)) { $0.unblocksInFlight = [alex.id] }
        await store.receive(.unblockFinished(alex.id, succeeded: true)) {
            $0.unblocksInFlight = []
            $0.blockedPeople = [sam]
        }
        await store.send(.unblockTapped(sam.id)) { $0.unblocksInFlight = [sam.id] }
        await store.receive(.unblockFinished(sam.id, succeeded: false)) {
            $0.unblocksInFlight = []
            $0.unblockFailed = sam.id
        }
        // The next load clears the error.
        await store.send(.blockedPeopleRequested) { $0.unblockFailed = nil }
        await store.receive(.blockedPeopleResponse([sam]))
        XCTAssertEqual(unblocked.value, [alex.id])
        await store.finish()
    }

    @MainActor
    func testUnblockDropsAListLoadThatStartedBeforeIt() async {
        let alex = AuthenticatedProfile(id: UUID(), displayName: "Alex")
        var client = InviteCreationRecorder(results: []).client
        // The load read before the unblock and answers after it.
        client.loadBlockedProfiles = {
            try await Task.sleep(for: .seconds(30))
            return [alex]
        }
        client.unblock = { _ in }
        var initial = CompetitionFeature.State()
        initial.blockedPeople = [alex]
        let store = TestStore(initialState: initial) { CompetitionFeature() }
            withDependencies: { $0.competitionClient = client }
        await store.send(.blockedPeopleRequested)
        await store.send(.unblockTapped(alex.id)) { $0.unblocksInFlight = [alex.id] }
        await store.receive(.unblockFinished(alex.id, succeeded: true)) {
            $0.unblocksInFlight = []
            $0.blockedPeople = []
        }
        // No blockedPeopleResponse([alex]) arrives to bring the row back.
        await store.finish()
    }

    @MainActor
    func testLateUnblockResultAfterStopIsDropped() async {
        let alex = AuthenticatedProfile(id: UUID(), displayName: "Alex")
        var initial = CompetitionFeature.State()
        initial.blockedPeople = [alex]
        initial.unblocksInFlight = [alex.id]
        let store = TestStore(initialState: initial) { CompetitionFeature() }
        await store.send(.stop) {
            $0.blockedPeople = nil
            $0.unblocksInFlight = []
        }
        await store.send(.unblockFinished(alex.id, succeeded: false))
        await store.finish()
    }

    @MainActor
    func testStopClearsBlockedPeople() async {
        let alex = AuthenticatedProfile(id: UUID(), displayName: "Alex")
        var initial = CompetitionFeature.State()
        initial.blockedPeople = [alex]
        initial.unblockFailed = alex.id
        let store = TestStore(initialState: initial) { CompetitionFeature() }
        await store.send(.stop) {
            $0.blockedPeople = nil
            $0.unblockFailed = nil
        }
        await store.finish()
    }

    @MainActor
    func testChallengeLinkRequested() async throws {
        let code = try XCTUnwrap(CompetitionChallengeLinkCode(rawValue: "Xb3kP9qL2mN8vR4tY6wZ1a"))
        let url = try XCTUnwrap(URL(string: "https://\(Self.host)/c/Xb3kP9qL2mN8vR4tY6wZ1a"))
        let resetElsewhere = try XCTUnwrap(CompetitionChallengeLinkCode(rawValue: "Qm7tR2vX9pL4kN8wB3cY6z"))
        let resetURL = try XCTUnwrap(URL(string: "https://\(Self.host)/c/Qm7tR2vX9pL4kN8wB3cY6z"))
        let answers = LockIsolated<[Result<CompetitionChallengeLinkCode, CompetitionRemoteFailure>]>([
            .success(code), .success(resetElsewhere), .failure(.retryableTransport),
        ])
        var client = InviteCreationRecorder(results: []).client
        client.loadChallengeLinkCode = { try answers.withValue { $0.removeFirst() }.get() }
        var links = CompetitionInviteLinkClient.fixture(
            host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: []
        )
        links.makeChallengeLink = { URL(string: "https://\(Self.host)/c/\($0.rawValue)") }
        let store = TestStore(initialState: CompetitionFeature.State()) { CompetitionFeature() }
            withDependencies: {
                $0.competitionClient = client
                $0.competitionInviteLinkClient = links
            }
        await store.send(.challengeLinkRequested)
        await store.receive(.challengeLinkResponse(url)) { $0.challengeLink = url }
        // Loaded again each time it's shown, so a reset elsewhere shows.
        await store.send(.challengeLinkRequested)
        await store.receive(.challengeLinkResponse(resetURL)) { $0.challengeLink = resetURL }
        // A failed refresh keeps the link shown.
        await store.send(.challengeLinkRequested)
        await store.receive(.challengeLinkResponse(nil))

        var failing = InviteCreationRecorder(results: []).client
        failing.loadChallengeLinkCode = { throw CompetitionRemoteFailure.retryableTransport }
        let failed = TestStore(initialState: CompetitionFeature.State()) { CompetitionFeature() }
            withDependencies: { $0.competitionClient = failing }
        await failed.send(.challengeLinkRequested)
        await failed.receive(.challengeLinkResponse(nil)) { $0.challengeLinkLoadFailed = true }
        await store.finish()
        await failed.finish()
    }

    @MainActor
    func testForegroundRefreshesOnlyAShownChallengeLink() async throws {
        let code = try XCTUnwrap(CompetitionChallengeLinkCode(rawValue: "Qm7tR2vX9pL4kN8wB3cY6z"))
        let old = try XCTUnwrap(URL(string: "https://\(Self.host)/c/Xb3kP9qL2mN8vR4tY6wZ1a"))
        let new = try XCTUnwrap(URL(string: "https://\(Self.host)/c/Qm7tR2vX9pL4kN8wB3cY6z"))
        let loads = LockIsolated(0)
        var client = InviteCreationRecorder(results: []).client
        client.loadChallengeLinkCode = {
            loads.withValue { $0 += 1 }
            return code
        }
        var links = CompetitionInviteLinkClient.fixture(
            host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: []
        )
        links.makeChallengeLink = { URL(string: "https://\(Self.host)/c/\($0.rawValue)") }
        var initial = CompetitionFeature.State()
        initial.challengeLink = old
        let store = TestStore(initialState: initial) { CompetitionFeature() }
            withDependencies: {
                $0.competitionClient = client
                $0.competitionInviteLinkClient = links
            }
        store.exhaustivity = .off
        await store.send(.sceneBecameActive)
        await store.receive(.challengeLinkResponse(new)) { $0.challengeLink = new }
        await store.finish()
        XCTAssertEqual(loads.value, 1)

        let unshown = TestStore(initialState: CompetitionFeature.State()) { CompetitionFeature() }
            withDependencies: {
                $0.competitionClient = client
                $0.competitionInviteLinkClient = links
            }
        unshown.exhaustivity = .off
        await unshown.send(.sceneBecameActive)
        await unshown.finish()
        XCTAssertEqual(loads.value, 1)
    }

    @MainActor
    func testChallengeLinkResetShowsNewLinkOrKeepsOldWithError() async throws {
        let old = try XCTUnwrap(URL(string: "https://\(Self.host)/c/Xb3kP9qL2mN8vR4tY6wZ1a"))
        let new = try XCTUnwrap(URL(string: "https://\(Self.host)/c/Qm7tR2vX9pL4kN8wB3cY6z"))
        let newCode = try XCTUnwrap(CompetitionChallengeLinkCode(rawValue: "Qm7tR2vX9pL4kN8wB3cY6z"))
        let outcomes = LockIsolated<[Result<CompetitionChallengeLinkCode, CompetitionRemoteFailure>]>([
            .failure(.retryableTransport), .success(newCode), .failure(.retryableTransport),
        ])
        let oldCode = try XCTUnwrap(CompetitionChallengeLinkCode(rawValue: "Xb3kP9qL2mN8vR4tY6wZ1a"))
        let thirdCode = try XCTUnwrap(CompetitionChallengeLinkCode(rawValue: "Zz9yX8wV7uT6sR5qP4oN3m"))
        let third = try XCTUnwrap(URL(string: "https://\(Self.host)/c/Zz9yX8wV7uT6sR5qP4oN3m"))
        let serverCodes = LockIsolated([oldCode, thirdCode])
        var client = InviteCreationRecorder(results: []).client
        client.resetChallengeLinkCode = {
            try outcomes.withValue { $0.removeFirst() }.get()
        }
        client.loadChallengeLinkCode = { serverCodes.withValue { $0.removeFirst() } }
        var links = CompetitionInviteLinkClient.fixture(
            host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: []
        )
        links.makeChallengeLink = { URL(string: "https://\(Self.host)/c/\($0.rawValue)") }
        var initial = CompetitionFeature.State()
        initial.challengeLink = old
        let store = TestStore(initialState: initial) { CompetitionFeature() }
            withDependencies: {
                $0.competitionClient = client
                $0.competitionInviteLinkClient = links
            }

        // Failure says so and loads the link again to show the server's.
        await store.send(.challengeLinkResetConfirmed) { $0.challengeLinkIsResetting = true }
        await store.receive(.challengeLinkResetResponse(nil)) {
            $0.challengeLinkIsResetting = false
            $0.challengeLinkResetFailed = true
        }
        await store.receive(.challengeLinkRequested)
        await store.receive(.challengeLinkResponse(old))

        // Success shows the new link and clears the error.
        await store.send(.challengeLinkResetConfirmed) {
            $0.challengeLinkIsResetting = true
            $0.challengeLinkResetFailed = false
        }
        await store.receive(.challengeLinkResetResponse(new)) {
            $0.challengeLinkIsResetting = false
            $0.challengeLink = new
        }

        // A reset whose answer was lost but that did happen: the reload shows
        // the new link and drops the error.
        await store.send(.challengeLinkResetConfirmed) { $0.challengeLinkIsResetting = true }
        await store.receive(.challengeLinkResetResponse(nil)) {
            $0.challengeLinkIsResetting = false
            $0.challengeLinkResetFailed = true
        }
        await store.receive(.challengeLinkRequested)
        await store.receive(.challengeLinkResponse(third)) {
            $0.challengeLink = third
            $0.challengeLinkResetFailed = false
        }

        await store.finish()

        // Signing out clears the reset state with the link.
        var resetting = initial
        resetting.challengeLinkIsResetting = true
        resetting.challengeLinkResetFailed = true
        let stopped = TestStore(initialState: resetting) { CompetitionFeature() }
            withDependencies: { $0.competitionClient = client }
        // A confirm or a load while a reset is running does nothing.
        await stopped.send(.challengeLinkResetConfirmed)
        await stopped.send(.challengeLinkRequested)
        await stopped.send(.stop) {
            $0.challengeLink = nil
            $0.challengeLinkIsResetting = false
            $0.challengeLinkResetFailed = false
        }
        await stopped.finish()
    }

    @MainActor
    func testFindRecipientAcceptsLinkCodeAndLegacyUUID() async throws {
        let recipient = Self.recipient
        let code = try XCTUnwrap(CompetitionChallengeLinkCode(rawValue: "Xb3kP9qL2mN8vR4tY6wZ1a"))
        let resolved = LockIsolated<[String]>([])
        var client = InviteCreationRecorder(results: []).client
        client.resolveChallengeLink = { code in
            resolved.withValue { $0.append(code.rawValue) }
            return "Maya"
        }
        client.resolveInviteRecipient = { _ in recipient }
        let store = TestStore(initialState: CompetitionFeature.State()) { CompetitionFeature() }
            withDependencies: { $0.competitionClient = client }
        // A link is kept as its code; only a 1.0.2 account code is an id.
        for (input, found) in [
            ("healthcomp://challenge/Xb3kP9qL2mN8vR4tY6wZ1a",
             CompetitionFeature.InviteRecipient(link: code, displayName: "Maya")),
            ("Xb3kP9qL2mN8vR4tY6wZ1a", .init(link: code, displayName: "Maya")),
            (recipient.id.uuidString.lowercased(), .init(recipient)),
        ] {
            await store.send(.inviteRecipientCodeChanged(input)) {
                $0.inviteRecipientCode = input
                $0.inviteRecipient = nil
                $0.inviteRecipientStatus = .idle
            }
            await store.send(.findInviteRecipientTapped) { $0.inviteRecipientStatus = .lookingUp }
            await store.receive(.inviteRecipientResponse(input, .success(found))) {
                $0.inviteRecipient = found
                $0.inviteRecipientStatus = .idle
            }
        }
        XCTAssertEqual(resolved.value, ["Xb3kP9qL2mN8vR4tY6wZ1a", "Xb3kP9qL2mN8vR4tY6wZ1a"])

        var own = InviteCreationRecorder(results: []).client
        own.resolveChallengeLink = { _ in throw CompetitionRemoteFailure.ownChallengeLink }
        let ownStore = TestStore(initialState: CompetitionFeature.State()) { CompetitionFeature() }
            withDependencies: { $0.competitionClient = own }
        await ownStore.send(.inviteRecipientCodeChanged("Xb3kP9qL2mN8vR4tY6wZ1a")) {
            $0.inviteRecipientCode = "Xb3kP9qL2mN8vR4tY6wZ1a"
        }
        await ownStore.send(.findInviteRecipientTapped) { $0.inviteRecipientStatus = .lookingUp }
        await ownStore.receive(.inviteRecipientResponse("Xb3kP9qL2mN8vR4tY6wZ1a", .failure(.ownChallengeLink))) {
            $0.inviteRecipientStatus = .ownCode
        }
        await store.finish()
        await ownStore.finish()
    }

    @MainActor
    func testChallengeSheetStatusDerivesChallengedYouAndInMatch() {
        let identity = RemoteCompetitionOpponentIdentity.identity(for: Self.recipient.id)
        let incoming = Self.presentation(
            CompetitionID(UUID()),
            lifecycle: .pending(direction: .incoming, createdAt: .distantPast, expiresAt: nil),
            identity: identity
        )
        let scheduled = Self.presentation(CompetitionID(UUID()), lifecycle: .scheduled, identity: identity)
        let tallying = Self.presentation(
            CompetitionID(UUID()), lifecycle: .tallying(startedAt: .distantPast), identity: identity
        )
        var state = CompetitionFeature.State(
            publication: .remote(revision: 1, competitions: [incoming, scheduled]),
            inviteRecipient: .init(Self.recipient)
        )
        XCTAssertEqual(state.challengeSheetStatus, .challengedYou(incoming))
        state.publication = .remote(revision: 2, competitions: [scheduled])
        XCTAssertEqual(state.challengeSheetStatus, .inMatch(scheduled))
        // A tallying match no longer blocks a new challenge, as on the server.
        state.publication = .remote(revision: 3, competitions: [tallying])
        XCTAssertEqual(state.challengeSheetStatus, .ready)
    }

    @MainActor
    func testRematchStateDerivesChallengedYouAndInMatch() {
        let identity = RemoteCompetitionOpponentIdentity.identity(for: Self.recipient.id)
        let parent = Self.presentation(CompetitionID(UUID()), identity: identity)
        let incoming = Self.presentation(
            CompetitionID(UUID()),
            lifecycle: .pending(direction: .incoming, createdAt: .distantPast, expiresAt: nil),
            identity: identity
        )
        let active = Self.presentation(CompetitionID(UUID()), lifecycle: .active(dayOrdinal: 2), identity: identity)
        var state = CompetitionFeature.State(
            publication: .remote(revision: 1, competitions: [parent, active, incoming])
        )
        XCTAssertEqual(state.rematchState(for: parent), .inMatch(active))
        state.publication = .remote(revision: 2, competitions: [parent, incoming])
        XCTAssertEqual(state.rematchState(for: parent), .challengedYou(incoming))
        // Their rematch of this match is .received, not .challengedYou.
        let rematch = Self.presentation(
            CompetitionID(UUID()),
            lifecycle: .pending(direction: .incoming, createdAt: .distantPast, expiresAt: nil),
            identity: identity,
            rematchParentID: parent.id
        )
        state.publication = .remote(revision: 3, competitions: [parent, rematch])
        XCTAssertEqual(state.rematchState(for: parent), .received(rematch))
        // A cancelled child counts as no child.
        let cancelled = Self.presentation(
            CompetitionID(UUID()),
            lifecycle: .cancelled(at: .distantPast),
            identity: identity,
            rematchParentID: parent.id
        )
        state.publication = .remote(revision: 4, competitions: [parent, cancelled])
        XCTAssertEqual(state.rematchState(for: parent), .available)
    }

    @MainActor
    func testServerConflictSetsConflictAndReconciles() async {
        let recorder = InviteCreationRecorder(results: [.failure(.incomingChallengeExists)])
        let key = UUID(uuidString: "00000000-0000-4000-8000-0000000000c1")!
        let store = TestStore(initialState: CompetitionFeature.State(
            publication: .remote(revision: 1),
            inviteRecipient: .init(Self.recipient)
        )) { CompetitionFeature() } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(
                host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: [key]
            )
        }
        await store.send(.createInviteTapped) {
            $0.inviteCreations[.sheet] = Creation(
                recipient: .profile(Self.recipient.id), idempotencyKey: key, status: .creating
            )
        }
        await store.receive(.createInviteResponse(.sheet, idempotencyKey: key, .failure(.incomingChallengeExists))) {
            $0.inviteCreations[.sheet]?.status = .failed(.conflict)
        }
        await store.finish()
        XCTAssertEqual(recorder.reconcileTriggers, [.pullToRefresh])
    }

    private static func link(_ character: Character) throws -> CompetitionInviteShareLink {
        let token = try XCTUnwrap(CompetitionInviteClaimToken(rawValue: String(repeating: character, count: 43)))
        return try XCTUnwrap(CompetitionInviteShareLink(host: host, token: token))
    }

    private static func presentation(
        _ id: CompetitionID,
        lifecycle: CompetitionLifecyclePresentation = .completed(
            outcome: .tie, basis: .stableAcrossPostBoundaryReads, completedAt: .distantPast
        ),
        identity: String = RemoteCompetitionOpponentIdentity.identity(
            for: RemoteCompetitionFeatureTests.recipient.id
        ),
        rematchParentID: CompetitionID? = nil
    ) -> CompetitionPresentation {
        CompetitionPresentation(
            id: id, ownerDisplayName: "Sender", opponentDisplayName: recipient.displayName,
            opponentIdentity: identity,
            lifecycle: lifecycle,
            acceptedConfiguration: nil, userPoints: 0, opponentPoints: 0, days: [],
            currentDayOrdinal: nil, lastRefresh: nil, tally: nil, terminalResult: nil,
            rematchParentID: rematchParentID
        )
    }

    private static func pending(
        _ id: CompetitionID,
        identity: String,
        expiresAt: Date? = nil,
        rematchParentID: CompetitionID? = nil
    ) -> CompetitionPresentation {
        presentation(
            id,
            lifecycle: .pending(direction: .outgoing, createdAt: .distantPast, expiresAt: expiresAt),
            identity: identity,
            rematchParentID: rematchParentID
        )
    }
}

private extension CompetitionPublication {
    static func remote(revision: UInt64, competitions: [CompetitionPresentation] = [], issues: [CompetitionClientIssue] = []) -> Self {
        Self(
            publicationRevision: revision,
            dashboard: CompetitionDashboard(
                competitions: competitions,
                awards: [],
                issues: issues,
                hiddenTerminalCompetitionCount: 0
            ),
            source: .remoteParticipants
        )
    }
}

private final class InviteCreationRecorder: @unchecked Sendable {
    enum Result {
        case success(
            CompetitionID,
            token: String,
            expectedRevision: UInt64
        )
        case failure(CompetitionRemoteFailure)
    }

    private let lock = NSLock()
    private var queuedResults: [Result]
    private var capturedRequests: [CompetitionInviteCreationRequest] = []
    private var capturedReconcileTriggers: [ActivityRefreshTrigger] = []

    init(results: [Result]) {
        self.queuedResults = results
    }

    var requestCount: Int { lock.withLock { capturedRequests.count } }
    var requests: [CompetitionInviteCreationRequest] {
        lock.withLock { capturedRequests }
    }
    var reconcileTriggers: [ActivityRefreshTrigger] {
        lock.withLock { capturedReconcileTriggers }
    }

    var client: CompetitionClient {
        CompetitionClient(
            start: { AsyncStream { $0.finish() } },
            updates: { AsyncStream { $0.finish() } },
            reconcileAll: { [weak self] trigger in
                self?.lock.withLock { self?.capturedReconcileTriggers.append(trigger) }
                return Self.publication
            },
            accept: { _ in Self.publication },
            decline: { _ in Self.publication },
            archive: { _ in Self.publication },
            rematch: { _ in Self.publication },
            reinvite: { Self.publication },
            waitUntil: { _ in },
            stop: {},
            createInvite: { [weak self] request in
                guard let self else {
                    throw CompetitionRemoteFailure.operationFailed
                }
                return try self.lock.withLock {
                    self.capturedRequests.append(request)
                    guard !self.queuedResults.isEmpty else {
                        throw CompetitionRemoteFailure.operationFailed
                    }
                    switch self.queuedResults.removeFirst() {
                    case let .success(id, token, expectedRevision):
                        return CompetitionInviteCreationOutcome(
                            invite: try CompetitionInvite(
                                competitionID: id.rawValue,
                                token: token
                            ),
                            expectedPublicationRevision: expectedRevision
                        )
                    case let .failure(failure):
                        throw failure
                    }
                }
            }
        )
    }

    private static let publication = CompetitionPublication(
        publicationRevision: 0,
        dashboard: CompetitionDashboard(
            competitions: [],
            awards: [],
            issues: [],
            hiddenTerminalCompetitionCount: 0
        )
    )
}

private extension CompetitionInviteLinkClient {
    static func fixture(
        host: String,
        timeZoneIdentifier: String,
        idempotencyKeys: [UUID]
    ) -> Self {
        let keys = LockIsolated(idempotencyKeys)
        return Self(
            makeShareLink: { rawToken in
                guard let token = CompetitionInviteClaimToken(
                    rawValue: rawToken
                ) else {
                    return nil
                }
                return CompetitionInviteShareLink(host: host, token: token)
            },
            currentTimeZoneIdentifier: { timeZoneIdentifier },
            makeIdempotencyKey: {
                keys.withValue { $0.isEmpty ? UUID() : $0.removeFirst() }
            },
            canCreateShareLink: { true }
        )
    }
}
