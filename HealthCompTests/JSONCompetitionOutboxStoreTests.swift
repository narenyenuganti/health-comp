import Foundation
import XCTest
@testable import HealthComp

final class JSONCompetitionOutboxStoreTests: XCTestCase {
    func testEnqueueSurvivesRelaunchBeforeReturning() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try scoreRequest()
        let enqueuedAt = Date(timeIntervalSince1970: 1_786_536_001)
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )

        let entry = try await store.enqueue(
            .scoreRevision(request),
            enqueuedAt: enqueuedAt
        )

        XCTAssertEqual(entry.semanticEventID, request.semanticEventID)
        XCTAssertEqual(entry.enqueuedAt, enqueuedAt)
        XCTAssertEqual(entry.payload, .scoreRevision(request))
        XCTAssertEqual(entry.state, .pending(attemptCount: 0, retryAt: nil))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("outbox.json").path
            )
        )

        let relaunched = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let relaunchedEntries = try await relaunched.entries()
        XCTAssertEqual(relaunchedEntries, [entry])
    }

    func testWireTimestampPrecisionPersistsAsCanonicalJSON() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = Date(
            timeIntervalSince1970: 1_786_536_001.123_456
        )
        let request = try scoreRequest(evaluatedAt: timestamp)
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )

        _ = try await store.enqueue(
            .scoreRevision(request),
            enqueuedAt: timestamp
        )

        let relaunched = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let durableEntries = try await relaunched.entries()
        XCTAssertEqual(durableEntries.count, 1)
        let durableEntry = try XCTUnwrap(durableEntries.first)
        XCTAssertEqual(durableEntry.semanticEventID, request.semanticEventID)
        XCTAssertLessThan(
            abs(durableEntry.enqueuedAt.timeIntervalSince(timestamp)),
            0.001
        )
        guard case let .scoreRevision(durableRequest) = durableEntry.payload
        else {
            return XCTFail("Expected a durable score revision")
        }
        XCTAssertEqual(
            durableRequest.evaluatedAt,
            Date(
                timeIntervalSince1970:
                    timestamp.timeIntervalSince1970.rounded(.down)
            )
        )
    }

    func testCanonicalizedWireTimestampDuplicateIsBytePreservingNoOp()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = Date(
            timeIntervalSince1970: 1_786_536_001.123_456
        )
        let request = try scoreRequest(evaluatedAt: timestamp)
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let first = try await store.enqueue(
            .scoreRevision(request),
            enqueuedAt: timestamp
        )
        let documentURL = root.appendingPathComponent("outbox.json")
        let before = try Data(contentsOf: documentURL)
        let relaunched = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )

        let duplicate = try await relaunched.enqueue(
            .scoreRevision(request),
            enqueuedAt: timestamp.addingTimeInterval(999)
        )

        XCTAssertEqual(duplicate, first)
        XCTAssertEqual(try Data(contentsOf: documentURL), before)
        let durableEntries = try await relaunched.entries()
        XCTAssertEqual(durableEntries, [first])
    }

    func testExactDuplicateEnqueueIsABytePreservingNoOp() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let payload = CompetitionOutboxPayload.scoreRevision(
            try scoreRequest()
        )
        let first = try await store.enqueue(
            payload,
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        let documentURL = root.appendingPathComponent("outbox.json")
        let before = try Data(contentsOf: documentURL)

        let duplicate = try await store.enqueue(
            payload,
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_999)
        )

        XCTAssertEqual(duplicate, first)
        XCTAssertEqual(try Data(contentsOf: documentURL), before)
        let entries = try await store.entries()
        XCTAssertEqual(entries, [first])
    }

    func testDivergentSemanticDuplicateFailsWithoutMutation() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let original = try await store.enqueue(
            .scoreRevision(try scoreRequest()),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        let documentURL = root.appendingPathComponent("outbox.json")
        let before = try Data(contentsOf: documentURL)

        do {
            _ = try await store.enqueue(
                .scoreRevision(
                    try scoreRequest(
                        clientRevision: 2,
                        wireContentSHA256: String(repeating: "b", count: 64)
                    )
                ),
                enqueuedAt: Date(timeIntervalSince1970: 1_786_536_999)
            )
            XCTFail("Expected divergent semantic duplicate failure")
        } catch {
            XCTAssertEqual(
                error as? CompetitionOutboxStoreFailure,
                .semanticEventConflict(original.semanticEventID)
            )
        }

        XCTAssertEqual(try Data(contentsOf: documentURL), before)
        let entries = try await store.entries()
        XCTAssertEqual(entries, [original])
    }

    func testCorruptPrimaryRecoversLastDurablePreviousSnapshot() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let first = try await store.enqueue(
            .scoreRevision(try scoreRequest()),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        _ = try await store.enqueue(
            .scoreRevision(
                try scoreRequest(
                    semanticEventID: UUID(
                        uuidString: "64000000-0000-4000-8000-000000000002"
                    )!,
                    clientRevision: 2,
                    wireContentSHA256: String(repeating: "b", count: 64)
                )
            ),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_002)
        )
        let previousURL = root.appendingPathComponent("outbox.previous.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previousURL.path))
        try Data("corrupt-primary".utf8).write(
            to: root.appendingPathComponent("outbox.json")
        )

        let relaunched = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let recovered = try await relaunched.entries()

        XCTAssertEqual(recovered, [first])
        let repaired = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let repairedEntries = try await repaired.entries()
        XCTAssertEqual(repairedEntries, [first])
    }

    func testStateUpdateAndRemovalRequireCurrentDurableGeneration()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let request = try scoreRequest()
        let entry = try await store.enqueue(
            .scoreRevision(request),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        let response = try CompetitionScoreRevisionResponse(
            disposition: .appended,
            rejectionCode: nil,
            acceptedCentiPoints: 27_500,
            wireContentSHA256: request.wireContentSHA256,
            acceptedServerSequence: 4,
            competitionCursor: 4
        )
        let receivedAt = Date(timeIntervalSince1970: 1_786_536_010)

        let accepted = try await store.update(
            entry.semanticEventID,
            expectedGeneration: entry.generation,
            state: .scoreAccepted(response, receivedAt: receivedAt)
        )

        XCTAssertEqual(accepted.generation, entry.generation + 1)
        XCTAssertEqual(
            accepted.state,
            .scoreAccepted(response, receivedAt: receivedAt)
        )
        let relaunched = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let durableAccepted = try await relaunched.entries()
        XCTAssertEqual(durableAccepted, [accepted])

        await XCTAssertThrowsErrorAsync(
            try await relaunched.remove(
                entry.semanticEventID,
                expectedGeneration: entry.generation
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionOutboxStoreFailure,
                .generationConflict(
                    expected: entry.generation,
                    actual: accepted.generation
                )
            )
        }
        try await relaunched.remove(
            entry.semanticEventID,
            expectedGeneration: accepted.generation
        )
        let empty = try await relaunched.entries()
        XCTAssertEqual(empty, [])
    }

    func testResponseStateMustMatchPayloadFamilyAndCommitment() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let request = try scoreRequest()
        let entry = try await store.enqueue(
            .scoreRevision(request),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        let mismatchedResponse = try CompetitionScoreRevisionResponse(
            disposition: .duplicate,
            rejectionCode: nil,
            acceptedCentiPoints: 27_500,
            wireContentSHA256: String(repeating: "f", count: 64),
            acceptedServerSequence: 4,
            competitionCursor: 4
        )
        let attestationReceipt = try CompetitionAttestationReceipt(
            disposition: .appended,
            windowCommitmentSHA256: String(repeating: "c", count: 64),
            entityServerSequence: 5
        )

        for state in [
            CompetitionOutboxState.scoreAccepted(
                mismatchedResponse,
                receivedAt: Date(timeIntervalSince1970: 1_786_536_010)
            ),
            .attestationAcknowledged(
                attestationReceipt,
                receivedAt: Date(timeIntervalSince1970: 1_786_536_011)
            ),
        ] {
            await XCTAssertThrowsErrorAsync(
                try await store.update(
                    entry.semanticEventID,
                    expectedGeneration: entry.generation,
                    state: state
                )
            ) { error in
                XCTAssertEqual(
                    error as? CompetitionOutboxStoreFailure,
                    .invalidDocument
                )
            }
        }

        let entries = try await store.entries()
        XCTAssertEqual(entries, [entry])
    }

    func testLockSymlinkIsRejectedWithoutMutatingItsTarget() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("lock-target")
        let bytes = Data("do-not-touch".utf8)
        try bytes.write(to: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: target.path
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outbox.lock"),
            withDestinationURL: target
        )
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )

        await XCTAssertThrowsErrorAsync(try await store.entries()) { error in
            XCTAssertEqual(
                error as? CompetitionOutboxStoreFailure,
                .unsafeFilesystemEntry
            )
        }

        XCTAssertEqual(try Data(contentsOf: target), bytes)
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: target.path)[
                .posixPermissions
            ] as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(mode, 0o644)
    }

    func testInterruptedCommitRecoversOnlyDurableSnapshots() async throws {
        for faultPoint in JSONCompetitionOutboxStoreFaultPoint.allCases {
            let root = makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let firstStore = JSONCompetitionOutboxStore(
                rootDirectory: root,
                fileProtection: .testNoop
            )
            let first = try await firstStore.enqueue(
                .scoreRevision(try scoreRequest()),
                enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
            )
            let secondRequest = try scoreRequest(
                semanticEventID: UUID(
                    uuidString: "64000000-0000-4000-8000-000000000002"
                )!,
                clientRevision: 2,
                wireContentSHA256: String(repeating: "b", count: 64)
            )
            let crashingStore = JSONCompetitionOutboxStore(
                rootDirectory: root,
                faultInjector: .init(crashAt: faultPoint),
                fileProtection: .testNoop
            )

            await XCTAssertThrowsErrorAsync(
                try await crashingStore.enqueue(
                    .scoreRevision(secondRequest),
                    enqueuedAt: Date(timeIntervalSince1970: 1_786_536_002)
                )
            ) { error in
                XCTAssertEqual(
                    error as? CompetitionOutboxStoreFailure,
                    .injectedCrash(faultPoint)
                )
            }

            let relaunched = JSONCompetitionOutboxStore(
                rootDirectory: root,
                fileProtection: .testNoop
            )
            let recovered = try await relaunched.entries()
            switch faultPoint {
            case .newTemporarySynced, .primaryMovedToPrevious:
                XCTAssertEqual(recovered, [first], faultPoint.rawValue)
            case .primaryDirectorySynced:
                XCTAssertEqual(
                    recovered.map(\.semanticEventID),
                    [first.semanticEventID, secondRequest.semanticEventID],
                    faultPoint.rawValue
                )
            }
            let staleTemporaries = try FileManager.default
                .contentsOfDirectory(atPath: root.path)
                .filter { $0.hasPrefix(".outbox.") && $0.hasSuffix(".tmp") }
            XCTAssertEqual(staleTemporaries, [], faultPoint.rawValue)
        }
    }

    func testDurableFilesUsePrivateModesAndFirstAuthenticationProtection()
        async throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o777)],
            ofItemAtPath: root.path
        )
        let recorder = OutboxProtectionRecorder()
        let store = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .live.observing { url, protection in
                try recorder.record(protection, for: url)
            }
        )
        _ = try await store.enqueue(
            .scoreRevision(try scoreRequest()),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_001)
        )
        _ = try await store.enqueue(
            .scoreRevision(
                try scoreRequest(
                    semanticEventID: UUID(
                        uuidString: "64000000-0000-4000-8000-000000000002"
                    )!,
                    clientRevision: 2,
                    wireContentSHA256: String(repeating: "b", count: 64)
                )
            ),
            enqueuedAt: Date(timeIntervalSince1970: 1_786_536_002)
        )

        try assertPrivateAttributes(
            root,
            permissions: 0o700,
            recorder: recorder
        )
        for name in [
            "outbox.lock",
            "outbox.json",
            "outbox.previous.json",
        ] {
            try assertPrivateAttributes(
                root.appendingPathComponent(name),
                permissions: 0o600,
                recorder: recorder
            )
        }
    }

    func testConcurrentStoreInstancesSerializeEveryEnqueue() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let second = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let requests = try (1...40).map { index in
            try scoreRequest(
                semanticEventID: UUID(
                    uuidString: String(
                        format: "64000000-0000-4000-8000-%012d",
                        index
                    )
                )!,
                clientRevision: Int64(index)
            )
        }

        let entries = try await withThrowingTaskGroup(
            of: CompetitionOutboxEntry.self
        ) { group in
            for (offset, request) in requests.enumerated() {
                group.addTask {
                    return try await (offset.isMultiple(of: 2)
                        ? first
                        : second
                    ).enqueue(
                        .scoreRevision(request),
                        enqueuedAt: Date(
                            timeIntervalSince1970:
                                1_786_536_001 + Double(offset)
                        )
                    )
                }
            }
            var values: [CompetitionOutboxEntry] = []
            for try await entry in group { values.append(entry) }
            return values
        }

        XCTAssertEqual(Set(entries.map(\.semanticEventID)).count, 40)
        let relaunched = JSONCompetitionOutboxStore(
            rootDirectory: root,
            fileProtection: .testNoop
        )
        let durable = try await relaunched.entries()
        XCTAssertEqual(
            Set(durable.map(\.semanticEventID)),
            Set(entries.map(\.semanticEventID))
        )
        XCTAssertEqual(durable.count, 40)
    }

    private func scoreRequest(
        semanticEventID: UUID = UUID(
            uuidString: "64000000-0000-4000-8000-000000000001"
        )!,
        clientRevision: Int64 = 1,
        wireContentSHA256: String = String(repeating: "a", count: 64),
        evaluatedAt: Date = Date(timeIntervalSince1970: 1_786_536_000)
    ) throws -> CompetitionScoreRevisionRequest {
        try CompetitionScoreRevisionRequest(
            competitionID: UUID(
                uuidString: "63000000-0000-4000-8000-000000000001"
            )!,
            semanticEventID: semanticEventID,
            dayOrdinal: 1,
            clientRevision: clientRevision,
            evaluatedAt: evaluatedAt,
            moveMode: "activeEnergyKilocalories",
            standMode: "standHours",
            moveBasisPoints: 10_000,
            exerciseBasisPoints: 5_000,
            standBasisPoints: 12_500,
            availabilityReason: "available",
            scoringPolicyIdentity: "healthcomp.activity-score.v1",
            wireContentSHA256: wireContentSHA256
        )
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
            .withCreatedDirectory()
    }

    private func assertPrivateAttributes(
        _ url: URL,
        permissions: Int,
        recorder: OutboxProtectionRecorder
    ) throws {
        let actual = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[
                .posixPermissions
            ] as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(actual, permissions, url.lastPathComponent)
        XCTAssertEqual(
            try recorder.protectionApplied(to: url),
            .completeUntilFirstUserAuthentication,
            url.lastPathComponent
        )
    }

}

private extension JSONCompetitionEventStoreFileProtection {
    static let testNoop = Self { _, _ in }
}

private extension URL {
    func withCreatedDirectory() -> URL {
        try! FileManager.default.createDirectory(
            at: self,
            withIntermediateDirectories: false
        )
        return self
    }
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

private final class OutboxProtectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var protectionByFileNumber: [UInt64: FileProtectionType] = [:]

    func record(
        _ protection: FileProtectionType,
        for url: URL
    ) throws {
        let fileNumber = try systemFileNumber(url)
        lock.withLock { protectionByFileNumber[fileNumber] = protection }
    }

    func protectionApplied(to url: URL) throws -> FileProtectionType? {
        let fileNumber = try systemFileNumber(url)
        return lock.withLock { protectionByFileNumber[fileNumber] }
    }

    private func systemFileNumber(_ url: URL) throws -> UInt64 {
        try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[
                .systemFileNumber
            ] as? NSNumber
        ).uint64Value
    }
}
