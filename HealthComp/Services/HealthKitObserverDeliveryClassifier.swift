import CompetitionCore
import Foundation
import UIKit

extension ActivityRefreshTrigger {
    var isHealthKitObserverDelivery: Bool {
        switch self {
        case .observerWakeupForeground, .observerWakeupBackground:
            return true
        case .launch,
             .foreground,
             .pullToRefresh,
             .summaryUpdate,
             .dayBoundary,
             .timeZoneChange,
             .protectedDataAvailable,
             .reconciliationProbe:
            return false
        }
    }
}

enum HealthKitObserverLifecyclePhase: Equatable, Sendable {
    case active
    case inactive
    case background
}

final class HealthKitObserverDeliveryClassifier: @unchecked Sendable {
    static let production = HealthKitObserverDeliveryClassifier()

    private let lock = NSLock()
    private var currentPhase: HealthKitObserverLifecyclePhase?
    private var hasObservedActive = false

    func observe(_ phase: HealthKitObserverLifecyclePhase) {
        lock.withLock {
            currentPhase = phase
            if phase == .active {
                hasObservedActive = true
            }
        }
    }

    func currentTrigger() -> ActivityRefreshTrigger {
        lock.withLock {
            if hasObservedActive, currentPhase == .background {
                return .observerWakeupBackground
            }
            return .observerWakeupForeground
        }
    }
}

final class HealthKitObserverDeliveryLifecycleBridge: @unchecked Sendable {
    static let production = HealthKitObserverDeliveryLifecycleBridge(
        classifier: .production
    )

    private let classifier: HealthKitObserverDeliveryClassifier
    private let notificationCenter: NotificationCenter
    private let observerTokens: [NSObjectProtocol]

    init(
        classifier: HealthKitObserverDeliveryClassifier,
        notificationCenter: NotificationCenter = .default
    ) {
        self.classifier = classifier
        self.notificationCenter = notificationCenter
        self.observerTokens = [
            notificationCenter.addObserver(
                forName: UIScene.willEnterForegroundNotification,
                object: nil,
                queue: nil
            ) { [classifier] _ in
                classifier.observe(.inactive)
            },
            notificationCenter.addObserver(
                forName: UIScene.didActivateNotification,
                object: nil,
                queue: nil
            ) { [classifier] _ in
                classifier.observe(.active)
            },
            notificationCenter.addObserver(
                forName: UIScene.willDeactivateNotification,
                object: nil,
                queue: nil
            ) { [classifier] _ in
                classifier.observe(.inactive)
            },
            notificationCenter.addObserver(
                forName: UIScene.didEnterBackgroundNotification,
                object: nil,
                queue: nil
            ) { [classifier] _ in
                classifier.observe(.background)
            },
        ]
    }

    deinit {
        observerTokens.forEach(notificationCenter.removeObserver)
    }

    func observe(_ phase: HealthKitObserverLifecyclePhase) {
        classifier.observe(phase)
    }
}
