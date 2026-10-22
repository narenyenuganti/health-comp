#if HEALTHCOMP_STAGING
import Foundation
import XCTest
@testable import HealthComp

final class StagingActivityObservationTests: XCTestCase {
    func testOnlyAnExplicitlyArmedRefreshProducesFixedAggregateCounts() async throws {
        let controls = StagingScoringOperatorControls()
        controls.bind(StagingScoringCaptureOwner())

        let unarmed = await controls.observeActivity {
            StagingScoringOperatorControls.recordActivity(.readStarted)
            return 17
        }
        XCTAssertEqual(unarmed, 17)
        XCTAssertEqual(controls.activityDisplayState(), .off)

        XCTAssertTrue(controls.requestActivityObservation())
        XCTAssertFalse(controls.requestActivityObservation())
        let result = await controls.observeActivity {
            StagingScoringOperatorControls.recordActivity(.readStarted)
            StagingScoringOperatorControls.recordActivity(.snapshotDays, count: 3)
            StagingScoringOperatorControls.recordActivity(.missingDays, count: 4)
            StagingScoringOperatorControls.recordActivity(.unchangedTerminal)
            return 23
        }

        XCTAssertEqual(result, 23)
        XCTAssertEqual(controls.activityDisplayState(), .complete(.init(counts: [
            .readStarted: 1, .snapshotDays: 3, .missingDays: 4,
            .unchangedTerminal: 1,
        ])))
        XCTAssertFalse(controls.requestActivityObservation())
    }

    func testExpiryDiscardsCountsAndReadingNeverExtendsTheWindow() async {
        let clock = ActivityObservationClock()
        let controls = StagingScoringOperatorControls(now: { clock.now })
        controls.bind(StagingScoringCaptureOwner())
        XCTAssertTrue(controls.requestActivityObservation())
        await controls.observeActivity {
            StagingScoringOperatorControls.recordActivity(.readStarted)
            clock.advance(seconds: 599)
            XCTAssertEqual(controls.activityDisplayState(), .running)
            clock.advance(seconds: 1)
            StagingScoringOperatorControls.recordActivity(.queuedRevisions)
        }
        XCTAssertEqual(controls.activityDisplayState(), .closed)
        XCTAssertFalse(controls.requestActivityObservation())
    }

    func testOwnerReplacementRejectsLateCountersFromTheOldOperation() async {
        let controls = StagingScoringOperatorControls()
        let old = StagingScoringCaptureOwner()
        controls.bind(old)
        XCTAssertTrue(controls.requestActivityObservation())
        await controls.observeActivity {
            StagingScoringOperatorControls.recordActivity(.missingDays, count: 7)
            controls.bind(StagingScoringCaptureOwner())
            XCTAssertEqual(controls.activityDisplayState(), .off)
            XCTAssertTrue(controls.requestActivityObservation())
            await controls.observeActivity {
                StagingScoringOperatorControls.recordActivity(.queuedRevisions)
            }
            StagingScoringOperatorControls.recordActivity(.readFailed)
            controls.cancel(for: old)
        }
        XCTAssertEqual(controls.activityDisplayState(), .complete(.init(counts: [
            .queuedRevisions: 1,
        ])))
    }

    func testInactivityClearsActivityEvenWhenHTTPResponseCaptureWasNeverArmed() async {
        let controls = StagingScoringOperatorControls()
        controls.bind(StagingScoringCaptureOwner())
        XCTAssertTrue(controls.requestActivityObservation())
        await controls.observeActivity {
            StagingScoringOperatorControls.recordActivity(.readStarted)
            controls.cancelStartedCapture()
            StagingScoringOperatorControls.recordActivity(.queuedRevisions)
        }
        XCTAssertEqual(controls.activityDisplayState(), .closed)
        XCTAssertEqual(controls.displayState(), .off)
    }

    func testHTTPClosureDoesNotDiscardActivityObservation() async {
        let controls = StagingScoringOperatorControls()
        let owner = StagingScoringCaptureOwner()
        controls.bind(owner)
        XCTAssertTrue(controls.requestActivityObservation())
        XCTAssertTrue(controls.requestArm())
        await controls.observeActivity {
            controls.cancel(for: owner)
            StagingScoringOperatorControls.recordActivity(.readStarted)
        }
        XCTAssertEqual(controls.displayState(), .closed)
        XCTAssertEqual(controls.activityDisplayState(), .complete(.init(counts: [
            .readStarted: 1,
        ])))
        XCTAssertTrue(controls.cancelCapture())
        XCTAssertEqual(controls.activityDisplayState(), .complete(.init(counts: [
            .readStarted: 1,
        ])))
    }

    func testFailureIsRethrownWithoutChangingTheOriginalOperation() async {
        enum Expected: Error { case failure }
        let controls = StagingScoringOperatorControls()
        controls.bind(StagingScoringCaptureOwner())
        XCTAssertTrue(controls.requestActivityObservation())
        do {
            try await controls.observeActivity {
                StagingScoringOperatorControls.recordActivity(.readFailed)
                throw Expected.failure
            }
            XCTFail("The observation must not swallow the operation's failure")
        } catch Expected.failure {} catch {
            XCTFail("The observation must preserve the original error")
        }
        XCTAssertEqual(controls.activityDisplayState(), .complete(.init(counts: [
            .readFailed: 1,
        ])))
    }

    func testDetachedWorkCannotContributeAndCountsStayBounded() async {
        let controls = StagingScoringOperatorControls()
        XCTAssertFalse(controls.requestActivityObservation())
        controls.bind(StagingScoringCaptureOwner())
        XCTAssertTrue(controls.requestActivityObservation())
        await controls.observeActivity {
            await Task.detached {
                StagingScoringOperatorControls.recordActivity(.readFailed)
            }.value
            StagingScoringOperatorControls.recordActivity(.missingDays, count: -1)
            StagingScoringOperatorControls.recordActivity(.snapshotDays, count: Int.max)
            StagingScoringOperatorControls.recordActivity(.snapshotDays)
        }
        XCTAssertEqual(controls.activityDisplayState(), .complete(.init(counts: [
            .snapshotDays: 10_000,
        ])))
        controls.cancelActivityObservation()
        XCTAssertEqual(controls.activityDisplayState(), .closed)
    }

    func testCancelledOperationDiscardsItsObservation() async {
        let controls = StagingScoringOperatorControls()
        controls.bind(StagingScoringCaptureOwner())
        XCTAssertTrue(controls.requestActivityObservation())
        await Task {
            await controls.observeActivity {
                StagingScoringOperatorControls.recordActivity(.readStarted)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }.value
        XCTAssertEqual(controls.activityDisplayState(), .closed)
    }
}

private final class ActivityObservationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(seconds: Int) {
        lock.withLock { instant = instant + .seconds(seconds) }
    }
}
#endif
