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

    func testNotificationChoicesAreOnUntilStoredOff() throws {
        let suite = "choices-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(CompetitionNotificationChoice.switchedOff(in: defaults), [])
        defaults.set(false, forKey: CompetitionNotificationChoice.leadChange.storageKey)
        XCTAssertEqual(CompetitionNotificationChoice.switchedOff(in: defaults), [.leadChange])
        defaults.set(true, forKey: CompetitionNotificationChoice.leadChange.storageKey)
        XCTAssertEqual(CompetitionNotificationChoice.switchedOff(in: defaults), [])
    }

    func testMutedPushKindsListsOnlySwitchedOffServerKinds() throws {
        let suite = "choices-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        for choice in [CompetitionNotificationChoice.nudge, .reaction, .leadChange] {
            defaults.set(false, forKey: choice.storageKey)
        }
        XCTAssertEqual(CompetitionNotificationChoice.mutedPushKinds(in: defaults), ["nudge", "reaction"])

        defaults.set(false, forKey: CompetitionNotificationChoice.friendRequest.storageKey)
        defaults.set(false, forKey: CompetitionNotificationChoice.friendAccepted.storageKey)
        XCTAssertEqual(
            CompetitionNotificationChoice.mutedPushKinds(in: defaults),
            ["friend_accepted", "friend_request", "nudge", "reaction"]
        )
    }

    func testFriendChoicesDefaultToOn() throws {
        let suite = "choices-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(CompetitionNotificationChoice.switchedOff(in: defaults), [])
        XCTAssertEqual(CompetitionNotificationChoice.mutedPushKinds(in: defaults), [])
    }

    func testNotificationChoiceKeysAndTitlesNeverChange() {
        XCTAssertEqual(
            CompetitionNotificationChoice.allCases.map(\.storageKey),
            [
                "healthcomp.notifications.lead-change",
                "healthcomp.notifications.close-score",
                "healthcomp.notifications.what-it-takes",
                "healthcomp.notifications.final-day",
                "healthcomp.notifications.group-banter",
                "healthcomp.notifications.live-activity",
                "healthcomp.notifications.reaction",
                "healthcomp.notifications.nudge",
                "healthcomp.notifications.friend_request",
                "healthcomp.notifications.friend_accepted",
            ]
        )
        XCTAssertEqual(
            CompetitionNotificationChoice.allCases.map(\.title),
            ["Lead changes", "Close scores", "What it takes", "Last day", "Group match banter", "Live Activity",
             "Reactions", "Nudges", "Friend requests", "Accepted requests"]
        )
        XCTAssertEqual(
            CompetitionNotificationChoice.allCases.filter(\.isServerSent),
            [.reaction, .nudge, .friendRequest, .friendAccepted]
        )
        XCTAssertEqual(
            CompetitionNotificationChoice.allCases.filter(\.isFriends).map(\.rawValue),
            ["friend_request", "friend_accepted"]
        )
    }
}
