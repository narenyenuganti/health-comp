import Foundation
import XCTest
@testable import HealthComp

final class SupabaseCompetitionRemoteAPITests: XCTestCase {
    func testCompetitionPresenceUsesOnlySuccessfulExactIDRows() async throws {
        for (rows, expected) in [
            ([[String: String]](), false),
            ([["id": competitionID.uuidString.lowercased()]], true),
        ] {
            let harness = CompetitionTransportHarness(stubs: [.response(200, try jsonData(rows))])
            let exists = try await makeAPI(harness).competitionExists(competitionID)
            XCTAssertEqual(exists, expected)
            let requests = await harness.recordedRequests()
            XCTAssertEqual(requests, [.competitionPresence(competitionID)])
        }
    }

    func testCompetitionPresenceRejectsErrorsAndMalformedRowsInsteadOfReportingAbsence() async throws {
        for body: Any in [
            NSNull(), ["id": competitionID.uuidString.lowercased()],
            [["id": profileID.uuidString.lowercased()]], [["id": NSNull()]],
            [["id": competitionID.uuidString.lowercased(), "extra": "unexpected"]],
            [["id": competitionID.uuidString.lowercased()], ["id": competitionID.uuidString.lowercased()]],
        ] {
            let data = body is NSNull ? Data("null".utf8) : try jsonData(body)
            let harness = CompetitionTransportHarness(stubs: [.response(200, data)])
            let failure = await remoteFailure { _ = try await makeAPI(harness).competitionExists(competitionID) }
            XCTAssertEqual(failure, .serverContractMismatch)
        }
        for status in [204, 206, 401, 403, 404, 406] {
            let harness = CompetitionTransportHarness(stubs: [.response(status, Data())])
            let failure = await remoteFailure { _ = try await makeAPI(harness).competitionExists(competitionID) }
            XCTAssertNotNil(failure)
        }
    }

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
        let notFound = try jsonData(["code": "PGRST202", "message": "redacted"])
        let harness = CompetitionTransportHarness(stubs: [
            .response(404, notFound),
            .response(404, notFound),
            .response(404, notFound),
            .response(404, notFound),
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
        XCTAssertEqual(requests.count, 5)
        let legacyBody: [String: Any] = [
            "installation_id": installationID.uuidString.lowercased(),
            "apns_token": String(repeating: "a1", count: 32),
            "environment": "sandbox",
        ]
        var challengeBody = legacyBody
        challengeBody["supports_challenges"] = true
        var reactionBody = challengeBody
        reactionBody["supports_reactions"] = true
        var mutedBody = reactionBody
        mutedBody["muted_push_kinds"] = [String]()
        var currentBody = mutedBody
        currentBody["supports_friends"] = true
        for (request, body) in zip(requests, [currentBody, mutedBody, reactionBody, challengeBody, legacyBody]) {
            try assertRPC(request, name: "register_current_device_installation", body: body)
        }
    }

    func testInstallationRegistrationFallsBackThroughOlderCalls() async throws {
        let notFound = try jsonData(["code": "PGRST202", "message": "redacted"])
        let active = try jsonData([
            "installation_id": installationID.uuidString.lowercased(),
            "environment": "sandbox",
            "state": "active",
        ])
        // A server with the five-argument call answers the second fallback,
        // one with the four-argument call the third; five 404s in a row
        // surface as notFound.
        let harness = CompetitionTransportHarness(stubs: [
            .response(404, notFound),
            .response(404, notFound),
            .response(200, active),
            .response(404, notFound),
            .response(404, notFound),
            .response(404, notFound),
            .response(200, active),
            .response(404, notFound),
            .response(404, notFound),
            .response(404, notFound),
            .response(404, notFound),
            .response(404, notFound),
        ])
        let request = try CompetitionInstallationRequest(
            installationID: installationID,
            apnsToken: String(repeating: "a1", count: 32),
            environment: .sandbox
        )
        let api = makeAPI(harness)

        let installation = try await api.registerInstallation(request)
        XCTAssertEqual(installation.state, .active)
        let fourArgument = try await api.registerInstallation(request)
        XCTAssertEqual(fourArgument.state, .active)
        let exhausted = await remoteFailure { _ = try await api.registerInstallation(request) }
        XCTAssertEqual(exhausted, .notFound)

        let requests = await harness.recordedRequests()
        XCTAssertEqual(requests.count, 12)
        let challengeBody: [String: Any] = [
            "installation_id": installationID.uuidString.lowercased(),
            "apns_token": String(repeating: "a1", count: 32),
            "environment": "sandbox",
            "supports_challenges": true,
        ]
        var reactionBody = challengeBody
        reactionBody["supports_reactions"] = true
        try assertRPC(requests[2], name: "register_current_device_installation", body: reactionBody)
        try assertRPC(requests[5], name: "register_current_device_installation", body: reactionBody)
        try assertRPC(requests[6], name: "register_current_device_installation", body: challengeBody)
    }

    func testRegisterInstallationFallsBackWithoutMutedPushKinds() async throws {
        let notFound = try jsonData(["code": "PGRST202", "message": "redacted"])
        let harness = CompetitionTransportHarness(stubs: [
            .response(404, notFound),
            .response(404, notFound),
            .response(200, try jsonData([
                "installation_id": installationID.uuidString.lowercased(),
                "environment": "sandbox",
                "state": "active",
            ])),
        ])
        let request = try CompetitionInstallationRequest(
            installationID: installationID,
            apnsToken: String(repeating: "a1", count: 32),
            environment: .sandbox,
            mutedPushKinds: ["nudge"]
        )

        _ = try await makeAPI(harness).registerInstallation(request)

        let requests = await harness.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        let reactionBody: [String: Any] = [
            "installation_id": installationID.uuidString.lowercased(),
            "apns_token": String(repeating: "a1", count: 32),
            "environment": "sandbox",
            "supports_challenges": true,
            "supports_reactions": true,
        ]
        var mutedBody = reactionBody
        mutedBody["muted_push_kinds"] = ["nudge"]
        var currentBody = mutedBody
        currentBody["supports_friends"] = true
        try assertRPC(requests[0], name: "register_current_device_installation", body: currentBody)
        try assertRPC(requests[1], name: "register_current_device_installation", body: mutedBody)
        try assertRPC(requests[2], name: "register_current_device_installation", body: reactionBody)
    }

    /// Before 20261109003100 the six-argument call rejects Friends mutes, so
    /// the fallback drops them and keeps the rest; once the server has the
    /// seven-argument call, the next registration sends every mute again.
    func testRegisterInstallationFallbackDropsFriendMutesThenSendsThemOnceMigrated() async throws {
        let notFound = try jsonData(["code": "PGRST202", "message": "redacted"])
        let active = try jsonData([
            "installation_id": installationID.uuidString.lowercased(),
            "environment": "sandbox",
            "state": "active",
        ])
        let harness = CompetitionTransportHarness(stubs: [
            .response(404, notFound),
            .response(200, active),
            .response(200, active),
        ])
        let request = try CompetitionInstallationRequest(
            installationID: installationID,
            apnsToken: String(repeating: "a1", count: 32),
            environment: .sandbox,
            mutedPushKinds: ["friend_accepted", "friend_request", "nudge", "reaction"]
        )
        let api = makeAPI(harness)

        let beforeMigration = try await api.registerInstallation(request)
        XCTAssertEqual(beforeMigration.state, .active)
        let afterMigration = try await api.registerInstallation(request)
        XCTAssertEqual(afterMigration.state, .active)

        let requests = await harness.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        let mutedBody: [String: Any] = [
            "installation_id": installationID.uuidString.lowercased(),
            "apns_token": String(repeating: "a1", count: 32),
            "environment": "sandbox",
            "supports_challenges": true,
            "supports_reactions": true,
            "muted_push_kinds": ["nudge", "reaction"],
        ]
        var currentBody = mutedBody
        currentBody["supports_friends"] = true
        currentBody["muted_push_kinds"] = ["friend_accepted", "friend_request", "nudge", "reaction"]
        try assertRPC(requests[0], name: "register_current_device_installation", body: currentBody)
        try assertRPC(requests[1], name: "register_current_device_installation", body: mutedBody)
        try assertRPC(requests[2], name: "register_current_device_installation", body: currentBody)
    }

    /// The live Supabase SDK reports a missing function as a PostgrestError,
    /// which arrives with code PGRST202 and no HTTP status.
    func testRegisterInstallationFallsBackOnPGRST202WithoutStatus() async throws {
        let harness = CompetitionTransportHarness(stubs: [
            .failure(.server(statusCode: nil, code: "PGRST202", message: "redacted")),
            .response(200, try jsonData([
                "installation_id": installationID.uuidString.lowercased(),
                "environment": "sandbox",
                "state": "active",
            ])),
        ])
        let request = try CompetitionInstallationRequest(
            installationID: installationID,
            apnsToken: String(repeating: "a1", count: 32),
            environment: .sandbox,
            mutedPushKinds: ["friend_accepted", "friend_request", "nudge", "reaction"]
        )

        let installation = try await makeAPI(harness).registerInstallation(request)

        XCTAssertEqual(installation.state, .active)
        let requests = await harness.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        let mutedBody: [String: Any] = [
            "installation_id": installationID.uuidString.lowercased(),
            "apns_token": String(repeating: "a1", count: 32),
            "environment": "sandbox",
            "supports_challenges": true,
            "supports_reactions": true,
            "muted_push_kinds": ["nudge", "reaction"],
        ]
        try assertRPC(requests[1], name: "register_current_device_installation", body: mutedBody)
    }

    /// Only PGRST202 means "this overload doesn't exist"; every other
    /// failure, including a 404 with another code, is thrown after one call.
    func testRegisterInstallationDoesNotFallBackOnOtherFailures() async throws {
        let cases: [(CompetitionTransportStub, CompetitionRemoteFailure)] = [
            (.response(404, try jsonData(["code": "not_found", "message": "redacted"])), .notFound),
            (.response(404, Data()), .notFound),
            (.response(406, try jsonData(["code": "PGRST116", "message": "redacted"])), .notFound),
            (.failure(.server(statusCode: nil, code: "PGRST116", message: "redacted")), .notFound),
            (.failure(.server(statusCode: nil, code: "42501", message: "redacted")), .operationFailed),
            (.response(403, try jsonData(["code": "forbidden", "message": "redacted"])), .forbidden),
            (.response(400, try jsonData(["code": "invalid_installation_request", "message": "redacted"])), .serverContractMismatch),
        ]
        let request = try CompetitionInstallationRequest(
            installationID: installationID,
            apnsToken: String(repeating: "a1", count: 32),
            environment: .sandbox
        )
        for (index, (stub, expected)) in cases.enumerated() {
            let harness = CompetitionTransportHarness(stubs: [stub])
            let failure: CompetitionRemoteFailure? = await remoteFailure {
                _ = try await makeAPI(harness).registerInstallation(request)
            }
            XCTAssertEqual(failure, expected, "case \(index)")
            let requestCount: Int = await harness.requestCount()
            XCTAssertEqual(requestCount, 1, "case \(index)")
        }
    }

    func testReactionsRouteThroughExactRPCs() async throws {
        let match = "85000000-0000-4000-8000-0000000000c1"
        let author = "85000000-0000-4000-8000-0000000000c2"
        let rows: [[String: Any]] = [
            [
                "competition_id": match, "day_ordinal": 2, "author_profile_id": author,
                "reaction": "huffing", "updated_at": "2026-11-09T16:12:00.123456+00:00",
            ],
            [
                "competition_id": match, "day_ordinal": NSNull(), "author_profile_id": author,
                "reaction": "clap", "updated_at": "2026-11-09T16:00:00+00:00",
            ],
            // Skipped: an unknown reaction, an uppercase id, a day out of range.
            [
                "competition_id": match, "day_ordinal": 1, "author_profile_id": author,
                "reaction": "heart", "updated_at": "2026-11-09T16:00:00+00:00",
            ],
            [
                "competition_id": match.uppercased(), "day_ordinal": 1,
                "author_profile_id": author, "reaction": "fire",
                "updated_at": "2026-11-09T16:00:00+00:00",
            ],
            [
                "competition_id": match, "day_ordinal": 8, "author_profile_id": author,
                "reaction": "fire", "updated_at": "2026-11-09T16:00:00+00:00",
            ],
        ]
        let row = rows[0]
        let echoDay: [String: Any] = ["competition_id": match, "day_ordinal": 2, "reaction": "fire"]
        let echoRemoval: [String: Any] = [
            "competition_id": match, "day_ordinal": NSNull(), "reaction": NSNull(),
        ]
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(["reactions": rows])),
            .response(200, try jsonData(["reactions": [], "extra": 1])),
            .response(200, try jsonData(["reactions": Array(repeating: row, count: 2_001)])),
            .response(200, try jsonData(echoDay)),
            .response(200, try jsonData(echoRemoval)),
            .response(200, try jsonData([
                "competition_id": match, "day_ordinal": 2, "reaction": "clap",
            ])),
            .response(200, try jsonData([
                "competition_id": match, "day_ordinal": NSNull(), "reaction": 5,
            ])),
            .failure(.server(statusCode: 400, code: "P0001", message: "reaction_not_allowed")),
        ])
        let api = makeAPI(harness)
        let matchID = UUID(uuidString: match)!
        let authorID = UUID(uuidString: author)!

        let reactions = try await api.listReactions()
        XCTAssertEqual(reactions, [
            CompetitionReactionRecord(
                competitionID: matchID, target: .day(2), authorProfileID: authorID,
                kind: .huffing, updatedAt: try CompetitionWireCodec.date("2026-11-09T16:12:00.123456+00:00")
            ),
            CompetitionReactionRecord(
                competitionID: matchID, target: .result, authorProfileID: authorID,
                kind: .clap, updatedAt: try CompetitionWireCodec.date("2026-11-09T16:00:00+00:00")
            ),
        ])
        let extraKey = await remoteFailure { _ = try await api.listReactions() }
        XCTAssertEqual(extraKey, .serverContractMismatch)
        let overCap = await remoteFailure { _ = try await api.listReactions() }
        XCTAssertEqual(overCap, .serverContractMismatch)

        try await api.setReaction(.init(competitionID: matchID, target: .day(2), kind: .fire))
        try await api.setReaction(.init(competitionID: matchID, target: .result, kind: nil))
        let divergent = await remoteFailure {
            try await api.setReaction(.init(competitionID: matchID, target: .day(2), kind: .fire))
        }
        XCTAssertEqual(divergent, .serverContractMismatch)
        let mistypedRemoval = await remoteFailure {
            try await api.setReaction(.init(competitionID: matchID, target: .result, kind: nil))
        }
        XCTAssertEqual(mistypedRemoval, .serverContractMismatch)
        let refused = await remoteFailure {
            try await api.setReaction(.init(competitionID: matchID, target: .day(2), kind: .fire))
        }
        XCTAssertEqual(refused, .forbidden)

        let requests = await harness.recordedRequests()
        try assertRPC(requests[0], name: "list_competition_reactions", body: [:])
        try assertRPC(requests[3], name: "set_competition_reaction", body: echoDay)
        try assertRPC(requests[4], name: "set_competition_reaction", body: echoRemoval)
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

    func testBlockChallengerSendsCompetitionIDAndValidatesEcho() async throws {
        let id = UUID(uuidString: "13000000-0000-4000-8000-00000000000b")!
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(["competition_id": id.uuidString.lowercased()])),
            .response(200, try jsonData(["competition_id": "13000000-0000-4000-8000-000000000008"])),
            .failure(.server(statusCode: 400, code: "P0001", message: "invite_unavailable")),
        ])
        let api = makeAPI(harness)
        try await api.blockChallenger(id)
        let mismatch = await remoteFailure { try await api.blockChallenger(id) }
        XCTAssertEqual(mismatch, .serverContractMismatch)
        let refused = await remoteFailure { try await api.blockChallenger(id) }
        XCTAssertEqual(refused, .inviteUnavailable)
        let requests = await harness.recordedRequests()
        try assertRPC(requests[0], name: "block_challenger", body: ["competition_id": id.uuidString.lowercased()])
    }

    func testListBlockedProfilesDecodesExactKeysAndSkipsUnreadableRows() async throws {
        let alex = "12000000-0000-4000-8000-0000000000b1"
        let rows: [[String: Any]] = [
            ["id": alex, "display_name": "Alex"],
            ["id": "NOT-A-UUID", "display_name": "Sam"],
            ["id": "12000000-0000-4000-8000-0000000000b2", "display_name": "Sam", "extra": 1],
        ]
        let tooMany = Array(repeating: ["id": alex, "display_name": "Alex"], count: 201)
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(["blocked": rows])),
            .response(200, try jsonData(["blocked": [], "extra": 1])),
            .response(200, try jsonData(["blocked": tooMany])),
        ])
        let api = makeAPI(harness)
        let people = try await api.listBlockedProfiles()
        XCTAssertEqual(people, [AuthenticatedProfile(id: UUID(uuidString: alex)!, displayName: "Alex")])
        let extraKey = await remoteFailure { _ = try await api.listBlockedProfiles() }
        XCTAssertEqual(extraKey, .serverContractMismatch)
        let overCap = await remoteFailure { _ = try await api.listBlockedProfiles() }
        XCTAssertEqual(overCap, .serverContractMismatch)
        let requests = await harness.recordedRequests()
        try assertRPC(requests[0], name: "list_blocked_profiles", body: [:])
    }

    func testUnblockProfileSendsIDAndValidatesEcho() async throws {
        let id = UUID(uuidString: "12000000-0000-4000-8000-0000000000b1")!
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(["profile_id": id.uuidString.lowercased()])),
            .response(200, try jsonData(["profile_id": "12000000-0000-4000-8000-0000000000b2"])),
            .response(200, try jsonData(["profile_id": id.uuidString.lowercased(), "extra": 1])),
        ])
        let api = makeAPI(harness)
        try await api.unblockProfile(id)
        let other = await remoteFailure { try await api.unblockProfile(id) }
        XCTAssertEqual(other, .serverContractMismatch)
        let extra = await remoteFailure { try await api.unblockProfile(id) }
        XCTAssertEqual(extra, .serverContractMismatch)
        let requests = await harness.recordedRequests()
        try assertRPC(requests[0], name: "unblock_profile", body: ["profile_id": id.uuidString.lowercased()])
    }

    private func friendSettingsBody(
        username: Any = NSNull(),
        show: Any = true,
        policy: Any = "friends_and_link"
    ) -> [String: Any] {
        ["username": username, "show_in_search": show, "challenge_policy": policy]
    }

    func testGetFriendSettingsDecodesExactKeys() async throws {
        var extra = friendSettingsBody()
        extra["extra"] = 1
        var missing = friendSettingsBody()
        missing.removeValue(forKey: "username")
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(friendSettingsBody())),
            .response(200, try jsonData(friendSettingsBody(username: "alice_1", show: false, policy: "friends_only"))),
            .response(200, try jsonData(extra)),
            .response(200, try jsonData(missing)),
            .response(200, try jsonData(friendSettingsBody(username: "Not Valid"))),
            .response(200, try jsonData(friendSettingsBody(show: 1))),
            .response(200, try jsonData(friendSettingsBody(policy: "everyone"))),
        ])
        let api = makeAPI(harness)
        let unset = try await api.getFriendSettings()
        XCTAssertEqual(unset, FriendSettings(username: nil, showInSearch: true, challengePolicy: .friendsAndLink))
        let set = try await api.getFriendSettings()
        XCTAssertEqual(set, FriendSettings(username: "alice_1", showInSearch: false, challengePolicy: .friendsOnly))
        for _ in 0..<5 {
            let failure = await remoteFailure { _ = try await api.getFriendSettings() }
            XCTAssertEqual(failure, .serverContractMismatch)
        }
        let requests = await harness.recordedRequests()
        try assertRPC(requests[0], name: "get_friend_settings", body: [:])
    }

    func testSetUsernameSendsTheNameAndValidatesEcho() async throws {
        var extra = friendSettingsBody(username: "alice")
        extra["extra"] = 1
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(friendSettingsBody(username: "alice"))),
            .response(200, try jsonData(friendSettingsBody(username: "someone_else"))),
            .response(200, try jsonData(extra)),
        ])
        let api = makeAPI(harness)
        let saved = try await api.setUsername("alice")
        XCTAssertEqual(saved.username, "alice")
        let other = await remoteFailure { _ = try await api.setUsername("alice") }
        XCTAssertEqual(other, .serverContractMismatch)
        let extraKey = await remoteFailure { _ = try await api.setUsername("alice") }
        XCTAssertEqual(extraKey, .serverContractMismatch)
        let requests = await harness.recordedRequests()
        try assertRPC(requests[0], name: "set_username", body: ["username": "alice"])
        // An invalid name never reaches the server.
        let invalid = await remoteFailure { _ = try await api.setUsername("Al") }
        XCTAssertEqual(invalid, .invalidUsername)
        let requestCount = await harness.requestCount()
        XCTAssertEqual(requestCount, 3)
    }

    func testUsernameAvailableDecodesExactlyAvailable() async throws {
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(["available": true])),
            .response(200, try jsonData(["available": false])),
            .response(200, try jsonData(["available": 1])),
            .response(200, try jsonData(["available": true, "extra": 1])),
        ])
        let api = makeAPI(harness)
        let yes = try await api.usernameAvailable("alice")
        XCTAssertTrue(yes)
        let no = try await api.usernameAvailable("alice")
        XCTAssertFalse(no)
        let wrongType = await remoteFailure { _ = try await api.usernameAvailable("alice") }
        XCTAssertEqual(wrongType, .serverContractMismatch)
        let extra = await remoteFailure { _ = try await api.usernameAvailable("alice") }
        XCTAssertEqual(extra, .serverContractMismatch)
        let requests = await harness.recordedRequests()
        try assertRPC(requests[0], name: "username_available", body: ["username": "alice"])
    }

    func testUpdateFriendSettingsSendsBothValuesAndValidatesEcho() async throws {
        var extra = friendSettingsBody(show: false, policy: "friends_only")
        extra["extra"] = 1
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(friendSettingsBody(username: "alice", show: false, policy: "friends_only"))),
            .response(200, try jsonData(friendSettingsBody(show: true, policy: "friends_only"))),
            .response(200, try jsonData(friendSettingsBody(show: false, policy: "friends_and_link"))),
            .response(200, try jsonData(extra)),
        ])
        let api = makeAPI(harness)
        let saved = try await api.updateFriendSettings(false, .friendsOnly)
        XCTAssertEqual(saved, FriendSettings(username: "alice", showInSearch: false, challengePolicy: .friendsOnly))
        for _ in 0..<3 {
            let failure = await remoteFailure { _ = try await api.updateFriendSettings(false, .friendsOnly) }
            XCTAssertEqual(failure, .serverContractMismatch)
        }
        let requests = await harness.recordedRequests()
        try assertRPC(
            requests[0],
            name: "update_friend_settings",
            body: ["show_in_search": false, "challenge_policy": "friends_only"]
        )
    }

    func testFriendSettingsErrorsMapToTypedFailures() async throws {
        let cases: [(String, CompetitionRemoteFailure)] = [
            ("invalid_username", .invalidUsername),
            ("username_unavailable", .usernameUnavailable),
            ("search_rate_limited", .searchRateLimited),
            ("invalid_friend_settings", .invalidFriendSettings),
        ]
        for (code, expected) in cases {
            let harness = CompetitionTransportHarness(stubs: [
                .response(400, try errorData(code: code)),
            ])
            let failure = await remoteFailure {
                _ = try await makeAPI(harness).setUsername("alice")
            }
            XCTAssertEqual(failure, expected, code)
        }
    }

    private let friendID = "12000000-0000-4000-8000-0000000000f1"

    private func personBody(
        id: Any? = nil,
        name: Any = "Jordan Lee",
        username: Any = "jordanlee",
        relationship: Any = "friend"
    ) -> [String: Any] {
        ["id": id ?? friendID, "display_name": name, "username": username, "relationship": relationship]
    }

    private func friendsListBody(
        friends: [Any] = [],
        incoming: [Any] = [],
        outgoing: [Any] = []
    ) -> [String: Any] {
        ["friends": friends, "incoming": incoming, "outgoing": outgoing]
    }

    func testListFriendsDecodesAllThreeListsAndCallsTheRPC() async throws {
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(friendsListBody(
                friends: [personBody(username: NSNull())],
                incoming: [personBody(relationship: "incoming")],
                outgoing: [personBody(relationship: "requested")]
            ))),
        ])
        let list = try await makeAPI(harness).listFriends()
        let id = UUID(uuidString: friendID)!
        XCTAssertEqual(list.friends, [FriendPerson(id: id, displayName: "Jordan Lee", username: nil, relationship: .friend)])
        XCTAssertEqual(list.incoming, [FriendPerson(id: id, displayName: "Jordan Lee", username: "jordanlee", relationship: .incoming)])
        XCTAssertEqual(list.outgoing.map(\.relationship), [.requested])
        let requests = await harness.recordedRequests()
        try assertRPC(requests[0], name: "list_friends", body: [:])
    }

    func testListFriendsRejectsTheWrongShape() async throws {
        var extraTop = friendsListBody()
        extraTop["extra"] = 1
        var missingList = friendsListBody()
        missingList.removeValue(forKey: "outgoing")
        var extraPerson = personBody()
        extraPerson["extra"] = 1
        var noUsername = personBody()
        noUsername.removeValue(forKey: "username")
        let bad: [[String: Any]] = [
            extraTop,
            missingList,
            ["friends": "x", "incoming": [], "outgoing": []],
            friendsListBody(friends: [extraPerson]),
            friendsListBody(friends: [noUsername]),
            friendsListBody(friends: [personBody(id: "not-a-uuid")]),
            friendsListBody(friends: [personBody(id: friendID.uppercased())]),
            friendsListBody(friends: [personBody(name: "")]),
            friendsListBody(friends: [personBody(name: 7)]),
            friendsListBody(friends: [personBody(username: "Not Valid")]),
            friendsListBody(friends: [personBody(relationship: "rival")]),
            friendsListBody(friends: [personBody(relationship: "incoming")]),
            friendsListBody(incoming: [personBody(relationship: "friend")]),
            friendsListBody(outgoing: [personBody(relationship: "none")]),
        ]
        for body in bad {
            let harness = CompetitionTransportHarness(stubs: [.response(200, try jsonData(body))])
            let failure = await remoteFailure { _ = try await makeAPI(harness).listFriends() }
            XCTAssertEqual(failure, .serverContractMismatch, "\(body)")
        }
    }

    func testSearchPeopleSendsTheQueryAndDecodesExactKeys() async throws {
        var extraPerson = personBody()
        extraPerson["extra"] = 1
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(["people": [personBody(relationship: "none"), personBody(relationship: "requested")]])),
            .response(200, try jsonData(["people": []])),
            .response(200, try jsonData(["people": [], "extra": 1])),
            .response(200, try jsonData(["results": []])),
            .response(200, try jsonData(["people": "x"])),
            .response(200, try jsonData(["people": [extraPerson]])),
        ])
        let api = makeAPI(harness)
        let found = try await api.searchPeople("@jor")
        XCTAssertEqual(found.map(\.relationship), [FriendRelationship.none, .requested])
        let none = try await api.searchPeople("nobody")
        XCTAssertEqual(none, [])
        for _ in 0..<4 {
            let failure = await remoteFailure { _ = try await api.searchPeople("abc") }
            XCTAssertEqual(failure, .serverContractMismatch)
        }
        let requests = await harness.recordedRequests()
        try assertRPC(requests[0], name: "search_people", body: ["query": "@jor"])
    }

    func testSendFriendRequestAcceptsOnlyItsOwnAnswers() async throws {
        let id = UUID(uuidString: friendID)!
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(["relationship": "requested"])),
            .response(200, try jsonData(["relationship": "friend"])),
            .response(200, try jsonData(["relationship": "none"])),
            .response(200, try jsonData(["relationship": "incoming"])),
            .response(200, try jsonData(["relationship": "requested", "extra": 1])),
            .response(200, try jsonData(["relationship": 1])),
        ])
        let api = makeAPI(harness)
        let requested = try await api.sendFriendRequest(id)
        XCTAssertEqual(requested, .requested)
        let friend = try await api.sendFriendRequest(id)
        XCTAssertEqual(friend, .friend)
        for _ in 0..<4 {
            let failure = await remoteFailure { _ = try await api.sendFriendRequest(id) }
            XCTAssertEqual(failure, .serverContractMismatch)
        }
        let requests = await harness.recordedRequests()
        try assertRPC(requests[0], name: "send_friend_request", body: ["profile_id": friendID])
    }

    func testRespondToFriendRequestSendsTheAnswerAndChecksTheEcho() async throws {
        let id = UUID(uuidString: friendID)!
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(["relationship": "friend"])),
            .response(200, try jsonData(["relationship": "none"])),
            .response(200, try jsonData(["relationship": "friend"])),
            .response(200, try jsonData(["relationship": "none"])),
            .response(200, try jsonData(["relationship": "requested"])),
            .response(200, try jsonData(["relationship": "none", "extra": 1])),
        ])
        let api = makeAPI(harness)
        let accepted = try await api.respondToFriendRequest(id, true)
        XCTAssertEqual(accepted, .friend)
        let declined = try await api.respondToFriendRequest(id, false)
        XCTAssertEqual(declined, FriendRelationship.none)
        // Declining someone who is already a friend changes nothing.
        let already = try await api.respondToFriendRequest(id, false)
        XCTAssertEqual(already, .friend)
        let acceptWithNone = await remoteFailure { _ = try await api.respondToFriendRequest(id, true) }
        XCTAssertEqual(acceptWithNone, .serverContractMismatch)
        let declineRequested = await remoteFailure { _ = try await api.respondToFriendRequest(id, false) }
        XCTAssertEqual(declineRequested, .serverContractMismatch)
        let extra = await remoteFailure { _ = try await api.respondToFriendRequest(id, false) }
        XCTAssertEqual(extra, .serverContractMismatch)
        let requests = await harness.recordedRequests()
        try assertRPC(requests[0], name: "respond_to_friend_request", body: ["profile_id": friendID, "accept": true])
        try assertRPC(requests[1], name: "respond_to_friend_request", body: ["profile_id": friendID, "accept": false])
    }

    func testRemoveFriendAnswersNone() async throws {
        let id = UUID(uuidString: friendID)!
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(["relationship": "none"])),
            .response(200, try jsonData(["relationship": "friend"])),
            .response(200, try jsonData(["relationship": "none", "extra": 1])),
            .response(200, try jsonData([:])),
        ])
        let api = makeAPI(harness)
        let removed = try await api.removeFriend(id)
        XCTAssertEqual(removed, FriendRelationship.none)
        for _ in 0..<3 {
            let failure = await remoteFailure { _ = try await api.removeFriend(id) }
            XCTAssertEqual(failure, .serverContractMismatch)
        }
        let requests = await harness.recordedRequests()
        try assertRPC(requests[0], name: "remove_friend", body: ["profile_id": friendID])
    }

    func testBlockProfileAnswersTheirBlockedListRow() async throws {
        let id = UUID(uuidString: friendID)!
        let other = "12000000-0000-4000-8000-0000000000ff"
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(["id": friendID, "display_name": "Dev Patel"])),
            // Someone else's row, extra keys, a missing name, the wrong shape.
            .response(200, try jsonData(["id": other, "display_name": "Dev Patel"])),
            .response(200, try jsonData(["id": friendID, "display_name": "Dev Patel", "username": "devp"])),
            .response(200, try jsonData(["id": friendID])),
            .response(200, try jsonData(["relationship": "none"])),
        ])
        let api = makeAPI(harness)
        let blocked = try await api.blockProfile(id)
        XCTAssertEqual(blocked, AuthenticatedProfile(id: id, displayName: "Dev Patel"))
        for _ in 0..<4 {
            let failure = await remoteFailure { _ = try await api.blockProfile(id) }
            XCTAssertEqual(failure, .serverContractMismatch)
        }
        let requests = await harness.recordedRequests()
        try assertRPC(requests[0], name: "block_profile", body: ["profile_id": friendID])
    }

    func testReportProfileAnswersReported() async throws {
        let id = UUID(uuidString: friendID)!
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(["reported": true])),
            .response(200, try jsonData(["reported": false])),
            // 1 is not JSON true.
            .response(200, try jsonData(["reported": 1])),
            .response(200, try jsonData(["reported": true, "extra": 1])),
            .response(200, try jsonData([:])),
        ])
        let api = makeAPI(harness)
        try await api.reportProfile(id)
        for _ in 0..<4 {
            let failure = await remoteFailure { try await api.reportProfile(id) }
            XCTAssertEqual(failure, .serverContractMismatch)
        }
        let requests = await harness.recordedRequests()
        try assertRPC(requests[0], name: "report_profile", body: ["profile_id": friendID])
    }

    func testFriendErrorsMapToTypedFailures() async throws {
        let id = UUID(uuidString: friendID)!
        typealias Call = @Sendable (CompetitionRemoteAPI) async throws -> Void
        let search: Call = { _ = try await $0.searchPeople("abc") }
        let add: Call = { _ = try await $0.sendFriendRequest(id) }
        let respond: Call = { _ = try await $0.respondToFriendRequest(id, true) }
        let remove: Call = { _ = try await $0.removeFriend(id) }
        let block: Call = { _ = try await $0.blockProfile(id) }
        let report: Call = { try await $0.reportProfile(id) }
        let cases: [(String, CompetitionRemoteFailure, Call)] = [
            ("invalid_query", .invalidQuery, search),
            ("search_rate_limited", .searchRateLimited, search),
            ("invalid_profile_id", .invalidProfileID, add),
            ("recipient_unavailable", .recipientUnavailable, add),
            ("friend_request_limit", .friendRequestLimit, add),
            ("invalid_profile_id", .invalidProfileID, respond),
            ("invalid_friend_request_response", .invalidFriendRequestResponse, respond),
            ("request_unavailable", .requestUnavailable, respond),
            ("invalid_profile_id", .invalidProfileID, remove),
            ("invalid_profile_id", .invalidProfileID, block),
            ("recipient_unavailable", .recipientUnavailable, block),
            ("invalid_profile_id", .invalidProfileID, report),
            ("recipient_unavailable", .recipientUnavailable, report),
        ]
        for (code, expected, call) in cases {
            let harness = CompetitionTransportHarness(stubs: [.response(400, try errorData(code: code))])
            let failure = await remoteFailure { try await call(makeAPI(harness)) }
            XCTAssertEqual(failure, expected, code)
        }
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

extension SupabaseCompetitionRemoteAPITests {
    private var photoOwner: UUID { UUID(uuidString: "12000000-0000-4000-8000-0000000000c1")! }
    private var photoVersion: UUID { UUID(uuidString: "13000000-0000-4000-8000-0000000000c1")! }

    func testListProfilePhotosAsksForIDsAndKeepsOnlyRequestedReadableRows() async throws {
        let stranger = "12000000-0000-4000-8000-0000000000c9"
        // The server returns at most one row per id asked for, so three ids
        // make room for the three rows below.
        let others = [
            UUID(uuidString: "12000000-0000-4000-8000-0000000000ca")!,
            UUID(uuidString: "12000000-0000-4000-8000-0000000000cb")!,
        ]
        let ownerRow = ["profile_id": photoOwner.uuidString.lowercased(), "photo_version": photoVersion.uuidString.lowercased()]
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(["photos": [
                ownerRow,
                ["profile_id": stranger, "photo_version": photoVersion.uuidString.lowercased()],
                ["profile_id": photoOwner.uuidString.lowercased(), "photo_version": "NOT-A-UUID"],
            ]])),
            .response(200, try jsonData(["photos": [ownerRow, ownerRow]])),
            .response(200, try jsonData(["photos": [], "extra": 1])),
        ])
        let api = makeAPI(harness)
        let references = try await api.listProfilePhotos([photoOwner] + others)
        XCTAssertEqual(references, [ProfilePhotoReference(ownerProfileID: photoOwner, version: photoVersion)])
        let moreRowsThanIDs = await remoteFailure { _ = try await api.listProfilePhotos([photoOwner]) }
        XCTAssertEqual(moreRowsThanIDs, .serverContractMismatch)
        let extra = await remoteFailure { _ = try await api.listProfilePhotos([photoOwner]) }
        XCTAssertEqual(extra, .serverContractMismatch)
        let tooMany = await remoteFailure { _ = try await api.listProfilePhotos((0..<201).map { _ in UUID() }) }
        XCTAssertEqual(tooMany, .serverContractMismatch)
        let none = try await api.listProfilePhotos([])
        XCTAssertEqual(none, [])
        let requests = await harness.recordedRequests()
        XCTAssertEqual(requests.count, 3, "no request for too many or no ids")
        try assertRPC(requests[0], name: "list_profile_photos", body: [
            "profile_ids": ([photoOwner] + others).map { $0.uuidString.lowercased() },
        ])
    }

    func testSetProfilePhotoUploadsThenSetsTheVersion() async throws {
        let jpeg = ProfilePhotoTestLabServer.fixtureJPEG(red: 0.8, green: 0.5, blue: 0.1)
        let reference = ProfilePhotoReference(ownerProfileID: photoOwner, version: photoVersion)
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, Data()),
            .response(200, try jsonData(["photo_version": photoVersion.uuidString.lowercased()])),
            .failure(.server(statusCode: 403, code: "403", message: "new row violates row-level security policy")),
        ])
        let api = makeAPI(harness)
        try await api.setProfilePhoto(reference, jpeg)
        let refused = await remoteFailure { try await api.setProfilePhoto(reference, jpeg) }
        XCTAssertEqual(refused, .forbidden)
        let notJPEG = await remoteFailure { try await api.setProfilePhoto(reference, Data("<html>".utf8)) }
        XCTAssertEqual(notJPEG, .serverContractMismatch)
        let requests = await harness.recordedRequests()
        XCTAssertEqual(requests.count, 3, "a non-JPEG is never sent")
        XCTAssertEqual(requests[0], .uploadProfilePhoto(path: reference.objectPath, data: jpeg))
        XCTAssertEqual(
            reference.objectPath,
            "12000000-0000-4000-8000-0000000000c1/13000000-0000-4000-8000-0000000000c1.jpg"
        )
        try assertRPC(requests[1], name: "set_profile_photo", body: ["photo_version": photoVersion.uuidString.lowercased()])
    }

    func testOwnProfilePhotoReadsVersionAndReviewNotice() async throws {
        let version = photoVersion.uuidString.lowercased()
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(["photo_version": version, "removed_by_review": false])),
            .response(200, try jsonData(["photo_version": NSNull(), "removed_by_review": true])),
            .response(200, try jsonData(["photo_version": NSNull(), "removed_by_review": 1])),
            .response(200, try jsonData(["photo_version": "NOT-A-UUID", "removed_by_review": false])),
            .response(200, try jsonData(["photo_version": NSNull()])),
        ])
        let api = makeAPI(harness)
        let current = try await api.ownProfilePhoto(photoOwner)
        XCTAssertEqual(current, OwnProfilePhoto(
            reference: ProfilePhotoReference(ownerProfileID: photoOwner, version: photoVersion),
            removedByReview: false
        ))
        let reviewed = try await api.ownProfilePhoto(photoOwner)
        XCTAssertEqual(reviewed, OwnProfilePhoto(reference: nil, removedByReview: true))
        for _ in 0..<3 {
            let failure = await remoteFailure { _ = try await api.ownProfilePhoto(photoOwner) }
            XCTAssertEqual(failure, .serverContractMismatch)
        }
        let requests = await harness.recordedRequests()
        try assertRPC(requests[0], name: "own_profile_photo", body: [:])
    }

    func testClearRemoveDownloadAndReportProfilePhoto() async throws {
        let jpeg = ProfilePhotoTestLabServer.fixtureJPEG(red: 0.1, green: 0.5, blue: 0.3)
        let reference = ProfilePhotoReference(ownerProfileID: photoOwner, version: photoVersion)
        let owner = photoOwner.uuidString.lowercased()
        let harness = CompetitionTransportHarness(stubs: [
            .response(200, try jsonData(["photo_version": NSNull()])),
            .response(200, try jsonData(["\(photoVersion.uuidString.lowercased()).jpg", "old.jpg", "nested/x.jpg"])),
            .response(200, Data()),
            .response(200, try jsonData([String]())),
            .response(200, jpeg),
            .response(200, Data("<html>".utf8)),
            .failure(.server(statusCode: 400, code: "not_found", message: "Object not found")),
            .response(200, try jsonData(["profile_id": owner])),
            .failure(.server(statusCode: 400, code: "P0001", message: "photo_unavailable")),
        ])
        let api = makeAPI(harness)
        try await api.clearProfilePhoto()
        try await api.removeProfilePhotoObjects(photoOwner, photoVersion)
        try await api.removeProfilePhotoObjects(photoOwner, nil)
        let downloaded = try await api.downloadProfilePhoto(reference)
        XCTAssertEqual(downloaded, jpeg)
        let notJPEG = await remoteFailure { _ = try await api.downloadProfilePhoto(reference) }
        XCTAssertEqual(notJPEG, .serverContractMismatch)
        let hidden = await remoteFailure { _ = try await api.downloadProfilePhoto(reference) }
        XCTAssertEqual(hidden, .notFound)
        try await api.reportProfilePhoto(photoOwner)
        let unavailable = await remoteFailure { try await api.reportProfilePhoto(photoOwner) }
        XCTAssertEqual(unavailable, .notFound)

        let requests = await harness.recordedRequests()
        try assertRPC(requests[0], name: "clear_profile_photo", body: [:])
        XCTAssertEqual(requests[1], .listProfilePhotoFolder(photoOwner))
        XCTAssertEqual(requests[2], .removeProfilePhotos(paths: ["\(owner)/old.jpg"]))
        XCTAssertEqual(requests[3], .listProfilePhotoFolder(photoOwner), "an empty folder removes nothing")
        XCTAssertEqual(requests[4], .downloadProfilePhoto(path: reference.objectPath))
        try assertRPC(requests[7], name: "report_profile_photo", body: ["profile_id": owner])
        XCTAssertEqual(requests.count, 9)
    }
}
