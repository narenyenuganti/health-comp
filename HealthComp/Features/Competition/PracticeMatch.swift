import CompetitionCore
import Foundation

/// A solo week on this iPhone against a bot. It runs on the local
/// engine beside the real matches, reads Health only through the runtime's
/// own reads, never takes HealthKit signal ownership and sends nothing.
enum PracticeMatch {
    static let opponentDisplayName = "Pacer"
    static let opponentIdentity = "practice-pacer:v1"
    /// The bot's name. A practice stored with an old pace stays "Pacer".
    static func opponentDisplayName(for difficulty: OpponentDifficulty?) -> String {
        difficulty.flatMap { BotMode(rawValue: $0.rawValue) }?.rawValue.capitalized
            ?? opponentDisplayName
    }

    /// In-flight and rejection key for Start. Never a journal id.
    static let startCommandID = CompetitionID(
        UUID(uuidString: "5A3C0000-0000-4000-8000-000000000001")!
    )
    static let fallbackBaselineDailyPoints = 300
    static let baselineRange = 100...600
    /// The pacer moves at most this often while Home is open.
    static let minimumRevealInterval: TimeInterval = 300

    /// Your usual daily points: the mean of the scored days, or 300 with
    /// fewer than 3 of them.
    static func baselineDailyPoints(_ reads: [ActivityWindowRead]) -> Int {
        let points = reads.flatMap(\.days).compactMap { result -> Double? in
            guard case let .snapshot(_, snapshot) = result else { return nil }
            return ActivityScoreCalculator.score(snapshot, policy: .healthKitCompatibility)
                .availableScore.map { min($0.points, ActivityScore.maximumDailyPoints) }
        }
        guard points.count >= 3 else { return fallbackBaselineDailyPoints }
        let mean = Int((points.reduce(0, +) / Double(points.count)).rounded())
        return min(max(mean, baselineRange.lowerBound), baselineRange.upperBound)
    }

    /// The 14 days before today, as two 7-day reads. A failed read is skipped.
    static func readLastTwoWeeks(
        environment: CompetitionEnvironmentClient,
        context: CompetitionEnvironmentContext
    ) async -> [ActivityWindowRead] {
        guard let calendar = try? CompetitionCalendar(timeZoneIdentifier: context.timeZoneIdentifier),
              let zone = TimeZone(identifier: context.timeZoneIdentifier)
        else { return [] }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = zone
        let today = gregorian.startOfDay(for: context.instant.wallDate)
        var reads: [ActivityWindowRead] = []
        for offset in [-14, -7] {
            guard let start = gregorian.date(byAdding: .day, value: offset, to: today),
                  let day = try? calendar.day(containing: start),
                  let window = try? CompetitionActivityWindow(calendar: calendar, startDay: day),
                  let read = try? await environment.read(window)
            else { continue }
            reads.append(read)
        }
        return reads
    }

    /// Starts tomorrow against a bot scaled to your last 2 weeks.
    static func start(
        _ difficulty: OpponentDifficulty,
        runtime: LocalCompetitionRuntime,
        environment: CompetitionEnvironmentClient
    ) async throws -> CompetitionID {
        let loaded = await runtime.loadAll()
        guard loaded.enumerationFailure == nil else {
            throw PracticeMatchError.storageUnavailable
        }
        for journal in loaded.successfulJournals {
            switch journal.projection.competition.lifecycle {
            case .scheduled, .active, .endsToday, .tallying:
                throw PracticeMatchError.alreadyUnderway
            default:
                break
            }
        }
        // Finished, broken or interrupted (still pending) practices go first.
        let leftovers = loaded.successfulJournals.map(\.projection.competition.id)
            + loaded.failures.map(\.competitionID)
        for id in leftovers {
            try? await runtime.delete(competitionID: id)
        }
        let context = await environment.context()
        let baseline = baselineDailyPoints(
            await readLastTwoWeeks(environment: environment, context: context)
        )
        let id = CompetitionID(UUID())
        try await runtime.create(
            try CompetitionGenesis(
                competitionID: id,
                direction: .outgoing,
                createdAt: context.instant.wallDate,
                expiresAt: nil,
                scoringPolicy: .healthKitCompatibility,
                downwardRevisionPolicy: .maximumObserved
            )
        )
        try await runtime.accept(
            competitionID: id,
            opponent: OpponentPlanGenerationRequest(
                seed: .random(in: .min ... .max),
                generatorVersion: .v3,
                difficulty: difficulty,
                baselineDailyPoints: baseline
            )
        )
        return id
    }

    /// The pacer's next checkpoint today, at least 5 minutes out, so a Home
    /// left open doesn't show a frozen pacer. Day boundaries come from the
    /// runtime's `nextWake`.
    static func nextPacerReveal(journals: [LoadedCompetitionJournal], now: Date) -> Date? {
        journals.compactMap { loaded -> Date? in
            let competition = loaded.projection.competition
            switch competition.lifecycle {
            case .active, .endsToday: break
            default: return nil
            }
            guard let schedule = competition.schedule,
                  let plan = competition.opponentPlan,
                  let days = try? schedule.calendar.sevenDayWindow(startingOn: schedule.startDay),
                  let today = try? schedule.calendar.day(containing: now),
                  let offset = days.firstIndex(of: today),
                  let start = try? schedule.calendar.startOfDay(today),
                  let end = try? schedule.calendar.startOfDay(schedule.calendar.day(after: today)),
                  let day = plan.days.first(where: { $0.ordinal == offset + 1 })
            else { return nil }
            let length = end.timeIntervalSince(start)
            return day.checkpoints
                .map { start.addingTimeInterval(Double($0.progressBasisPoints) / 10_000 * length) }
                .first { $0 > now }
                .map { max($0, now.addingTimeInterval(minimumRevealInterval)) }
        }.min()
    }

    /// Finished practices whose result has left Home: deleted, so no Health
    /// values linger out of sight.
    static func expiredResults(journals: [LoadedCompetitionJournal], now: Date) -> [CompetitionID] {
        journals.compactMap { loaded in
            let competition = loaded.projection.competition
            guard case let .completed(completed) = competition.lifecycle,
                  let schedule = competition.schedule,
                  let leaves = competitionResultLeavesHome(
                      schedule: schedule,
                      completedAt: completed.completedAt
                  )?.at,
                  leaves <= now
            else { return nil }
            return competition.id
        }
    }
}

enum PracticeMatchError: Error, Equatable {
    case alreadyUnderway
    case storageUnavailable
}

extension LocalCompetitionPresentation {
    var isPractice: Bool { opponentIdentity == PracticeMatch.opponentIdentity }
}

extension LocalCompetitionDashboard {
    /// Practice sits beside the real matches; it never adds awards or issues.
    func addingPractice(_ practice: [LocalCompetitionPresentation]) -> Self {
        guard !practice.isEmpty else { return self }
        return Self(
            competitions: (competitions + practice).sorted {
                $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
            },
            awards: awards,
            issues: issues,
            hiddenTerminalCompetitionCount: hiddenTerminalCompetitionCount,
            groupMatches: groupMatches
        )
    }
}
