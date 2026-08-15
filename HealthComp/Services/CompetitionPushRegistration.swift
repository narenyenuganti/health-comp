import Darwin
import Foundation
import UIKit

enum CompetitionPushRegistrationEvent: Equatable, Sendable {
    case registered(String)
    case failed
}

enum CompetitionPushRegistrationFailure: Error, Equatable, Sendable {
    case invalidConfiguration
}

extension CompetitionInstallationEnvironment {
    static func configured(bundle: Bundle = .main) throws -> Self {
        guard let rawValue = bundle.object(
            forInfoDictionaryKey: "HEALTHCOMP_APNS_ENVIRONMENT"
        ) as? String,
            let environment = Self(rawValue: rawValue)
        else {
            throw CompetitionPushRegistrationFailure.invalidConfiguration
        }
        return environment
    }
}

final class CompetitionPushRegistrationHub: @unchecked Sendable {
    private let lock = NSLock()
    private var latestTokenValue: String?
    private var continuations: [
        UUID: AsyncStream<CompetitionPushRegistrationEvent>.Continuation
    ] = [:]

    func publishDeviceToken(_ data: Data) {
        guard (32...100).contains(data.count) else {
            publishFailure()
            return
        }
        let token = data.map { String(format: "%02x", $0) }.joined()
        let listeners = lock.withLock { () -> [
            AsyncStream<CompetitionPushRegistrationEvent>.Continuation
        ] in
            latestTokenValue = token
            return Array(continuations.values)
        }
        listeners.forEach { $0.yield(.registered(token)) }
    }

    func publishFailure() {
        let listeners = lock.withLock { () -> [
            AsyncStream<CompetitionPushRegistrationEvent>.Continuation
        ] in
            latestTokenValue = nil
            return Array(continuations.values)
        }
        listeners.forEach { $0.yield(.failed) }
    }

    func latestToken() -> String? {
        lock.withLock { latestTokenValue }
    }

    func clear() {
        lock.withLock { latestTokenValue = nil }
    }

    func events() -> AsyncStream<CompetitionPushRegistrationEvent> {
        AsyncStream { continuation in
            let id = UUID()
            let replay = lock.withLock { () -> String? in
                continuations[id] = continuation
                return latestTokenValue
            }
            if let replay {
                continuation.yield(.registered(replay))
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        _ = lock.withLock { continuations.removeValue(forKey: id) }
    }
}

enum CompetitionPushRegistrationEnvironment {
    static let liveHub = CompetitionPushRegistrationHub()
}

struct CompetitionPushRegistrationClient: Sendable {
    var register: @Sendable () async -> Void
    var unregister: @Sendable () async -> Void
    var latestToken: @Sendable () async -> String?
    var events: @Sendable () -> AsyncStream<CompetitionPushRegistrationEvent>

    static let inert = Self(
        register: {},
        unregister: {},
        latestToken: { nil },
        events: { AsyncStream { $0.finish() } }
    )

    static let liveValue = Self(
        register: {
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        },
        unregister: {
            await MainActor.run {
                UIApplication.shared.unregisterForRemoteNotifications()
            }
            CompetitionPushRegistrationEnvironment.liveHub.clear()
        },
        latestToken: {
            CompetitionPushRegistrationEnvironment.liveHub.latestToken()
        },
        events: {
            CompetitionPushRegistrationEnvironment.liveHub.events()
        }
    )
}

enum CompetitionInstallationStateStoreFailure: Error, Equatable, Sendable {
    case invalidDirectory
    case unsafeFilesystemEntry
    case invalidDocument
    case ioFailure
}

struct CompetitionInstallationLocalState: Equatable, Sendable {
    let installationID: UUID
    let registrationAttempted: Bool
}

actor CompetitionInstallationStateStore {
    private struct Document: Codable {
        let version: Int
        let installationID: String
        let registrationAttempted: Bool

        enum CodingKeys: String, CodingKey {
            case version
            case installationID = "installation_id"
            case registrationAttempted = "registration_attempted"
        }
    }

    private let directory: URL
    private let fileURL: URL
    private let makeUUID: @Sendable () -> UUID
    private let fileProtection: JSONCompetitionEventStoreFileProtection

    init(
        directory: URL,
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        fileProtection: JSONCompetitionEventStoreFileProtection = .live
    ) {
        self.directory = directory.standardizedFileURL
        self.fileURL = directory.standardizedFileURL.appendingPathComponent(
            "installation-state.v1.json",
            isDirectory: false
        )
        self.makeUUID = makeUUID
        self.fileProtection = fileProtection
    }

    func loadOrCreate() throws -> CompetitionInstallationLocalState {
        try validateDirectory()
        if let document = try readDocument() {
            return try state(from: document)
        }
        let installationID = makeUUID()
        guard installationID.uuidString
            != "00000000-0000-0000-0000-000000000000"
        else {
            throw CompetitionInstallationStateStoreFailure.invalidDocument
        }
        let state = CompetitionInstallationLocalState(
            installationID: installationID,
            registrationAttempted: false
        )
        try persist(state)
        return state
    }

    func markRegistrationAttempted() throws {
        let state = try loadOrCreate()
        guard !state.registrationAttempted else { return }
        try persist(
            CompetitionInstallationLocalState(
                installationID: state.installationID,
                registrationAttempted: true
            )
        )
    }

    func clearRegistrationAttempted() throws {
        let state = try loadOrCreate()
        guard state.registrationAttempted else { return }
        try persist(
            CompetitionInstallationLocalState(
                installationID: state.installationID,
                registrationAttempted: false
            )
        )
    }

    private func validateDirectory() throws {
        guard directory.isFileURL else {
            throw CompetitionInstallationStateStoreFailure.invalidDirectory
        }
        let descriptor = directory.path.withCString { path in
            Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw CompetitionInstallationStateStoreFailure.invalidDirectory
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              Darwin.fchmod(descriptor, mode_t(0o700)) == 0
        else {
            throw CompetitionInstallationStateStoreFailure.invalidDirectory
        }
        do {
            try fileProtection.apply(
                .completeUntilFirstUserAuthentication,
                to: directory
            )
        } catch {
            throw CompetitionInstallationStateStoreFailure.ioFailure
        }
    }

    private func readDocument() throws -> Document? {
        let descriptor = fileURL.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP {
                throw CompetitionInstallationStateStoreFailure
                    .unsafeFilesystemEntry
            }
            throw CompetitionInstallationStateStoreFailure.ioFailure
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              (1...4_096).contains(Int(metadata.st_size)),
              Darwin.fchmod(descriptor, mode_t(0o600)) == 0
        else {
            throw CompetitionInstallationStateStoreFailure
                .unsafeFilesystemEntry
        }
        do {
            try fileProtection.apply(
                .completeUntilFirstUserAuthentication,
                to: fileURL
            )
        } catch {
            throw CompetitionInstallationStateStoreFailure.ioFailure
        }
        var data = Data(count: Int(metadata.st_size))
        let bytesRead = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return count < 0 ? -1 : offset }
                offset += count
            }
            return offset
        }
        guard bytesRead == data.count,
              let raw = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Set(raw.keys) == [
                "installation_id", "registration_attempted", "version",
              ],
              let document = try? JSONDecoder().decode(
                Document.self,
                from: data
              )
        else {
            throw CompetitionInstallationStateStoreFailure.invalidDocument
        }
        return document
    }

    private func state(
        from document: Document
    ) throws -> CompetitionInstallationLocalState {
        guard document.version == 1,
              let installationID = UUID(uuidString: document.installationID),
              installationID.uuidString.lowercased()
                == document.installationID,
              installationID.uuidString
                != "00000000-0000-0000-0000-000000000000"
        else {
            throw CompetitionInstallationStateStoreFailure.invalidDocument
        }
        return CompetitionInstallationLocalState(
            installationID: installationID,
            registrationAttempted: document.registrationAttempted
        )
    }

    private func persist(_ state: CompetitionInstallationLocalState) throws {
        try validateDirectory()
        try rejectUnsafeDestination()
        let document = Document(
            version: 1,
            installationID: state.installationID.uuidString.lowercased(),
            registrationAttempted: state.registrationAttempted
        )
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(document)
        } catch {
            throw CompetitionInstallationStateStoreFailure.invalidDocument
        }
        let temporaryURL = directory.appendingPathComponent(
            ".installation-state.\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        let descriptor = temporaryURL.path.withCString { path in
            Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw CompetitionInstallationStateStoreFailure.ioFailure
        }
        var shouldRemoveTemporary = true
        defer {
            _ = Darwin.close(descriptor)
            if shouldRemoveTemporary {
                _ = temporaryURL.path.withCString(Darwin.unlink)
            }
        }
        let wroteAll = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wroteAll,
              Darwin.fsync(descriptor) == 0,
              Darwin.fchmod(descriptor, mode_t(0o600)) == 0
        else {
            throw CompetitionInstallationStateStoreFailure.ioFailure
        }
        do {
            try fileProtection.apply(
                .completeUntilFirstUserAuthentication,
                to: temporaryURL
            )
        } catch {
            throw CompetitionInstallationStateStoreFailure.ioFailure
        }
        guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
            throw CompetitionInstallationStateStoreFailure.ioFailure
        }
        shouldRemoveTemporary = false
        try synchronizeDirectory()
    }

    private func rejectUnsafeDestination() throws {
        var metadata = stat()
        let result = fileURL.path.withCString { path in
            Darwin.lstat(path, &metadata)
        }
        if result != 0 {
            guard errno == ENOENT else {
                throw CompetitionInstallationStateStoreFailure.ioFailure
            }
            return
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw CompetitionInstallationStateStoreFailure
                .unsafeFilesystemEntry
        }
    }

    private func synchronizeDirectory() throws {
        let descriptor = directory.path.withCString { path in
            Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw CompetitionInstallationStateStoreFailure.ioFailure
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw CompetitionInstallationStateStoreFailure.ioFailure
        }
    }
}

actor CompetitionInstallationCoordinator {
    private let remoteAPI: CompetitionRemoteAPI
    private let registration: CompetitionPushRegistrationClient
    private let store: CompetitionInstallationStateStore
    private let environment: CompetitionInstallationEnvironment

    private var eventTask: Task<Void, Never>?
    private var localState: CompetitionInstallationLocalState?
    private var pendingToken: String?
    private var registeredToken: String?
    private var isDraining = false
    private var hasStarted = false

    init(
        remoteAPI: CompetitionRemoteAPI,
        registration: CompetitionPushRegistrationClient,
        store: CompetitionInstallationStateStore,
        environment: CompetitionInstallationEnvironment
    ) {
        self.remoteAPI = remoteAPI
        self.registration = registration
        self.store = store
        self.environment = environment
    }

    func start() async throws {
        guard !hasStarted else {
            await reconcile()
            return
        }
        localState = try await store.loadOrCreate()
        hasStarted = true
        let events = registration.events()
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.receive(event)
            }
        }
        await registration.register()
        await reconcile()
    }

    func reconcile() async {
        guard hasStarted, let token = await registration.latestToken() else {
            return
        }
        await enqueue(token)
    }

    func stopListening() async {
        hasStarted = false
        let task = eventTask
        task?.cancel()
        eventTask = nil
        pendingToken = nil
        registeredToken = nil
        await task?.value
    }

    func prepareForProfileTeardown(
        requireRemoteRemoval: Bool
    ) async throws {
        await registration.unregister()
        await stopListening()
        let state = try await store.loadOrCreate()
        guard state.registrationAttempted else { return }
        do {
            let removed = try await remoteAPI.removeInstallation(
                state.installationID
            )
            guard removed.installationID == state.installationID,
                  removed.state == .revoked
            else {
                throw CompetitionRemoteFailure.serverContractMismatch
            }
            try await store.clearRegistrationAttempted()
        } catch let failure as CompetitionRemoteFailure {
            if failure == .forbidden {
                try await store.clearRegistrationAttempted()
                return
            }
            if requireRemoteRemoval { throw failure }
        } catch {
            if requireRemoteRemoval { throw error }
        }
    }

    private func receive(_ event: CompetitionPushRegistrationEvent) async {
        switch event {
        case let .registered(token):
            await enqueue(token)
        case .failed:
            pendingToken = nil
        }
    }

    private func enqueue(_ token: String) async {
        guard token != registeredToken else { return }
        pendingToken = token
        guard !isDraining else { return }
        isDraining = true
        while let next = pendingToken {
            pendingToken = nil
            await register(next)
        }
        isDraining = false
    }

    private func register(_ token: String) async {
        guard let state = localState,
              let request = try? CompetitionInstallationRequest(
                installationID: state.installationID,
                apnsToken: token,
                environment: environment
              )
        else { return }
        do {
            try await store.markRegistrationAttempted()
            let registered = try await remoteAPI.registerInstallation(request)
            guard registered.installationID == state.installationID,
                  registered.environment == environment,
                  registered.state == .active
            else {
                throw CompetitionRemoteFailure.serverContractMismatch
            }
            registeredToken = token
            localState = CompetitionInstallationLocalState(
                installationID: state.installationID,
                registrationAttempted: true
            )
        } catch {
            registeredToken = nil
        }
    }
}
