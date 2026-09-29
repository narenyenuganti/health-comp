import Foundation
import OSLog

@main
enum CompetitionRefreshDiagnosticTests {
    static func main() {
        do {
            try run()
        } catch {
            // Never print unexpected log content or system error descriptions.
            print("FAIL: competition_refresh_diagnostic_output")
            exit(1)
        }
    }

    private static func run() throws {
        let start = Date()
        let failures: [RemoteCompetitionRuntimeFailure] = [
            .cancelled, .unauthenticated, .forbidden, .discoveryUnavailable,
            .profileMismatch, .competitionNotMaterialized,
            .serverContractMismatch, .storageUnavailable, .cursorRetryLimitExceeded,
        ]
        for failure in failures {
            failure.recordRefreshDiagnostic()
        }
        Logger(
            subsystem: "com.narenyenuganti.HealthComp.staging",
            category: "CompetitionRefreshTest"
        ).notice("capture_ready")

#if HEALTHCOMP_STAGING
        let expected = [
            "refresh_cancelled", "refresh_unauthenticated", "refresh_forbidden",
            "refresh_discovery_unavailable", "refresh_profile_mismatch",
            "refresh_competition_not_materialized", "refresh_server_contract_mismatch",
            "refresh_storage_unavailable", "refresh_cursor_retry_limit_exceeded",
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
                    "CompetitionRefresh", "CompetitionRefreshTest"
                )
            ).compactMap { $0 as? OSLogEntryLog }
            let ready = entries.contains {
                $0.category == "CompetitionRefreshTest"
                    && $0.composedMessage == "capture_ready"
            }
            let actual = entries.filter { $0.category == "CompetitionRefresh" }
                .map(\.composedMessage)
            if ready && actual == expected {
#if HEALTHCOMP_STAGING
                print("PASS: staging_refresh_fixed_diagnostic_output")
#else
                print("PASS: ordinary_build_refresh_diagnostics_disabled")
#endif
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw Failure()
    }

    private struct Failure: Error {}
}
