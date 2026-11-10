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
    /// Families switched off on this iPhone (Account → Notifications). Empty by
    /// default so tests and fixtures keep every family on.
    var switchedOff: @Sendable () -> Set<CompetitionNotificationChoice> = { [] }

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

/// What Account → Notifications can switch off. Results, challenges and
/// challenge expiry have no case: they're always on. Stored per iPhone.
enum CompetitionNotificationChoice: String, CaseIterable, Sendable {
    case leadChange = "lead-change"
    case closeScore = "close-score"
    case whatItTakes = "what-it-takes"
    case finalDay = "final-day"
    case liveActivity = "live-activity"
    case reaction // raw value = server work kind (20261102002700)
    case nudge // raw value = server work kind (20261101002500)
    case friendRequest = "friend_request" // server work kind (20261109003100)
    case friendAccepted = "friend_accepted" // server work kind (20261109003100)
    case groupBanter = "group-banter"

    var title: String {
        switch self {
        case .leadChange: "Lead changes"
        case .closeScore: "Close scores"
        case .whatItTakes: "What it takes"
        case .finalDay: "Last day"
        case .liveActivity: "Live Activity"
        case .reaction: "Reactions"
        case .nudge: "Nudges"
        case .friendRequest: "Friend requests"
        case .friendAccepted: "Accepted requests"
        case .groupBanter: "Group match banter"
        }
    }

    /// Held back by the server, not the planner.
    var isServerSent: Bool { self == .reaction || self == .nudge || isFriends }

    /// Its own section; servers before 20261109003100 reject these mutes.
    var isFriends: Bool { self == .friendRequest || self == .friendAccepted }

    /// Persisted on devices: never rename a raw value.
    var storageKey: String { "healthcomp.notifications." + rawValue }

    /// A missing value means on.
    static func switchedOff(in defaults: UserDefaults = .standard) -> Set<Self> {
        Set(allCases.filter { defaults.object(forKey: $0.storageKey) as? Bool == false })
    }

    /// Sent with registration; sorted so equal sets encode equally.
    static func mutedPushKinds(in defaults: UserDefaults = .standard) -> [String] {
        switchedOff(in: defaults).filter(\.isServerSent).map(\.rawValue).sorted()
    }
}
