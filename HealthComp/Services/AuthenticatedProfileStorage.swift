import Darwin
import Dependencies
import Foundation

func capturePOSIXCall(
    _ operation: () -> Int32
) -> (result: Int32, errorCode: Int32) {
    let result = operation()
    return (result, errno)
}

struct AuthenticatedProfileStoragePaths: Equatable, Sendable {
    let profileID: UUID
    let rootDirectory: URL
    let competitionEventsDirectory: URL
    let outboxDirectory: URL
    let serverCursorsDirectory: URL
    let notificationPreferencesDirectory: URL
    let installationsDirectory: URL
    let appAttestDirectory: URL
    let backgroundDeliveryDirectory: URL

    var fixedDirectories: [URL] {
        [
            competitionEventsDirectory,
            outboxDirectory,
            serverCursorsDirectory,
            notificationPreferencesDirectory,
            installationsDirectory,
            appAttestDirectory,
            backgroundDeliveryDirectory,
        ]
    }

    init(profileID: UUID, rootDirectory: URL) {
        self.profileID = profileID
        self.rootDirectory = rootDirectory
        self.competitionEventsDirectory = rootDirectory.appendingPathComponent(
            "CompetitionEvents",
            isDirectory: true
        )
        self.outboxDirectory = rootDirectory.appendingPathComponent(
            "Outbox",
            isDirectory: true
        )
        self.serverCursorsDirectory = rootDirectory.appendingPathComponent(
            "ServerCursors",
            isDirectory: true
        )
        self.notificationPreferencesDirectory = rootDirectory
            .appendingPathComponent(
                "NotificationPreferences",
                isDirectory: true
            )
        self.installationsDirectory = rootDirectory.appendingPathComponent(
            "Installations",
            isDirectory: true
        )
        self.appAttestDirectory = rootDirectory.appendingPathComponent(
            "AppAttest",
            isDirectory: true
        )
        self.backgroundDeliveryDirectory = rootDirectory
            .appendingPathComponent(
                "BackgroundDelivery",
                isDirectory: true
            )
    }
}

enum AuthenticatedProfileStorageFailure: Error, Equatable, Sendable {
    case invalidApplicationSupportDirectory
    case unsafeFilesystemEntry
    case profileTransitionRequiresCleanup
    case cleanupFailed
}

struct AuthenticatedProfileStorage: Sendable {
    var mount: @Sendable (UUID) async throws ->
        AuthenticatedProfileStoragePaths
    var teardown: @Sendable (UUID) async throws -> Void

    init(
        mount: @escaping @Sendable (UUID) async throws ->
            AuthenticatedProfileStoragePaths,
        teardown: @escaping @Sendable (UUID) async throws -> Void
    ) {
        self.mount = mount
        self.teardown = teardown
    }

    static func live(
        applicationSupportDirectory: URL,
        fileProtection: JSONCompetitionEventStoreFileProtection = .live,
        removeItem: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        }
    ) -> Self {
        let coordinator = AuthenticatedProfileStorageCoordinator(
            applicationSupportDirectory: applicationSupportDirectory,
            fileProtection: fileProtection,
            removeItem: removeItem
        )
        return Self(
            mount: { try await coordinator.mount($0) },
            teardown: { try await coordinator.teardown($0) }
        )
    }
}

extension AuthenticatedProfileStorage: TestDependencyKey {
    static let testValue = Self(
        mount: { _ in
            throw AuthenticatedProfileStorageFailure
                .invalidApplicationSupportDirectory
        },
        teardown: { _ in
            throw AuthenticatedProfileStorageFailure
                .invalidApplicationSupportDirectory
        }
    )
}

extension AuthenticatedProfileStorage: DependencyKey {
    static let liveValue: Self = {
        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return .live(applicationSupportDirectory: directory)
        } catch {
            return Self(
                mount: { _ in
                    throw AuthenticatedProfileStorageFailure
                        .invalidApplicationSupportDirectory
                },
                teardown: { _ in
                    throw AuthenticatedProfileStorageFailure
                        .invalidApplicationSupportDirectory
                }
            )
        }
    }()
}

extension DependencyValues {
    var authenticatedProfileStorage: AuthenticatedProfileStorage {
        get { self[AuthenticatedProfileStorage.self] }
        set { self[AuthenticatedProfileStorage.self] = newValue }
    }
}

private actor AuthenticatedProfileStorageCoordinator {
    typealias RemoveItem = @Sendable (URL) throws -> Void

    private let applicationSupportDirectory: URL
    private let fileProtection: JSONCompetitionEventStoreFileProtection
    private let removeItem: RemoveItem
    private let fileManager = FileManager.default
    private var activeProfileID: UUID?

    init(
        applicationSupportDirectory: URL,
        fileProtection: JSONCompetitionEventStoreFileProtection,
        removeItem: @escaping RemoveItem
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
            .standardizedFileURL
        self.fileProtection = fileProtection
        self.removeItem = removeItem
    }

    func mount(_ profileID: UUID) throws -> AuthenticatedProfileStoragePaths {
        guard activeProfileID == nil || activeProfileID == profileID else {
            throw AuthenticatedProfileStorageFailure
                .profileTransitionRequiresCleanup
        }
        let profilesRoot = try prepareProfilesRoot()
        try rejectDifferentOrUnsafeProfiles(
            in: profilesRoot,
            requestedProfileID: profileID
        )
        activeProfileID = profileID

        let root = profilesRoot.appendingPathComponent(
            profileID.uuidString.lowercased(),
            isDirectory: true
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profileID,
            rootDirectory: root
        )
        do {
            try ensurePrivateDirectory(root)
            for directory in paths.fixedDirectories {
                try ensurePrivateDirectory(directory)
            }
            return paths
        } catch let failure as AuthenticatedProfileStorageFailure {
            throw failure
        } catch {
            throw AuthenticatedProfileStorageFailure.unsafeFilesystemEntry
        }
    }

    func teardown(_ profileID: UUID) throws {
        guard activeProfileID == nil || activeProfileID == profileID else {
            throw AuthenticatedProfileStorageFailure
                .profileTransitionRequiresCleanup
        }
        activeProfileID = profileID
        let profilesRoot = try prepareProfilesRoot()
        let root = profilesRoot.appendingPathComponent(
            profileID.uuidString.lowercased(),
            isDirectory: true
        )

        switch try entryKind(at: root) {
        case .absent:
            activeProfileID = nil
            return
        case .directory:
            break
        case .regularFile, .other:
            throw AuthenticatedProfileStorageFailure.unsafeFilesystemEntry
        }

        try validateRemovalTree(root)
        do {
            try removeItem(root)
        } catch {
            throw AuthenticatedProfileStorageFailure.cleanupFailed
        }
        guard try entryKind(at: root) == .absent else {
            throw AuthenticatedProfileStorageFailure.cleanupFailed
        }
        activeProfileID = nil
    }

    private func prepareProfilesRoot() throws -> URL {
        guard applicationSupportDirectory.isFileURL else {
            throw AuthenticatedProfileStorageFailure
                .invalidApplicationSupportDirectory
        }
        guard try entryKind(at: applicationSupportDirectory) == .directory
        else {
            throw AuthenticatedProfileStorageFailure
                .invalidApplicationSupportDirectory
        }
        let healthComp = applicationSupportDirectory.appendingPathComponent(
            "HealthComp",
            isDirectory: true
        )
        let profiles = healthComp.appendingPathComponent(
            "Profiles",
            isDirectory: true
        )
        let version = profiles.appendingPathComponent(
            "v1",
            isDirectory: true
        )
        for directory in [healthComp, profiles, version] {
            try ensurePrivateDirectory(directory)
        }
        return version
    }

    private func rejectDifferentOrUnsafeProfiles(
        in profilesRoot: URL,
        requestedProfileID: UUID
    ) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: profilesRoot,
            includingPropertiesForKeys: nil,
            options: []
        )
        let requestedName = requestedProfileID.uuidString.lowercased()
        for entry in entries {
            guard try entryKind(at: entry) == .directory,
                  let profileID = UUID(uuidString: entry.lastPathComponent),
                  entry.lastPathComponent
                    == profileID.uuidString.lowercased()
            else {
                throw AuthenticatedProfileStorageFailure.unsafeFilesystemEntry
            }
            guard entry.lastPathComponent == requestedName else {
                throw AuthenticatedProfileStorageFailure
                    .profileTransitionRequiresCleanup
            }
        }
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        switch try entryKind(at: url) {
        case .absent:
            let call = url.path.withCString { path in
                capturePOSIXCall {
                    Darwin.mkdir(path, mode_t(0o700))
                }
            }
            if call.result != 0, call.errorCode != EEXIST {
                throw AuthenticatedProfileStorageFailure
                    .unsafeFilesystemEntry
            }
            guard try entryKind(at: url) == .directory else {
                throw AuthenticatedProfileStorageFailure
                    .unsafeFilesystemEntry
            }
        case .directory:
            break
        case .regularFile, .other:
            throw AuthenticatedProfileStorageFailure.unsafeFilesystemEntry
        }
        guard Darwin.chmod(url.path, mode_t(0o700)) == 0 else {
            throw AuthenticatedProfileStorageFailure.unsafeFilesystemEntry
        }
        do {
            try fileProtection.apply(
                .completeUntilFirstUserAuthentication,
                to: url
            )
        } catch {
            throw AuthenticatedProfileStorageFailure.unsafeFilesystemEntry
        }
    }

    private func validateRemovalTree(_ directory: URL) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for entry in entries {
            switch try entryKind(at: entry) {
            case .directory:
                try validateRemovalTree(entry)
            case .regularFile:
                continue
            case .absent, .other:
                throw AuthenticatedProfileStorageFailure
                    .unsafeFilesystemEntry
            }
        }
    }

    private enum EntryKind: Equatable {
        case absent
        case directory
        case regularFile
        case other
    }

    private func entryKind(at url: URL) throws -> EntryKind {
        var metadata = stat()
        let call = url.path.withCString { path in
            capturePOSIXCall { Darwin.lstat(path, &metadata) }
        }
        guard call.result == 0 else {
            if call.errorCode == ENOENT { return .absent }
            throw AuthenticatedProfileStorageFailure.unsafeFilesystemEntry
        }
        switch metadata.st_mode & S_IFMT {
        case S_IFDIR:
            return .directory
        case S_IFREG:
            return .regularFile
        default:
            return .other
        }
    }
}
