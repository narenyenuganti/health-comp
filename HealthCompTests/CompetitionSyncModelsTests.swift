import Foundation
import CompetitionCore
import XCTest
@testable import HealthComp

final class CompetitionSyncModelsTests: XCTestCase {
    func testProfileUsesTheExactSafeProjection() throws {
        let data = Data(
            #"{"id":"11111111-1111-4111-8111-111111111111","display_name":"Beta Alice"}"#.utf8
        )

        let profile = try CompetitionWireCodec.decode(
            AuthenticatedProfile.self,
            from: data,
            contract: .profile
        )

        XCTAssertEqual(
            profile,
            AuthenticatedProfile(
                id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                displayName: "Beta Alice"
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(
                jsonObject(
                    CompetitionWireCodec.encode(profile, contract: .profile)
                ) as? NSDictionary
            ),
            try XCTUnwrap(jsonObject(data) as? NSDictionary)
        )
    }

    func testProfileRejectsUnknownOrSensitiveIdentityFieldsBeforeDecode() {
        for json in [
            #"{"id":"11111111-1111-4111-8111-111111111111","display_name":"Beta Alice","auth_user_id":"22222222-2222-4222-8222-222222222222"}"#,
            #"{"id":"11111111-1111-4111-8111-111111111111","display_name":"Beta Alice","email":"alice@example.com"}"#,
        ] {
            XCTAssertThrowsError(
                try CompetitionWireCodec.decode(
                    AuthenticatedProfile.self,
                    from: Data(json.utf8),
                    contract: .profile
                )
            ) { error in
                XCTAssertEqual(
                    error as? CompetitionWireContractError,
                    .serverContractMismatch
                )
            }
        }
    }

    func testScoreSubmissionEncodesOnlyTheExactPrivacySafeContract() throws {
        let request = try CompetitionScoreRevisionRequest(
            competitionID: UUID(uuidString: "63000000-0000-4000-8000-000000000001")!,
            semanticEventID: UUID(uuidString: "64000000-0000-4000-8000-000000000001")!,
            dayOrdinal: 1,
            clientRevision: 9_007_199_254_740_993,
            evaluatedAt: Date(timeIntervalSince1970: 1_786_536_000),
            moveMode: "activeEnergyKilocalories",
            standMode: "standHours",
            moveBasisPoints: 10_000,
            exerciseBasisPoints: 5_000,
            standBasisPoints: 12_500,
            availabilityReason: "available",
            scoringPolicyIdentity: "healthcomp.activity-score.v1",
            wireContentSHA256: String(repeating: "a", count: 64)
        )

        let object = try XCTUnwrap(
            jsonObject(
                CompetitionWireCodec.encode(
                    request,
                    contract: .scoreRevisionRequest
                )
            ) as? [String: AnyHashable]
        )

        let expected: [String: AnyHashable] = [
                "version": 1,
                "competitionId": "63000000-0000-4000-8000-000000000001",
                "semanticEventId": "64000000-0000-4000-8000-000000000001",
                "dayOrdinal": 1,
                "clientRevision": "9007199254740993",
                "evaluatedAt": "2026-08-12T12:00:00Z",
                "moveMode": "activeEnergyKilocalories",
                "standMode": "standHours",
                "moveBasisPoints": 10_000,
                "exerciseBasisPoints": 5_000,
                "standBasisPoints": 12_500,
                "availabilityReason": "available",
                "scoringPolicyIdentity": "healthcomp.activity-score.v1",
                "wireContentSHA256": String(repeating: "a", count: 64),
            ]
        XCTAssertEqual(
            object as NSDictionary,
            expected as NSDictionary
        )
    }

    func testRecursivePrivacySentinelsAreRejectedDirectlyAndThroughBase64() throws {
        let base = try XCTUnwrap(
            jsonObject(
                CompetitionWireCodec.encode(
                    try fixtureScoreRequest(),
                    contract: .scoreRevisionRequest
                )
            ) as? [String: Any]
        )
        let sentinels = [
            "activity-snapshot:secret",
            "accepted-activity-score:secret",
            "live-day-score:secret",
        ]

        for sentinel in sentinels {
            for value in [
                sentinel,
                Data(sentinel.utf8).base64EncodedString(),
                Data(sentinel.utf8).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: ""),
            ] {
                var candidate = base
                candidate["unexpected"] = ["nested": [value]]
                let data = try JSONSerialization.data(withJSONObject: candidate)

                XCTAssertThrowsError(
                    try CompetitionWireCodec.decode(
                        CompetitionScoreRevisionRequest.self,
                        from: data,
                        contract: .scoreRevisionRequest
                    )
                ) { error in
                    XCTAssertEqual(
                        error as? CompetitionWireContractError,
                        .serverContractMismatch
                    )
                }
            }
        }
    }

    func testCompetitionDescriptorUsesOnlyParticipantSafePresentation() throws {
        let data = try jsonData(competitionDescriptorObject())

        let descriptor = try CompetitionWireCodec.decode(
            CompetitionDescriptor.self,
            from: data,
            contract: .competitionDescriptor
        )

        XCTAssertEqual(descriptor.competitionID, competitionID)
        XCTAssertEqual(descriptor.creatorProfileID, participantAID)
        XCTAssertEqual(descriptor.lifecycle, .scheduled)
        XCTAssertEqual(descriptor.serverCursor, 3)
        XCTAssertEqual(
            descriptor.participants.map(\.profile.displayName),
            ["Beta Alice", "Beta Bob"]
        )
        XCTAssertEqual(
            try jsonObject(
                CompetitionWireCodec.encode(
                    descriptor,
                    contract: .competitionDescriptor
                )
            ) as? NSDictionary,
            try jsonObject(data) as? NSDictionary
        )
    }

    func testPostgresOffsetTimestampsDecodeAndReencodeCanonically() throws {
        var object = competitionDescriptorObject()
        object["invitation_expires_at"] = "2026-08-12T12:00:00+00:00"
        object["best_available_deadline"] = "2026-08-21T07:00:00+00:00"

        let descriptor = try CompetitionWireCodec.decode(
            CompetitionDescriptor.self,
            from: jsonData(object),
            contract: .competitionDescriptor
        )

        XCTAssertEqual(descriptor.invitationExpiresAt, referenceDate)
        let encoded = try XCTUnwrap(
            jsonObject(
                CompetitionWireCodec.encode(
                    descriptor,
                    contract: .competitionDescriptor
                )
            ) as? [String: Any]
        )
        XCTAssertEqual(encoded["invitation_expires_at"] as? String, timestamp)
        XCTAssertEqual(
            encoded["best_available_deadline"] as? String,
            "2026-08-21T07:00:00Z"
        )
    }

    func testInviteAndClaimContractsAreExactAndCapabilityMinimal() throws {
        let createRequest = try CompetitionInviteCreationRequest(
            timeZoneIdentifier: "America/Los_Angeles",
            rematchParentID: nil,
            idempotencyKey: idempotencyID
        )
        XCTAssertEqual(
            try jsonObject(
                CompetitionWireCodec.encode(
                    createRequest,
                    contract: .inviteCreationRequest
                )
            ) as? NSDictionary,
            [
                "timeZoneIdentifier": "America/Los_Angeles",
                "rematchParentId": NSNull(),
                "idempotencyKey": idempotencyID.uuidString.lowercased(),
            ] as NSDictionary
        )

        let token = Data(repeating: 0x42, count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let inviteData = try jsonData([
            "competitionId": competitionID.uuidString.lowercased(),
            "token": token,
        ])
        let invite = try CompetitionWireCodec.decode(
            CompetitionInvite.self,
            from: inviteData,
            contract: .inviteCreationResponse
        )
        XCTAssertEqual(invite.competitionID, competitionID)
        XCTAssertEqual(invite.token, token)

        let claim = try CompetitionInviteClaimRequest(token: token)
        XCTAssertEqual(
            try jsonObject(
                CompetitionWireCodec.encode(
                    claim,
                    contract: .inviteClaimRequest
                )
            ) as? NSDictionary,
            ["token": token] as NSDictionary
        )
        let result = try CompetitionWireCodec.decode(
            CompetitionInviteClaim.self,
            from: try jsonData([
                "competitionId": competitionID.uuidString.lowercased(),
            ]),
            contract: .inviteClaimResponse
        )
        XCTAssertEqual(result.competitionID, competitionID)
    }

    func testInviteClaimDirectDecodePreservesTokenInvariant() throws {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                CompetitionInviteClaimRequest.self,
                from: jsonData(["token": "short"])
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionWireContractError,
                .serverContractMismatch
            )
        }
    }

    func testScoreAndAttestationReceiptsStayAcknowledgments() throws {
        let scoreData = try jsonData([
            "disposition": "appended",
            "acceptedCentiPoints": 27_500,
            "wireContentSHA256": digest("a"),
            "acceptedServerSeq": "4",
            "competitionCursor": "7",
        ])
        let score = try CompetitionWireCodec.decode(
            CompetitionScoreRevisionResponse.self,
            from: scoreData,
            contract: .scoreRevisionResponse
        )
        XCTAssertEqual(score.disposition, .appended)
        XCTAssertEqual(score.acceptedServerSequence, 4)
        XCTAssertEqual(score.competitionCursor, 7)

        let attestationRequest = try CompetitionAttestationRequest(
            competitionID: competitionID,
            semanticEventID: semanticEventID,
            attestationVersion: 2,
            basis: .stable,
            acceptedRevisions: [1, 2, 3, 4, 5, 6, 7],
            windowCommitmentSHA256: digest("b")
        )
        let requestObject = try XCTUnwrap(
            jsonObject(
                CompetitionWireCodec.encode(
                    attestationRequest,
                    contract: .attestationRequest
                )
            ) as? NSDictionary
        )
        XCTAssertEqual(
            Set(requestObject.allKeys as! [String]),
            [
                "version", "competitionId", "semanticEventId",
                "attestationVersion", "basis", "acceptedRevisions",
                "windowCommitmentSHA256",
            ]
        )
        XCTAssertEqual(
            requestObject["acceptedRevisions"] as? [String],
            ["1", "2", "3", "4", "5", "6", "7"]
        )

        let receipt = try CompetitionWireCodec.decode(
            CompetitionAttestationReceipt.self,
            from: try jsonData([
                "disposition": "duplicate",
                "windowCommitmentSHA256": digest("b"),
                "serverCursor": "8",
            ]),
            contract: .attestationResponse
        )
        XCTAssertEqual(receipt.disposition, .duplicate)
        XCTAssertEqual(receipt.entityServerSequence, 8)
        XCTAssertEqual(receipt.windowCommitmentSHA256, digest("b"))
    }

    func testInstallationAndSynchronizationCursorContractsAreExact() throws {
        let request = try CompetitionInstallationRequest(
            installationID: installationID,
            apnsToken: String(repeating: "a1", count: 32),
            environment: .sandbox
        )
        XCTAssertEqual(
            try jsonObject(
                CompetitionWireCodec.encode(
                    request,
                    contract: .installationRequest
                )
            ) as? NSDictionary,
            [
                "installation_id": installationID.uuidString.lowercased(),
                "apns_token": String(repeating: "a1", count: 32),
                "environment": "sandbox",
            ] as NSDictionary
        )

        let installation = try CompetitionWireCodec.decode(
            CompetitionInstallation.self,
            from: try jsonData([
                "installation_id": installationID.uuidString.lowercased(),
                "environment": "sandbox",
                "state": "active",
            ]),
            contract: .installationResponse
        )
        XCTAssertEqual(installation.installationID, installationID)
        XCTAssertEqual(installation.state, .active)

        let cursor = try CompetitionSynchronizationCursor(
            competitionID: competitionID,
            lastSeenServerSequence: 9_007_199_254_740_993
        )
        let cursorData = try CompetitionWireCodec.encode(
            cursor,
            contract: .synchronizationCursor
        )
        XCTAssertEqual(
            try jsonObject(cursorData) as? NSDictionary,
            [
                "competition_id": competitionID.uuidString.lowercased(),
                "last_seen_server_seq": "9007199254740993",
            ] as NSDictionary
        )
        XCTAssertEqual(
            try CompetitionWireCodec.decode(
                CompetitionSynchronizationCursor.self,
                from: cursorData,
                contract: .synchronizationCursor
            ),
            cursor
        )
    }

    func testChangePageDecodesEveryAuthoritativePayloadFamilyGapFree() throws {
        let data = try jsonData(try changePageObject())

        let page = try CompetitionWireCodec.decode(
            CompetitionChangePage.self,
            from: data,
            contract: .changePage
        )

        XCTAssertEqual(page.competitionID, competitionID)
        XCTAssertEqual(page.afterServerSequence, 0)
        XCTAssertEqual(page.snapshotServerSequence, 7)
        XCTAssertEqual(page.nextServerSequence, 7)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(
            page.changes.map(\.kind),
            [
                .participantAdded,
                .competitionLifecycleChanged,
                .profilePresentationChanged,
                .scoreRevisionRecorded,
                .participantAttested,
                .competitionResultConfirmed,
                .competitionAwardEarned,
            ]
        )

        guard case let .participantAttestation(attestation) =
            page.changes[4].payload
        else {
            return XCTFail("Expected authoritative attestation")
        }
        XCTAssertEqual(attestation.attestationVersion, 2)
        XCTAssertEqual(attestation.attestedAt, referenceDate)

        guard case let .result(result) = page.changes[5].payload else {
            return XCTFail("Expected exact shared result")
        }
        XCTAssertEqual(result.outcome, .tie)
        XCTAssertEqual(result.frozenWindow.participants.count, 2)

        guard case let .award(award) = page.changes[6].payload else {
            return XCTFail("Expected award")
        }
        XCTAssertEqual(award.type, .sevenDayFinisher)
    }

    func testChangePageRejectsUnknownFieldsWrongTypesAndPrivacyShapes() throws {
        let valid = try changePageObject()
        var invalidValues: [Any] = []

        var extraRoot = valid
        extraRoot["debug"] = true
        invalidValues.append(extraRoot)

        var numericCursor = valid
        numericCursor["next_server_seq"] = 7
        invalidValues.append(numericCursor)

        var nonEmptyZeroWidthPage = valid
        nonEmptyZeroWidthPage["next_server_seq"] = "0"
        nonEmptyZeroWidthPage["has_more"] = true
        invalidValues.append(nonEmptyZeroWidthPage)

        var emptyProgresslessPage = valid
        emptyProgresslessPage["next_server_seq"] = "0"
        emptyProgresslessPage["has_more"] = true
        emptyProgresslessPage["changes"] = []
        invalidValues.append(emptyProgresslessPage)

        var disproportionateSequenceSpan = valid
        disproportionateSequenceSpan["snapshot_server_seq"] =
            String(Int64.max)
        disproportionateSequenceSpan["next_server_seq"] = String(Int64.max)
        invalidValues.append(disproportionateSequenceSpan)

        var oversizedPage = valid
        let firstChange = try XCTUnwrap(
            (valid["changes"] as? [[String: Any]])?.first
        )
        oversizedPage["snapshot_server_seq"] = "201"
        oversizedPage["next_server_seq"] = "201"
        oversizedPage["changes"] = (1...201).map { sequence in
            var change = firstChange
            change["server_seq"] = String(sequence)
            return change
        }
        invalidValues.append(oversizedPage)

        var unknownKind = valid
        var unknownChanges = unknownKind["changes"] as! [[String: Any]]
        unknownChanges[0]["kind"] = "future_unvalidated_kind"
        unknownKind["changes"] = unknownChanges
        invalidValues.append(unknownKind)

        var rawGoal = valid
        var goalChanges = rawGoal["changes"] as! [[String: Any]]
        var scorePayload = goalChanges[3]["payload"] as! [String: Any]
        scorePayload["move_goal"] = 600
        goalChanges[3]["payload"] = scorePayload
        rawGoal["changes"] = goalChanges
        invalidValues.append(rawGoal)

        var encodedFingerprint = valid
        var fingerprintChanges = encodedFingerprint["changes"] as! [[String: Any]]
        var awardPayload = fingerprintChanges[6]["payload"] as! [String: Any]
        awardPayload["opaque"] = Data("live-day-score:secret".utf8)
            .base64EncodedString()
        fingerprintChanges[6]["payload"] = awardPayload
        encodedFingerprint["changes"] = fingerprintChanges
        invalidValues.append(encodedFingerprint)

        for invalid in invalidValues {
            XCTAssertThrowsError(
                try CompetitionWireCodec.decode(
                    CompetitionChangePage.self,
                    from: jsonData(invalid),
                    contract: .changePage
                )
            ) { error in
                XCTAssertEqual(
                    error as? CompetitionWireContractError,
                    .serverContractMismatch
                )
            }
        }
    }

    private func fixtureScoreRequest() throws -> CompetitionScoreRevisionRequest {
        try CompetitionScoreRevisionRequest(
            competitionID: UUID(uuidString: "63000000-0000-4000-8000-000000000001")!,
            semanticEventID: UUID(uuidString: "64000000-0000-4000-8000-000000000001")!,
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
            wireContentSHA256: String(repeating: "a", count: 64)
        )
    }

    private func jsonObject(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }

    private func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func competitionDescriptorObject() -> [String: Any] {
        [
            "id": competitionID.uuidString.lowercased(),
            "creator_profile_id": participantAID.uuidString.lowercased(),
            "time_zone_identifier": "America/Los_Angeles",
            "start_day": "2026-08-13",
            "scoring_policy_identity": "healthcomp.activity-score.v1",
            "lifecycle": "scheduled",
            "invitation_expires_at": "2026-08-12T12:00:00Z",
            "best_available_deadline": "2026-08-21T07:00:00Z",
            "rematch_parent_id": NSNull(),
            "next_server_seq": 4,
            "participants": [
                [
                    "profile_id": participantAID.uuidString.lowercased(),
                    "role": "creator",
                    "state": "accepted",
                    "profile": [
                        "id": participantAID.uuidString.lowercased(),
                        "display_name": "Beta Alice",
                    ],
                ],
                [
                    "profile_id": participantBID.uuidString.lowercased(),
                    "role": "invitee",
                    "state": "accepted",
                    "profile": [
                        "id": participantBID.uuidString.lowercased(),
                        "display_name": "Beta Bob",
                    ],
                ],
            ],
        ]
    }

    private func changePageObject() throws -> [String: Any] {
        let scoreWire = try RemoteScoreRevisionWireV1(
            competitionID: competitionID,
            participantID: participantAID,
            dayOrdinal: 1,
            moveMode: "activeEnergyKilocalories",
            standMode: "standHours",
            moveBasisPoints: 10_000,
            exerciseBasisPoints: 5_000,
            standBasisPoints: 12_500,
            availabilityReason: "available",
            scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            clientRevision: 1
        )
        let missingDays = try (1...7).map { ordinal in
            try RemoteFinalizationDayV1(
                ordinal: ordinal,
                status: .unavailable,
                source: .deadlineMissing,
                points: nil,
                reason: "missing",
                wireContentSHA256: nil,
                clientRevision: nil,
                serverSequence: nil
            )
        }
        let commitmentA = try RemoteFinalizationWireV1.windowCommitment(
            competitionID: competitionID,
            participantID: participantAID,
            days: missingDays
        )
        let commitmentB = try RemoteFinalizationWireV1.windowCommitment(
            competitionID: competitionID,
            participantID: participantBID,
            days: missingDays
        )
        let resultHash = try RemoteFinalizationWireV1.resultHash(
            competitionID: competitionID,
            participantA: participantAID,
            totalA: 0,
            commitmentA: commitmentA,
            participantB: participantBID,
            totalB: 0,
            commitmentB: commitmentB,
            outcome: "tie",
            winner: nil,
            basis: "best_available"
        )
        let days: [[String: Any]] = (1...7).map { ordinal in
            [
                "ordinal": ordinal,
                "status": "unavailable",
                "source": "deadline_missing",
                "centi_points": NSNull(),
                "reason": "missing",
                "wire_content_sha256": NSNull(),
                "client_revision": NSNull(),
                "server_seq": NSNull(),
                "scoring_policy_identity": NSNull(),
            ]
        }
        let frozenWindow: [String: Any] = [
            "version": 2,
            "policy": "healthcomp.activity-score.v1",
            "participants": [
                [
                    "profile_id": participantAID.uuidString.lowercased(),
                    "total_centi_points": 0,
                    "window_commitment_sha256": commitmentA,
                    "days": days,
                ],
                [
                    "profile_id": participantBID.uuidString.lowercased(),
                    "total_centi_points": 0,
                    "window_commitment_sha256": commitmentB,
                    "days": days,
                ],
            ],
        ]

        return [
            "competition_id": competitionID.uuidString.lowercased(),
            "after_server_seq": "0",
            "snapshot_server_seq": "7",
            "next_server_seq": "7",
            "has_more": false,
            "changes": [
                change(
                    sequence: 1,
                    kind: "participant_added",
                    entityID: participantAID,
                    payload: [
                        "profile_id": participantAID.uuidString.lowercased(),
                        "role": "creator",
                        "state": "accepted",
                    ]
                ),
                change(
                    sequence: 2,
                    kind: "competition_lifecycle_changed",
                    entityID: competitionID,
                    payload: [
                        "lifecycle": "scheduled",
                        "time_zone_identifier": "America/Los_Angeles",
                        "start_day": "2026-08-13",
                        "best_available_deadline": "2026-08-21T07:00:00Z",
                        "scoring_policy_identity": "healthcomp.activity-score.v1",
                    ]
                ),
                change(
                    sequence: 3,
                    kind: "profile_presentation_changed",
                    entityID: participantBID,
                    payload: [
                        "profile_id": participantBID.uuidString.lowercased(),
                        "display_name": "Beta Bob",
                    ]
                ),
                change(
                    sequence: 4,
                    kind: "score_revision_recorded",
                    entityID: scoreEntityID,
                    payload: [
                        "participant_profile_id": participantAID.uuidString.lowercased(),
                        "day_ordinal": 1,
                        "client_revision": "1",
                        "move_mode": "activeEnergyKilocalories",
                        "stand_mode": "standHours",
                        "move_basis_points": 10_000,
                        "exercise_basis_points": 5_000,
                        "stand_basis_points": 12_500,
                        "accepted_centi_points": 27_500,
                        "availability_reason": "available",
                        "scoring_policy_identity": "healthcomp.activity-score.v1",
                        "wire_digest_version": 1,
                        "wire_content_sha256": scoreWire.wireContentSHA256,
                        "server_seq": "4",
                        "evaluated_at": timestamp,
                    ]
                ),
                change(
                    sequence: 5,
                    kind: "participant_attested",
                    entityID: attestationEntityID,
                    payload: [
                        "participant_profile_id": participantAID.uuidString.lowercased(),
                        "basis": "stable",
                        "window_commitment_sha256": digest("c"),
                        "accepted_revisions": ["1", "2", "3", "4", "5", "6", "7"],
                        "attestation_version": "2",
                        "server_seq": "5",
                        "attested_at": timestamp,
                    ]
                ),
                change(
                    sequence: 6,
                    kind: "competition_result_confirmed",
                    entityID: competitionID,
                    payload: [
                        "participant_a_profile_id": participantAID.uuidString.lowercased(),
                        "participant_b_profile_id": participantBID.uuidString.lowercased(),
                        "participant_a_total_centi_points": 0,
                        "participant_b_total_centi_points": 0,
                        "winner_profile_id": NSNull(),
                        "outcome": "tie",
                        "finalization_basis": "best_available",
                        "completed_at": timestamp,
                        "frozen_window": frozenWindow,
                        "immutable_hash": resultHash,
                        "server_seq": "6",
                    ]
                ),
                change(
                    sequence: 7,
                    kind: "competition_award_earned",
                    entityID: awardEntityID,
                    payload: [
                        "profile_id": participantAID.uuidString.lowercased(),
                        "award_type": "seven_day_finisher",
                        "server_seq": "7",
                        "earned_at": timestamp,
                    ]
                ),
            ],
        ]
    }

    private func change(
        sequence: Int64,
        kind: String,
        entityID: UUID,
        payload: [String: Any]
    ) -> [String: Any] {
        [
            "server_seq": String(sequence),
            "kind": kind,
            "entity_id": entityID.uuidString.lowercased(),
            "occurred_at": timestamp,
            "payload": payload,
        ]
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private var competitionID: UUID {
        UUID(uuidString: "63000000-0000-4000-8000-000000000001")!
    }
    private var participantAID: UUID {
        UUID(uuidString: "11000000-0000-4000-8000-000000000001")!
    }
    private var participantBID: UUID {
        UUID(uuidString: "22000000-0000-4000-8000-000000000001")!
    }
    private var idempotencyID: UUID {
        UUID(uuidString: "66000000-0000-4000-8000-000000000001")!
    }
    private var semanticEventID: UUID {
        UUID(uuidString: "65000000-0000-4000-8000-000000000001")!
    }
    private var installationID: UUID {
        UUID(uuidString: "85000000-0000-4000-8000-000000000001")!
    }
    private var scoreEntityID: UUID {
        UUID(uuidString: "87000000-0000-4000-8000-000000000001")!
    }
    private var attestationEntityID: UUID {
        UUID(uuidString: "87000000-0000-4000-8000-000000000002")!
    }
    private var awardEntityID: UUID {
        UUID(uuidString: "87000000-0000-4000-8000-000000000003")!
    }
    private var timestamp: String { "2026-08-12T12:00:00Z" }
    private var referenceDate: Date {
        ISO8601DateFormatter().date(from: timestamp)!
    }
}
