import CompetitionCore
import Foundation

struct CompetitionNotificationPolicy: Sendable {
    var maximumPostsPerEvaluation: Int
    var maximumPostsPerCompetitionDay: Int
    var scheduledFireDate: @Sendable (
        _ family: CompetitionScheduledNotificationFamily,
        _ baseDate: Date,
        _ timeZoneIdentifier: String
    ) -> Date?
    var isCloseScore: @Sendable (
        _ ownerPoints: Double,
        _ opponentPoints: Double
    ) -> Bool
    var isDailyMaximum: @Sendable (_ points: Double) -> Bool
    var priority: @Sendable (_ family: NotificationEmissionFamily) -> Int
    var content: @Sendable (
        _ message: CompetitionNotificationMessage
    ) -> CompetitionNotificationContent
}

extension CompetitionNotificationPolicy {
    /// Versioned, reversible product policy for local notifications. Semantic
    /// identifiers deliberately do not include any of these choices, so copy,
    /// timing, and budgets can evolve without changing durable dedupe keys.
    static let liveV1 = Self(
        maximumPostsPerEvaluation: 1,
        maximumPostsPerCompetitionDay: 2,
        scheduledFireDate: { family, baseDate, timeZoneIdentifier in
            guard family != .inviteExpiry else { return baseDate }
            guard let timeZone = TimeZone(identifier: timeZoneIdentifier)
            else {
                return nil
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return calendar.date(
                bySettingHour: 9,
                minute: 0,
                second: 0,
                of: baseDate
            )
        },
        isCloseScore: { ownerPoints, opponentPoints in
            ownerPoints.isFinite
                && opponentPoints.isFinite
                && abs(ownerPoints - opponentPoints) <= 50
        },
        isDailyMaximum: { points in
            points.isFinite
                && points >= ActivityScore.maximumDailyPoints
        },
        priority: { family in
            switch family {
            case .result: 50
            case .dailyMaximum: 40
            case .closeScore: 30
            case .leadChange: 20
            case .catchUp: 10
            }
        },
        content: { message in liveV1Content(message) }
    )

    static func liveV1Content(
        _ message: CompetitionNotificationMessage,
        locale: Locale = .current
    ) -> CompetitionNotificationContent {
        let opponent = message.opponentDisplayName
        func content(_ title: String, _ body: String) -> CompetitionNotificationContent {
            CompetitionNotificationContent(title: title, body: body)
        }
        switch message.family {
        case .scheduled(.inviteExpiry):
            return content(
                "Challenge expiring",
                "Your challenge with \(opponent) expires soon."
            )
        case .scheduled(.scheduledStart):
            return content(
                statusTitle(.active(dayOrdinal: 1), opponent: opponent),
                "Your match with \(opponent) starts today."
            )
        case .scheduled(.finalDay):
            return content(
                statusTitle(.endsToday, opponent: opponent),
                "Today is the last day of your match with \(opponent)."
            )
        case .scheduled(.competitionEnded):
            return content(
                statusTitle(.tallying(startedAt: .distantPast), opponent: opponent),
                "HealthComp is checking the latest Activity data before finalizing your result with \(opponent)."
            )
        case .opportunistic(.leadChange):
            return content(
                "Lead change",
                scoreCopy(
                    prefix: "The lead changed in your match with \(opponent).",
                    message: message,
                    locale: locale
                )
            )
        case .opportunistic(.closeScore):
            return content(
                "A close match",
                scoreCopy(
                    prefix: "Your match with \(opponent) is close.",
                    message: message,
                    locale: locale
                )
            )
        case .opportunistic(.dailyMaximum):
            return content(
                "Daily maximum reached",
                "You reached 600 points today against \(opponent)."
            )
        case .opportunistic(.result):
            let title = message.outcome.map {
                statusTitle(
                    .completed(
                        outcome: $0,
                        basis: .stableAcrossPostBoundaryReads,
                        completedAt: .distantPast
                    ),
                    opponent: opponent
                )
            } ?? "Match complete"
            guard message.ownerPoints != nil, message.opponentPoints != nil else {
                return content(title, "Your match with \(opponent) is complete.")
            }
            return content(
                title,
                scoreCopy(prefix: "Final score:", message: message, locale: locale)
            )
        case .opportunistic(.catchUp):
            return content(
                "Match update",
                "Open HealthComp for the latest on your match with \(opponent)."
            )
        }
    }

    /// Lifecycle titles come from the shared status formatter, so a
    /// notification and the screen it opens use the same words.
    private static func statusTitle(
        _ lifecycle: LocalCompetitionLifecyclePresentation,
        opponent: String
    ) -> String {
        competitionStatusText(
            lifecycle,
            schedule: nil,
            opponentDisplayName: opponent,
            style: .notification
        ).title
    }

    /// Whole points in the user's locale; a result whose whole points would
    /// match uses two decimals.
    private static func scoreCopy(
        prefix: String,
        message: CompetitionNotificationMessage,
        locale: Locale
    ) -> String {
        guard let ownerPoints = message.ownerPoints,
              let opponentPoints = message.opponentPoints
        else {
            return prefix
        }
        let digits = message.family == .opportunistic(.result)
            ? competitionFinalFractionDigits(userPoints: ownerPoints, opponentPoints: opponentPoints)
            : 0
        let owner = competitionPointsText(ownerPoints, fractionDigits: digits, locale: locale)
        let opponent = competitionPointsText(opponentPoints, fractionDigits: digits, locale: locale)
        return "\(prefix) You \(owner), \(message.opponentDisplayName) \(opponent)."
    }
}

struct CompetitionNotificationPlanner: Sendable {
    enum PlanningError: Error, Equatable, Sendable {
        case invalidTimeZoneIdentifier(String)
        case invalidPublicationRevision(UInt64)
        case invalidEvaluationDate
    }

    let policy: CompetitionNotificationPolicy

    func plan(
        _ snapshot: CompetitionNotificationPlanningSnapshot,
        authorization: CompetitionNotificationAuthorizationState,
        mutedOpponentIdentities: Set<String>
    ) throws -> CompetitionNotificationPlan {
        guard snapshot.publicationRevision > 0 else {
            throw PlanningError.invalidPublicationRevision(
                snapshot.publicationRevision
            )
        }
        guard snapshot.evaluatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw PlanningError.invalidEvaluationDate
        }
        guard TimeZone(identifier: snapshot.timeZoneIdentifier) != nil else {
            throw PlanningError.invalidTimeZoneIdentifier(
                snapshot.timeZoneIdentifier
            )
        }

        var scheduled: [CompetitionScheduledNotificationRequest] = []
        var decisions: [CompetitionNotificationEmissionDecision] = []
        var suppressions: [NotificationEmissionRecorded] = []
        var cancellations: Set<CompetitionID> = []
        var deliveredCleanup: [
            CompetitionID: CompetitionNotificationDeliveredCleanup
        ] = [:]

        for competition in snapshot.competitions {
            switch competition.lifecycle {
            case .declined, .expired:
                deliveredCleanup[competition.id] = .all
            case .archived:
                deliveredCleanup[competition.id] = .nonResult
            case .pending, .scheduled, .active, .endsToday, .tallying,
                 .completed:
                break
            }

            if !authorization.permitsNotifications
                || mutedOpponentIdentities.contains(
                    competition.opponentIdentity
                ) {
                cancellations.insert(competition.id)
                continue
            }

            scheduled.append(
                contentsOf: try scheduledRequests(
                    for: competition,
                    snapshot: snapshot
                )
            )
            let opportunity = try opportunisticPlan(
                for: competition,
                snapshot: snapshot
            )
            decisions.append(contentsOf: opportunity.decisions)
            suppressions.append(contentsOf: opportunity.suppressions)

            if competition.lifecycle.isNotificationTerminal {
                cancellations.insert(competition.id)
            }
        }

        decisions.sort {
            let left = policy.priority($0.record.family)
            let right = policy.priority($1.record.family)
            if left != right { return left > right }
            return $0.record.semanticEventID < $1.record.semanticEventID
        }
        let globalMaximum = max(0, policy.maximumPostsPerEvaluation)
        if decisions.count > globalMaximum {
            for decision in decisions.dropFirst(globalMaximum) {
                suppressions.append(
                    try NotificationEmissionRecorded(
                        competitionID: decision.record.competitionID,
                        family: decision.record.family,
                        episodeKey: decision.record.episodeKey,
                        disposition: .suppressed(reason: .superseded),
                        decidedAt: snapshot.evaluatedAt,
                        basisPublicationRevision: snapshot.publicationRevision
                    )
                )
            }
            decisions = Array(decisions.prefix(globalMaximum))
        }

        return CompetitionNotificationPlan(
            desiredScheduledRequests: scheduled.sorted {
                $0.identifier < $1.identifier
            },
            emissionDecisions: decisions,
            suppressionRecords: suppressions,
            cancelCompetitionIDs: cancellations,
            deliveredCleanupByCompetitionID: deliveredCleanup
        )
    }

    private func scheduledRequests(
        for competition: CompetitionNotificationCompetitionSnapshot,
        snapshot: CompetitionNotificationPlanningSnapshot
    ) throws -> [CompetitionScheduledNotificationRequest] {
        let bases = try scheduledBases(
            for: competition,
            publicationTimeZoneIdentifier: snapshot.timeZoneIdentifier
        )
        return try bases.compactMap { family, baseDate, timeZoneIdentifier in
            guard let fireDate = policy.scheduledFireDate(
                family,
                baseDate,
                timeZoneIdentifier
            ), fireDate > snapshot.evaluatedAt else {
                return nil
            }
            let components = try triggerComponents(
                for: fireDate,
                timeZoneIdentifier: timeZoneIdentifier
            )
            let message = CompetitionNotificationMessage(
                family: .scheduled(family),
                competitionID: competition.id,
                opponentDisplayName: competition.opponentDisplayName,
                ownerPoints: nil,
                opponentPoints: nil,
                outcome: nil
            )
            return CompetitionScheduledNotificationRequest(
                identifier: CompetitionNotificationIdentifier.scheduled(
                    competitionID: competition.id,
                    family: family
                ),
                content: policy.content(message),
                dateComponents: components,
                route: .competition(competition.id)
            )
        }
    }

    private func scheduledBases(
        for competition: CompetitionNotificationCompetitionSnapshot,
        publicationTimeZoneIdentifier: String
    ) throws -> [(
        CompetitionScheduledNotificationFamily,
        Date,
        String
    )] {
        switch competition.lifecycle {
        case let .pending(expiresAt):
            return expiresAt.map {
                [(.inviteExpiry, $0, publicationTimeZoneIdentifier)]
            } ?? []

        case .scheduled, .active, .endsToday, .tallying:
            guard let schedule = competition.schedule else { return [] }
            let calendar = schedule.calendar
            let days = try calendar.sevenDayWindow(
                startingOn: schedule.startDay
            )
            let finalDay = days[6]
            let endDay = try calendar.day(after: finalDay)
            let timeZone = calendar.timeZoneIdentifier
            let start = try calendar.startOfDay(schedule.startDay)
            let final = try calendar.startOfDay(finalDay)
            let end = try calendar.startOfDay(endDay)
            switch competition.lifecycle {
            case .scheduled:
                return [
                    (.scheduledStart, start, timeZone),
                    (.finalDay, final, timeZone),
                    (.competitionEnded, end, timeZone),
                ]
            case let .active(dayOrdinal):
                return dayOrdinal < 7
                    ? [
                        (.finalDay, final, timeZone),
                        (.competitionEnded, end, timeZone),
                    ]
                    : [(.competitionEnded, end, timeZone)]
            case .endsToday, .tallying:
                return [(.competitionEnded, end, timeZone)]
            default:
                return []
            }

        case .declined, .expired, .completed, .archived:
            return []
        }
    }

    private func triggerComponents(
        for date: Date,
        timeZoneIdentifier: String
    ) throws -> DateComponents {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw PlanningError.invalidTimeZoneIdentifier(
                timeZoneIdentifier
            )
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = calendar.dateComponents(
            [.era, .year, .month, .day, .hour, .minute, .second],
            from: date
        )
        components.calendar = calendar
        components.timeZone = timeZone
        return components
    }

    private struct OpportunityPlan {
        var decisions: [CompetitionNotificationEmissionDecision] = []
        var suppressions: [NotificationEmissionRecorded] = []
    }

    private struct Candidate {
        let record: NotificationEmissionRecorded
        let message: CompetitionNotificationMessage
    }

    private func opportunisticPlan(
        for competition: CompetitionNotificationCompetitionSnapshot,
        snapshot: CompetitionNotificationPlanningSnapshot
    ) throws -> OpportunityPlan {
        let staleSuppressions = try staleSuppressionRecords(
            for: competition,
            snapshot: snapshot
        )
        var candidates = try candidates(
            for: competition,
            snapshot: snapshot
        ).filter {
            !competition.emissionHistory.recordedIDs.contains(
                $0.record.semanticEventID
            )
        }
        candidates.sort {
            let left = policy.priority($0.record.family)
            let right = policy.priority($1.record.family)
            if left != right { return left > right }
            return $0.record.semanticEventID < $1.record.semanticEventID
        }

        let maximum = max(0, policy.maximumPostsPerEvaluation)
        var result = OpportunityPlan(suppressions: staleSuppressions)
        for (index, candidate) in candidates.enumerated() {
            let dayBudgetExhausted: Bool
            if let dayOrdinal = candidate.record.episodeKey.dayOrdinal {
                dayBudgetExhausted = competition.emissionHistory
                    .emittedCountByDayOrdinal[dayOrdinal, default: 0]
                    >= max(0, policy.maximumPostsPerCompetitionDay)
            } else {
                dayBudgetExhausted = false
            }

            if index < maximum && !dayBudgetExhausted {
                result.decisions.append(
                    CompetitionNotificationEmissionDecision(
                        record: candidate.record,
                        request: CompetitionImmediateNotificationRequest(
                            identifier: CompetitionNotificationIdentifier
                                .opportunistic(candidate.record),
                            content: policy.content(candidate.message),
                            route: .competition(competition.id)
                        )
                    )
                )
            } else {
                result.suppressions.append(
                    try NotificationEmissionRecorded(
                        competitionID: candidate.record.competitionID,
                        family: candidate.record.family,
                        episodeKey: candidate.record.episodeKey,
                        disposition: .suppressed(
                            reason: dayBudgetExhausted
                                ? .budgetExceeded
                                : .superseded
                        ),
                        decidedAt: snapshot.evaluatedAt,
                        basisPublicationRevision: snapshot.publicationRevision
                    )
                )
            }
        }
        if result.decisions.isEmpty,
           !staleSuppressions.isEmpty,
           maximum > 0,
           let catchUp = try catchUpDecision(
               for: competition,
               snapshot: snapshot
           ) {
            result.decisions = [catchUp]
        }
        return result
    }

    private func staleSuppressionRecords(
        for competition: CompetitionNotificationCompetitionSnapshot,
        snapshot: CompetitionNotificationPlanningSnapshot
    ) throws -> [NotificationEmissionRecorded] {
        guard let currentDayOrdinal = competition.currentDayOrdinal else {
            return []
        }
        let pastDays = competition.days
            .filter { $0.ordinal < currentDayOrdinal }
            .sorted { $0.ordinal < $1.ordinal }
        var records: [NotificationEmissionRecorded] = []
        var seenIDs: Set<String> = []
        var ownerTotal = 0.0
        var opponentTotal = 0.0
        var totalsAreComplete = true
        var previousLeader: NotificationEmissionLeader?

        for day in pastDays {
            if let ownerPoints = day.ownerAcceptedPoints,
               policy.isDailyMaximum(ownerPoints) {
                try appendStaleSuppression(
                    family: .dailyMaximum,
                    episode: .day(day.ordinal),
                    competition: competition,
                    snapshot: snapshot,
                    seenIDs: &seenIDs,
                    records: &records
                )
            }

            guard totalsAreComplete,
                  let ownerPoints = day.ownerAcceptedPoints,
                  let opponentPoints = day.opponentRevealedPoints
            else {
                totalsAreComplete = false
                continue
            }
            ownerTotal += ownerPoints
            opponentTotal += opponentPoints

            if policy.isCloseScore(ownerTotal, opponentTotal) {
                try appendStaleSuppression(
                    family: .closeScore,
                    episode: .day(day.ordinal),
                    competition: competition,
                    snapshot: snapshot,
                    seenIDs: &seenIDs,
                    records: &records
                )
            }

            let leader = displayedLeader(ownerTotal, opponentTotal)
            if let leader, leader != previousLeader {
                try appendStaleSuppression(
                    family: .leadChange,
                    episode: .leader(
                        dayOrdinal: day.ordinal,
                        leader: leader
                    ),
                    competition: competition,
                    snapshot: snapshot,
                    seenIDs: &seenIDs,
                    records: &records
                )
                previousLeader = leader
            }
        }
        return records
    }

    private func appendStaleSuppression(
        family: NotificationEmissionFamily,
        episode: NotificationEpisodeKey,
        competition: CompetitionNotificationCompetitionSnapshot,
        snapshot: CompetitionNotificationPlanningSnapshot,
        seenIDs: inout Set<String>,
        records: inout [NotificationEmissionRecorded]
    ) throws {
        let record = try NotificationEmissionRecorded(
            competitionID: competition.id,
            family: family,
            episodeKey: episode,
            disposition: .suppressed(reason: .staleEpisode),
            decidedAt: snapshot.evaluatedAt,
            basisPublicationRevision: snapshot.publicationRevision
        )
        guard seenIDs.insert(record.semanticEventID).inserted,
              !competition.emissionHistory.recordedIDs.contains(
                  record.semanticEventID
              )
        else {
            return
        }
        records.append(record)
    }

    private func catchUpDecision(
        for competition: CompetitionNotificationCompetitionSnapshot,
        snapshot: CompetitionNotificationPlanningSnapshot
    ) throws -> CompetitionNotificationEmissionDecision? {
        let episode: NotificationEpisodeKey
        if let dayOrdinal = competition.currentDayOrdinal {
            guard competition.emissionHistory.emittedCountByDayOrdinal[
                dayOrdinal,
                default: 0
            ] < max(0, policy.maximumPostsPerCompetitionDay) else {
                return nil
            }
            episode = .day(dayOrdinal)
        } else if competition.lifecycle == .tallying {
            episode = .tallying
        } else {
            return nil
        }
        let record = try NotificationEmissionRecorded(
            competitionID: competition.id,
            family: .catchUp,
            episodeKey: episode,
            disposition: .emitted,
            decidedAt: snapshot.evaluatedAt,
            basisPublicationRevision: snapshot.publicationRevision
        )
        guard !competition.emissionHistory.recordedIDs.contains(
            record.semanticEventID
        ) else {
            return nil
        }
        let message = CompetitionNotificationMessage(
            family: .opportunistic(.catchUp),
            competitionID: competition.id,
            opponentDisplayName: competition.opponentDisplayName,
            ownerPoints: nil,
            opponentPoints: nil,
            outcome: nil
        )
        return CompetitionNotificationEmissionDecision(
            record: record,
            request: CompetitionImmediateNotificationRequest(
                identifier: record.semanticEventID,
                content: policy.content(message),
                route: .competition(competition.id)
            )
        )
    }

    private func candidates(
        for competition: CompetitionNotificationCompetitionSnapshot,
        snapshot: CompetitionNotificationPlanningSnapshot
    ) throws -> [Candidate] {
        var result: [Candidate] = []

        if let terminal = competition.terminalResult {
            result.append(
                try candidate(
                    family: .result,
                    episode: .result,
                    competition: competition,
                    snapshot: snapshot,
                    ownerPoints: terminal.ownerPoints,
                    opponentPoints: terminal.opponentPoints,
                    outcome: terminal.outcome
                )
            )
        }

        if competition.lifecycle.permitsFreshScoreCopy,
           competition.latestRefresh == .completed,
           competition.evaluationFreshness.isFreshCompletedRefresh,
           let ordinal = competition.currentDayOrdinal,
           let day = competition.days.first(where: { $0.ordinal == ordinal }),
           let accepted = day.ownerAcceptedPoints,
           policy.isDailyMaximum(accepted) {
            result.append(
                try candidate(
                    family: .dailyMaximum,
                    episode: .day(ordinal),
                    competition: competition,
                    snapshot: snapshot,
                    ownerPoints: accepted,
                    opponentPoints: day.opponentRevealedPoints,
                    outcome: nil
                )
            )
        }

        guard competition.lifecycle.permitsFreshScoreCopy,
              competition.latestRefresh == .completed,
              competition.evaluationFreshness.isFreshCompletedRefresh,
              let ordinal = competition.currentDayOrdinal
        else {
            return result
        }

        if policy.isCloseScore(
            competition.ownerPoints,
            competition.opponentPoints
        ) {
            result.append(
                try candidate(
                    family: .closeScore,
                    episode: .day(ordinal),
                    competition: competition,
                    snapshot: snapshot,
                    ownerPoints: competition.ownerPoints,
                    opponentPoints: competition.opponentPoints,
                    outcome: nil
                )
            )
        }

        if let leader = displayedLeader(
            competition.ownerPoints, competition.opponentPoints
        ) {
            if mostRecentRecordedLeader(
                in: competition,
                through: ordinal
            ) != leader {
                result.append(
                    try candidate(
                        family: .leadChange,
                        episode: .leader(
                            dayOrdinal: ordinal,
                            leader: leader
                        ),
                        competition: competition,
                        snapshot: snapshot,
                        ownerPoints: competition.ownerPoints,
                        opponentPoints: competition.opponentPoints,
                        outcome: nil
                    )
                )
            }
        }
        return result
    }

    /// The leader by the whole points people see; nil when they read equal,
    /// so "The lead changed … You 412, Alex 412." can't happen.
    private func displayedLeader(
        _ ownerPoints: Double,
        _ opponentPoints: Double
    ) -> NotificationEmissionLeader? {
        let margin = competitionDisplayedMargin(
            userPoints: ownerPoints, opponentPoints: opponentPoints
        )
        if margin > 0 { return .owner }
        if margin < 0 { return .opponent }
        return nil
    }

    private func mostRecentRecordedLeader(
        in competition: CompetitionNotificationCompetitionSnapshot,
        through dayOrdinal: Int
    ) -> NotificationEmissionLeader? {
        guard dayOrdinal >= 1 else { return nil }
        for day in stride(from: min(dayOrdinal, 7), through: 1, by: -1) {
            for leader in NotificationEmissionLeader.allCases {
                guard let id = try? NotificationEmissionRecorded.semanticID(
                    competitionID: competition.id,
                    family: .leadChange,
                    episodeKey: .leader(
                        dayOrdinal: day,
                        leader: leader
                    )
                ) else {
                    continue
                }
                if competition.emissionHistory.recordedIDs.contains(id) {
                    return leader
                }
            }
        }
        return nil
    }

    private func candidate(
        family: NotificationEmissionFamily,
        episode: NotificationEpisodeKey,
        competition: CompetitionNotificationCompetitionSnapshot,
        snapshot: CompetitionNotificationPlanningSnapshot,
        ownerPoints: Double?,
        opponentPoints: Double?,
        outcome: CompetitionOutcome?
    ) throws -> Candidate {
        let record = try NotificationEmissionRecorded(
            competitionID: competition.id,
            family: family,
            episodeKey: episode,
            disposition: .emitted,
            decidedAt: snapshot.evaluatedAt,
            basisPublicationRevision: snapshot.publicationRevision
        )
        return Candidate(
            record: record,
            message: CompetitionNotificationMessage(
                family: .opportunistic(family),
                competitionID: competition.id,
                opponentDisplayName: competition.opponentDisplayName,
                ownerPoints: ownerPoints,
                opponentPoints: opponentPoints,
                outcome: outcome
            )
        )
    }
}

private extension CompetitionNotificationEvaluationFreshness {
    var isFreshCompletedRefresh: Bool {
        guard case let .freshCompletedRefresh(attemptID, readAt) = self else {
            return false
        }
        return !attemptID.isEmpty
            && readAt.timeIntervalSinceReferenceDate.isFinite
    }
}

private extension CompetitionNotificationLifecycle {
    var permitsFreshScoreCopy: Bool {
        switch self {
        case .active, .endsToday:
            true
        case .pending, .declined, .expired, .scheduled, .tallying,
             .completed, .archived:
            false
        }
    }

    var isNotificationTerminal: Bool {
        switch self {
        case .declined, .expired, .archived:
            true
        case .pending, .scheduled, .active, .endsToday, .tallying,
             .completed:
            false
        }
    }
}
