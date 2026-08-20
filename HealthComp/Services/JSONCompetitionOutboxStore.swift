import Darwin
import Foundation

enum JSONCompetitionOutboxStoreFaultPoint:
    String,
    CaseIterable,
    Sendable
{
    case newTemporarySynced
    case primaryMovedToPrevious
    case primaryDirectorySynced
}

struct JSONCompetitionOutboxStoreFaultInjector: Sendable {
    let crashAt: JSONCompetitionOutboxStoreFaultPoint?

    init(crashAt: JSONCompetitionOutboxStoreFaultPoint? = nil) {
        self.crashAt = crashAt
    }

    static let none = Self()

    func checkpoint(_ point: JSONCompetitionOutboxStoreFaultPoint) throws {
        guard crashAt == point else { return }
        throw CompetitionOutboxStoreFailure.injectedCrash(point)
    }
}

actor JSONCompetitionOutboxStore: CompetitionOutboxStore {
    private let rootDirectory: URL
    private let faultInjector: JSONCompetitionOutboxStoreFaultInjector
    private let fileProtection: JSONCompetitionEventStoreFileProtection
    private let fileManager = FileManager.default

    init(
        rootDirectory: URL,
        fileProtection: JSONCompetitionEventStoreFileProtection = .live
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.faultInjector = .none
        self.fileProtection = fileProtection
    }

    init(
        rootDirectory: URL,
        faultInjector: JSONCompetitionOutboxStoreFaultInjector,
        fileProtection: JSONCompetitionEventStoreFileProtection = .live
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.faultInjector = faultInjector
        self.fileProtection = fileProtection
    }

    func enqueue(
        _ payload: CompetitionOutboxPayload,
        enqueuedAt: Date
    ) async throws -> CompetitionOutboxEntry {
        let canonicalPayload = try Self.canonicalPayload(payload)
        return try withExclusiveLock {
            var document = try readDocument()
            if let existing = document.entries.first(where: {
                $0.semanticEventID == canonicalPayload.semanticEventID
            }) {
                guard existing.payload == canonicalPayload else {
                    throw CompetitionOutboxStoreFailure.semanticEventConflict(
                        canonicalPayload.semanticEventID
                    )
                }
                return existing
            }
            guard document.revision < UInt64.max else {
                throw CompetitionOutboxStoreFailure.generationOverflow
            }
            let entry = try CompetitionOutboxEntry(
                semanticEventID: canonicalPayload.semanticEventID,
                enqueuedAt: enqueuedAt,
                generation: 1,
                payload: canonicalPayload,
                state: .pending(attemptCount: 0, retryAt: nil)
            )
            document.entries.append(entry)
            document.revision += 1
            try persist(document)
            return entry
        }
    }

    private static func canonicalPayload(
        _ payload: CompetitionOutboxPayload
    ) throws -> CompetitionOutboxPayload {
        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch let failure as CompetitionOutboxStoreFailure {
            throw failure
        } catch {
            throw CompetitionOutboxStoreFailure.invalidDocument
        }
        let verified: CompetitionOutboxPayload
        do {
            verified = try decoder.decode(
                CompetitionOutboxPayload.self,
                from: data
            )
        } catch {
            throw CompetitionOutboxStoreFailure.invalidDocument
        }
        let verifiedData: Data
        do {
            verifiedData = try encoder.encode(verified)
        } catch let failure as CompetitionOutboxStoreFailure {
            throw failure
        } catch {
            throw CompetitionOutboxStoreFailure.invalidDocument
        }
        guard verifiedData == data else {
            throw CompetitionOutboxStoreFailure.invalidDocument
        }
        return verified
    }

    func entries() async throws -> [CompetitionOutboxEntry] {
        try withExclusiveLock { try readDocument().entries }
    }

    func update(
        _ semanticEventID: UUID,
        expectedGeneration: UInt64,
        state: CompetitionOutboxState
    ) async throws -> CompetitionOutboxEntry {
        try withExclusiveLock {
            var document = try readDocument()
            guard let index = document.entries.firstIndex(where: {
                $0.semanticEventID == semanticEventID
            }) else {
                throw CompetitionOutboxStoreFailure.entryNotFound(
                    semanticEventID
                )
            }
            let existing = document.entries[index]
            guard existing.generation == expectedGeneration else {
                throw CompetitionOutboxStoreFailure.generationConflict(
                    expected: expectedGeneration,
                    actual: existing.generation
                )
            }
            if existing.state == state { return existing }
            guard existing.generation < UInt64.max,
                  document.revision < UInt64.max
            else {
                throw CompetitionOutboxStoreFailure.generationOverflow
            }
            let updated = try CompetitionOutboxEntry(
                semanticEventID: existing.semanticEventID,
                enqueuedAt: existing.enqueuedAt,
                generation: existing.generation + 1,
                payload: existing.payload,
                state: state
            )
            document.entries[index] = updated
            document.revision += 1
            try persist(document)
            return updated
        }
    }

    func remove(
        _ semanticEventID: UUID,
        expectedGeneration: UInt64
    ) async throws {
        try withExclusiveLock {
            var document = try readDocument()
            guard let index = document.entries.firstIndex(where: {
                $0.semanticEventID == semanticEventID
            }) else {
                return
            }
            let existing = document.entries[index]
            guard existing.generation == expectedGeneration else {
                throw CompetitionOutboxStoreFailure.generationConflict(
                    expected: expectedGeneration,
                    actual: existing.generation
                )
            }
            guard document.revision < UInt64.max else {
                throw CompetitionOutboxStoreFailure.generationOverflow
            }
            document.entries.remove(at: index)
            document.revision += 1
            try persist(document)
        }
    }

    private func withExclusiveLock<Value>(
        _ operation: () throws -> Value
    ) throws -> Value {
        try validateRootDirectory()
        let lockURL = rootDirectory.appendingPathComponent("outbox.lock")
        let descriptor = lockURL.path.withCString { path in
            Darwin.open(
                path,
                O_RDWR | O_CREAT | O_CLOEXEC | O_EXLOCK | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw CompetitionOutboxStoreFailure.unsafeFilesystemEntry
            }
            throw posixFailure("open outbox lock")
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              Darwin.fchmod(descriptor, mode_t(0o600)) == 0
        else {
            throw CompetitionOutboxStoreFailure.unsafeFilesystemEntry
        }
        try fileProtection.apply(
            .completeUntilFirstUserAuthentication,
            to: lockURL
        )
        try reapStaleTemporaryFiles()
        return try operation()
    }

    private func validateRootDirectory() throws {
        guard rootDirectory.isFileURL else {
            throw CompetitionOutboxStoreFailure.invalidRootDirectory
        }
        let descriptor = rootDirectory.path.withCString { path in
            Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw CompetitionOutboxStoreFailure.invalidRootDirectory
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              Darwin.fchmod(descriptor, mode_t(0o700)) == 0
        else {
            throw CompetitionOutboxStoreFailure.invalidRootDirectory
        }
        try fileProtection.apply(
            .completeUntilFirstUserAuthentication,
            to: rootDirectory
        )
    }

    private func readDocument() throws -> StoredDocument {
        let primary = try readCandidate(at: primaryURL)
        let previous = try readCandidate(at: previousURL)
        switch (primary, previous) {
        case let (.valid(document, _), _):
            return document
        case let (.corrupt, .valid(document, data)),
             let (.absent, .valid(document, data)):
            try recoverPrimary(from: data)
            return document
        case (.absent, .absent):
            return .empty
        case (.corrupt, .absent),
             (.corrupt, .corrupt),
             (.absent, .corrupt):
            throw CompetitionOutboxStoreFailure.invalidDocument
        }
    }

    private func readCandidate(at url: URL) throws -> Candidate {
        let descriptor = url.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return .absent }
            if errno == ELOOP {
                throw CompetitionOutboxStoreFailure.unsafeFilesystemEntry
            }
            throw posixFailure("open outbox candidate")
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw posixFailure("inspect outbox candidate")
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw CompetitionOutboxStoreFailure.unsafeFilesystemEntry
        }
        guard metadata.st_size >= 0,
              metadata.st_size <= StoredDocument.maximumEncodedBytes else {
            return .corrupt
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= StoredDocument.maximumEncodedBytes else {
                    return .corrupt
                }
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw posixFailure("read outbox document")
        }
        do {
            return .valid(
                try Self.decoder.decode(StoredDocument.self, from: data),
                data
            )
        } catch {
            return .corrupt
        }
    }

    private func persist(_ document: StoredDocument) throws {
        let data: Data
        do {
            data = try Self.encoder.encode(document)
        } catch let failure as CompetitionOutboxStoreFailure {
            throw failure
        } catch {
            throw CompetitionOutboxStoreFailure.invalidDocument
        }
        guard data.count <= StoredDocument.maximumEncodedBytes else {
            throw CompetitionOutboxStoreFailure.invalidDocument
        }
        let verified: StoredDocument
        do {
            verified = try Self.decoder.decode(
                StoredDocument.self,
                from: data
            )
        } catch {
            throw CompetitionOutboxStoreFailure.invalidDocument
        }
        // Nested wire timestamps intentionally encode at whole-second
        // precision, so validate their canonical bytes instead of requiring
        // lossy in-memory Date values to remain exactly equal.
        let verifiedData: Data
        do {
            verifiedData = try Self.encoder.encode(verified)
        } catch let failure as CompetitionOutboxStoreFailure {
            throw failure
        } catch {
            throw CompetitionOutboxStoreFailure.invalidDocument
        }
        guard verifiedData == data else {
            throw CompetitionOutboxStoreFailure.invalidDocument
        }
        let temporaryURL = try writeTemporary(data, role: "new")
        do {
            try faultInjector.checkpoint(.newTemporarySynced)
            switch try entryKind(at: primaryURL) {
            case .absent:
                break
            case .regularFile:
                switch try entryKind(at: previousURL) {
                case .absent:
                    break
                case .regularFile:
                    try unlink(previousURL, operation: "unlink old previous")
                case .directory, .other:
                    throw CompetitionOutboxStoreFailure
                        .unsafeFilesystemEntry
                }
                guard Darwin.rename(primaryURL.path, previousURL.path) == 0
                else {
                    throw posixFailure("rename outbox previous")
                }
                try synchronizeDirectory()
                try faultInjector.checkpoint(.primaryMovedToPrevious)
            case .directory, .other:
                throw CompetitionOutboxStoreFailure.unsafeFilesystemEntry
            }
            guard Darwin.rename(temporaryURL.path, primaryURL.path) == 0 else {
                throw posixFailure("rename outbox document")
            }
            try synchronizeDirectory()
            try faultInjector.checkpoint(.primaryDirectorySynced)
        } catch {
            if !isInjectedCrash(error) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            throw error
        }
    }

    private func recoverPrimary(from data: Data) throws {
        let temporaryURL = try writeTemporary(data, role: "recovery")
        do {
            switch try entryKind(at: primaryURL) {
            case .absent:
                break
            case .regularFile:
                try unlink(primaryURL, operation: "unlink corrupt primary")
            case .directory, .other:
                throw CompetitionOutboxStoreFailure.unsafeFilesystemEntry
            }
            guard Darwin.rename(temporaryURL.path, primaryURL.path) == 0 else {
                throw posixFailure("rename recovered outbox document")
            }
            try synchronizeDirectory()
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func writeTemporary(_ data: Data, role: String) throws -> URL {
        let url = rootDirectory.appendingPathComponent(
            ".outbox.\(role).\(UUID().uuidString.lowercased()).tmp"
        )
        let descriptor = url.path.withCString { path in
            Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw posixFailure("create outbox temporary")
        }
        var isOpen = true
        var shouldRemove = true
        defer {
            if isOpen { _ = Darwin.close(descriptor) }
            if shouldRemove { try? fileManager.removeItem(at: url) }
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw posixFailure("chmod outbox temporary")
        }
        try fileProtection.apply(
            .completeUntilFirstUserAuthentication,
            to: url
        )
        try writeAll(data, to: descriptor)
        try synchronize(descriptor, operation: "fsync outbox temporary")
        try fullySynchronize(
            descriptor,
            operation: "full fsync outbox temporary"
        )
        guard Darwin.close(descriptor) == 0 else {
            isOpen = false
            throw posixFailure("close outbox temporary")
        }
        isOpen = false
        shouldRemove = false
        return url
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
                    throw posixFailure("write outbox temporary")
                }
                offset += count
            }
        }
    }

    private func synchronize(
        _ descriptor: Int32,
        operation: String
    ) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw posixFailure(operation)
        }
    }

    private func fullySynchronize(
        _ descriptor: Int32,
        operation: String
    ) throws {
        while Darwin.fcntl(descriptor, F_FULLFSYNC) != 0 {
            if errno == EINTR { continue }
            throw posixFailure(operation)
        }
    }

    private func synchronizeDirectory() throws {
        let descriptor = rootDirectory.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw posixFailure("open outbox directory")
        }
        defer { _ = Darwin.close(descriptor) }
        try synchronize(descriptor, operation: "fsync outbox directory")
    }

    private func reapStaleTemporaryFiles() throws {
        let entries = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        var removedAny = false
        for url in entries where isTemporaryFilename(url.lastPathComponent) {
            guard try entryKind(at: url) == .regularFile else {
                throw CompetitionOutboxStoreFailure.unsafeFilesystemEntry
            }
            try unlink(url, operation: "unlink stale outbox temporary")
            removedAny = true
        }
        if removedAny { try synchronizeDirectory() }
    }

    private func isTemporaryFilename(_ value: String) -> Bool {
        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count == 5,
              components[0].isEmpty,
              components[1] == "outbox",
              components[2] == "new" || components[2] == "recovery",
              UUID(uuidString: String(components[3])) != nil,
              components[4] == "tmp"
        else {
            return false
        }
        return true
    }

    private func unlink(_ url: URL, operation: String) throws {
        while Darwin.unlink(url.path) != 0 {
            if errno == EINTR { continue }
            if errno == ENOENT { return }
            throw posixFailure(operation)
        }
    }

    private enum EntryKind {
        case absent
        case regularFile
        case directory
        case other
    }

    private func entryKind(at url: URL) throws -> EntryKind {
        var metadata = stat()
        let result = url.path.withCString { path in
            Darwin.lstat(path, &metadata)
        }
        guard result == 0 else {
            if errno == ENOENT { return .absent }
            throw posixFailure("inspect outbox entry")
        }
        switch metadata.st_mode & S_IFMT {
        case S_IFREG:
            return .regularFile
        case S_IFDIR:
            return .directory
        default:
            return .other
        }
    }

    private var primaryURL: URL {
        rootDirectory.appendingPathComponent("outbox.json")
    }

    private var previousURL: URL {
        rootDirectory.appendingPathComponent("outbox.previous.json")
    }

    private func posixFailure(
        _ operation: String
    ) -> CompetitionOutboxStoreFailure {
        .io(operation: operation, code: errno)
    }

    private func isInjectedCrash(_ error: any Error) -> Bool {
        guard case .injectedCrash = error as? CompetitionOutboxStoreFailure
        else {
            return false
        }
        return true
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.nonConformingFloatEncodingStrategy = .throw
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        decoder.nonConformingFloatDecodingStrategy = .throw
        return decoder
    }()

    private enum Candidate {
        case absent
        case valid(StoredDocument, Data)
        case corrupt
    }
}

private struct StoredDocument: Codable, Equatable, Sendable {
    static let version: UInt32 = 1
    static let maximumEncodedBytes = 4 * 1024 * 1024
    static let empty = Self(revision: 0, entries: [])

    let schemaVersion: UInt32
    var revision: UInt64
    var entries: [CompetitionOutboxEntry]

    init(revision: UInt64, entries: [CompetitionOutboxEntry]) {
        self.schemaVersion = Self.version
        self.revision = revision
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case revision
        case entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            UInt32.self,
            forKey: .schemaVersion
        )
        let revision = try container.decode(UInt64.self, forKey: .revision)
        let entries = try container.decode(
            [CompetitionOutboxEntry].self,
            forKey: .entries
        )
        guard schemaVersion == Self.version,
              revision >= UInt64(entries.isEmpty ? 0 : 1),
              Set(entries.map(\.semanticEventID)).count == entries.count
        else {
            throw CompetitionOutboxStoreFailure.invalidDocument
        }
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.entries = entries
    }
}
