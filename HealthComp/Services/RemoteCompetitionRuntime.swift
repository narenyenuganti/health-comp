import CompetitionCore
import CryptoKit
import Darwin
import Foundation

enum RemoteCompetitionRuntimeFailure: Error, Equatable, Sendable {
    case cancelled
    case unauthenticated
    case forbidden
    case discoveryUnavailable
    case profileMismatch
    case competitionNotMaterialized
    case serverContractMismatch
    case storageUnavailable
    case cursorRetryLimitExceeded
}

enum RemoteCompetitionCacheFailure: Error, Equatable, Sendable {
    case invalidRootDirectory
    case unsafeFilesystemEntry
    case invalidDocument
}

struct RemoteCompetitionCacheEntry: Codable, Equatable, Sendable {
    let descriptor: CompetitionDescriptor
    let lastSeenServerSequence: Int64

    init(
        descriptor: CompetitionDescriptor,
        lastSeenServerSequence: Int64
    ) throws {
        guard lastSeenServerSequence >= 0,
              lastSeenServerSequence <= descriptor.serverCursor
        else {
            throw RemoteCompetitionCacheFailure.invalidDocument
        }
        self.descriptor = descriptor
        self.lastSeenServerSequence = lastSeenServerSequence
    }
}

protocol RemoteCompetitionCacheStore: Sendable {
    func load(profileID: UUID) async throws -> [RemoteCompetitionCacheEntry]
    func save(
        _ entries: [RemoteCompetitionCacheEntry],
        profileID: UUID
    ) async throws
}

actor JSONRemoteCompetitionCacheStore: RemoteCompetitionCacheStore {
    private struct Document: Codable {
        static let currentVersion = 1

        let version: Int
        let profileID: UUID
        let entries: [RemoteCompetitionCacheEntry]
    }

    private let rootDirectory: URL
    private let fileProtection: JSONCompetitionEventStoreFileProtection
    private let filename = "competition-inventory.v1.json"
    private let lockFilename = "competition-inventory.v1.lock"
    private let maximumEncodedBytes = 1_048_576
    private let fileManager = FileManager.default

    init(
        rootDirectory: URL,
        fileProtection: JSONCompetitionEventStoreFileProtection = .live
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileProtection = fileProtection
    }

    func load(profileID: UUID) throws -> [RemoteCompetitionCacheEntry] {
        try withExclusiveLock { rootDescriptor in
            guard let data = try readData(rootDescriptor: rootDescriptor) else {
                return []
            }
            guard let document = try? JSONDecoder().decode(
                Document.self,
                from: data
            ),
            document.version == Document.currentVersion,
            document.profileID == profileID,
            document.entries.count
                == Set(document.entries.map {
                    $0.descriptor.competitionID
                }).count,
            document.entries.allSatisfy({ entry in
                entry.lastSeenServerSequence >= 0
                    && entry.lastSeenServerSequence
                        <= entry.descriptor.serverCursor
                    && entry.descriptor.participants.contains(where: {
                        $0.profileID == profileID
                    })
            })
            else {
                throw RemoteCompetitionCacheFailure.invalidDocument
            }
            return document.entries.sorted(by: Self.sortEntries)
        }
    }

    func save(
        _ entries: [RemoteCompetitionCacheEntry],
        profileID: UUID
    ) throws {
        guard entries.count
                == Set(entries.map { $0.descriptor.competitionID }).count,
              entries.allSatisfy({ entry in
                  entry.descriptor.participants.contains(where: {
                      $0.profileID == profileID
                  })
              })
        else {
            throw RemoteCompetitionCacheFailure.invalidDocument
        }
        let document = Document(
            version: Document.currentVersion,
            profileID: profileID,
            entries: entries.sorted(by: Self.sortEntries)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= maximumEncodedBytes else {
            throw RemoteCompetitionCacheFailure.invalidDocument
        }
        try withExclusiveLock { rootDescriptor in
            switch try entryKind(
                rootDescriptor: rootDescriptor,
                filename: filename
            ) {
            case .absent, .regularFile:
                break
            case .other:
                throw RemoteCompetitionCacheFailure.unsafeFilesystemEntry
            }
            try persist(data, rootDescriptor: rootDescriptor)
        }
    }

    private var fileURL: URL {
        rootDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    private func withExclusiveLock<Value>(
        _ operation: (Int32) throws -> Value
    ) throws -> Value {
        let rootDescriptor = try openRootDirectory()
        defer { _ = Darwin.close(rootDescriptor) }
        let lockDescriptor = lockFilename.withCString { name in
            Darwin.openat(
                rootDescriptor,
                name,
                O_RDWR | O_CREAT | O_CLOEXEC | O_EXLOCK | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard lockDescriptor >= 0 else {
            throw RemoteCompetitionCacheFailure.unsafeFilesystemEntry
        }
        defer { _ = Darwin.close(lockDescriptor) }
        var metadata = stat()
        guard Darwin.fstat(lockDescriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              Darwin.fchmod(lockDescriptor, mode_t(0o600)) == 0
        else {
            throw RemoteCompetitionCacheFailure.unsafeFilesystemEntry
        }
        try fileProtection.apply(
            .completeUntilFirstUserAuthentication,
            to: rootDirectory.appendingPathComponent(lockFilename)
        )
        try reapStaleTemporaryFiles(rootDescriptor: rootDescriptor)
        return try operation(rootDescriptor)
    }

    private func openRootDirectory() throws -> Int32 {
        guard rootDirectory.isFileURL else {
            throw RemoteCompetitionCacheFailure.invalidRootDirectory
        }
        let descriptor = rootDirectory.path.withCString { path in
            Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw RemoteCompetitionCacheFailure.invalidRootDirectory
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              Darwin.fchmod(descriptor, mode_t(0o700)) == 0
        else {
            _ = Darwin.close(descriptor)
            throw RemoteCompetitionCacheFailure.invalidRootDirectory
        }
        do {
            try fileProtection.apply(
                .completeUntilFirstUserAuthentication,
                to: rootDirectory
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    private func readData(rootDescriptor: Int32) throws -> Data? {
        let descriptor = filename.withCString { name in
            Darwin.openat(
                rootDescriptor,
                name,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw RemoteCompetitionCacheFailure.unsafeFilesystemEntry
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= maximumEncodedBytes
        else {
            throw RemoteCompetitionCacheFailure.unsafeFilesystemEntry
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= maximumEncodedBytes else {
                    throw RemoteCompetitionCacheFailure.invalidDocument
                }
                continue
            }
            if count == 0 { return data }
            if errno == EINTR { continue }
            throw RemoteCompetitionCacheFailure.unsafeFilesystemEntry
        }
    }

    private func persist(_ data: Data, rootDescriptor: Int32) throws {
        let temporaryFilename = ".competition-inventory.\(UUID().uuidString.lowercased()).tmp"
        let temporaryDescriptor = temporaryFilename.withCString { name in
            Darwin.openat(
                rootDescriptor,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard temporaryDescriptor >= 0 else {
            throw RemoteCompetitionCacheFailure.unsafeFilesystemEntry
        }
        var isOpen = true
        var shouldRemove = true
        defer {
            if isOpen { _ = Darwin.close(temporaryDescriptor) }
            if shouldRemove {
                _ = temporaryFilename.withCString { name in
                    Darwin.unlinkat(rootDescriptor, name, 0)
                }
            }
        }
        guard Darwin.fchmod(temporaryDescriptor, mode_t(0o600)) == 0 else {
            throw RemoteCompetitionCacheFailure.unsafeFilesystemEntry
        }
        try fileProtection.apply(
            .completeUntilFirstUserAuthentication,
            to: rootDirectory.appendingPathComponent(temporaryFilename)
        )
        try writeAll(data, to: temporaryDescriptor)
        try synchronize(temporaryDescriptor)
        try fullySynchronize(temporaryDescriptor)
        guard Darwin.close(temporaryDescriptor) == 0 else {
            isOpen = false
            throw RemoteCompetitionCacheFailure.unsafeFilesystemEntry
        }
        isOpen = false
        let renameResult = temporaryFilename.withCString { temporaryName in
            filename.withCString { finalName in
                Darwin.renameat(
                    rootDescriptor,
                    temporaryName,
                    rootDescriptor,
                    finalName
                )
            }
        }
        guard renameResult == 0 else {
            throw RemoteCompetitionCacheFailure.unsafeFilesystemEntry
        }
        shouldRemove = false
        try fileProtection.apply(
            .completeUntilFirstUserAuthentication,
            to: fileURL
        )
        try synchronize(rootDescriptor)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw RemoteCompetitionCacheFailure.unsafeFilesystemEntry
                }
                offset += count
            }
        }
    }

    private func synchronize(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw RemoteCompetitionCacheFailure.unsafeFilesystemEntry
        }
    }

    private func fullySynchronize(_ descriptor: Int32) throws {
        while Darwin.fcntl(descriptor, F_FULLFSYNC) != 0 {
            if errno == EINTR { continue }
            throw RemoteCompetitionCacheFailure.unsafeFilesystemEntry
        }
    }

    private enum EntryKind: Equatable {
        case absent
        case regularFile
        case other
    }

    private func entryKind(
        rootDescriptor: Int32,
        filename: String
    ) throws -> EntryKind {
        var metadata = stat()
        let result = filename.withCString { name in
            Darwin.fstatat(
                rootDescriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard result == 0 else {
            if errno == ENOENT { return .absent }
            throw RemoteCompetitionCacheFailure.unsafeFilesystemEntry
        }
        return metadata.st_mode & S_IFMT == S_IFREG ? .regularFile : .other
    }

    private func reapStaleTemporaryFiles(rootDescriptor: Int32) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        var removedAny = false
        for entry in entries
        where isTemporaryFilename(entry.lastPathComponent) {
            let entryFilename = entry.lastPathComponent
            guard try entryKind(
                rootDescriptor: rootDescriptor,
                filename: entryFilename
            ) == .regularFile
            else {
                throw RemoteCompetitionCacheFailure.unsafeFilesystemEntry
            }
            let result = entryFilename.withCString { name in
                Darwin.unlinkat(rootDescriptor, name, 0)
            }
            guard result == 0 else {
                throw RemoteCompetitionCacheFailure.unsafeFilesystemEntry
            }
            removedAny = true
        }
        if removedAny { try synchronize(rootDescriptor) }
    }

    private func isTemporaryFilename(_ value: String) -> Bool {
        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        return components.count == 4
            && components[0].isEmpty
            && components[1] == "competition-inventory"
            && UUID(uuidString: String(components[2])) != nil
            && components[3] == "tmp"
    }

    private static func sortEntries(
        _ lhs: RemoteCompetitionCacheEntry,
        _ rhs: RemoteCompetitionCacheEntry
    ) -> Bool {
        lhs.descriptor.competitionID.uuidString
            < rhs.descriptor.competitionID.uuidString
    }
}

struct RemoteCompetitionMaterialization: Equatable, Sendable {
    let descriptor: CompetitionDescriptor
    let journal: LoadedCompetitionJournal
}

struct RemoteCompetitionRuntimeIDFailure: Equatable, Sendable {
    let competitionID: CompetitionID
    let failure: RemoteCompetitionRuntimeFailure
}

struct RemoteCompetitionRuntimeActivityFailure: Equatable, Sendable {
    let competitionID: CompetitionID
    let failure: CompetitionActivitySourceError
}

private struct RemoteCompetitionSynchronizationOutcome {
    let materialization: RemoteCompetitionMaterialization
    let activityFailure: CompetitionActivitySourceError?
}

private struct RemoteOwnerScoreRefreshOutcome {
    let materialization: RemoteCompetitionMaterialization
    let activityFailure: CompetitionActivitySourceError?
}

enum RemoteCompetitionRuntimeIDOutcome: Equatable, Sendable {
    case success(RemoteCompetitionMaterialization)
    case failure(RemoteCompetitionRuntimeIDFailure)

    var competitionID: CompetitionID {
        switch self {
        case let .success(materialization):
            CompetitionID(materialization.descriptor.competitionID)
        case let .failure(failure):
            failure.competitionID
        }
    }
}

struct RemoteCompetitionRuntimeOutcome: Equatable, Sendable {
    let outcomes: [RemoteCompetitionRuntimeIDOutcome]
    let discoveryFailure: RemoteCompetitionRuntimeFailure?
    let activityFailures: [RemoteCompetitionRuntimeActivityFailure]

    init(
        outcomes: [RemoteCompetitionRuntimeIDOutcome],
        discoveryFailure: RemoteCompetitionRuntimeFailure?,
        activityFailures: [RemoteCompetitionRuntimeActivityFailure] = []
    ) {
        self.outcomes = outcomes
        self.discoveryFailure = discoveryFailure
        self.activityFailures = activityFailures
    }

    var successfulJournals: [LoadedCompetitionJournal] {
        outcomes.compactMap { outcome in
            guard case let .success(value) = outcome else { return nil }
            return value.journal
        }
    }

    var successfulCompetitions: [RemoteCompetitionMaterialization] {
        outcomes.compactMap { outcome in
            guard case let .success(value) = outcome else { return nil }
            return value
        }
    }

    var failures: [RemoteCompetitionRuntimeIDFailure] {
        outcomes.compactMap { outcome in
            guard case let .failure(failure) = outcome else { return nil }
            return failure
        }
    }
}

/// Owns the profile-scoped reconciliation boundary between the server's
/// competition inventory and the durable Core journals on this device.
actor RemoteCompetitionRuntime {
    private let profileID: UUID
    private let store: any CompetitionEventStore
    private let remoteAPI: CompetitionRemoteAPI
    private let environment: CompetitionEnvironmentClient?
    private let outboxStore: (any CompetitionOutboxStore)?
    private let syncCoordinator: CompetitionSyncCoordinator?
    private let cacheStore: (any RemoteCompetitionCacheStore)?
    private let now: @Sendable () -> Date
    private let engine = CompetitionEngine()
    private let maximumCursorRetries = 4

    init(
        profileID: UUID,
        store: any CompetitionEventStore,
        remoteAPI: CompetitionRemoteAPI,
        environment: CompetitionEnvironmentClient? = nil,
        outboxStore: (any CompetitionOutboxStore)? = nil,
        cacheStore: (any RemoteCompetitionCacheStore)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.profileID = profileID
        self.store = store
        self.remoteAPI = remoteAPI
        self.environment = environment
        self.outboxStore = outboxStore
        self.cacheStore = cacheStore
        self.now = now
        self.syncCoordinator = outboxStore.map { outboxStore in
            CompetitionSyncCoordinator(
                profileID: profileID,
                outboxStore: outboxStore,
                remoteAPI: remoteAPI,
                acceptedScorePersistence: .eventStore(store),
                now: now
            )
        }
    }

    func stop() async {
        await syncCoordinator?.stop()
    }

    func commitNotificationDecisions(
        competition: CompetitionNotificationCompetitionSnapshot,
        replan: @escaping CompetitionNotificationDecisionCommitter.Replan
    ) async throws -> CompetitionNotificationDecisionCommitResult {
        for retry in 0..<maximumCursorRetries {
            guard let loaded = try await store.load(competition.id) else {
                throw RemoteCompetitionRuntimeFailure
                    .competitionNotMaterialized
            }
            let fresh = RemoteCompetitionProjector.notificationCompetition(
                reloading: loaded,
                profileID: profileID,
                baseline: competition
            )
            let replanned = try replan(fresh)
            guard !replanned.isEmpty else { return .noDecision }

            let recordedIDs = loaded.projection.notificationEmissions
                .recordedIDs
            var seenIDs: Set<String> = []
            let novel = replanned.filter { decision in
                let id = decision.record.semanticEventID
                return seenIDs.insert(id).inserted
                    && !recordedIDs.contains(id)
            }
            guard !novel.isEmpty else { return .duplicate }

            do {
                let result = try await store.append(
                    novel.map {
                        .notificationEmissionRecorded($0.record)
                    },
                    to: competition.id,
                    expectedCursor: loaded.journal.cursor
                )
                guard result.appendedCount > 0 else { return .duplicate }
                return .appended(novel)
            } catch let error as CompetitionEventStoreError {
                guard case .cursorConflict = error else { throw error }
                guard retry + 1 < maximumCursorRetries else {
                    throw RemoteCompetitionRuntimeFailure
                        .cursorRetryLimitExceeded
                }
            }
        }
        throw RemoteCompetitionRuntimeFailure.cursorRetryLimitExceeded
    }

    func synchronizeAll() async -> RemoteCompetitionRuntimeOutcome {
        await syncCoordinator?.wake()
        let cachedEntries: [RemoteCompetitionCacheEntry]
        do {
            cachedEntries = try await cacheStore?.load(
                profileID: profileID
            ) ?? []
        } catch {
            return RemoteCompetitionRuntimeOutcome(
                outcomes: [],
                discoveryFailure: .storageUnavailable
            )
        }
        let descriptors: [CompetitionDescriptor]
        do {
            descriptors = try await remoteAPI.listCompetitions()
        } catch {
            return await offlineOutcome(
                cachedEntries: cachedEntries,
                discoveryFailure: Self.failure(from: error)
            )
        }

        var outcomes: [RemoteCompetitionRuntimeIDOutcome] = []
        var activityFailures: [RemoteCompetitionRuntimeActivityFailure] = []
        var nextCacheByID = Dictionary(
            uniqueKeysWithValues: cachedEntries.map {
                ($0.descriptor.competitionID, $0)
            }
        )
        let listedIDs = Set(descriptors.map(\.competitionID))
        nextCacheByID = nextCacheByID.filter { listedIDs.contains($0.key) }
        for descriptor in descriptors.sorted(by: Self.sortDescriptors) {
            let competitionID = CompetitionID(descriptor.competitionID)
            guard descriptor.participants.contains(where: {
                $0.profileID == profileID
            }) else {
                outcomes.append(
                    .failure(
                        RemoteCompetitionRuntimeIDFailure(
                            competitionID: competitionID,
                            failure: .profileMismatch
                        )
                    )
                )
                continue
            }
            switch descriptor.lifecycle {
            case .declined, .expired, .cancelled:
                nextCacheByID.removeValue(
                    forKey: descriptor.competitionID
                )
                continue
            default:
                break
            }
            do {
                let synchronized = try await synchronize(
                    descriptor: descriptor,
                    cachedEntry: nextCacheByID[descriptor.competitionID]
                )
                let cacheEntry = try RemoteCompetitionCacheEntry(
                    descriptor: descriptor,
                    lastSeenServerSequence: descriptor.serverCursor
                )
                outcomes.append(
                    .success(synchronized.materialization)
                )
                if let failure = synchronized.activityFailure {
                    activityFailures.append(
                        RemoteCompetitionRuntimeActivityFailure(
                            competitionID: competitionID,
                            failure: failure
                        )
                    )
                }
                nextCacheByID[descriptor.competitionID] = cacheEntry
            } catch {
                outcomes.append(
                    .failure(
                        RemoteCompetitionRuntimeIDFailure(
                            competitionID: competitionID,
                            failure: Self.failure(from: error)
                        )
                    )
                )
            }
        }
        do {
            try await cacheStore?.save(
                Array(nextCacheByID.values),
                profileID: profileID
            )
        } catch {
            return RemoteCompetitionRuntimeOutcome(
                outcomes: outcomes,
                discoveryFailure: .storageUnavailable,
                activityFailures: activityFailures
            )
        }
        return RemoteCompetitionRuntimeOutcome(
            outcomes: outcomes,
            discoveryFailure: nil,
            activityFailures: activityFailures
        )
    }

    private func offlineOutcome(
        cachedEntries: [RemoteCompetitionCacheEntry],
        discoveryFailure: RemoteCompetitionRuntimeFailure
    ) async -> RemoteCompetitionRuntimeOutcome {
        var outcomes: [RemoteCompetitionRuntimeIDOutcome] = []
        for entry in cachedEntries {
            let competitionID = CompetitionID(
                entry.descriptor.competitionID
            )
            do {
                guard entry.descriptor.participants.contains(where: {
                    $0.profileID == profileID
                }) else {
                    throw RemoteCompetitionRuntimeFailure.profileMismatch
                }
                guard let loaded = try await store.load(competitionID) else {
                    throw RemoteCompetitionRuntimeFailure
                        .competitionNotMaterialized
                }
                try validateCached(
                    descriptor: entry.descriptor,
                    journal: loaded
                )
                outcomes.append(
                    .success(
                        RemoteCompetitionMaterialization(
                            descriptor: entry.descriptor,
                            journal: loaded
                        )
                    )
                )
            } catch {
                outcomes.append(
                    .failure(
                        RemoteCompetitionRuntimeIDFailure(
                            competitionID: competitionID,
                            failure: Self.failure(from: error)
                        )
                    )
                )
            }
        }
        return RemoteCompetitionRuntimeOutcome(
            outcomes: outcomes,
            discoveryFailure: discoveryFailure
        )
    }

    private func validateCached(
        descriptor: CompetitionDescriptor,
        journal: LoadedCompetitionJournal
    ) throws {
        guard journal.projection.competition.id
                == CompetitionID(descriptor.competitionID),
              journal.journal.genesis.expiresAt
                == descriptor.invitationExpiresAt
        else {
            throw RemoteCompetitionRuntimeFailure.serverContractMismatch
        }
        switch descriptor.lifecycle {
        case .pending:
            guard descriptor.creatorProfileID == profileID,
                  journal.projection.competition.remoteConfiguration == nil
            else {
                throw RemoteCompetitionRuntimeFailure.serverContractMismatch
            }
        case .scheduled, .active, .endsToday, .tallying, .completed,
             .archived:
            guard let configuration = journal.projection.competition
                    .remoteConfiguration,
                  configuration.competitionID
                    == CompetitionID(descriptor.competitionID),
                  configuration.owner.profileID == profileID,
                  configuration.scoringPolicyIdentity
                    == descriptor.scoringPolicyIdentity,
                  configuration.acceptedSchedule
                    == (try Self.schedule(from: descriptor)),
                  descriptor.participants.contains(where: {
                      $0.profileID == configuration.remote.profileID
                  })
            else {
                throw RemoteCompetitionRuntimeFailure.serverContractMismatch
            }
        case .declined, .expired, .cancelled:
            throw RemoteCompetitionRuntimeFailure
                .competitionNotMaterialized
        }
    }

    private func synchronize(
        descriptor: CompetitionDescriptor,
        cachedEntry: RemoteCompetitionCacheEntry?
    ) async throws -> RemoteCompetitionSynchronizationOutcome {
        let competitionID = CompetitionID(descriptor.competitionID)
        let existing = try await store.load(competitionID)
        let canResume = cachedEntry.map {
            $0.descriptor.competitionID == descriptor.competitionID
                && $0.lastSeenServerSequence <= descriptor.serverCursor
        } ?? false
        let requiresFullHistory = existing == nil
            || !canResume
            || descriptor.lifecycle != .pending
                && existing?.projection.competition.remoteConfiguration == nil
        let history = try await fetchHistory(
            for: descriptor,
            after: requiresFullHistory
                ? 0
                : cachedEntry?.lastSeenServerSequence ?? 0
        )
        switch descriptor.lifecycle {
        case .pending:
            if !requiresFullHistory, let existing {
                guard history.isEmpty else {
                    throw RemoteCompetitionRuntimeFailure
                        .serverContractMismatch
                }
                try validateCached(
                    descriptor: descriptor,
                    journal: existing
                )
                return RemoteCompetitionSynchronizationOutcome(
                    materialization: RemoteCompetitionMaterialization(
                        descriptor: descriptor,
                        journal: existing
                    ),
                    activityFailure: nil
                )
            }
            return RemoteCompetitionSynchronizationOutcome(
                materialization: try await materializePending(
                    descriptor: descriptor,
                    history: history
                ),
                activityFailure: nil
            )
        case .scheduled, .active, .endsToday, .tallying, .completed,
             .archived:
            let materialized: RemoteCompetitionMaterialization
            if !requiresFullHistory, let existing {
                try validateCached(
                    descriptor: descriptor,
                    journal: existing
                )
                materialized = RemoteCompetitionMaterialization(
                    descriptor: descriptor,
                    journal: existing
                )
            } else {
                materialized = try await materializeScheduled(
                    descriptor: descriptor,
                    history: history
                )
            }
            let advanced = try await advanceClock(materialized)
            let reconciled = try await applyDownloadedChanges(
                requiresFullHistory
                    ? Array(history.dropFirst(3))
                    : history,
                to: advanced
            )
            let lifecycleReconciled = try await
                applyServerLifecycleChanges(
                    requiresFullHistory
                        ? Array(history.dropFirst(3))
                        : history,
                    to: reconciled
                )
            try validateServerTerminalLifecycle(
                descriptor: descriptor,
                journal: lifecycleReconciled.journal
            )
            try await removeMaterializedAttestationAcknowledgments(
                from: lifecycleReconciled
            )
            let refreshed = try await refreshOwnerScores(
                in: lifecycleReconciled
            )
            return RemoteCompetitionSynchronizationOutcome(
                materialization: try await enqueueFinalWindowAttestation(
                    for: refreshed.materialization
                ),
                activityFailure: refreshed.activityFailure
            )
        case .declined, .expired, .cancelled:
            throw RemoteCompetitionRuntimeFailure
                .competitionNotMaterialized
        }
    }

    private func advanceClock(
        _ materialization: RemoteCompetitionMaterialization
    ) async throws -> RemoteCompetitionMaterialization {
        let competitionID = materialization.journal
            .projection.competition.id
        let clockEvents = try engine.observeClock(
            materialization.journal.projection.competition,
            at: now()
        )
        guard !clockEvents.isEmpty else { return materialization }
        _ = try await store.append(
            clockEvents.map(CompetitionDomainEvent.lifecycle),
            to: competitionID,
            expectedCursor: materialization.journal.journal.cursor
        )
        guard let loaded = try await store.load(competitionID) else {
            throw RemoteCompetitionRuntimeFailure.storageUnavailable
        }
        return RemoteCompetitionMaterialization(
            descriptor: materialization.descriptor,
            journal: loaded
        )
    }

    private func refreshOwnerScores(
        in materialization: RemoteCompetitionMaterialization
    ) async throws -> RemoteOwnerScoreRefreshOutcome {
        guard let environment, let outboxStore, let syncCoordinator,
              let configuration = materialization.journal.projection
                .competition.remoteConfiguration
        else {
            return RemoteOwnerScoreRefreshOutcome(
                materialization: materialization,
                activityFailure: nil
            )
        }
        switch materialization.journal.projection.competition.lifecycle {
        case .active, .endsToday, .tallying:
            break
        case .pendingInvitation, .declined, .expired, .scheduled,
             .completed, .archived:
            return RemoteOwnerScoreRefreshOutcome(
                materialization: materialization,
                activityFailure: nil
            )
        }

        let window = try CompetitionActivityWindow(
            calendar: configuration.acceptedSchedule.calendar,
            startDay: configuration.acceptedSchedule.startDay
        )
        let read: ActivityWindowRead
        do {
            read = try await environment.read(window)
        } catch let failure as CompetitionActivitySourceError {
            return RemoteOwnerScoreRefreshOutcome(
                materialization: materialization,
                activityFailure: failure
            )
        }
        let evaluatedAt = now()
        let existingOutboxEntries = try await outboxStore.entries()
        let ownerLedger = materialization.journal.projection
            .remoteScoreLedgers[profileID]
        var maximumClientRevision: Int64 = 0
        var acceptedByOrdinal: [Int: RemoteAcceptedScoreRow] = [:]
        if let ownerLedger {
            for ordinal in 1...7 {
                if let row = try ownerLedger.visibleEntry(
                    forActiveDayOrdinal: ordinal
                ) {
                    acceptedByOrdinal[ordinal] = row
                    maximumClientRevision = max(
                        maximumClientRevision,
                        row.clientRevision
                    )
                }
            }
        }
        let pendingRequests = existingOutboxEntries.compactMap {
            entry -> CompetitionScoreRevisionRequest? in
            guard case let .scoreRevision(request) = entry.payload,
                  request.competitionID
                    == configuration.competitionID.rawValue
            else {
                return nil
            }
            return request
        }
        maximumClientRevision = max(
            maximumClientRevision,
            pendingRequests.map(\.clientRevision).max() ?? 0
        )

        for (offset, result) in read.days.enumerated() {
            let ordinal = offset + 1
            let dayStart = try window.calendar.startOfDay(result.day)
            guard dayStart <= evaluatedAt else { continue }

            let evidence = try Self.remoteEvidence(from: result)
            if let pending = pendingRequests
                .filter({ $0.dayOrdinal == ordinal })
                .max(by: { $0.clientRevision < $1.clientRevision }),
               try Self.wire(
                   competitionID: configuration.competitionID.rawValue,
                   profileID: profileID,
                   ordinal: ordinal,
                   evidence: evidence,
                   clientRevision: pending.clientRevision
               ).wireContentSHA256 == pending.wireContentSHA256 {
                continue
            }
            if let accepted = acceptedByOrdinal[ordinal],
               try Self.wire(
                   competitionID: configuration.competitionID.rawValue,
                   profileID: profileID,
                   ordinal: ordinal,
                   evidence: evidence,
                   clientRevision: accepted.clientRevision
               ).wireContentSHA256 == accepted.wireContentSHA256 {
                continue
            }

            guard maximumClientRevision < Int64.max else {
                throw RemoteCompetitionRuntimeFailure.serverContractMismatch
            }
            maximumClientRevision += 1
            let wire = try Self.wire(
                competitionID: configuration.competitionID.rawValue,
                profileID: profileID,
                ordinal: ordinal,
                evidence: evidence,
                clientRevision: maximumClientRevision
            )
            let request = try CompetitionScoreRevisionRequest(
                competitionID: wire.competitionID,
                semanticEventID: Self.semanticEventID(for: wire),
                dayOrdinal: wire.dayOrdinal,
                clientRevision: wire.clientRevision,
                evaluatedAt: evaluatedAt,
                moveMode: wire.moveMode,
                standMode: wire.standMode,
                moveBasisPoints: wire.moveBasisPoints,
                exerciseBasisPoints: wire.exerciseBasisPoints,
                standBasisPoints: wire.standBasisPoints,
                availabilityReason: wire.availabilityReason,
                scoringPolicyIdentity: wire.scoringPolicyIdentity,
                wireContentSHA256: wire.wireContentSHA256
            )
            _ = try await syncCoordinator.enqueue(
                .scoreRevision(request),
                enqueuedAt: evaluatedAt
            )
        }
        await syncCoordinator.waitUntilIdle()
        guard let loaded = try await store.load(
            configuration.competitionID
        ) else {
            throw RemoteCompetitionRuntimeFailure.storageUnavailable
        }
        return RemoteOwnerScoreRefreshOutcome(
            materialization: RemoteCompetitionMaterialization(
                descriptor: materialization.descriptor,
                journal: loaded
            ),
            activityFailure: nil
        )
    }

    private func enqueueFinalWindowAttestation(
        for materialization: RemoteCompetitionMaterialization
    ) async throws -> RemoteCompetitionMaterialization {
        guard let outboxStore, let syncCoordinator,
              case .tallying = materialization.journal.projection
                .competition.lifecycle,
              let configuration = materialization.journal.projection
                .competition.remoteConfiguration
        else {
            return materialization
        }

        let ownerLedger = materialization.journal.projection
            .remoteScoreLedgers[profileID]
        let rows: [RemoteAcceptedScoreRow?]
        if let ownerLedger {
            rows = try (1...7).map {
                try ownerLedger.visibleEntry(forActiveDayOrdinal: $0)
            }
        } else {
            rows = Array(repeating: nil, count: 7)
        }
        let acceptedRevisions = rows.map { $0?.clientRevision ?? 0 }
        let basis: CompetitionAttestationBasis
        if acceptedRevisions.allSatisfy({ $0 > 0 }) {
            basis = .stable
        } else if now() >= configuration.bestAvailableDeadline {
            basis = .bestAvailable
        } else {
            return materialization
        }
        let finalizationDays = try rows.enumerated().map {
            offset,
            row -> RemoteFinalizationDayV1 in
            let ordinal = offset + 1
            guard let row else {
                return try RemoteFinalizationDayV1(
                    ordinal: ordinal,
                    status: .unavailable,
                    source: .deadlineMissing,
                    points: nil,
                    reason: "missing",
                    wireContentSHA256: nil,
                    clientRevision: nil,
                    serverSequence: nil
                )
            }
            if let points = row.acceptedCentiPoints {
                return try RemoteFinalizationDayV1(
                    ordinal: ordinal,
                    status: .points,
                    source: .acceptedRevision,
                    points: points,
                    reason: nil,
                    wireContentSHA256: row.wireContentSHA256,
                    clientRevision: row.clientRevision,
                    serverSequence: row.serverSequence
                )
            }
            return try RemoteFinalizationDayV1(
                ordinal: ordinal,
                status: .unavailable,
                source: .acceptedRevision,
                points: nil,
                reason: row.availabilityReason,
                wireContentSHA256: row.wireContentSHA256,
                clientRevision: row.clientRevision,
                serverSequence: row.serverSequence
            )
        }
        let commitment = try RemoteFinalizationWireV1.windowCommitment(
            competitionID: configuration.competitionID.rawValue,
            participantID: profileID,
            days: finalizationDays
        )
        let existingEntries = try await outboxStore.entries()
        let queuedRequests = existingEntries.compactMap {
            entry -> CompetitionAttestationRequest? in
            guard case let .finalWindowAttestation(request) = entry.payload,
                  request.competitionID
                    == configuration.competitionID.rawValue
            else {
                return nil
            }
            return request
        }
        if queuedRequests.contains(where: {
            $0.basis == basis
                && $0.acceptedRevisions == acceptedRevisions
                && $0.windowCommitmentSHA256 == commitment
        }) {
            await syncCoordinator.wake()
            await syncCoordinator.waitUntilIdle()
            return materialization
        }
        if let accepted = materialization.journal.projection
            .remoteWindowAttestations[profileID],
           accepted.basis == Self.domainBasis(basis),
           accepted.acceptedRevisions == acceptedRevisions,
           accepted.windowCommitment == commitment {
            return materialization
        }
        let priorVersion = materialization.journal.projection
            .remoteWindowAttestations[profileID]?.attestationVersion ?? 0
        let queuedVersion = queuedRequests.map(\.attestationVersion).max()
            ?? 0
        let maximumVersion = max(priorVersion, queuedVersion)
        guard maximumVersion < Int64.max else {
            throw RemoteCompetitionRuntimeFailure.serverContractMismatch
        }
        let attestationVersion = maximumVersion + 1
        let request = try CompetitionAttestationRequest(
            competitionID: configuration.competitionID.rawValue,
            semanticEventID: Self.attestationSemanticEventID(
                competitionID: configuration.competitionID.rawValue,
                profileID: profileID,
                basis: basis,
                acceptedRevisions: acceptedRevisions,
                windowCommitmentSHA256: commitment,
                attestationVersion: attestationVersion
            ),
            attestationVersion: attestationVersion,
            basis: basis,
            acceptedRevisions: acceptedRevisions,
            windowCommitmentSHA256: commitment
        )
        _ = try await syncCoordinator.enqueue(
            .finalWindowAttestation(request),
            enqueuedAt: now()
        )
        await syncCoordinator.waitUntilIdle()
        return materialization
    }

    private func removeMaterializedAttestationAcknowledgments(
        from materialization: RemoteCompetitionMaterialization
    ) async throws {
        guard let outboxStore,
              let attestation = materialization.journal.projection
                .remoteWindowAttestations[profileID]
        else {
            return
        }
        for entry in try await outboxStore.entries() {
            guard case let .finalWindowAttestation(request) = entry.payload,
                  case let .attestationAcknowledged(receipt, _) = entry.state,
                  request.competitionID
                    == materialization.descriptor.competitionID,
                  request.basis == Self.transportBasis(attestation.basis),
                  request.acceptedRevisions
                    == attestation.acceptedRevisions,
                  request.windowCommitmentSHA256
                    == attestation.windowCommitment,
                  request.attestationVersion
                    == attestation.attestationVersion,
                  receipt.windowCommitmentSHA256
                    == attestation.windowCommitment,
                  receipt.entityServerSequence == attestation.serverSequence
            else {
                continue
            }
            try await outboxStore.remove(
                entry.semanticEventID,
                expectedGeneration: entry.generation
            )
        }
    }

    private static func attestationSemanticEventID(
        competitionID: UUID,
        profileID: UUID,
        basis: CompetitionAttestationBasis,
        acceptedRevisions: [Int64],
        windowCommitmentSHA256: String,
        attestationVersion: Int64
    ) -> UUID {
        let value = ([
            "healthcomp.remote-attestation-semantic-id.v1",
            competitionID.uuidString.lowercased(),
            profileID.uuidString.lowercased(),
            basis.rawValue,
            windowCommitmentSHA256,
            String(attestationVersion),
        ] + acceptedRevisions.map(String.init)).joined(separator: ":")
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }

    private static func transportBasis(
        _ basis: RemoteFinalizationBasis
    ) -> CompetitionAttestationBasis {
        switch basis {
        case .stable:
            .stable
        case .bestAvailable:
            .bestAvailable
        }
    }

    private struct RemoteEvidence: Sendable {
        let moveMode: String
        let standMode: String
        let moveBasisPoints: Int?
        let exerciseBasisPoints: Int?
        let standBasisPoints: Int?
        let availabilityReason: String
    }

    private static func remoteEvidence(
        from result: ActivityDayReadResult
    ) throws -> RemoteEvidence {
        switch result {
        case .missing:
            return RemoteEvidence(
                moveMode: ActivityMoveMode.activeEnergyKilocalories.rawValue,
                standMode: ActivityStandMode.unknown.rawValue,
                moveBasisPoints: nil,
                exerciseBasisPoints: nil,
                standBasisPoints: nil,
                availabilityReason: "sourceDataUnavailable"
            )
        case let .snapshot(_, snapshot):
            switch ActivityScoreCalculator.score(
                snapshot,
                policy: .healthKitCompatibility
            ) {
            case let .available(score):
                return RemoteEvidence(
                    moveMode: snapshot.moveMode.rawValue,
                    standMode: snapshot.standMode.rawValue,
                    moveBasisPoints: try RemoteScoringWireV1
                        .quantizePercent(score.movePercentage),
                    exerciseBasisPoints: try RemoteScoringWireV1
                        .quantizePercent(score.exercisePercentage),
                    standBasisPoints: try RemoteScoringWireV1
                        .quantizePercent(score.standOrRollPercentage),
                    availabilityReason: "available"
                )
            case let .unavailable(reasons):
                guard let reason = reasons.map(\.rawValue).sorted().first
                else {
                    throw RemoteCompetitionRuntimeFailure
                        .serverContractMismatch
                }
                return RemoteEvidence(
                    moveMode: snapshot.moveMode.rawValue,
                    standMode: snapshot.standMode.rawValue,
                    moveBasisPoints: nil,
                    exerciseBasisPoints: nil,
                    standBasisPoints: nil,
                    availabilityReason: reason
                )
            }
        }
    }

    private static func wire(
        competitionID: UUID,
        profileID: UUID,
        ordinal: Int,
        evidence: RemoteEvidence,
        clientRevision: Int64
    ) throws -> RemoteScoreRevisionWireV1 {
        try RemoteScoreRevisionWireV1(
            competitionID: competitionID,
            participantID: profileID,
            dayOrdinal: ordinal,
            moveMode: evidence.moveMode,
            standMode: evidence.standMode,
            moveBasisPoints: evidence.moveBasisPoints,
            exerciseBasisPoints: evidence.exerciseBasisPoints,
            standBasisPoints: evidence.standBasisPoints,
            availabilityReason: evidence.availabilityReason,
            scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            clientRevision: clientRevision
        )
    }

    private static func semanticEventID(
        for wire: RemoteScoreRevisionWireV1
    ) -> UUID {
        var data = Data("healthcomp.remote-score-semantic-id.v1".utf8)
        data.append(Data(wire.wireContentSHA256.utf8))
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }

    private func materializeScheduled(
        descriptor: CompetitionDescriptor,
        history: [CompetitionChange]
    ) async throws -> RemoteCompetitionMaterialization {
        guard descriptor.participants.count == 2,
              let ownerDescriptor = descriptor.participants.first(where: {
                  $0.profileID == profileID
              }),
              ownerDescriptor.state == .accepted,
              let remoteDescriptor = descriptor.participants.first(where: {
                  $0.profileID != profileID
              }),
              remoteDescriptor.state == .accepted,
              let creationChange = history.first,
              creationChange.serverSequence == 1,
              creationChange.kind == .participantAdded,
              creationChange.entityID == descriptor.creatorProfileID,
              case let .participant(creatorChange) = creationChange.payload,
              creatorChange.profileID == descriptor.creatorProfileID,
              creatorChange.role == .creator,
              creatorChange.state == .accepted,
              let inviteeChange = history.dropFirst().first,
              inviteeChange.serverSequence == 2,
              inviteeChange.kind == .participantAdded,
              case let .participant(invitee) = inviteeChange.payload,
              invitee.role == .invitee,
              invitee.state == .accepted,
              descriptor.participants.contains(where: {
                  $0.profileID == invitee.profileID && $0.role == .invitee
              }),
              let lifecycleChange = history.dropFirst(2).first,
              lifecycleChange.serverSequence == 3,
              lifecycleChange.kind == .competitionLifecycleChanged,
              lifecycleChange.entityID == descriptor.competitionID,
              case let .lifecycle(lifecycle) = lifecycleChange.payload,
              lifecycle.lifecycle == .scheduled,
              lifecycle.timeZoneIdentifier == descriptor.timeZoneIdentifier,
              lifecycle.startDay == descriptor.startDay,
              lifecycle.bestAvailableDeadline
                == descriptor.bestAvailableDeadline,
              lifecycle.scoringPolicyIdentity
                == descriptor.scoringPolicyIdentity,
              let bestAvailableDeadline = descriptor.bestAvailableDeadline
        else {
            throw RemoteCompetitionRuntimeFailure.serverContractMismatch
        }

        let schedule = try Self.schedule(from: descriptor)
        let competitionID = CompetitionID(descriptor.competitionID)
        let expectedGenesis = try CompetitionGenesis(
            competitionID: competitionID,
            direction: ownerDescriptor.role == .creator
                ? .outgoing
                : .incoming,
            createdAt: creationChange.occurredAt,
            expiresAt: descriptor.invitationExpiresAt,
            scoringPolicy: .healthKitCompatibility,
            downwardRevisionPolicy: .maximumObserved
        )
        let expectedConfiguration = try RemoteCompetitionConfiguration(
            competitionID: competitionID,
            owner: try RemoteParticipant(profileID: profileID),
            remote: try RemoteParticipant(
                profileID: remoteDescriptor.profileID
            ),
            acceptedSchedule: schedule,
            scoringPolicyIdentity: descriptor.scoringPolicyIdentity,
            backendDescriptorRevision: lifecycleChange.serverSequence,
            bestAvailableDeadline: bestAvailableDeadline
        )

        var loaded: LoadedCompetitionJournal
        if let existing = try await store.load(competitionID) {
            guard existing.journal.genesis == expectedGenesis else {
                throw RemoteCompetitionRuntimeFailure.serverContractMismatch
            }
            loaded = existing
        } else {
            do {
                _ = try await store.create(expectedGenesis)
            } catch CompetitionEventStoreError.identityAlreadyExists {
                // A concurrent synchronizer won the create race.
            }
            guard let created = try await store.load(competitionID),
                  created.journal.genesis == expectedGenesis
            else {
                throw RemoteCompetitionRuntimeFailure.serverContractMismatch
            }
            loaded = created
        }

        if let existingConfiguration =
            loaded.projection.competition.remoteConfiguration {
            guard existingConfiguration == expectedConfiguration else {
                throw RemoteCompetitionRuntimeFailure.serverContractMismatch
            }
        } else {
            _ = try await store.append(
                [.remoteConfigurationAccepted(expectedConfiguration)],
                to: competitionID,
                expectedCursor: loaded.journal.cursor
            )
            guard let configured = try await store.load(competitionID) else {
                throw RemoteCompetitionRuntimeFailure.storageUnavailable
            }
            loaded = configured
        }

        guard loaded.projection.competition.remoteConfiguration
                == expectedConfiguration
        else {
            throw RemoteCompetitionRuntimeFailure.serverContractMismatch
        }
        switch loaded.projection.competition.lifecycle {
        case .scheduled, .active, .endsToday, .tallying, .completed,
             .archived:
            break
        case .pendingInvitation, .declined, .expired:
            throw RemoteCompetitionRuntimeFailure.serverContractMismatch
        }
        return RemoteCompetitionMaterialization(
            descriptor: descriptor,
            journal: loaded
        )
    }

    private func applyDownloadedChanges(
        _ changes: [CompetitionChange],
        to materialization: RemoteCompetitionMaterialization
    ) async throws -> RemoteCompetitionMaterialization {
        guard !changes.isEmpty else { return materialization }
        guard let configuration = materialization.journal.projection
                .competition.remoteConfiguration
        else {
            throw RemoteCompetitionRuntimeFailure.serverContractMismatch
        }
        let events = try changes.compactMap {
            change -> CompetitionDomainEvent? in
            switch change.payload {
            case let .score(score):
                guard change.kind == .scoreRevisionRecorded,
                      change.entityID == score.participantProfileID,
                      score.participantProfileID
                        == configuration.owner.profileID
                        || score.participantProfileID
                        == configuration.remote.profileID
                else {
                    throw RemoteCompetitionRuntimeFailure
                        .serverContractMismatch
                }
                let row = try RemoteAcceptedScoreRow(
                    ordinal: score.dayOrdinal,
                    acceptedCentiPoints: score.acceptedCentiPoints,
                    availabilityReason: score.availabilityReason == "available"
                        ? nil
                        : score.availabilityReason,
                    wireContentSHA256: score.wireContentSHA256,
                    scoringPolicyIdentity: score.scoringPolicyIdentity,
                    clientRevision: score.clientRevision,
                    serverSequence: score.serverSequence
                )
                return CompetitionDomainEvent.remoteScoreRevisionRecorded(
                    try RemoteScoreRevision(
                        competitionID: configuration.competitionID,
                        participant: try RemoteParticipant(
                            profileID: score.participantProfileID
                        ),
                        row: row,
                        recordedAt: score.evaluatedAt
                    )
                )
            case let .participantAttestation(attestation):
                guard change.kind == .participantAttested,
                      change.entityID == attestation.participantProfileID,
                      attestation.participantProfileID
                        == configuration.owner.profileID
                        || attestation.participantProfileID
                        == configuration.remote.profileID
                else {
                    throw RemoteCompetitionRuntimeFailure
                        .serverContractMismatch
                }
                // Each device persists only its owner's attestation. The
                // opponent's attestation remains server-owned result input.
                guard attestation.participantProfileID
                        == configuration.owner.profileID
                else { return nil }
                return .remoteFinalWindowAttested(
                    try RemoteFinalWindowAttestation(
                        competitionID: configuration.competitionID,
                        participant: configuration.owner,
                        windowCommitment: attestation
                            .windowCommitmentSHA256,
                        basis: Self.domainBasis(attestation.basis),
                        acceptedRevisions: attestation.acceptedRevisions,
                        attestationVersion: attestation.attestationVersion,
                        serverSequence: attestation.serverSequence,
                        attestedAt: attestation.attestedAt
                    )
                )
            case let .result(result):
                guard change.kind == .competitionResultConfirmed,
                      change.entityID
                        == configuration.competitionID.rawValue,
                      Set([
                          result.participantAProfileID,
                          result.participantBProfileID,
                      ]) == Set([
                          configuration.owner.profileID,
                          configuration.remote.profileID,
                      ])
                else {
                    throw RemoteCompetitionRuntimeFailure
                        .serverContractMismatch
                }
                let windows = try result.frozenWindow.participants.map {
                    window in
                    try SharedParticipantWindow(
                        competitionID: configuration.competitionID,
                        participant: try RemoteParticipant(
                            profileID: window.profileID
                        ),
                        totalCentiPoints: window.totalCentiPoints,
                        windowCommitment: window
                            .windowCommitmentSHA256,
                        days: try window.days.map { day in
                            try SharedResultDay(
                                ordinal: day.ordinal,
                                status: day.status == .points
                                    ? .points
                                    : .unavailable,
                                source: day.source == .acceptedRevision
                                    ? .acceptedRevision
                                    : .deadlineMissing,
                                centiPoints: day.centiPoints,
                                reason: day.reason,
                                wireContentSHA256: day
                                    .wireContentSHA256,
                                clientRevision: day.clientRevision,
                                serverSequence: day.serverSequence,
                                scoringPolicyIdentity: day
                                    .scoringPolicyIdentity
                            )
                        }
                    )
                }
                return .sharedResultConfirmed(
                    try SharedCompetitionResult(
                        competitionID: configuration.competitionID,
                        owner: configuration.owner,
                        remote: configuration.remote,
                        windows: windows,
                        frozenWindowVersion: CompetitionFrozenWindow.version,
                        scoringPolicyIdentity: result.frozenWindow.policy,
                        winner: try result.winnerProfileID.map {
                            try RemoteParticipant(profileID: $0)
                        },
                        basis: Self.domainBasis(result.finalizationBasis),
                        resultHash: result.immutableHash,
                        confirmedAt: result.completedAt,
                        serverSequence: result.serverSequence
                    )
                )
            case .participant, .lifecycle, .profilePresentation, .award:
                return nil
            }
        }
        do {
            _ = try await store.append(
                events,
                to: configuration.competitionID,
                expectedCursor: materialization.journal.journal.cursor
            )
        } catch CompetitionEventStoreError.journal {
            throw RemoteCompetitionRuntimeFailure.serverContractMismatch
        }
        guard let loaded = try await store.load(
            configuration.competitionID
        ) else {
            throw RemoteCompetitionRuntimeFailure.storageUnavailable
        }
        return RemoteCompetitionMaterialization(
            descriptor: materialization.descriptor,
            journal: loaded
        )
    }

    private func applyServerLifecycleChanges(
        _ changes: [CompetitionChange],
        to materialization: RemoteCompetitionMaterialization
    ) async throws -> RemoteCompetitionMaterialization {
        var current = materialization
        for change in changes {
            guard case let .lifecycle(lifecycle) = change.payload else {
                continue
            }
            guard change.kind == .competitionLifecycleChanged,
                  change.entityID == materialization
                    .descriptor.competitionID,
                  lifecycle.timeZoneIdentifier
                    == materialization.descriptor.timeZoneIdentifier,
                  lifecycle.startDay
                    == materialization.descriptor.startDay,
                  lifecycle.bestAvailableDeadline
                    == materialization.descriptor.bestAvailableDeadline,
                  lifecycle.scoringPolicyIdentity
                    == materialization.descriptor.scoringPolicyIdentity
            else {
                throw RemoteCompetitionRuntimeFailure.serverContractMismatch
            }
            guard lifecycle.lifecycle == .archived else { continue }
            switch current.journal.projection.competition.lifecycle {
            case let .archived(archived):
                guard archived.archivedAt == change.occurredAt else {
                    throw RemoteCompetitionRuntimeFailure
                        .serverContractMismatch
                }
            case .completed:
                let event = try engine.archive(
                    current.journal.projection.competition,
                    at: change.occurredAt
                )
                do {
                    _ = try await store.append(
                        [.lifecycle(event)],
                        to: current.journal.projection.competition.id,
                        expectedCursor: current.journal.journal.cursor
                    )
                } catch CompetitionEventStoreError.journal {
                    throw RemoteCompetitionRuntimeFailure
                        .serverContractMismatch
                }
                guard let loaded = try await store.load(
                    current.journal.projection.competition.id
                ) else {
                    throw RemoteCompetitionRuntimeFailure.storageUnavailable
                }
                current = RemoteCompetitionMaterialization(
                    descriptor: materialization.descriptor,
                    journal: loaded
                )
            case .pendingInvitation, .declined, .expired, .scheduled,
                 .active, .endsToday, .tallying:
                throw RemoteCompetitionRuntimeFailure
                    .serverContractMismatch
            }
        }
        return current
    }

    private func validateServerTerminalLifecycle(
        descriptor: CompetitionDescriptor,
        journal: LoadedCompetitionJournal
    ) throws {
        let localLifecycle = journal.projection.competition.lifecycle
        switch descriptor.lifecycle {
        case .completed:
            guard case .completed = localLifecycle else {
                throw RemoteCompetitionRuntimeFailure.serverContractMismatch
            }
        case .archived:
            guard case .archived = localLifecycle else {
                throw RemoteCompetitionRuntimeFailure.serverContractMismatch
            }
        case .scheduled, .active, .endsToday, .tallying:
            switch localLifecycle {
            case .scheduled, .active, .endsToday, .tallying:
                break
            case .pendingInvitation, .declined, .expired, .completed, .archived:
                throw RemoteCompetitionRuntimeFailure.serverContractMismatch
            }
        case .pending, .declined, .expired, .cancelled:
            throw RemoteCompetitionRuntimeFailure.serverContractMismatch
        }
    }

    private static func domainBasis(
        _ basis: CompetitionAttestationBasis
    ) -> RemoteFinalizationBasis {
        switch basis {
        case .stable:
            .stable
        case .bestAvailable:
            .bestAvailable
        }
    }

    private func fetchHistory(
        for descriptor: CompetitionDescriptor,
        after initialCursor: Int64 = 0
    ) async throws -> [CompetitionChange] {
        guard initialCursor >= 0,
              initialCursor <= descriptor.serverCursor
        else {
            throw RemoteCompetitionRuntimeFailure.serverContractMismatch
        }
        var cursor = initialCursor
        var snapshot: Int64?
        var changes: [CompetitionChange] = []
        repeat {
            let page = try await remoteAPI.fetchChanges(
                try CompetitionSynchronizationCursor(
                    competitionID: descriptor.competitionID,
                    lastSeenServerSequence: cursor
                ),
                200
            )
            guard page.competitionID == descriptor.competitionID,
                  page.afterServerSequence == cursor,
                  page.snapshotServerSequence == descriptor.serverCursor,
                  page.nextServerSequence <= descriptor.serverCursor,
                  !page.hasMore || page.nextServerSequence > cursor,
                  snapshot == nil || snapshot == page.snapshotServerSequence
            else {
                throw RemoteCompetitionRuntimeFailure.serverContractMismatch
            }
            snapshot = page.snapshotServerSequence
            changes.append(contentsOf: page.changes)
            cursor = page.nextServerSequence
            if !page.hasMore { break }
        } while true

        guard snapshot == descriptor.serverCursor,
              cursor == descriptor.serverCursor
        else {
            throw RemoteCompetitionRuntimeFailure.serverContractMismatch
        }
        return changes
    }

    private func materializePending(
        descriptor: CompetitionDescriptor,
        history: [CompetitionChange]
    ) async throws -> RemoteCompetitionMaterialization {
        guard descriptor.creatorProfileID == profileID,
              descriptor.participants.count == 1,
              let creator = descriptor.participants.first,
              creator.profileID == profileID,
              creator.role == .creator,
              creator.state == .accepted,
              let creationChange = history.first,
              creationChange.serverSequence == 1,
              creationChange.kind == .participantAdded,
              creationChange.entityID == profileID,
              case let .participant(participant) = creationChange.payload,
              participant.profileID == profileID,
              participant.role == .creator,
              participant.state == .accepted,
              history.count == 1
        else {
            throw RemoteCompetitionRuntimeFailure.serverContractMismatch
        }

        let competitionID = CompetitionID(descriptor.competitionID)
        let expectedGenesis = try CompetitionGenesis(
            competitionID: competitionID,
            direction: .outgoing,
            createdAt: creationChange.occurredAt,
            expiresAt: descriptor.invitationExpiresAt,
            scoringPolicy: .healthKitCompatibility,
            downwardRevisionPolicy: .maximumObserved
        )
        if let existing = try await store.load(competitionID) {
            guard existing.journal.genesis == expectedGenesis,
                  existing.projection.competition.remoteConfiguration == nil
            else {
                throw RemoteCompetitionRuntimeFailure.serverContractMismatch
            }
            return RemoteCompetitionMaterialization(
                descriptor: descriptor,
                journal: existing
            )
        }

        do {
            _ = try await store.create(expectedGenesis)
        } catch CompetitionEventStoreError.identityAlreadyExists {
            // A concurrent synchronizer won the create race. Validate below.
        }
        guard let loaded = try await store.load(competitionID),
              loaded.journal.genesis == expectedGenesis,
              loaded.projection.competition.remoteConfiguration == nil
        else {
            throw RemoteCompetitionRuntimeFailure.serverContractMismatch
        }
        return RemoteCompetitionMaterialization(
            descriptor: descriptor,
            journal: loaded
        )
    }

    private static func failure(
        from error: Error
    ) -> RemoteCompetitionRuntimeFailure {
        if error is CancellationError { return .cancelled }
        switch error as? CompetitionRemoteFailure {
        case .cancelled:
            return .cancelled
        case .unauthenticated:
            return .unauthenticated
        case .forbidden:
            return .forbidden
        case .serverContractMismatch:
            return .serverContractMismatch
        default:
            break
        }
        if let failure = error as? RemoteCompetitionRuntimeFailure {
            return failure
        }
        if error is CompetitionEventStoreError {
            return .storageUnavailable
        }
        if error is RemoteCompetitionCacheFailure {
            return .storageUnavailable
        }
        return .discoveryUnavailable
    }

    private static func schedule(
        from descriptor: CompetitionDescriptor
    ) throws -> CompetitionSchedule {
        guard let timeZoneIdentifier = descriptor.timeZoneIdentifier,
              let startDay = descriptor.startDay
        else {
            throw RemoteCompetitionRuntimeFailure.serverContractMismatch
        }
        let components = startDay.split(separator: "-")
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2])
        else {
            throw RemoteCompetitionRuntimeFailure.serverContractMismatch
        }
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: timeZoneIdentifier
        )
        return CompetitionSchedule(
            calendar: calendar,
            startDay: try CompetitionDay(
                era: 1,
                year: year,
                month: month,
                day: day,
                timeZoneIdentifier: timeZoneIdentifier
            )
        )
    }

    private static func sortDescriptors(
        _ lhs: CompetitionDescriptor,
        _ rhs: CompetitionDescriptor
    ) -> Bool {
        lhs.competitionID.uuidString < rhs.competitionID.uuidString
    }
}
