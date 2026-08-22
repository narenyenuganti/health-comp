import CryptoKit
import Foundation
import XCTest
@testable import HealthComp

final class AppAttestClientTests: XCTestCase {
    func testClientDataMatchesFrozenCrossLanguageGoldenBytes() throws {
        let encoded = try AppAttestClientDataV1.encode(
            challengeID: challengeID,
            challenge: bytes(from: 0, count: 32),
            profileID: profileID,
            installationID: installationID,
            payloadSHA256: bytes(from: 32, count: 32)
        )

        XCTAssertEqual(
            encoded.hex,
            "6865616c7468636f6d702d6170702d6174746573742d763100" +
                "010000001010000000000040008000000000000001" +
                "0200000020000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" +
                "030000001020000000000040008000000000000002" +
                "040000001030000000000040008000000000000003" +
                "0500000020202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f" +
                "060000000e73636f72655f7265766973696f6e"
        )
    }

    func testChallengeAndProofWireContractsAreExact() throws {
        let request = try CompetitionAppAttestChallengeRequest(
            installationID: installationID,
            payloadSHA256: String(repeating: "a", count: 64),
            keyID: keyA
        )
        let requestData = try CompetitionWireCodec.encode(
            request,
            contract: .appAttestChallengeRequest
        )
        let requestObject = try XCTUnwrap(
            try jsonObject(requestData) as? NSDictionary
        )
        XCTAssertEqual(
            requestObject,
            [
                "installationID": installationID.uuidString.lowercased(),
                "keyID": keyA,
                "payloadSHA256": String(repeating: "a", count: 64),
                "version": 1,
            ] as NSDictionary
        )

        let challengeData = try JSONSerialization.data(withJSONObject: [
            "challenge": bytes(from: 0, count: 32).base64EncodedString(),
            "challengeID": challengeID.uuidString.lowercased(),
            "expiresAt": "2026-08-15T20:05:00Z",
            "proofKind": "attestation",
            "version": 1,
        ])
        let challenge = try CompetitionWireCodec.decode(
            CompetitionAppAttestChallenge.self,
            from: challengeData,
            contract: .appAttestChallengeResponse
        )
        let score = try scoreRequest(revision: 1)
        let envelope = try CompetitionAttestedScoreRevisionRequest(
            score: score,
            appAttest: CompetitionAppAttestProof(
                challengeID: challenge.challengeID,
                installationID: installationID,
                keyID: keyA,
                proofKind: challenge.proofKind,
                object: Data("attestation-object".utf8)
            )
        )
        let envelopeData = try CompetitionWireCodec.encode(
            envelope,
            contract: .attestedScoreRevisionRequest
        )
        let envelopeObject = try XCTUnwrap(
            try jsonObject(envelopeData) as? [String: Any]
        )
        XCTAssertEqual(Set(envelopeObject.keys), ["appAttest", "score", "version"])
        let proof = try XCTUnwrap(envelopeObject["appAttest"] as? [String: Any])
        XCTAssertEqual(
            Set(proof.keys),
            [
                "challengeID", "installationID", "keyID", "object",
                "proofKind", "version",
            ]
        )
        XCTAssertEqual(
            proof["object"] as? String,
            Data("attestation-object".utf8).base64EncodedString()
        )
    }

    func testUnsupportedServiceFailsClosedBeforeChallengeRequest() async throws {
        let fixture = try makeFixture(service: AppAttestServiceProbe(supported: false))

        await XCTAssertThrowsErrorAsync(
            try await fixture.client.appendScoreRevision(scoreRequest(revision: 1))
        ) { error in
            XCTAssertEqual(
                error as? CompetitionRemoteFailure,
                .appAttestUnavailable
            )
        }
        let challengeRequests = await fixture.remote.challengeRequests()
        let submissions = await fixture.remote.submissions()
        XCTAssertEqual(challengeRequests, [])
        XCTAssertEqual(submissions, [])
    }

    func testServerUnavailableRetriesSameKeyAndChallenge() async throws {
        let service = AppAttestServiceProbe(
            attestationResults: [
                .failure(.serverUnavailable),
                .success(Data("attestation-object".utf8)),
            ]
        )
        let fixture = try makeFixture(service: service)
        let score = try scoreRequest(revision: 1)

        await XCTAssertThrowsErrorAsync(
            try await fixture.client.appendScoreRevision(score)
        ) { error in
            XCTAssertEqual(
                error as? CompetitionRemoteFailure,
                .retryableTransport
            )
        }
        _ = try await fixture.client.appendScoreRevision(score)

        let generatedKeys = await service.generatedKeys()
        let challengeRequests = await fixture.remote.challengeRequests()
        let attempts = await service.attestationAttempts()
        let submissions = await fixture.remote.submissions()
        XCTAssertEqual(generatedKeys, [keyA])
        XCTAssertEqual(challengeRequests.count, 1)
        XCTAssertEqual(attempts.map(\.keyID), [keyA, keyA])
        XCTAssertEqual(attempts[0].clientDataHash, attempts[1].clientDataHash)
        XCTAssertEqual(submissions.count, 1)

        let stateText = try String(
            contentsOf: fixture.stateFile,
            encoding: .utf8
        )
        XCTAssertFalse(stateText.contains("attestation-object"))
        XCTAssertFalse(stateText.contains("private"))
    }

    func testInvalidKeyStartsOverWithReplacementKey() async throws {
        let service = AppAttestServiceProbe(
            generatedKeyResults: [.success(keyA), .success(keyB)],
            attestationResults: [
                .failure(.invalidKey),
                .success(Data("replacement-attestation".utf8)),
            ]
        )
        let remote = AppAttestRemoteProbe(
            challengeIDs: [challengeID, replacementChallengeID],
            proofKinds: [.attestation, .attestation]
        )
        let fixture = try makeFixture(service: service, remote: remote)

        _ = try await fixture.client.appendScoreRevision(
            scoreRequest(revision: 1)
        )

        let generatedKeys = await service.generatedKeys()
        let challengeRequests = await remote.challengeRequests()
        let attestationAttempts = await service.attestationAttempts()
        let submissions = await remote.submissions()
        XCTAssertEqual(generatedKeys, [keyA, keyB])
        XCTAssertEqual(
            challengeRequests.map(\.keyID),
            [keyA, keyB]
        )
        XCTAssertEqual(
            attestationAttempts.map(\.keyID),
            [keyA, keyB]
        )
        XCTAssertEqual(submissions.count, 1)
    }

    func testSuccessfulAttestationTransitionsToAssertion() async throws {
        let service = AppAttestServiceProbe(
            attestationResults: [.success(Data("attestation".utf8))],
            assertionResults: [.success(Data("assertion".utf8))]
        )
        let remote = AppAttestRemoteProbe(
            challengeIDs: [challengeID, replacementChallengeID],
            proofKinds: [.attestation, .assertion]
        )
        let fixture = try makeFixture(service: service, remote: remote)

        _ = try await fixture.client.appendScoreRevision(
            scoreRequest(revision: 1)
        )
        _ = try await fixture.client.appendScoreRevision(
            scoreRequest(revision: 2)
        )

        let generatedKeys = await service.generatedKeys()
        let attestationAttempts = await service.attestationAttempts()
        let assertionAttempts = await service.assertionAttempts()
        let submissions = await remote.submissions()
        XCTAssertEqual(generatedKeys, [keyA])
        XCTAssertEqual(attestationAttempts.map(\.keyID), [keyA])
        XCTAssertEqual(assertionAttempts.map(\.keyID), [keyA])
        XCTAssertEqual(
            submissions.map(\.appAttest.proofKind),
            [.attestation, .assertion]
        )
    }

    func testConcurrentSubmissionsDoNotShareChallengeOrProof() async throws {
        let service = AppAttestServiceProbe(
            attestationResults: [.success(Data("attestation".utf8))],
            assertionResults: [.success(Data("assertion".utf8))]
        )
        let remote = AppAttestRemoteProbe(
            challengeIDs: [challengeID, replacementChallengeID],
            proofKinds: [.attestation, .assertion],
            pauseFirstChallenge: true
        )
        let fixture = try makeFixture(service: service, remote: remote)
        let first = Task {
            try await fixture.client.appendScoreRevision(
                scoreRequest(revision: 1)
            )
        }
        await remote.waitUntilFirstChallengeIsPaused()
        let second = Task {
            try await fixture.client.appendScoreRevision(
                scoreRequest(revision: 2)
            )
        }

        for _ in 0..<100 {
            if await remote.challengeRequests().count != 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let requestsBeforeResume = await remote.challengeRequests()
        await remote.resumeFirstChallenge()
        _ = try await first.value
        _ = try await second.value

        let requests = await remote.challengeRequests()
        let submissions = await remote.submissions()
        XCTAssertEqual(requestsBeforeResume.count, 1)
        XCTAssertEqual(Set(requests.map(\.payloadSHA256)).count, 2)
        XCTAssertEqual(
            submissions.map(\.appAttest.proofKind),
            [.attestation, .assertion]
        )
    }

    func testRepeatedContextUnavailableRemainsTypedAfterOneRefresh()
        async throws
    {
        let service = AppAttestServiceProbe(
            attestationResults: [
                .success(Data("first-attestation".utf8)),
                .success(Data("refreshed-attestation".utf8)),
            ]
        )
        let remote = AppAttestRemoteProbe(
            challengeIDs: [challengeID, replacementChallengeID],
            proofKinds: [.attestation, .attestation],
            submissionFailures: [
                .appAttestContextUnavailable,
                .appAttestContextUnavailable,
            ]
        )
        let fixture = try makeFixture(service: service, remote: remote)

        await XCTAssertThrowsErrorAsync(
            try await fixture.client.appendScoreRevision(
                scoreRequest(revision: 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionRemoteFailure,
                .appAttestContextUnavailable
            )
        }

        let generatedKeys = await service.generatedKeys()
        let challengeRequests = await remote.challengeRequests()
        let attempts = await service.attestationAttempts()
        let submissions = await remote.submissions()
        XCTAssertEqual(generatedKeys, [keyA])
        XCTAssertEqual(challengeRequests.count, 2)
        XCTAssertEqual(attempts.map(\.keyID), [keyA, keyA])
        XCTAssertEqual(submissions.count, 2)
    }

    func testStateRejectsCrossProfileReuseAndCorruption() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = AppAttestStateStore(
            profileID: profileID,
            directory: directory,
            fileProtection: .testNoop
        )
        try await first.save(
            AppAttestLocalState(profileID: profileID, keyID: keyA)
        )

        let otherProfile = AppAttestStateStore(
            profileID: UUID(
                uuidString: "90000000-0000-4000-8000-000000000009"
            )!,
            directory: directory,
            fileProtection: .testNoop
        )
        await XCTAssertThrowsErrorAsync(try await otherProfile.load()) {
            XCTAssertEqual(
                $0 as? AppAttestStateStoreFailure,
                .invalidDocument
            )
        }

        try Data("{\"version\":1}".utf8).write(
            to: directory.appendingPathComponent("app-attest-state.v1.json")
        )
        await XCTAssertThrowsErrorAsync(try await first.load()) {
            XCTAssertEqual(
                $0 as? AppAttestStateStoreFailure,
                .invalidDocument
            )
        }
    }

    private func makeFixture(
        service: AppAttestServiceProbe,
        remote: AppAttestRemoteProbe = AppAttestRemoteProbe()
    ) throws -> (
        client: AppAttestClient,
        remote: AppAttestRemoteProbe,
        stateFile: URL
    ) {
        let directory = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = AppAttestStateStore(
            profileID: profileID,
            directory: directory,
            fileProtection: .testNoop
        )
        let client = AppAttestClient.live(
            profileID: profileID,
            installationID: installationID,
            service: service,
            stateStore: store,
            issueChallenge: { try await remote.issue($0) },
            submit: { try await remote.submit($0) },
            now: { self.now }
        )
        return (
            client,
            remote,
            directory.appendingPathComponent("app-attest-state.v1.json")
        )
    }

    private func scoreRequest(revision: Int64) throws
        -> CompetitionScoreRevisionRequest
    {
        try CompetitionScoreRevisionRequest(
            competitionID: UUID(
                uuidString: "40000000-0000-4000-8000-000000000004"
            )!,
            semanticEventID: UUID(
                uuidString: String(
                    format: "50000000-0000-4000-8000-%012lld",
                    revision
                )
            )!,
            dayOrdinal: 1,
            clientRevision: revision,
            evaluatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            moveMode: "activeEnergyKilocalories",
            standMode: "standHours",
            moveBasisPoints: 10_000,
            exerciseBasisPoints: 9_000,
            standBasisPoints: 8_000,
            availabilityReason: "available",
            scoringPolicyIdentity: "healthcomp.activity-score.v1",
            wireContentSHA256: String(repeating: "b", count: 64)
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory.standardizedFileURL
    }

    private func jsonObject(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }

    private func bytes(from: UInt8, count: Int) -> Data {
        Data((0..<count).map { from &+ UInt8($0) })
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let challengeID = UUID(
        uuidString: "10000000-0000-4000-8000-000000000001"
    )!
    private let replacementChallengeID = UUID(
        uuidString: "11000000-0000-4000-8000-000000000011"
    )!
    private let profileID = UUID(
        uuidString: "20000000-0000-4000-8000-000000000002"
    )!
    private let installationID = UUID(
        uuidString: "30000000-0000-4000-8000-000000000003"
    )!
    private let keyA = Data(repeating: 0x41, count: 32).base64EncodedString()
    private let keyB = Data(repeating: 0x42, count: 32).base64EncodedString()
}

private actor AppAttestServiceProbe: AppAttestServiceProtocol {
    struct Attempt: Equatable, Sendable {
        let keyID: String
        let clientDataHash: Data
    }

    private let supported: Bool
    private var generatedKeyResults: [Result<String, AppAttestServiceFailure>]
    private var attestationResults: [Result<Data, AppAttestServiceFailure>]
    private var assertionResults: [Result<Data, AppAttestServiceFailure>]
    private var generated: [String] = []
    private var attestations: [Attempt] = []
    private var assertions: [Attempt] = []

    init(
        supported: Bool = true,
        generatedKeyResults: [Result<String, AppAttestServiceFailure>] = [
            .success(Data(repeating: 0x41, count: 32).base64EncodedString()),
        ],
        attestationResults: [Result<Data, AppAttestServiceFailure>] = [
            .success(Data("attestation".utf8)),
        ],
        assertionResults: [Result<Data, AppAttestServiceFailure>] = [
            .success(Data("assertion".utf8)),
        ]
    ) {
        self.supported = supported
        self.generatedKeyResults = generatedKeyResults
        self.attestationResults = attestationResults
        self.assertionResults = assertionResults
    }

    func isSupported() -> Bool { supported }

    func generateKey() throws -> String {
        let result = generatedKeyResults.removeFirst()
        let key = try result.get()
        generated.append(key)
        return key
    }

    func attestKey(_ keyID: String, clientDataHash: Data) throws -> Data {
        attestations.append(Attempt(keyID: keyID, clientDataHash: clientDataHash))
        return try attestationResults.removeFirst().get()
    }

    func generateAssertion(
        _ keyID: String,
        clientDataHash: Data
    ) throws -> Data {
        assertions.append(Attempt(keyID: keyID, clientDataHash: clientDataHash))
        return try assertionResults.removeFirst().get()
    }

    func generatedKeys() -> [String] { generated }
    func attestationAttempts() -> [Attempt] { attestations }
    func assertionAttempts() -> [Attempt] { assertions }
}

private actor AppAttestRemoteProbe {
    private var challengeIDs: [UUID]
    private var proofKinds: [CompetitionAppAttestProofKind]
    private var submissionFailures: [CompetitionRemoteFailure]
    private var requests: [CompetitionAppAttestChallengeRequest] = []
    private var submitted: [CompetitionAttestedScoreRevisionRequest] = []
    private let pauseFirstChallenge: Bool
    private var firstChallengeContinuation: CheckedContinuation<Void, Never>?
    private var firstChallengeWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        challengeIDs: [UUID] = [
            UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
        ],
        proofKinds: [CompetitionAppAttestProofKind] = [.attestation],
        submissionFailures: [CompetitionRemoteFailure] = [],
        pauseFirstChallenge: Bool = false
    ) {
        self.challengeIDs = challengeIDs
        self.proofKinds = proofKinds
        self.submissionFailures = submissionFailures
        self.pauseFirstChallenge = pauseFirstChallenge
    }

    func issue(
        _ request: CompetitionAppAttestChallengeRequest
    ) async throws -> CompetitionAppAttestChallenge {
        let challengeID = challengeIDs.removeFirst()
        let proofKind = proofKinds.removeFirst()
        requests.append(request)
        if pauseFirstChallenge, requests.count == 1 {
            await withCheckedContinuation { continuation in
                firstChallengeContinuation = continuation
                let waiters = firstChallengeWaiters
                firstChallengeWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        return try CompetitionAppAttestChallenge(
            challengeID: challengeID,
            challenge: Data((0..<32).map(UInt8.init)),
            expiresAt: Date(timeIntervalSince1970: 1_700_000_300),
            proofKind: proofKind
        )
    }

    func waitUntilFirstChallengeIsPaused() async {
        if firstChallengeContinuation != nil { return }
        await withCheckedContinuation { firstChallengeWaiters.append($0) }
    }

    func resumeFirstChallenge() {
        let continuation = firstChallengeContinuation
        firstChallengeContinuation = nil
        continuation?.resume()
    }

    func submit(
        _ request: CompetitionAttestedScoreRevisionRequest
    ) throws -> CompetitionScoreRevisionResponse {
        submitted.append(request)
        if !submissionFailures.isEmpty {
            throw submissionFailures.removeFirst()
        }
        return try CompetitionScoreRevisionResponse(
            disposition: .appended,
            rejectionCode: nil,
            acceptedCentiPoints: 27_000,
            wireContentSHA256: request.score.wireContentSHA256,
            acceptedServerSequence: request.score.clientRevision,
            competitionCursor: request.score.clientRevision
        )
    }

    func challengeRequests() -> [CompetitionAppAttestChallengeRequest] {
        requests
    }

    func submissions() -> [CompetitionAttestedScoreRevisionRequest] {
        submitted
    }
}

private extension JSONCompetitionEventStoreFileProtection {
    static let testNoop = Self { _, _ in }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (any Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
