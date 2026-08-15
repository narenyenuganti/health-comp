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
    private enum UserInfoKey {
        static let version = "healthcomp.route.v"
        static let kind = "healthcomp.route.kind"
        static let competitionID = "healthcomp.route.competitionID"
    }

    enum Kind: Hashable, Sendable {
        case competition
        case claimInvite
    }

    case competition(CompetitionID)
    case claimInvite(CompetitionInviteClaimToken)

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
        case "healthcomp":
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

            default:
                return nil
            }

        case "https":
            guard let allowedInviteHost,
                  CompetitionInviteHost.isValid(allowedInviteHost),
                  url.host == allowedInviteHost,
                  encodedPath.hasPrefix("/invite/"),
                  !encodedPath.hasSuffix("/")
            else {
                return nil
            }
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
        case .claimInvite:
            // Invite tokens are intentionally forbidden from notification
            // payloads. An empty payload fails closed when decoded.
            return [:]
        }
    }

    var kind: Kind {
        switch self {
        case .competition:
            .competition
        case .claimInvite:
            .claimInvite
        }
    }
}

struct CompetitionImmediateNotificationRequest: Equatable, Sendable {
    let identifier: String
    let content: CompetitionNotificationContent
    let route: CompetitionRoute
}

struct CompetitionScheduledNotificationRequest: Equatable, Sendable {
    let identifier: String
    let content: CompetitionNotificationContent
    let dateComponents: DateComponents
    let route: CompetitionRoute
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
            content: makeContent(request.content, route: request.route),
            trigger: nil
        )
    }

    private static func makeContent(
        _ notification: CompetitionNotificationContent,
        route: CompetitionRoute
    ) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo = route.userInfo
        return content
    }
}
#endif
