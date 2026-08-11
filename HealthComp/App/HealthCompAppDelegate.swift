import UIKit
import UserNotifications

final class HealthCompAppDelegate: NSObject,
    UIApplicationDelegate,
    UNUserNotificationCenterDelegate {
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
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let route = CompetitionRoute(
            userInfo: response.notification.request.content.userInfo
        ) else {
            return
        }
        _ = CompetitionRoutingEnvironment.liveHub.enqueue(route)
    }
}
