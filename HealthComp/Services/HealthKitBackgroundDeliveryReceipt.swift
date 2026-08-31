import CompetitionCore
import Darwin
import Foundation

struct HealthKitBackgroundDeliveryReceipt: Codable, Equatable, Sendable {
    let signalID: String
    let trigger: ActivityRefreshTrigger
    let processedAt: Date
    let publicationRevision: UInt64
    let hadIssues: Bool

    enum CodingKeys: String, CodingKey {
        case signalID = "signal_id"
        case trigger
        case processedAt = "processed_at"
        case publicationRevision = "publication_revision"
        case hadIssues = "had_issues"
    }
}

struct HealthKitBackgroundDeliveryReceiptClient: Sendable {
    let contains: @Sendable (_ signalID: String) async throws -> Bool
    let commit: @Sendable (
        HealthKitBackgroundDeliveryReceipt
    ) async throws -> Void

    init(
        contains: @escaping @Sendable (String) async throws -> Bool = {
            _ in false
        },
        commit: @escaping @Sendable (
            HealthKitBackgroundDeliveryReceipt
        ) async throws -> Void
    ) {
        self.contains = contains
        self.commit = commit
    }

    static func live(
        directory: URL,
        fileProtection: JSONCompetitionEventStoreFileProtection = .live
    ) -> Self {
        let store = HealthKitBackgroundDeliveryReceiptStore(
            directory: directory,
            fileProtection: fileProtection
        )
        return Self(
            contains: { signalID in
                try await store.contains(signalID)
            },
            commit: { receipt in
                try await store.commit(receipt)
            }
        )
    }

    static let discarding = Self(commit: { _ in })
}

enum HealthKitBackgroundDeliveryReceiptStoreFailure:
    Error,
    Equatable,
    Sendable
{
    case invalidDirectory
    case unsafeFilesystemEntry
    case invalidReceipt
    case invalidDocument
    case signalConflict
    case ioFailure
}

enum HealthKitBackgroundDeliveryReceiptStoreFaultPoint: Sendable {
    case temporaryFullSync
    case temporarySynced
    case destinationFullSync
    case directorySync
}

struct HealthKitBackgroundDeliveryReceiptStoreFaultInjector: Sendable {
    let failAt: HealthKitBackgroundDeliveryReceiptStoreFaultPoint?

    init(
        failAt: HealthKitBackgroundDeliveryReceiptStoreFaultPoint? = nil
    ) {
        self.failAt = failAt
    }

    static let none = Self()

    func checkpoint(
        _ point: HealthKitBackgroundDeliveryReceiptStoreFaultPoint
    ) throws {
        guard failAt == point else { return }
        throw HealthKitBackgroundDeliveryReceiptStoreFailure.ioFailure
    }
}

actor HealthKitBackgroundDeliveryReceiptStore {
    private struct Document: Codable, Equatable {
        static let currentVersion: UInt32 = 1
        static let maximumReceiptCount = 128
        static let maximumEncodedBytes = 64 * 1024

        let schemaVersion: UInt32
        var receipts: [HealthKitBackgroundDeliveryReceipt]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case receipts
        }

        init(receipts: [HealthKitBackgroundDeliveryReceipt]) {
            self.schemaVersion = Self.currentVersion
            self.receipts = receipts
        }
    }

    private enum EntryKind {
        case absent
        case regularFile
        case directory
        case other
    }

    private let directory: URL
    private let fileURL: URL
    private let faultInjector:
        HealthKitBackgroundDeliveryReceiptStoreFaultInjector
    private let fileProtection: JSONCompetitionEventStoreFileProtection

    init(
        directory: URL,
        fileProtection: JSONCompetitionEventStoreFileProtection = .live
    ) {
        self.directory = directory.standardizedFileURL
        self.fileURL = directory.standardizedFileURL.appendingPathComponent(
            "background-delivery-receipts.v1.json",
            isDirectory: false
        )
        self.faultInjector = .none
        self.fileProtection = fileProtection
    }

    init(
        directory: URL,
        faultInjector:
            HealthKitBackgroundDeliveryReceiptStoreFaultInjector,
        fileProtection: JSONCompetitionEventStoreFileProtection = .live
    ) {
        self.directory = directory.standardizedFileURL
        self.fileURL = directory.standardizedFileURL.appendingPathComponent(
            "background-delivery-receipts.v1.json",
            isDirectory: false
        )
        self.faultInjector = faultInjector
        self.fileProtection = fileProtection
    }

    func commit(_ receipt: HealthKitBackgroundDeliveryReceipt) throws {
        let receipt = try Self.canonicalReceipt(receipt)
        try validateDirectory()
        try reapStaleTemporaryFiles()
        var document = try readDocument()
        if let existing = document.receipts.first(where: {
            $0.signalID == receipt.signalID
        }) {
            guard existing == receipt else {
                throw HealthKitBackgroundDeliveryReceiptStoreFailure
                    .signalConflict
            }
            try ensureReceiptFileIsDurable()
            return
        }
        document.receipts.append(receipt)
        if document.receipts.count > Document.maximumReceiptCount {
            document.receipts.removeFirst(
                document.receipts.count - Document.maximumReceiptCount
            )
        }
        try persist(document)
    }

    func contains(_ signalID: String) throws -> Bool {
        guard Self.isValidSignalID(signalID) else {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure
                .invalidReceipt
        }
        try validateDirectory()
        try reapStaleTemporaryFiles()
        let isContained = try readDocument().receipts.contains {
            $0.signalID == signalID
        }
        if isContained { try ensureReceiptFileIsDurable() }
        return isContained
    }

    func receipts() throws -> [HealthKitBackgroundDeliveryReceipt] {
        try validateDirectory()
        try reapStaleTemporaryFiles()
        return try readDocument().receipts
    }

    private func readDocument() throws -> Document {
        guard let data = try readData() else {
            return Document(receipts: [])
        }
        guard Self.hasStrictSchema(data),
              let document = try? Self.decoder.decode(
                  Document.self,
                  from: data
              ),
              document.schemaVersion == Document.currentVersion,
              document.receipts.count <= Document.maximumReceiptCount,
              Set(document.receipts.map(\.signalID)).count
                == document.receipts.count,
              document.receipts.allSatisfy(Self.isValid)
        else {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure
                .invalidDocument
        }
        return document
    }

    private func persist(_ document: Document) throws {
        guard document.schemaVersion == Document.currentVersion,
              document.receipts.count <= Document.maximumReceiptCount,
              Set(document.receipts.map(\.signalID)).count
                == document.receipts.count,
              document.receipts.allSatisfy(Self.isValid),
              let data = try? Self.encoder.encode(document),
              data.count <= Document.maximumEncodedBytes,
              Self.hasStrictSchema(data),
              let verified = try? Self.decoder.decode(
                  Document.self,
                  from: data
              ),
              let verifiedData = try? Self.encoder.encode(verified),
              verifiedData == data
        else {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure
                .invalidDocument
        }
        try rejectUnsafeDestination()
        try writeAtomically(data)
    }

    private func validateDirectory() throws {
        guard directory.isFileURL else {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure
                .invalidDirectory
        }
        let descriptor = directory.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure
                .invalidDirectory
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              Darwin.fchmod(descriptor, mode_t(0o700)) == 0
        else {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure
                .invalidDirectory
        }
        do {
            try fileProtection.apply(
                .completeUntilFirstUserAuthentication,
                to: directory
            )
        } catch {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure.ioFailure
        }
    }

    private func readData() throws -> Data? {
        let descriptor = fileURL.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP {
                throw HealthKitBackgroundDeliveryReceiptStoreFailure
                    .unsafeFilesystemEntry
            }
            throw HealthKitBackgroundDeliveryReceiptStoreFailure.ioFailure
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG
        else {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure
                .unsafeFilesystemEntry
        }
        guard metadata.st_size > 0,
              metadata.st_size <= Document.maximumEncodedBytes,
              Darwin.fchmod(descriptor, mode_t(0o600)) == 0
        else {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure
                .invalidDocument
        }
        do {
            try fileProtection.apply(
                .completeUntilFirstUserAuthentication,
                to: fileURL
            )
        } catch {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure.ioFailure
        }
        var data = Data(count: Int(metadata.st_size))
        let readCount = data.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return -1 }
                offset += count
            }
            return offset
        }
        guard readCount == data.count else {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure.ioFailure
        }
        return data
    }

    private func writeAtomically(_ data: Data) throws {
        let temporaryURL = directory.appendingPathComponent(
            ".background-delivery.\(UUID().uuidString.lowercased()).tmp"
        )
        let descriptor = temporaryURL.path.withCString { path in
            Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure.ioFailure
        }
        var descriptorIsOpen = true
        var removeTemporary = true
        defer {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
            if removeTemporary {
                _ = temporaryURL.path.withCString(Darwin.unlink)
            }
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure.ioFailure
        }
        do {
            try fileProtection.apply(
                .completeUntilFirstUserAuthentication,
                to: temporaryURL
            )
        } catch {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure.ioFailure
        }
        let wroteAll = data.withUnsafeBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wroteAll, Self.synchronize(descriptor) else {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure.ioFailure
        }
        try fullySynchronize(
            descriptor,
            failurePoint: .temporaryFullSync
        )
        do {
            try faultInjector.checkpoint(.temporarySynced)
        } catch {
            removeTemporary = false
            throw error
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptorIsOpen = false
            throw HealthKitBackgroundDeliveryReceiptStoreFailure.ioFailure
        }
        descriptorIsOpen = false
        guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure.ioFailure
        }
        removeTemporary = false
        try ensureReceiptFileIsDurable()
    }

    private func ensureReceiptFileIsDurable() throws {
        let descriptor = fileURL.path.withCString { path in
            Darwin.open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw HealthKitBackgroundDeliveryReceiptStoreFailure
                    .unsafeFilesystemEntry
            }
            throw HealthKitBackgroundDeliveryReceiptStoreFailure.ioFailure
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              Darwin.fchmod(descriptor, mode_t(0o600)) == 0
        else {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure
                .unsafeFilesystemEntry
        }
        do {
            try fileProtection.apply(
                .completeUntilFirstUserAuthentication,
                to: fileURL
            )
        } catch {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure.ioFailure
        }
        guard Self.synchronize(descriptor) else {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure.ioFailure
        }
        try synchronizeDirectory()
        try fullySynchronize(
            descriptor,
            failurePoint: .destinationFullSync
        )
    }

    private func rejectUnsafeDestination() throws {
        switch try entryKind(at: fileURL) {
        case .absent, .regularFile:
            return
        case .directory, .other:
            throw HealthKitBackgroundDeliveryReceiptStoreFailure
                .unsafeFilesystemEntry
        }
    }

    private func reapStaleTemporaryFiles() throws {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure.ioFailure
        }
        var removedAny = false
        for entry in entries
        where Self.isTemporaryFilename(entry.lastPathComponent) {
            guard try entryKind(at: entry) == .regularFile else {
                throw HealthKitBackgroundDeliveryReceiptStoreFailure
                    .unsafeFilesystemEntry
            }
            while Darwin.unlink(entry.path) != 0 {
                if errno == EINTR { continue }
                throw HealthKitBackgroundDeliveryReceiptStoreFailure.ioFailure
            }
            removedAny = true
        }
        if removedAny { try synchronizeDirectory() }
    }

    private func synchronizeDirectory() throws {
        let descriptor = directory.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure.ioFailure
        }
        defer { _ = Darwin.close(descriptor) }
        try faultInjector.checkpoint(.directorySync)
        guard Self.synchronize(descriptor) else {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure.ioFailure
        }
    }

    private func entryKind(at url: URL) throws -> EntryKind {
        var metadata = stat()
        let result = url.path.withCString { Darwin.lstat($0, &metadata) }
        guard result == 0 else {
            if errno == ENOENT { return .absent }
            throw HealthKitBackgroundDeliveryReceiptStoreFailure.ioFailure
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

    private static func isValid(
        _ receipt: HealthKitBackgroundDeliveryReceipt
    ) -> Bool {
        guard receipt.trigger == .observerWakeupBackground,
              receipt.processedAt.timeIntervalSinceReferenceDate.isFinite,
              receipt.publicationRevision > 0,
              Self.isValidSignalID(receipt.signalID)
        else {
            return false
        }
        return true
    }

    private static func isValidSignalID(_ value: String) -> Bool {
        guard (1 ... 160).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || [45, 46, 58, 95].contains(byte)
        }
    }

    private static func canonicalReceipt(
        _ receipt: HealthKitBackgroundDeliveryReceipt
    ) throws -> HealthKitBackgroundDeliveryReceipt {
        guard Self.isValid(receipt),
              let data = try? Self.encoder.encode(receipt),
              data.count <= Document.maximumEncodedBytes,
              let canonical = try? Self.decoder.decode(
                  HealthKitBackgroundDeliveryReceipt.self,
                  from: data
              ),
              Self.isValid(canonical),
              let verifiedData = try? Self.encoder.encode(canonical),
              verifiedData == data
        else {
            throw HealthKitBackgroundDeliveryReceiptStoreFailure
                .invalidReceipt
        }
        return canonical
    }

    private static func hasStrictSchema(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Set(object.keys) == ["receipts", "schema_version"],
              let entries = object["receipts"] as? [[String: Any]],
              entries.allSatisfy({ entry in
                  Set(entry.keys) == [
                      "had_issues",
                      "processed_at",
                      "publication_revision",
                      "signal_id",
                      "trigger",
                  ]
              })
        else {
            return false
        }
        return true
    }

    private static func isTemporaryFilename(_ value: String) -> Bool {
        let parts = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard parts.count == 4,
              parts[0].isEmpty,
              parts[1] == "background-delivery",
              UUID(uuidString: String(parts[2])) != nil,
              parts[3] == "tmp"
        else {
            return false
        }
        return true
    }

    private static func synchronize(_ descriptor: Int32) -> Bool {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            return false
        }
        return true
    }

    private func fullySynchronize(
        _ descriptor: Int32,
        failurePoint: HealthKitBackgroundDeliveryReceiptStoreFaultPoint
    ) throws {
        try faultInjector.checkpoint(failurePoint)
        while Darwin.fcntl(descriptor, F_FULLFSYNC) != 0 {
            if errno == EINTR { continue }
            throw HealthKitBackgroundDeliveryReceiptStoreFailure.ioFailure
        }
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
}
