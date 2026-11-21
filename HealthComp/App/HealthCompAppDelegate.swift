import UIKit
import UserNotifications

final class HealthCompAppDelegate: NSObject,
    UIApplicationDelegate,
    UNUserNotificationCenterDelegate {
    private let pushRegistrationHub: CompetitionPushRegistrationHub

    override init() {
        self.pushRegistrationHub = CompetitionPushRegistrationEnvironment
            .liveHub
        super.init()
    }

    init(pushRegistrationHub: CompetitionPushRegistrationHub) {
        self.pushRegistrationHub = pushRegistrationHub
        super.init()
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [
            UIApplication.LaunchOptionsKey: Any
        ]? = nil
    ) -> Bool {
        CompetitionWatchSync.shared.activate()
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--judges-decision") {
            UserDefaults.standard.removeObject(forKey: CompetitionMotionSeen.storageKey)
        }
        if ProcessInfo.processInfo.arguments.contains("--judges-notifications") {
            UNUserNotificationCenter.current().setNotificationCategories(CompetitionReactionAlert.categories)
        }
        guard case .disabled = CompetitionTestLabLaunchParser.decision(
            arguments: ProcessInfo.processInfo.arguments
        ) else {
            return true
        }
#endif
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories(
            CompetitionReactionAlert.categories
        )
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        pushRegistrationHub.publishDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        pushRegistrationHub.publishFailure()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        if CompetitionReactionAlert.route(userInfo: userInfo) == .friends {
            await MainActor.run {
                NotificationCenter.default.post(name: .healthCompFriendsPushReceived, object: nil)
            }
        }
        return []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        if let action = CompetitionReactionAlert.request(
            actionIdentifier: response.actionIdentifier,
            categoryIdentifier: content.categoryIdentifier,
            userInfo: content.userInfo
        ) {
            do {
                guard let send = CompetitionReactionAlert.send else { throw CancellationError() }
                try await send(action.recipientUserID, action.reaction)
            } catch {
                let notice = UNMutableNotificationContent()
                notice.title = "Reaction not sent"
                notice.body = "Open the match to send it again."
                notice.userInfo = content.userInfo
                try? await center.add(
                    UNNotificationRequest(identifier: UUID().uuidString, content: notice, trigger: nil)
                )
            }
            return
        }
        guard let route = CompetitionReactionAlert.route(userInfo: content.userInfo) else {
            return
        }
        _ = CompetitionRoutingEnvironment.liveHub.enqueue(route)
    }
}

extension Notification.Name {
    static let healthCompFriendsPushReceived = Notification.Name("healthcomp.friendsPushReceived")
}
