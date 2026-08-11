import Foundation
import XCTest
@testable import CompetitionCore

final class RemoteScoringGoldenTests: XCTestCase {
    struct Fixture: Decodable {
        enum Value: Decodable {
            case integer(Int)
            case string(String)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let integer = try? container.decode(Int.self) { self = .integer(integer); return }
                self = .string(try container.decode(String.self))
            }
        }
        struct Vector: Decodable {
            let kind:String; let name:String; let input:String?; let basis_points:Int?
            let field:String?; let value:Value?
            let competition_id:UUID?; let participant_id:UUID?; let day_ordinal:Int?; let client_revision:String?
            let move_mode:String?; let stand_mode:String?; let move_basis_points:Int?; let exercise_basis_points:Int?; let stand_basis_points:Int?
            let availability_reason:String?; let accepted_centi_points:Int?; let canonical_hex:String?; let sha256:String?
        }
        let version:Int; let policy_identity:String; let wire_digest_version:Int; let vectors:[Vector]
    }
    func testFrozenFixtureSchemaDecimalHalfEvenAndInvalidInputs() throws {
        let f=try fixture(); XCTAssertEqual(f.version,1);XCTAssertEqual(f.policy_identity,RemoteScoringWireV1.policyIdentity);XCTAssertEqual(f.wire_digest_version,1)
        for v in f.vectors where v.kind=="quantization" { XCTAssertEqual(try RemoteScoringWireV1.quantizePercent(Double(v.input!)!),v.basis_points) }
        for v in f.vectors where v.kind=="invalid_decimal" { XCTAssertThrowsError(try RemoteScoringWireV1.quantizePercent(Double(v.input!)!)) }
    }
    func testTrustedValuesAtOrAboveCapNeverOverflowDecimalArithmetic() throws {
        XCTAssertEqual(try RemoteScoringWireV1.quantizePercent(1e127), 20_000)
        XCTAssertEqual(try RemoteScoringWireV1.quantizePercent(Double.greatestFiniteMagnitude), 20_000)
    }
    func testCanonicalBytesScoresAndDigestsMatchSoleFixture() throws {
        let f=try fixture(); for v in f.vectors where v.kind=="score" {
            let wire=try RemoteScoreRevisionWireV1(competitionID:v.competition_id!,participantID:v.participant_id!,dayOrdinal:v.day_ordinal!,moveMode:v.move_mode!,standMode:v.stand_mode!,moveBasisPoints:v.move_basis_points,exerciseBasisPoints:v.exercise_basis_points,standBasisPoints:v.stand_basis_points,availabilityReason:v.availability_reason!,scoringPolicyIdentity:f.policy_identity,clientRevision:Int64(v.client_revision!)!)
            XCTAssertEqual(wire.acceptedCentiPoints,v.accepted_centi_points);XCTAssertEqual(wire.canonicalContentHex,try XCTUnwrap(v.canonical_hex));XCTAssertEqual(wire.wireContentSHA256,try XCTUnwrap(v.sha256))
        }
    }
    func testEveryFixtureKindIsAccountedForAndInvalidWireVectorsExecute() throws {
        let f = try fixture()
        let counts = Dictionary(grouping: f.vectors, by: \.kind).mapValues(\.count)
        XCTAssertEqual(counts, ["quantization": 14, "invalid_decimal": 4, "score": 4, "invalid_wire": 3, "privacy": 5, "digest_mutation": 11, "window_commitment": 1, "result_hash": 1])
        for vector in f.vectors where vector.kind == "privacy" {
            guard case .string? = vector.value else { return XCTFail("privacy vector \(vector.name) must carry a string") }
        }
        let base = try XCTUnwrap(f.vectors.first { $0.kind == "score" && $0.name == "move_exercise_stand" })
        for vector in f.vectors where vector.kind == "invalid_wire" {
            switch vector.field {
            case "move_basis_points":
                guard case .integer(let value)? = vector.value else { return XCTFail("integer mutation required") }
                XCTAssertThrowsError(try wire(from: base, policy: f.policy_identity, moveBasisPoints: value))
            case "accepted_centi_points":
                guard case .integer(let value)? = vector.value else { return XCTFail("integer mutation required") }
                XCTAssertNotEqual(try wire(from: base, policy: f.policy_identity).acceptedCentiPoints, value)
            case "policy_identity":
                guard case .string(let value)? = vector.value else { return XCTFail("string mutation required") }
                XCTAssertThrowsError(try wire(from: base, policy: value))
            default: XCTFail("unhandled invalid-wire field \(vector.field ?? "nil")")
            }
        }
    }
    func testEveryDigestFieldMutationChangesSwiftDigest() throws {
        let f = try fixture()
        let base = try XCTUnwrap(f.vectors.first { $0.kind == "score" && $0.name == "move_exercise_stand" })
        let original = try wire(from: base, policy: f.policy_identity)
        for vector in f.vectors where vector.kind == "digest_mutation" {
            let mutated: RemoteScoreRevisionWireV1
            switch vector.field {
            case "competition_id": mutated = try wire(from: base, policy: f.policy_identity, competitionID: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!)
            case "participant_id": mutated = try wire(from: base, policy: f.policy_identity, participantID: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!)
            case "day_ordinal": mutated = try wire(from: base, policy: f.policy_identity, dayOrdinal: 2)
            case "move_mode": mutated = try wire(from: base, policy: f.policy_identity, moveMode: "moveMinutes")
            case "stand_mode": mutated = try wire(from: base, policy: f.policy_identity, standMode: "rollHours")
            case "move_basis_points": mutated = try wire(from: base, policy: f.policy_identity, moveBasisPoints: 10_001)
            case "exercise_basis_points": mutated = try wire(from: base, policy: f.policy_identity, exerciseBasisPoints: 5_001)
            case "stand_basis_points": mutated = try wire(from: base, policy: f.policy_identity, standBasisPoints: 2_501)
            case "availability_reason":
                mutated = try RemoteScoreRevisionWireV1(competitionID: base.competition_id!, participantID: base.participant_id!, dayOrdinal: base.day_ordinal!, moveMode: base.move_mode!, standMode: base.stand_mode!, moveBasisPoints: nil, exerciseBasisPoints: nil, standBasisPoints: nil, availabilityReason: "summaryPaused", scoringPolicyIdentity: f.policy_identity, clientRevision: Int64(base.client_revision!)!)
            case "policy_identity":
                XCTAssertThrowsError(try wire(from: base, policy: "healthcomp.activity-score.v1\u{0}"))
                continue
            case "client_revision": mutated = try wire(from: base, policy: f.policy_identity, clientRevision: 8)
            default: return XCTFail("unhandled digest field \(vector.field ?? "nil")")
            }
            XCTAssertNotEqual(mutated.wireContentSHA256, original.wireContentSHA256, vector.name)
        }
    }
    func testClientValidationExcludesNilIDsUnknownAvailableAndServerMissing() throws {
        let nilID=UUID(uuidString:"00000000-0000-0000-0000-000000000000")!, id=UUID(uuidString:"00000000-0000-0000-0000-000000000001")!
        XCTAssertThrowsError(try score(competition:nilID,participant:id,stand:"standHours",reason:"available"))
        XCTAssertThrowsError(try score(competition:id,participant:id,stand:"unknown",reason:"available"))
        XCTAssertThrowsError(try RemoteScoreRevisionWireV1(competitionID:id,participantID:id,dayOrdinal:1,moveMode:"moveMinutes",standMode:"rollHours",moveBasisPoints:nil,exerciseBasisPoints:nil,standBasisPoints:nil,availabilityReason:"missing",scoringPolicyIdentity:RemoteScoringWireV1.policyIdentity,clientRevision:1))
    }
    func testFinalizationDayRejectsInvalidShapeAndResultHashMutates() throws {
        XCTAssertThrowsError(try RemoteFinalizationDayV1(ordinal:0,status:.points,source:.acceptedRevision,points:1,reason:nil,wireContentSHA256:String(repeating:"0",count:64),clientRevision:1,serverSequence:1))
        XCTAssertThrowsError(try RemoteFinalizationDayV1(ordinal:1,status:.points,source:.acceptedRevision,points:1,reason:nil,wireContentSHA256:"bad",clientRevision:1,serverSequence:1))
        XCTAssertThrowsError(try RemoteFinalizationDayV1(ordinal:1,status:.unavailable,source:.acceptedRevision,points:nil,reason:"invented",wireContentSHA256:String(repeating:"0",count:64),clientRevision:1,serverSequence:1))
        let a=UUID(uuidString:"00000000-0000-0000-0000-000000000001")!,b=UUID(uuidString:"00000000-0000-0000-0000-000000000002")!,c=UUID(uuidString:"00000000-0000-0000-0000-000000000003")!
        let h1=try RemoteFinalizationWireV1.resultHash(competitionID:c,participantA:a,totalA:1,commitmentA:String(repeating:"1",count:64),participantB:b,totalB:2,commitmentB:String(repeating:"2",count:64),outcome:"winner",winner:b,basis:"stable")
        let h2=try RemoteFinalizationWireV1.resultHash(competitionID:c,participantA:a,totalA:2,commitmentA:String(repeating:"1",count:64),participantB:b,totalB:2,commitmentB:String(repeating:"2",count:64),outcome:"tie",winner:nil,basis:"stable")
        XCTAssertNotEqual(h1,h2)
        XCTAssertThrowsError(try RemoteFinalizationWireV1.resultHash(competitionID:c,participantA:a,totalA:1,commitmentA:String(repeating:"1",count:64),participantB:b,totalB:2,commitmentB:String(repeating:"2",count:64),outcome:"tie",winner:nil,basis:"stable"))
        XCTAssertThrowsError(try RemoteFinalizationWireV1.resultHash(competitionID:c,participantA:a,totalA:1,commitmentA:String(repeating:"1",count:64),participantB:b,totalB:2,commitmentB:String(repeating:"2",count:64),outcome:"winner",winner:c,basis:"stable"))
        let zero=UUID(uuidString:"00000000-0000-0000-0000-000000000000")!
        XCTAssertThrowsError(try RemoteFinalizationWireV1.resultHash(competitionID:zero,participantA:a,totalA:1,commitmentA:String(repeating:"1",count:64),participantB:b,totalB:2,commitmentB:String(repeating:"2",count:64),outcome:"winner",winner:b,basis:"stable"))
        XCTAssertThrowsError(try RemoteFinalizationWireV1.resultHash(competitionID:c,participantA:zero,totalA:1,commitmentA:String(repeating:"1",count:64),participantB:b,totalB:2,commitmentB:String(repeating:"2",count:64),outcome:"winner",winner:b,basis:"stable"))
        XCTAssertThrowsError(try RemoteFinalizationWireV1.resultHash(competitionID:c,participantA:a,totalA:1,commitmentA:String(repeating:"1",count:64),participantB:zero,totalB:2,commitmentB:String(repeating:"2",count:64),outcome:"winner",winner:b,basis:"stable"))
        XCTAssertThrowsError(try RemoteFinalizationWireV1.resultHash(competitionID:c,participantA:a,totalA:1,commitmentA:String(repeating:"1",count:64),participantB:b,totalB:2,commitmentB:String(repeating:"2",count:64),outcome:"winner",winner:nil,basis:"stable"))
        XCTAssertThrowsError(try RemoteFinalizationWireV1.resultHash(competitionID:c,participantA:a,totalA:1,commitmentA:String(repeating:"1",count:64),participantB:b,totalB:2,commitmentB:String(repeating:"2",count:64),outcome:"winner",winner:a,basis:"stable"))
        XCTAssertThrowsError(try RemoteFinalizationWireV1.resultHash(competitionID:c,participantA:a,totalA:2,commitmentA:String(repeating:"1",count:64),participantB:b,totalB:2,commitmentB:String(repeating:"2",count:64),outcome:"winner",winner:a,basis:"stable"))
        XCTAssertThrowsError(try RemoteFinalizationWireV1.resultHash(competitionID:c,participantA:b,totalA:2,commitmentA:String(repeating:"2",count:64),participantB:a,totalB:1,commitmentB:String(repeating:"1",count:64),outcome:"winner",winner:b,basis:"stable"))
    }
    func testExactSevenDayCommitmentAndResultHashGolden() throws {
        let f=try fixture(),c=UUID(uuidString:"00000000-0000-0000-0000-000000000001")!,a=UUID(uuidString:"00000000-0000-0000-0000-000000000002")!,b=UUID(uuidString:"00000000-0000-0000-0000-000000000003")!
        let days=try (1...7).map{try RemoteFinalizationDayV1(ordinal:$0,status:.unavailable,source:.deadlineMissing,points:nil,reason:"missing",wireContentSHA256:nil,clientRevision:nil,serverSequence:nil)}
        let commitment=try RemoteFinalizationWireV1.windowCommitment(competitionID:c,participantID:a,days:days)
        XCTAssertEqual(commitment,f.vectors.first{$0.kind=="window_commitment"}!.sha256)
        XCTAssertEqual(try RemoteFinalizationWireV1.resultHash(competitionID:c,participantA:a,totalA:0,commitmentA:commitment,participantB:b,totalB:0,commitmentB:"588ea277c08636f5bbe674af648daeb482219af27bddf0c5eccf0017ee67b3de",outcome:"tie",winner:nil,basis:"best_available"),f.vectors.first{$0.kind=="result_hash"}!.sha256)
    }
    private func score(competition:UUID,participant:UUID,stand:String,reason:String)throws->RemoteScoreRevisionWireV1{try .init(competitionID:competition,participantID:participant,dayOrdinal:1,moveMode:"moveMinutes",standMode:stand,moveBasisPoints:1,exerciseBasisPoints:1,standBasisPoints:1,availabilityReason:reason,scoringPolicyIdentity:RemoteScoringWireV1.policyIdentity,clientRevision:1)}
    private func wire(from v: Fixture.Vector, policy: String, competitionID: UUID? = nil, participantID: UUID? = nil, dayOrdinal: Int? = nil, moveMode: String? = nil, standMode: String? = nil, moveBasisPoints: Int?? = nil, exerciseBasisPoints: Int?? = nil, standBasisPoints: Int?? = nil, availabilityReason: String? = nil, clientRevision: Int64? = nil) throws -> RemoteScoreRevisionWireV1 {
        try RemoteScoreRevisionWireV1(competitionID: competitionID ?? v.competition_id!, participantID: participantID ?? v.participant_id!, dayOrdinal: dayOrdinal ?? v.day_ordinal!, moveMode: moveMode ?? v.move_mode!, standMode: standMode ?? v.stand_mode!, moveBasisPoints: moveBasisPoints ?? v.move_basis_points, exerciseBasisPoints: exerciseBasisPoints ?? v.exercise_basis_points, standBasisPoints: standBasisPoints ?? v.stand_basis_points, availabilityReason: availabilityReason ?? v.availability_reason!, scoringPolicyIdentity: policy, clientRevision: clientRevision ?? Int64(v.client_revision!)!)
    }
    private func fixture() throws->Fixture{let source=URL(fileURLWithPath:#filePath);let root=source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent();return try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:root.appendingPathComponent("supabase/tests/fixtures/scoring-v1.json")))}
}
