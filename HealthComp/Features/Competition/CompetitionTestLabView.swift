#if DEBUG

import CompetitionCore
import ComposableArchitecture
import Foundation
import SwiftUI

enum CompetitionTestLabFixtureKind: String, CaseIterable, Equatable, Sendable {
    case lateSync = "late-sync"
    case missing
    case unavailable
    case moveTimeRoll = "move-time-roll"
    case bestAvailable = "best-available"
    case loss
    case tie

    var title: String {
        switch self {
        case .lateSync: "Full late-sync lifecycle"
        case .missing: "Missing Activity"
        case .unavailable: "Unavailable Activity"
        case .moveTimeRoll: "Move Time and Roll"
        case .bestAvailable: "Best available result"
        case .loss: "Completed loss"
        case .tie: "Completed tie"
        }
    }
}

enum CompetitionTestLabJournalMode: Equatable, Sendable {
    case unique
    case persistent
}

struct CompetitionTestLabConfiguration: Equatable, Sendable {
    let fixture: CompetitionTestLabFixtureKind
    let seed: UInt64
    let difficulty: OpponentDifficulty
    let direction: InvitationDirection
    let runID: String
    let journalMode: CompetitionTestLabJournalMode

    init(
        fixture: CompetitionTestLabFixtureKind,
        seed: UInt64,
        difficulty: OpponentDifficulty,
        direction: InvitationDirection,
        runID: String,
        journalMode: CompetitionTestLabJournalMode = .unique
    ) {
        self.fixture = fixture
        self.seed = seed
        self.difficulty = difficulty
        self.direction = direction
        self.runID = runID
        self.journalMode = journalMode
    }

    static func defaultConfiguration() -> Self {
        Self(
            fixture: .lateSync,
            seed: 424_242,
            difficulty: .balanced,
            direction: .outgoing,
            runID: "lab-\(UUID().uuidString.lowercased())"
        )
    }
}

enum CompetitionTestLabLaunchDecision: Equatable {
    case disabled
    case configured(CompetitionTestLabConfiguration)
    case invalid(String)
}

enum CompetitionTestLabLaunchParser {
    static func decision(arguments: [String]) -> CompetitionTestLabLaunchDecision {
        guard arguments.contains("--local-competition-test-lab") else {
            return .disabled
        }

        var fixture = CompetitionTestLabFixtureKind.lateSync
        var seed: UInt64 = 424_242
        var difficulty = OpponentDifficulty.balanced
        var direction = InvitationDirection.outgoing
        var runID = "lab-\(UUID().uuidString.lowercased())"
        var hasExplicitRunID = false
        var seen = Set<String>()
        var index = 0

        func value(after option: String, at index: Int) -> String? {
            guard index + 1 < arguments.count else { return nil }
            let value = arguments[index + 1]
            guard !value.hasPrefix("--") else { return nil }
            return value
        }

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--local-competition-test-lab" {
                index += 1
                continue
            }
            guard argument.hasPrefix("--local-competition-") else {
                index += 1
                continue
            }
            guard seen.insert(argument).inserted,
                  let rawValue = value(after: argument, at: index)
            else {
                return .invalid("Invalid or repeated option: \(argument)")
            }
            switch argument {
            case "--local-competition-fixture":
                guard let parsed = CompetitionTestLabFixtureKind(
                    rawValue: rawValue
                ) else {
                    return .invalid("Unknown fixture: \(rawValue)")
                }
                fixture = parsed
            case "--local-competition-seed":
                guard let parsed = UInt64(rawValue) else {
                    return .invalid("Seed must be an unsigned whole number.")
                }
                seed = parsed
            case "--local-competition-difficulty":
                guard let parsed = OpponentDifficulty(rawValue: rawValue) else {
                    return .invalid("Unknown difficulty: \(rawValue)")
                }
                difficulty = parsed
            case "--local-competition-direction":
                guard let parsed = InvitationDirection(rawValue: rawValue) else {
                    return .invalid("Unknown invitation direction: \(rawValue)")
                }
                direction = parsed
            case "--local-competition-run-id":
                guard isValidRunID(rawValue) else {
                    return .invalid("Run ID contains unsafe characters.")
                }
                runID = rawValue
                hasExplicitRunID = true
            default:
                return .invalid("Unknown test-lab option: \(argument)")
            }
            index += 2
        }

        guard isValidRunID(runID) else {
            return .invalid("Run ID contains unsafe characters.")
        }
        return .configured(
            CompetitionTestLabConfiguration(
                fixture: fixture,
                seed: seed,
                difficulty: difficulty,
                direction: direction,
                runID: runID,
                journalMode: hasExplicitRunID ? .persistent : .unique
            )
        )
    }

    static func isValidRunID(_ value: String) -> Bool {
        guard (1...80).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-"
                || scalar == "_"
        }
    }
}

enum CompetitionTestLabStorage {
    static var baseDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthCompTestLab", isDirectory: true)
            .standardizedFileURL
    }

    static func uniqueJournalRoot(runID: String) throws -> URL {
        guard CompetitionTestLabLaunchParser.isValidRunID(runID) else {
            throw CompetitionTestLabStorageError.invalidRunID
        }
        let runDirectory = baseDirectory
            .appendingPathComponent(runID, isDirectory: true)
            .standardizedFileURL
        let root = runDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        guard isSafeSessionRoot(root, runID: runID) else {
            throw CompetitionTestLabStorageError.unsafeRoot
        }
        return root
    }

    static func persistentJournalRoot(runID: String) throws -> URL {
        guard CompetitionTestLabLaunchParser.isValidRunID(runID) else {
            throw CompetitionTestLabStorageError.invalidRunID
        }
        let root = baseDirectory
            .appendingPathComponent(runID, isDirectory: true)
            .appendingPathComponent("persistent", isDirectory: true)
            .standardizedFileURL
        guard isSafeSessionRoot(root, runID: runID) else {
            throw CompetitionTestLabStorageError.unsafeRoot
        }
        return root
    }

    static func isSafeSessionRoot(_ root: URL, runID: String) -> Bool {
        guard CompetitionTestLabLaunchParser.isValidRunID(runID) else {
            return false
        }
        let expectedParent = baseDirectory
            .appendingPathComponent(runID, isDirectory: true)
            .standardizedFileURL
        let standardized = root.standardizedFileURL
        return standardized.deletingLastPathComponent() == expectedParent
            && (
                UUID(uuidString: standardized.lastPathComponent) != nil
                    || standardized.lastPathComponent == "persistent"
            )
    }

    static func removeSessionRoot(_ root: URL, runID: String) throws {
        guard isSafeSessionRoot(root, runID: runID) else {
            throw CompetitionTestLabStorageError.unsafeRoot
        }
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
    }
}

enum CompetitionTestLabStorageError: Error, Equatable {
    case invalidRunID
    case unsafeRoot
}

struct CompetitionTestLabCheckpoint: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case scheduledWake
        case fixtureChange
    }

    enum ExpectedProjection: Equatable, Sendable {
        case active(dayOrdinal: Int)
        case endsToday
        case tallying
        case tallyingAwaitingStability
        case completed(basis: FinalizationBasis)
    }

    let label: String
    let date: Date
    let kind: Kind
    let expectedProjection: ExpectedProjection

    func matches(_ publication: LocalCompetitionPublication) -> Bool {
        guard publication.evaluatedAt >= date,
              let competition = publication.dashboard.competitions.first
        else {
            return false
        }
        switch (expectedProjection, competition.lifecycle) {
        case let (.active(expected), .active(actual)):
            return expected == actual
        case (.endsToday, .endsToday):
            return true
        case (.tallying, .tallying):
            return true
        case (.tallyingAwaitingStability, .tallying):
            return competition.tally?.attention == .awaitingStability
        case let (.completed(expected), .completed(_, actual, _)):
            return expected == actual
        default:
            return false
        }
    }
}

struct CompetitionTestLabFixtureCatalog: Equatable, Sendable {
    let fixture: ActivityFixture
    let checkpoints: [CompetitionTestLabCheckpoint]

    static func make(
        configuration: CompetitionTestLabConfiguration
    ) throws -> Self {
        let acceptedAt = Date(timeIntervalSinceReferenceDate: 43_200)
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let startDay = try calendar.startDay(afterAcceptanceAt: acceptedAt)
        let days = try calendar.sevenDayWindow(startingOn: startDay)
        let schedule = CompetitionSchedule(
            calendar: calendar,
            startDay: startDay
        )
        let opponentPlan = try OpponentPlanGenerator.generate(
            seed: configuration.seed,
            generatorVersion: .v1,
            difficulty: configuration.difficulty,
            schedule: schedule
        )
        let boundaries = try days.map(calendar.startOfDay)
        let endBoundary = try calendar.startOfDay(
            calendar.day(after: days[6])
        )
        let lateDaySeven = endBoundary.addingTimeInterval(1)
        let stableResult = lateDaySeven.addingTimeInterval(0.000_000_001)
        let stableCompleteResult = endBoundary.addingTimeInterval(1)
        let fullSnapshot = try snapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .unknown,
            pauseState: .unknown
        )
        let moveTimeSnapshot = try snapshot(
            moveMode: .moveMinutes,
            standMode: .rollHours,
            pauseState: .running
        )

        let initialDays: [FixtureActivityValue]
        let initialReadState: FixtureActivityReadState
        var changes: [FixtureActivityChange] = []
        var checkpoints = boundaries.enumerated().map { offset, date in
            CompetitionTestLabCheckpoint(
                label: offset < 6 ? "Day \(offset + 1)" : "Ends Today",
                date: date,
                kind: .scheduledWake,
                expectedProjection: offset < 6
                    ? .active(dayOrdinal: offset + 1)
                    : .endsToday
            )
        }
        checkpoints.append(
            CompetitionTestLabCheckpoint(
                label: "Tallying Points",
                date: endBoundary,
                kind: .scheduledWake,
                expectedProjection: .tallying
            )
        )

        switch configuration.fixture {
        case .lateSync:
            initialDays = days.enumerated().map { offset, day in
                offset < 6
                    ? .snapshot(day: day, snapshot: fullSnapshot)
                    : .missing(day: day)
            }
            initialReadState = .available
            changes = [
                try FixtureActivityChange(
                    at: lateDaySeven,
                    updates: [
                        .snapshot(day: days[6], snapshot: fullSnapshot),
                    ],
                    triggers: [.summaryUpdate]
                ),
            ]
            checkpoints.append(
                CompetitionTestLabCheckpoint(
                    label: "Late Day 7",
                    date: lateDaySeven,
                    kind: .fixtureChange,
                    expectedProjection: .tallyingAwaitingStability
                )
            )
            checkpoints.append(
                CompetitionTestLabCheckpoint(
                    label: "Result",
                    date: stableResult,
                    kind: .scheduledWake,
                    expectedProjection: .completed(
                        basis: .stableAcrossPostBoundaryReads
                    )
                )
            )

        case .missing:
            initialDays = days.map { .missing(day: $0) }
            initialReadState = .available
            checkpoints.append(
                CompetitionTestLabCheckpoint(
                    label: "Fallback Check",
                    date: endBoundary.addingTimeInterval(60),
                    kind: .scheduledWake,
                    expectedProjection: .tallying
                )
            )

        case .unavailable:
            initialDays = days.map {
                .snapshot(day: $0, snapshot: fullSnapshot)
            }
            initialReadState = .failure(.healthDataUnavailable)
            checkpoints.append(
                CompetitionTestLabCheckpoint(
                    label: "Fallback Check",
                    date: endBoundary.addingTimeInterval(60),
                    kind: .scheduledWake,
                    expectedProjection: .tallying
                )
            )

        case .moveTimeRoll:
            initialDays = days.map {
                .snapshot(day: $0, snapshot: moveTimeSnapshot)
            }
            initialReadState = .available
            checkpoints.append(
                CompetitionTestLabCheckpoint(
                    label: "Stable Read",
                    date: stableCompleteResult,
                    kind: .scheduledWake,
                    expectedProjection: .completed(
                        basis: .stableAcrossPostBoundaryReads
                    )
                )
            )

        case .bestAvailable:
            initialDays = days.map { day in
                .snapshot(day: day, snapshot: fullSnapshot)
            }
            initialReadState = .available
            checkpoints.append(
                CompetitionTestLabCheckpoint(
                    label: "Best Available Result",
                    date: endBoundary.addingTimeInterval(60),
                    kind: .scheduledWake,
                    expectedProjection: .completed(basis: .bestAvailable)
                )
            )

        case .loss:
            let zero = try pointsSnapshot(points: 0)
            initialDays = days.map {
                .snapshot(day: $0, snapshot: zero)
            }
            initialReadState = .available
            checkpoints.append(
                CompetitionTestLabCheckpoint(
                    label: "Loss Result",
                    date: stableCompleteResult,
                    kind: .scheduledWake,
                    expectedProjection: .completed(
                        basis: .stableAcrossPostBoundaryReads
                    )
                )
            )

        case .tie:
            initialDays = try zip(days, opponentPlan.days).map { day, planDay in
                .snapshot(
                    day: day,
                    snapshot: try pointsSnapshot(points: planDay.finalPoints)
                )
            }
            initialReadState = .available
            checkpoints.append(
                CompetitionTestLabCheckpoint(
                    label: "Tie Result",
                    date: stableResult,
                    kind: .scheduledWake,
                    expectedProjection: .completed(
                        basis: .stableAcrossPostBoundaryReads
                    )
                )
            )
        }

        return Self(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: acceptedAt,
                    monotonic: MonotonicInstant(
                        epochID: "test-lab-\(configuration.runID)",
                        nanoseconds: 1_000
                    )
                ),
                timeZoneIdentifier: "UTC",
                initialDays: initialDays,
                initialReadState: initialReadState,
                changes: changes
            ),
            checkpoints: checkpoints
        )
    }

    private static func snapshot(
        moveMode: ActivityMoveMode,
        standMode: ActivityStandMode,
        pauseState: ActivityPauseState
    ) throws -> ActivitySnapshot {
        let move: ActivityRingReading
        switch moveMode {
        case .activeEnergyKilocalories:
            move = try ActivityRingReading(value: 1_000, goal: 500)
        case .moveMinutes:
            move = try ActivityRingReading(value: 60, goal: 30)
        }
        return ActivitySnapshot(
            moveMode: moveMode,
            standMode: standMode,
            move: move,
            exercise: try ActivityRingReading(value: 60, goal: 30),
            standOrRoll: try ActivityRingReading(value: 24, goal: 12),
            pauseState: pauseState
        )
    }

    private static func pointsSnapshot(points: Int) throws -> ActivitySnapshot {
        ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(
                value: Double(points),
                goal: 100
            ),
            exercise: try ActivityRingReading(value: 0, goal: 100),
            standOrRoll: try ActivityRingReading(value: 0, goal: 100),
            pauseState: .running
        )
    }
}

private struct CompetitionTestLabPersistedState: Codable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let checkpointIndex: Int
    let logicalDate: Date

    init(checkpointIndex: Int, logicalDate: Date) {
        self.schemaVersion = Self.schemaVersion
        self.checkpointIndex = checkpointIndex
        self.logicalDate = logicalDate
    }
}

private enum CompetitionTestLabPersistedStateStore {
    static func load(
        root: URL,
        catalog: CompetitionTestLabFixtureCatalog
    ) throws -> CompetitionTestLabPersistedState? {
        let url = stateURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let state: CompetitionTestLabPersistedState
        do {
            state = try JSONDecoder().decode(
                CompetitionTestLabPersistedState.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw CompetitionTestLabPersistedStateError.corrupt
        }
        guard state.schemaVersion
            == CompetitionTestLabPersistedState.schemaVersion,
            (0...catalog.checkpoints.count).contains(state.checkpointIndex)
        else {
            throw CompetitionTestLabPersistedStateError.outOfCatalog
        }
        let expectedDate = state.checkpointIndex == 0
            ? catalog.fixture.initialInstant.wallDate
            : catalog.checkpoints[state.checkpointIndex - 1].date
        guard abs(state.logicalDate.timeIntervalSince(expectedDate))
            < 0.000_001
        else {
            throw CompetitionTestLabPersistedStateError.outOfCatalog
        }
        return state
    }

    static func save(
        checkpointIndex: Int,
        logicalDate: Date,
        root: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(
            CompetitionTestLabPersistedState(
                checkpointIndex: checkpointIndex,
                logicalDate: logicalDate
            )
        )
        try data.write(to: stateURL(root: root), options: .atomic)
    }

    private static func stateURL(root: URL) -> URL {
        root.appendingPathComponent("fixture-state-v1.json", isDirectory: false)
    }
}

private enum CompetitionTestLabPersistedStateError: Error {
    case corrupt
    case outOfCatalog
}

enum CompetitionTestLabPublicationAcknowledger {
    static func next(
        after baseline: UInt64,
        checkpoint: CompetitionTestLabCheckpoint,
        from publications: AsyncStream<LocalCompetitionPublication>
    ) async -> LocalCompetitionPublication? {
        for await publication in publications
        where publication.publicationRevision > baseline
            && checkpoint.matches(publication) {
            return publication
        }
        return nil
    }
}

struct CompetitionTestLabClientFactory {
    let make: (
        CompetitionEnvironmentClient,
        LocalCompetitionStoreAvailability,
        LocalCompetitionRuntimeConfiguration,
        InvitationDirection,
        UInt64,
        OpponentDifficulty
    ) -> CompetitionClient

    static let localFixture = Self { environment, store, configuration,
        direction, seed, difficulty in
        CompetitionClient.localFixture(
            environment: environment,
            storeAvailability: store,
            configuration: configuration,
            bootstrapDirection: direction,
            opponentRequest: { _ in
                OpponentPlanGenerationRequest(
                    seed: seed,
                    generatorVersion: .v1,
                    difficulty: difficulty
                )
            }
        )
    }
}

@MainActor
final class CompetitionTestLabSession: ObservableObject, Identifiable {
    let id = UUID()
    let configuration: CompetitionTestLabConfiguration
    let catalog: CompetitionTestLabFixtureCatalog
    let source: FixtureActivitySource
    let client: CompetitionClient
    let store: StoreOf<MainTabFeature>
    let journalRoot: URL

    @Published private(set) var checkpointIndex = 0
    @Published private(set) var isAdvancing = false
    @Published private(set) var canAdvance = false
    @Published private(set) var logicalDate: Date
    @Published private(set) var statusMessage = "Accept or start the invitation."
    private var readinessTask: Task<Void, Never>?

    init(
        configuration: CompetitionTestLabConfiguration,
        clientFactory: CompetitionTestLabClientFactory = .localFixture
    ) throws {
        let fixtureCatalog = try CompetitionTestLabFixtureCatalog.make(
            configuration: configuration
        )
        let root: URL
        switch configuration.journalMode {
        case .unique:
            root = try CompetitionTestLabStorage.uniqueJournalRoot(
                runID: configuration.runID
            )
        case .persistent:
            root = try CompetitionTestLabStorage.persistentJournalRoot(
                runID: configuration.runID
            )
        }
        let persistedState = configuration.journalMode == .persistent
            ? try CompetitionTestLabPersistedStateStore.load(
                root: root,
                catalog: fixtureCatalog
            )
            : nil
        let fixtureSource: FixtureActivitySource
        if let persistedState {
            fixtureSource = try FixtureActivitySource(
                fixture: fixtureCatalog.fixture,
                restoringAt: persistedState.logicalDate
            )
        } else {
            fixtureSource = FixtureActivitySource(
                fixture: fixtureCatalog.fixture
            )
        }
        let environment = CompetitionEnvironmentClient.accelerated(
            source: fixtureSource
        )
        let eventStore = JSONCompetitionEventStore(rootDirectory: root)
        let runtimeConfiguration: LocalCompetitionRuntimeConfiguration
        switch configuration.fixture {
        case .bestAvailable:
            runtimeConfiguration = LocalCompetitionRuntimeConfiguration(
                minimumStabilityNanoseconds: 120 * 1_000_000_000,
                bestAvailableGrace: 60
            )
        case .moveTimeRoll, .loss, .tie:
            runtimeConfiguration = LocalCompetitionRuntimeConfiguration(
                minimumStabilityNanoseconds: 1_000_000_000,
                bestAvailableGrace: 60
            )
        case .lateSync, .missing, .unavailable:
            runtimeConfiguration = .testing
        }
        let labClient = clientFactory.make(
            environment,
            .available(eventStore),
            runtimeConfiguration,
            configuration.direction,
            configuration.seed,
            configuration.difficulty
        )
        let labRoutingClient = CompetitionRoutingEnvironment.makeLab().client
        self.configuration = configuration
        self.catalog = fixtureCatalog
        self.source = fixtureSource
        self.journalRoot = root
        self.client = labClient
        self.store = Store(initialState: MainTabFeature.State()) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = labClient
            $0.competitionRoutingClient = labRoutingClient
        }
        self.checkpointIndex = persistedState?.checkpointIndex ?? 0
        self.logicalDate = persistedState?.logicalDate
            ?? fixtureCatalog.fixture.initialInstant.wallDate
    }

    var nextCheckpoint: CompetitionTestLabCheckpoint? {
        guard catalog.checkpoints.indices.contains(checkpointIndex) else {
            return nil
        }
        return catalog.checkpoints[checkpointIndex]
    }

    func observeCanonicalPublication(
        _ publication: LocalCompetitionPublication?
    ) {
        guard let publication else { return }
        logicalDate = publication.evaluatedAt
        guard !isAdvancing else { return }
        scheduleReadiness(for: publication)
    }

    func advanceOneCheckpoint() async {
        guard canAdvance, !isAdvancing, let checkpoint = nextCheckpoint else {
            return
        }
        isAdvancing = true
        canAdvance = false
        statusMessage = "Advancing to \(checkpoint.label)…"
        let baseline = store.withState {
            $0.competition.publication?.publicationRevision ?? 0
        }
        let publicationTask = Task<LocalCompetitionPublication?, Never> {
            [client] in
            await CompetitionTestLabPublicationAcknowledger.next(
                after: baseline,
                checkpoint: checkpoint,
                from: client.updates()
            )
        }

        do {
            try await source.advance(to: checkpoint.date)
            guard let publication = await publicationTask.value else {
                statusMessage = "No newer fixture publication arrived."
                isAdvancing = false
                return
            }
            guard await waitForCanonicalRevision(
                publication.publicationRevision
            ) else {
                statusMessage = "The canonical view did not catch up."
                isAdvancing = false
                return
            }
            checkpointIndex += 1
            logicalDate = publication.evaluatedAt
            if configuration.journalMode == .persistent {
                try CompetitionTestLabPersistedStateStore.save(
                    checkpointIndex: checkpointIndex,
                    logicalDate: logicalDate,
                    root: journalRoot
                )
            }
            isAdvancing = false
            statusMessage = checkpointIndex < catalog.checkpoints.count
                ? "Ready for \(catalog.checkpoints[checkpointIndex].label)."
                : "Fixture lifecycle complete."
            let canonical = store.withState { $0.competition.publication }
            scheduleReadiness(for: canonical)
        } catch {
            publicationTask.cancel()
            statusMessage = "Checkpoint failed: \(error.localizedDescription)"
            isAdvancing = false
        }
    }

    private func waitForCanonicalRevision(_ revision: UInt64) async -> Bool {
        for _ in 0..<50_000 {
            let current = store.withState {
                $0.competition.publication?.publicationRevision ?? 0
            }
            if current >= revision { return true }
            await Task.yield()
        }
        return false
    }

    private func scheduleReadiness(
        for publication: LocalCompetitionPublication?
    ) {
        readinessTask?.cancel()
        canAdvance = false
        guard !isAdvancing, let publication, let nextCheckpoint else {
            return
        }
        let expectedIndex = checkpointIndex
        let expectedRevision = publication.publicationRevision
        readinessTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<50_000 {
                guard !Task.isCancelled,
                      !self.isAdvancing,
                      self.checkpointIndex == expectedIndex,
                      self.store.withState({
                          $0.competition.publication?.publicationRevision
                      }) == expectedRevision
                else {
                    return
                }
                let waiterDates = await self.source.pendingWaiterDates()
                if self.hasExpectedWaiter(
                    waiterDates,
                    for: nextCheckpoint
                ) {
                    self.canAdvance = true
                    self.statusMessage = "Ready for \(nextCheckpoint.label)."
                    return
                }
                await Task.yield()
            }
        }
    }

    private func hasExpectedWaiter(
        _ waiterDates: [Date],
        for nextCheckpoint: CompetitionTestLabCheckpoint
    ) -> Bool {
        let epsilon = 0.000_001
        switch nextCheckpoint.kind {
        case .scheduledWake:
            return waiterDates.contains {
                abs($0.timeIntervalSince(nextCheckpoint.date)) < epsilon
            }
        case .fixtureChange:
            return waiterDates.first.map {
                $0 > nextCheckpoint.date
            } ?? false
        }
    }
}

@MainActor
final class CompetitionTestLabController: ObservableObject {
    @Published private(set) var session: CompetitionTestLabSession?
    @Published private(set) var configurationError: String?
    @Published var draftFixture: CompetitionTestLabFixtureKind
    @Published var draftSeed: String
    @Published var draftDifficulty: OpponentDifficulty
    @Published var draftDirection: InvitationDirection
    @Published var draftRunID: String

    private let initialConfiguration: CompetitionTestLabConfiguration
    private let clientFactory: CompetitionTestLabClientFactory

    init(
        configuration: CompetitionTestLabConfiguration,
        clientFactory: CompetitionTestLabClientFactory = .localFixture
    ) {
        self.initialConfiguration = configuration
        self.clientFactory = clientFactory
        self.draftFixture = configuration.fixture
        self.draftSeed = String(configuration.seed)
        self.draftDifficulty = configuration.difficulty
        self.draftDirection = configuration.direction
        self.draftRunID = configuration.runID
        rebuild(configuration)
    }

    func applyDraft() {
        guard let seed = UInt64(draftSeed),
              CompetitionTestLabLaunchParser.isValidRunID(draftRunID) else {
            configurationError = "Seed or run ID is invalid."
            return
        }
        rebuild(
            CompetitionTestLabConfiguration(
                fixture: draftFixture,
                seed: seed,
                difficulty: draftDifficulty,
                direction: draftDirection,
                runID: draftRunID,
                journalMode: .unique
            )
        )
    }

    func reset() {
        draftFixture = initialConfiguration.fixture
        draftSeed = String(initialConfiguration.seed)
        draftDifficulty = initialConfiguration.difficulty
        draftDirection = initialConfiguration.direction
        draftRunID = initialConfiguration.runID
        rebuild(
            CompetitionTestLabConfiguration(
                fixture: initialConfiguration.fixture,
                seed: initialConfiguration.seed,
                difficulty: initialConfiguration.difficulty,
                direction: initialConfiguration.direction,
                runID: initialConfiguration.runID,
                journalMode: .unique
            )
        )
    }

    private func rebuild(_ configuration: CompetitionTestLabConfiguration) {
        let priorSession = session
        do {
            let replacement = try CompetitionTestLabSession(
                configuration: configuration,
                clientFactory: clientFactory
            )
            session = replacement
            configurationError = nil
            if let priorSession {
                Task {
                    await priorSession.client.stop()
                    try? CompetitionTestLabStorage.removeSessionRoot(
                        priorSession.journalRoot,
                        runID: priorSession.configuration.runID
                    )
                }
            }
        } catch {
            configurationError = error.localizedDescription
        }
    }
}

struct CompetitionTestLabRootView: View {
    @StateObject var controller: CompetitionTestLabController

    init(configuration: CompetitionTestLabConfiguration) {
        _controller = StateObject(
            wrappedValue: CompetitionTestLabController(
                configuration: configuration,
                clientFactory: .localFixture
            )
        )
    }

    var body: some View {
        Group {
            if let session = controller.session {
                CompetitionTestLabView(
                    controller: controller,
                    session: session
                )
                .id(session.id)
            } else {
                CompetitionTestLabConfigurationErrorView(
                    message: controller.configurationError
                        ?? "The fixture session could not be created."
                )
            }
        }
    }
}

struct CompetitionTestLabView: View {
    @ObservedObject var controller: CompetitionTestLabController
    @ObservedObject var session: CompetitionTestLabSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsConfiguration = false

    var body: some View {
        VStack(spacing: 0) {
            testLabBar
            Divider()
            MainTabView(store: session.store)
        }
        .onChange(
            of: session.store.competition.publication?.publicationRevision,
            initial: true
        ) { _, _ in
            session.observeCanonicalPublication(
                session.store.competition.publication
            )
        }
        .sheet(isPresented: $showsConfiguration) {
            CompetitionTestLabConfigurationView(controller: controller)
        }
    }

    private var testLabBar: some View {
        VStack(spacing: 8) {
            metadataLayout { metadataItems }

            checkpointLayout { checkpointItems }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var metadataLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 10))
    }

    private var checkpointLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 10))
    }

    @ViewBuilder
    private var metadataItems: some View {
        Text("FIXTURE DATA")
            .font(.caption.weight(.bold))
            .foregroundStyle(.orange)
            // A leaf marker keeps this stable root identifier from replacing
            // the identifiers of every control in the containing lab view.
            .accessibilityIdentifier("testlab.root")
        Text(logicalTimeText)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("testlab.logical-time")
        Text(colorScheme == .dark ? "DARK" : "LIGHT")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("testlab.appearance")
            .accessibilityLabel(
                colorScheme == .dark ? "Dark appearance" : "Light appearance"
            )
        Spacer(minLength: 4)
        Button("Controls") { showsConfiguration = true }
            .font(.caption.weight(.semibold))
            .frame(minHeight: 44)
            .accessibilityIdentifier("testlab.controls")
    }

    @ViewBuilder
    private var checkpointItems: some View {
        Text(session.statusMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("testlab.current-step")
        Button {
            Task { await session.advanceOneCheckpoint() }
        } label: {
            if session.isAdvancing {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Text("Next Checkpoint")
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .buttonStyle(CompetitionTestLabCheckpointButtonStyle())
        .disabled(!session.canAdvance || session.isAdvancing)
        .accessibilityIdentifier("competition.testLab.nextCheckpoint")
    }

    private var logicalTimeText: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d, HH:mm:ss"
        return formatter.string(from: session.logicalDate) + " UTC"
    }
}

private struct CompetitionTestLabCheckpointButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: minimumHeight)
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .background(
                isEnabled ? Color.accentColor : Color.secondary.opacity(0.16),
                in: Capsule()
            )
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Capsule())
            .opacity(configuration.isPressed && isEnabled ? 0.82 : 1)
    }
}

private struct CompetitionTestLabConfigurationView: View {
    @ObservedObject var controller: CompetitionTestLabController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("Fixture", selection: $controller.draftFixture) {
                    ForEach(CompetitionTestLabFixtureKind.allCases, id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                .accessibilityIdentifier("testlab.fixture")
                TextField("Numeric seed", text: $controller.draftSeed)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("testlab.seed")
                Picker("Difficulty", selection: $controller.draftDifficulty) {
                    ForEach(OpponentDifficulty.allCases, id: \.self) {
                        Text($0.rawValue.capitalized).tag($0)
                    }
                }
                .accessibilityIdentifier("testlab.difficulty")
                Picker("Invitation", selection: $controller.draftDirection) {
                    Text("Outgoing").tag(InvitationDirection.outgoing)
                    Text("Incoming").tag(InvitationDirection.incoming)
                }
                .accessibilityIdentifier("testlab.direction")
                TextField("Run ID", text: $controller.draftRunID)

                if let error = controller.configurationError {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("testlab.configuration-error")
                }
            }
            .navigationTitle("Fixture Controls")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { controller.reset() }
                        .accessibilityIdentifier("testlab.reset")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        controller.applyDraft()
                        if controller.configurationError == nil { dismiss() }
                    }
                    .accessibilityIdentifier("testlab.apply")
                }
            }
        }
    }
}

struct CompetitionTestLabConfigurationErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView(
            "Fixture Configuration Error",
            systemImage: "exclamationmark.triangle.fill",
            description: Text(message)
        )
        .accessibilityIdentifier("testlab.configuration-error")
    }
}

#endif
