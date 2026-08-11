import Foundation
import XCTest
@testable import HealthComp

final class CompetitionNotificationPreferencesTests: XCTestCase {
    func testMutePersistsAcrossStoreRecreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "notification-preferences-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preferences.json")

        let first = CompetitionNotificationPreferencesStore(fileURL: url)
        try await first.setMuted("local-opponent:v1:default", true)

        let persisted = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as? [String: Any]
        XCTAssertEqual(persisted?["version"] as? Int, 1)
        XCTAssertEqual(
            persisted?["mutedOpponentIdentities"] as? [String],
            ["local-opponent:v1:default"]
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: url.appendingPathExtension("tmp").path
            )
        )

        let reloaded = CompetitionNotificationPreferencesStore(fileURL: url)
        let reloadedIdentities = try await reloaded
            .mutedOpponentIdentities()
        XCTAssertEqual(reloadedIdentities, ["local-opponent:v1:default"])
    }

    func testUnmuteRemovesIdentityWithoutChangingDisplayNameKeys() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "notification-preferences-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompetitionNotificationPreferencesStore(
            fileURL: root.appendingPathComponent("preferences.json")
        )

        try await store.setMuted("local-opponent:v1:default", true)
        try await store.setMuted("local-opponent:v1:default", false)

        let identities = try await store.mutedOpponentIdentities()
        XCTAssertEqual(identities, [])
    }

    func testCorruptPreferencesFailClosedInsteadOfAssumingUnmuted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "notification-preferences-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let url = root.appendingPathComponent("preferences.json")
        try Data("not-json".utf8).write(to: url)
        let store = CompetitionNotificationPreferencesStore(fileURL: url)

        do {
            _ = try await store.mutedOpponentIdentities()
            XCTFail("Corrupt preferences must not silently become unmuted.")
        } catch let error as CompetitionNotificationPreferencesError {
            XCTAssertEqual(error, .invalidDocument)
        }
    }

    func testEmptyOpponentIdentityIsRejectedBeforePersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "notification-preferences-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preferences.json")
        let store = CompetitionNotificationPreferencesStore(fileURL: url)

        do {
            try await store.setMuted("", true)
            XCTFail("An empty stable identity must be rejected.")
        } catch let error as CompetitionNotificationPreferencesError {
            XCTAssertEqual(error, .invalidIdentity)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
