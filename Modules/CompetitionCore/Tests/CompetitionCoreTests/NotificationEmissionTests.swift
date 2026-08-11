import Foundation
import XCTest

@testable import CompetitionCore

final class NotificationEmissionTests: XCTestCase {
    func testPayloadVersionFourIsCurrentAndLegacyV3IsSupported() throws {
        XCTAssertEqual(CompetitionJournalEnvelope.currentPayloadVersion, 4)

        let competitionID = CompetitionID(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let envelope = CompetitionJournalEnvelope(
            payloadVersion: 3,
            commitRevision: 1,
            sequence: 1,
            streamID: competitionID,
            semanticEventID: "test-event",
            payload: Data("{}".utf8),
            previousEnvelopeSHA256: String(repeating: "0", count: 64)
        )

        let encoded = try pinnedEncoder().encode(envelope)
        let decoded = try pinnedDecoder().decode(
            CompetitionJournalEnvelope.self,
            from: encoded
        )

        XCTAssertEqual(decoded.payloadVersion, 3)
    }

    func testEmissionRecordUsesDeterministicValidatedSemanticIdentity() throws {
        let competitionID = CompetitionID(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let record = try NotificationEmissionRecorded(
            competitionID: competitionID,
            family: .leadChange,
            episodeKey: .leader(dayOrdinal: 7, leader: .owner),
            disposition: .emitted,
            decidedAt: Date(timeIntervalSinceReferenceDate: 123_456),
            basisPublicationRevision: 42
        )

        XCTAssertEqual(
            record.semanticEventID,
            "competition-notification:v1:11111111-2222-3333-4444-555555555555:lead-change:day:7:leader:owner"
        )
        XCTAssertEqual(record.episodeKey.dayOrdinal, 7)

        let encoded = try pinnedEncoder().encode(record)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            [
                "semanticEventID",
                "competitionID",
                "family",
                "episodeKey",
                "disposition",
                "decidedAt",
                "basisPublicationRevision",
            ]
        )
        XCTAssertEqual(object["episodeKey"] as? String, "day:7:leader:owner")
        XCTAssertEqual(
            try pinnedDecoder().decode(
                NotificationEmissionRecorded.self,
                from: encoded
            ),
            record
        )

        var forged = object
        forged["semanticEventID"] = "competition-notification:v1:forged"
        XCTAssertThrowsError(
            try pinnedDecoder().decode(
                NotificationEmissionRecorded.self,
                from: JSONSerialization.data(withJSONObject: forged)
            )
        ) { error in
            XCTAssertEqual(
                error as? NotificationEmissionRecorded.ValidationError,
                .semanticIDMismatch(
                    expected: record.semanticEventID,
                    actual: "competition-notification:v1:forged"
                )
            )
        }
    }

    func testEmissionRecordRejectsInvalidOrMismatchedTypedEpisodes() throws {
        let competitionID = CompetitionID(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let decidedAt = Date(timeIntervalSinceReferenceDate: 123_456)

        XCTAssertThrowsError(
            try NotificationEmissionRecorded(
                competitionID: competitionID,
                family: .dailyMaximum,
                episodeKey: .day(0),
                disposition: .emitted,
                decidedAt: decidedAt,
                basisPublicationRevision: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? NotificationEmissionRecorded.ValidationError,
                .invalidDayOrdinal(0)
            )
        }
        XCTAssertThrowsError(
            try NotificationEmissionRecorded(
                competitionID: competitionID,
                family: .result,
                episodeKey: .day(7),
                disposition: .suppressed(reason: .superseded),
                decidedAt: decidedAt,
                basisPublicationRevision: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? NotificationEmissionRecorded.ValidationError,
                .episodeDoesNotMatchFamily
            )
        }
    }

    func testV3EmissionEventsFoldOnlyIntoNotificationProjection() throws {
        var journal = try CompetitionJournal(genesis: makeGenesis())
        let before = try CompetitionReplayer.replay(journal)
        let emitted = try makeRecord(
            family: .leadChange,
            episodeKey: .leader(dayOrdinal: 1, leader: .owner),
            disposition: .emitted,
            revision: 4
        )
        let suppressed = try makeRecord(
            family: .closeScore,
            episodeKey: .day(1),
            disposition: .suppressed(reason: .budgetExceeded),
            revision: 4
        )

        let append = try journal.append(
            [
                .notificationEmissionRecorded(emitted),
                .notificationEmissionRecorded(suppressed),
            ],
            expectedCursor: journal.cursor
        )
        let roundTripped = try pinnedDecoder().decode(
            CompetitionJournal.self,
            from: pinnedEncoder().encode(journal)
        )
        let after = try CompetitionReplayer.replay(roundTripped)

        XCTAssertEqual(append.appendedCount, 2)
        XCTAssertEqual(journal.envelopes.map(\.payloadVersion), [4, 4])
        XCTAssertEqual(after.competition, before.competition)
        XCTAssertEqual(after.scoreLedger, before.scoreLedger)
        XCTAssertEqual(after.activityRefresh, before.activityRefresh)
        XCTAssertEqual(
            after.notificationEmissions.recordedIDs,
            [emitted.semanticEventID, suppressed.semanticEventID]
        )
        XCTAssertEqual(after.notificationEmissions.emittedCountByDayOrdinal, [1: 1])

        for envelope in journal.envelopes {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: envelope.payload)
                    as? [String: Any]
            )
            XCTAssertEqual(Set(object.keys), ["notificationEmissionRecorded"])
        }
    }

    func testEmissionDuplicateIsByteAndCursorStableAndDivergenceConflicts() throws {
        var journal = try CompetitionJournal(genesis: makeGenesis())
        let staleCursor = journal.cursor
        let emitted = try makeRecord(
            family: .dailyMaximum,
            episodeKey: .day(3),
            disposition: .emitted,
            revision: 9
        )
        _ = try journal.append(
            [.notificationEmissionRecorded(emitted)],
            expectedCursor: journal.cursor
        )
        let bytes = try pinnedEncoder().encode(journal)
        let cursor = journal.cursor

        let duplicate = try journal.append(
            [.notificationEmissionRecorded(emitted)],
            expectedCursor: staleCursor
        )

        XCTAssertEqual(duplicate.appendedCount, 0)
        XCTAssertEqual(duplicate.cursor, cursor)
        XCTAssertEqual(try pinnedEncoder().encode(journal), bytes)

        let divergent = try makeRecord(
            family: .dailyMaximum,
            episodeKey: .day(3),
            disposition: .suppressed(reason: .superseded),
            revision: 10
        )
        XCTAssertThrowsError(
            try journal.append(
                [.notificationEmissionRecorded(divergent)],
                expectedCursor: journal.cursor
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .semanticEventConflict(eventID: emitted.semanticEventID)
            )
        }
        XCTAssertEqual(try pinnedEncoder().encode(journal), bytes)
    }

    func testPayloadV1AndV2RejectNotificationUnionKeyAsInvalidTransition() throws {
        let genesis = try makeGenesis()
        let record = try makeRecord(
            family: .result,
            episodeKey: .result,
            disposition: .emitted,
            revision: 12
        )
        let payload = try pinnedEncoder().encode(
            CompetitionDomainEvent.notificationEmissionRecorded(record)
        )

        for payloadVersion in [UInt32(1), UInt32(2)] {
            let envelope = CompetitionJournalEnvelope(
                payloadVersion: payloadVersion,
                commitRevision: 1,
                sequence: 1,
                streamID: competitionID,
                semanticEventID: record.semanticEventID,
                payload: payload,
                previousEnvelopeSHA256: try CompetitionJournal(
                    genesis: genesis
                ).genesisDigest
            )

            XCTAssertThrowsError(
                try CompetitionJournal(
                    validating: genesis,
                    envelopes: [envelope]
                )
            ) { error in
                XCTAssertEqual(
                    error as? CompetitionJournalError,
                    .invalidDomainTransition(sequence: 1),
                    "payload version \(payloadVersion)"
                )
            }
        }
    }

    func testFrozenV2DecoderRecognizesAllThreeLegacyUnionKeys() throws {
        let genesis = try makeGenesis(expiresAt: nil)
        let empty = try CompetitionJournal(genesis: genesis)
        let acceptance = try acceptanceEvent(in: genesis)
        let acceptanceEnvelope = CompetitionJournalEnvelope(
            payloadVersion: 2,
            commitRevision: 1,
            sequence: 1,
            streamID: competitionID,
            semanticEventID: acceptance.id,
            payload: try pinnedEncoder().encode(
                FrozenDomainEventV2.lifecycle(acceptance)
            ),
            previousEnvelopeSHA256: empty.genesisDigest
        )
        let refresh = try refreshAttemptForUnionKey()
        let refreshEnvelope = CompetitionJournalEnvelope(
            payloadVersion: 2,
            commitRevision: 2,
            sequence: 2,
            streamID: competitionID,
            semanticEventID: refresh.semanticEventID,
            payload: try pinnedEncoder().encode(
                FrozenDomainEventV2.activityRefreshAttemptRecorded(refresh)
            ),
            previousEnvelopeSHA256: acceptanceEnvelope.envelopeSHA256
        )

        let refreshJournal = try CompetitionJournal(
            validating: genesis,
            envelopes: [acceptanceEnvelope, refreshEnvelope]
        )
        XCTAssertEqual(
            try CompetitionReplayer.replay(refreshJournal)
                .activityRefresh.latestAttempt,
            refresh
        )

        let snapshot = try ActivitySnapshotRecorded(
            observationID: "v2-union-key-snapshot",
            competitionID: competitionID,
            observedAt: date(2026, 8, 10, 12),
            dayOrdinal: 1,
            snapshot: try activitySnapshot(points: 100)
        )
        let snapshotEnvelope = CompetitionJournalEnvelope(
            payloadVersion: 2,
            commitRevision: 2,
            sequence: 2,
            streamID: competitionID,
            semanticEventID: snapshot.semanticEventID,
            payload: try pinnedEncoder().encode(
                FrozenDomainEventV2.activitySnapshotRecorded(snapshot)
            ),
            previousEnvelopeSHA256: acceptanceEnvelope.envelopeSHA256
        )
        XCTAssertThrowsError(
            try CompetitionJournal(
                validating: genesis,
                envelopes: [acceptanceEnvelope, snapshotEnvelope]
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .standaloneActivitySnapshotRequiresPayloadV1(sequence: 2)
            )
        }
    }

    func testMixedPayloadV1V2V3JournalReplaysWithoutReencodingHistory() throws {
        let genesis = try makeGenesis(expiresAt: nil)
        let acceptance = try acceptanceEvent(in: genesis)
        var acceptedCompetition = genesis.makeCompetition()
        try CompetitionEngine().apply(acceptance, to: &acceptedCompetition)
        let started = try XCTUnwrap(
            CompetitionEngine().observeClock(
                acceptedCompetition,
                at: date(2026, 8, 10, 0)
            ).first
        )
        let record = try makeRecord(
            family: .leadChange,
            episodeKey: .leader(dayOrdinal: 1, leader: .opponent),
            disposition: .emitted,
            revision: 3
        )
        let empty = try CompetitionJournal(genesis: genesis)
        let v1Payload = try pinnedEncoder().encode(
            FrozenDomainEventV1.lifecycle(acceptance)
        )
        let v1Envelope = CompetitionJournalEnvelope(
            payloadVersion: 1,
            commitRevision: 1,
            sequence: 1,
            streamID: competitionID,
            semanticEventID: acceptance.id,
            payload: v1Payload,
            previousEnvelopeSHA256: empty.genesisDigest
        )
        let v2Payload = try pinnedEncoder().encode(
            FrozenDomainEventV2.lifecycle(started)
        )
        let v2Envelope = CompetitionJournalEnvelope(
            payloadVersion: 2,
            commitRevision: 2,
            sequence: 2,
            streamID: competitionID,
            semanticEventID: started.id,
            payload: v2Payload,
            previousEnvelopeSHA256: v1Envelope.envelopeSHA256
        )
        let v3Payload = try pinnedEncoder().encode(
            CompetitionDomainEvent.notificationEmissionRecorded(record)
        )
        let v3Envelope = CompetitionJournalEnvelope(
            payloadVersion: 3,
            commitRevision: 3,
            sequence: 3,
            streamID: competitionID,
            semanticEventID: record.semanticEventID,
            payload: v3Payload,
            previousEnvelopeSHA256: v2Envelope.envelopeSHA256
        )

        let journal = try CompetitionJournal(
            validating: genesis,
            envelopes: [v1Envelope, v2Envelope, v3Envelope]
        )
        let replay = try CompetitionReplayer.replay(journal)

        XCTAssertEqual(journal.envelopes.map(\.payloadVersion), [1, 2, 3])
        XCTAssertEqual(
            journal.envelopes.map(\.payload),
            [v1Payload, v2Payload, v3Payload]
        )
        XCTAssertEqual(
            replay.competition.lifecycle,
            .active(day: try CompetitionActiveDay(1))
        )
        XCTAssertEqual(replay.notificationEmissions.recordedIDs, [record.semanticEventID])
    }

    func testPayloadVersionCannotDowngradeFromV3ToV2() throws {
        let genesis = try makeGenesis()
        let record = try makeRecord(
            family: .catchUp,
            episodeKey: .tallying,
            disposition: .suppressed(reason: .staleEpisode),
            revision: 7
        )
        let empty = try CompetitionJournal(genesis: genesis)
        let v3Payload = try pinnedEncoder().encode(
            CompetitionDomainEvent.notificationEmissionRecorded(record)
        )
        let v3Envelope = CompetitionJournalEnvelope(
            payloadVersion: 3,
            commitRevision: 1,
            sequence: 1,
            streamID: competitionID,
            semanticEventID: record.semanticEventID,
            payload: v3Payload,
            previousEnvelopeSHA256: empty.genesisDigest
        )
        let declined = CompetitionEvent(
            competitionID: competitionID,
            occurredAt: date(2026, 8, 9, 11),
            kind: .invitationDeclined
        )
        let v2Envelope = CompetitionJournalEnvelope(
            payloadVersion: 2,
            commitRevision: 2,
            sequence: 2,
            streamID: competitionID,
            semanticEventID: declined.id,
            payload: try pinnedEncoder().encode(
                FrozenDomainEventV2.lifecycle(declined)
            ),
            previousEnvelopeSHA256: v3Envelope.envelopeSHA256
        )

        XCTAssertThrowsError(
            try CompetitionJournal(
                validating: genesis,
                envelopes: [v3Envelope, v2Envelope]
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .payloadVersionDowngrade(sequence: 2)
            )
        }
    }

    func testFrozenV2AndLiveV3TopLevelUnionKeysAreExact() throws {
        let lifecycle = CompetitionEvent(
            competitionID: competitionID,
            occurredAt: date(2026, 8, 9, 11),
            kind: .invitationDeclined
        )
        let snapshot = try ActivitySnapshotRecorded(
            observationID: "union-key-snapshot",
            competitionID: competitionID,
            observedAt: date(2026, 8, 10, 12),
            dayOrdinal: 1,
            snapshot: try activitySnapshot(points: 100)
        )
        let refresh = try refreshAttemptForUnionKey()
        let notification = try makeRecord(
            family: .result,
            episodeKey: .result,
            disposition: .emitted,
            revision: 11
        )

        let v2Keys = try Set(
            [
                FrozenDomainEventV2.lifecycle(lifecycle),
                .activitySnapshotRecorded(snapshot),
                .activityRefreshAttemptRecorded(refresh),
            ].map(topLevelKey)
        )
        let v3Keys = try Set(
            [
                CompetitionDomainEvent.lifecycle(lifecycle),
                .activitySnapshotRecorded(snapshot),
                .activityRefreshAttemptRecorded(refresh),
                .notificationEmissionRecorded(notification),
            ].map(topLevelKey)
        )

        XCTAssertEqual(
            v2Keys,
            [
                "lifecycle",
                "activitySnapshotRecorded",
                "activityRefreshAttemptRecorded",
            ]
        )
        XCTAssertEqual(
            v3Keys,
            [
                "lifecycle",
                "activitySnapshotRecorded",
                "activityRefreshAttemptRecorded",
                "notificationEmissionRecorded",
            ]
        )
    }

    func testNotificationVocabularyAndV3PayloadDigestArePinned() throws {
        XCTAssertEqual(
            Set(NotificationEmissionFamily.allCases.map(\.rawValue)),
            ["lead-change", "close-score", "daily-max", "result", "catch-up"]
        )
        XCTAssertEqual(
            Set(NotificationSuppressionReason.allCases.map(\.rawValue)),
            ["superseded", "staleEpisode", "budgetExceeded"]
        )
        XCTAssertEqual(
            Set(NotificationEmissionLeader.allCases.map(\.rawValue)),
            ["owner", "opponent"]
        )

        var journal = try CompetitionJournal(genesis: makeGenesis())
        let record = try makeRecord(
            family: .leadChange,
            episodeKey: .leader(dayOrdinal: 7, leader: .owner),
            disposition: .emitted,
            revision: 42
        )
        _ = try journal.append(
            [.notificationEmissionRecorded(record)],
            expectedCursor: journal.cursor
        )
        let envelope = try XCTUnwrap(journal.envelopes.first)

        XCTAssertEqual(envelope.payloadVersion, 4)
        XCTAssertEqual(
            envelope.payloadSHA256,
            "8d9fd2c4818c1c0fb7ec2c88b884b3b8d87c22c141c25b92a0cf9b9ee3556c38"
        )
    }

    private func pinnedEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func pinnedDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    private func topLevelKey<T: Encodable>(_ value: T) throws -> String {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: pinnedEncoder().encode(value))
                as? [String: Any]
        )
        XCTAssertEqual(object.keys.count, 1)
        return try XCTUnwrap(object.keys.first)
    }

    private func makeGenesis(
        expiresAt: Date? = nil
    ) throws -> CompetitionGenesis {
        try CompetitionGenesis(
            competitionID: competitionID,
            direction: .incoming,
            createdAt: date(2026, 8, 9, 10),
            expiresAt: expiresAt,
            scoringPolicy: .appleCompatibility,
            downwardRevisionPolicy: .maximumObserved
        )
    }

    private func acceptanceEvent(
        in genesis: CompetitionGenesis
    ) throws -> CompetitionEvent {
        try CompetitionEngine().accept(
            genesis.makeCompetition(),
            at: date(2026, 8, 9, 11),
            timeZoneIdentifier: "America/Los_Angeles",
            opponent: OpponentPlanGenerationRequest(
                seed: 42,
                generatorVersion: .v1,
                difficulty: .balanced
            )
        )
    }

    private func refreshAttemptForUnionKey() throws -> ActivityRefreshAttemptRecorded {
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let days = try calendar.sevenDayWindow(
            startingOn: calendar.day(containing: date(2026, 8, 10, 0))
        )
        return try ActivityRefreshAttemptRecorded(
            attemptID: "union-key-refresh",
            competitionID: competitionID,
            attemptOrdinal: 1,
            trigger: .launch,
            attemptedAt: date(2026, 8, 9, 12),
            readAt: date(2026, 8, 9, 12),
            monotonicInstant: MonotonicInstant(
                epochID: "union-key",
                nanoseconds: 1
            ),
            readStatus: .completed,
            days: zip(1...7, days).map { ordinal, day in
                ActivityDayObservation(
                    day: day,
                    ordinal: ordinal,
                    availability: .notYetOccurred
                )
            }
        )
    }

    private func activitySnapshot(points: Double) throws -> ActivitySnapshot {
        ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(value: points / 100, goal: 1),
            exercise: try ActivityRingReading(value: 0, goal: 1),
            standOrRoll: try ActivityRingReading(value: 0, goal: 1),
            pauseState: .running
        )
    }

    private func makeRecord(
        family: NotificationEmissionFamily,
        episodeKey: NotificationEpisodeKey,
        disposition: NotificationEmissionDisposition,
        revision: UInt64
    ) throws -> NotificationEmissionRecorded {
        try NotificationEmissionRecorded(
            competitionID: competitionID,
            family: family,
            episodeKey: episodeKey,
            disposition: disposition,
            decidedAt: date(2026, 8, 10, 12),
            basisPublicationRevision: revision
        )
    }

    private var competitionID: CompetitionID {
        CompetitionID(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int
    ) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "America/Los_Angeles")
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return components.date!
    }
}

private enum FrozenDomainEventV1: Codable {
    case lifecycle(CompetitionEvent)
}

private enum FrozenDomainEventV2: Codable {
    case lifecycle(CompetitionEvent)
    case activitySnapshotRecorded(ActivitySnapshotRecorded)
    case activityRefreshAttemptRecorded(ActivityRefreshAttemptRecorded)
}
