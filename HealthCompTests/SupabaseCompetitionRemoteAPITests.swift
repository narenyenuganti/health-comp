import Foundation
import XCTest
@testable import HealthComp

final class SupabaseCompetitionRemoteAPITests: XCTestCase {
    func testRoutesEveryOperationWithExactAppOwnedRequests() async throws {
        let inviteToken = Data(repeating: 0x42, count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(profileObject(name: "Beta Alice"))),
            .response(200, try jsonData(profileObject(name: "Beta Alice 2"))),
            .response(200, try jsonData([])),
            .response(200, try jsonData(descriptorObject())),
            .response(201, try jsonData([
                "competitionId": competitionID.uuidString.lowercased(),
                "token": inviteToken,
            ])),
            .response(200, try jsonData([
                "competitionId": competitionID.uuidString.lowercased(),
            ])),
            .response(200, try jsonData([
                "disposition": "appended",
                "acceptedCentiPoints": 27_500,
                "wireContentSHA256": digest("a"),
                "acceptedServerSeq": "1",
                "competitionCursor": "1",
            ])),
            .response(200, try jsonData([
                "disposition": "appended",
                "windowCommitmentSHA256": digest("b"),
                "serverCursor": "2",
            ])),
            .response(200, try jsonData([
                "competition_id": competitionID.uuidString.lowercased(),
                "after_server_seq": "0",
                "snapshot_server_seq": "0",
                "next_server_seq": "0",
                "has_more": false,
                "changes": [],
            ])),
            .response(200, try jsonData(installationObject(state: "active"))),
            .response(200, try jsonData(installationObject(state: "revoked"))),
        ])
        let api = makeAPI(harness)
        let inviteRequest = try CompetitionInviteCreationRequest(
            timeZoneIdentifier: "America/Los_Angeles",
            rematchParentID: nil,
            idempotencyKey: idempotencyID
        )
        let claimRequest = try CompetitionInviteClaimRequest(token: inviteToken)
        let scoreRequest = try fixtureScoreRequest()
        let attestationRequest = try CompetitionAttestationRequest(
            competitionID: competitionID,
            semanticEventID: attestationEventID,
            attestationVersion: 2,
            basis: .stable,
            acceptedRevisions: [1, 2, 3, 4, 5, 6, 7],
            windowCommitmentSHA256: digest("b")
        )
        let cursor = try CompetitionSynchronizationCursor(
            competitionID: competitionID,
            lastSeenServerSequence: 0
        )
        let installationRequest = try CompetitionInstallationRequest(
            installationID: installationID,
            apnsToken: String(repeating: "a1", count: 32),
            environment: .sandbox
        )

        let bootstrappedProfile = try await api.bootstrapProfile(nil)
        let updatedProfile = try await api.updateProfile("Beta Alice 2")
        let listedCompetitions = try await api.listCompetitions()
        let fetchedCompetition = try await api.fetchCompetition(competitionID)
        let createdInvite = try await api.createInvite(inviteRequest)
        let claimedInvite = try await api.claimInvite(claimRequest)
        let scoreResponse = try await api.appendScoreRevision(scoreRequest)
        let attestationReceipt = try await api.submitAttestation(
            attestationRequest
        )
        let changePage = try await api.fetchChanges(cursor, 100)
        let registeredInstallation = try await api.registerInstallation(
            installationRequest
        )
        let removedInstallation = try await api.removeInstallation(
            installationID
        )

        XCTAssertEqual(bootstrappedProfile.displayName, "Beta Alice")
        XCTAssertEqual(updatedProfile.displayName, "Beta Alice 2")
        XCTAssertEqual(listedCompetitions, [])
        XCTAssertEqual(fetchedCompetition.competitionID, competitionID)
        XCTAssertEqual(createdInvite.token, inviteToken)
        XCTAssertEqual(claimedInvite.competitionID, competitionID)
        XCTAssertEqual(scoreResponse.disposition, .appended)
        XCTAssertEqual(attestationReceipt.entityServerSequence, 2)
        XCTAssertEqual(changePage.nextServerSequence, 0)
        XCTAssertEqual(registeredInstallation.state, .active)
        XCTAssertEqual(removedInstallation.state, .revoked)

        let requests = await harness.recordedRequests()
        XCTAssertEqual(requests.count, 11)
        try assertRPC(
            requests[0],
            name: "bootstrap_current_profile",
            body: ["suggested_display_name": NSNull()]
        )
        try assertRPC(
            requests[1],
            name: "update_current_profile",
            body: ["new_display_name": "Beta Alice 2"]
        )
        XCTAssertEqual(requests[2], .listCompetitions)
        XCTAssertEqual(requests[3], .fetchCompetition(competitionID))
        try assertFunction(
            requests[4],
            name: "create-competition-invite",
            body: try jsonObject(
                CompetitionWireCodec.encode(
                    inviteRequest,
                    contract: .inviteCreationRequest
                )
            )
        )
        try assertFunction(
            requests[5],
            name: "claim-competition-invite",
            body: ["token": inviteToken]
        )
        try assertFunction(
            requests[6],
            name: "submit-score-revision",
            body: try jsonObject(
                CompetitionWireCodec.encode(
                    scoreRequest,
                    contract: .scoreRevisionRequest
                )
            )
        )
        try assertFunction(
            requests[7],
            name: "attest-final-window",
            body: try jsonObject(
                CompetitionWireCodec.encode(
                    attestationRequest,
                    contract: .attestationRequest
                )
            )
        )
        try assertRPC(
            requests[8],
            name: "fetch_competition_changes",
            body: [
                "competition_id": competitionID.uuidString.lowercased(),
                "after_server_seq": "0",
                "page_size": 100,
            ]
        )
        try assertRPC(
            requests[9],
            name: "register_current_device_installation",
            body: try jsonObject(
                CompetitionWireCodec.encode(
                    installationRequest,
                    contract: .installationRequest
                )
            )
        )
        try assertRPC(
            requests[10],
            name: "remove_current_device_installation",
            body: [
                "installation_id": installationID.uuidString.lowercased(),
            ]
        )
    }

    func testRejectedScoreIsAReconciliationReceiptAndIsNotRetried()
        async throws
    {
        let harness = CompetitionTransportHarness(stubs: [
            .response(409, try jsonData([
                "disposition": "rejected",
                "code": "revision_regression",
                "acceptedCentiPoints": 27_500,
                "wireContentSHA256": digest("a"),
                "acceptedServerSeq": "1",
                "competitionCursor": "3",
            ])),
        ])

        let response = try await makeAPI(harness)
            .appendScoreRevision(fixtureScoreRequest())

        XCTAssertEqual(response.disposition, .rejected)
        XCTAssertEqual(response.rejectionCode, .revisionRegression)
        let requestCount = await harness.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testOnlyTransportAndRetryableHTTPFailuresMapAsRetryable() async {
        let cases: [CompetitionTransportStub] = [
            .failure(.network),
            .failure(.relay),
            .response(408, Data()),
            .response(429, Data()),
            .response(500, Data()),
            .response(503, Data()),
        ]

        for stub in cases {
            let harness = CompetitionTransportHarness(stubs: [stub])
            let failure = await remoteFailure {
                _ = try await makeAPI(harness)
                    .fetchCompetition(competitionID)
            }
            XCTAssertEqual(failure, .retryableTransport)
            let requestCount = await harness.requestCount()
            XCTAssertEqual(requestCount, 1)
        }
    }

    func testTypedFourHundredsMapToStableNonRetryableFailures() async throws {
        let cases: [(Int, String, CompetitionRemoteFailure)] = [
            (401, "unauthorized", .unauthenticated),
            (403, "rematch_not_allowed", .forbidden),
            (404, "competition_not_found", .notFound),
            (409, "divergent_duplicate", .divergentDuplicate),
            (409, "idempotency_conflict", .divergentDuplicate),
            (409, "revision_regression", .staleRevision),
            (409, "attestation_regression", .staleRevision),
            (409, "attestation_downgrade", .staleRevision),
            (409, "competition_finalized", .finalizedCompetition),
            (409, "incompatible_policy", .incompatiblePolicy),
            (400, "wrong_policy", .incompatiblePolicy),
            (400, "server_contract_mismatch", .serverContractMismatch),
            (400, "invalid_request", .serverContractMismatch),
        ]

        for (status, code, expected) in cases {
            let harness = CompetitionTransportHarness(stubs: [
                .response(status, try errorData(code: code)),
            ])
            let failure = await remoteFailure {
                _ = try await makeAPI(harness)
                    .fetchCompetition(competitionID)
            }
            XCTAssertEqual(failure, expected, "Unexpected mapping for \(code)")
            XCTAssertNotEqual(failure, .retryableTransport)
            let requestCount = await harness.requestCount()
            XCTAssertEqual(requestCount, 1)
        }
    }

    func testSDKPostgrestErrorsMapWithoutHTTPStatus() async {
        let cases: [(String, CompetitionRemoteFailure)] = [
            ("PGRST116", .notFound),
            ("PGRST301", .unauthenticated),
            ("PGRST302", .unauthenticated),
            ("PGRST303", .unauthenticated),
        ]

        for (code, expected) in cases {
            let harness = CompetitionTransportHarness(stubs: [
                .failure(
                    .server(
                        statusCode: nil,
                        code: code,
                        message: "redacted"
                    )
                ),
            ])
            let failure = await remoteFailure {
                _ = try await makeAPI(harness)
                    .fetchCompetition(competitionID)
            }
            XCTAssertEqual(failure, expected, "Unexpected mapping for \(code)")
            let requestCount = await harness.requestCount()
            XCTAssertEqual(requestCount, 1)
        }
    }

    func testClaimFailuresRemainPrivacyCollapsed() async throws {
        let token = Data(repeating: 0x42, count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let request = try CompetitionInviteClaimRequest(token: token)
        let cases = [
            (400, "invalid_request"),
            (403, "self_claim_forbidden"),
            (404, "invite_unavailable"),
            (409, "invite_consumed"),
        ]

        for (status, code) in cases {
            let harness = CompetitionTransportHarness(stubs: [
                .response(status, try errorData(code: code)),
            ])
            let failure = await remoteFailure {
                _ = try await makeAPI(harness).claimInvite(request)
            }
            XCTAssertEqual(failure, .inviteUnavailable)
            let requestCount = await harness.requestCount()
            XCTAssertEqual(requestCount, 1)
        }
    }

    func testCancellationIsPreservedWithoutRetry() async {
        let harness = CompetitionTransportHarness(stubs: [
            .failure(.cancelled),
        ])

        let failure = await remoteFailure {
            _ = try await makeAPI(harness).fetchCompetition(competitionID)
        }

        XCTAssertEqual(failure, .cancelled)
        let requestCount = await harness.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testAttestationAcknowledgmentCannotFabricateDomainState() async throws {
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData([
                "disposition": "appended",
                "windowCommitmentSHA256": digest("b"),
                "serverCursor": "2",
                "participant_profile_id": profileID.uuidString.lowercased(),
            ])),
        ])
        let request = try CompetitionAttestationRequest(
            competitionID: competitionID,
            semanticEventID: attestationEventID,
            attestationVersion: 2,
            basis: .stable,
            acceptedRevisions: [1, 2, 3, 4, 5, 6, 7],
            windowCommitmentSHA256: digest("b")
        )

        let failure = await remoteFailure {
            _ = try await makeAPI(harness).submitAttestation(request)
        }

        XCTAssertEqual(failure, .serverContractMismatch)
    }

    func testDeletionStaysUnavailableAndSendsNothing() async {
        let harness = CompetitionTransportHarness(stubs: [])

        let failure = await remoteFailure {
            try await makeAPI(harness).requestAccountDeletion()
        }

        XCTAssertEqual(failure, .accountDeletionUnavailable)
        let requestCount = await harness.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testInvalidLocalParametersFailBeforeTransport() async {
        let harness = CompetitionTransportHarness(stubs: [])
        let api = makeAPI(harness)

        let invalidName = await remoteFailure {
            _ = try await api.updateProfile(" Former competitor ")
        }
        let invalidPage = await remoteFailure {
            _ = try await api.fetchChanges(
                try CompetitionSynchronizationCursor(
                    competitionID: competitionID,
                    lastSeenServerSequence: 0
                ),
                201
            )
        }

        XCTAssertEqual(invalidName, .serverContractMismatch)
        XCTAssertEqual(invalidPage, .serverContractMismatch)
        let requestCount = await harness.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testFetchChangesRejectsResponseLargerThanRequestedPage() async throws {
        let change: (Int) -> [String: Any] = { sequence in
            [
                "server_seq": String(sequence),
                "kind": "profile_presentation_changed",
                "entity_id": self.profileID.uuidString.lowercased(),
                "occurred_at": "2026-08-12T12:00:00Z",
                "payload": [
                    "profile_id": self.profileID.uuidString.lowercased(),
                    "display_name": "Beta Alice",
                ],
            ]
        }
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData([
                "competition_id": competitionID.uuidString.lowercased(),
                "after_server_seq": "0",
                "snapshot_server_seq": "2",
                "next_server_seq": "2",
                "has_more": false,
                "changes": [change(1), change(2)],
            ])),
        ])
        let cursor = try CompetitionSynchronizationCursor(
            competitionID: competitionID,
            lastSeenServerSequence: 0
        )

        let failure = await remoteFailure {
            _ = try await makeAPI(harness).fetchChanges(cursor, 1)
        }

        XCTAssertEqual(failure, .serverContractMismatch)
        let requestCount = await harness.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    private func makeAPI(
        _ harness: CompetitionTransportHarness
    ) -> CompetitionRemoteAPI {
        SupabaseCompetitionRemoteAPI.make(
            transport: CompetitionRemoteTransport { request in
                try await harness.send(request)
            }
        )
    }

    private func remoteFailure<Value>(
        _ operation: () async throws -> Value
    ) async -> CompetitionRemoteFailure? {
        do {
            _ = try await operation()
            return nil
        } catch let failure as CompetitionRemoteFailure {
            return failure
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))")
            return nil
        }
    }

    private func assertRPC(
        _ request: CompetitionRemoteTransportRequest,
        name: String,
        body: Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard case let .rpc(actualName, data) = request else {
            return XCTFail("Expected RPC request", file: file, line: line)
        }
        XCTAssertEqual(actualName, name, file: file, line: line)
        XCTAssertEqual(
            try jsonObject(data) as? NSDictionary,
            body as? NSDictionary,
            file: file,
            line: line
        )
    }

    private func assertFunction(
        _ request: CompetitionRemoteTransportRequest,
        name: String,
        body: Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard case let .function(actualName, data) = request else {
            return XCTFail("Expected function request", file: file, line: line)
        }
        XCTAssertEqual(actualName, name, file: file, line: line)
        XCTAssertEqual(
            try jsonObject(data) as? NSDictionary,
            body as? NSDictionary,
            file: file,
            line: line
        )
    }

    private func fixtureScoreRequest() throws -> CompetitionScoreRevisionRequest {
        try CompetitionScoreRevisionRequest(
            competitionID: competitionID,
            semanticEventID: scoreEventID,
            dayOrdinal: 1,
            clientRevision: 1,
            evaluatedAt: Date(timeIntervalSince1970: 1_786_536_000),
            moveMode: "activeEnergyKilocalories",
            standMode: "standHours",
            moveBasisPoints: 10_000,
            exerciseBasisPoints: 5_000,
            standBasisPoints: 12_500,
            availabilityReason: "available",
            scoringPolicyIdentity: "healthcomp.activity-score.v1",
            wireContentSHA256: digest("a")
        )
    }

    private func profileObject(name: String) -> [String: Any] {
        [
            "id": profileID.uuidString.lowercased(),
            "display_name": name,
        ]
    }

    private func descriptorObject() -> [String: Any] {
        [
            "id": competitionID.uuidString.lowercased(),
            "creator_profile_id": profileID.uuidString.lowercased(),
            "time_zone_identifier": NSNull(),
            "start_day": NSNull(),
            "scoring_policy_identity": "healthcomp.activity-score.v1",
            "lifecycle": "pending",
            "invitation_expires_at": "2026-08-12T12:00:00Z",
            "best_available_deadline": NSNull(),
            "rematch_parent_id": NSNull(),
            "next_server_seq": 1,
            "participants": [[
                "profile_id": profileID.uuidString.lowercased(),
                "role": "creator",
                "state": "accepted",
                "profile": profileObject(name: "Beta Alice"),
            ]],
        ]
    }

    private func installationObject(state: String) -> [String: Any] {
        [
            "installation_id": installationID.uuidString.lowercased(),
            "environment": "sandbox",
            "state": state,
        ]
    }

    private func errorData(code: String) throws -> Data {
        try jsonData([
            "error": ["code": code, "message": "redacted"],
        ])
    }

    private func jsonData(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func jsonObject(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private var competitionID: UUID {
        UUID(uuidString: "63000000-0000-4000-8000-000000000001")!
    }
    private var profileID: UUID {
        UUID(uuidString: "11000000-0000-4000-8000-000000000001")!
    }
    private var idempotencyID: UUID {
        UUID(uuidString: "66000000-0000-4000-8000-000000000001")!
    }
    private var scoreEventID: UUID {
        UUID(uuidString: "64000000-0000-4000-8000-000000000001")!
    }
    private var attestationEventID: UUID {
        UUID(uuidString: "65000000-0000-4000-8000-000000000001")!
    }
    private var installationID: UUID {
        UUID(uuidString: "85000000-0000-4000-8000-000000000001")!
    }
}

private enum CompetitionTransportStub: Sendable {
    case response(Int, Data)
    case failure(CompetitionRemoteTransportFailure)
}

private actor CompetitionTransportHarness {
    private var stubs: [CompetitionTransportStub]
    private var requests: [CompetitionRemoteTransportRequest] = []

    init(stubs: [CompetitionTransportStub]) {
        self.stubs = stubs
    }

    func send(
        _ request: CompetitionRemoteTransportRequest
    ) throws -> CompetitionRemoteTransportResponse {
        requests.append(request)
        guard !stubs.isEmpty else {
            throw CompetitionRemoteTransportFailure.other
        }
        switch stubs.removeFirst() {
        case let .response(status, data):
            return CompetitionRemoteTransportResponse(
                statusCode: status,
                data: data
            )
        case let .failure(failure):
            throw failure
        }
    }

    func recordedRequests() -> [CompetitionRemoteTransportRequest] {
        requests
    }

    func requestCount() -> Int {
        requests.count
    }
}
