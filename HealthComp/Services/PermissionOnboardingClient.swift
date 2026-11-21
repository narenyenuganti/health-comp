import Dependencies
import Foundation
import HealthKit

enum PermissionOnboardingStep: Equatable, Sendable {
    case health
    case notifications
}

enum HealthAccessStatus: Equatable, Sendable {
    case unavailable
    case notRequested
    case requested
}

struct PermissionOnboardingClient: Sendable {
    var requestHealthAccess: @Sendable () async -> Void
    var deferNotifications: @Sendable () async -> Void
    var healthAccess: @Sendable () async -> HealthAccessStatus
    var notificationsDeferred: @Sendable () async -> Bool

    static func steps(health: HealthAccessStatus) -> [PermissionOnboardingStep] {
        health == .notRequested ? [.health] : []
    }

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
