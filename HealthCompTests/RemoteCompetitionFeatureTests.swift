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
        await store.receive(.inviteRecipientResponse(recipient.id, .success(recipient))) {
            $0.inviteRecipientStatus = .idle
            $0.inviteRecipient = recipient
        }
        // Native fields may send their unchanged value again when focus ends.
        await store.send(.inviteRecipientCodeChanged(recipient.id.uuidString))
        await store.send(.inviteRecipientCodeChanged("another code")) {
            $0.inviteRecipientCode = "another code"
            $0.inviteRecipient = nil
        }
        await store.send(.inviteRecipientResponse(recipient.id, .success(recipient)))
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
            await store.receive(.inviteRecipientResponse(Self.recipient.id, .failure(failure))) {
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
            inviteCreations: [.sheet: Creation(recipientID: Self.recipient.id, idempotencyKey: key, status: .creating)],
            inviteRecipient: Self.recipient
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
            inviteCreations: [.sheet: Creation(recipientID: Self.recipient.id, idempotencyKey: key, status: .creating)],
            inviteRecipient: Self.recipient
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
        let store = TestStore(initialState: CompetitionFeature.State(inviteRecipient: Self.recipient)) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: [key])
        }
        await store.send(.createInviteTapped) {
            $0.inviteCreations[.sheet] = Creation(recipientID: Self.recipient.id, idempotencyKey: key, status: .creating)
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
    func testFailedDiscoveryAfterSuccessfulCreationPreservesShareLinkAndRetryKey() async throws {
        let id = CompetitionID(UUID())
        let key = UUID()
        let link = try Self.link("C")
        for issue in [CompetitionClientIssue.remoteUnavailable, .storageUnavailable, .competitionFailures([id])] {
            let failed = CompetitionPublication.remote(revision: 4, issues: [issue])
            let store = TestStore(initialState: CompetitionFeature.State(
                publication: failed,
                inviteCreations: [.sheet: Creation(recipientID: Self.recipient.id, idempotencyKey: key, status: .creating)],
                inviteRecipient: Self.recipient
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
                inviteCreations: [.sheet: Creation(recipientID: Self.recipient.id, idempotencyKey: key, status: .creating)],
                inviteRecipient: Self.recipient
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
                inviteCreations: [.rematch(of: parentID): Creation(recipientID: Self.recipient.id, idempotencyKey: UUID(), status: .sent(childID))],
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
                .sheet: Creation(recipientID: Self.recipient.id, idempotencyKey: UUID(), status: .sent(accepted)),
                .rematch(of: parentID): Creation(recipientID: Self.recipient.id, idempotencyKey: UUID(), status: .sent(expired)),
                .rematch(of: otherParent): Creation(recipientID: Self.recipient.id, idempotencyKey: UUID(), status: .sent(missing)),
                .rematch(of: thirdParent): Creation(recipientID: Self.recipient.id, idempotencyKey: UUID(), status: .sent(stillPending)),
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
                .sheet: Creation(recipientID: Self.recipient.id, idempotencyKey: UUID(), status: .creating),
                .rematch(of: parentID): Creation(recipientID: Self.recipient.id, idempotencyKey: UUID(), status: .sent(parentID)),
            ],
            inviteLinks: [parentID: .ready(link, minimumRevision: 1)],
            inviteRecipient: Self.recipient
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
        var initial = CompetitionFeature.State(inviteRecipient: Self.recipient)
        initial.inviteRecipientCode = Self.recipient.id.uuidString
        let store = TestStore(initialState: initial) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: [key])
        }
        await store.send(.createInviteTapped) {
            $0.inviteCreations[.sheet] = Creation(recipientID: Self.recipient.id, idempotencyKey: key, status: .creating)
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
            inviteCreations: [.sheet: Creation(recipientID: Self.recipient.id, idempotencyKey: UUID(), status: .sent(id))],
            inviteRecipient: Self.recipient
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
            inviteCreations: [.sheet: Creation(recipientID: Self.recipient.id, idempotencyKey: key, status: .creating)],
            inviteRecipient: Self.recipient
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
                recipientID: Self.recipient.id, idempotencyKey: idempotencyKey, status: .creating
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
            inviteRecipient: sheetPerson
        )
        initial.inviteRecipientCode = sheetPerson.id.uuidString
        let store = TestStore(initialState: initial) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: [keyA, keyB])
        }
        await store.send(.rematchTapped(parentA)) {
            $0.inviteCreations[.rematch(of: parentA)] = Creation(recipientID: Self.recipient.id, idempotencyKey: keyA, status: .creating)
        }
        await store.receive(.createInviteResponse(.rematch(of: parentA), idempotencyKey: keyA, .success(link: linkA, competitionID: childA, expectedRevision: 3))) {
            $0.inviteLinks[childA] = .ready(linkA, minimumRevision: 3)
            $0.inviteCreations[.rematch(of: parentA)]?.status = .sent(childA)
        }
        await store.send(.rematchTapped(parentB)) {
            $0.inviteCreations[.rematch(of: parentB)] = Creation(recipientID: Self.recipient.id, idempotencyKey: keyB, status: .creating)
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
            $0.inviteCreations[.rematch(of: parentID)] = Creation(recipientID: Self.recipient.id, idempotencyKey: key, status: .creating)
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
    func testSheetAccountGoneClearsPersonWithNotFound() async {
        let key = UUID()
        let recorder = InviteCreationRecorder(results: [.failure(.recipientUnavailable)])
        let store = TestStore(initialState: CompetitionFeature.State(inviteRecipient: Self.recipient)) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: [key])
        }
        await store.send(.createInviteTapped) {
            $0.inviteCreations[.sheet] = Creation(recipientID: Self.recipient.id, idempotencyKey: key, status: .creating)
        }
        await store.receive(.createInviteResponse(.sheet, idempotencyKey: key, .failure(.recipientUnavailable))) {
            $0.inviteCreations = [:]
            $0.inviteRecipient = nil
            $0.inviteRecipientStatus = .notFound
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
            inviteRecipient: Self.recipient
        )
        func slot(_ status: Creation.Status) -> Creation {
            Creation(recipientID: Self.recipient.id, idempotencyKey: UUID(), status: status)
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

    @MainActor
    func testDivergentDuplicateRotatesKey() async {
        let first = UUID()
        let rotated = UUID()
        let recorder = InviteCreationRecorder(results: [.failure(.divergentDuplicate), .failure(.retryableTransport)])
        let store = TestStore(initialState: CompetitionFeature.State(inviteRecipient: Self.recipient)) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: [first, rotated])
        }
        await store.send(.createInviteTapped) {
            $0.inviteCreations[.sheet] = Creation(recipientID: Self.recipient.id, idempotencyKey: first, status: .creating)
        }
        await store.receive(.createInviteResponse(.sheet, idempotencyKey: first, .failure(.divergentDuplicate))) {
            $0.inviteCreations[.sheet] = Creation(recipientID: Self.recipient.id, idempotencyKey: rotated, status: .failed(.connection))
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
        let store = TestStore(initialState: CompetitionFeature.State(inviteRecipient: Self.recipient)) {
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
            $0.inviteCreations[.sheet] = Creation(recipientID: Self.recipient.id, idempotencyKey: idempotencyKey, status: .creating)
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
        let store = TestStore(initialState: CompetitionFeature.State(inviteRecipient: Self.recipient)) {
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
                recipientID: Self.recipient.id, idempotencyKey: idempotencyKey, status: .failed(.unavailable)
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
                    recipientID: Self.recipient.id, idempotencyKey: idempotencyKey, status: .failed(.connection)
                )],
                inviteRecipient: Self.recipient
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
        let store = TestStore(initialState: CompetitionFeature.State(inviteRecipient: Self.recipient)) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(host: Self.host, timeZoneIdentifier: "UTC", idempotencyKeys: [idempotencyKey, UUID()])
        }

        await store.send(.createInviteTapped) {
            $0.inviteCreations[.sheet] = Creation(recipientID: Self.recipient.id, idempotencyKey: idempotencyKey, status: .creating)
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
