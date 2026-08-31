import Darwin
import Foundation
import XCTest

@testable import HealthComp

final class HealthKitBackgroundDeliveryReceiptTests: XCTestCase {
    func testCommitRoundTripsPrivacySafeReceiptAndIdenticalRetryIsIdempotent()
        async throws
    {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let protection = BackgroundDeliveryProtectionRecorder()
        let store = HealthKitBackgroundDeliveryReceiptStore(
            directory: directory,
            fileProtection: JSONCompetitionEventStoreFileProtection {
                url,
                value in
                protection.record(url: url, protection: value)
            }
        )
        let receipt = makeReceipt(signalID: "healthkit-background:process:1")
        let containedBeforeCommit = try await store.contains(receipt.signalID)
        XCTAssertFalse(containedBeforeCommit)

        try await store.commit(receipt)
        try await store.commit(receipt)

        let receipts = try await store.receipts()
        let containedAfterCommit = try await store.contains(receipt.signalID)
        XCTAssertEqual(receipts, [receipt])
        XCTAssertTrue(containedAfterCommit)
        let fileURL = directory.appendingPathComponent(
            "background-delivery-receipts.v1.json"
        )
        let data = try Data(contentsOf: fileURL)
        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(raw.keys), ["receipts", "schema_version"])
        let entries = try XCTUnwrap(raw["receipts"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(
            Set(try XCTUnwrap(entries.first).keys),
            [
                "had_issues",
                "processed_at",
                "publication_revision",
                "signal_id",
                "trigger",
            ]
        )
        XCTAssertEqual(
            entries.first?["trigger"] as? String,
            "observerWakeupBackground"
        )
        XCTAssertEqual(try permissions(at: directory), 0o700)
        XCTAssertEqual(try permissions(at: fileURL), 0o600)
        XCTAssertEqual(
            protection.protection(at: directory),
            .completeUntilFirstUserAuthentication
        )
        XCTAssertEqual(
            protection.protection(at: fileURL),
            .completeUntilFirstUserAuthentication
        )
    }

    func testConflictingSignalReuseIsRejectedWithoutChangingReceipt()
        async throws
    {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HealthKitBackgroundDeliveryReceiptStore(
            directory: directory,
            fileProtection: .backgroundDeliveryTestNoop
        )
        let original = makeReceipt(signalID: "healthkit-background:process:2")
        try await store.commit(original)
        let conflict = HealthKitBackgroundDeliveryReceipt(
            signalID: original.signalID,
            trigger: original.trigger,
            processedAt: original.processedAt,
            publicationRevision: original.publicationRevision,
            hadIssues: true
        )

        await XCTAssertThrowsBackgroundDeliveryError(
            try await store.commit(conflict),
            equals: .signalConflict
        )
        let receipts = try await store.receipts()
        XCTAssertEqual(receipts, [original])
    }

    func testSubmillisecondTimestampCanonicalizesAndRetryIsIdempotent()
        async throws
    {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HealthKitBackgroundDeliveryReceiptStore(
            directory: directory,
            fileProtection: .backgroundDeliveryTestNoop
        )
        let receipt = HealthKitBackgroundDeliveryReceipt(
            signalID: "healthkit-background:process:submillisecond",
            trigger: .observerWakeupBackground,
            processedAt: Date(
                timeIntervalSince1970: 1_788_000_000.123_456
            ),
            publicationRevision: 2,
            hadIssues: false
        )

        try await store.commit(receipt)
        try await store.commit(receipt)

        let storedReceipts = try await store.receipts()
        let stored = try XCTUnwrap(storedReceipts.first)
        XCTAssertEqual(stored.signalID, receipt.signalID)
        XCTAssertEqual(stored.trigger, receipt.trigger)
        XCTAssertEqual(
            stored.publicationRevision,
            receipt.publicationRevision
        )
        XCTAssertLessThan(
            abs(stored.processedAt.timeIntervalSince1970
                - receipt.processedAt.timeIntervalSince1970),
            0.000_001
        )
    }

    func testRetentionIsBoundedToNewest128Receipts() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HealthKitBackgroundDeliveryReceiptStore(
            directory: directory,
            fileProtection: .backgroundDeliveryTestNoop
        )

        for ordinal in 1 ... 129 {
            try await store.commit(
                makeReceipt(
                    signalID: "healthkit-background:process:\(ordinal)",
                    ordinal: ordinal
                )
            )
        }

        let receipts = try await store.receipts()
        XCTAssertEqual(receipts.count, 128)
        XCTAssertEqual(
            receipts.first?.signalID,
            "healthkit-background:process:2"
        )
        XCTAssertEqual(
            receipts.last?.signalID,
            "healthkit-background:process:129"
        )
    }

    func testInvalidReceiptAndInvalidDocumentAreRejected() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HealthKitBackgroundDeliveryReceiptStore(
            directory: directory,
            fileProtection: .backgroundDeliveryTestNoop
        )
        let invalid = HealthKitBackgroundDeliveryReceipt(
            signalID: "contains private whitespace",
            trigger: .observerWakeupBackground,
            processedAt: Date(timeIntervalSince1970: 1_788_000_000),
            publicationRevision: 1,
            hadIssues: false
        )

        await XCTAssertThrowsBackgroundDeliveryError(
            try await store.commit(invalid),
            equals: .invalidReceipt
        )
        let fileURL = directory.appendingPathComponent(
            "background-delivery-receipts.v1.json"
        )
        try Data("{}".utf8).write(to: fileURL)
        await XCTAssertThrowsBackgroundDeliveryError(
            try await store.receipts(),
            equals: .invalidDocument
        )
        try Data(repeating: 0x20, count: 64 * 1024 + 1).write(
            to: fileURL
        )
        await XCTAssertThrowsBackgroundDeliveryError(
            try await store.receipts(),
            equals: .invalidDocument
        )
    }

    func testSymlinkedReceiptFileIsRejectedWithoutTouchingDestination()
        async throws
    {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sentinel = Data("outside-must-not-change".utf8)
        try sentinel.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let fileURL = directory.appendingPathComponent(
            "background-delivery-receipts.v1.json"
        )
        try FileManager.default.createSymbolicLink(
            at: fileURL,
            withDestinationURL: outside
        )
        let store = HealthKitBackgroundDeliveryReceiptStore(
            directory: directory,
            fileProtection: .backgroundDeliveryTestNoop
        )

        await XCTAssertThrowsBackgroundDeliveryError(
            try await store.commit(
                makeReceipt(signalID: "healthkit-background:process:3")
            ),
            equals: .unsafeFilesystemEntry
        )
        XCTAssertEqual(try Data(contentsOf: outside), sentinel)
    }

    private func makeReceipt(
        signalID: String,
        ordinal: Int = 1
    ) -> HealthKitBackgroundDeliveryReceipt {
        HealthKitBackgroundDeliveryReceipt(
            signalID: signalID,
            trigger: .observerWakeupBackground,
            processedAt: Date(
                timeIntervalSince1970: 1_788_000_000
                    + TimeInterval(ordinal)
            ),
            publicationRevision: UInt64(ordinal),
            hadIssues: false
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        return url.standardizedFileURL
    }

    private func permissions(at url: URL) throws -> Int {
        let value = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[
                .posixPermissions
            ] as? NSNumber
        )
        return value.intValue & 0o777
    }
}

private final class BackgroundDeliveryProtectionRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [URL: FileProtectionType] = [:]

    func record(url: URL, protection: FileProtectionType) {
        lock.withLock { values[url.standardizedFileURL] = protection }
    }

    func protection(at url: URL) -> FileProtectionType? {
        lock.withLock { values[url.standardizedFileURL] }
    }
}

private extension JSONCompetitionEventStoreFileProtection {
    static let backgroundDeliveryTestNoop = Self { _, _ in }
}

private func XCTAssertThrowsBackgroundDeliveryError<T>(
    _ expression: @autoclosure () async throws -> T,
    equals expected: HealthKitBackgroundDeliveryReceiptStoreFailure,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected background delivery failure", file: file, line: line)
    } catch {
        XCTAssertEqual(
            error as? HealthKitBackgroundDeliveryReceiptStoreFailure,
            expected,
            file: file,
            line: line
        )
    }
}
