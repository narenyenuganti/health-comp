import CompetitionCore
import Foundation

struct CompetitionNotificationPolicy: Sendable {
    /// The cap per match per evaluation; matches never compete for it.
    var maximumPostsPerEvaluation: Int
    var maximumPostsPerCompetitionDay: Int
    var scheduledFireDate: @Sendable (
        _ family: CompetitionScheduledNotificationFamily,
        _ baseDate: Date,
        _ timeZoneIdentifier: String
    ) -> Date?
    var isCloseScore: @Sendable (
        _ ownerPoints: Double,
        _ opponentPoints: Double,
        _ dayOrdinal: Int
    ) -> Bool
    var isDailyMaximum: @Sendable (_ points: Double) -> Bool
    var priority: @Sendable (_ family: NotificationEmissionFamily) -> Int
    var content: @Sendable (
        _ message: CompetitionNotificationMessage
    ) -> CompetitionNotificationContent
    var summaryContent: @Sendable (
        _ messages: [CompetitionNotificationMessage]
    ) -> CompetitionNotificationContent = {
        CompetitionNotificationPolicy.liveV1SummaryContent($0)
    }
}

extension CompetitionNotificationPolicy {
    /// Versioned, reversible product policy for local notifications. Semantic
    /// identifiers deliberately do not include any of these choices, so copy,
    /// timing, and budgets can evolve without changing durable dedupe keys.
    static let liveV1 = Self(
        maximumPostsPerEvaluation: 1,
        maximumPostsPerCompetitionDay: 2,
        scheduledFireDate: { family, baseDate, timeZoneIdentifier in
            guard family != .inviteExpiry else {
                return baseDate.addingTimeInterval(-4 * 60 * 60)
            }
            guard let timeZone = TimeZone(identifier: timeZoneIdentifier)
            else {
                return nil
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return calendar.date(
                bySettingHour: family == .whatItTakes ? 19 : 9,
                minute: 0,
                second: 0,
                of: baseDate
            )
        },
        isCloseScore: { owner, opponent, dayOrdinal in
            owner.isFinite && opponent.isFinite
                && dayOrdinal >= 5 && min(owner, opponent) >= 300
                && abs(competitionDisplayedMargin(userPoints: owner, opponentPoints: opponent)) <= 50
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
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> CompetitionNotificationContent {
        let name = message.opponentDisplayName
        func content(_ title: String, _ body: String) -> CompetitionNotificationContent {
            CompetitionNotificationContent(title: title, body: body)
        }
        func points(_ value: Double?, _ digits: Int = 0) -> String {
            competitionPointsText(value, fractionDigits: digits, locale: locale)
        }
        let days = daysLeftText(message.dayOrdinal)
        switch message.family {
        case .scheduled(.inviteExpiry):
            let time = message.expiresAt.map {
                $0.formatted(Date.FormatStyle(
                    date: .omitted, time: .shortened, locale: locale, timeZone: timeZone
                ))
            }
            switch message.invitationDirection {
            case .outgoing:
                return content(
                    "\(name) hasn’t accepted yet",
                    time.map { "Your challenge expires at \($0)." }
                        ?? "Your challenge expires soon."
                )
            case .incoming:
                return content(
                    statusTitle(
                        .pending(direction: .incoming, createdAt: .distantPast, expiresAt: nil),
                        opponent: name
                    ),
                    time.map { "The challenge expires at \($0)." }
                        ?? "The challenge expires soon."
                )
            }
        case .scheduled(.scheduledStart):
            return content(
                statusTitle(.active(dayOrdinal: 1), opponent: name),
                "Your match with \(name) starts today."
            )
        case .scheduled(.finalDay):
            return content(
                statusTitle(.endsToday, opponent: name),
                "Today is the last day of your match with \(name)."
            )
        case .scheduled(.competitionEnded):
            return content(
                statusTitle(.tallying(startedAt: .distantPast), opponent: name),
                "HealthComp is checking the latest Activity data before finalizing your result with \(name)."
            )
        case .scheduled(.whatItTakes):
            guard let takes = message.whatItTakes, let need = takes.points else {
                return content(
                    "Match update",
                    "Open HealthComp for the latest on your match with \(name)."
                )
            }
            // The match zone's abbreviation at that midnight, when it differs
            // from the phone's, as the status line does.
            let zone: String = {
                guard let end = message.matchDayEnd,
                      let id = message.matchTimeZoneIdentifier,
                      let matchZone = TimeZone(identifier: id),
                      matchZone.secondsFromGMT(for: end) != timeZone.secondsFromGMT(for: end)
                else { return "" }
                return " " + (matchZone.abbreviation(for: end) ?? id)
            }()
            return content(
                "\(points(need)) to take the lead from \(name)",
                "\(takes.suggestion) Day \(takes.dayOrdinal) ends at midnight\(zone)."
            )
        case .opportunistic(.leadChange):
            let own = points(message.ownerPoints)
            let opp = points(message.opponentPoints)
            let youLead = competitionDisplayedMargin(
                userPoints: message.ownerPoints ?? 0,
                opponentPoints: message.opponentPoints ?? 0
            ) > 0
            return content(
                youLead ? "You took the lead" : "\(name) took the lead",
                [
                    youLead ? "You \(own), \(name) \(opp)." : "\(name) \(opp), you \(own).",
                    days,
                ].compactMap { $0 }.joined(separator: " ")
            )
        case .opportunistic(.closeScore):
            let margin = competitionDisplayedMargin(
                userPoints: message.ownerPoints ?? 0,
                opponentPoints: message.opponentPoints ?? 0
            )
            let gap = competitionPointsAccessibilityText(abs(margin), locale: locale)
            let standing = margin < 0 ? "You’re \(gap) behind."
                : margin > 0 ? "You’re \(gap) ahead."
                : "All square."
            return content(
                "Neck and neck with \(name)",
                [days, standing].compactMap { $0 }.joined(separator: " ")
            )
        case .opportunistic(.dailyMaximum):
            let count = max(1, message.liveMatchCount)
            let body = switch count {
            case 1: "That’s the daily max."
            case 2: "That’s the daily max. It counts in both your matches."
            default: "That’s the daily max. It counts in all \(count) of your matches."
            }
            return content(
                points(ActivityScore.maximumDailyPoints) + " today",
                body
            )
        case .opportunistic(.result):
            let title = message.outcome.map {
                statusTitle(
                    .completed(
                        outcome: $0,
                        basis: .stableAcrossPostBoundaryReads,
                        completedAt: .distantPast
                    ),
                    opponent: name
                )
            } ?? "Match complete"
            guard let scores = resultScores(message, locale: locale) else {
                return content(title, "Your match with \(name) is complete.")
            }
            let body = message.outcome == .loss
                ? "\(scores.opp) to \(scores.own)."
                : "\(scores.own) to \(scores.opp)."
            return content(
                title,
                [body, beltSentence(message)].compactMap { $0 }.joined(separator: " ")
            )
        case .opportunistic(.catchUp):
            return content(
                "Match update",
                "Open HealthComp for the latest on your match with \(name)."
            )
        }
    }

    /// One notification for several matches: results or catch-ups from one
    /// evaluation, or same-time 9:00 reminders.
    static func liveV1SummaryContent(
        _ messages: [CompetitionNotificationMessage],
        locale: Locale = .current
    ) -> CompetitionNotificationContent {
        guard let first = messages.first else {
            return CompetitionNotificationContent(title: "", body: "")
        }
        guard messages.count > 1 else { return liveV1Content(first, locale: locale) }
        let names = uniqueNamesText(messages, locale: locale)
        switch first.family {
        case .opportunistic(.result):
            func rank(_ outcome: CompetitionOutcome?) -> Int {
                switch outcome {
                case .win: 0
                case .tie: 1
                case .loss: 2
                case nil: 3
                }
            }
            let sorted = messages.sorted {
                if rank($0.outcome) != rank($1.outcome) {
                    return rank($0.outcome) < rank($1.outcome)
                }
                let order = $0.opponentDisplayName.localizedStandardCompare($1.opponentDisplayName)
                if order != .orderedSame { return order == .orderedAscending }
                return $0.competitionID.rawValue.uuidString < $1.competitionID.rawValue.uuidString
            }
            let sentences = sorted.map { message -> String in
                let name = message.opponentDisplayName
                guard let scores = resultScores(message, locale: locale) else {
                    return "Your match with \(name) is complete."
                }
                let sentence = switch message.outcome {
                case .win: "You beat \(name) \(scores.own) to \(scores.opp)."
                case .loss: "\(name) won \(scores.opp) to \(scores.own)."
                case .tie: "All square with \(name) at \(scores.own)."
                case nil: "Your match with \(name) is complete."
                }
                return [sentence, beltSentence(message)].compactMap { $0 }.joined(separator: " ")
            }
            return CompetitionNotificationContent(
                title: "\(messages.count) matches finished",
                body: sentences.joined(separator: " ")
            )
        case .opportunistic(.catchUp):
            return CompetitionNotificationContent(
                title: "Match update",
                body: "Open HealthComp for the latest on your matches with \(names)."
            )
        case .scheduled(.scheduledStart):
            return CompetitionNotificationContent(
                title: statusTitle(.active(dayOrdinal: 1), opponent: first.opponentDisplayName),
                body: "Your matches with \(names) start today."
            )
        case .scheduled(.finalDay):
            return CompetitionNotificationContent(
                title: statusTitle(.endsToday, opponent: first.opponentDisplayName),
                body: "Today is the last day of your matches with \(names)."
            )
        case .scheduled(.competitionEnded):
            return CompetitionNotificationContent(
                title: statusTitle(.tallying(startedAt: .distantPast), opponent: first.opponentDisplayName),
                body: "HealthComp is checking the latest Activity data before finalizing your results with \(names)."
            )
        case .scheduled(.inviteExpiry), .scheduled(.whatItTakes), .opportunistic(.leadChange),
             .opportunistic(.closeScore), .opportunistic(.dailyMaximum):
            return liveV1Content(first, locale: locale)
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

    /// "You took the belt from Sam." on a take; nil otherwise.
    private static func beltSentence(_ message: CompetitionNotificationMessage) -> String? {
        switch message.beltTake {
        case .took(.you, nil, _): "You took the belt."
        case .took(.you, _?, _): "You took the belt from \(message.opponentDisplayName)."
        case .took(.them, _, _): "\(message.opponentDisplayName) took the belt."
        default: nil
        }
    }

    /// Final scores in the user's locale; two decimals only when whole points
    /// would hide the winner.
    private static func resultScores(
        _ message: CompetitionNotificationMessage,
        locale: Locale
    ) -> (own: String, opp: String)? {
        guard let own = message.ownerPoints, let opp = message.opponentPoints else {
            return nil
        }
        let digits = competitionFinalFractionDigits(userPoints: own, opponentPoints: opp)
        return (
            competitionPointsText(own, fractionDigits: digits, locale: locale),
            competitionPointsText(opp, fractionDigits: digits, locale: locale)
        )
    }

    private static func daysLeftText(_ dayOrdinal: Int?) -> String? {
        switch dayOrdinal {
        case 7?: "Last day."
        case 6?: "Two days left."
        case 5?: "Three days left."
        case 4?: "Four days left."
        case 3?: "Five days left."
        case 2?: "Six days left."
        case 1?: "Seven days left."
        default: nil
        }
    }

    private static func uniqueNamesText(
        _ messages: [CompetitionNotificationMessage],
        locale: Locale
    ) -> String {
        let names = Set(messages.map(\.opponentDisplayName))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: names) ?? names.joined(separator: ", ")
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
        mutedOpponentIdentities: Set<String>,
        switchedOff: Set<CompetitionNotificationChoice> = []
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

        var scheduledCandidates: [ScheduledCandidate] = []
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

            scheduledCandidates.append(
                contentsOf: try scheduledRequests(
                    for: competition,
                    snapshot: snapshot
                ).filter { !$0.message.family.isOff(in: switchedOff) }
            )
            let opportunity = try opportunisticPlan(
                for: competition,
                snapshot: snapshot,
                switchedOff: switchedOff
            )
            decisions.append(contentsOf: opportunity.decisions)
            suppressions.append(contentsOf: opportunity.suppressions)

            if competition.lifecycle.isNotificationTerminal {
                cancellations.insert(competition.id)
            }
        }

        // Each match spends its own per-evaluation cap in `opportunisticPlan`;
        // the sort only keeps the output deterministic.
        decisions.sort {
            let left = policy.priority($0.record.family)
            let right = policy.priority($1.record.family)
            if left != right { return left > right }
            return $0.record.semanticEventID < $1.record.semanticEventID
        }

        return CompetitionNotificationPlan(
            desiredScheduledRequests: mergedScheduledRequests(scheduledCandidates).sorted {
                $0.identifier < $1.identifier
            },
            emissionDecisions: decisions,
            suppressionRecords: suppressions,
            cancelCompetitionIDs: cancellations,
            deliveredCleanupByCompetitionID: deliveredCleanup
        )
    }

    /// Collapses durable, accepted emissions from one evaluation into what iOS
    /// posts: several results (or catch-ups) become one summary, and the
    /// daily maximum posts once, naming nobody.
    func immediateRequests(
        for emissions: [CompetitionNotificationEmissionDecision],
        in snapshot: CompetitionNotificationPlanningSnapshot
    ) -> [CompetitionImmediateNotificationRequest] {
        let grouped: Set<NotificationEmissionFamily> = [.result, .catchUp, .dailyMaximum]
        var requests: [CompetitionImmediateNotificationRequest] = []
        var handled: Set<NotificationEmissionFamily> = []
        for emission in emissions {
            let family = emission.record.family
            guard grouped.contains(family) else {
                requests.append(emission.request)
                continue
            }
            guard handled.insert(family).inserted else { continue }
            let group = emissions.filter { $0.record.family == family }
            let identifier = group.map(\.request.identifier).min()!
            if family == .dailyMaximum {
                var message = emission.message
                message.liveMatchCount = max(1, snapshot.liveMatchCount)
                requests.append(CompetitionImmediateNotificationRequest(
                    identifier: identifier,
                    content: policy.content(message),
                    route: nil
                ))
            } else if group.count == 1 {
                requests.append(emission.request)
            } else {
                requests.append(CompetitionImmediateNotificationRequest(
                    identifier: identifier,
                    content: policy.summaryContent(group.map(\.message)),
                    route: nil
                ))
            }
        }
        return requests
    }

    private struct ScheduledCandidate {
        let request: CompetitionScheduledNotificationRequest
        let message: CompetitionNotificationMessage
        let fireDate: Date
    }

    /// Same-time 9:00 reminders for several matches become one request.
    private func mergedScheduledRequests(
        _ candidates: [ScheduledCandidate]
    ) -> [CompetitionScheduledNotificationRequest] {
        var requests: [CompetitionScheduledNotificationRequest] = []
        var handled: Set<Int> = []
        for (index, candidate) in candidates.enumerated() where !handled.contains(index) {
            guard case let .scheduled(family) = candidate.message.family,
                  family != .inviteExpiry
            else {
                requests.append(candidate.request)
                continue
            }
            let members = candidates.indices.filter {
                candidates[$0].message.family == candidate.message.family
                    && candidates[$0].fireDate == candidate.fireDate
            }
            handled.formUnion(members)
            if family == .whatItTakes {
                // One evening reminder: the smallest gap, keeping its route.
                // ponytail: grouped by fire instant, so matches in different
                // zones can each post one; group by evening if that bites.
                func key(_ index: Int) -> (Double, String) {
                    (candidates[index].message.whatItTakes?.points ?? .infinity,
                     candidates[index].request.identifier)
                }
                let pick = members.min { key($0) < key($1) }!
                requests.append(candidates[pick].request)
                continue
            }
            guard members.count > 1 else {
                requests.append(candidate.request)
                continue
            }
            let first = members.min {
                candidates[$0].request.identifier < candidates[$1].request.identifier
            }!
            requests.append(CompetitionScheduledNotificationRequest(
                identifier: candidates[first].request.identifier,
                content: policy.summaryContent(members.map { candidates[$0].message }),
                dateComponents: candidates[first].request.dateComponents,
                route: nil
            ))
        }
        return requests
    }

    private func scheduledRequests(
        for competition: CompetitionNotificationCompetitionSnapshot,
        snapshot: CompetitionNotificationPlanningSnapshot
    ) throws -> [ScheduledCandidate] {
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
            var message = CompetitionNotificationMessage(
                family: .scheduled(family),
                competitionID: competition.id,
                opponentDisplayName: competition.opponentDisplayName,
                ownerPoints: nil,
                opponentPoints: nil,
                outcome: nil
            )
            if case let .pending(direction, expiresAt) = competition.lifecycle {
                message.expiresAt = expiresAt
                message.invitationDirection = direction
            }
            if family == .whatItTakes, let takes = competition.whatItTakes {
                message.whatItTakes = takes
                message.dayOrdinal = takes.dayOrdinal
                message.matchTimeZoneIdentifier = timeZoneIdentifier
                // Base is that day's midnight in the match zone.
                message.matchDayEnd = try competition.schedule.map {
                    try $0.calendar.startOfDay($0.calendar.day(after: $0.calendar.day(containing: baseDate)))
                }
            }
            return ScheduledCandidate(
                request: CompetitionScheduledNotificationRequest(
                    identifier: CompetitionNotificationIdentifier.scheduled(
                        competitionID: competition.id,
                        family: family
                    ),
                    content: policy.content(message),
                    dateComponents: components,
                    route: .competition(competition.id)
                ),
                message: message,
                fireDate: fireDate
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
        case let .pending(_, expiresAt):
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
            // The reminder's day comes from the value, not the lifecycle, so
            // the trigger, N and "Day d" describe the same clock day.
            // ponytail: content as of the last plan; a 6:45 PM BGAppRefresh
            // re-plan is the upgrade if stale numbers bite.
            // ponytail: a pending reminder can outlive a server cancellation
            // until the next reconcile; a generic cancellation push is the upgrade.
            var takes: [(CompetitionScheduledNotificationFamily, Date, String)] = []
            if competition.lifecycle.isLiveDay,
               let value = competition.whatItTakes, value.points != nil,
               value.dayOrdinal == competition.currentDayOrdinal,
               days.indices.contains(value.dayOrdinal - 1) {
                takes = [(.whatItTakes, try calendar.startOfDay(days[value.dayOrdinal - 1]), timeZone)]
            }
            switch competition.lifecycle {
            case .scheduled:
                return [
                    (.scheduledStart, start, timeZone),
                    (.finalDay, final, timeZone),
                    (.competitionEnded, end, timeZone),
                ]
            case let .active(dayOrdinal):
                return (dayOrdinal < 7
                    ? [
                        (.finalDay, final, timeZone),
                        (.competitionEnded, end, timeZone),
                    ]
                    : [(.competitionEnded, end, timeZone)]) + takes
            case .endsToday, .tallying:
                // `takes` is empty while tallying.
                return [(.competitionEnded, end, timeZone)] + takes
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
        snapshot: CompetitionNotificationPlanningSnapshot,
        switchedOff: Set<CompetitionNotificationChoice>
    ) throws -> OpportunityPlan {
        let staleSuppressions = try staleSuppressionRecords(
            for: competition,
            snapshot: snapshot
        )
        var result = OpportunityPlan(suppressions: staleSuppressions)
        if let baseline = try leadBaselineRecord(for: competition, snapshot: snapshot),
           !competition.emissionHistory.recordedIDs.contains(baseline.semanticEventID) {
            result.suppressions.append(baseline)
        }
        var candidates = try candidates(
            for: competition,
            snapshot: snapshot
        ).filter {
            !competition.emissionHistory.recordedIDs.contains(
                $0.record.semanticEventID
            )
        }
        // Switched off: recorded silently, so turning it back on never posts a
        // late one, and this match's slot goes to its next candidate.
        // ponytail: reuse .superseded; add NotificationSuppressionReason.switchedOff
        // in CompetitionCore if support needs to tell them apart.
        let isOff = { CompetitionNotificationMessageFamily.opportunistic($0).isOff(in: switchedOff) }
        for candidate in candidates where isOff(candidate.record.family) {
            result.suppressions.append(
                try suppressed(candidate.record, reason: .superseded, snapshot: snapshot)
            )
        }
        candidates.removeAll { isOff($0.record.family) }
        // "600 today" posts once a day across matches; this match's slot goes
        // to its next candidate.
        if dailyMaximumRecordedInAnotherMatch(competition, snapshot: snapshot) {
            for candidate in candidates where candidate.record.family == .dailyMaximum {
                result.suppressions.append(
                    try suppressed(candidate.record, reason: .superseded, snapshot: snapshot)
                )
            }
            candidates.removeAll { $0.record.family == .dailyMaximum }
        }
        candidates.sort {
            let left = policy.priority($0.record.family)
            let right = policy.priority($1.record.family)
            if left != right { return left > right }
            return $0.record.semanticEventID < $1.record.semanticEventID
        }

        let maximum = max(0, policy.maximumPostsPerEvaluation)
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
                        message: candidate.message,
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
                    try suppressed(
                        candidate.record,
                        reason: dayBudgetExhausted ? .budgetExceeded : .superseded,
                        snapshot: snapshot
                    )
                )
            }
        }
        if result.decisions.isEmpty,
           staleSuppressions.contains(where: { !isOff($0.family) }),
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

            if policy.isCloseScore(ownerTotal, opponentTotal, day.ordinal) {
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
            message: message,
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
                    outcome: terminal.outcome,
                    beltTake: beltTake(for: competition, in: snapshot)
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
                    outcome: nil,
                    dayOrdinal: ordinal,
                    liveMatchCount: max(1, snapshot.liveMatchCount)
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
            competition.opponentPoints,
            ordinal
        ) {
            result.append(
                try candidate(
                    family: .closeScore,
                    episode: .day(ordinal),
                    competition: competition,
                    snapshot: snapshot,
                    ownerPoints: competition.ownerPoints,
                    opponentPoints: competition.opponentPoints,
                    outcome: nil,
                    dayOrdinal: ordinal
                )
            )
        }

        // A change needs an earlier leader and never fires on Day 1;
        // `leadBaselineRecord` records the first leader silently.
        if let leader = currentLeader(competition),
           ordinal >= 2,
           let previous = mostRecentRecordedLeader(in: competition, through: ordinal),
           previous != leader {
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
                    outcome: nil,
                    dayOrdinal: ordinal
                )
            )
        }
        return result
    }

    private func currentLeader(
        _ competition: CompetitionNotificationCompetitionSnapshot
    ) -> NotificationEmissionLeader? {
        displayedLeader(competition.ownerPoints, competition.opponentPoints)
    }

    /// The first shown leader, and any Day 1 flip, is recorded silently: it is
    /// the baseline later changes compare against, and usually sync order.
    private func leadBaselineRecord(
        for competition: CompetitionNotificationCompetitionSnapshot,
        snapshot: CompetitionNotificationPlanningSnapshot
    ) throws -> NotificationEmissionRecorded? {
        guard competition.lifecycle.permitsFreshScoreCopy,
              competition.latestRefresh == .completed,
              competition.evaluationFreshness.isFreshCompletedRefresh,
              let ordinal = competition.currentDayOrdinal,
              let leader = currentLeader(competition)
        else {
            return nil
        }
        let previous = mostRecentRecordedLeader(in: competition, through: ordinal)
        guard previous != leader, previous == nil || ordinal == 1 else { return nil }
        return try NotificationEmissionRecorded(
            competitionID: competition.id,
            family: .leadChange,
            episodeKey: .leader(dayOrdinal: ordinal, leader: leader),
            disposition: .suppressed(reason: .superseded),
            decidedAt: snapshot.evaluatedAt,
            basisPublicationRevision: snapshot.publicationRevision
        )
    }

    /// Another live match already recorded today's daily maximum (emitted or
    /// suppressed), each checked against its own current day.
    private func dailyMaximumRecordedInAnotherMatch(
        _ competition: CompetitionNotificationCompetitionSnapshot,
        snapshot: CompetitionNotificationPlanningSnapshot
    ) -> Bool {
        snapshot.competitions.contains { other in
            guard other.id != competition.id,
                  other.lifecycle.isLiveDay,
                  let day = other.currentDayOrdinal,
                  let id = try? NotificationEmissionRecorded.semanticID(
                      competitionID: other.id,
                      family: .dailyMaximum,
                      episodeKey: .day(day)
                  )
            else {
                return false
            }
            return other.emissionHistory.recordedIDs.contains(id)
        }
    }

    private func suppressed(
        _ record: NotificationEmissionRecorded,
        reason: NotificationSuppressionReason,
        snapshot: CompetitionNotificationPlanningSnapshot
    ) throws -> NotificationEmissionRecorded {
        try NotificationEmissionRecorded(
            competitionID: record.competitionID,
            family: record.family,
            episodeKey: record.episodeKey,
            disposition: .suppressed(reason: reason),
            decidedAt: snapshot.evaluatedAt,
            basisPublicationRevision: snapshot.publicationRevision
        )
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

    /// The leader of the latest day with a recorded leader. When both leaders
    /// are recorded for that day (a Day 1 flip, or a same-day change), the
    /// record set can't say which came last, so that day's end-of-day shown
    /// totals decide; nil when they can't, so the next lead is a silent
    /// baseline rather than a guess.
    private func mostRecentRecordedLeader(
        in competition: CompetitionNotificationCompetitionSnapshot,
        through dayOrdinal: Int
    ) -> NotificationEmissionLeader? {
        guard dayOrdinal >= 1 else { return nil }
        for day in stride(from: min(dayOrdinal, 7), through: 1, by: -1) {
            let recorded = NotificationEmissionLeader.allCases.filter { leader in
                guard let id = try? NotificationEmissionRecorded.semanticID(
                    competitionID: competition.id,
                    family: .leadChange,
                    episodeKey: .leader(dayOrdinal: day, leader: leader)
                ) else {
                    return false
                }
                return competition.emissionHistory.recordedIDs.contains(id)
            }
            switch recorded.count {
            case 0: continue
            case 1: return recorded[0]
            default: return endOfDayLeader(in: competition, day: day)
            }
        }
        return nil
    }

    /// The shown leader of the cumulative totals through `day`; nil when any
    /// day's points are missing or the shown totals are equal.
    private func endOfDayLeader(
        in competition: CompetitionNotificationCompetitionSnapshot,
        day: Int
    ) -> NotificationEmissionLeader? {
        var ownerTotal = 0.0
        var opponentTotal = 0.0
        for ordinal in 1...day {
            guard let points = competition.days.first(where: { $0.ordinal == ordinal }),
                  let owner = points.ownerAcceptedPoints,
                  let opponent = points.opponentRevealedPoints
            else {
                return nil
            }
            ownerTotal += owner
            opponentTotal += opponent
        }
        return displayedLeader(ownerTotal, opponentTotal)
    }

    private func candidate(
        family: NotificationEmissionFamily,
        episode: NotificationEpisodeKey,
        competition: CompetitionNotificationCompetitionSnapshot,
        snapshot: CompetitionNotificationPlanningSnapshot,
        ownerPoints: Double?,
        opponentPoints: Double?,
        outcome: CompetitionOutcome?,
        dayOrdinal: Int? = nil,
        liveMatchCount: Int = 1,
        beltTake: CompetitionBeltEvent? = nil
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
                outcome: outcome,
                dayOrdinal: dayOrdinal,
                liveMatchCount: liveMatchCount,
                beltTake: beltTake
            )
        )
    }

    /// The belt event of a finished match when it took the belt, from every
    /// snapshot match with the same person (muted ones too, so muting never
    /// shifts the history). The fold orders weeks like History does.
    private func beltTake(
        for competition: CompetitionNotificationCompetitionSnapshot,
        in snapshot: CompetitionNotificationPlanningSnapshot
    ) -> CompetitionBeltEvent? {
        guard competition.opponentDisplayName != competitionFormerCompetitorName else { return nil }
        let event = competitionBelt(
            snapshot.competitions
                .filter { $0.opponentIdentity == competition.opponentIdentity }
                .compactMap { week in
                    week.terminalResult.map {
                        (
                            id: week.id,
                            end: week.schedule.flatMap(competitionScheduleBoundaries)?.end,
                            outcome: $0.outcome,
                            margin: abs($0.ownerPoints - $0.opponentPoints)
                        )
                    }
                }
        ).events[competition.id]
        if case .took = event { return event }
        return nil
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
