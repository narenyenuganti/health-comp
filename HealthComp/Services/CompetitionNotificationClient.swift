import Dependencies
import DependenciesMacros
import Foundation
import UserNotifications

@DependencyClient
struct CompetitionNotificationClient: Sendable {
    var requestAuthorization: @Sendable () async throws -> Bool
    var schedule: @Sendable (_ alert: CompetitionAlert) async throws -> Void
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
        schedule: { alert in
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: alert.id.uuidString,
                content: content,
                trigger: nil
            )
            try await UNUserNotificationCenter.current().add(request)
        }
    )
}
