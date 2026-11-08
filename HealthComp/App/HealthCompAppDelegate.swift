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
#if DEBUG
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
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        if let reaction = CompetitionReactionAlert.request(
            actionIdentifier: response.actionIdentifier,
            categoryIdentifier: content.categoryIdentifier,
            userInfo: content.userInfo
        ) {
            // In the background, without opening the app. iOS keeps it
            // running until this returns; the next open shows what you sent.
            try? await CompetitionReactionAlert.send?(reaction)
            return
        }
        guard let route = CompetitionRoute(
            userInfo: response.notification.request.content.userInfo
        ) else {
            return
        }
        _ = CompetitionRoutingEnvironment.liveHub.enqueue(route)
    }
}
