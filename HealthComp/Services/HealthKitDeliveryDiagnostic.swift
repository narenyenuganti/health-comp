#if HEALTHCOMP_STAGING
import OSLog
#endif

/// Fixed labels only: never accept identities, Health values, tokens or errors.
enum HealthKitDeliveryDiagnostic: String {
    case registrationStarted = "registration_started"
    case registrationSucceeded = "registration_succeeded"
    case registrationFailed = "registration_failed"
    case callbackArrived = "callback_arrived"
    case receiptStored = "receipt_stored"
    case receiptAlreadyStored = "receipt_already_stored"
    case receiptPersistenceFailed = "receipt_persistence_failed"
    case completionCalled = "completion_called"

    func record() {
#if HEALTHCOMP_STAGING
        Self.logger.notice("\(rawValue, privacy: .public)")
#endif
    }

#if HEALTHCOMP_STAGING
    private static let logger = Logger(
        subsystem: "com.narenyenuganti.HealthComp.staging",
        category: "HealthKitDelivery"
    )
#endif
}
