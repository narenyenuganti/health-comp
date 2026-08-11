import Foundation

public struct CompetitionEngine: Sendable {
    public enum EngineError: Error, Equatable, Sendable {
        case invalidTransition
        case eventForDifferentCompetition
        case missingSchedule
        case invalidFinalizationAuthorization
        case staleFinalizationAuthorization
        case opponentPlanMismatch
        case rematchRequiresCompletedCompetition
        case rematchMustUseNewIdentity
    }

    public init() {}

    public func accept(
        _ competition: Competition,
        at acceptedAt: Date,
        timeZoneIdentifier: String,
        opponent request: OpponentPlanGenerationRequest
    ) throws -> CompetitionEvent {
        guard case .pendingInvitation = competition.lifecycle else {
            throw EngineError.invalidTransition
        }
        if case let .pendingInvitation(invitation) = competition.lifecycle,
           let expiresAt = invitation.expiresAt,
           acceptedAt >= expiresAt {
            return event(
                for: competition,
                at: expiresAt,
                kind: .invitationExpired
            )
        }
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: timeZoneIdentifier
        )
        let schedule = CompetitionSchedule(
            calendar: calendar,
            startDay: try calendar.startDay(afterAcceptanceAt: acceptedAt)
        )
        let opponentPlan = try OpponentPlanGenerator.generate(
            seed: request.seed,
            generatorVersion: request.generatorVersion,
            difficulty: request.difficulty,
            schedule: schedule
        )
        return event(
            for: competition,
            at: acceptedAt,
            kind: .invitationAccepted(
                try AcceptedCompetitionConfiguration(
                    schedule: schedule,
                    opponentPlan: opponentPlan
                )
            )
        )
    }

    public func decline(
        _ competition: Competition,
        at declinedAt: Date
    ) throws -> CompetitionEvent {
        guard case let .pendingInvitation(invitation) = competition.lifecycle else {
            throw EngineError.invalidTransition
        }
        if let expiresAt = invitation.expiresAt, declinedAt >= expiresAt {
            return event(
                for: competition,
                at: expiresAt,
                kind: .invitationExpired
            )
        }
        return event(
            for: competition,
            at: declinedAt,
            kind: .invitationDeclined
        )
    }

    public func observeClock(
        _ competition: Competition,
        at observationDate: Date
    ) throws -> [CompetitionEvent] {
        if case let .pendingInvitation(invitation) = competition.lifecycle {
            guard let expiry = invitation.expiresAt, observationDate >= expiry else {
                return []
            }
            return unseen(
                [event(for: competition, at: expiry, kind: .invitationExpired)],
                in: competition
            )
        }

        switch competition.lifecycle {
        case .declined, .expired, .completed, .archived:
            return []
        case .pendingInvitation:
            return []
        case .scheduled, .active, .endsToday, .tallying:
            break
        }

        guard let schedule = competition.schedule else {
            throw EngineError.missingSchedule
        }

        let calendar = schedule.calendar
        let days = try calendar.sevenDayWindow(startingOn: schedule.startDay)
        var events: [CompetitionEvent] = []

        let dayOneStart = try calendar.startOfDay(days[0])
        if observationDate >= dayOneStart {
            events.append(
                event(for: competition, at: dayOneStart, kind: .competitionStarted)
            )
        }

        for ordinal in 1...6 {
            let nextDayStart = try calendar.startOfDay(days[ordinal])
            guard observationDate >= nextDayStart else { break }
            events.append(
                event(for: competition, at: nextDayStart, kind: .dayClosed(ordinal))
            )
            if ordinal == 6 {
                events.append(
                    event(for: competition, at: nextDayStart, kind: .finalDayStarted)
                )
            }
        }

        let dayAfterWindow = try calendar.day(after: days[6])
        let endBoundary = try calendar.startOfDay(dayAfterWindow)
        if observationDate >= endBoundary {
            events.append(
                event(for: competition, at: endBoundary, kind: .dayClosed(7))
            )
            events.append(
                event(for: competition, at: endBoundary, kind: .tallyStarted)
            )
        }

        return unseen(events, in: competition)
    }

    public func finalize(
        _ competition: Competition,
        authorization: FinalizationAuthorization,
        at completedAt: Date
    ) throws -> CompetitionEvent {
        guard case let .tallying(tally) = competition.lifecycle else {
            throw EngineError.invalidTransition
        }
        guard authorization.competitionID == competition.id else {
            throw EngineError.invalidFinalizationAuthorization
        }
        guard authorization.reconciliationRevision
                == tally.reconciliation.revision
        else {
            throw EngineError.staleFinalizationAuthorization
        }
        guard case let .finalize(currentAuthorization) = authorization.policy.decision(
            for: competition,
            at: authorization.decisionAt
        ), currentAuthorization == authorization else {
            throw EngineError.invalidFinalizationAuthorization
        }
        return event(
            for: competition,
            at: completedAt,
            kind: .competitionFinalized(
                FinalizationRecord(authorization: authorization)
            )
        )
    }

    public func recordFinalRead(
        _ competition: Competition,
        evidence: FinalReadEvidence
    ) throws -> CompetitionEvent {
        guard case .tallying = competition.lifecycle else {
            throw EngineError.invalidTransition
        }
        try validateOpponentPlanBinding(
            evidence: evidence,
            competition: competition
        )
        return event(
            for: competition,
            at: evidence.readAt,
            kind: .finalReadRecorded(
                FinalReadRecord(evidence: evidence)
            )
        )
    }

    public func archive(
        _ competition: Competition,
        at archivedAt: Date
    ) throws -> CompetitionEvent {
        guard case .completed = competition.lifecycle else {
            throw EngineError.invalidTransition
        }
        return event(
            for: competition,
            at: archivedAt,
            kind: .competitionArchived
        )
    }

    public func rematch(
        from competition: Competition,
        newID: CompetitionID,
        createdAt: Date,
        expiresAt: Date?
    ) throws -> Competition {
        switch competition.lifecycle {
        case .completed, .archived:
            break
        default:
            throw EngineError.rematchRequiresCompletedCompetition
        }
        guard newID != competition.id else {
            throw EngineError.rematchMustUseNewIdentity
        }
        return .pending(
            id: newID,
            direction: .outgoing,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }

    public func apply(
        _ events: [CompetitionEvent],
        to competition: inout Competition
    ) throws {
        var workingCopy = competition
        for event in events {
            try apply(event, to: &workingCopy)
        }
        competition = workingCopy
    }

    public func apply(
        _ event: CompetitionEvent,
        to competition: inout Competition
    ) throws {
        guard event.competitionID == competition.id else {
            throw EngineError.eventForDifferentCompetition
        }
        if case let .finalReadRecorded(record) = event.kind {
            try validateOpponentPlanBinding(
                evidence: record.evidence,
                competition: competition
            )
        }
        guard !competition.appliedEventIDs.contains(event.id) else {
            return
        }

        switch event.kind {
        case let .invitationAccepted(configuration):
            guard case .pendingInvitation = competition.lifecycle else {
                throw EngineError.invalidTransition
            }
            competition.schedule = configuration.schedule
            competition.opponentPlan = configuration.opponentPlan
            competition.lifecycle = .scheduled

        case .invitationDeclined:
            guard case .pendingInvitation = competition.lifecycle else {
                throw EngineError.invalidTransition
            }
            competition.lifecycle = .declined(at: event.occurredAt)

        case .invitationExpired:
            guard case .pendingInvitation = competition.lifecycle else {
                throw EngineError.invalidTransition
            }
            competition.lifecycle = .expired(at: event.occurredAt)

        case .competitionStarted:
            guard case .scheduled = competition.lifecycle else {
                throw EngineError.invalidTransition
            }
            competition.lifecycle = .active(day: try CompetitionActiveDay(1))

        case let .dayClosed(day):
            if day < 6 {
                guard case let .active(activeDay) = competition.lifecycle,
                      activeDay.ordinal == day
                else {
                    throw EngineError.invalidTransition
                }
                competition.lifecycle = .active(
                    day: try CompetitionActiveDay(day + 1)
                )
            } else if day == 6 {
                guard case let .active(activeDay) = competition.lifecycle,
                      activeDay.ordinal == 6
                else {
                    throw EngineError.invalidTransition
                }
            } else if day == 7 {
                guard case .endsToday = competition.lifecycle else {
                    throw EngineError.invalidTransition
                }
            } else {
                throw EngineError.invalidTransition
            }

        case .finalDayStarted:
            guard case let .active(activeDay) = competition.lifecycle,
                  activeDay.ordinal == 6
            else {
                throw EngineError.invalidTransition
            }
            competition.lifecycle = .endsToday

        case .tallyStarted:
            guard case .endsToday = competition.lifecycle else {
                throw EngineError.invalidTransition
            }
            competition.lifecycle = .tallying(
                TallyingCompetition(startedAt: event.occurredAt)
            )

        case let .finalReadRecorded(record):
            guard case var .tallying(tally) = competition.lifecycle else {
                throw EngineError.invalidTransition
            }
            tally.reconciliation.record(
                record.evidence,
                boundary: tally.startedAt
            )
            competition.lifecycle = .tallying(tally)

        case let .competitionFinalized(record):
            guard case let .tallying(tally) = competition.lifecycle else {
                throw EngineError.invalidTransition
            }
            guard record.reconciliationRevision == tally.reconciliation.revision else {
                throw EngineError.staleFinalizationAuthorization
            }
            let authorization = FinalizationAuthorization(
                competitionID: competition.id,
                reconciliationRevision: record.reconciliationRevision,
                eligibleAttemptID: record.eligibleAttemptID,
                snapshot: record.snapshot,
                basis: record.basis,
                policy: record.policy,
                decisionAt: record.decisionAt
            )
            guard case let .finalize(currentAuthorization) = record.policy.decision(
                for: competition,
                at: record.decisionAt
            ), currentAuthorization == authorization else {
                throw EngineError.invalidFinalizationAuthorization
            }
            competition.lifecycle = .completed(
                CompletedCompetition(
                    snapshot: record.snapshot,
                    basis: record.basis,
                    completedAt: event.occurredAt
                )
            )

        case .competitionArchived:
            guard case let .completed(completed) = competition.lifecycle else {
                throw EngineError.invalidTransition
            }
            competition.lifecycle = .archived(
                ArchivedCompetition(
                    completed: completed,
                    archivedAt: event.occurredAt
                )
            )
        }

        competition.appliedEventIDs.append(event.id)
    }

    private func event(
        for competition: Competition,
        at occurredAt: Date,
        kind: CompetitionEventKind
    ) -> CompetitionEvent {
        CompetitionEvent(
            competitionID: competition.id,
            occurredAt: occurredAt,
            kind: kind
        )
    }

    private func validateOpponentPlanBinding(
        evidence: FinalReadEvidence,
        competition: Competition
    ) throws {
        guard let content = evidence.completeWindowContent else {
            return
        }
        guard let opponentPlan = competition.opponentPlan,
              opponentPlan.matches(content)
        else {
            throw EngineError.opponentPlanMismatch
        }
    }

    private func unseen(
        _ events: [CompetitionEvent],
        in competition: Competition
    ) -> [CompetitionEvent] {
        events.filter { !competition.appliedEventIDs.contains($0.id) }
    }
}
