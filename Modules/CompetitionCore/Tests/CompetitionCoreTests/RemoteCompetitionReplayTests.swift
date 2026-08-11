import Foundation
import XCTest

@testable import CompetitionCore

final class RemoteCompetitionReplayTests: XCTestCase {
    func testRemoteConfigurationSemanticIdentityBindsBothParticipantsAndDescriptorRevision() throws {
        let competitionID = CompetitionID(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!)
        let schedule = CompetitionSchedule(
            calendar: try CompetitionCalendar(timeZoneIdentifier: "America/Los_Angeles"),
            startDay: try CompetitionDay(era: 1, year: 2026, month: 8, day: 10, timeZoneIdentifier: "America/Los_Angeles")
        )
        let owner = try RemoteParticipant(profileID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let remote = try RemoteParticipant(profileID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)

        let baseline = try RemoteCompetitionConfiguration(
            competitionID: competitionID,
            owner: owner,
            remote: remote,
            acceptedSchedule: schedule,
            scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            backendDescriptorRevision: 1,
            bestAvailableDeadline: Date(timeIntervalSince1970: 1_787_000_000)
        )
        let changedParticipant = try RemoteCompetitionConfiguration(
            competitionID: competitionID,
            owner: owner,
            remote: try RemoteParticipant(profileID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!),
            acceptedSchedule: schedule,
            scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            backendDescriptorRevision: 1,
            bestAvailableDeadline: Date(timeIntervalSince1970: 1_787_000_000)
        )
        let changedRevision = try RemoteCompetitionConfiguration(
            competitionID: competitionID,
            owner: owner,
            remote: remote,
            acceptedSchedule: schedule,
            scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            backendDescriptorRevision: 2,
            bestAvailableDeadline: Date(timeIntervalSince1970: 1_787_000_000)
        )

        XCTAssertNotEqual(baseline.semanticIdentity, changedParticipant.semanticIdentity)
        XCTAssertNotEqual(baseline.semanticIdentity, changedRevision.semanticIdentity)
    }

    func testRemoteValueSemanticIDsChangeWhenPersistedFactsChange() throws {
        let competitionID = CompetitionID(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!)
        let owner = try RemoteParticipant(profileID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let row = try RemoteAcceptedScoreRow(ordinal: 1, acceptedCentiPoints: 123, availabilityReason: nil, wireContentSHA256: String(repeating: "a", count: 64), clientRevision: 1, serverSequence: 2)
        let first = try RemoteScoreRevision(competitionID: competitionID, participant: owner, row: row, recordedAt: Date(timeIntervalSince1970: 100))
        let later = try RemoteScoreRevision(competitionID: competitionID, participant: owner, row: row, recordedAt: Date(timeIntervalSince1970: 101))
        XCTAssertNotEqual(first.semanticEventID, later.semanticEventID)

        let attestation = try RemoteFinalWindowAttestation(competitionID: competitionID, participant: owner, windowCommitment: String(repeating: "b", count: 64), basis: .stable, acceptedRevisions: [1, 2, 3, 4, 5, 6, 7], attestationVersion: 1, serverSequence: 3, attestedAt: Date(timeIntervalSince1970: 102))
        let changedRevision = try RemoteFinalWindowAttestation(competitionID: competitionID, participant: owner, windowCommitment: String(repeating: "b", count: 64), basis: .stable, acceptedRevisions: [1, 2, 3, 4, 5, 6, 8], attestationVersion: 1, serverSequence: 3, attestedAt: Date(timeIntervalSince1970: 102))
        XCTAssertNotEqual(attestation.semanticEventID, changedRevision.semanticEventID)

        let receipt = try SynchronizationReceipt(competitionID: competitionID, serverCursor: 4, acknowledgedEventID: first.semanticEventID, kind: .scoreRevision, disposition: .appended, entityServerSequence: 2, receivedAt: Date(timeIntervalSince1970: 103))
        let duplicate = try SynchronizationReceipt(competitionID: competitionID, serverCursor: 4, acknowledgedEventID: first.semanticEventID, kind: .scoreRevision, disposition: .duplicate, entityServerSequence: 2, receivedAt: Date(timeIntervalSince1970: 103))
        XCTAssertNotEqual(receipt.semanticEventID, duplicate.semanticEventID)
    }

    func testRemoteConfigurationReplaysOnceAndRejectsSimulatedActivityEvidence() throws {
        let competitionID = CompetitionID(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!)
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "America/Los_Angeles")
        let schedule = CompetitionSchedule(calendar: calendar, startDay: try CompetitionDay(era: 1, year: 2026, month: 8, day: 10, timeZoneIdentifier: calendar.timeZoneIdentifier))
        let owner = try RemoteParticipant(profileID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let remote = try RemoteParticipant(profileID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        let config = try RemoteCompetitionConfiguration(competitionID: competitionID, owner: owner, remote: remote, acceptedSchedule: schedule, scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity, backendDescriptorRevision: 1, bestAvailableDeadline: Date(timeIntervalSince1970: 1_787_000_000))
        let genesis = try CompetitionGenesis(competitionID: competitionID, direction: .incoming, createdAt: Date(timeIntervalSince1970: 1_786_000_000), expiresAt: nil, scoringPolicy: .appleCompatibility, downwardRevisionPolicy: .maximumObserved)
        var journal = try CompetitionJournal(genesis: genesis)
        _ = try journal.append([.remoteConfigurationAccepted(config)], expectedCursor: journal.cursor)
        let projection = try CompetitionReplayer.replay(journal)
        XCTAssertEqual(projection.competition.remoteConfiguration, config)
        XCTAssertEqual(projection.competition.lifecycle, .scheduled)
    }

    func testV4ValueDecodersRevalidateConstructorInvariants() throws {
        let owner = try RemoteParticipant(profileID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let row = try RemoteAcceptedScoreRow(ordinal: 1, acceptedCentiPoints: 1, availabilityReason: nil, wireContentSHA256: String(repeating: "a", count: 64), clientRevision: 1, serverSequence: 1)
        let revision = try RemoteScoreRevision(competitionID: CompetitionID(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!), participant: owner, row: row, recordedAt: Date(timeIntervalSince1970: 1))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(revision)) as? [String: Any])
        json["recordedAt"] = "not-a-date"
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteScoreRevision.self, from: JSONSerialization.data(withJSONObject: json)))

        let receipt = try SynchronizationReceipt(competitionID: revision.competitionID, serverCursor: 3, acknowledgedEventID: revision.semanticEventID, kind: .scoreRevision, disposition: .appended, entityServerSequence: 1, receivedAt: Date(timeIntervalSince1970: 2))
        var receiptJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        receiptJSON["disposition"] = "rejected"
        XCTAssertThrowsError(try JSONDecoder().decode(SynchronizationReceipt.self, from: JSONSerialization.data(withJSONObject: receiptJSON)))
    }

    func testSharedResultUsesExactFrozenWindowV2ShapeAndRejectsPoisonedPayloads() throws {
        let result = try validSharedResult()
        let data = try JSONEncoder().encode(result)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["competition_id", "owner_profile_id", "remote_profile_id", "frozen_window", "winner_profile_id", "finalization_basis", "immutable_hash", "completed_at", "server_seq"])
        let window = try XCTUnwrap(json["frozen_window"] as? [String: Any])
        XCTAssertEqual(Set(window.keys), ["version", "policy", "participants"])
        XCTAssertEqual(window["version"] as? Int, 2)
        XCTAssertEqual(window["policy"] as? String, RemoteScoringWireV1.policyIdentity)
        let participants = try XCTUnwrap(window["participants"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(participants.first).keys), ["profile_id", "total_centi_points", "window_commitment_sha256", "days"])
        let day = try XCTUnwrap(try XCTUnwrap(participants.first)["days"] as? [[String: Any]]).first!
        XCTAssertEqual(Set(day.keys), ["ordinal", "status", "source", "centi_points", "reason", "wire_content_sha256", "client_revision", "server_seq", "scoring_policy_identity"])
        XCTAssertEqual(try JSONDecoder().decode(SharedCompetitionResult.self, from: data), result)

        for mutation: (inout [String: Any]) -> Void in [
            { $0["frozen_window"] = ["version": 1] },
            { var w = $0["frozen_window"] as! [String: Any]; w["policy"] = "wrong"; $0["frozen_window"] = w },
            { $0["winner_profile_id"] = NSNull() },
            { $0["server_seq"] = 0 },
            { $0["completed_at"] = "bad" },
            { $0["immutable_hash"] = String(repeating: "0", count: 64) },
        ] {
            var poisoned = json; mutation(&poisoned)
            XCTAssertThrowsError(try JSONDecoder().decode(SharedCompetitionResult.self, from: JSONSerialization.data(withJSONObject: poisoned)))
        }

        let missing = try SharedResultDay(ordinal: 1, status: .unavailable, source: .deadlineMissing, centiPoints: nil, reason: "missing", wireContentSHA256: nil, clientRevision: nil, serverSequence: nil, scoringPolicyIdentity: nil)
        let missingJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(missing)) as? [String: Any])
        XCTAssertEqual(Set(missingJSON.keys), Set(day.keys))
        XCTAssertTrue(missingJSON["centi_points"] is NSNull)
        XCTAssertEqual(try JSONDecoder().decode(SharedResultDay.self, from: JSONEncoder().encode(missing)), missing)
    }

    func testRemoteTerminalProjectionContainsOnlyRemoteCommittedFacts() throws {
        let result = try validSharedResult()
        let schedule = CompetitionSchedule(
            calendar: try CompetitionCalendar(timeZoneIdentifier: "America/Los_Angeles"),
            startDay: try CompetitionDay(era: 1, year: 2026, month: 8, day: 10, timeZoneIdentifier: "America/Los_Angeles")
        )
        let configuration = try RemoteCompetitionConfiguration(
            competitionID: result.competitionID,
            owner: result.owner,
            remote: result.remote,
            acceptedSchedule: schedule,
            scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            backendDescriptorRevision: 3,
            bestAvailableDeadline: Date(timeIntervalSince1970: 1_787_000_000)
        )
        let completed = try CompletedCompetition(
            snapshot: FinalScoreSnapshot(userPoints: 2.8, opponentPoints: 0.28),
            basis: .stableAcrossPostBoundaryReads,
            completedAt: result.confirmedAt
        )
        let competition = Competition(
            id: result.competitionID,
            lifecycle: .completed(completed),
            schedule: schedule,
            opponentPlan: nil,
            remoteConfiguration: configuration,
            appliedEventIDs: []
        )
        let projection = CompetitionReplayProjection(
            competition: competition,
            scoreLedger: ScoreLedger(scoringPolicy: .appleCompatibility, downwardRevisionPolicy: .maximumObserved),
            sharedResult: result
        )

        let terminal = try CompetitionSemanticTerminalProjection(projection: projection)
        XCTAssertEqual(terminal.counterpartyKind, .remote)
        XCTAssertEqual(terminal.remoteOwnerProfileID, result.owner.profileID.uuidString.lowercased())
        XCTAssertEqual(terminal.remoteParticipantProfileID, result.remote.profileID.uuidString.lowercased())
        XCTAssertEqual(terminal.remoteResultHash, result.resultHash)
        XCTAssertEqual(terminal.remoteDays.count, 14)
        XCTAssertTrue(terminal.remoteDays.allSatisfy { $0.wireContentSHA256 == nil })
        XCTAssertTrue(terminal.ledgerIsFrozen)
        let encoded = try JSONEncoder().encode(terminal)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["downwardRevisionPolicy"])
        XCTAssertNil(object["days"])
        XCTAssertNil(object["opponentPlanCommitmentHex"])
        XCTAssertEqual(object["counterpartyKind"] as? String, "remote")
    }

    func testRemoteTerminalFixturesMatchProductionPayloadV4Replay() throws {
        let cases: [RemoteFixtureCase] = [
            .init(name: "remote-stable-win", ownerBase: 300, remoteBase: 200, basis: .stable, ownerMissingOrdinal: nil, cachedRemoteOrdinals: Array(1...7), expectedOutcome: .win),
            .init(name: "remote-stable-loss", ownerBase: 100, remoteBase: 200, basis: .stable, ownerMissingOrdinal: nil, cachedRemoteOrdinals: Array(1...7), expectedOutcome: .loss),
            .init(name: "remote-stable-tie", ownerBase: 200, remoteBase: 200, basis: .stable, ownerMissingOrdinal: nil, cachedRemoteOrdinals: Array(1...7), expectedOutcome: .tie),
            .init(name: "remote-best-available-incomplete", ownerBase: 100, remoteBase: 200, basis: .bestAvailable, ownerMissingOrdinal: 7, cachedRemoteOrdinals: [1], expectedOutcome: .loss),
        ]

        for fixtureCase in cases {
            let journal = try remoteFixtureJournal(fixtureCase)
            let projection = try CompetitionReplayer.replay(journal)
            let terminal = try CompetitionSemanticTerminalProjection(projection: projection)
            let trace = RemoteCompetitionGoldenTrace(
                schema: "healthcomp-remote-competition-trace-v1",
                scenario: fixtureCase.name,
                payloadVersion: 4,
                semanticEventIDs: journal.envelopes.map(\.semanticEventID),
                terminal: terminal
            )

            XCTAssertTrue(journal.envelopes.allSatisfy { $0.payloadVersion == 4 }, fixtureCase.name)
            XCTAssertEqual(terminal.counterpartyKind, .remote, fixtureCase.name)
            XCTAssertEqual(terminal.outcome, fixtureCase.expectedOutcome, fixtureCase.name)
            XCTAssertEqual(terminal.userPoints, Double(fixtureCase.ownerTotal) / 100, fixtureCase.name)
            XCTAssertEqual(terminal.opponentPoints, Double(fixtureCase.remoteTotal) / 100, fixtureCase.name)
            XCTAssertEqual(terminal.remoteOwnerProfileID, fixtureOwner.profileID.uuidString.lowercased(), fixtureCase.name)
            XCTAssertEqual(terminal.remoteParticipantProfileID, fixtureRemote.profileID.uuidString.lowercased(), fixtureCase.name)
            XCTAssertNotNil(terminal.remoteOwnerWindowCommitment, fixtureCase.name)
            XCTAssertNotNil(terminal.remoteParticipantWindowCommitment, fixtureCase.name)
            XCTAssertNotNil(terminal.remoteResultHash, fixtureCase.name)
            XCTAssertEqual(terminal.remoteDays.map(\.profileID), Array(repeating: fixtureOwner.profileID.uuidString.lowercased(), count: 7) + Array(repeating: fixtureRemote.profileID.uuidString.lowercased(), count: 7), fixtureCase.name)
            XCTAssertEqual(terminal.remoteDays.map(\.ordinal), Array(1...7) + Array(1...7), fixtureCase.name)
            XCTAssertTrue(terminal.remoteDays.allSatisfy { $0.wireContentSHA256 == nil }, fixtureCase.name)

            if fixtureCase.basis == .stable {
                XCTAssertEqual(terminal.basis, .stableAcrossPostBoundaryReads, fixtureCase.name)
            } else {
                XCTAssertEqual(terminal.basis, .bestAvailable, fixtureCase.name)
                XCTAssertEqual(terminal.remoteDays.first { $0.profileID == fixtureOwner.profileID.uuidString.lowercased() && $0.ordinal == 7 }?.source, .deadlineMissing, fixtureCase.name)
                XCTAssertNil(try projection.remoteScoreLedgers[fixtureRemote.profileID]?.visibleEntry(forActiveDayOrdinal: 2), fixtureCase.name)
                XCTAssertEqual(terminal.remoteDays.first { $0.profileID == fixtureRemote.profileID.uuidString.lowercased() && $0.ordinal == 2 }?.source, .acceptedRevision, fixtureCase.name)
            }

            let fixtureData = try encodedRemoteFixture(trace)
            let fixtureURL = remoteFixtureURL(named: fixtureCase.name)
            guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
                XCTFail("Missing remote trace fixture at \(fixtureURL.path):\n\(String(decoding: fixtureData, as: UTF8.self))")
                continue
            }
            XCTAssertEqual(try Data(contentsOf: fixtureURL), fixtureData, "fixture drift: \(fixtureCase.name)")

            let terminalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(terminal)) as? [String: Any])
            XCTAssertNil(terminalObject["days"], fixtureCase.name)
            XCTAssertNil(terminalObject["downwardRevisionPolicy"], fixtureCase.name)
            XCTAssertNil(terminalObject["opponentPlanCommitmentHex"], fixtureCase.name)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(terminal), as: UTF8.self).localizedCaseInsensitiveContains("healthkit"), fixtureCase.name)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(terminal), as: UTF8.self).localizedCaseInsensitiveContains("fingerprint"), fixtureCase.name)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(terminal), as: UTF8.self).localizedCaseInsensitiveContains("wirecontent"), fixtureCase.name)
        }
    }

    func testRemoteReplayAcceptsOnlyServerAuthoritativeResultEvidence() throws {
        let bestAvailable = try remoteJournal(
            basis: .bestAvailable,
            ownerMissingOrdinal: 7,
            cachedRemoteOrdinals: [1],
            confirmedAt: fixtureDeadline
        )
        let projection = try CompetitionReplayer.replay(bestAvailable)
        XCTAssertEqual(projection.sharedResult?.basis, .bestAvailable)
        XCTAssertEqual(try projection.sharedResult?.window(for: fixtureOwner).days[6].source, .deadlineMissing)
        XCTAssertEqual(try projection.remoteScoreLedgers[fixtureRemote.profileID]?.visibleEntry(forActiveDayOrdinal: 1)?.acceptedCentiPoints, 201)
        XCTAssertNil(try projection.remoteScoreLedgers[fixtureRemote.profileID]?.visibleEntry(forActiveDayOrdinal: 2))

        XCTAssertThrowsError(try remoteJournal(
            basis: .stable,
            ownerMissingOrdinal: 7,
            cachedRemoteOrdinals: Array(1...7),
            confirmedAt: fixtureDeadline
        ))
        XCTAssertThrowsError(try remoteJournal(
            basis: .bestAvailable,
            ownerMissingOrdinal: 7,
            cachedRemoteOrdinals: [1],
            confirmedAt: fixtureDeadline.addingTimeInterval(-1)
        ))
        XCTAssertThrowsError(try remoteJournal(
            basis: .bestAvailable,
            ownerMissingOrdinal: nil,
            cachedRemoteOrdinals: [1],
            confirmedAt: fixtureDeadline,
            mutateCachedRemoteResult: true
        ))
        XCTAssertThrowsError(try remoteJournal(
            basis: .bestAvailable,
            ownerMissingOrdinal: nil,
            cachedRemoteOrdinals: [1],
            confirmedAt: fixtureDeadline,
            mutateOwnerResult: true
        ))
    }

    func testRemoteJournalRejectsLocalActivityAndFinalizationPaths() throws {
        var journal = try remoteJournalPrefix()
        let schedule = try XCTUnwrap(CompetitionReplayer.replay(journal).competition.schedule)
        let days = try schedule.calendar.sevenDayWindow(startingOn: schedule.startDay)
        let refresh = try ActivityRefreshAttemptRecorded(
            attemptID: "remote-local-refresh",
            competitionID: fixtureCompetitionID,
            attemptOrdinal: 1,
            trigger: .launch,
            attemptedAt: fixtureDeadline,
            readAt: fixtureDeadline,
            monotonicInstant: MonotonicInstant(epochID: "remote", nanoseconds: 1),
            readStatus: .completed,
            days: zip(1...7, days).map { ordinal, day in
                ActivityDayObservation(day: day, ordinal: ordinal, availability: .notYetOccurred)
            }
        )
        XCTAssertThrowsError(try journal.append([.activityRefreshAttemptRecorded(refresh)], expectedCursor: journal.cursor))
        let snapshot = try ActivitySnapshotRecorded(
            observationID: "remote-local-snapshot",
            competitionID: fixtureCompetitionID,
            observedAt: fixtureDeadline,
            dayOrdinal: 1,
            snapshot: try fixtureSnapshot()
        )
        XCTAssertThrowsError(try journal.append([.activitySnapshotRecorded(snapshot)], expectedCursor: journal.cursor))

        let remoteCompetition = try CompetitionReplayer.replay(journal).competition
        XCTAssertThrowsError(try CompetitionEngine().recordFinalRead(remoteCompetition, evidence: try fixtureFinalReadEvidence()))
        XCTAssertThrowsError(try CompetitionEngine().finalize(remoteCompetition, authorization: try fixtureAuthorization(), at: fixtureDeadline))
    }

    func testEveryV4RemoteTopLevelCaseIsRejectedByFrozenV1ThroughV3Decoders() throws {
        let result = try remoteResult(basis: .stable, ownerMissingOrdinal: nil, mutateOwner: false, mutateRemote: false)
        let score = try fixtureScore(participant: fixtureOwner, ordinal: 1, points: 101, revision: 1, sequence: 1)
        let attestation = try RemoteFinalWindowAttestation(competitionID: fixtureCompetitionID, participant: fixtureOwner, windowCommitment: try result.window(for: fixtureOwner).windowCommitment, basis: .stable, acceptedRevisions: Array(1...7).map(Int64.init), attestationVersion: 1, serverSequence: 8, attestedAt: fixtureDeadline)
        let receipt = try SynchronizationReceipt(competitionID: fixtureCompetitionID, serverCursor: 9, acknowledgedEventID: score.semanticEventID, kind: .scoreRevision, disposition: .appended, entityServerSequence: score.row.serverSequence, receivedAt: fixtureDeadline)
        let remoteEvents: [CompetitionDomainEvent] = [
            .remoteConfigurationAccepted(try fixtureConfiguration()),
            .remoteScoreRevisionRecorded(score),
            .remoteFinalWindowAttested(attestation),
            .sharedResultConfirmed(result),
            .synchronizationReceiptRecorded(receipt),
        ]

        for event in remoteEvents {
            let payload = try JSONEncoder().encode(event)
            for version in UInt32(1)...UInt32(3) {
                XCTAssertThrowsError(try poisonedJournal(payloadVersion: version, payload: payload, semanticEventID: event.semanticEventID), "\(event.semanticEventID) must not cross v\(version)'s frozen top-level decoder")
            }
        }
    }

    func testFrozenV1ThroughV3LifecycleWrappersRejectFakeRemoteDiscriminator() throws {
        let event = CompetitionEvent(competitionID: fixtureCompetitionID, occurredAt: fixtureDeadline, kind: .invitationDeclined)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(CompetitionDomainEvent.lifecycle(event))) as? [String: Any])
        var lifecycle = try XCTUnwrap(object["lifecycle"] as? [String: Any])
        var wrapped = try XCTUnwrap(lifecycle["_0"] as? [String: Any])
        let configurationObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(try fixtureConfiguration())) as? [String: Any])
        wrapped["kind"] = ["remoteConfigurationAccepted": ["_0": configurationObject]]
        lifecycle["_0"] = wrapped
        object["lifecycle"] = lifecycle
        let payload = try JSONSerialization.data(withJSONObject: object)
        for version in UInt32(1)...UInt32(3) {
            XCTAssertThrowsError(try poisonedJournal(payloadVersion: version, payload: payload, semanticEventID: event.id), "fake remote lifecycle discriminator must not decode in v\(version)")
        }
    }

    func testRemoteSemanticIDsCoverEveryPersistedField() throws {
        let config = try fixtureConfiguration()
        let configVariants = [
            try RemoteCompetitionConfiguration(competitionID: CompetitionID(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaab")!), owner: config.owner, remote: config.remote, acceptedSchedule: config.acceptedSchedule, scoringPolicyIdentity: config.scoringPolicyIdentity, backendDescriptorRevision: config.backendDescriptorRevision, bestAvailableDeadline: config.bestAvailableDeadline),
            try RemoteCompetitionConfiguration(competitionID: config.competitionID, owner: try RemoteParticipant(profileID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!), remote: config.remote, acceptedSchedule: config.acceptedSchedule, scoringPolicyIdentity: config.scoringPolicyIdentity, backendDescriptorRevision: config.backendDescriptorRevision, bestAvailableDeadline: config.bestAvailableDeadline),
            try RemoteCompetitionConfiguration(competitionID: config.competitionID, owner: config.owner, remote: config.remote, acceptedSchedule: CompetitionSchedule(calendar: config.acceptedSchedule.calendar, startDay: try CompetitionDay(era: 1, year: 2026, month: 8, day: 11, timeZoneIdentifier: config.acceptedSchedule.calendar.timeZoneIdentifier)), scoringPolicyIdentity: config.scoringPolicyIdentity, backendDescriptorRevision: config.backendDescriptorRevision, bestAvailableDeadline: config.bestAvailableDeadline.addingTimeInterval(86_400)),
            try RemoteCompetitionConfiguration(competitionID: config.competitionID, owner: config.owner, remote: config.remote, acceptedSchedule: config.acceptedSchedule, scoringPolicyIdentity: config.scoringPolicyIdentity, backendDescriptorRevision: config.backendDescriptorRevision + 1, bestAvailableDeadline: config.bestAvailableDeadline),
            try RemoteCompetitionConfiguration(competitionID: config.competitionID, owner: config.owner, remote: config.remote, acceptedSchedule: config.acceptedSchedule, scoringPolicyIdentity: config.scoringPolicyIdentity, backendDescriptorRevision: config.backendDescriptorRevision, bestAvailableDeadline: config.bestAvailableDeadline.addingTimeInterval(1)),
        ]
        configVariants.forEach { XCTAssertNotEqual(config.semanticIdentity, $0.semanticIdentity) }
        XCTAssertThrowsError(try RemoteCompetitionConfiguration(competitionID: config.competitionID, owner: config.owner, remote: config.remote, acceptedSchedule: config.acceptedSchedule, scoringPolicyIdentity: "unrecognized-policy", backendDescriptorRevision: config.backendDescriptorRevision, bestAvailableDeadline: config.bestAvailableDeadline))

        let score = try fixtureScore(participant: fixtureOwner, ordinal: 1, points: 101, revision: 1, sequence: 1)
        let scoreVariants = [
            try fixtureScore(participant: fixtureRemote, ordinal: 1, points: 101, revision: 1, sequence: 1),
            try fixtureScore(participant: fixtureOwner, ordinal: 2, points: 101, revision: 1, sequence: 1),
            try fixtureScore(participant: fixtureOwner, ordinal: 1, points: 102, revision: 1, sequence: 1),
            try RemoteScoreRevision(competitionID: fixtureCompetitionID, participant: fixtureOwner, row: try RemoteAcceptedScoreRow(ordinal: 1, acceptedCentiPoints: nil, availabilityReason: "invalidSourceData", wireContentSHA256: String(repeating: "b", count: 64), clientRevision: 1, serverSequence: 1), recordedAt: score.recordedAt),
            try fixtureScore(participant: fixtureOwner, ordinal: 1, points: 101, revision: 2, sequence: 1),
            try fixtureScore(participant: fixtureOwner, ordinal: 1, points: 101, revision: 1, sequence: 2),
            try RemoteScoreRevision(competitionID: fixtureCompetitionID, participant: fixtureOwner, row: try RemoteAcceptedScoreRow(ordinal: 1, acceptedCentiPoints: 101, availabilityReason: nil, wireContentSHA256: String(repeating: "c", count: 64), clientRevision: 1, serverSequence: 1), recordedAt: score.recordedAt),
        ]
        scoreVariants.forEach { XCTAssertNotEqual(score.semanticEventID, $0.semanticEventID) }

        let attestation = try RemoteFinalWindowAttestation(competitionID: fixtureCompetitionID, participant: fixtureOwner, windowCommitment: String(repeating: "b", count: 64), basis: .stable, acceptedRevisions: Array(1...7).map(Int64.init), attestationVersion: 1, serverSequence: 1, attestedAt: fixtureDeadline)
        let attestationVariants = [
            try RemoteFinalWindowAttestation(competitionID: fixtureCompetitionID, participant: fixtureRemote, windowCommitment: attestation.windowCommitment, basis: attestation.basis, acceptedRevisions: attestation.acceptedRevisions, attestationVersion: attestation.attestationVersion, serverSequence: attestation.serverSequence, attestedAt: attestation.attestedAt),
            try RemoteFinalWindowAttestation(competitionID: fixtureCompetitionID, participant: fixtureOwner, windowCommitment: String(repeating: "c", count: 64), basis: attestation.basis, acceptedRevisions: attestation.acceptedRevisions, attestationVersion: attestation.attestationVersion, serverSequence: attestation.serverSequence, attestedAt: attestation.attestedAt),
            try RemoteFinalWindowAttestation(competitionID: fixtureCompetitionID, participant: fixtureOwner, windowCommitment: attestation.windowCommitment, basis: .bestAvailable, acceptedRevisions: attestation.acceptedRevisions, attestationVersion: attestation.attestationVersion, serverSequence: attestation.serverSequence, attestedAt: attestation.attestedAt),
            try RemoteFinalWindowAttestation(competitionID: fixtureCompetitionID, participant: fixtureOwner, windowCommitment: attestation.windowCommitment, basis: attestation.basis, acceptedRevisions: [1, 2, 3, 4, 5, 6, 8], attestationVersion: attestation.attestationVersion, serverSequence: attestation.serverSequence, attestedAt: attestation.attestedAt),
            try RemoteFinalWindowAttestation(competitionID: fixtureCompetitionID, participant: fixtureOwner, windowCommitment: attestation.windowCommitment, basis: attestation.basis, acceptedRevisions: attestation.acceptedRevisions, attestationVersion: 2, serverSequence: attestation.serverSequence, attestedAt: attestation.attestedAt),
            try RemoteFinalWindowAttestation(competitionID: fixtureCompetitionID, participant: fixtureOwner, windowCommitment: attestation.windowCommitment, basis: attestation.basis, acceptedRevisions: attestation.acceptedRevisions, attestationVersion: attestation.attestationVersion, serverSequence: 2, attestedAt: attestation.attestedAt),
        ]
        attestationVariants.forEach { XCTAssertNotEqual(attestation.semanticEventID, $0.semanticEventID) }

        let result = try remoteResult(basis: .stable, ownerMissingOrdinal: nil, mutateOwner: false, mutateRemote: false)
        let resultVariants = [
            try remoteResult(basis: .bestAvailable, ownerMissingOrdinal: nil, mutateOwner: false, mutateRemote: false),
            try remoteResult(basis: .stable, ownerMissingOrdinal: nil, mutateOwner: true, mutateRemote: false),
        ]
        resultVariants.forEach { XCTAssertNotEqual(result.semanticEventID, $0.semanticEventID) }
        let swappedRoles = try SharedCompetitionResult(
            competitionID: result.competitionID,
            owner: result.remote,
            remote: result.owner,
            windows: result.windows,
            winner: result.winner,
            basis: result.basis,
            resultHash: result.resultHash,
            confirmedAt: result.confirmedAt,
            serverSequence: result.serverSequence
        )
        XCTAssertNotEqual(result.semanticEventID, swappedRoles.semanticEventID)

        let receipt = try SynchronizationReceipt(competitionID: fixtureCompetitionID, serverCursor: 2, acknowledgedEventID: score.semanticEventID, kind: .scoreRevision, disposition: .appended, entityServerSequence: 1, receivedAt: fixtureDeadline)
        let receiptVariants = [
            try SynchronizationReceipt(competitionID: fixtureCompetitionID, serverCursor: 2, acknowledgedEventID: "another-event", kind: .scoreRevision, disposition: .appended, entityServerSequence: 1, receivedAt: fixtureDeadline),
            try SynchronizationReceipt(competitionID: fixtureCompetitionID, serverCursor: 2, acknowledgedEventID: score.semanticEventID, kind: .finalWindowAttestation, disposition: .appended, entityServerSequence: 1, receivedAt: fixtureDeadline),
            try SynchronizationReceipt(competitionID: fixtureCompetitionID, serverCursor: 2, acknowledgedEventID: score.semanticEventID, kind: .scoreRevision, disposition: .duplicate, entityServerSequence: 1, receivedAt: fixtureDeadline),
            try SynchronizationReceipt(competitionID: fixtureCompetitionID, serverCursor: 2, acknowledgedEventID: score.semanticEventID, kind: .scoreRevision, disposition: .appended, entityServerSequence: 2, receivedAt: fixtureDeadline),
            try SynchronizationReceipt(competitionID: fixtureCompetitionID, serverCursor: 3, acknowledgedEventID: score.semanticEventID, kind: .scoreRevision, disposition: .appended, entityServerSequence: 1, receivedAt: fixtureDeadline),
        ]
        receiptVariants.forEach { XCTAssertNotEqual(receipt.semanticEventID, $0.semanticEventID) }
    }

    private func validSharedResult() throws -> SharedCompetitionResult {
        let cid = CompetitionID(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!)
        let owner = try RemoteParticipant(profileID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let remote = try RemoteParticipant(profileID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        let ownerWindow = try participantWindow(cid, owner, offset: 10)
        let remoteWindow = try participantWindow(cid, remote, offset: 1)
        let hash = try RemoteFinalizationWireV1.resultHash(competitionID: cid.rawValue, participantA: owner.profileID, totalA: ownerWindow.totalCentiPoints, commitmentA: ownerWindow.windowCommitment, participantB: remote.profileID, totalB: remoteWindow.totalCentiPoints, commitmentB: remoteWindow.windowCommitment, outcome: "winner", winner: owner.profileID, basis: "stable")
        return try SharedCompetitionResult(competitionID: cid, owner: owner, remote: remote, windows: [ownerWindow, remoteWindow], winner: owner, basis: .stable, resultHash: hash, confirmedAt: Date(timeIntervalSince1970: 100), serverSequence: 9)
    }

    private func participantWindow(_ cid: CompetitionID, _ participant: RemoteParticipant, offset: Int) throws -> SharedParticipantWindow {
        let days = try (1...7).map { ordinal in
            try SharedResultDay(ordinal: ordinal, status: .points, source: .acceptedRevision, centiPoints: ordinal + offset, reason: nil, wireContentSHA256: String(repeating: String(ordinal), count: 64), clientRevision: Int64(ordinal), serverSequence: Int64(ordinal), scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity)
        }
        let finalDays = try days.map { try RemoteFinalizationDayV1(ordinal: $0.ordinal, status: .points, source: .acceptedRevision, points: $0.centiPoints, reason: nil, wireContentSHA256: $0.wireContentSHA256, clientRevision: $0.clientRevision, serverSequence: $0.serverSequence) }
        let commitment = try RemoteFinalizationWireV1.windowCommitment(competitionID: cid.rawValue, participantID: participant.profileID, days: finalDays)
        return try SharedParticipantWindow(competitionID: cid, participant: participant, totalCentiPoints: days.compactMap(\.centiPoints).reduce(0, +), windowCommitment: commitment, days: days)
    }

    private let fixtureCompetitionID = CompetitionID(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!)
    private let fixtureOwner = try! RemoteParticipant(profileID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    private let fixtureRemote = try! RemoteParticipant(profileID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
    private let fixtureDeadline = Date(timeIntervalSince1970: 1_787_000_000)

    private func fixtureConfiguration() throws -> RemoteCompetitionConfiguration {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "America/Los_Angeles")
        return try RemoteCompetitionConfiguration(
            competitionID: fixtureCompetitionID,
            owner: fixtureOwner,
            remote: fixtureRemote,
            acceptedSchedule: CompetitionSchedule(calendar: calendar, startDay: try CompetitionDay(era: 1, year: 2026, month: 8, day: 10, timeZoneIdentifier: calendar.timeZoneIdentifier)),
            scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            backendDescriptorRevision: 1,
            bestAvailableDeadline: fixtureDeadline
        )
    }

    private func poisonedJournal(payloadVersion: UInt32, payload: Data, semanticEventID: String) throws -> CompetitionJournal {
        let genesis = try CompetitionGenesis(competitionID: fixtureCompetitionID, direction: .incoming, createdAt: fixtureDeadline.addingTimeInterval(-900_000), expiresAt: nil, scoringPolicy: .appleCompatibility, downwardRevisionPolicy: .maximumObserved)
        let empty = try CompetitionJournal(genesis: genesis)
        let envelope = CompetitionJournalEnvelope(payloadVersion: payloadVersion, commitRevision: 1, sequence: 1, streamID: fixtureCompetitionID, semanticEventID: semanticEventID, payload: payload, previousEnvelopeSHA256: empty.genesisDigest)
        return try CompetitionJournal(validating: genesis, envelopes: [envelope])
    }

    private func remoteJournalPrefix() throws -> CompetitionJournal {
        let config = try fixtureConfiguration()
        let genesis = try CompetitionGenesis(competitionID: fixtureCompetitionID, direction: .incoming, createdAt: fixtureDeadline.addingTimeInterval(-900_000), expiresAt: nil, scoringPolicy: .appleCompatibility, downwardRevisionPolicy: .maximumObserved)
        var journal = try CompetitionJournal(genesis: genesis)
        _ = try journal.append([.remoteConfigurationAccepted(config)], expectedCursor: journal.cursor)
        let clock = try CompetitionEngine().observeClock(CompetitionReplayer.replay(journal).competition, at: fixtureDeadline)
        _ = try journal.append(clock.map(CompetitionDomainEvent.lifecycle), expectedCursor: journal.cursor)
        return journal
    }

    private func fixtureScore(participant: RemoteParticipant, ordinal: Int, points: Int, revision: Int64, sequence: Int64) throws -> RemoteScoreRevision {
        let digestSeed = (participant == fixtureOwner ? 100 : 200) + ordinal
        return try RemoteScoreRevision(
            competitionID: fixtureCompetitionID,
            participant: participant,
            row: try RemoteAcceptedScoreRow(ordinal: ordinal, acceptedCentiPoints: points, availabilityReason: nil, wireContentSHA256: String(format: "%064x", digestSeed), clientRevision: revision, serverSequence: sequence),
            recordedAt: fixtureDeadline.addingTimeInterval(Double(sequence))
        )
    }

    private func remoteResult(basis: RemoteFinalizationBasis, ownerMissingOrdinal: Int?, mutateOwner: Bool, mutateRemote: Bool) throws -> SharedCompetitionResult {
        func days(for participant: RemoteParticipant, base: Int, missing: Int?, mutate: Bool) throws -> [SharedResultDay] {
            try (1...7).map { ordinal in
                if ordinal == missing {
                    return try SharedResultDay(ordinal: ordinal, status: .unavailable, source: .deadlineMissing, centiPoints: nil, reason: "missing", wireContentSHA256: nil, clientRevision: nil, serverSequence: nil, scoringPolicyIdentity: nil)
                }
                let points = base + ordinal + (mutate && ordinal == 1 ? 1 : 0)
                let serverSequence = Int64(ordinal + (participant == fixtureRemote ? 100 : 0))
                return try SharedResultDay(ordinal: ordinal, status: .points, source: .acceptedRevision, centiPoints: points, reason: nil, wireContentSHA256: String(format: "%064x", ordinal + base), clientRevision: Int64(ordinal), serverSequence: serverSequence, scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity)
            }
        }
        func window(_ participant: RemoteParticipant, _ days: [SharedResultDay]) throws -> SharedParticipantWindow {
            let finalDays = try days.map { try RemoteFinalizationDayV1(ordinal: $0.ordinal, status: $0.status == .points ? .points : .unavailable, source: $0.source == .acceptedRevision ? .acceptedRevision : .deadlineMissing, points: $0.centiPoints, reason: $0.reason, wireContentSHA256: $0.wireContentSHA256, clientRevision: $0.clientRevision, serverSequence: $0.serverSequence) }
            return try SharedParticipantWindow(competitionID: fixtureCompetitionID, participant: participant, totalCentiPoints: days.compactMap(\.centiPoints).reduce(0, +), windowCommitment: RemoteFinalizationWireV1.windowCommitment(competitionID: fixtureCompetitionID.rawValue, participantID: participant.profileID, days: finalDays), days: days)
        }
        let ownerWindow = try window(fixtureOwner, days(for: fixtureOwner, base: 100, missing: ownerMissingOrdinal, mutate: mutateOwner))
        let remoteWindow = try window(fixtureRemote, days(for: fixtureRemote, base: 200, missing: nil, mutate: mutateRemote))
        let ordered = [ownerWindow, remoteWindow]
        let winner: RemoteParticipant? = ownerWindow.totalCentiPoints == remoteWindow.totalCentiPoints ? nil : (ownerWindow.totalCentiPoints > remoteWindow.totalCentiPoints ? fixtureOwner : fixtureRemote)
        let hash = try RemoteFinalizationWireV1.resultHash(competitionID: fixtureCompetitionID.rawValue, participantA: fixtureOwner.profileID, totalA: ownerWindow.totalCentiPoints, commitmentA: ownerWindow.windowCommitment, participantB: fixtureRemote.profileID, totalB: remoteWindow.totalCentiPoints, commitmentB: remoteWindow.windowCommitment, outcome: winner == nil ? "tie" : "winner", winner: winner?.profileID, basis: basis.rawValue)
        return try SharedCompetitionResult(competitionID: fixtureCompetitionID, owner: fixtureOwner, remote: fixtureRemote, windows: ordered, winner: winner, basis: basis, resultHash: hash, confirmedAt: fixtureDeadline, serverSequence: 99)
    }

    private func remoteJournal(basis: RemoteFinalizationBasis, ownerMissingOrdinal: Int?, cachedRemoteOrdinals: [Int], confirmedAt: Date, mutateCachedRemoteResult: Bool = false, mutateOwnerResult: Bool = false) throws -> CompetitionJournal {
        var journal = try remoteJournalPrefix()
        var events: [CompetitionDomainEvent] = []
        for ordinal in 1...7 where ordinal != ownerMissingOrdinal {
            events.append(.remoteScoreRevisionRecorded(try fixtureScore(participant: fixtureOwner, ordinal: ordinal, points: 100 + ordinal, revision: Int64(ordinal), sequence: Int64(ordinal))))
        }
        for ordinal in cachedRemoteOrdinals {
            events.append(.remoteScoreRevisionRecorded(try fixtureScore(participant: fixtureRemote, ordinal: ordinal, points: 200 + ordinal, revision: Int64(ordinal), sequence: Int64(100 + ordinal))))
        }
        _ = try journal.append(events, expectedCursor: journal.cursor)
        var result = try remoteResult(basis: basis, ownerMissingOrdinal: ownerMissingOrdinal, mutateOwner: mutateOwnerResult, mutateRemote: mutateCachedRemoteResult)
        result = try SharedCompetitionResult(competitionID: result.competitionID, owner: result.owner, remote: result.remote, windows: result.windows, winner: result.winner, basis: result.basis, resultHash: result.resultHash, confirmedAt: confirmedAt, serverSequence: result.serverSequence)
        _ = try journal.append([.sharedResultConfirmed(result)], expectedCursor: journal.cursor)
        return journal
    }

    private func remoteFixtureJournal(_ fixtureCase: RemoteFixtureCase) throws -> CompetitionJournal {
        var journal = try remoteJournalPrefix()
        let ownerDays = try remoteFixtureDays(participant: fixtureOwner, base: fixtureCase.ownerBase, missingOrdinal: fixtureCase.ownerMissingOrdinal)
        let remoteDays = try remoteFixtureDays(participant: fixtureRemote, base: fixtureCase.remoteBase, missingOrdinal: nil)
        let ownerWindow = try remoteFixtureWindow(participant: fixtureOwner, days: ownerDays)
        let remoteWindow = try remoteFixtureWindow(participant: fixtureRemote, days: remoteDays)
        var events: [CompetitionDomainEvent] = []
        for day in ownerDays where day.status == .points {
            events.append(.remoteScoreRevisionRecorded(try remoteFixtureScore(participant: fixtureOwner, day: day)))
        }
        for ordinal in fixtureCase.cachedRemoteOrdinals {
            let day = remoteDays[ordinal - 1]
            events.append(.remoteScoreRevisionRecorded(try remoteFixtureScore(participant: fixtureRemote, day: day)))
        }
        _ = try journal.append(events, expectedCursor: journal.cursor)
        let winner: RemoteParticipant? = fixtureCase.ownerTotal == fixtureCase.remoteTotal ? nil : (fixtureCase.ownerTotal > fixtureCase.remoteTotal ? fixtureOwner : fixtureRemote)
        let hash = try RemoteFinalizationWireV1.resultHash(competitionID: fixtureCompetitionID.rawValue, participantA: fixtureOwner.profileID, totalA: fixtureCase.ownerTotal, commitmentA: ownerWindow.windowCommitment, participantB: fixtureRemote.profileID, totalB: fixtureCase.remoteTotal, commitmentB: remoteWindow.windowCommitment, outcome: winner == nil ? "tie" : "winner", winner: winner?.profileID, basis: fixtureCase.basis.rawValue)
        let result = try SharedCompetitionResult(competitionID: fixtureCompetitionID, owner: fixtureOwner, remote: fixtureRemote, windows: [ownerWindow, remoteWindow], winner: winner, basis: fixtureCase.basis, resultHash: hash, confirmedAt: fixtureDeadline, serverSequence: 99)
        _ = try journal.append([.sharedResultConfirmed(result)], expectedCursor: journal.cursor)
        return journal
    }

    private func remoteFixtureScore(participant: RemoteParticipant, day: SharedResultDay) throws -> RemoteScoreRevision {
        try RemoteScoreRevision(
            competitionID: fixtureCompetitionID,
            participant: participant,
            row: RemoteAcceptedScoreRow(
                ordinal: day.ordinal,
                acceptedCentiPoints: try XCTUnwrap(day.centiPoints),
                availabilityReason: nil,
                wireContentSHA256: try XCTUnwrap(day.wireContentSHA256),
                clientRevision: try XCTUnwrap(day.clientRevision),
                serverSequence: try XCTUnwrap(day.serverSequence)
            ),
            recordedAt: fixtureDeadline.addingTimeInterval(Double(try XCTUnwrap(day.serverSequence)))
        )
    }

    private func remoteFixtureDays(participant: RemoteParticipant, base: Int, missingOrdinal: Int?) throws -> [SharedResultDay] {
        try (1...7).map { ordinal in
            if ordinal == missingOrdinal {
                return try SharedResultDay(ordinal: ordinal, status: .unavailable, source: .deadlineMissing, centiPoints: nil, reason: "missing", wireContentSHA256: nil, clientRevision: nil, serverSequence: nil, scoringPolicyIdentity: nil)
            }
            let sequence = Int64(ordinal + (participant == fixtureRemote ? 100 : 0))
            return try SharedResultDay(ordinal: ordinal, status: .points, source: .acceptedRevision, centiPoints: base + ordinal, reason: nil, wireContentSHA256: String(format: "%064x", base + ordinal), clientRevision: Int64(ordinal), serverSequence: sequence, scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity)
        }
    }

    private func remoteFixtureWindow(participant: RemoteParticipant, days: [SharedResultDay]) throws -> SharedParticipantWindow {
        let finalDays = try days.map { try RemoteFinalizationDayV1(ordinal: $0.ordinal, status: $0.status == .points ? .points : .unavailable, source: $0.source == .acceptedRevision ? .acceptedRevision : .deadlineMissing, points: $0.centiPoints, reason: $0.reason, wireContentSHA256: $0.wireContentSHA256, clientRevision: $0.clientRevision, serverSequence: $0.serverSequence) }
        return try SharedParticipantWindow(competitionID: fixtureCompetitionID, participant: participant, totalCentiPoints: days.compactMap(\.centiPoints).reduce(0, +), windowCommitment: RemoteFinalizationWireV1.windowCommitment(competitionID: fixtureCompetitionID.rawValue, participantID: participant.profileID, days: finalDays), days: days)
    }

    private func remoteFixtureURL(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HealthCompTests/Fixtures", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension("json")
    }

    private func encodedRemoteFixture(_ fixture: RemoteCompetitionGoldenTrace) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(fixture) + Data([0x0A])
    }

    private func fixtureSnapshot() throws -> ActivitySnapshot {
        ActivitySnapshot(moveMode: .activeEnergyKilocalories, standMode: .standHours, move: try ActivityRingReading(value: 1, goal: 1), exercise: try ActivityRingReading(value: 1, goal: 1), standOrRoll: try ActivityRingReading(value: 1, goal: 1), pauseState: .running)
    }

    private func fixtureFinalReadEvidence() throws -> FinalReadEvidence {
        try FinalReadEvidence(attemptID: "remote-final-read", readAt: fixtureDeadline, monotonicInstant: MonotonicInstant(epochID: "remote", nanoseconds: 1), evaluableOrdinals: [], acceptedScoreOrdinals: [], missingOrdinals: Set(1...7), unavailableOrdinals: [], completeWindowContent: nil, opponentPlanIsFinal: false)
    }

    private func fixtureAuthorization() throws -> FinalizationAuthorization {
        FinalizationAuthorization(competitionID: fixtureCompetitionID, reconciliationRevision: 0, eligibleAttemptID: "remote", snapshot: try FinalScoreSnapshot(userPoints: 0, opponentPoints: 0), basis: .bestAvailable, policy: FinalizationPolicy(minimumStabilityNanoseconds: 0, bestAvailableDeadline: fixtureDeadline), decisionAt: fixtureDeadline)
    }
}

private struct RemoteFixtureCase {
    let name: String
    let ownerBase: Int
    let remoteBase: Int
    let basis: RemoteFinalizationBasis
    let ownerMissingOrdinal: Int?
    let cachedRemoteOrdinals: [Int]
    let expectedOutcome: CompetitionOutcome

    var ownerTotal: Int {
        (1...7)
            .filter { $0 != ownerMissingOrdinal }
            .map { ownerBase + $0 }
            .reduce(0, +)
    }

    var remoteTotal: Int {
        (1...7).map { remoteBase + $0 }.reduce(0, +)
    }
}

private struct RemoteCompetitionGoldenTrace: Codable, Equatable {
    let schema: String
    let scenario: String
    let payloadVersion: UInt32
    let semanticEventIDs: [String]
    let terminal: CompetitionSemanticTerminalProjection
}
