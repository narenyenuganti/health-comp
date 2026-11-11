import Foundation

enum FriendChallengePolicy: String, CaseIterable, Equatable, Sendable {
    case friendsAndLink = "friends_and_link"
    case friendsOnly = "friends_only"

    var title: String {
        switch self {
        case .friendsAndLink: "Friends and anyone with my link"
        case .friendsOnly: "Friends only"
        }
    }
}

/// Your username and who can find or challenge you. Held on the server.
struct FriendSettings: Equatable, Sendable {
    var username: String?
    var showInSearch: Bool
    var challengePolicy: FriendChallengePolicy

    /// What the username field keeps of what was typed or pasted.
    static func sanitizedUsername(_ text: String) -> String {
        String(text.lowercased().filter { character in
            character.isASCII && (character.isLowercase || character.isNumber || character == "_")
        }.prefix(20))
    }

    /// The server's rule: `^[a-z0-9_]{3,20}$`.
    static func isValidUsername(_ username: String) -> Bool {
        username.count >= 3 && sanitizedUsername(username) == username
    }
}

/// How someone stands to you, as the server says it.
enum FriendRelationship: String, Equatable, Sendable {
    case none, requested, incoming, friend
}

/// Someone found in search or on your Friends lists. Never activity data.
struct FriendPerson: Equatable, Identifiable, Sendable {
    let id: UUID
    let displayName: String
    /// Nil until the server lets you see it.
    let username: String?
    var relationship: FriendRelationship

    /// The key of their person page.
    var identity: String { RemoteCompetitionOpponentIdentity.identity(for: id) }
}

/// A person's finished 1v1 weeks, across everyone they've played.
struct CompetitionCareer: Equatable, Sendable {
    var wins = 0
    var losses = 0
    var ties = 0
    var people = 0
    var belts = 0
    var winStreak = 0
    var bestWeek = 0.0

    var weeks: Int { wins + losses + ties }

    /// "14–6", or "14–6–2" with ties, as a record reads everywhere else.
    var text: String {
        ([wins, losses] + (ties > 0 ? [ties] : [])).map(String.init).joined(separator: "–")
    }
}

struct FriendsList: Equatable, Sendable {
    var friends: [FriendPerson] = []
    /// Requests to you, newest first.
    var incoming: [FriendPerson] = []
    /// Your requests, newest first.
    var outgoing: [FriendPerson] = []
}
