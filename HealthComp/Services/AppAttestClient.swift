import CryptoKit
import Darwin
import Foundation

enum AppAttestServiceFailure: Error, Equatable, Sendable {
    case serverUnavailable
    case invalidKey
    case operationFailed
}

protocol AppAttestServiceProtocol: Sendable {
    func isSupported() async -> Bool
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(
        _ keyID: String,
        clientDataHash: Data
    ) async throws -> Data
}

struct AppAttestClient: Sendable {
    var appendScoreRevision: @Sendable (
        CompetitionScoreRevisionRequest
    ) async throws -> CompetitionScoreRevisionResponse

    static func live(
        profileID: UUID,
        installationID: UUID,
        service: any AppAttestServiceProtocol,
        stateStore: AppAttestStateStore,
        issueChallenge: @escaping @Sendable (
            CompetitionAppAttestChallengeRequest
        ) async throws -> CompetitionAppAttestChallenge,
        submit: @escaping @Sendable (
            CompetitionAttestedScoreRevisionRequest
        ) async throws -> CompetitionScoreRevisionResponse,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> Self {
        let coordinator = AppAttestClientCoordinator(
            profileID: profileID,
            installationID: installationID,
            service: service,
            stateStore: stateStore,
            issueChallenge: issueChallenge,
            submit: submit,
            now: now
        )
        return Self(
            appendScoreRevision: {
                try await coordinator.appendScoreRevision($0)
            }
        )
    }
}

enum AppAttestClientDataV1 {
    private static let domain = Data("healthcomp-app-attest-v1\0".utf8)

    static func encode(
        challengeID: UUID,
        challenge: Data,
        profileID: UUID,
        installationID: UUID,
        payloadSHA256: Data
    ) throws -> Data {
        guard challenge.count == 32, payloadSHA256.count == 32 else {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
        return domain
            + (try field(1, uuidBytes(challengeID)))
            + field(2, challenge)
            + (try field(3, uuidBytes(profileID)))
            + (try field(4, uuidBytes(installationID)))
            + field(5, payloadSHA256)
            + field(6, Data("score_revision".utf8))
    }

    private static func field(_ tag: UInt8, _ value: Data) -> Data {
        var length = UInt32(value.count).bigEndian
        var result = Data([tag])
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(value)
        return result
    }

    private static func uuidBytes(_ value: UUID) throws -> Data {
        let canonical = value.uuidString.lowercased()
        guard canonical != "00000000-0000-0000-0000-000000000000" else {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
        let hex = canonical.replacingOccurrences(of: "-", with: "")
        var result = Data(capacity: 16)
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else {
                throw CompetitionRemoteFailure.serverContractMismatch
            }
            result.append(byte)
            index = end
        }
        guard result.count == 16 else {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
        return result
    }
}

enum AppAttestStateStoreFailure: Error, Equatable, Sendable {
    case invalidDirectory
    case unsafeFilesystemEntry
    case invalidDocument
    case ioFailure
}

struct AppAttestPendingChallenge: Equatable, Sendable {
    let challengeID: UUID
    let challenge: Data
    let expiresAt: Date
    let payloadSHA256: String
    let keyID: String
    let proofKind: CompetitionAppAttestProofKind
}

struct AppAttestLocalState: Equatable, Sendable {
    let profileID: UUID
    let keyID: String?
    let pendingChallenge: AppAttestPendingChallenge?

    init(
        profileID: UUID,
        keyID: String?,
        pendingChallenge: AppAttestPendingChallenge? = nil
    ) {
        self.profileID = profileID
        self.keyID = keyID
        self.pendingChallenge = pendingChallenge
    }
}

actor AppAttestStateStore {
    private struct Document: Codable {
        let version: Int
        let profileID: String
        let keyID: String?
        let pendingChallenge: PendingDocument?

        enum CodingKeys: String, CodingKey {
            case version
            case profileID = "profile_id"
            case keyID = "key_id"
            case pendingChallenge = "pending_challenge"
        }

        init(
            version: Int,
            profileID: String,
            keyID: String?,
            pendingChallenge: PendingDocument?
        ) {
            self.version = version
            self.profileID = profileID
            self.keyID = keyID
            self.pendingChallenge = pendingChallenge
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.version = try container.decode(Int.self, forKey: .version)
            self.profileID = try container.decode(
                String.self,
                forKey: .profileID
            )
            self.keyID = try container.decodeIfPresent(
                String.self,
                forKey: .keyID
            )
            self.pendingChallenge = try container.decodeIfPresent(
                PendingDocument.self,
                forKey: .pendingChallenge
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(profileID, forKey: .profileID)
            try container.encode(keyID, forKey: .keyID)
            try container.encode(
                pendingChallenge,
                forKey: .pendingChallenge
            )
        }
    }

    private struct PendingDocument: Codable {
        let challengeID: String
        let challenge: String
        let expiresAt: String
        let payloadSHA256: String
        let keyID: String
        let proofKind: CompetitionAppAttestProofKind

        enum CodingKeys: String, CodingKey {
            case challengeID = "challenge_id"
            case challenge
            case expiresAt = "expires_at"
            case payloadSHA256 = "payload_sha256"
            case keyID = "key_id"
            case proofKind = "proof_kind"
        }
    }

    private let profileID: UUID
    private let directory: URL
    private let fileURL: URL
    private let fileProtection: JSONCompetitionEventStoreFileProtection

    init(
        profileID: UUID,
        directory: URL,
        fileProtection: JSONCompetitionEventStoreFileProtection = .live
    ) {
        self.profileID = profileID
        self.directory = directory.standardizedFileURL
        self.fileURL = directory.standardizedFileURL.appendingPathComponent(
            "app-attest-state.v1.json",
            isDirectory: false
        )
        self.fileProtection = fileProtection
    }

    func load() throws -> AppAttestLocalState {
        try validateDirectory()
        guard let data = try readData() else {
            return AppAttestLocalState(profileID: profileID, keyID: nil)
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Set(raw.keys) == [
                  "key_id", "pending_challenge", "profile_id", "version",
              ],
              raw["key_id"] is NSNull || raw["key_id"] is String,
              raw["pending_challenge"] is NSNull
                || validPendingObject(raw["pending_challenge"]),
              let document = try? JSONDecoder().decode(
                  Document.self,
                  from: data
              ),
              document.version == 1,
              document.profileID == profileID.uuidString.lowercased(),
              document.keyID.map(Self.validKeyID) ?? true
        else {
            throw AppAttestStateStoreFailure.invalidDocument
        }
        let pending: AppAttestPendingChallenge?
        if let value = document.pendingChallenge {
            guard let challengeID = UUID(uuidString: value.challengeID),
                  challengeID.uuidString.lowercased() == value.challengeID,
                  let challenge = Data(base64Encoded: value.challenge),
                  challenge.count == 32,
                  challenge.base64EncodedString() == value.challenge,
                  let expiresAt = try? CompetitionWireCodec.date(
                      value.expiresAt
                  ),
                  Self.validDigest(
                      value.payloadSHA256
                  ),
                  Self.validKeyID(value.keyID),
                  value.keyID == document.keyID
            else {
                throw AppAttestStateStoreFailure.invalidDocument
            }
            pending = AppAttestPendingChallenge(
                challengeID: challengeID,
                challenge: challenge,
                expiresAt: expiresAt,
                payloadSHA256: value.payloadSHA256,
                keyID: value.keyID,
                proofKind: value.proofKind
            )
        } else {
            pending = nil
        }
        guard document.keyID != nil || pending == nil else {
            throw AppAttestStateStoreFailure.invalidDocument
        }
        return AppAttestLocalState(
            profileID: profileID,
            keyID: document.keyID,
            pendingChallenge: pending
        )
    }

    func save(_ state: AppAttestLocalState) throws {
        guard state.profileID == profileID,
              state.keyID.map(Self.validKeyID) ?? true,
              state.pendingChallenge.map({ pending in
                  pending.challenge.count == 32
                    && pending.expiresAt.timeIntervalSinceReferenceDate.isFinite
                    && Self.validDigest(
                        pending.payloadSHA256
                    )
                    && Self.validKeyID(pending.keyID)
                    && pending.keyID == state.keyID
              }) ?? true,
              state.keyID != nil || state.pendingChallenge == nil
        else {
            throw AppAttestStateStoreFailure.invalidDocument
        }
        try validateDirectory()
        try rejectUnsafeDestination()
        let pendingDocument: PendingDocument?
        if let pending = state.pendingChallenge {
            let expiresAt: String
            do {
                expiresAt = try CompetitionWireCodec.timestamp(
                    pending.expiresAt
                )
            } catch {
                throw AppAttestStateStoreFailure.invalidDocument
            }
            pendingDocument = PendingDocument(
                challengeID: pending.challengeID.uuidString.lowercased(),
                challenge: pending.challenge.base64EncodedString(),
                expiresAt: expiresAt,
                payloadSHA256: pending.payloadSHA256,
                keyID: pending.keyID,
                proofKind: pending.proofKind
            )
        } else {
            pendingDocument = nil
        }
        let document = Document(
            version: 1,
            profileID: profileID.uuidString.lowercased(),
            keyID: state.keyID,
            pendingChallenge: pendingDocument
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(document), data.count <= 2_048
        else {
            throw AppAttestStateStoreFailure.invalidDocument
        }
        try writeAtomically(data)
    }

    private func validateDirectory() throws {
        guard directory.isFileURL else {
            throw AppAttestStateStoreFailure.invalidDirectory
        }
        let descriptor = directory.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw AppAttestStateStoreFailure.invalidDirectory
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              Darwin.fchmod(descriptor, mode_t(0o700)) == 0
        else {
            throw AppAttestStateStoreFailure.invalidDirectory
        }
        do {
            try fileProtection.apply(
                .completeUntilFirstUserAuthentication,
                to: directory
            )
        } catch {
            throw AppAttestStateStoreFailure.ioFailure
        }
    }

    private func readData() throws -> Data? {
        let descriptor = fileURL.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP {
                throw AppAttestStateStoreFailure.unsafeFilesystemEntry
            }
            throw AppAttestStateStoreFailure.ioFailure
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              (1...2_048).contains(Int(metadata.st_size)),
              Darwin.fchmod(descriptor, mode_t(0o600)) == 0
        else {
            throw AppAttestStateStoreFailure.unsafeFilesystemEntry
        }
        do {
            try fileProtection.apply(
                .completeUntilFirstUserAuthentication,
                to: fileURL
            )
        } catch {
            throw AppAttestStateStoreFailure.ioFailure
        }
        var data = Data(count: Int(metadata.st_size))
        let count = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            var offset = 0
            while offset < buffer.count {
                let readCount = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if readCount < 0 && errno == EINTR { continue }
                guard readCount > 0 else { return -1 }
                offset += readCount
            }
            return offset
        }
        guard count == data.count else {
            throw AppAttestStateStoreFailure.ioFailure
        }
        return data
    }

    private func writeAtomically(_ data: Data) throws {
        let temporaryURL = directory.appendingPathComponent(
            ".app-attest-state.\(UUID().uuidString.lowercased()).tmp"
        )
        let descriptor = temporaryURL.path.withCString { path in
            Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw AppAttestStateStoreFailure.ioFailure
        }
        var removeTemporary = true
        defer {
            _ = Darwin.close(descriptor)
            if removeTemporary {
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
            throw AppAttestStateStoreFailure.ioFailure
        }
        do {
            try fileProtection.apply(
                .completeUntilFirstUserAuthentication,
                to: temporaryURL
            )
        } catch {
            throw AppAttestStateStoreFailure.ioFailure
        }
        guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
            throw AppAttestStateStoreFailure.ioFailure
        }
        removeTemporary = false
        let directoryDescriptor = directory.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else {
            throw AppAttestStateStoreFailure.ioFailure
        }
        defer { _ = Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw AppAttestStateStoreFailure.ioFailure
        }
    }

    private func rejectUnsafeDestination() throws {
        var metadata = stat()
        let result = fileURL.path.withCString { Darwin.lstat($0, &metadata) }
        if result != 0 {
            guard errno == ENOENT else {
                throw AppAttestStateStoreFailure.ioFailure
            }
            return
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw AppAttestStateStoreFailure.unsafeFilesystemEntry
        }
    }

    private func validPendingObject(_ value: Any?) -> Bool {
        guard let object = value as? [String: Any] else { return false }
        return Set(object.keys) == [
            "challenge", "challenge_id", "expires_at", "key_id",
            "payload_sha256", "proof_kind",
        ]
    }

    private static func validKeyID(_ value: String) -> Bool {
        guard let data = Data(base64Encoded: value), data.count == 32 else {
            return false
        }
        return data.base64EncodedString() == value
    }

    private static func validDigest(_ value: String) -> Bool {
        value.range(
            of: "^[0-9a-f]{64}$",
            options: .regularExpression
        ) != nil
    }
}

private actor AppAttestClientCoordinator {
    private enum Control: Error {
        case replaceKey
    }

    private struct EphemeralProof {
        let challengeID: UUID
        let keyID: String
        let payloadSHA256: String
        let proof: CompetitionAppAttestProof
    }

    private let profileID: UUID
    private let installationID: UUID
    private let service: any AppAttestServiceProtocol
    private let stateStore: AppAttestStateStore
    private let issueChallenge: @Sendable (
        CompetitionAppAttestChallengeRequest
    ) async throws -> CompetitionAppAttestChallenge
    private let submit: @Sendable (
        CompetitionAttestedScoreRevisionRequest
    ) async throws -> CompetitionScoreRevisionResponse
    private let now: @Sendable () -> Date
    private var ephemeralProof: EphemeralProof?

    init(
        profileID: UUID,
        installationID: UUID,
        service: any AppAttestServiceProtocol,
        stateStore: AppAttestStateStore,
        issueChallenge: @escaping @Sendable (
            CompetitionAppAttestChallengeRequest
        ) async throws -> CompetitionAppAttestChallenge,
        submit: @escaping @Sendable (
            CompetitionAttestedScoreRevisionRequest
        ) async throws -> CompetitionScoreRevisionResponse,
        now: @escaping @Sendable () -> Date
    ) {
        self.profileID = profileID
        self.installationID = installationID
        self.service = service
        self.stateStore = stateStore
        self.issueChallenge = issueChallenge
        self.submit = submit
        self.now = now
    }

    func appendScoreRevision(
        _ score: CompetitionScoreRevisionRequest
    ) async throws -> CompetitionScoreRevisionResponse {
        guard await service.isSupported() else {
            throw CompetitionRemoteFailure.appAttestUnavailable
        }
        let scoreData: Data
        do {
            scoreData = try CompetitionWireCodec.encode(
                score,
                contract: .scoreRevisionRequest
            )
        } catch {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
        let digestData = Data(SHA256.hash(data: scoreData))
        let digestHex = digestData.map {
            String(format: "%02x", $0)
        }.joined()
        var replacementAttemptsRemaining = 1
        var contextRefreshAttemptsRemaining = 1

        while true {
            var state: AppAttestLocalState
            do {
                state = try await stateStore.load()
            } catch {
                throw CompetitionRemoteFailure.appAttestUnavailable
            }
            if state.keyID == nil {
                let keyID = try await generateKey()
                state = AppAttestLocalState(
                    profileID: profileID,
                    keyID: keyID
                )
                try await save(state)
            }
            guard let keyID = state.keyID else {
                throw CompetitionRemoteFailure.appAttestUnavailable
            }
            let challenge = try await challenge(
                state: &state,
                keyID: keyID,
                payloadSHA256: digestHex
            )
            let proof: CompetitionAppAttestProof
            if let cached = ephemeralProof,
               cached.challengeID == challenge.challengeID,
               cached.keyID == keyID,
               cached.payloadSHA256 == digestHex {
                proof = cached.proof
            } else {
                do {
                    proof = try await createProof(
                        challenge: challenge,
                        keyID: keyID,
                        payloadSHA256: digestData
                    )
                } catch Control.replaceKey {
                    try await resetKey()
                    guard replacementAttemptsRemaining > 0 else {
                        throw CompetitionRemoteFailure.appAttestRejected
                    }
                    replacementAttemptsRemaining -= 1
                    continue
                }
                ephemeralProof = EphemeralProof(
                    challengeID: challenge.challengeID,
                    keyID: keyID,
                    payloadSHA256: digestHex,
                    proof: proof
                )
            }
            let envelope: CompetitionAttestedScoreRevisionRequest
            do {
                envelope = try CompetitionAttestedScoreRevisionRequest(
                    score: score,
                    appAttest: proof
                )
            } catch {
                throw CompetitionRemoteFailure.serverContractMismatch
            }

            do {
                let response = try await submit(envelope)
                ephemeralProof = nil
                try? await stateStore.save(
                    AppAttestLocalState(
                        profileID: profileID,
                        keyID: keyID
                    )
                )
                return response
            } catch let failure as CompetitionRemoteFailure {
                switch failure {
                case .appAttestContextUnavailable:
                    try await clearPending(keyID: keyID)
                    guard contextRefreshAttemptsRemaining > 0 else {
                        throw CompetitionRemoteFailure.retryableTransport
                    }
                    contextRefreshAttemptsRemaining -= 1
                    continue
                case .appAttestProofConflict:
                    try await resetKey()
                    guard replacementAttemptsRemaining > 0 else {
                        throw CompetitionRemoteFailure.appAttestRejected
                    }
                    replacementAttemptsRemaining -= 1
                    continue
                case .appAttestRejected:
                    try await resetKey()
                    throw failure
                default:
                    throw failure
                }
            }
        }
    }

    private func generateKey() async throws -> String {
        do {
            let keyID = try await service.generateKey()
            guard Self.validKeyID(keyID) else {
                throw CompetitionRemoteFailure.appAttestUnavailable
            }
            return keyID
        } catch AppAttestServiceFailure.serverUnavailable {
            throw CompetitionRemoteFailure.retryableTransport
        } catch let failure as CompetitionRemoteFailure {
            throw failure
        } catch {
            throw CompetitionRemoteFailure.appAttestUnavailable
        }
    }

    private func challenge(
        state: inout AppAttestLocalState,
        keyID: String,
        payloadSHA256: String
    ) async throws -> CompetitionAppAttestChallenge {
        if let pending = state.pendingChallenge,
           pending.keyID == keyID,
           pending.payloadSHA256 == payloadSHA256,
           pending.expiresAt > now() {
            return try CompetitionAppAttestChallenge(
                challengeID: pending.challengeID,
                challenge: pending.challenge,
                expiresAt: pending.expiresAt,
                proofKind: pending.proofKind
            )
        }
        ephemeralProof = nil
        state = AppAttestLocalState(profileID: profileID, keyID: keyID)
        try await save(state)
        let request: CompetitionAppAttestChallengeRequest
        do {
            request = try CompetitionAppAttestChallengeRequest(
                installationID: installationID,
                payloadSHA256: payloadSHA256,
                keyID: keyID
            )
        } catch {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
        let issued = try await issueChallenge(request)
        guard issued.expiresAt > now() else {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
        let pending = AppAttestPendingChallenge(
            challengeID: issued.challengeID,
            challenge: issued.challenge,
            expiresAt: issued.expiresAt,
            payloadSHA256: payloadSHA256,
            keyID: keyID,
            proofKind: issued.proofKind
        )
        state = AppAttestLocalState(
            profileID: profileID,
            keyID: keyID,
            pendingChallenge: pending
        )
        try await save(state)
        return issued
    }

    private func createProof(
        challenge: CompetitionAppAttestChallenge,
        keyID: String,
        payloadSHA256: Data
    ) async throws -> CompetitionAppAttestProof {
        let clientData = try AppAttestClientDataV1.encode(
            challengeID: challenge.challengeID,
            challenge: challenge.challenge,
            profileID: profileID,
            installationID: installationID,
            payloadSHA256: payloadSHA256
        )
        let clientDataHash = Data(SHA256.hash(data: clientData))
        let object: Data
        do {
            switch challenge.proofKind {
            case .attestation:
                object = try await service.attestKey(
                    keyID,
                    clientDataHash: clientDataHash
                )
            case .assertion:
                object = try await service.generateAssertion(
                    keyID,
                    clientDataHash: clientDataHash
                )
            }
        } catch AppAttestServiceFailure.serverUnavailable {
            throw CompetitionRemoteFailure.retryableTransport
        } catch AppAttestServiceFailure.invalidKey {
            throw Control.replaceKey
        } catch {
            if challenge.proofKind == .attestation {
                try await resetKey()
            }
            throw CompetitionRemoteFailure.appAttestUnavailable
        }
        do {
            return try CompetitionAppAttestProof(
                challengeID: challenge.challengeID,
                installationID: installationID,
                keyID: keyID,
                proofKind: challenge.proofKind,
                object: object
            )
        } catch {
            if challenge.proofKind == .attestation {
                try await resetKey()
            }
            throw CompetitionRemoteFailure.appAttestUnavailable
        }
    }

    private func clearPending(keyID: String) async throws {
        ephemeralProof = nil
        try await save(
            AppAttestLocalState(profileID: profileID, keyID: keyID)
        )
    }

    private func resetKey() async throws {
        ephemeralProof = nil
        try await save(
            AppAttestLocalState(profileID: profileID, keyID: nil)
        )
    }

    private func save(_ state: AppAttestLocalState) async throws {
        do {
            try await stateStore.save(state)
        } catch {
            throw CompetitionRemoteFailure.appAttestUnavailable
        }
    }

    private static func validKeyID(_ value: String) -> Bool {
        guard let data = Data(base64Encoded: value), data.count == 32 else {
            return false
        }
        return data.base64EncodedString() == value
    }
}
