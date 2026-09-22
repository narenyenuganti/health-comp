import Foundation
import OSLog

@main
enum HealthKitDeliveryDiagnosticTests {
    static func main() {
        do {
            try run()
        } catch {
            // Do not print unexpected log content or system error descriptions.
            print("FAIL: healthkit_delivery_diagnostic_output")
            exit(1)
        }
    }

    private static func run() throws {
        let start = Date()
        HealthKitDeliveryDiagnostic.registrationStarted.record()
        HealthKitDeliveryDiagnostic.registrationSucceeded.record()
        HealthKitDeliveryDiagnostic.registrationFailed.record()
        HealthKitDeliveryDiagnostic.callbackArrived.record()
        HealthKitDeliveryDiagnostic.receiptStored.record()
        HealthKitDeliveryDiagnostic.receiptAlreadyStored.record()
        HealthKitDeliveryDiagnostic.receiptPersistenceFailed.record()
        HealthKitDeliveryDiagnostic.completionCalled.record()
        Logger(
            subsystem: "com.narenyenuganti.HealthComp.staging",
            category: "HealthKitDeliveryTest"
        ).notice("capture_ready")

#if HEALTHCOMP_STAGING
        let expected = [
            "registration_started", "registration_succeeded", "registration_failed",
            "callback_arrived", "receipt_stored", "receipt_already_stored",
            "receipt_persistence_failed", "completion_called",
        ]
#else
        let expected: [String] = []
#endif
        let deadline = Date().addingTimeInterval(10)
        repeat {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(
                at: store.position(date: start),
                matching: NSPredicate(
                    format: "subsystem == %@ AND (category == %@ OR category == %@)",
                    "com.narenyenuganti.HealthComp.staging",
                    "HealthKitDelivery", "HealthKitDeliveryTest"
                )
            ).compactMap { $0 as? OSLogEntryLog }
            let ready = entries.contains {
                $0.category == "HealthKitDeliveryTest"
                    && $0.composedMessage == "capture_ready"
            }
            let actual = entries.filter { $0.category == "HealthKitDelivery" }
                .map(\.composedMessage)
            if ready && actual == expected {
#if HEALTHCOMP_STAGING
                print("PASS: staging_healthkit_fixed_diagnostic_output")
#else
                print("PASS: ordinary_build_healthkit_diagnostics_disabled")
#endif
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw Failure()
    }

    private struct Failure: Error {}
}
