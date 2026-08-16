import CompetitionCore
import ComposableArchitecture
import Foundation
import XCTest
@testable import HealthComp

final class RemoteCompetitionFeatureTests: XCTestCase {
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
                createdInviteLink: link
            )
        ) {
            CompetitionFeature()
        }

        await store.send(.stop) {
            $0.inviteCreationStatus = .idle
            $0.inviteCreationIdempotencyKey = nil
            $0.inviteCreationRematchParentID = nil
            $0.createdInviteLink = nil
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
                publication: .remote(revision: 7)
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
        }

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests[0].rematchParentID, parentID.rawValue)
        XCTAssertEqual(
            recorder.requests[0].timeZoneIdentifier,
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
        let store = TestStore(initialState: CompetitionFeature.State()) {
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
        let store = TestStore(initialState: CompetitionFeature.State()) {
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
                inviteCreationIdempotencyKey: idempotencyKey
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
        let store = TestStore(initialState: CompetitionFeature.State()) {
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
        }

        XCTAssertEqual(
            recorder.requests.map(\.idempotencyKey),
            [idempotencyKey, idempotencyKey]
        )
        await store.finish()
    }
}

private extension CompetitionPublication {
    static func remote(revision: UInt64) -> Self {
        Self(
            publicationRevision: revision,
            dashboard: CompetitionDashboard(
                competitions: [],
                awards: [],
                issues: [],
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
