import Darwin
import Foundation
import XCTest
@testable import HealthComp

final class AuthenticatedProfileStorageTests: XCTestCase {
    private let profileA = UUID(
        uuidString: "A1000000-0000-4000-8000-000000000001"
    )!
    private let profileB = UUID(
        uuidString: "B2000000-0000-4000-8000-000000000002"
    )!

    func testPOSIXCallCapturesErrnoWithItsResult() {
        let captured = capturePOSIXCall {
            errno = EACCES
            return -1
        }

        errno = ENOENT

        XCTAssertEqual(captured.result, -1)
        XCTAssertEqual(captured.errorCode, EACCES)
    }

    func testMountDerivesLowercaseProfileRootAndFixedProtectedChildren()
        async throws
    {
        let applicationSupport = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let protection = ProfileProtectionRecorder()
        let storage = AuthenticatedProfileStorage.live(
            applicationSupportDirectory: applicationSupport,
            fileProtection: JSONCompetitionEventStoreFileProtection {
                url,
                value in
                protection.record(url: url, protection: value)
            }
        )

        let paths = try await storage.mount(profileA)
        let expectedRoot = applicationSupport
            .appendingPathComponent("HealthComp", isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent(
                profileA.uuidString.lowercased(),
                isDirectory: true
            )

        XCTAssertEqual(paths.profileID, profileA)
        XCTAssertEqual(paths.rootDirectory, expectedRoot)
        XCTAssertEqual(
            paths.fixedDirectories.map(\.lastPathComponent),
            [
                "CompetitionEvents",
                "Outbox",
                "ServerCursors",
                "NotificationPreferences",
                "Installations",
            ]
        )
        for url in [paths.rootDirectory] + paths.fixedDirectories {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: url.path,
                    isDirectory: &isDirectory
                )
            )
            XCTAssertTrue(isDirectory.boolValue)
            XCTAssertEqual(try permissions(at: url), 0o700)
            XCTAssertEqual(
                protection.protection(at: url),
                .completeUntilFirstUserAuthentication
            )
        }
    }

    func testMountRejectsSymlinksInHierarchyAndFixedChildren() async throws {
        let applicationSupport = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let outside = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let healthComp = applicationSupport.appendingPathComponent(
            "HealthComp",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: healthComp,
            withIntermediateDirectories: false
        )
        let profiles = healthComp.appendingPathComponent(
            "Profiles",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: profiles,
            withDestinationURL: outside
        )
        let hierarchyStorage = AuthenticatedProfileStorage.live(
            applicationSupportDirectory: applicationSupport,
            fileProtection: .testNoop
        )

        await XCTAssertThrowsErrorAsync(
            try await hierarchyStorage.mount(profileA)
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedProfileStorageFailure,
                .unsafeFilesystemEntry
            )
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: outside.path),
            []
        )

        try FileManager.default.removeItem(at: profiles)
        let childStorage = AuthenticatedProfileStorage.live(
            applicationSupportDirectory: applicationSupport,
            fileProtection: .testNoop
        )
        let paths = try await childStorage.mount(profileA)
        try FileManager.default.removeItem(at: paths.outboxDirectory)
        try FileManager.default.createSymbolicLink(
            at: paths.outboxDirectory,
            withDestinationURL: outside
        )

        await XCTAssertThrowsErrorAsync(
            try await childStorage.mount(profileA)
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedProfileStorageFailure,
                .unsafeFilesystemEntry
            )
        }
    }

    func testTeardownWipesExactlyOneProfileAndNeverItsSibling() async throws {
        let applicationSupport = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let storage = AuthenticatedProfileStorage.live(
            applicationSupportDirectory: applicationSupport,
            fileProtection: .testNoop
        )
        let pathsA = try await storage.mount(profileA)
        let profilesRoot = pathsA.rootDirectory.deletingLastPathComponent()
        let rootB = profilesRoot.appendingPathComponent(
            profileB.uuidString.lowercased(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rootB,
            withIntermediateDirectories: false
        )
        let siblingSentinel = rootB.appendingPathComponent("keep.txt")
        try Data("profile-b-must-survive".utf8).write(to: siblingSentinel)

        try await storage.teardown(profileA)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: pathsA.rootDirectory.path)
        )
        XCTAssertEqual(
            try Data(contentsOf: siblingSentinel),
            Data("profile-b-must-survive".utf8)
        )
    }

    func testCleanupFailureBlocksMountingAnotherProfile() async throws {
        let applicationSupport = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let storage = AuthenticatedProfileStorage.live(
            applicationSupportDirectory: applicationSupport,
            fileProtection: .testNoop,
            removeItem: { _ in throw InjectedStorageFailure() }
        )
        _ = try await storage.mount(profileA)

        await XCTAssertThrowsErrorAsync(
            try await storage.teardown(profileA)
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedProfileStorageFailure,
                .cleanupFailed
            )
        }
        await XCTAssertThrowsErrorAsync(
            try await storage.mount(profileB)
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedProfileStorageFailure,
                .profileTransitionRequiresCleanup
            )
        }
    }

    func testFreshStorageInstanceRejectsAbandonedDifferentProfile()
        async throws
    {
        let applicationSupport = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let first = AuthenticatedProfileStorage.live(
            applicationSupportDirectory: applicationSupport,
            fileProtection: .testNoop
        )
        _ = try await first.mount(profileA)
        let relaunched = AuthenticatedProfileStorage.live(
            applicationSupportDirectory: applicationSupport,
            fileProtection: .testNoop
        )

        await XCTAssertThrowsErrorAsync(
            try await relaunched.mount(profileB)
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedProfileStorageFailure,
                .profileTransitionRequiresCleanup
            )
        }
    }

    func testSequentialProfileTransitionCannotLoadOrDrainPriorPaths()
        async throws
    {
        let applicationSupport = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let storage = AuthenticatedProfileStorage.live(
            applicationSupportDirectory: applicationSupport,
            fileProtection: .testNoop
        )
        let pathsA = try await storage.mount(profileA)
        let privateOutbox = pathsA.outboxDirectory.appendingPathComponent(
            "profile-a-pending.json"
        )
        try Data("A only".utf8).write(to: privateOutbox)

        try await storage.teardown(profileA)
        let pathsB = try await storage.mount(profileB)

        XCTAssertNotEqual(pathsA.rootDirectory, pathsB.rootDirectory)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: privateOutbox.path)
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: pathsB.outboxDirectory.path
            ),
            []
        )
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
            .withCreatedDirectory()
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

private struct InjectedStorageFailure: Error {}

private final class ProfileProtectionRecorder: @unchecked Sendable {
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
