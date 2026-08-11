import CompetitionCore
import Darwin
import Foundation

struct JSONCompetitionEventStoreFileProtection: Sendable {
    typealias Apply = @Sendable (
        _ url: URL,
        _ protection: FileProtectionType
    ) throws -> Void

    private let applyOperation: Apply

    init(apply: @escaping Apply) {
        self.applyOperation = apply
    }

    static let live = Self { url, protection in
        try FileManager.default.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: url.path
        )
    }

    func observing(_ observer: @escaping Apply) -> Self {
        let applyOperation = applyOperation
        return Self { url, protection in
            try applyOperation(url, protection)
            try observer(url, protection)
        }
    }

    func apply(
        _ protection: FileProtectionType,
        to url: URL
    ) throws {
        try applyOperation(url, protection)
    }
}

struct JSONCompetitionEventStoreFaultInjector: Sendable {
    enum CandidateRole: String, Equatable, Sendable {
        case primary
        case previous
    }

    struct ReadFailure: Equatable, Sendable {
        let role: CandidateRole
        let code: Int32
    }

    enum FaultPoint: String, CaseIterable, Sendable {
        case newTemporaryCreated
        case newTemporaryWritten
        case newTemporarySynced
        case backupTemporaryCreated
        case backupTemporaryWritten
        case backupTemporarySynced
        case backupRenamed
        case backupDirectorySynced
        case primaryRenamed
        case primaryDirectorySynced
        case recoveryTemporaryCreated
        case recoveryTemporaryWritten
        case recoveryTemporarySynced
        case corruptPrimaryQuarantined
        case quarantineDirectorySynced
        case recoveryPrimaryRenamed
        case recoveryDirectorySynced
        case tombstoneTemporaryCreated
        case tombstoneTemporaryWritten
        case tombstoneTemporarySynced
        case tombstoneRenamed
        case tombstoneDirectorySynced
        case cleanupUnlinked
        case cleanupDirectorySynced
    }

    enum WriteBehavior: Equatable, Sendable {
        case interrupted
        case maximumBytes(Int)
        case zero
        case fail(code: Int32)
        case system
    }

    enum EncodedCandidateBehavior: Equatable, Sendable {
        case system
        case replaceWith(Data)
    }

    let crashAt: FaultPoint?
    let writeBehaviors: [WriteBehavior]
    let encodedCandidateBehavior: EncodedCandidateBehavior
    let readFailure: ReadFailure?
    let fullSyncFailureCode: Int32?

    init(
        crashAt: FaultPoint? = nil,
        writeBehaviors: [WriteBehavior] = [],
        encodedCandidateBehavior: EncodedCandidateBehavior = .system,
        readFailure: ReadFailure? = nil,
        fullSyncFailureCode: Int32? = nil
    ) {
        self.crashAt = crashAt
        self.writeBehaviors = writeBehaviors
        self.encodedCandidateBehavior = encodedCandidateBehavior
        self.readFailure = readFailure
        self.fullSyncFailureCode = fullSyncFailureCode
    }

    static let none = Self()

    func checkpoint(_ point: FaultPoint) throws {
        guard crashAt == point else { return }
        throw JSONCompetitionEventStoreError.injectedCrash(point)
    }

    func writeBehavior(at invocation: Int) -> WriteBehavior {
        guard writeBehaviors.indices.contains(invocation) else {
            return .system
        }
        return writeBehaviors[invocation]
    }

    func encodedCandidate(from systemData: Data) -> Data {
        switch encodedCandidateBehavior {
        case .system:
            return systemData
        case let .replaceWith(data):
            return data
        }
    }

    func readFailureCode(for role: CandidateRole) -> Int32? {
        guard readFailure?.role == role else { return nil }
        return readFailure?.code
    }
}

enum JSONCompetitionEventStoreError: Error, Equatable, Sendable {
    case invalidRootDirectory
    case corruptPrimaryAndPrevious
    case divergentSnapshots
    case invalidEncodedCandidate
    case posix(operation: String, code: Int32)
    case shortWrite
    case injectedCrash(JSONCompetitionEventStoreFaultInjector.FaultPoint)
}

public actor JSONCompetitionEventStore: CompetitionEventStore {
    private let rootDirectory: URL
    private let worker: CompetitionEventStoreIOWorker
    private let faultInjector: JSONCompetitionEventStoreFaultInjector
    private let fileProtection: JSONCompetitionEventStoreFileProtection

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.worker = CompetitionEventStoreIOWorker()
        self.faultInjector = .none
        self.fileProtection = .live
    }

    init(
        rootDirectory: URL,
        faultInjector: JSONCompetitionEventStoreFaultInjector,
        fileProtection: JSONCompetitionEventStoreFileProtection = .live
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.worker = CompetitionEventStoreIOWorker()
        self.faultInjector = faultInjector
        self.fileProtection = fileProtection
    }

    public static func live() throws -> JSONCompetitionEventStore {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return JSONCompetitionEventStore(
            rootDirectory: applicationSupport
                .appendingPathComponent("HealthComp", isDirectory: true)
                .appendingPathComponent("CompetitionEvents", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
        )
    }

    public func ids() async throws -> [CompetitionID] {
        let rootDirectory = rootDirectory
        let faultInjector = faultInjector
        let fileProtection = fileProtection
        return try await worker.perform {
            let storage = CompetitionEventStoreSynchronousStorage(
                rootDirectory: rootDirectory,
                faultInjector: faultInjector,
                fileProtection: fileProtection
            )
            return try storage.withExclusiveLock {
                try storage.ids()
            }
        }
    }

    public func load(
        _ id: CompetitionID
    ) async throws -> LoadedCompetitionJournal? {
        let rootDirectory = rootDirectory
        let faultInjector = faultInjector
        let fileProtection = fileProtection
        return try await worker.perform {
            let storage = CompetitionEventStoreSynchronousStorage(
                rootDirectory: rootDirectory,
                faultInjector: faultInjector,
                fileProtection: fileProtection
            )
            return try storage.withExclusiveLock {
                guard try !storage.isTombstoned(id) else {
                    try storage.cleanupDeletedIdentity(id)
                    return nil
                }
                guard let resolved = try storage.resolve(id) else {
                    try storage.reapStaleTemporaryFiles(for: id)
                    return nil
                }
                try storage.reapStaleTemporaryFiles(for: id)
                do {
                    return try LoadedCompetitionJournal(
                        journal: resolved.stored.journal,
                        source: resolved.source
                    )
                } catch let error as CompetitionJournalError {
                    throw CompetitionEventStoreError.journal(error)
                }
            }
        }
    }

    public func create(
        _ genesis: CompetitionGenesis
    ) async throws -> CompetitionEventStoreCreateResult {
        let rootDirectory = rootDirectory
        let faultInjector = faultInjector
        let fileProtection = fileProtection
        return try await worker.perform {
            let storage = CompetitionEventStoreSynchronousStorage(
                rootDirectory: rootDirectory,
                faultInjector: faultInjector,
                fileProtection: fileProtection
            )
            return try storage.withExclusiveLock {
                guard try !storage.isTombstoned(genesis.competitionID) else {
                    try storage.cleanupDeletedIdentity(genesis.competitionID)
                    throw CompetitionEventStoreError.identityWasDeleted
                }
                if let resolved = try storage.resolve(genesis.competitionID) {
                    guard resolved.stored.journal.genesis == genesis else {
                        throw CompetitionEventStoreError.identityAlreadyExists
                    }
                    try storage.reapStaleTemporaryFiles(
                        for: genesis.competitionID
                    )
                    return CompetitionEventStoreCreateResult(
                        cursor: resolved.stored.journal.cursor,
                        created: false
                    )
                }
                try storage.reapStaleTemporaryFiles(
                    for: genesis.competitionID
                )
                let journal = try CompetitionJournal(genesis: genesis)
                try storage.replacePrimary(
                    with: try storage.validatedEncoding(of: journal),
                    id: genesis.competitionID,
                    previousPrimary: nil
                )
                return CompetitionEventStoreCreateResult(
                    cursor: journal.cursor,
                    created: true
                )
            }
        }
    }

    public func append(
        _ events: [CompetitionDomainEvent],
        to id: CompetitionID,
        expectedCursor: CompetitionJournalCursor
    ) async throws -> CompetitionJournalAppendResult {
        let rootDirectory = rootDirectory
        let faultInjector = faultInjector
        let fileProtection = fileProtection
        return try await worker.perform {
            let storage = CompetitionEventStoreSynchronousStorage(
                rootDirectory: rootDirectory,
                faultInjector: faultInjector,
                fileProtection: fileProtection
            )
            return try storage.withExclusiveLock {
                guard try !storage.isTombstoned(id) else {
                    try storage.cleanupDeletedIdentity(id)
                    throw CompetitionEventStoreError.identityWasDeleted
                }
                guard let resolved = try storage.resolve(id) else {
                    throw CompetitionEventStoreError.identityNotFound
                }
                let stored = resolved.stored
                var journal = stored.journal
                let result: CompetitionJournalAppendResult
                do {
                    result = try journal.append(
                        events,
                        expectedCursor: expectedCursor
                    )
                } catch let error as CompetitionJournalError {
                    if case let .cursorConflict(expected, actual) = error {
                        throw CompetitionEventStoreError.cursorConflict(
                            expected: expected,
                            actual: actual
                        )
                    }
                    throw CompetitionEventStoreError.journal(error)
                }
                try storage.reapStaleTemporaryFiles(for: id)
                guard result.appendedCount > 0 else { return result }
                try storage.replacePrimary(
                    with: try storage.validatedEncoding(of: journal),
                    id: id,
                    previousPrimary: stored.data
                )
                return result
            }
        }
    }

    public func delete(
        _ id: CompetitionID,
        expectedCursor: CompetitionJournalCursor
    ) async throws {
        let rootDirectory = rootDirectory
        let faultInjector = faultInjector
        let fileProtection = fileProtection
        try await worker.perform {
            let storage = CompetitionEventStoreSynchronousStorage(
                rootDirectory: rootDirectory,
                faultInjector: faultInjector,
                fileProtection: fileProtection
            )
            try storage.withExclusiveLock {
                if try storage.isTombstoned(id) {
                    try storage.cleanupDeletedIdentity(id)
                    return
                }
                guard let resolved = try storage.resolve(id) else {
                    throw CompetitionEventStoreError.identityNotFound
                }
                guard resolved.stored.journal.cursor == expectedCursor else {
                    throw CompetitionEventStoreError.cursorConflict(
                        expected: expectedCursor,
                        actual: resolved.stored.journal.cursor
                    )
                }
                try storage.reapStaleTemporaryFiles(for: id)
                try storage.commitTombstone(id)
                try storage.cleanupDeletedIdentity(id)
            }
        }
    }
}

private final class CompetitionEventStoreIOWorker: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.narenyenuganti.HealthComp.competition-event-store"
    )

    func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }
}

private struct CompetitionEventStoreSynchronousStorage {
    struct StoredJournal: Sendable {
        let data: Data
        let journal: CompetitionJournal
    }

    struct ResolvedJournal: Sendable {
        let stored: StoredJournal
        let source: CompetitionJournalLoadSource
    }

    private enum Candidate {
        case absent
        case valid(StoredJournal)
        case corrupt(Data?)
        case upgradeRequired(CompetitionJournalError)
    }

    private let rootDirectory: URL
    private let fileManager = FileManager.default
    private let faultInjector: JSONCompetitionEventStoreFaultInjector
    private let fileProtection: JSONCompetitionEventStoreFileProtection

    init(
        rootDirectory: URL,
        faultInjector: JSONCompetitionEventStoreFaultInjector,
        fileProtection: JSONCompetitionEventStoreFileProtection
    ) {
        self.rootDirectory = rootDirectory
        self.faultInjector = faultInjector
        self.fileProtection = fileProtection
    }

    func withExclusiveLock<Value>(
        _ operation: () throws -> Value
    ) throws -> Value {
        try prepareRootDirectory()
        let lockURL = rootDirectory.appendingPathComponent("store.lock")
        let lockDescriptor = try openFile(
            lockURL,
            flags: O_RDWR | O_CREAT | O_CLOEXEC | O_EXLOCK | O_NOFOLLOW,
            mode: mode_t(0o600),
            operation: "open store lock"
        )
        defer { _ = Darwin.close(lockDescriptor) }
        var lockMetadata = stat()
        guard Darwin.fstat(lockDescriptor, &lockMetadata) == 0 else {
            throw posixError("inspect store lock")
        }
        guard lockMetadata.st_mode & S_IFMT == S_IFREG else {
            throw JSONCompetitionEventStoreError.posix(
                operation: "inspect store lock",
                code: EINVAL
            )
        }
        guard Darwin.fchmod(lockDescriptor, mode_t(0o600)) == 0 else {
            throw posixError("chmod store lock")
        }
        try setFileProtection(at: lockURL)
        return try operation()
    }

    func reapStaleTemporaryFiles(for id: CompetitionID) throws {
        let urls = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        )
        var removedAny = false
        for url in urls {
            guard temporaryIdentity(from: url.lastPathComponent) == id else {
                continue
            }
            while true {
                if Darwin.unlink(url.path) == 0 {
                    removedAny = true
                    break
                }
                if errno == EINTR { continue }
                if errno == ENOENT { break }
                throw posixError("unlink stale journal temporary")
            }
        }
        if removedAny {
            try synchronizeDirectory()
        }
    }

    private func temporaryIdentity(
        from filename: String
    ) -> CompetitionID? {
        let temporaryRoles: Set<Substring> = [
            "new",
            "backup",
            "recovery",
            "tombstone",
        ]
        let components = filename.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count == 5,
              components[0].isEmpty,
              let identity = UUID(uuidString: String(components[1])),
              temporaryRoles.contains(components[2]),
              UUID(uuidString: String(components[3])) != nil,
              components[4] == "tmp"
        else {
            return nil
        }
        return CompetitionID(identity)
    }

    func resolve(_ id: CompetitionID) throws -> ResolvedJournal? {
        let primary = try readCandidate(
            primaryURL(id),
            expectedID: id,
            role: .primary
        )
        let previous = try readCandidate(
            previousURL(id),
            expectedID: id,
            role: .previous
        )

        if case let .upgradeRequired(error) = primary {
            throw CompetitionEventStoreError.journal(error)
        }
        if case let .upgradeRequired(error) = previous {
            throw CompetitionEventStoreError.journal(error)
        }

        switch (primary, previous) {
        case (.absent, .absent):
            return nil

        case let (.valid(primary), .absent),
             let (.valid(primary), .corrupt):
            return ResolvedJournal(stored: primary, source: .primary)

        case let (.valid(primary), .valid(previous)):
            switch primary.journal.relationship(to: previous.journal) {
            case .equal, .descendant:
                return ResolvedJournal(stored: primary, source: .primary)
            case .prefix:
                try recover(
                    id: id,
                    previous: previous,
                    quarantinePrimary: true
                )
                return ResolvedJournal(
                    stored: previous,
                    source: .recoveredPrevious
                )
            case .divergent:
                throw JSONCompetitionEventStoreError.divergentSnapshots
            }

        case let (.corrupt, .valid(previous)):
            try recover(
                id: id,
                previous: previous,
                quarantinePrimary: true
            )
            return ResolvedJournal(
                stored: previous,
                source: .recoveredPrevious
            )

        case let (.absent, .valid(previous)):
            try recover(
                id: id,
                previous: previous,
                quarantinePrimary: false
            )
            return ResolvedJournal(
                stored: previous,
                source: .recoveredPrevious
            )

        case (.absent, .corrupt),
             (.corrupt, .absent),
             (.corrupt, .corrupt):
            throw JSONCompetitionEventStoreError.corruptPrimaryAndPrevious

        case (.valid, .upgradeRequired),
             (.corrupt, .upgradeRequired),
             (.absent, .upgradeRequired),
             (.upgradeRequired, _):
            preconditionFailure("Upgrade-required candidates were handled above")
        }
    }

    private func readCandidate(
        _ url: URL,
        expectedID: CompetitionID,
        role: JSONCompetitionEventStoreFaultInjector.CandidateRole
    ) throws -> Candidate {
        guard let data = try readCandidateData(at: url, role: role) else {
            return .absent
        }
        do {
            let journal = try decoder().decode(
                CompetitionJournal.self,
                from: data
            )
            guard journal.genesis.competitionID == expectedID else {
                return .corrupt(data)
            }
            return .valid(
                StoredJournal(
                    data: data,
                    journal: journal
                )
            )
        } catch let error as CompetitionJournalError {
            return isUpgradeRequired(error)
                ? .upgradeRequired(error)
                : .corrupt(data)
        } catch {
            return .corrupt(data)
        }
    }

    private func readCandidateData(
        at url: URL,
        role: JSONCompetitionEventStoreFaultInjector.CandidateRole
    ) throws -> Data? {
        let operation = "read journal \(role.rawValue)"
        if let code = faultInjector.readFailureCode(for: role) {
            throw JSONCompetitionEventStoreError.posix(
                operation: operation,
                code: code
            )
        }

        let descriptor: Int32
        while true {
            let result = url.path.withCString {
                Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            if result >= 0 {
                descriptor = result
                break
            }
            if errno == EINTR { continue }
            if errno == ENOENT { return nil }
            throw posixError(operation)
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw posixError(operation)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw JSONCompetitionEventStoreError.posix(
                operation: operation,
                code: EINVAL
            )
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(
                    descriptor,
                    rawBuffer.baseAddress,
                    rawBuffer.count
                )
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 { return data }
            if errno == EINTR { continue }
            throw posixError(operation)
        }
    }

    private func isUpgradeRequired(_ error: CompetitionJournalError) -> Bool {
        switch error {
        case .upgradeRequiredGenesisVersion,
             .upgradeRequiredJournalVersion,
             .upgradeRequiredEnvelopeVersion,
             .upgradeRequiredPayloadVersion:
            return true
        default:
            return false
        }
    }

    private func recover(
        id: CompetitionID,
        previous: StoredJournal,
        quarantinePrimary: Bool
    ) throws {
        let recoveryURL = try writeTemporary(
            previous.data,
            role: "recovery",
            id: id
        )
        var shouldRemoveRecovery = true
        defer {
            if shouldRemoveRecovery {
                try? fileManager.removeItem(at: recoveryURL)
            }
        }
        do {
            if quarantinePrimary {
                let quarantineURL = rootDirectory.appendingPathComponent(
                    "\(fileStem(id)).corrupt.\(UUID().uuidString.lowercased()).json"
                )
                guard Darwin.rename(
                    primaryURL(id).path,
                    quarantineURL.path
                ) == 0 else {
                    throw posixError("quarantine corrupt primary")
                }
                try faultInjector.checkpoint(.corruptPrimaryQuarantined)
                try synchronizeDirectory()
                try faultInjector.checkpoint(.quarantineDirectorySynced)
            }
            guard Darwin.rename(recoveryURL.path, primaryURL(id).path) == 0 else {
                throw posixError("rename recovery primary")
            }
            shouldRemoveRecovery = false
            try faultInjector.checkpoint(.recoveryPrimaryRenamed)
            try synchronizeDirectory()
            try faultInjector.checkpoint(.recoveryDirectorySynced)
        } catch {
            if isInjectedCrash(error) {
                shouldRemoveRecovery = false
            }
            throw error
        }
    }

    func ids() throws -> [CompetitionID] {
        let primarySuffix = ".journal.json"
        let previousSuffix = ".journal.previous.json"
        let tombstoneSuffix = ".deleted"
        let candidateIDs = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        .reduce(into: Set<CompetitionID>()) { ids, url in
            let name = url.lastPathComponent
            let suffix: String
            if name.hasSuffix(previousSuffix) {
                suffix = previousSuffix
            } else if name.hasSuffix(primarySuffix) {
                suffix = primarySuffix
            } else if name.hasSuffix(tombstoneSuffix) {
                suffix = tombstoneSuffix
            } else if let id = temporaryIdentity(from: name) {
                ids.insert(id)
                return
            } else {
                return
            }
            let stem = String(name.dropLast(suffix.count))
            guard let uuid = UUID(uuidString: stem) else { return }
            ids.insert(CompetitionID(uuid))
        }
        let sortedIDs = candidateIDs.sorted {
            $0.rawValue.uuidString.lowercased()
                < $1.rawValue.uuidString.lowercased()
        }
        var resolvedIDs: [CompetitionID] = []
        resolvedIDs.reserveCapacity(sortedIDs.count)
        for id in sortedIDs {
            if try isTombstoned(id) {
                try cleanupDeletedIdentity(id)
                continue
            }
            if try resolve(id) != nil {
                try reapStaleTemporaryFiles(for: id)
                resolvedIDs.append(id)
            } else {
                try reapStaleTemporaryFiles(for: id)
            }
        }
        return resolvedIDs
    }

    func isTombstoned(_ id: CompetitionID) throws -> Bool {
        var metadata = stat()
        let result = tombstoneURL(id).path.withCString {
            Darwin.lstat($0, &metadata)
        }
        if result == 0 { return true }
        if errno == ENOENT { return false }
        throw posixError("inspect tombstone")
    }

    func commitTombstone(_ id: CompetitionID) throws {
        let payload = Data(
            "healthcomp.competition-deleted:v1:\(fileStem(id))".utf8
        )
        let temporaryURL = try writeTemporary(
            payload,
            role: "tombstone",
            id: id
        )
        var shouldRemove = true
        defer {
            if shouldRemove { try? fileManager.removeItem(at: temporaryURL) }
        }
        do {
            guard Darwin.rename(
                temporaryURL.path,
                tombstoneURL(id).path
            ) == 0 else {
                throw posixError("rename tombstone")
            }
            shouldRemove = false
            try faultInjector.checkpoint(.tombstoneRenamed)
            try synchronizeDirectory()
            try faultInjector.checkpoint(.tombstoneDirectorySynced)
        } catch {
            if isInjectedCrash(error) {
                shouldRemove = false
            }
            throw error
        }
    }

    func cleanupDeletedIdentity(_ id: CompetitionID) throws {
        let stem = fileStem(id)
        let knownNames = Set([
            primaryURL(id).lastPathComponent,
            previousURL(id).lastPathComponent,
        ])
        let urls = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        )
        for url in urls {
            let name = url.lastPathComponent
            let isTemporary = name.hasPrefix(".\(stem).")
                && name.hasSuffix(".tmp")
            let isQuarantine = name.hasPrefix("\(stem).corrupt.")
                && name.hasSuffix(".json")
            guard knownNames.contains(name) || isTemporary || isQuarantine else {
                continue
            }
            while Darwin.unlink(url.path) != 0 {
                if errno == EINTR { continue }
                if errno == ENOENT { break }
                throw posixError("unlink deleted competition file")
            }
        }
        try faultInjector.checkpoint(.cleanupUnlinked)
        try synchronizeDirectory()
        try faultInjector.checkpoint(.cleanupDirectorySynced)
    }

    func validatedEncoding(of journal: CompetitionJournal) throws -> Data {
        let data = faultInjector.encodedCandidate(
            from: try encoder().encode(journal)
        )
        do {
            let decoded = try decoder().decode(
                CompetitionJournal.self,
                from: data
            )
            _ = try LoadedCompetitionJournal(
                journal: decoded,
                source: .primary
            )
            guard decoded == journal else {
                throw JSONCompetitionEventStoreError.invalidEncodedCandidate
            }
            return data
        } catch let error as CompetitionJournalError {
            throw CompetitionEventStoreError.journal(error)
        } catch let error as JSONCompetitionEventStoreError {
            throw error
        } catch {
            throw JSONCompetitionEventStoreError.invalidEncodedCandidate
        }
    }

    func replacePrimary(
        with data: Data,
        id: CompetitionID,
        previousPrimary: Data?
    ) throws {
        let primaryURL = primaryURL(id)
        let temporaryURL = try writeTemporary(
            data,
            role: "new",
            id: id
        )
        var temporaryURLs = [temporaryURL]
        defer {
            for url in temporaryURLs {
                try? fileManager.removeItem(at: url)
            }
        }
        do {
            if let previousPrimary {
                let backupTemporaryURL = try writeTemporary(
                    previousPrimary,
                    role: "backup",
                    id: id
                )
                temporaryURLs.append(backupTemporaryURL)
                guard Darwin.rename(
                    backupTemporaryURL.path,
                    previousURL(id).path
                ) == 0 else {
                    throw posixError("rename journal previous")
                }
                temporaryURLs.removeAll { $0 == backupTemporaryURL }
                try faultInjector.checkpoint(.backupRenamed)
                try synchronizeDirectory()
                try faultInjector.checkpoint(.backupDirectorySynced)
            }
            guard Darwin.rename(temporaryURL.path, primaryURL.path) == 0 else {
                throw posixError("rename journal primary")
            }
            temporaryURLs.removeAll { $0 == temporaryURL }
            try faultInjector.checkpoint(.primaryRenamed)
            try synchronizeDirectory()
            try faultInjector.checkpoint(.primaryDirectorySynced)
        } catch {
            if isInjectedCrash(error) {
                temporaryURLs.removeAll()
            }
            throw error
        }
    }

    private func writeTemporary(
        _ data: Data,
        role: String,
        id: CompetitionID
    ) throws -> URL {
        let temporaryURL = rootDirectory.appendingPathComponent(
            ".\(fileStem(id)).\(role).\(UUID().uuidString.lowercased()).tmp"
        )
        let descriptor = try openFile(
            temporaryURL,
            flags: O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode: mode_t(0o600),
            operation: "create \(role) temporary"
        )
        var isOpen = true
        var shouldRemove = true
        defer {
            if isOpen { _ = Darwin.close(descriptor) }
            if shouldRemove { try? fileManager.removeItem(at: temporaryURL) }
        }
        do {
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw posixError("chmod \(role) temporary")
            }
            try setFileProtection(at: temporaryURL)
            try checkpointTemporary(role: role, phase: .created)
            try writeAll(data, to: descriptor)
            try checkpointTemporary(role: role, phase: .written)
            try synchronize(descriptor, operation: "fsync \(role) temporary")
            try fullySynchronizeFile(
                descriptor,
                operation: "full fsync \(role) temporary"
            )
            try checkpointTemporary(role: role, phase: .synced)
            guard Darwin.close(descriptor) == 0 else {
                isOpen = false
                throw posixError("close \(role) temporary")
            }
            isOpen = false
            shouldRemove = false
            return temporaryURL
        } catch {
            if isInjectedCrash(error) {
                shouldRemove = false
            }
            throw error
        }
    }

    private enum TemporaryPhase {
        case created
        case written
        case synced
    }

    private func checkpointTemporary(
        role: String,
        phase: TemporaryPhase
    ) throws {
        let point: JSONCompetitionEventStoreFaultInjector.FaultPoint?
        switch (role, phase) {
        case ("new", .created): point = .newTemporaryCreated
        case ("new", .written): point = .newTemporaryWritten
        case ("new", .synced): point = .newTemporarySynced
        case ("backup", .created): point = .backupTemporaryCreated
        case ("backup", .written): point = .backupTemporaryWritten
        case ("backup", .synced): point = .backupTemporarySynced
        case ("recovery", .created): point = .recoveryTemporaryCreated
        case ("recovery", .written): point = .recoveryTemporaryWritten
        case ("recovery", .synced): point = .recoveryTemporarySynced
        case ("tombstone", .created): point = .tombstoneTemporaryCreated
        case ("tombstone", .written): point = .tombstoneTemporaryWritten
        case ("tombstone", .synced): point = .tombstoneTemporarySynced
        default: point = nil
        }
        if let point { try faultInjector.checkpoint(point) }
    }

    private func prepareRootDirectory() throws {
        guard rootDirectory.isFileURL else {
            throw JSONCompetitionEventStoreError.invalidRootDirectory
        }
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [
                .posixPermissions: NSNumber(value: 0o700),
                .protectionKey: FileProtectionType
                    .completeUntilFirstUserAuthentication,
            ]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: rootDirectory.path
        )
        try fileProtection.apply(
            .completeUntilFirstUserAuthentication,
            to: rootDirectory
        )
    }

    private func setFileProtection(at url: URL) throws {
        try fileProtection.apply(
            .completeUntilFirstUserAuthentication,
            to: url
        )
    }

    private func primaryURL(_ id: CompetitionID) -> URL {
        rootDirectory.appendingPathComponent("\(fileStem(id)).journal.json")
    }

    private func previousURL(_ id: CompetitionID) -> URL {
        rootDirectory.appendingPathComponent(
            "\(fileStem(id)).journal.previous.json"
        )
    }

    private func tombstoneURL(_ id: CompetitionID) -> URL {
        rootDirectory.appendingPathComponent("\(fileStem(id)).deleted")
    }

    private func fileStem(_ id: CompetitionID) -> String {
        id.rawValue.uuidString.lowercased()
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            var invocation = 0
            while offset < rawBuffer.count {
                let remaining = min(rawBuffer.count - offset, Int(Int32.max))
                let behavior = faultInjector.writeBehavior(at: invocation)
                invocation += 1
                let written: Int
                switch behavior {
                case .interrupted:
                    errno = EINTR
                    written = -1
                case let .maximumBytes(maximum):
                    guard maximum > 0 else {
                        throw JSONCompetitionEventStoreError.shortWrite
                    }
                    written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        min(remaining, maximum)
                    )
                case .zero:
                    written = 0
                case let .fail(code):
                    errno = code
                    written = -1
                case .system:
                    written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        remaining
                    )
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    if written == 0 {
                        throw JSONCompetitionEventStoreError.shortWrite
                    }
                    throw posixError("write journal temporary")
                }
                offset += written
            }
        }
    }

    private func synchronize(_ descriptor: Int32, operation: String) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw posixError(operation)
        }
    }

    private func synchronizeDirectory() throws {
        let descriptor = try openFile(
            rootDirectory,
            flags: O_RDONLY | O_DIRECTORY | O_CLOEXEC,
            mode: nil,
            operation: "open store directory"
        )
        defer { _ = Darwin.close(descriptor) }
        try synchronize(descriptor, operation: "fsync store directory")
    }

    private func fullySynchronizeFile(
        _ descriptor: Int32,
        operation: String
    ) throws {
        if let code = faultInjector.fullSyncFailureCode {
            throw JSONCompetitionEventStoreError.posix(
                operation: operation,
                code: code
            )
        }
        while Darwin.fcntl(descriptor, F_FULLFSYNC) != 0 {
            if errno == EINTR { continue }
            throw posixError(operation)
        }
    }

    private func openFile(
        _ url: URL,
        flags: Int32,
        mode: mode_t?,
        operation: String
    ) throws -> Int32 {
        while true {
            let descriptor: Int32
            if let mode {
                descriptor = url.path.withCString {
                    Darwin.open($0, flags, mode)
                }
            } else {
                descriptor = url.path.withCString {
                    Darwin.open($0, flags)
                }
            }
            if descriptor >= 0 { return descriptor }
            if errno == EINTR { continue }
            throw posixError(operation)
        }
    }

    private func posixError(
        _ operation: String
    ) -> JSONCompetitionEventStoreError {
        JSONCompetitionEventStoreError.posix(
            operation: operation,
            code: errno
        )
    }

    private func isInjectedCrash(_ error: Error) -> Bool {
        guard let storeError = error as? JSONCompetitionEventStoreError else {
            return false
        }
        if case .injectedCrash = storeError { return true }
        return false
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.nonConformingFloatEncodingStrategy = .throw
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        decoder.nonConformingFloatDecodingStrategy = .throw
        return decoder
    }
}
