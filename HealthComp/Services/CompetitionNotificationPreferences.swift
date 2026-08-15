import Foundation

enum CompetitionNotificationPreferencesError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidDocument
    case unsupportedVersion(Int)
    case ioFailure
}

actor CompetitionNotificationPreferencesStore {
    private struct Document: Codable {
        static let currentVersion = 1

        let version: Int
        let mutedOpponentIdentities: [String]
    }

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func mutedOpponentIdentities() throws -> Set<String> {
        try load()
    }

    func setMuted(_ opponentIdentity: String, _ isMuted: Bool) throws {
        guard !opponentIdentity.isEmpty else {
            throw CompetitionNotificationPreferencesError.invalidIdentity
        }
        var identities = try load()
        if isMuted {
            identities.insert(opponentIdentity)
        } else {
            identities.remove(opponentIdentity)
        }
        try persist(identities)
    }

    private func load() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw CompetitionNotificationPreferencesError.ioFailure
        }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw CompetitionNotificationPreferencesError.invalidDocument
        }
        guard document.version == Document.currentVersion else {
            throw CompetitionNotificationPreferencesError.unsupportedVersion(
                document.version
            )
        }
        guard document.mutedOpponentIdentities.allSatisfy({ !$0.isEmpty }),
              Set(document.mutedOpponentIdentities).count
                == document.mutedOpponentIdentities.count
        else {
            throw CompetitionNotificationPreferencesError.invalidDocument
        }
        return Set(document.mutedOpponentIdentities)
    }

    private func persist(_ identities: Set<String>) throws {
        let document = Document(
            version: Document.currentVersion,
            mutedOpponentIdentities: identities.sorted()
        )
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(document)
        } catch {
            throw CompetitionNotificationPreferencesError.invalidDocument
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw CompetitionNotificationPreferencesError.ioFailure
        }
    }
}

struct CompetitionNotificationPreferencesClient: Sendable {
    var mutedOpponentIdentities: @Sendable () async throws -> Set<String>
    var setMuted: @Sendable (
        _ opponentIdentity: String,
        _ isMuted: Bool
    ) async throws -> Void

    static func live(
        fileURL: URL
    ) -> CompetitionNotificationPreferencesClient {
        let store = CompetitionNotificationPreferencesStore(fileURL: fileURL)
        return CompetitionNotificationPreferencesClient(
            mutedOpponentIdentities: {
                try await store.mutedOpponentIdentities()
            },
            setMuted: { identity, isMuted in
                try await store.setMuted(identity, isMuted)
            }
        )
    }

    static func constant(
        mutedOpponentIdentities: Set<String>
    ) -> CompetitionNotificationPreferencesClient {
        CompetitionNotificationPreferencesClient(
            mutedOpponentIdentities: { mutedOpponentIdentities },
            setMuted: { _, _ in }
        )
    }

    static func remote(
        remoteAPI: CompetitionRemoteAPI
    ) -> CompetitionNotificationPreferencesClient {
        CompetitionNotificationPreferencesClient(
            mutedOpponentIdentities: {
                let profileIDs = try await remoteAPI
                    .loadMutedOpponentProfileIDs()
                return Set(profileIDs.map {
                    RemoteCompetitionOpponentIdentity.identity(for: $0)
                })
            },
            setMuted: { identity, isMuted in
                guard let profileID = RemoteCompetitionOpponentIdentity
                    .profileID(identity)
                else {
                    throw CompetitionNotificationPreferencesError
                        .invalidIdentity
                }
                try await remoteAPI.setOpponentMuted(profileID, isMuted)
            }
        )
    }

    static let unavailable = CompetitionNotificationPreferencesClient(
        mutedOpponentIdentities: {
            throw CompetitionNotificationPreferencesError.ioFailure
        },
        setMuted: { _, _ in
            throw CompetitionNotificationPreferencesError.ioFailure
        }
    )
}

enum RemoteCompetitionOpponentIdentity {
    static let prefix = "remote-profile:v1:"

    static func identity(for profileID: UUID) -> String {
        prefix + profileID.uuidString.lowercased()
    }

    static func profileID(_ identity: String) -> UUID? {
        guard identity.hasPrefix(prefix) else { return nil }
        let value = String(identity.dropFirst(prefix.count))
        guard let profileID = UUID(uuidString: value),
              profileID.uuidString.lowercased() == value,
              profileID.uuidString
                != "00000000-0000-0000-0000-000000000000"
        else { return nil }
        return profileID
    }
}
