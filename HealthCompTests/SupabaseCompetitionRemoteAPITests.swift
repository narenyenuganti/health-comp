import Foundation
import XCTest
@testable import HealthComp

final class SupabaseCompetitionRemoteAPITests: XCTestCase {
    func testRecipientResolutionUsesOnlyExactAccountCodeAndRejectsAnotherIdentity() async throws {
        let id = UUID(uuidString: "22000000-0000-4000-8000-000000000001")!
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(["id": id.uuidString.lowercased(), "display_name": "Chosen account"])),
            .response(200, try jsonData(["id": profileID.uuidString.lowercased(), "display_name": "Wrong account"])),
        ])
        let api = makeAPI(harness)
        let recipient = try await api.resolveInviteRecipient(id)
        XCTAssertEqual(recipient, AuthenticatedProfile(id: id, displayName: "Chosen account"))
        let requests = await harness.recordedRequests()
        try assertRPC(requests[0], name: "resolve_invitation_recipient", body: ["profile_id": id.uuidString.lowercased()])
        let failure = await remoteFailure { _ = try await api.resolveInviteRecipient(id) }
        XCTAssertEqual(failure, .serverContractMismatch)
    }
    func testNotificationMutesRouteThroughExactAccountRPCs() async throws {
        let opponentID = UUID(
            uuidString: "12000000-0000-4000-8000-000000000002"
        )!
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData([
                "opponent_profile_ids": [
                    opponentID.uuidString.lowercased(),
                ],
            ])),
            .response(200, try jsonData([
                "opponent_profile_id": opponentID.uuidString.lowercased(),
                "is_muted": true,
            ])),
        ])
        let api = makeAPI(harness)

        let muted = try await api.loadMutedOpponentProfileIDs()
        try await api.setOpponentMuted(opponentID, true)

        XCTAssertEqual(muted, [opponentID])
        let requests = await harness.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        try assertRPC(
            requests[0],
            name: "list_current_notification_mutes",
            body: [:]
        )
        try assertRPC(
            requests[1],
            name: "set_current_notification_mute",
            body: [
                "opponent_profile_id": opponentID.uuidString.lowercased(),
                "is_muted": true,
            ]
        )
    }

    func testNotificationMuteResponsesRejectUnknownOrDivergentFields()
        async throws
    {
        let opponentID = UUID(
            uuidString: "12000000-0000-4000-8000-000000000002"
        )!
        let unknownFieldHarness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData([
                "opponent_profile_ids": [],
                "profile_id": profileID.uuidString.lowercased(),
            ])),
        ])
        let divergentHarness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData([
                "opponent_profile_id": profileID.uuidString.lowercased(),
                "is_muted": false,
            ])),
        ])

        let unknownFailure = await remoteFailure {
            _ = try await self.makeAPI(unknownFieldHarness)
                .loadMutedOpponentProfileIDs()
        }
        let divergentFailure = await remoteFailure {
            try await self.makeAPI(divergentHarness)
                .setOpponentMuted(opponentID, true)
        }

        XCTAssertEqual(unknownFailure, .serverContractMismatch)
        XCTAssertEqual(divergentFailure, .serverContractMismatch)
    }

    func testArchiveRoutesThroughAuthenticatedIdempotentRPC() async throws {
        let harness = CompetitionTransportHarness(stubs: [
            .response(
                200,
                try jsonData([
                    "competition_id": competitionID.uuidString.lowercased(),
                ])
            ),
        ])

        try await makeAPI(harness).archiveCompetition(competitionID)

        let requests = await harness.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        try assertRPC(
            requests[0],
            name: "archive_competition",
            body: [
                "competition_id": competitionID.uuidString.lowercased(),
            ]
        )
    }

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
                "version": 1,
                "challengeID": appAttestChallengeID.uuidString.lowercased(),
                "challenge": Data(repeating: 0x31, count: 32)
                    .base64EncodedString(),
                "expiresAt": "2026-08-15T20:05:00Z",
                "proofKind": "attestation",
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
            recipientProfileID: UUID(uuidString: "22000000-0000-4000-8000-000000000001")!,
            timeZoneIdentifier: "America/Los_Angeles",
            rematchParentID: nil,
            idempotencyKey: idempotencyID
        )
        let claimRequest = try CompetitionInviteClaimRequest(token: inviteToken)
        let scoreRequest = try fixtureScoreRequest()
        let challengeRequest = try CompetitionAppAttestChallengeRequest(
            installationID: installationID,
            payloadSHA256: digest("c"),
            keyID: appAttestKeyID
        )
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
        let challenge = try await api.issueAppAttestChallenge(
            challengeRequest
        )
        let attestedScoreRequest = try CompetitionAttestedScoreRevisionRequest(
            score: scoreRequest,
            appAttest: CompetitionAppAttestProof(
                challengeID: challenge.challengeID,
                installationID: installationID,
                keyID: appAttestKeyID,
                proofKind: challenge.proofKind,
                object: Data("attestation-object".utf8)
            )
        )
        let scoreResponse = try await api.submitAttestedScoreRevision(
            attestedScoreRequest
        )
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
        XCTAssertEqual(challenge.proofKind, .attestation)
        XCTAssertEqual(scoreResponse.disposition, .appended)
        XCTAssertEqual(attestationReceipt.entityServerSequence, 2)
        XCTAssertEqual(changePage.nextServerSequence, 0)
        XCTAssertEqual(registeredInstallation.state, .active)
        XCTAssertEqual(removedInstallation.state, .revoked)

        let requests = await harness.recordedRequests()
        XCTAssertEqual(requests.count, 12)
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
            name: "app-attest-challenge",
            body: try jsonObject(
                CompetitionWireCodec.encode(
                    challengeRequest,
                    contract: .appAttestChallengeRequest
                )
            )
        )
        try assertFunction(
            requests[7],
            name: "submit-score-revision",
            body: try jsonObject(
                CompetitionWireCodec.encode(
                    attestedScoreRequest,
                    contract: .attestedScoreRevisionRequest
                )
            )
        )
        try assertFunction(
            requests[8],
            name: "attest-final-window",
            body: try jsonObject(
                CompetitionWireCodec.encode(
                    attestationRequest,
                    contract: .attestationRequest
                )
            )
        )
        try assertRPC(
            requests[9],
            name: "fetch_competition_changes",
            body: [
                "competition_id": competitionID.uuidString.lowercased(),
                "after_server_seq": "0",
                "page_size": 100,
            ]
        )
        try assertRPC(
            requests[10],
            name: "register_current_device_installation",
            body: try jsonObject(
                CompetitionWireCodec.encode(
                    installationRequest,
                    contract: .installationRequest
                )
            )
        )
        try assertRPC(
            requests[11],
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
            .submitAttestedScoreRevision(fixtureAttestedScoreRequest())

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

    func testCompetitionDiscoveryRetriesOneTransientTransportFailure()
        async throws
    {
        let harness = CompetitionTransportHarness(stubs: [
            .failure(.network),
            .response(200, try jsonData([])),
        ])

        let failure = await remoteFailure {
            let competitions = try await makeAPI(harness)
                .listCompetitions()
            XCTAssertEqual(competitions, [])
        }

        XCTAssertNil(failure)
        let requests = await harness.recordedRequests()
        XCTAssertEqual(requests, [.listCompetitions, .listCompetitions])
    }

    func testCompetitionHistoryRetriesOneTransientTransportFailure()
        async throws
    {
        let harness = CompetitionTransportHarness(stubs: [
            .failure(.network),
            .response(200, try jsonData([
                "competition_id": competitionID.uuidString.lowercased(),
                "after_server_seq": "0",
                "snapshot_server_seq": "0",
                "next_server_seq": "0",
                "has_more": false,
                "changes": [],
            ])),
        ])
        let cursor = try CompetitionSynchronizationCursor(
            competitionID: competitionID,
            lastSeenServerSequence: 0
        )

        let failure = await remoteFailure {
            let page = try await makeAPI(harness).fetchChanges(cursor, 200)
            XCTAssertEqual(page.nextServerSequence, 0)
        }

        XCTAssertNil(failure)
        let requests = await harness.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first, requests.last)
        try assertRPC(
            requests[0],
            name: "fetch_competition_changes",
            body: [
                "competition_id": competitionID.uuidString.lowercased(),
                "after_server_seq": "0",
                "page_size": 200,
            ]
        )
    }

    func testBareScoreSubmissionFailsClosedWithoutTransport() async throws {
        let harness = CompetitionTransportHarness(stubs: [])

        let failure = await remoteFailure {
            _ = try await makeAPI(harness)
                .appendScoreRevision(fixtureScoreRequest())
        }

        XCTAssertEqual(failure, .appAttestUnavailable)
        let requestCount = await harness.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testInstallationRegistrationFallsBackToLegacyCallOnUnmigratedServer()
        async throws
    {
        let harness = CompetitionTransportHarness(stubs: [
            .response(404, try jsonData([
                "code": "PGRST202", "message": "redacted",
            ])),
            .response(200, try jsonData([
                "installation_id": installationID.uuidString.lowercased(),
                "environment": "sandbox",
                "state": "active",
            ])),
        ])
        let request = try CompetitionInstallationRequest(
            installationID: installationID,
            apnsToken: String(repeating: "a1", count: 32),
            environment: .sandbox
        )

        let installation = try await makeAPI(harness)
            .registerInstallation(request)

        XCTAssertEqual(installation.state, .active)
        let requests = await harness.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        let legacyBody: [String: Any] = [
            "installation_id": installationID.uuidString.lowercased(),
            "apns_token": String(repeating: "a1", count: 32),
            "environment": "sandbox",
        ]
        var currentBody = legacyBody
        currentBody["supports_challenges"] = true
        try assertRPC(
            requests[0],
            name: "register_current_device_installation",
            body: currentBody
        )
        try assertRPC(
            requests[1],
            name: "register_current_device_installation",
            body: legacyBody
        )
    }

    func testChallengeRetriesInstallationRegistrationRace() async throws {
        let harness = CompetitionTransportHarness(stubs: [
            .response(
                404,
                try errorData(code: "installation_unavailable")
            ),
        ])
        let request = try CompetitionAppAttestChallengeRequest(
            installationID: installationID,
            payloadSHA256: digest("c"),
            keyID: appAttestKeyID
        )

        let failure = await remoteFailure {
            _ = try await makeAPI(harness).issueAppAttestChallenge(request)
        }

        XCTAssertEqual(failure, .retryableTransport)
        let requestCount = await harness.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testAppAttestSubmissionErrorsKeepStableIntegritySemantics()
        async throws
    {
        let cases: [(Int, String, CompetitionRemoteFailure)] = [
            (401, "app_attest_proof_rejected", .appAttestRejected),
            (409, "app_attest_context_unavailable", .appAttestContextUnavailable),
            (409, "app_attest_grant_unavailable", .appAttestContextUnavailable),
            (409, "app_attest_proof_conflict", .appAttestProofConflict),
            (404, "installation_unavailable", .notFound),
        ]
        for (status, code, expected) in cases {
            let harness = CompetitionTransportHarness(stubs: [
                .response(status, try errorData(code: code)),
            ])
            let failure = await remoteFailure {
                _ = try await makeAPI(harness).submitAttestedScoreRevision(
                    fixtureAttestedScoreRequest()
                )
            }
            XCTAssertEqual(failure, expected, "Unexpected mapping for \(code)")
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

    func testOwnClaimMapsToForbidden() async throws {
        let token = Data(repeating: 0x42, count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let request = try CompetitionInviteClaimRequest(token: token)
        for code in ["self_claim_forbidden", "cannot_claim_own_invite"] {
            let harness = CompetitionTransportHarness(stubs: [
                .response(403, try errorData(code: code)),
            ])
            let failure = await remoteFailure {
                _ = try await makeAPI(harness).claimInvite(request)
            }
            XCTAssertEqual(failure, .forbidden)
            let requestCount = await harness.requestCount()
            XCTAssertEqual(requestCount, 1)
        }
    }

    func testListedCancelledMatchDecodesWithoutASchedule() async throws {
        // What the server stores after Cancel Match: no start day or deadline.
        var cancelled = descriptorObject()
        cancelled["lifecycle"] = "cancelled"
        cancelled["time_zone_identifier"] = "America/Los_Angeles"
        cancelled["participants"] = [
            [
                "profile_id": profileID.uuidString.lowercased(),
                "role": "creator",
                "state": "accepted",
                "profile": profileObject(name: "Beta Alice"),
            ],
            [
                "profile_id": "12000000-0000-4000-8000-0000000000b9",
                "role": "invitee",
                "state": "accepted",
                "profile": ["id": "12000000-0000-4000-8000-0000000000b9", "display_name": "Maya"],
            ],
        ]
        let harness = CompetitionTransportHarness(stubs: [.response(200, try jsonData([cancelled]))])
        let listed = try await makeAPI(harness).listCompetitions()
        XCTAssertEqual(listed.map(\.lifecycle), [.cancelled])

        // A schedule left on a cancelled row would fail the whole listing.
        var stale = cancelled
        stale["start_day"] = "2026-11-02"
        stale["best_available_deadline"] = "2026-11-10T08:00:00+00:00"
        let staleHarness = CompetitionTransportHarness(stubs: [.response(200, try jsonData([stale]))])
        let failure = await remoteFailure { _ = try await makeAPI(staleHarness).listCompetitions() }
        XCTAssertEqual(failure, .serverContractMismatch)
    }

    func testListChallengesDecodesIncomingAndClosedWithPostgresTimestamps() async throws {
        let sender = "12000000-0000-4000-8000-0000000000a1"
        let other = "12000000-0000-4000-8000-0000000000a2"
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData([
                "incoming": [[
                    "competition_id": "13000000-0000-4000-8000-000000000001",
                    "sender": ["id": sender, "display_name": "Naren"],
                    "time_zone_identifier": "America/Los_Angeles",
                    "created_at": "2026-11-01T21:14:00.123456+00:00",
                    "expires_at": "2026-11-02T21:14:00.123456+00:00",
                ]],
                "closed": [[
                    "competition_id": "13000000-0000-4000-8000-000000000002",
                    "kind": "cancelled",
                    "other": ["id": other, "display_name": "Former competitor"],
                    "closed_at": "2026-11-01T20:00:00+00:00",
                ]],
            ])),
        ])
        let list = try await makeAPI(harness).listChallenges()
        let requests = await harness.recordedRequests()
        try assertRPC(requests[0], name: "list_challenges", body: [:])
        XCTAssertEqual(list.incoming.count, 1)
        XCTAssertEqual(list.incoming[0].sender.displayName, "Naren")
        XCTAssertEqual(
            list.incoming[0].expiresAt.timeIntervalSince(list.incoming[0].createdAt),
            86_400,
            accuracy: 0.001
        )
        XCTAssertEqual(list.closed, [CompetitionChallengeList.Closed(
            competitionID: UUID(uuidString: "13000000-0000-4000-8000-000000000002")!,
            kind: .cancelled,
            other: AuthenticatedProfile(id: UUID(uuidString: other)!, displayName: "Former competitor"),
            closedAt: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T20:00:00Z"))
        )])
    }

    func testListChallengesSkipsBadRowsAndKeepsZWJNames() async throws {
        func incoming(_ id: String, name: String, timeZone: String = "UTC") -> [String: Any] {
            [
                "competition_id": id,
                "sender": ["id": "12000000-0000-4000-8000-0000000000a1", "display_name": name],
                "time_zone_identifier": timeZone,
                "created_at": "2026-11-01T21:14:00+00:00",
                "expires_at": "2026-11-02T21:14:00+00:00",
            ]
        }
        // A family emoji joined with U+200D, which the server accepts.
        let family = "Sam \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        var extra = incoming("13000000-0000-4000-8000-000000000002", name: "Extra")
        extra["score"] = 1
        let body: [String: Any] = [
            "incoming": [
                incoming("13000000-0000-4000-8000-000000000001", name: family),
                extra,
                incoming("13000000-0000-4000-8000-000000000003", name: "Former competitor"),
                incoming("13000000-0000-4000-8000-000000000004", name: "Bell\u{7}"),
                incoming("13000000-0000-4000-8000-000000000005", name: "Zone", timeZone: "Mars/Olympus"),
                incoming("13000000-0000-4000-8000-000000000006", name: "Naren"),
            ],
            "closed": [
                ["competition_id": "13000000-0000-4000-8000-000000000007", "kind": "conceded",
                 "other": ["id": "12000000-0000-4000-8000-0000000000a2", "display_name": "Maya"],
                 "closed_at": "2026-11-01T20:00:00+00:00"],
            ],
        ]
        let harness = CompetitionTransportHarness(stubs: [.response(200, try jsonData(body))])
        let list = try await makeAPI(harness).listChallenges()
        XCTAssertEqual(list.incoming.map(\.sender.displayName), [family, "Naren"])
        XCTAssertEqual(list.closed, [])

        // The list's own shape still has to be exact.
        let malformed = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(["incoming": [], "closed": [], "history": []])),
        ])
        let failure = await remoteFailure { _ = try await makeAPI(malformed).listChallenges() }
        XCTAssertEqual(failure, .serverContractMismatch)
    }

    func testPreviewInviteUsesFunctionAndMapsErrors() async throws {
        let token = Data(repeating: 0x42, count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let request = try CompetitionInviteClaimRequest(token: token)
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData([
                "competitionId": "13000000-0000-4000-8000-000000000001",
                "state": "pending",
                "sender": ["id": "12000000-0000-4000-8000-0000000000a1", "displayName": "Naren"],
                "timeZoneIdentifier": "America/Los_Angeles",
                "expiresAt": "2026-11-02T21:14:00.5+00:00",
            ])),
        ])
        let preview = try await makeAPI(harness).previewInvite(request)
        XCTAssertEqual(preview.sender.displayName, "Naren")
        XCTAssertEqual(preview.state, .pending)
        let requests = await harness.recordedRequests()
        try assertFunction(requests[0], name: "preview-competition-invite", body: ["token": token])

        for (status, code, expected) in [
            (409, "self_claim_forbidden", CompetitionRemoteFailure.forbidden),
            (409, "active_match_exists", .activeMatchExists),
            (404, "invite_unavailable", .inviteUnavailable),
        ] {
            let failing = CompetitionTransportHarness(stubs: [.response(status, try errorData(code: code))])
            let failure = await remoteFailure { _ = try await makeAPI(failing).previewInvite(request) }
            XCTAssertEqual(failure, expected)
        }
    }

    func testAcceptDeclineCancelSendCompetitionIDAndValidateEcho() async throws {
        let id = UUID(uuidString: "13000000-0000-4000-8000-000000000009")!
        let echo = try jsonData(["competition_id": id.uuidString.lowercased()])
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, echo), .response(200, echo), .response(200, echo),
            .response(200, try jsonData(["competition_id": "13000000-0000-4000-8000-000000000008"])),
        ])
        let api = makeAPI(harness)
        try await api.acceptChallenge(id)
        try await api.declineChallenge(id)
        try await api.cancelCompetition(id)
        let failure = await remoteFailure { try await api.cancelCompetition(id) }
        XCTAssertEqual(failure, .serverContractMismatch)
        let requests = await harness.recordedRequests()
        let body = ["competition_id": id.uuidString.lowercased()]
        try assertRPC(requests[0], name: "accept_competition_challenge", body: body)
        try assertRPC(requests[1], name: "decline_competition_challenge", body: body)
        try assertRPC(requests[2], name: "cancel_competition", body: body)

        let refused = CompetitionTransportHarness(stubs: [
            .failure(.server(statusCode: 400, code: "P0001", message: "cancel_not_allowed")),
        ])
        let cancelFailure = await remoteFailure { try await makeAPI(refused).cancelCompetition(id) }
        XCTAssertEqual(cancelFailure, .forbidden)
    }

    func testChallengeLinkCodeAndResolve() async throws {
        let profile = "12000000-0000-4000-8000-0000000000a3"
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(["code": "Xb3kP9qL2mN8vR4tY6wZ1a"])),
            .response(200, try jsonData(["display_name": "Maya"])),
            // A link never hands out an account id; the old shape is refused.
            .response(200, try jsonData(["id": profile, "display_name": "Maya"])),
            .failure(.server(statusCode: 400, code: "P0001", message: "own_challenge_link")),
            .response(200, try jsonData(["code": "short"])),
        ])
        let api = makeAPI(harness)
        let code = try await api.loadChallengeLinkCode()
        XCTAssertEqual(code.rawValue, "Xb3kP9qL2mN8vR4tY6wZ1a")
        let maya = try await api.resolveChallengeLink(code)
        XCTAssertEqual(maya, "Maya")
        let withID = await remoteFailure { _ = try await api.resolveChallengeLink(code) }
        XCTAssertEqual(withID, .serverContractMismatch)
        let own = await remoteFailure { _ = try await api.resolveChallengeLink(code) }
        XCTAssertEqual(own, .ownChallengeLink)
        let malformed = await remoteFailure { _ = try await api.loadChallengeLinkCode() }
        XCTAssertEqual(malformed, .serverContractMismatch)
        let requests = await harness.recordedRequests()
        try assertRPC(requests[0], name: "get_my_challenge_link", body: [:])
        try assertRPC(requests[1], name: "resolve_challenge_link", body: ["code": "Xb3kP9qL2mN8vR4tY6wZ1a"])
    }

    func testCreateFromChallengeLinkSendsTheCodeNotAnID() async throws {
        let code = try XCTUnwrap(CompetitionChallengeLinkCode(rawValue: "Xb3kP9qL2mN8vR4tY6wZ1a"))
        let request = try CompetitionInviteCreationRequest(
            recipient: .challengeLink(code),
            timeZoneIdentifier: "UTC",
            rematchParentID: nil,
            idempotencyKey: UUID(uuidString: "84000000-0000-4000-8000-000000000001")!
        )
        let harness = CompetitionTransportHarness(stubs: [
            .response(201, try jsonData([
                "competitionId": competitionID.uuidString.lowercased(),
                "token": String(repeating: "A", count: 43),
            ])),
            .response(404, try errorData(code: "recipient_unavailable")),
        ])
        let api = makeAPI(harness)
        _ = try await api.createInvite(request)
        let reset = await remoteFailure { _ = try await api.createInvite(request) }
        XCTAssertEqual(reset, .recipientUnavailable)
        let requests = await harness.recordedRequests()
        try assertFunction(requests[0], name: "create-competition-invite", body: [
            "challengeLinkCode": "Xb3kP9qL2mN8vR4tY6wZ1a",
            "timeZoneIdentifier": "UTC",
            "rematchParentId": NSNull(),
            "idempotencyKey": "84000000-0000-4000-8000-000000000001",
        ])
        // A rematch is never by link.
        XCTAssertThrowsError(try CompetitionInviteCreationRequest(
            recipient: .challengeLink(code),
            timeZoneIdentifier: "UTC",
            rematchParentID: competitionID,
            idempotencyKey: UUID(uuidString: "84000000-0000-4000-8000-000000000002")!
        ))
        // A stored request decodes back to the same link recipient.
        let decoded = try JSONDecoder().decode(
            CompetitionInviteCreationRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
    }

    func testResetChallengeLinkCode() async throws {
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(["code": "Qm7tR2vX9pL4kN8wB3cY6z"])),
            .response(200, try jsonData(["code": "Qm7tR2vX9pL4kN8wB3cY6z", "extra": 1])),
            .failure(.server(statusCode: 401, code: "42501", message: "active_profile_required")),
        ])
        let api = makeAPI(harness)
        let code = try await api.resetChallengeLinkCode()
        XCTAssertEqual(code.rawValue, "Qm7tR2vX9pL4kN8wB3cY6z")
        let extraKey = await remoteFailure { _ = try await api.resetChallengeLinkCode() }
        XCTAssertEqual(extraKey, .serverContractMismatch)
        let signedOut = await remoteFailure { _ = try await api.resetChallengeLinkCode() }
        XCTAssertEqual(signedOut, .unauthenticated)
        let requests = await harness.recordedRequests()
        try assertRPC(requests[0], name: "reset_my_challenge_link", body: [:])
    }

    func testNudgeSendsCompetitionIDAndDecodesNudgedAt() async throws {
        let id = UUID(uuidString: "84000000-0000-4000-8000-0000000000b1")!
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(["nudged_at": "2026-11-09T16:12:00.123456+00:00"])),
            .response(200, try jsonData(["nudged_at": "2026-11-09T16:12:00.123456+00:00", "extra": 1])),
            .failure(.server(statusCode: 400, code: "P0001", message: "nudge_not_allowed")),
            .failure(.server(statusCode: 400, code: "P0002", message: "competition_not_found")),
        ])
        let api = makeAPI(harness)
        let nudgedAt = try await api.nudgeCompetitionParticipant(id)
        XCTAssertEqual(nudgedAt.timeIntervalSince1970, 1_794_240_720.123456, accuracy: 0.001)
        let extraKey = await remoteFailure { _ = try await api.nudgeCompetitionParticipant(id) }
        XCTAssertEqual(extraKey, .serverContractMismatch)
        let refused = await remoteFailure { _ = try await api.nudgeCompetitionParticipant(id) }
        XCTAssertEqual(refused, .forbidden)
        let notFound = await remoteFailure { _ = try await api.nudgeCompetitionParticipant(id) }
        XCTAssertEqual(notFound, .notFound)
        let requests = await harness.recordedRequests()
        try assertRPC(
            requests[0],
            name: "nudge_competition_participant",
            body: ["competition_id": id.uuidString.lowercased()]
        )
    }

    func testCreateClassifiesIncomingAndActiveConflicts() async throws {
        let request = try CompetitionInviteCreationRequest(
            recipientProfileID: UUID(uuidString: "12000000-0000-4000-8000-0000000000a4")!,
            timeZoneIdentifier: "UTC",
            rematchParentID: nil,
            idempotencyKey: UUID(uuidString: "84000000-0000-4000-8000-000000000001")!
        )
        for (code, expected) in [
            ("active_match_exists", CompetitionRemoteFailure.activeMatchExists),
            ("incoming_challenge_exists", .incomingChallengeExists),
            ("pending_invitation_exists", .pendingInvitationExists),
        ] {
            let harness = CompetitionTransportHarness(stubs: [.response(409, try errorData(code: code))])
            let failure = await remoteFailure { _ = try await makeAPI(harness).createInvite(request) }
            XCTAssertEqual(failure, expected)
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

    func testCancelledDiscoveryDoesNotRetryALateTransportFailure() async {
        await assertCancelledHeldDiscovery(.failure(.network))
    }

    func testCancelledDiscoveryDoesNotPublishALateSuccessfulResponse() async {
        await assertCancelledHeldDiscovery(.response(200, Data("[]".utf8)))
    }

    private func assertCancelledHeldDiscovery(_ result: CompetitionTransportStub) async {
        let entered = expectation(description: "discovery transport entered")
        let transport = HeldDiscoveryTransport(entered: entered, result: result)
        let api = SupabaseCompetitionRemoteAPI.make(
            transport: CompetitionRemoteTransport { _ in try await transport.send() }
        )
        let operation = Task { () -> CompetitionRemoteFailure? in
            do {
                _ = try await api.listCompetitions()
                return nil
            } catch let failure as CompetitionRemoteFailure {
                return failure
            } catch {
                XCTFail("Unexpected error type: \(type(of: error))")
                return nil
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        operation.cancel()
        await transport.release()
        let failure = await operation.value
        XCTAssertEqual(failure, .cancelled)
        let count = await transport.count
        XCTAssertEqual(count, 1)
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

    private func fixtureAttestedScoreRequest() throws
        -> CompetitionAttestedScoreRevisionRequest
    {
        try CompetitionAttestedScoreRevisionRequest(
            score: fixtureScoreRequest(),
            appAttest: CompetitionAppAttestProof(
                challengeID: appAttestChallengeID,
                installationID: installationID,
                keyID: appAttestKeyID,
                proofKind: .attestation,
                object: Data("attestation-object".utf8)
            )
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
    private var appAttestChallengeID: UUID {
        UUID(uuidString: "86000000-0000-4000-8000-000000000001")!
    }
    private var appAttestKeyID: String {
        Data(repeating: 0x41, count: 32).base64EncodedString()
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

private actor HeldDiscoveryTransport {
    let entered: XCTestExpectation
    let result: CompetitionTransportStub
    var count = 0
    var continuation: CheckedContinuation<Void, Never>?

    init(entered: XCTestExpectation, result: CompetitionTransportStub) {
        self.entered = entered
        self.result = result
    }

    func send() async throws -> CompetitionRemoteTransportResponse {
        count += 1
        if count == 1 {
            await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
        }
        switch result {
        case let .failure(error): throw error
        case let .response(status, data):
            return CompetitionRemoteTransportResponse(statusCode: status, data: data)
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
