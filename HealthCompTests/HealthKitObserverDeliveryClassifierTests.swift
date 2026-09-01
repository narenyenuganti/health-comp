import CompetitionCore
import UIKit
import XCTest

@testable import HealthComp

final class HealthKitObserverDeliveryClassifierTests: XCTestCase {
    func testUnknownInitialInactiveAndInitialBackgroundFailClosedToForeground() {
        let classifier = HealthKitObserverDeliveryClassifier()

        XCTAssertEqual(
            classifier.currentTrigger(),
            .observerWakeupForeground
        )

        classifier.observe(.inactive)
        XCTAssertEqual(
            classifier.currentTrigger(),
            .observerWakeupForeground
        )

        classifier.observe(.background)
        XCTAssertEqual(
            classifier.currentTrigger(),
            .observerWakeupForeground
        )
    }

    func testObservedActiveBackgroundAndReactivationTransitionsTruthfully() {
        let classifier = HealthKitObserverDeliveryClassifier()

        classifier.observe(.active)
        XCTAssertEqual(
            classifier.currentTrigger(),
            .observerWakeupForeground
        )

        classifier.observe(.inactive)
        XCTAssertEqual(
            classifier.currentTrigger(),
            .observerWakeupForeground
        )

        classifier.observe(.background)
        XCTAssertEqual(
            classifier.currentTrigger(),
            .observerWakeupBackground
        )

        classifier.observe(.active)
        XCTAssertEqual(
            classifier.currentTrigger(),
            .observerWakeupForeground
        )

        classifier.observe(.background)
        XCTAssertEqual(
            classifier.currentTrigger(),
            .observerWakeupBackground
        )
    }

    func testWillEnterForegroundFailsClosedBeforeReactivation() {
        let classifier = HealthKitObserverDeliveryClassifier()
        classifier.observe(.active)
        classifier.observe(.background)
        XCTAssertEqual(
            classifier.currentTrigger(),
            .observerWakeupBackground
        )

        classifier.observe(.inactive)

        XCTAssertEqual(
            classifier.currentTrigger(),
            .observerWakeupForeground
        )
    }

    func testWillEnterForegroundNotificationFailsClosedSynchronously() {
        let notificationCenter = NotificationCenter()
        let classifier = HealthKitObserverDeliveryClassifier()
        let bridge = HealthKitObserverDeliveryLifecycleBridge(
            classifier: classifier,
            notificationCenter: notificationCenter
        )
        bridge.observe(.active)
        bridge.observe(.background)
        XCTAssertEqual(
            classifier.currentTrigger(),
            .observerWakeupBackground
        )

        notificationCenter.post(
            name: UIScene.willEnterForegroundNotification,
            object: nil
        )

        XCTAssertEqual(
            classifier.currentTrigger(),
            .observerWakeupForeground
        )
        withExtendedLifetime(bridge) {}
    }
}
