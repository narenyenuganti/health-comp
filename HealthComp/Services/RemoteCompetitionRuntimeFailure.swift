#if HEALTHCOMP_STAGING
import OSLog
#endif

enum RemoteCompetitionRuntimeFailure: Error, Equatable, Sendable {
    case cancelled
    case unauthenticated
    case forbidden
    case discoveryUnavailable
    case profileMismatch
    case competitionNotMaterialized
    case serverContractMismatch
    case storageUnavailable
    case cursorRetryLimitExceeded

    enum ContractStage: String, Sendable {
        case cachedJournal = "refresh_contract_stage_cached_journal"
        case history = "refresh_contract_stage_history"
        case materialization = "refresh_contract_stage_materialization"
        case clock = "refresh_contract_stage_clock"
        case downloadedChanges = "refresh_contract_stage_downloaded_changes"
        case serverLifecycle = "refresh_contract_stage_server_lifecycle"
        case ownerScores = "refresh_contract_stage_owner_scores"
        case finalAttestation = "refresh_contract_stage_final_attestation"
    }

    /// Fixed categories only, with no IDs, Health values, tokens or error text.
    func recordRefreshDiagnostic(contractStage: ContractStage? = nil) {
#if HEALTHCOMP_STAGING
        let label: String
        switch self {
        case .cancelled: label = "refresh_cancelled"
        case .unauthenticated: label = "refresh_unauthenticated"
        case .forbidden: label = "refresh_forbidden"
        case .discoveryUnavailable: label = "refresh_discovery_unavailable"
        case .profileMismatch: label = "refresh_profile_mismatch"
        case .competitionNotMaterialized:
            label = "refresh_competition_not_materialized"
        case .serverContractMismatch:
            label = contractStage?.rawValue ?? "refresh_server_contract_mismatch"
        case .storageUnavailable: label = "refresh_storage_unavailable"
        case .cursorRetryLimitExceeded:
            label = "refresh_cursor_retry_limit_exceeded"
        }
        Self.refreshLogger.notice("\(label, privacy: .public)")
#endif
    }

#if HEALTHCOMP_STAGING
    private static let refreshLogger = Logger(
        subsystem: "com.narenyenuganti.HealthComp.staging",
        category: "CompetitionRefresh"
    )
#endif
}
