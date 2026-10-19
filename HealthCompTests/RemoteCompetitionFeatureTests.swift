import CompetitionCore
import ComposableArchitecture
import Foundation
import XCTest
@testable import HealthComp

final class RemoteCompetitionFeatureTests: XCTestCase {
    private static let recipient = AuthenticatedProfile(
        id: UUID(uuidString: "82000000-0000-4000-8000-000000000099")!,
        displayName: "Alexandria Catherine Montgomery-Wellington"
    )

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
        await store.send(.inviteRecipientCodeChanged("not-an-account-code")) {
            $0.inviteRecipientCode = "not-an-account-code"
        }
        await store.send(.findInviteRecipientTapped) { $0.inviteRecipientStatus = .unavailable }
        await store.send(.createInviteTapped)
        await store.finish()
    }

    @MainActor
    func testAcceptedCreationRetryDoesNotOfferConsumedInvitationLink() async throws {
        let id = CompetitionID(UUID())
        let key = UUID()
        let token = try XCTUnwrap(CompetitionInviteClaimToken(rawValue: String(repeating: "A", count: 43)))
        let link = try XCTUnwrap(CompetitionInviteShareLink(host: "invites.healthcomp.example", token: token))
        let store = TestStore(initialState: CompetitionFeature.State(
            publication: .remote(revision: 4, competitions: [Self.presentation(id)]),
            inviteCreationStatus: .creating,
            inviteCreationIdempotencyKey: key,
            inviteRecipient: Self.recipient
        )) { CompetitionFeature() }
        await store.send(.createInviteResponse(idempotencyKey: key, .success(
            link: link, competitionID: id, expectedRevision: 4
        ))) {
            $0.inviteCreationStatus = .idle
            $0.inviteCreationIdempotencyKey = nil
        }
        await store.finish()
    }

    @MainActor
    func testExpiredInvitationMissingFromNextDashboardClearsShareLink() async throws {
        let id = CompetitionID(UUID())
        let key = UUID()
        let token = try XCTUnwrap(CompetitionInviteClaimToken(rawValue: String(repeating: "B", count: 43)))
        let link = try XCTUnwrap(CompetitionInviteShareLink(host: "invites.healthcomp.example", token: token))
        let store = TestStore(initialState: CompetitionFeature.State(
            inviteCreationStatus: .creating, inviteCreationIdempotencyKey: key,
            inviteRecipient: Self.recipient
        )) { CompetitionFeature() }
        await store.send(.createInviteResponse(idempotencyKey: key, .success(link: link, competitionID: id, expectedRevision: 4))) {
            $0.inviteCreationStatus = .ready
            $0.createdInviteLink = link
            $0.createdInviteCompetitionID = id
            $0.createdInviteExpectedPublicationRevision = 4
        }
        await store.send(.publication(.remote(revision: 3))) { $0.publication = .remote(revision: 3) }
        await store.send(.publication(.remote(revision: 4))) {
            $0.publication = .remote(revision: 4)
            $0.inviteCreationStatus = .idle
            $0.inviteCreationIdempotencyKey = nil
            $0.createdInviteLink = nil
            $0.createdInviteCompetitionID = nil
            $0.createdInviteExpectedPublicationRevision = 0
        }
        await store.finish()
    }

    @MainActor
    func testDuplicatePendingInvitationIsNotPresentedAsRetryable() async {
        let key = UUID()
        let recorder = InviteCreationRecorder(results: [.failure(.pendingInvitationExists)])
        let store = TestStore(initialState: CompetitionFeature.State(inviteRecipient: Self.recipient)) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(host: "invites.healthcomp.example", timeZoneIdentifier: "UTC", idempotencyKey: key)
        }
        await store.send(.createInviteTapped) {
            $0.inviteCreationStatus = .creating
            $0.inviteCreationIdempotencyKey = key
        }
        await store.receive(.createInviteResponse(idempotencyKey: key, .failure(.pendingInvitationExists))) {
            $0.inviteCreationStatus = .pendingInvitationExists
        }
        XCTAssertEqual(recorder.requestCount, 1)
        await store.finish()
    }

    @MainActor
    func testFailedDiscoveryAfterSuccessfulCreationPreservesShareLinkAndRetryKey() async throws {
        let id = CompetitionID(UUID())
        let key = UUID()
        let token = try XCTUnwrap(CompetitionInviteClaimToken(rawValue: String(repeating: "C", count: 43)))
        let link = try XCTUnwrap(CompetitionInviteShareLink(host: "invites.healthcomp.example", token: token))
        for issue in [CompetitionClientIssue.remoteUnavailable, .storageUnavailable, .competitionFailures([id])] {
            let failed = CompetitionPublication.remote(revision: 4, issues: [issue])
            let store = TestStore(initialState: CompetitionFeature.State(
                publication: failed, inviteCreationStatus: .creating,
                inviteCreationIdempotencyKey: key, inviteRecipient: Self.recipient
            )) { CompetitionFeature() }
            await store.send(.createInviteResponse(idempotencyKey: key, .success(link: link, competitionID: id, expectedRevision: 4))) {
                $0.inviteCreationStatus = .ready
                $0.createdInviteLink = link
                $0.createdInviteCompetitionID = id
                $0.createdInviteExpectedPublicationRevision = 4
            }
            await store.send(.publication(.remote(revision: 5))) {
                $0.publication = .remote(revision: 5)
                $0.inviteCreationStatus = .idle
                $0.inviteCreationIdempotencyKey = nil
                $0.createdInviteLink = nil
                $0.createdInviteCompetitionID = nil
                $0.createdInviteExpectedPublicationRevision = 0
            }
            await store.finish()
        }
    }
    @MainActor
    func testStopClearsInviteCreationStateAndShareLink() async throws {
        let idempotencyKey = UUID(
            uuidString: "82000000-0000-0000-0000-000000000010"
        )!
        let token = try XCTUnwrap(
            CompetitionInviteClaimToken(
                rawValue: "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"
            )
        )
        let link = try XCTUnwrap(
            CompetitionInviteShareLink(
                host: "invites.healthcomp.example",
                token: token
            )
        )
        let store = TestStore(
            initialState: CompetitionFeature.State(
                inviteCreationStatus: .creating,
                inviteCreationIdempotencyKey: idempotencyKey,
                inviteCreationRematchParentID: CompetitionID(
                    UUID(
                        uuidString:
                            "82000000-0000-0000-0000-000000000011"
                    )!
                ),
                createdInviteLink: link,
                inviteRecipient: Self.recipient
            )
        ) {
            CompetitionFeature()
        }

        await store.send(.stop) {
            $0.inviteCreationStatus = .idle
            $0.inviteCreationIdempotencyKey = nil
            $0.inviteCreationRematchParentID = nil
            $0.createdInviteLink = nil
            $0.inviteRecipient = nil
        }
        await store.finish()
    }

    @MainActor
    func testRemoteRematchCreatesShareableInviteAgainstCompletedParent() async throws {
        let idempotencyKey = UUID(
            uuidString: "82000000-0000-0000-0000-000000000005"
        )!
        let parentID = CompetitionID(
            UUID(uuidString: "82000000-0000-0000-0000-000000000006")!
        )
        let childID = CompetitionID(
            UUID(uuidString: "82000000-0000-0000-0000-000000000007")!
        )
        let rawToken = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
        let token = try XCTUnwrap(
            CompetitionInviteClaimToken(rawValue: rawToken)
        )
        let link = try XCTUnwrap(
            CompetitionInviteShareLink(
                host: "invites.healthcomp.example",
                token: token
            )
        )
        let recorder = InviteCreationRecorder(
            results: [
                .success(
                    childID,
                    token: rawToken,
                    expectedRevision: 8
                ),
            ]
        )
        let store = TestStore(
            initialState: CompetitionFeature.State(
                publication: .remote(revision: 7, competitions: [Self.presentation(parentID)])
            )
        ) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(
                host: "invites.healthcomp.example",
                timeZoneIdentifier: "America/New_York",
                idempotencyKey: idempotencyKey
            )
        }

        await store.send(.rematchTapped(parentID)) {
            $0.inviteCreationStatus = .creating
            $0.inviteCreationIdempotencyKey = idempotencyKey
            $0.inviteCreationRematchParentID = parentID
            $0.inviteRecipient = Self.recipient
            $0.inviteRecipientCode = Self.recipient.id.uuidString.lowercased()
        }
        await store.receive(
            .createInviteResponse(
                idempotencyKey: idempotencyKey,
                .success(
                    link: link,
                    competitionID: childID,
                    expectedRevision: 8
                )
            )
        ) {
            $0.inviteCreationStatus = .ready
            $0.createdInviteLink = link
            $0.createdInviteCompetitionID = childID
            $0.createdInviteExpectedPublicationRevision = 8
        }

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.rematchParentID, parentID.rawValue)
        XCTAssertEqual(recorder.requests.first?.recipientProfileID, Self.recipient.id)
        XCTAssertEqual(
            recorder.requests.first?.timeZoneIdentifier,
            "America/New_York"
        )
        await store.finish()
    }

    @MainActor
    func testCreateInviteBuildsRedactedHTTPSLinkFromServerToken() async throws {
        let idempotencyKey = UUID(
            uuidString: "82000000-0000-0000-0000-000000000001"
        )!
        let competitionID = CompetitionID(
            UUID(uuidString: "82000000-0000-0000-0000-000000000002")!
        )
        let rawToken = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let token = try XCTUnwrap(
            CompetitionInviteClaimToken(rawValue: rawToken)
        )
        let link = try XCTUnwrap(
            CompetitionInviteShareLink(
                host: "invites.healthcomp.example",
                token: token
            )
        )
        let recorder = InviteCreationRecorder(
            results: [
                .success(
                    competitionID,
                    token: rawToken,
                    expectedRevision: 4
                ),
            ]
        )
        let store = TestStore(initialState: CompetitionFeature.State(inviteRecipient: Self.recipient)) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(
                host: "invites.healthcomp.example",
                timeZoneIdentifier: "America/Los_Angeles",
                idempotencyKey: idempotencyKey
            )
        }

        await store.send(.createInviteTapped) {
            $0.inviteCreationStatus = .creating
            $0.inviteCreationIdempotencyKey = idempotencyKey
        }
        await store.receive(
            .createInviteResponse(
                idempotencyKey: idempotencyKey,
                .success(
                    link: link,
                    competitionID: competitionID,
                    expectedRevision: 4
                )
            )
        ) {
            $0.inviteCreationStatus = .ready
            $0.createdInviteLink = link
            $0.createdInviteCompetitionID = competitionID
            $0.createdInviteExpectedPublicationRevision = 4
        }

        XCTAssertEqual(recorder.requestCount, 1)
        XCTAssertEqual(
            recorder.requests.first?.timeZoneIdentifier,
            "America/Los_Angeles"
        )
        XCTAssertEqual(recorder.requests.first?.idempotencyKey, idempotencyKey)
        XCTAssertFalse(String(reflecting: store.state).contains(rawToken))
        await store.finish()
    }

    @MainActor
    func testCreateInviteWithoutLinkConfigurationFailsBeforeServerWrite()
        async
    {
        let idempotencyKey = UUID(
            uuidString: "82000000-0000-4000-8000-000000000020"
        )!
        let competitionID = CompetitionID(
            UUID(uuidString: "82000000-0000-4000-8000-000000000021")!
        )
        let recorder = InviteCreationRecorder(
            results: [
                .success(
                    competitionID,
                    token: "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",
                    expectedRevision: 1
                ),
            ]
        )
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
            $0.inviteCreationStatus = .configurationUnavailable
        }

        XCTAssertEqual(recorder.requestCount, 0)
        await store.finish()
    }

    @MainActor
    func testReadyInviteWithoutShareLinkRetriesWithSameIdempotencyKey() async throws {
        let idempotencyKey = UUID(
            uuidString: "82000000-0000-0000-0000-000000000012"
        )!
        let competitionID = CompetitionID(
            UUID(uuidString: "82000000-0000-0000-0000-000000000013")!
        )
        let rawToken = "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"
        let token = try XCTUnwrap(
            CompetitionInviteClaimToken(rawValue: rawToken)
        )
        let link = try XCTUnwrap(
            CompetitionInviteShareLink(
                host: "invites.healthcomp.example",
                token: token
            )
        )
        let recorder = InviteCreationRecorder(
            results: [
                .success(
                    competitionID,
                    token: rawToken,
                    expectedRevision: 9
                ),
            ]
        )
        let store = TestStore(
            initialState: CompetitionFeature.State(
                inviteCreationStatus: .ready,
                inviteCreationIdempotencyKey: idempotencyKey,
                inviteRecipient: Self.recipient
            )
        ) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(
                host: "invites.healthcomp.example",
                timeZoneIdentifier: "UTC",
                idempotencyKey: UUID()
            )
        }

        await store.send(.createInviteTapped) {
            $0.inviteCreationStatus = .creating
        }
        await store.receive(
            .createInviteResponse(
                idempotencyKey: idempotencyKey,
                .success(
                    link: link,
                    competitionID: competitionID,
                    expectedRevision: 9
                )
            )
        ) {
            $0.inviteCreationStatus = .ready
            $0.createdInviteLink = link
            $0.createdInviteCompetitionID = competitionID
            $0.createdInviteExpectedPublicationRevision = 9
        }

        XCTAssertEqual(
            recorder.requests.map(\.idempotencyKey),
            [idempotencyKey]
        )
        await store.finish()
    }

    @MainActor
    func testRetryableCreateReusesIdempotencyKey() async throws {
        let idempotencyKey = UUID(
            uuidString: "82000000-0000-0000-0000-000000000003"
        )!
        let competitionID = CompetitionID(
            UUID(uuidString: "82000000-0000-0000-0000-000000000004")!
        )
        let rawToken = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
        let token = try XCTUnwrap(
            CompetitionInviteClaimToken(rawValue: rawToken)
        )
        let link = try XCTUnwrap(
            CompetitionInviteShareLink(
                host: "invites.healthcomp.example",
                token: token
            )
        )
        let recorder = InviteCreationRecorder(
            results: [
                .failure(.retryableTransport),
                .success(
                    competitionID,
                    token: rawToken,
                    expectedRevision: 2
                ),
            ]
        )
        let store = TestStore(initialState: CompetitionFeature.State(inviteRecipient: Self.recipient)) {
            CompetitionFeature()
        } withDependencies: {
            $0.competitionClient = recorder.client
            $0.competitionInviteLinkClient = .fixture(
                host: "invites.healthcomp.example",
                timeZoneIdentifier: "UTC",
                idempotencyKey: idempotencyKey
            )
        }

        await store.send(.createInviteTapped) {
            $0.inviteCreationStatus = .creating
            $0.inviteCreationIdempotencyKey = idempotencyKey
        }
        await store.receive(
            .createInviteResponse(
                idempotencyKey: idempotencyKey,
                .failure(.retryableTransport)
            )
        ) {
            $0.inviteCreationStatus = .retryable
        }
        await store.send(.createInviteTapped) {
            $0.inviteCreationStatus = .creating
        }
        await store.receive(
            .createInviteResponse(
                idempotencyKey: idempotencyKey,
                .success(
                    link: link,
                    competitionID: competitionID,
                    expectedRevision: 2
                )
            )
        ) {
            $0.inviteCreationStatus = .ready
            $0.createdInviteLink = link
            $0.createdInviteCompetitionID = competitionID
            $0.createdInviteExpectedPublicationRevision = 2
        }

        XCTAssertEqual(
            recorder.requests.map(\.idempotencyKey),
            [idempotencyKey, idempotencyKey]
        )
        await store.finish()
    }

    private static func presentation(_ id: CompetitionID) -> CompetitionPresentation {
        CompetitionPresentation(
            id: id, ownerDisplayName: "Sender", opponentDisplayName: recipient.displayName,
            opponentIdentity: RemoteCompetitionOpponentIdentity.identity(for: recipient.id),
            lifecycle: .completed(outcome: .tie, basis: .stableAcrossPostBoundaryReads, completedAt: .distantPast),
            acceptedConfiguration: nil, userPoints: 0, opponentPoints: 0, days: [],
            currentDayOrdinal: nil, lastRefresh: nil, tally: nil, terminalResult: nil
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

    init(results: [Result]) {
        self.queuedResults = results
    }

    var requestCount: Int { lock.withLock { capturedRequests.count } }
    var requests: [CompetitionInviteCreationRequest] {
        lock.withLock { capturedRequests }
    }

    var client: CompetitionClient {
        CompetitionClient(
            start: { AsyncStream { $0.finish() } },
            updates: { AsyncStream { $0.finish() } },
            reconcileAll: { _ in Self.publication },
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
        idempotencyKey: UUID
    ) -> Self {
        Self(
            makeShareLink: { rawToken in
                guard let token = CompetitionInviteClaimToken(
                    rawValue: rawToken
                ) else {
                    return nil
                }
                return CompetitionInviteShareLink(host: host, token: token)
            },
            currentTimeZoneIdentifier: { timeZoneIdentifier },
            makeIdempotencyKey: { idempotencyKey },
            canCreateShareLink: { true }
        )
    }
}
