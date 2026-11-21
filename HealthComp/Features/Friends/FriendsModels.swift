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

struct FriendSettings: Equatable, Sendable {
    var username: String?
    var showInSearch: Bool
    var challengePolicy: FriendChallengePolicy

    static func sanitizedUsername(_ text: String) -> String {
        String(text.lowercased().filter { character in
            character.isASCII && (character.isLowercase || character.isNumber || character == "_")
        }.prefix(20))
    }

    static func isValidUsername(_ username: String) -> Bool {
        username.count >= 3 && sanitizedUsername(username) == username
    }
}

enum FriendRelationship: String, Equatable, Sendable {
    case none, requested, incoming, friend
}

struct FriendPerson: Equatable, Identifiable, Sendable {
    let id: UUID
    let displayName: String
    let username: String?
    var relationship: FriendRelationship

    var identity: String { RemoteCompetitionOpponentIdentity.identity(for: id) }
}

struct CompetitionCareer: Equatable, Sendable {
    var wins = 0
    var losses = 0
    var ties = 0
    var people = 0
    var belts = 0
    var winStreak = 0
    var bestWeek = 0.0

    var weeks: Int { wins + losses + ties }

    var text: String {
        ([wins, losses] + (ties > 0 ? [ties] : [])).map(String.init).joined(separator: "–")
    }
}

struct FriendsList: Equatable, Sendable {
    var friends: [FriendPerson] = []
    var incoming: [FriendPerson] = []
    var outgoing: [FriendPerson] = []
}
