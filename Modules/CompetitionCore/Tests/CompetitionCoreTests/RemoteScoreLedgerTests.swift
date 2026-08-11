import Foundation
import XCTest
@testable import CompetitionCore

final class RemoteScoreLedgerTests: XCTestCase {
    func testRemoteParticipantCarriesOnlyStableProfileIDAndCounterpartyRoundTrips() throws {
        let participant = try RemoteParticipant(profileID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        XCTAssertEqual(try JSONDecoder().decode(RemoteParticipant.self, from: JSONEncoder().encode(participant)), participant)
        let counterparty: CompetitionCounterparty = .remote(participant)
        XCTAssertEqual(try JSONDecoder().decode(CompetitionCounterparty.self, from: JSONEncoder().encode(counterparty)), counterparty)
        XCTAssertFalse(String(data: try JSONEncoder().encode(participant), encoding: .utf8)!.contains("display"))
    }

    func testAcceptsServerRowsMonotonicallyAndMakesExactDuplicateANoOp() throws {
        var ledger = try fixtureLedger()
        let first = try row(ordinal: 1, points: 12_345, revision: 1, sequence: 2)
        XCTAssertTrue(try ledger.accept(first))
        XCTAssertFalse(try ledger.accept(first))
        XCTAssertEqual(try ledger.visibleEntry(forActiveDayOrdinal: 1), first)
        XCTAssertThrowsError(try ledger.accept(try row(ordinal: 2, points: 1, revision: 1, sequence: 3)))
        XCTAssertThrowsError(try ledger.accept(try row(ordinal: 1, points: 12_346, revision: 1, sequence: 2)))
        let revision = try row(ordinal: 1, points: 12_346, revision: 2, sequence: 4)
        XCTAssertTrue(try ledger.accept(revision))
        XCTAssertEqual(try ledger.visibleEntry(forActiveDayOrdinal: 1), revision)
    }

    func testRejectsInvalidAcceptedRowsAndSupportsClosedUnavailableEvidence() throws {
        var ledger = try fixtureLedger()
        XCTAssertThrowsError(try RemoteAcceptedScoreRow(ordinal: 0, acceptedCentiPoints: 0, availabilityReason: nil, wireContentSHA256: digest("a"), clientRevision: 1, serverSequence: 1))
        XCTAssertThrowsError(try RemoteAcceptedScoreRow(ordinal: 1, acceptedCentiPoints: 60_001, availabilityReason: nil, wireContentSHA256: digest("a"), clientRevision: 1, serverSequence: 1))
        XCTAssertThrowsError(try RemoteAcceptedScoreRow(ordinal: 1, acceptedCentiPoints: nil, availabilityReason: "invented", wireContentSHA256: digest("a"), clientRevision: 1, serverSequence: 1))
        XCTAssertThrowsError(try RemoteAcceptedScoreRow(ordinal: 1, acceptedCentiPoints: 1, availabilityReason: nil, wireContentSHA256: String(repeating: "A", count: 64), clientRevision: 1, serverSequence: 1))
        let unavailable = try row(ordinal: 3, points: nil, reason: "sourceDataUnavailable", revision: 1, sequence: 1)
        XCTAssertTrue(try ledger.accept(unavailable))
        XCTAssertEqual(try ledger.visibleEntry(forActiveDayOrdinal: 3), unavailable)
    }

    func testFrozenWindowCommitmentIsSensitiveToAcceptedEvidenceAndIdentity() throws {
        let participantA = try RemoteParticipant(profileID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let participantB = try RemoteParticipant(profileID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        let competitionA = CompetitionID(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!)
        let competitionB = CompetitionID(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!)
        let accepted = try row(ordinal: 1, points: 10, revision: 1, sequence: 1)
        let changedPoints = try row(ordinal: 1, points: 11, revision: 1, sequence: 1)
        let changedAvailability = try row(ordinal: 1, points: nil, reason: "sourceDataUnavailable", revision: 1, sequence: 1)
        let changedDigest = try row(ordinal: 1, points: 10, revision: 1, sequence: 1, digestCharacter: "b")
        let changedSequence = try row(ordinal: 1, points: 10, revision: 1, sequence: 2)

        let base = try RemoteScoreLedger(competitionID: competitionA, participant: participantA, acceptedSchedule: fixtureSchedule(), acceptedRows: completeRows(first: accepted))
        let variants = [
            try RemoteScoreLedger(competitionID: competitionA, participant: participantA, acceptedSchedule: fixtureSchedule(), acceptedRows: completeRows(first: changedPoints)),
            try RemoteScoreLedger(competitionID: competitionA, participant: participantA, acceptedSchedule: fixtureSchedule(), acceptedRows: completeRows(first: changedAvailability)),
            try RemoteScoreLedger(competitionID: competitionA, participant: participantA, acceptedSchedule: fixtureSchedule(), acceptedRows: completeRows(first: changedDigest)),
            try RemoteScoreLedger(competitionID: competitionA, participant: participantA, acceptedSchedule: fixtureSchedule(), acceptedRows: completeRows(first: changedSequence)),
            try RemoteScoreLedger(competitionID: competitionA, participant: participantB, acceptedSchedule: fixtureSchedule(), acceptedRows: completeRows(first: accepted)),
            try RemoteScoreLedger(competitionID: competitionB, participant: participantA, acceptedSchedule: fixtureSchedule(), acceptedRows: completeRows(first: accepted)),
        ]
        let commitment = try base.windowCommitment()
        XCTAssertTrue(try variants.allSatisfy { try $0.windowCommitment() != commitment })
        XCTAssertEqual(try base.frozenWindow().count, 7)
        XCTAssertEqual(try base.visibleEntry(forActiveDayOrdinal: 2)?.ordinal, 2)
        XCTAssertThrowsError(try base.visibleEntry(forActiveDayOrdinal: 8))
    }

    func testFrozenWindowRequiresServerAcceptedEvidenceForEveryOrdinal() throws {
        var ledger = try fixtureLedger()
        XCTAssertThrowsError(try ledger.frozenWindow())
        for ordinal in 1...6 { XCTAssertTrue(try ledger.accept(try row(ordinal: ordinal, points: ordinal, revision: Int64(ordinal), sequence: Int64(ordinal)))) }
        XCTAssertThrowsError(try ledger.frozenWindow())
        XCTAssertTrue(try ledger.accept(try row(ordinal: 7, points: 60_000, revision: 7, sequence: 7)))
        XCTAssertEqual(try ledger.frozenWindow().count, 7)
    }

    func testVisibleEntryReturnsOnlyTheRequestedOrdinalAndAcceptedHistoryRejectsReplays() throws {
        var ledger = try fixtureLedger()
        let dayOne = try row(ordinal: 1, points: 0, revision: 1, sequence: 10)
        let dayTwo = try row(ordinal: 2, points: 60_000, revision: 2, sequence: 20)
        let dayOneRevision = try row(ordinal: 1, points: 1, revision: 3, sequence: 30)
        XCTAssertTrue(try ledger.accept(dayOne))
        XCTAssertTrue(try ledger.accept(dayTwo))
        XCTAssertTrue(try ledger.accept(dayOneRevision))
        XCTAssertEqual(try ledger.visibleEntry(forActiveDayOrdinal: 1), dayOneRevision)
        XCTAssertEqual(try ledger.visibleEntry(forActiveDayOrdinal: 2), dayTwo)
        XCTAssertNotEqual(try ledger.visibleEntry(forActiveDayOrdinal: 1), dayTwo)
        XCTAssertFalse(try ledger.accept(dayOne))
        XCTAssertThrowsError(try ledger.accept(try row(ordinal: 3, points: 1, revision: 4, sequence: 20)))
        XCTAssertThrowsError(try ledger.accept(try row(ordinal: 3, points: 1, revision: 2, sequence: 40)))
    }

    func testCodableRoundTripDoesNotEncodePrivateHealthOrDisplayData() throws {
        let ledger = try RemoteScoreLedger(competitionID: CompetitionID(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!), participant: try RemoteParticipant(profileID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!), acceptedSchedule: fixtureSchedule(), acceptedRows: [try row(ordinal: 1, points: 1, revision: 1, sequence: 1)])
        let encoded = try JSONEncoder().encode(ledger)
        XCTAssertEqual(try JSONDecoder().decode(RemoteScoreLedger.self, from: encoded), ledger)
        let json = String(data: encoded, encoding: .utf8)!
        for prohibited in ["fingerprint", "display", "moveBasis", "exerciseBasis", "standBasis"] { XCTAssertFalse(json.localizedCaseInsensitiveContains(prohibited)) }
    }

    func testSimulatedCounterpartyRoundTrips() throws {
        let schedule = try fixtureSchedule()
        let plan = try OpponentPlanGenerator.generate(
            seed: 9,
            generatorVersion: .v1,
            difficulty: .balanced,
            schedule: schedule
        )
        let counterparty: CompetitionCounterparty = .simulated(plan)
        XCTAssertEqual(try JSONDecoder().decode(CompetitionCounterparty.self, from: JSONEncoder().encode(counterparty)), counterparty)
    }

    func testLedgerRejectsScheduleWhoseStartDayIsOutsideItsCalendarAndPoisonedDecode() throws {
        let invalidSchedule = CompetitionSchedule(
            calendar: try CompetitionCalendar(timeZoneIdentifier: "America/Los_Angeles"),
            startDay: try CompetitionDay(era: 1, year: 2026, month: 8, day: 10, timeZoneIdentifier: "UTC")
        )
        let competitionID = CompetitionID(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!)
        let participant = try RemoteParticipant(profileID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        XCTAssertThrowsError(try RemoteScoreLedger(competitionID: competitionID, participant: participant, acceptedSchedule: invalidSchedule))

        let valid = try RemoteScoreLedger(competitionID: competitionID, participant: participant, acceptedSchedule: fixtureSchedule())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        var schedule = try XCTUnwrap(json["acceptedSchedule"] as? [String: Any])
        var startDay = try XCTUnwrap(schedule["startDay"] as? [String: Any])
        startDay["timeZoneIdentifier"] = "UTC"
        schedule["startDay"] = startDay
        json["acceptedSchedule"] = schedule
        let poisoned = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteScoreLedger.self, from: poisoned))
    }

    private func fixtureLedger() throws -> RemoteScoreLedger {
        try RemoteScoreLedger(competitionID: CompetitionID(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!), participant: try RemoteParticipant(profileID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!), acceptedSchedule: fixtureSchedule())
    }

    private func fixtureSchedule() throws -> CompetitionSchedule {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "America/Los_Angeles")
        return CompetitionSchedule(calendar: calendar, startDay: try CompetitionDay(era: 1, year: 2026, month: 8, day: 10, timeZoneIdentifier: calendar.timeZoneIdentifier))
    }

    private func row(ordinal: Int, points: Int?, reason: String? = nil, revision: Int64, sequence: Int64, digestCharacter: Character = "a") throws -> RemoteAcceptedScoreRow {
        try RemoteAcceptedScoreRow(ordinal: ordinal, acceptedCentiPoints: points, availabilityReason: reason, wireContentSHA256: digest(digestCharacter), clientRevision: revision, serverSequence: sequence)
    }

    private func completeRows(first: RemoteAcceptedScoreRow) throws -> [RemoteAcceptedScoreRow] {
        [first] + (try (2...7).map { ordinal in
            try row(ordinal: ordinal, points: ordinal, revision: Int64(ordinal), sequence: Int64(ordinal + 100))
        })
    }

    private func digest(_ character: Character) -> String { String(repeating: String(character), count: 64) }
}
