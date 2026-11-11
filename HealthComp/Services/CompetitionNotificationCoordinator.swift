import CompetitionCore
import Foundation

/// Source-neutral boundary for atomically recording notification decisions.
///
/// A successful `.appended` result means the semantic decision is durable. It
/// never means that iOS, APNs, or a user actually received a notification.
struct CompetitionNotificationDecisionCommitter: Sendable {
    typealias Replan = @Sendable (
        CompetitionNotificationCompetitionSnapshot
    ) throws -> [CompetitionNotificationDurableDecision]
    typealias Commit = @Sendable (
        CompetitionNotificationCompetitionSnapshot,
        @escaping Replan
    ) async throws -> CompetitionNotificationDecisionCommitResult

    let commit: Commit

    static func local(runtime: LocalCompetitionRuntime) -> Self {
        Self { competition, replan in
            try await runtime.commitNotificationDecisions(
                competitionID: competition.id,
                replan: { loaded in
                    let context = CompetitionEnvironmentContext(
                        instant: EnvironmentInstant(
                            wallDate: competition.evaluatedAt,
                            monotonic: MonotonicInstant(
                                epochID: "notification-replan-v1",
                                nanoseconds: 0
                            )
                        ),
                        timeZoneIdentifier: competition.timeZoneIdentifier
                    )
                    let isFreshEvaluation: Bool
                    if case .freshCompletedRefresh =
                        competition.evaluationFreshness {
                        isFreshEvaluation = true
                    } else {
                        isFreshEvaluation = false
                    }
                    let fresh = LocalCompetitionProjector
                        .notificationCompetition(
                            from: loaded,
                            context: context,
                            configuration: .live,
                            isFreshEvaluation: isFreshEvaluation
                        )
                    return try replan(fresh)
                }
            )
        }
    }

    static func remote(runtime: RemoteCompetitionRuntime) -> Self {
        Self { competition, replan in
            try await runtime.commitNotificationDecisions(
                competition: competition,
                replan: replan
            )
        }
    }
}

struct CompetitionNotificationCoordinatorClient: Sendable {
    var submit: @Sendable (
        CompetitionNotificationPlanningSnapshot
    ) async -> Void
    var reconcileLatest: @Sendable () async -> Void
    var cancelAll: @Sendable (CompetitionID) async -> Void

    static let noop = Self(
        submit: { _ in },
        reconcileLatest: {},
        cancelAll: { _ in }
    )

    static func live(
        runtime: LocalCompetitionRuntime?,
        planner: CompetitionNotificationPlanner,
        notifications: CompetitionNotificationClient,
        preferences: CompetitionNotificationPreferencesClient,
        reportError: @escaping @Sendable (_ context: String) -> Void = { _ in }
    ) -> Self {
        guard let runtime else { return .noop }
        return live(
            decisionCommitter: .local(runtime: runtime),
            planner: planner,
            notifications: notifications,
            preferences: preferences,
            reportError: reportError
        )
    }

    static func live(
        decisionCommitter: CompetitionNotificationDecisionCommitter?,
        planner: CompetitionNotificationPlanner,
        notifications: CompetitionNotificationClient,
        preferences: CompetitionNotificationPreferencesClient,
        reportError: @escaping @Sendable (_ context: String) -> Void = { _ in }
    ) -> Self {
        guard let decisionCommitter else { return .noop }
        let coordinator = CompetitionNotificationCoordinator(
            planner: planner,
            notifications: notifications,
            preferences: preferences,
            commitDecisions: decisionCommitter.commit,
            reportError: reportError
        )
        return Self(
            submit: { snapshot in await coordinator.submit(snapshot) },
            reconcileLatest: { await coordinator.reconcileLatest() },
            cancelAll: { id in await coordinator.cancelAll(id) }
        )
    }
}

actor CompetitionNotificationCoordinator {
    typealias ReplanDecisions = @Sendable (
        CompetitionNotificationCompetitionSnapshot
    ) throws -> [CompetitionNotificationDurableDecision]
    typealias CommitDecisions = @Sendable (
        CompetitionNotificationCompetitionSnapshot,
        @escaping ReplanDecisions
    ) async throws -> CompetitionNotificationDecisionCommitResult

    private let planner: CompetitionNotificationPlanner
    private let notifications: CompetitionNotificationClient
    private let preferences: CompetitionNotificationPreferencesClient
    private let commitDecisions: CommitDecisions
    private let reportError: @Sendable (_ context: String) -> Void

    private var latestSnapshot: CompetitionNotificationPlanningSnapshot?
    private var pendingSnapshot: CompetitionNotificationPlanningSnapshot?
    private var isDraining = false
    private var knownPendingRequests: [
        String: CompetitionScheduledNotificationRequest
    ] = [:]
    /// Records this coordinator committed that a later snapshot's journals
    /// may not show yet, so cross-match calls ("600 today" once) see them.
    private var committedRecords: [
        CompetitionID: [NotificationEmissionRecorded]
    ] = [:]

    init(
        planner: CompetitionNotificationPlanner,
        notifications: CompetitionNotificationClient,
        preferences: CompetitionNotificationPreferencesClient,
        commitDecisions: @escaping CommitDecisions,
        reportError: @escaping @Sendable (_ context: String) -> Void = { _ in }
    ) {
        self.planner = planner
        self.notifications = notifications
        self.preferences = preferences
        self.commitDecisions = commitDecisions
        self.reportError = reportError
    }

    func submit(_ snapshot: CompetitionNotificationPlanningSnapshot) async {
        if let latestSnapshot,
           latestSnapshot.publicationRevision > snapshot.publicationRevision {
            return
        }
        latestSnapshot = snapshot
        pendingSnapshot = snapshot
        guard !isDraining else { return }
        isDraining = true
        while let next = pendingSnapshot {
            pendingSnapshot = nil
            await reconcile(next)
        }
        isDraining = false
    }

    func reconcileLatest() async {
        guard let latestSnapshot else { return }
        await submit(latestSnapshot)
    }

    func cancelAll(_ competitionID: CompetitionID) async {
        let prefix = CompetitionNotificationIdentifier.competitionPrefix(
            competitionID
        )
        async let pending = notifications.pendingIDs(prefix)
        async let delivered = notifications.deliveredIDs(prefix)
        let (pendingIDs, deliveredIDs) = await (pending, delivered)
        if !pendingIDs.isEmpty {
            await notifications.removePending(pendingIDs.sorted())
            forgetKnownPending(pendingIDs)
        }
        if !deliveredIDs.isEmpty {
            await notifications.removeDelivered(deliveredIDs.sorted())
        }
    }

    func removeOrphans(knownCompetitionIDs: Set<CompetitionID>) async {
        async let pending = notifications.pendingIDs(
            CompetitionNotificationIdentifier.namespace
        )
        async let delivered = notifications.deliveredIDs(
            CompetitionNotificationIdentifier.namespace
        )
        let (pendingIDs, deliveredIDs) = await (pending, delivered)
        let orphanedPending = pendingIDs.filter {
            guard let id = CompetitionNotificationIdentifier.competitionID(
                from: $0
            ) else {
                return true
            }
            return !knownCompetitionIDs.contains(id)
        }.sorted()
        let orphanedDelivered = deliveredIDs.filter {
            guard let id = CompetitionNotificationIdentifier.competitionID(
                from: $0
            ) else {
                return true
            }
            return !knownCompetitionIDs.contains(id)
        }.sorted()
        if !orphanedPending.isEmpty {
            await notifications.removePending(orphanedPending)
            forgetKnownPending(orphanedPending)
        }
        if !orphanedDelivered.isEmpty {
            await notifications.removeDelivered(orphanedDelivered)
        }
    }

    private func reconcile(
        _ submitted: CompetitionNotificationPlanningSnapshot
    ) async {
        let snapshot = foldingCommittedRecords(into: submitted)
        if let knownCompetitionIDs = snapshot.knownCompetitionIDs {
            await removeOrphans(knownCompetitionIDs: knownCompetitionIDs)
            guard !isSuperseded(snapshot) else { return }
        }
        let authorization = await notifications.authorizationState()
        guard !isSuperseded(snapshot) else { return }
        let muted: Set<String>
        do {
            muted = try await preferences.mutedOpponentIdentities()
        } catch {
            guard !isSuperseded(snapshot) else { return }
            reportError("notification-preferences-read-failed")
            await removePendingForSnapshot(snapshot)
            return
        }
        guard !isSuperseded(snapshot) else { return }
        let switchedOff = preferences.switchedOff()

        let plan: CompetitionNotificationPlan
        do {
            plan = try planner.plan(
                snapshot,
                authorization: authorization,
                mutedOpponentIdentities: muted,
                switchedOff: switchedOff
            )
        } catch {
            reportError("notification-plan-failed")
            return
        }

        let pendingBefore = await notifications.pendingIDs(
            CompetitionNotificationIdentifier.namespace
        )
        knownPendingRequests = knownPendingRequests.filter {
            pendingBefore.contains($0.key)
        }
        guard !isSuperseded(snapshot) else { return }
        let desiredIDs = Set(
            plan.desiredScheduledRequests.map(\.identifier)
        )
        let snapshotIDs = Set(snapshot.competitions.map(\.id) + snapshot.groupMatches.map(\.id))
        let obsolete = pendingBefore.filter { identifier in
            guard let id = CompetitionNotificationIdentifier.competitionID(
                from: identifier
            ) else {
                return true
            }
            return snapshotIDs.contains(id) && !desiredIDs.contains(identifier)
        }
        if !obsolete.isEmpty {
            await notifications.removePending(obsolete.sorted())
            forgetKnownPending(obsolete)
        }

        for (competitionID, cleanup) in plan
            .deliveredCleanupByCompetitionID {
            let prefix = CompetitionNotificationIdentifier.competitionPrefix(
                competitionID
            )
            let delivered = await notifications.deliveredIDs(prefix)
            guard !isSuperseded(snapshot) else { return }
            let identifiers: [String]
            switch cleanup {
            case .all:
                identifiers = delivered.sorted()
            case .nonResult:
                identifiers = delivered.filter {
                    !$0.hasSuffix(":result:result")
                }.sorted()
            }
            if !identifiers.isEmpty {
                await notifications.removeDelivered(identifiers)
            }
        }

        guard authorization.permitsNotifications else { return }

        let durableCompetitionIDs = Set(
            plan.emissionDecisions.map(\.record.competitionID)
                + plan.suppressionRecords.map(\.competitionID)
        )
        let emissionBudgetByCompetition = Dictionary(
            grouping: plan.emissionDecisions,
            by: \.record.competitionID
        ).mapValues(\.count)
        var accepted: [CompetitionNotificationEmissionDecision] = []
        for competition in snapshot.competitions
            where durableCompetitionIDs.contains(competition.id) {
            if isSuperseded(snapshot) { break }
            let emissionBudget = emissionBudgetByCompetition[
                competition.id,
                default: 0
            ]
            do {
                let result = try await commitDecisions(
                    competition,
                    { [planner] freshCompetition in
                        // Siblings stay as this evaluation saw them, so the
                        // replan makes the same cross-match calls ("600
                        // today" once) as the plan above.
                        let freshSnapshot = CompetitionNotificationPlanningSnapshot(
                            publicationRevision: snapshot.publicationRevision,
                            evaluatedAt: snapshot.evaluatedAt,
                            timeZoneIdentifier: snapshot.timeZoneIdentifier,
                            competitions: snapshot.competitions.filter {
                                $0.id != freshCompetition.id
                            } + [freshCompetition]
                        )
                        let freshPlan = try planner.plan(
                            freshSnapshot,
                            authorization: authorization,
                            mutedOpponentIdentities: muted,
                            switchedOff: switchedOff
                        )
                        let ownEmissions = freshPlan.emissionDecisions.filter {
                            $0.record.competitionID == freshCompetition.id
                        }
                        let ownSuppressions = freshPlan.suppressionRecords.filter {
                            $0.competitionID == freshCompetition.id
                        }
                        let acceptedEmissions = ownEmissions
                            .prefix(emissionBudget)
                        let budgetSuppressions = try ownEmissions
                            .dropFirst(emissionBudget)
                            .map { decision in
                                try NotificationEmissionRecorded(
                                    competitionID:
                                        decision.record.competitionID,
                                    family: decision.record.family,
                                    episodeKey: decision.record.episodeKey,
                                    disposition: .suppressed(
                                        reason: .superseded
                                    ),
                                    decidedAt: snapshot.evaluatedAt,
                                    basisPublicationRevision:
                                        snapshot.publicationRevision
                                )
                            }
                        return acceptedEmissions.map {
                            .emission($0)
                        } + ownSuppressions.map {
                            .suppression($0)
                        } + budgetSuppressions.map {
                            .suppression($0)
                        }
                    }
                )
                guard case let .appended(acceptedDecisions) = result else {
                    continue
                }
                for acceptedDecision in acceptedDecisions {
                    committedRecords[competition.id, default: []]
                        .append(acceptedDecision.record)
                    if case let .emission(emission) = acceptedDecision {
                        accepted.append(emission)
                    }
                }
                if isSuperseded(snapshot) { break }
            } catch {
                reportError("notification-decision-append-failed")
            }
        }
        // Committed decisions always post, even when a newer snapshot arrived.
        for request in planner.immediateRequests(for: accepted, in: snapshot) {
            do {
                try await notifications.postNow(request)
            } catch {
                reportError("notification-post-failed-after-append")
            }
        }
        guard !isSuperseded(snapshot) else { return }

        let remainingPending = pendingBefore.subtracting(obsolete)
        for request in plan.desiredScheduledRequests
            where !remainingPending.contains(request.identifier)
                || knownPendingRequests[request.identifier] != request {
            guard !isSuperseded(snapshot) else { return }
            do {
                try await notifications.upsert(request)
                knownPendingRequests[request.identifier] = request
            } catch {
                reportError("notification-upsert-failed")
            }
        }
    }

    /// Adds committed records the snapshot's journals don't show yet, and
    /// forgets those they already do (or whose match left the snapshot).
    private func foldingCommittedRecords(
        into snapshot: CompetitionNotificationPlanningSnapshot
    ) -> CompetitionNotificationPlanningSnapshot {
        let competitionsByID = Dictionary(
            snapshot.competitions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var kept: [CompetitionID: [NotificationEmissionRecorded]] = [:]
        for (id, records) in committedRecords {
            guard let competition = competitionsByID[id] else { continue }
            let missing = records.filter {
                !competition.emissionHistory.recordedIDs.contains($0.semanticEventID)
            }
            if !missing.isEmpty { kept[id] = missing }
        }
        committedRecords = kept
        guard !committedRecords.isEmpty else { return snapshot }
        return CompetitionNotificationPlanningSnapshot(
            publicationRevision: snapshot.publicationRevision,
            evaluatedAt: snapshot.evaluatedAt,
            timeZoneIdentifier: snapshot.timeZoneIdentifier,
            competitions: snapshot.competitions.map { competition in
                guard let missing = committedRecords[competition.id] else {
                    return competition
                }
                var recordedIDs = competition.emissionHistory.recordedIDs
                var emitted = competition.emissionHistory.emittedCountByDayOrdinal
                for record in missing where recordedIDs.insert(record.semanticEventID).inserted {
                    if case .emitted = record.disposition,
                       let day = record.episodeKey.dayOrdinal {
                        emitted[day, default: 0] += 1
                    }
                }
                return competition.replacingEmissionHistory(
                    NotificationEmissionProjection(
                        recordedIDs: recordedIDs,
                        emittedCountByDayOrdinal: emitted
                    )
                )
            },
            knownCompetitionIDs: snapshot.knownCompetitionIDs,
            groupMatches: snapshot.groupMatches
        )
    }

    private func isSuperseded(
        _ snapshot: CompetitionNotificationPlanningSnapshot
    ) -> Bool {
        latestSnapshot.map {
            $0.publicationRevision > snapshot.publicationRevision
        } ?? false
    }

    private func removePendingForSnapshot(
        _ snapshot: CompetitionNotificationPlanningSnapshot
    ) async {
        let ids = Set(snapshot.competitions.map(\.id) + snapshot.groupMatches.map(\.id))
        let pending = await notifications.pendingIDs(
            CompetitionNotificationIdentifier.namespace
        )
        let matching = pending.filter { identifier in
            CompetitionNotificationIdentifier.competitionID(
                from: identifier
            ).map(ids.contains) ?? true
        }.sorted()
        if !matching.isEmpty {
            await notifications.removePending(matching)
            forgetKnownPending(matching)
        }
    }

    private func forgetKnownPending<Identifiers: Sequence>(
        _ identifiers: Identifiers
    ) where Identifiers.Element == String {
        for identifier in identifiers {
            knownPendingRequests[identifier] = nil
        }
    }
}

private extension CompetitionNotificationCompetitionSnapshot {
    func replacingEmissionHistory(
        _ history: NotificationEmissionProjection
    ) -> Self {
        Self(
            id: id,
            opponentIdentity: opponentIdentity,
            opponentDisplayName: opponentDisplayName,
            lifecycle: lifecycle,
            schedule: schedule,
            ownerPoints: ownerPoints,
            opponentPoints: opponentPoints,
            days: days,
            currentDayOrdinal: currentDayOrdinal,
            latestRefresh: latestRefresh,
            evaluationFreshness: evaluationFreshness,
            terminalResult: terminalResult,
            emissionHistory: history,
            evaluatedAt: evaluatedAt,
            timeZoneIdentifier: timeZoneIdentifier,
            whatItTakes: whatItTakes
        )
    }
}
