import CompetitionCore
#if canImport(Dependencies)
import Dependencies
import DependenciesMacros
#endif
import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

enum CompetitionNotificationAuthorizationState: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    var permitsNotifications: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined, .denied:
            false
        }
    }
}

struct CompetitionNotificationContent: Equatable, Sendable {
    let title: String
    let body: String
}

struct CompetitionInviteClaimToken:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    let rawValue: String

    init?(rawValue: String) {
        guard (try? CompetitionInviteClaimRequest(token: rawValue)) != nil else {
            return nil
        }
        self.rawValue = rawValue
    }

    var description: String { "[REDACTED INVITE TOKEN]" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["value": description])
    }
}

/// A person's reusable challenge link code (`/c/<code>`). It only lets
/// someone create a pending challenge to that person.
struct CompetitionChallengeLinkCode:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.range(
            of: "^[A-Za-z0-9_-]{22}$",
            options: .regularExpression
        ) != nil else {
            return nil
        }
        self.rawValue = rawValue
    }

    var description: String { "[REDACTED CHALLENGE LINK]" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["value": description])
    }
}

struct CompetitionInviteShareLink:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    let url: URL

    init?(host: String, token: CompetitionInviteClaimToken) {
        guard CompetitionInviteHost.isValid(host),
              let url = URL(
                string: "https://\(host)/invite/\(token.rawValue)"
              ),
              CompetitionRoute(
                url: url,
                allowedInviteHost: host
              ) == .claimInvite(token)
        else {
            return nil
        }
        self.url = url
    }

    init?(fallbackToken token: CompetitionInviteClaimToken) {
        guard let url = URL(
            string: "\(CompetitionRoute.customURLScheme)://invite/\(token.rawValue)"
        ),
            CompetitionRoute(url: url) == .claimInvite(token)
        else {
            return nil
        }
        self.url = url
    }

    var description: String { "[REDACTED INVITE LINK]" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["value": description])
    }
}

enum CompetitionInviteHost {
    static func isValid(_ value: String) -> Bool {
        guard value == value.lowercased(),
              !value.hasSuffix("."),
              value.range(
                of: "^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$",
                options: .regularExpression
              ) != nil
        else {
            return false
        }
        return true
    }
}

enum CompetitionRoute: Equatable, Sendable {
    // Co-installed Staging must not receive production invitation links.
    #if HEALTHCOMP_STAGING
    static let customURLScheme = "healthcomp-staging"
    #else
    static let customURLScheme = "healthcomp"
    #endif

    private enum UserInfoKey {
        static let version = "healthcomp.route.v"
        static let kind = "healthcomp.route.kind"
        static let competitionID = "healthcomp.route.competitionID"
    }

    enum Kind: Hashable, Sendable {
        case competition
        case claimInvite
        case challengeLink
    }

    case competition(CompetitionID)
    case claimInvite(CompetitionInviteClaimToken)
    /// Someone's challenge link: offers to challenge them.
    case challengeLink(CompetitionChallengeLinkCode)

    /// The custom-scheme link that opens a match, for widgets. Lowercased:
    /// `init?(url:)` rejects an uppercase uuid.
    var url: URL? {
        guard case let .competition(id) = self else { return nil }
        return URL(string: "\(Self.customURLScheme)://competition/\(id.rawValue.uuidString.lowercased())")
    }

    init?(url: URL) {
        self.init(
            url: url,
            allowedInviteHost: CompetitionInviteLinkConfiguration.live.host
        )
    }

    init?(url: URL, allowedInviteHost: String?) {
        guard url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil
        else {
            return nil
        }
        let encodedPath = url.path(percentEncoded: true)
        switch url.scheme {
        case let scheme? where scheme == Self.customURLScheme:
            guard encodedPath.first == "/",
                  !encodedPath.hasSuffix("/"),
                  encodedPath.dropFirst().contains("/") == false
            else {
                return nil
            }
            let pathValue = String(encodedPath.dropFirst())
            switch url.host {
            case "competition":
                guard let uuid = UUID(uuidString: pathValue),
                      uuid.uuidString.lowercased() == pathValue
                else {
                    return nil
                }
                self = .competition(CompetitionID(uuid))

            case "invite":
                guard let token = CompetitionInviteClaimToken(
                    rawValue: pathValue
                ) else {
                    return nil
                }
                self = .claimInvite(token)

            case "challenge":
                guard let code = CompetitionChallengeLinkCode(
                    rawValue: pathValue
                ) else {
                    return nil
                }
                self = .challengeLink(code)

            default:
                return nil
            }

        case "https":
            guard let allowedInviteHost,
                  CompetitionInviteHost.isValid(allowedInviteHost),
                  url.host == allowedInviteHost,
                  !encodedPath.hasSuffix("/")
            else {
                return nil
            }
            if encodedPath.hasPrefix("/c/") {
                let pathValue = String(encodedPath.dropFirst("/c/".count))
                guard let code = CompetitionChallengeLinkCode(
                    rawValue: pathValue
                ) else {
                    return nil
                }
                self = .challengeLink(code)
                return
            }
            guard encodedPath.hasPrefix("/invite/") else { return nil }
            let pathValue = String(encodedPath.dropFirst("/invite/".count))
            guard !pathValue.isEmpty,
                  !pathValue.contains("/"),
                  let token = CompetitionInviteClaimToken(
                    rawValue: pathValue
                  )
            else {
                return nil
            }
            self = .claimInvite(token)

        default:
            return nil
        }
    }

    init?(userInfo: [AnyHashable: Any]) {
        let routeKeys = Set([
            UserInfoKey.version,
            UserInfoKey.kind,
            UserInfoKey.competitionID,
        ])
        let stringKeys = Set(userInfo.keys.compactMap { $0 as? String })
        guard stringKeys.count == userInfo.count else { return nil }
        if stringKeys == routeKeys.union(["aps"]) {
            guard userInfo["aps"] is [String: Any] else { return nil }
        } else {
            guard stringKeys == routeKeys else { return nil }
        }
        guard let version = userInfo[UserInfoKey.version] as? Int,
              version == 1,
              userInfo[UserInfoKey.kind] as? String == "competition",
              let persistedID = userInfo[UserInfoKey.competitionID] as? String,
              let uuid = UUID(uuidString: persistedID),
              uuid.uuidString.lowercased() == persistedID
        else {
            return nil
        }
        self = .competition(CompetitionID(uuid))
    }

    var userInfo: [AnyHashable: Any] {
        switch self {
        case let .competition(id):
            return [
                UserInfoKey.version: 1,
                UserInfoKey.kind: "competition",
                UserInfoKey.competitionID:
                    id.rawValue.uuidString.lowercased(),
            ]
        case .claimInvite, .challengeLink:
            // Invite tokens and link codes are intentionally forbidden from
            // notification payloads. An empty payload fails closed when decoded.
            return [:]
        }
    }

    var kind: Kind {
        switch self {
        case .competition:
            .competition
        case .claimInvite:
            .claimInvite
        case .challengeLink:
            .challengeLink
        }
    }
}

/// A nil route (summaries, merged reminders) opens the app where it was.
struct CompetitionImmediateNotificationRequest: Equatable, Sendable {
    let identifier: String
    let content: CompetitionNotificationContent
    let route: CompetitionRoute?
    /// Lead changes and results: the alert carries the four reactions, aimed
    /// at this target in the route's match.
    var reactionTarget: CompetitionReactionTarget? = nil
}

/// The four reactions as actions on a local lead-change or result alert. The
/// category names the target and the route names the match, so the payload
/// stays exactly the route's. Sending one sets it (a second replaces the
/// first, never removes it) without opening the app, and plays no rain.
enum CompetitionReactionAlert {
    static func category(_ target: CompetitionReactionTarget) -> String {
        switch target {
        case let .day(ordinal): "competition.react.day.\(ordinal)"
        case .result: "competition.react.result"
        }
    }

    static func actionIdentifier(_ kind: CompetitionReactionKind) -> String {
        "competition.react.\(kind.rawValue)"
    }

    /// Matches have seven days.
    static let targets: [CompetitionReactionTarget] = [.result] + (1...7).map(CompetitionReactionTarget.day)

    /// What a reaction action sends; nil for a tap, a dismiss or anything else.
    static func request(
        actionIdentifier: String,
        categoryIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> CompetitionReactionRequest? {
        guard let kind = CompetitionReactionKind.allCases.first(where: {
            Self.actionIdentifier($0) == actionIdentifier
        }),
            let target = targets.first(where: { category($0) == categoryIdentifier }),
            case let .competition(id)? = CompetitionRoute(userInfo: userInfo)
        else { return nil }
        return CompetitionReactionRequest(competitionID: id.rawValue, target: target, kind: kind)
    }

    /// The reactions RPC, set once by the live composition before any
    /// delegate callback; nil in the Test Labs, so their alerts send nothing.
    nonisolated(unsafe) static var send: (@Sendable (CompetitionReactionRequest) async throws -> Void)?

    #if canImport(UserNotifications)
    /// Unlock first: the session lives in the keychain, and it keeps a
    /// pocket from reacting.
    static var categories: Set<UNNotificationCategory> {
        let actions = CompetitionReactionKind.allCases.map {
            UNNotificationAction(
                identifier: actionIdentifier($0),
                title: "\($0.emoji) \($0.spokenName)",
                options: [.authenticationRequired]
            )
        }
        return Set(targets.map {
            UNNotificationCategory(
                identifier: category($0),
                actions: actions,
                intentIdentifiers: []
            )
        })
    }
    #endif
}

struct CompetitionScheduledNotificationRequest: Equatable, Sendable {
    let identifier: String
    let content: CompetitionNotificationContent
    let dateComponents: DateComponents
    let route: CompetitionRoute?
}

/// One Notification Center thread per match, matching the server's
/// `thread-id`; summaries share their own thread.
func competitionNotificationThreadIdentifier(_ route: CompetitionRoute?) -> String {
    if case let .competition(id)? = route {
        return "competition:" + id.rawValue.uuidString.lowercased()
    }
    return "competition-summary"
}

#if canImport(Dependencies) && canImport(UserNotifications)
@DependencyClient
struct CompetitionNotificationClient: Sendable {
    var requestAuthorization: @Sendable () async throws -> Bool
    var authorizationState: @Sendable () async ->
        CompetitionNotificationAuthorizationState = { .denied }
    var upsert: @Sendable (
        _ request: CompetitionScheduledNotificationRequest
    ) async throws -> Void = { _ in }
    var postNow: @Sendable (
        _ request: CompetitionImmediateNotificationRequest
    ) async throws -> Void = { _ in }
    var pendingIDs: @Sendable (_ prefix: String) async -> Set<String> = {
        _ in []
    }
    var deliveredIDs: @Sendable (_ prefix: String) async -> Set<String> = {
        _ in []
    }
    var removePending: @Sendable (_ identifiers: [String]) async -> Void = {
        _ in
    }
    var removeDelivered: @Sendable (_ identifiers: [String]) async -> Void = {
        _ in
    }

}

extension CompetitionNotificationClient: TestDependencyKey {
    static let testValue = CompetitionNotificationClient()
}

extension DependencyValues {
    var competitionNotificationClient: CompetitionNotificationClient {
        get { self[CompetitionNotificationClient.self] }
        set { self[CompetitionNotificationClient.self] = newValue }
    }
}

extension CompetitionNotificationClient: DependencyKey {
    static let liveValue = CompetitionNotificationClient(
        requestAuthorization: {
            try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .badge, .sound]
            )
        },
        authorizationState: {
            let settings = await UNUserNotificationCenter.current()
                .notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                return .notDetermined
            case .denied:
                return .denied
            case .authorized:
                return .authorized
            case .provisional:
                return .provisional
            case .ephemeral:
                return .ephemeral
            @unknown default:
                return .denied
            }
        },
        upsert: { request in
            try await UNUserNotificationCenter.current().add(
                Self.makeRequest(request)
            )
        },
        postNow: { request in
            try await UNUserNotificationCenter.current().add(
                Self.makeRequest(request)
            )
        },
        pendingIDs: { prefix in
            let requests = await UNUserNotificationCenter.current()
                .pendingNotificationRequests()
            return Set(
                requests.lazy.map(\.identifier).filter {
                    $0.hasPrefix(prefix)
                }
            )
        },
        deliveredIDs: { prefix in
            let notifications = await UNUserNotificationCenter.current()
                .deliveredNotifications()
            return Set(
                notifications.lazy.map(\.request.identifier).filter {
                    $0.hasPrefix(prefix)
                }
            )
        },
        removePending: { identifiers in
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(
                    withIdentifiers: identifiers
                )
        },
        removeDelivered: { identifiers in
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    )

    private static func makeRequest(
        _ request: CompetitionScheduledNotificationRequest
    ) -> UNNotificationRequest {
        UNNotificationRequest(
            identifier: request.identifier,
            content: makeContent(request.content, route: request.route),
            trigger: UNCalendarNotificationTrigger(
                dateMatching: request.dateComponents,
                repeats: false
            )
        )
    }

    private static func makeRequest(
        _ request: CompetitionImmediateNotificationRequest
    ) -> UNNotificationRequest {
        UNNotificationRequest(
            identifier: request.identifier,
            content: makeContent(
                request.content,
                route: request.route,
                reactionTarget: request.reactionTarget
            ),
            trigger: nil
        )
    }

    private static func makeContent(
        _ notification: CompetitionNotificationContent,
        route: CompetitionRoute?,
        reactionTarget: CompetitionReactionTarget? = nil
    ) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo = route?.userInfo ?? [:]
        content.threadIdentifier = competitionNotificationThreadIdentifier(route)
        if case .competition? = route, let reactionTarget {
            content.categoryIdentifier = CompetitionReactionAlert.category(reactionTarget)
        }
        return content
    }
}
#endif
