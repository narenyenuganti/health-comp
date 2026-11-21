import CompetitionCore
import Foundation

struct PracticeShadowRival: Equatable, Identifiable, Sendable {
    let id: String
    let profileID: UUID?
    let displayName: String
    let samples: [OpponentRivalSample]
    let profile: OpponentShadowProfile

    var shadowDisplayName: String { "\(displayName)’s Shadow" }

    var summaryLine: String {
        "Avg \(profile.mean)/day · \(profile.bounds.lowerBound)–\(profile.bounds.upperBound) pts"
    }

    init(
        id: String,
        profileID: UUID?,
        displayName: String,
        samples: [OpponentRivalSample]
    ) throws {
        self.id = id
        self.profileID = profileID
        self.displayName = displayName
        self.samples = samples
        self.profile = try OpponentShadowProfile(
            samples: samples,
            opponentName: "\(displayName)’s Shadow"
        )
    }
}

enum PracticeStartTarget: Equatable, Sendable {
    case bot(OpponentDifficulty, metrics: CompetitionMetrics = .threeRings)
    case shadow(PracticeShadowRival, metrics: CompetitionMetrics = .threeRings)

    var metrics: CompetitionMetrics {
        switch self {
        case let .bot(_, metrics), let .shadow(_, metrics):
            metrics.isEmpty ? .threeRings : metrics
        }
    }
}

enum PracticeMetricsStore {
    private static let key = "healthcomp.practice.metrics.v1"

    static func save(_ metrics: CompetitionMetrics, for id: CompetitionID) {
        var map = loadAll()
        if metrics.isDefaultRings {
            map.removeValue(forKey: id.rawValue.uuidString.lowercased())
        } else {
            map[id.rawValue.uuidString.lowercased()] = metrics.rawValue
        }
        UserDefaults.standard.set(map, forKey: key)
    }

    static func metrics(for id: CompetitionID) -> CompetitionMetrics {
        guard let raw = loadAll()[id.rawValue.uuidString.lowercased()] else {
            return .threeRings
        }
        let parsed = CompetitionMetrics(rawValue: raw)
        return parsed.isEmpty ? .threeRings : parsed
    }

    static func remove(for id: CompetitionID) {
        var map = loadAll()
        map.removeValue(forKey: id.rawValue.uuidString.lowercased())
        UserDefaults.standard.set(map, forKey: key)
    }

    private static func loadAll() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
    }
}

enum PracticeMatch {
    static let opponentDisplayName = "Pacer"
    static let opponentIdentity = "practice-pacer:v1"
    static func opponentDisplayName(for difficulty: OpponentDifficulty?) -> String {
        if difficulty == .shadow { return "Shadow" }
        return difficulty.flatMap { BotMode(rawValue: $0.rawValue) }?.rawValue.capitalized
            ?? opponentDisplayName
    }

    static func opponentDisplayName(for plan: OpponentPlan?) -> String {
        if let custom = plan?.opponentName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        return opponentDisplayName(for: plan?.difficulty)
    }

    static let startCommandID = CompetitionID(
        UUID(uuidString: "5A3C0000-0000-4000-8000-000000000001")!
    )
    static let fallbackBaselineDailyPoints = 300
    static let baselineRange = 100...600
    static let minimumRevealInterval: TimeInterval = 300

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

    static func start(
        _ difficulty: OpponentDifficulty,
        runtime: LocalCompetitionRuntime,
        environment: CompetitionEnvironmentClient
    ) async throws -> CompetitionID {
        try await start(.bot(difficulty), runtime: runtime, environment: environment)
    }

    static func start(
        _ target: PracticeStartTarget,
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
        let leftovers = loaded.successfulJournals.map(\.projection.competition.id)
            + loaded.failures.map(\.competitionID)
        for id in leftovers {
            try? await runtime.delete(competitionID: id)
            PracticeMetricsStore.remove(for: id)
        }
        let context = await environment.context()
        let request: OpponentPlanGenerationRequest
        let chosenMetrics = target.metrics
        switch target {
        case let .bot(difficulty, _):
            let baseline = baselineDailyPoints(
                await readLastTwoWeeks(environment: environment, context: context)
            )
            request = OpponentPlanGenerationRequest(
                seed: .random(in: .min ... .max),
                generatorVersion: .v3,
                difficulty: difficulty,
                baselineDailyPoints: baseline
            )
        case let .shadow(rival, _):
            request = OpponentPlanGenerationRequest(
                seed: .random(in: .min ... .max),
                generatorVersion: .v4,
                difficulty: .shadow,
                shadowProfile: rival.profile
            )
        }
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
            opponent: request
        )
        PracticeMetricsStore.save(chosenMetrics, for: id)
        return id
    }

    static func shadowRivals(
        competitions: [LocalCompetitionPresentation],
        groupMatches: [GroupMatchPresentation] = [],
        blocked: [AuthenticatedProfile] = []
    ) -> [PracticeShadowRival] {
        let blockedIDs = Set(blocked.map(\.id))
        struct Bucket {
            var profileID: UUID?
            var displayName: String
            var samples: [OpponentRivalSample] = []
        }
        var buckets: [String: Bucket] = [:]
        var order: [String] = []

        func record(identity: String, profileID: UUID?, name: String, day: CompetitionDay, points: Int) {
            guard name != competitionFormerCompetitorName, !name.isEmpty else { return }
            if let profileID, blockedIDs.contains(profileID) { return }
            let weekday = gregorianWeekday(year: day.year, month: day.month, day: day.day)
            guard let sample = try? OpponentRivalSample(weekday: weekday, points: points) else { return }
            if buckets[identity] == nil {
                order.append(identity)
                buckets[identity] = Bucket(profileID: profileID, displayName: name)
            }
            buckets[identity]?.displayName = name
            buckets[identity]?.samples.append(sample)
        }

        for competition in competitions where !competition.isPractice {
            let maxClosedOrdinal: Int
            switch competition.lifecycle {
            case .completed, .archived, .tallying:
                maxClosedOrdinal = 7
            case let .active(dayOrdinal):
                maxClosedOrdinal = dayOrdinal - 1
            case .endsToday:
                maxClosedOrdinal = 6
            case .pending, .scheduled, .declined, .expired, .cancelled:
                continue
            }
            guard maxClosedOrdinal >= 1 else { continue }
            let pid = RemoteCompetitionOpponentIdentity.profileID(competition.opponentIdentity)
            for day in competition.days where day.ordinal <= maxClosedOrdinal && !day.opponentReportedNoData {
                guard let revealed = day.opponentRevealedPoints else { continue }
                let ringOnly = revealed - (day.opponentSleepPoints ?? 0)
                let pts = Int(min(600, max(0, ringOnly.rounded())))
                record(
                    identity: competition.opponentIdentity,
                    profileID: pid,
                    name: competition.opponentDisplayName,
                    day: day.day,
                    points: pts
                )
            }
        }

        for match in groupMatches where match.frozenStandings != nil {
            guard let schedule = match.schedule,
                  let window = try? schedule.calendar.sevenDayWindow(startingOn: schedule.startDay),
                  window.count == 7
            else { continue }
            let dayRows = match.frozenDays ?? match.days
            for seat in match.seats where seat.id != match.viewerSeatID {
                guard let pid = seat.profileID else { continue }
                let identity = RemoteCompetitionOpponentIdentity.identity(for: pid)
                for row in dayRows where row.seatID == seat.id && (1...7).contains(row.ordinal) {
                    guard case let .centipoints(centipoints) = row.value else { continue }
                    let pts = min(600, max(0, (centipoints + 50) / 100))
                    record(
                        identity: identity,
                        profileID: pid,
                        name: seat.name,
                        day: window[row.ordinal - 1],
                        points: pts
                    )
                }
            }
        }

        return order.compactMap { identity -> PracticeShadowRival? in
            guard let bucket = buckets[identity] else { return nil }
            return try? PracticeShadowRival(
                id: identity,
                profileID: bucket.profileID,
                displayName: bucket.displayName,
                samples: bucket.samples
            )
        }.sorted { lhs, rhs in
            if lhs.samples.count != rhs.samples.count {
                return lhs.samples.count > rhs.samples.count
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func gregorianWeekday(year y0: Int, month m: Int, day d: Int) -> Int {
        let offsets = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
        let y = m < 3 ? y0 - 1 : y0
        let zeroBased = (y + y / 4 - y / 100 + y / 400 + offsets[m - 1] + d) % 7
        return ((zeroBased + 7) % 7) + 1
    }

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

    static func startBlocker(
        in competitions: [LocalCompetitionPresentation]
    ) -> String? {
        guard let underway = competitions.first(where: { competition in
            guard competition.isPractice else { return false }
            switch competition.lifecycle {
            case .scheduled, .active, .endsToday, .tallying: return true
            default: return false
            }
        }) else { return nil }
        return "In a practice match with \(underway.opponentDisplayName)"
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
