import Dependencies
import Foundation
import HealthKit

/// A first-run screen that explains an iOS permission before iOS asks.
enum PermissionOnboardingStep: Equatable, Sendable {
    case health
    case notifications
}

struct PermissionOnboardingClient: Sendable {
    var pendingSteps: @Sendable () async -> [PermissionOnboardingStep]
    var requestHealthAccess: @Sendable () async -> Void
    var requestNotifications: @Sendable () async -> Void
    /// Records "Not now", so the notifications screen shows only once. The
    /// Home button still turns them on later.
    var deferNotifications: @Sendable () async -> Void

    /// Health comes first because scoring needs it. iOS asks for Health only
    /// once, so its own request status says whether the screen is due.
    static func steps(
        healthNeedsRequest: Bool,
        notificationState: CompetitionNotificationAuthorizationState,
        notificationsDeferred: Bool
    ) -> [PermissionOnboardingStep] {
        var steps: [PermissionOnboardingStep] = []
        if healthNeedsRequest {
            steps.append(.health)
        }
        if notificationState == .notDetermined, !notificationsDeferred {
            steps.append(.notifications)
        }
        return steps
    }

    static let inert = PermissionOnboardingClient(
        pendingSteps: { [] },
        requestHealthAccess: {},
        requestNotifications: {},
        deferNotifications: {}
    )
}

extension PermissionOnboardingClient: TestDependencyKey {
    static let testValue = PermissionOnboardingClient.inert
}

extension PermissionOnboardingClient: DependencyKey {
    static let liveValue: PermissionOnboardingClient = {
        let healthStore = HKHealthStore()
        let notifications = CompetitionNotificationClient.liveValue
        let deferredKey = "healthcomp.onboarding.notificationsDeferred"
        return PermissionOnboardingClient(
            pendingSteps: {
                var healthNeedsRequest = false
                if HKHealthStore.isHealthDataAvailable() {
                    let status = try? await healthStore
                        .statusForAuthorizationRequest(
                            toShare: [],
                            read: HealthKitProvider.competitionReadTypes()
                        )
                    healthNeedsRequest = status == .shouldRequest
                }
                return steps(
                    healthNeedsRequest: healthNeedsRequest,
                    notificationState: await notifications
                        .authorizationState(),
                    notificationsDeferred: UserDefaults.standard.bool(
                        forKey: deferredKey
                    )
                )
            },
            requestHealthAccess: {
                // iOS never says whether reads were allowed, so either answer
                // moves on.
                try? await healthStore.requestAuthorization(
                    toShare: [],
                    read: HealthKitProvider.competitionReadTypes()
                )
            },
            requestNotifications: {
                _ = try? await notifications.requestAuthorization()
            },
            deferNotifications: {
                UserDefaults.standard.set(true, forKey: deferredKey)
            }
        )
    }()
}

extension DependencyValues {
    var permissionOnboardingClient: PermissionOnboardingClient {
        get { self[PermissionOnboardingClient.self] }
        set { self[PermissionOnboardingClient.self] = newValue }
    }
}
