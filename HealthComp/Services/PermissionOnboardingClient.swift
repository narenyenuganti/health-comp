import Dependencies
import Foundation
import HealthKit

/// A first-run screen that explains an iOS permission before iOS asks.
enum PermissionOnboardingStep: Equatable, Sendable {
    case health
    case notifications
}

/// What HealthKit will say. It never says whether reads were allowed, only
/// whether iOS has asked.
enum HealthAccessStatus: Equatable, Sendable {
    case unavailable
    case notRequested
    case requested
}

struct PermissionOnboardingClient: Sendable {
    var requestHealthAccess: @Sendable () async -> Void
    /// Records Not now on the notifications prompt.
    var deferNotifications: @Sendable () async -> Void
    var healthAccess: @Sendable () async -> HealthAccessStatus
    var notificationsDeferred: @Sendable () async -> Bool

    /// The first run is Health only; notifications are asked once a match
    /// with a person exists.
    static func steps(health: HealthAccessStatus) -> [PermissionOnboardingStep] {
        health == .notRequested ? [.health] : []
    }

    /// `notificationsDeferred: true` keeps hosts that inject this, like the
    /// local Test Lab, from ever showing the notifications prompt.
    static let inert = PermissionOnboardingClient(
        requestHealthAccess: {},
        deferNotifications: {},
        healthAccess: { .requested },
        notificationsDeferred: { true }
    )
}

extension PermissionOnboardingClient: TestDependencyKey {
    static let testValue = PermissionOnboardingClient.inert
}

extension PermissionOnboardingClient: DependencyKey {
    static let liveValue: PermissionOnboardingClient = {
        let healthStore = HKHealthStore()
        let deferredKey = "healthcomp.onboarding.notificationsDeferred"
        return PermissionOnboardingClient(
            requestHealthAccess: {
                // iOS never says whether reads were allowed, so either answer
                // moves on.
                try? await healthStore.requestAuthorization(
                    toShare: [],
                    read: HealthKitProvider.competitionReadTypes()
                )
            },
            deferNotifications: {
                UserDefaults.standard.set(true, forKey: deferredKey)
            },
            healthAccess: {
                guard HKHealthStore.isHealthDataAvailable() else {
                    return .unavailable
                }
                do {
                    let status = try await healthStore
                        .statusForAuthorizationRequest(
                            toShare: [],
                            read: HealthKitProvider.competitionReadTypes()
                        )
                    return status == .shouldRequest ? .notRequested : .requested
                } catch {
                    return .unavailable
                }
            },
            notificationsDeferred: {
                UserDefaults.standard.bool(forKey: deferredKey)
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
