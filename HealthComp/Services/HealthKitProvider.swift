import Foundation
import HealthKit
import CompetitionCore

struct HealthKitObserverWakeup: @unchecked Sendable {
    let completion: () -> Void
}

struct HealthKitCompetitionDependencies: @unchecked Sendable {
    let isHealthDataAvailable: @Sendable () -> Bool
    let requestAuthorization: @Sendable (Set<HKObjectType>) async throws -> Void
    let readActivitySummaries: @Sendable (CompetitionActivityWindow) async throws -> [HKActivitySummary]
    let resolveStandMode: @Sendable () throws -> ActivityStandMode
    let summaryUpdates: @Sendable (CompetitionActivityWindow) -> AsyncStream<[HKActivitySummary]>
    let observerUpdates: @Sendable () -> AsyncStream<HealthKitObserverWakeup>
    let enableBackgroundDelivery: @Sendable (HKSampleType) async throws -> Void

    init(
        isHealthDataAvailable: @escaping @Sendable () -> Bool,
        requestAuthorization: @escaping @Sendable (Set<HKObjectType>) async throws -> Void,
        readActivitySummaries: @escaping @Sendable (CompetitionActivityWindow) async throws -> [HKActivitySummary],
        resolveStandMode: @escaping @Sendable () throws -> ActivityStandMode,
        summaryUpdates: @escaping @Sendable (CompetitionActivityWindow) -> AsyncStream<[HKActivitySummary]>,
        observerUpdates: @escaping @Sendable () -> AsyncStream<HealthKitObserverWakeup>,
        enableBackgroundDelivery: @escaping @Sendable (HKSampleType) async throws -> Void = { _ in }
    ) {
        self.isHealthDataAvailable = isHealthDataAvailable
        self.requestAuthorization = requestAuthorization
        self.readActivitySummaries = readActivitySummaries
        self.resolveStandMode = resolveStandMode
        self.summaryUpdates = summaryUpdates
        self.observerUpdates = observerUpdates
        self.enableBackgroundDelivery = enableBackgroundDelivery
    }

    static func test(
        summaries: [HKActivitySummary],
        standMode: ActivityStandMode = .standHours
    ) -> Self {
        Self(
            isHealthDataAvailable: { true },
            requestAuthorization: { _ in },
            readActivitySummaries: { _ in summaries },
            resolveStandMode: { standMode },
            summaryUpdates: { _ in AsyncStream { $0.finish() } },
            observerUpdates: { AsyncStream { $0.finish() } }
        )
    }
}

final class HealthKitProvider: HealthDataProvider, @unchecked Sendable {
    // HealthKit observer completion ownership must outlive any individual
    // feature/provider instance. The production state is process-rooted so a
    // replacement environment can replay pending signals instead of tearing
    // down callbacks before their journal outcome is persisted.
    private static let productionSignalState = HealthKitProviderSignalState()

    private let healthStore: HKHealthStore
    private let userId: UUID
    private let competitionDependencies: HealthKitCompetitionDependencies
    private let signalState: HealthKitProviderSignalState

    init(userId: UUID, healthStore: HKHealthStore = HKHealthStore()) {
        self.userId = userId
        self.healthStore = healthStore
        self.competitionDependencies = Self.liveCompetitionDependencies(
            healthStore: healthStore
        )
        self.signalState = Self.productionSignalState
    }

    init(
        userId: UUID,
        competitionDependencies: HealthKitCompetitionDependencies
    ) {
        self.userId = userId
        self.healthStore = HKHealthStore()
        self.competitionDependencies = competitionDependencies
        self.signalState = HealthKitProviderSignalState()
    }

    func requestAuthorization() async throws {
        guard competitionDependencies.isHealthDataAvailable() else {
            throw CompetitionActivitySourceError.healthDataUnavailable
        }
        let metricTypes = availableMetricTypes().compactMap {
            Self.hkObjectType(for: $0)
        }
        try await competitionDependencies.requestAuthorization(
            Self.competitionReadTypes().union(metricTypes)
        )
        await ensureBackgroundDelivery()
    }

    func requestReadAuthorization() async throws {
        guard competitionDependencies.isHealthDataAvailable() else {
            throw CompetitionActivitySourceError.healthDataUnavailable
        }
        try await competitionDependencies.requestAuthorization(
            Self.competitionReadTypes()
        )
        await ensureBackgroundDelivery()
    }

    func availableMetricTypes() -> [MetricType] {
        [.activeCalories, .exerciseMinutes, .standHours, .steps, .sleepScore, .distance]
    }

    func fetchMetrics(for range: DateRange, types: [MetricType]) async throws -> [HealthMetric] {
        var results: [HealthMetric] = []
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        for type in types {
            let value = try await fetchSingleMetric(type: type, range: range)
            if let value {
                results.append(HealthMetric(
                    id: UUID(),
                    userId: userId,
                    metricType: type,
                    value: value,
                    date: dateFormatter.string(from: range.start),
                    source: .healthkit,
                    syncedAt: Date()
                ))
            }
        }
        return results
    }

    func fetchActivityRingSummaries(for range: DateRange) async throws -> [ActivityRingSummary] {
        let calendar = Self.activitySummaryCalendar()
        let components = Self.activitySummaryDateComponents(for: range, calendar: calendar)
        let predicate = HKQuery.predicate(
            forActivitySummariesBetweenStart: components.start,
            end: components.end
        )
        let descriptor = HKActivitySummaryQueryDescriptor(predicate: predicate)
        let summaries = try await descriptor.result(for: healthStore)
        let syncedAt = Date()

        return try summaries
            .map {
                try Self.activityRingSummary(
                    from: $0,
                    userId: userId,
                    calendar: calendar,
                    syncedAt: syncedAt
                )
            }
            .sorted { $0.date < $1.date }
    }

    func read(
        _ window: CompetitionActivityWindow
    ) async throws -> ActivityWindowRead {
        guard competitionDependencies.isHealthDataAvailable() else {
            throw CompetitionActivitySourceError.healthDataUnavailable
        }
        await ensureBackgroundDelivery()

        let summaries: [HKActivitySummary]
        do {
            summaries = try await competitionDependencies
                .readActivitySummaries(window)
        } catch {
            if error is CancellationError { throw CancellationError() }
            throw Self.sourceError(from: error)
        }

        let standMode: ActivityStandMode
        do {
            standMode = try competitionDependencies.resolveStandMode()
        } catch {
            // Public HealthKit does not expose read-denial state. If the
            // characteristic cannot be read, preserve a neutral Stand/Roll
            // identity while retaining the numeric ring reading.
            standMode = .unknown
        }

        var mappedByDay: [CompetitionDay: ActivitySnapshot] = [:]
        for summary in summaries {
            let mapped: (day: CompetitionDay, snapshot: ActivitySnapshot)
            do {
                mapped = try Self.competitionSnapshot(
                    from: summary,
                    calendar: window.calendar,
                    standMode: standMode
                )
            } catch {
                throw CompetitionActivitySourceError.invalidResponse
            }
            guard window.days.contains(mapped.day),
                  mappedByDay.updateValue(
                    mapped.snapshot,
                    forKey: mapped.day
                  ) == nil
            else {
                throw CompetitionActivitySourceError.invalidResponse
            }
        }

        return try ActivityWindowRead(
            window: window,
            days: window.days.map { day in
                mappedByDay[day].map {
                    .snapshot(day: day, snapshot: $0)
                } ?? .missing(day: day)
            }
        )
    }

    func synchronizeSummarySubscriptions(
        to desiredWindows: Set<CompetitionActivityWindow>
    ) async {
        await signalState.synchronizeSummarySubscriptions(
            to: desiredWindows,
            makeStream: competitionDependencies.summaryUpdates
        )
    }

    func signals() async -> AsyncStream<EnvironmentSignal> {
        let stream = await signalState.stream()
        await signalState.startObserverUpdatesIfNeeded(
            makeStream: competitionDependencies.observerUpdates
        )
        await ensureBackgroundDelivery()
        return stream
    }

    func completeSignal(_ id: String) async {
        await signalState.completeSignal(id)
    }

    static func competitionSnapshot(
        from summary: HKActivitySummary,
        calendar: CompetitionCalendar,
        standMode: ActivityStandMode,
        supportsPausedState: Bool? = nil
    ) throws -> (day: CompetitionDay, snapshot: ActivitySnapshot) {
        let gregorian = try competitionCalendar(calendar)
        let components = summary.dateComponents(for: gregorian)
        guard let era = components.era,
              let year = components.year,
              let month = components.month,
              let day = components.day
        else {
            throw CompetitionActivitySourceError.invalidResponse
        }
        let competitionDay = try CompetitionDay(
            era: era,
            year: year,
            month: month,
            day: day,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )

        let moveMode: ActivityMoveMode
        let move: ActivityRingReading
        if summary.activityMoveMode == .appleMoveTime {
            moveMode = .moveMinutes
            move = try ActivityRingReading(
                value: summary.appleMoveTime.doubleValue(for: .minute()),
                goal: summary.appleMoveTimeGoal.doubleValue(for: .minute())
            )
        } else {
            moveMode = .activeEnergyKilocalories
            move = try ActivityRingReading(
                value: summary.activeEnergyBurned.doubleValue(
                    for: .kilocalorie()
                ),
                goal: summary.activeEnergyBurnedGoal.doubleValue(
                    for: .kilocalorie()
                )
            )
        }

        let snapshot = ActivitySnapshot(
            moveMode: moveMode,
            standMode: standMode,
            move: move,
            exercise: try ActivityRingReading(
                value: summary.appleExerciseTime.doubleValue(for: .minute()),
                goal: summary.exerciseTimeGoal?.doubleValue(for: .minute())
            ),
            standOrRoll: try ActivityRingReading(
                value: summary.appleStandHours.doubleValue(for: .count()),
                goal: summary.standHoursGoal?.doubleValue(for: .count())
            ),
            pauseState: pauseState(
                from: summary,
                supportsPausedState: supportsPausedState
            )
        )
        return (competitionDay, snapshot)
    }

    static func activitySummaryDateComponents(
        for range: DateRange,
        calendar: Calendar
    ) -> (start: DateComponents, end: DateComponents) {
        let endDate = calendar.date(byAdding: .day, value: -1, to: range.end) ?? range.end
        return (
            activitySummaryDateComponents(from: range.start, calendar: calendar),
            activitySummaryDateComponents(from: endDate, calendar: calendar)
        )
    }

    static func activityRingSummary(
        from summary: HKActivitySummary,
        userId: UUID,
        calendar: Calendar,
        syncedAt: Date
    ) throws -> ActivityRingSummary {
        let dateComponents = summary.dateComponents(for: calendar)
        guard
            let year = dateComponents.year,
            let month = dateComponents.month,
            let day = dateComponents.day
        else {
            throw HealthKitProviderError.missingActivitySummaryDate
        }

        let move = moveValueAndGoal(from: summary)
        let exerciseGoal = summary.exerciseTimeGoal?.doubleValue(for: .minute()) ?? 0
        let standGoal = summary.standHoursGoal?.doubleValue(for: .count()) ?? 0

        return ActivityRingSummary(
            id: UUID(),
            userId: userId,
            date: String(format: "%04d-%02d-%02d", year, month, day),
            moveValue: move.value,
            moveGoal: move.goal,
            exerciseValue: summary.appleExerciseTime.doubleValue(for: .minute()),
            exerciseGoal: exerciseGoal,
            standValue: summary.appleStandHours.doubleValue(for: .count()),
            standGoal: standGoal,
            source: .healthkit,
            syncedAt: syncedAt
        )
    }

    // MARK: - HK Type Mapping

    static func hkQuantityType(for metricType: MetricType) -> HKQuantityType? {
        switch metricType {
        case .activeCalories: return HKQuantityType(.activeEnergyBurned)
        case .exerciseMinutes: return HKQuantityType(.appleExerciseTime)
        case .standHours: return HKQuantityType(.appleStandTime)
        case .steps: return HKQuantityType(.stepCount)
        case .distance: return HKQuantityType(.distanceWalkingRunning)
        case .sleepScore: return nil
        }
    }

    static func hkObjectType(for metricType: MetricType) -> HKObjectType? {
        if metricType == .sleepScore {
            return HKCategoryType(.sleepAnalysis)
        }
        return hkQuantityType(for: metricType)
    }

    // MARK: - Private

    private enum HealthKitProviderError: Error {
        case missingActivitySummaryDate
    }

    private static func activitySummaryCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private static func competitionCalendar(
        _ competitionCalendar: CompetitionCalendar
    ) throws -> Calendar {
        guard let timeZone = TimeZone(
            identifier: competitionCalendar.timeZoneIdentifier
        ) else {
            throw CompetitionActivitySourceError.invalidResponse
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func competitionReadTypes() -> Set<HKObjectType> {
        var types = Set<HKObjectType>(observerSampleTypes())
        types.insert(HKObjectType.activitySummaryType())
        types.insert(HKCharacteristicType(.wheelchairUse))
        return types
    }

    private static func observerSampleTypes() -> [HKSampleType] {
        [
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.appleExerciseTime),
            HKQuantityType(.appleStandTime),
            HKQuantityType(.appleMoveTime),
            HKCategoryType(.appleStandHour),
            HKWorkoutType.workoutType(),
        ]
    }

    private func ensureBackgroundDelivery() async {
        await signalState.ensureBackgroundDelivery(
            for: Self.observerSampleTypes(),
            enable: competitionDependencies.enableBackgroundDelivery
        )
    }

    private static func activitySummaryPredicate(
        for window: CompetitionActivityWindow
    ) throws -> NSPredicate {
        guard let first = window.days.first,
              let last = window.days.last
        else {
            throw CompetitionActivitySourceError.invalidResponse
        }
        let calendar = try competitionCalendar(window.calendar)
        let timeZone = calendar.timeZone
        let start = DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            era: first.era,
            year: first.year,
            month: first.month,
            day: first.day
        )
        let end = DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            era: last.era,
            year: last.year,
            month: last.month,
            day: last.day
        )
        return HKQuery.predicate(
            forActivitySummariesBetweenStart: start,
            end: end
        )
    }

    private static func pauseState(
        from summary: HKActivitySummary,
        supportsPausedState: Bool?
    ) -> ActivityPauseState {
        if supportsPausedState == false { return .unknown }
#if os(iOS)
        if #available(iOS 18.0, *) {
            return summary.isPaused ? .paused : .running
        }
#elseif os(macOS)
        if #available(macOS 15.0, *) {
            return summary.isPaused ? .paused : .running
        }
#endif
        return .unknown
    }

    private static func sourceError(
        from error: Error
    ) -> CompetitionActivitySourceError {
        if let sourceError = error as? CompetitionActivitySourceError {
            return sourceError
        }
        let nsError = error as NSError
        guard nsError.domain == HKErrorDomain else {
            return .unclassifiedQueryFailure
        }
        switch HKError.Code(rawValue: nsError.code) {
        case .errorHealthDataUnavailable:
            return .healthDataUnavailable
        case .errorDatabaseInaccessible:
            return .protectedDataUnavailable
        default:
            // Read authorization is private. Even an authorization-related
            // query error is not exposed as proof that the user denied reads.
            return .unclassifiedQueryFailure
        }
    }

    private static func liveCompetitionDependencies(
        healthStore: HKHealthStore
    ) -> HealthKitCompetitionDependencies {
        HealthKitCompetitionDependencies(
            isHealthDataAvailable: {
                HKHealthStore.isHealthDataAvailable()
            },
            requestAuthorization: { readTypes in
                try await healthStore.requestAuthorization(
                    toShare: [],
                    read: readTypes
                )
            },
            readActivitySummaries: { window in
                let descriptor = HKActivitySummaryQueryDescriptor(
                    predicate: try activitySummaryPredicate(for: window)
                )
                return try await descriptor.result(for: healthStore)
            },
            resolveStandMode: {
                let wheelchairUse = try healthStore.wheelchairUse()
                switch wheelchairUse.wheelchairUse {
                case .yes:
                    return .rollHours
                case .no:
                    return .standHours
                case .notSet:
                    return .unknown
                @unknown default:
                    return .unknown
                }
            },
            summaryUpdates: { window in
                AsyncStream { continuation in
                    let task = Task {
                        do {
                            let descriptor = HKActivitySummaryQueryDescriptor(
                                predicate: try activitySummaryPredicate(
                                    for: window
                                )
                            )
                            for try await summaries in descriptor.results(
                                for: healthStore
                            ) {
                                guard !Task.isCancelled else { break }
                                continuation.yield(summaries)
                            }
                        } catch {
                            // A foreground/protected-data signal will retry the
                            // authoritative one-shot read. The async-sequence
                            // payload is never persisted as source evidence.
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            observerUpdates: {
                AsyncStream { continuation in
                    let queries = observerSampleTypes().map { type in
                        HKObserverQuery(
                            sampleType: type,
                            predicate: nil
                        ) { _, completion, _ in
                            continuation.yield(
                                HealthKitObserverWakeup(
                                    completion: completion
                                )
                            )
                        }
                    }
                    for query in queries {
                        healthStore.execute(query)
                    }
                    continuation.onTermination = { _ in
                        for query in queries {
                            healthStore.stop(query)
                        }
                    }
                }
            },
            enableBackgroundDelivery: { type in
                try await healthStore.enableBackgroundDelivery(
                    for: type,
                    frequency: .immediate
                )
            }
        )
    }

    private static func activitySummaryDateComponents(
        from date: Date,
        calendar: Calendar
    ) -> DateComponents {
        var components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        components.calendar = calendar
        return components
    }

    private static func moveValueAndGoal(from summary: HKActivitySummary) -> (value: Double, goal: Double) {
        if summary.activityMoveMode == .appleMoveTime {
            return (
                summary.appleMoveTime.doubleValue(for: .minute()),
                summary.appleMoveTimeGoal.doubleValue(for: .minute())
            )
        }

        return (
            summary.activeEnergyBurned.doubleValue(for: .kilocalorie()),
            summary.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie())
        )
    }

    private func fetchSingleMetric(type: MetricType, range: DateRange) async throws -> Double? {
        if type == .sleepScore {
            return try await fetchSleepHours(range: range)
        }
        guard let quantityType = Self.hkQuantityType(for: type) else { return nil }

        let predicate = HKQuery.predicateForSamples(
            withStart: range.start, end: range.end, options: .strictStartDate
        )
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: HKSamplePredicate<HKQuantitySample>.quantitySample(
                type: quantityType, predicate: predicate
            ),
            options: .cumulativeSum
        )
        let result = try await descriptor.result(for: healthStore)
        return result?.sumQuantity()?.doubleValue(for: Self.unit(for: type))
    }

    private func fetchSleepHours(range: DateRange) async throws -> Double? {
        let sleepType = HKCategoryType(.sleepAnalysis)
        let predicate = HKQuery.predicateForSamples(
            withStart: range.start, end: range.end, options: .strictStartDate
        )
        let descriptor = HKSampleQueryDescriptor<HKCategorySample>(
            predicates: [.categorySample(type: sleepType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: healthStore)

        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        ]
        let totalSeconds = samples
            .filter { asleepValues.contains($0.value) }
            .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
        let hours = totalSeconds / 3600.0
        return hours > 0 ? hours : nil
    }

    private static func unit(for type: MetricType) -> HKUnit {
        switch type {
        case .activeCalories: return .kilocalorie()
        case .exerciseMinutes: return .minute()
        case .standHours: return .minute()
        case .steps: return .count()
        case .distance: return .meter()
        case .sleepScore: return .count()
        }
    }
}

private actor HealthKitProviderSignalState {
    private struct SummarySubscription {
        let generation: UUID
        let task: Task<Void, Never>
    }

    private enum BackgroundDeliveryState {
        case registering(id: UUID, task: Task<Bool, Never>)
        case enabled
    }

    private var continuation: AsyncStream<EnvironmentSignal>.Continuation?
    private var continuationToken: UUID?
    private let signalInstanceID = UUID().uuidString.lowercased()
    private var nextSignalOrdinal: UInt64 = 1
    private var completions: [String: () -> Void] = [:]
    private var pendingCompletionSignals: [EnvironmentSignal] = []
    private var observerTask: Task<Void, Never>?
    private var summarySubscriptions: [
        CompetitionActivityWindow: SummarySubscription
    ] = [:]
    private var desiredSummaryWindows = Set<CompetitionActivityWindow>()
    private var backgroundDeliveryStates: [HKSampleType: BackgroundDeliveryState] = [:]

    deinit {
        // Production state is process-rooted and does not deinitialize during
        // app/runtime replacement. Test state may deinitialize here; never call
        // HealthKit completions without the required persisted refresh outcome.
        observerTask?.cancel()
        for subscription in summarySubscriptions.values {
            subscription.task.cancel()
        }
    }

    func stream() -> AsyncStream<EnvironmentSignal> {
        let token = UUID()
        return AsyncStream { continuation in
            let replacedContinuation = self.continuation
            self.continuationToken = token
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.stop(token: token) }
            }
            for signal in pendingCompletionSignals {
                continuation.yield(signal)
            }
            replacedContinuation?.finish()
        }
    }

    func startObserverUpdatesIfNeeded(
        makeStream: @escaping @Sendable () -> AsyncStream<HealthKitObserverWakeup>
    ) {
        guard observerTask == nil else { return }
        let updates = makeStream()
        observerTask = Task { [weak self] in
            for await update in updates {
                guard !Task.isCancelled else { break }
                await self?.emit(
                    trigger: .observerWakeupBackground,
                    completion: update.completion
                )
            }
        }
    }

    func ensureBackgroundDelivery(
        for types: [HKSampleType],
        enable: @escaping @Sendable (HKSampleType) async throws -> Void
    ) async {
        for type in types {
            var initiatedRegistration = false
            registration: while true {
                switch backgroundDeliveryStates[type] {
                case .enabled:
                    break registration
                case let .registering(id, task):
                    let succeeded = await task.value
                    if case let .registering(currentID, _) =
                        backgroundDeliveryStates[type],
                       currentID == id {
                        backgroundDeliveryStates[type] = succeeded
                            ? .enabled
                            : nil
                    }
                    if succeeded || initiatedRegistration {
                        break registration
                    }
                case nil:
                    guard !initiatedRegistration else {
                        break registration
                    }
                    initiatedRegistration = true
                    let id = UUID()
                    let task = Task {
                        do {
                            try await enable(type)
                            return true
                        } catch {
                            return false
                        }
                    }
                    backgroundDeliveryStates[type] = .registering(
                        id: id,
                        task: task
                    )
                }
            }
        }
    }

    func synchronizeSummarySubscriptions(
        to desiredWindows: Set<CompetitionActivityWindow>,
        makeStream: @escaping @Sendable (CompetitionActivityWindow) -> AsyncStream<[HKActivitySummary]>
    ) {
        let removedWindows = Set(summarySubscriptions.keys)
            .subtracting(desiredWindows)
        for window in removedWindows {
            let removed = summarySubscriptions.removeValue(forKey: window)
            removed?.task.cancel()
        }
        self.desiredSummaryWindows = desiredWindows

        for window in desiredWindows where summarySubscriptions[window] == nil {
            startSummaryUpdates(window: window, makeStream: makeStream)
        }
    }

    private func startSummaryUpdates(
        window: CompetitionActivityWindow,
        makeStream: @escaping @Sendable (CompetitionActivityWindow) -> AsyncStream<[HKActivitySummary]>
    ) {
        let generation = UUID()
        let updates = makeStream(window)
        let task = Task { [weak self] in
            // Descriptor payloads are deliberately discarded. They are only a
            // wakeup signal for a subsequent authoritative one-shot reread.
            for await _ in updates {
                guard !Task.isCancelled else { break }
                await self?.emit(trigger: .summaryUpdate, completion: nil)
            }
            await self?.summaryUpdatesFinished(
                generation: generation,
                window: window
            )
        }
        summarySubscriptions[window] = SummarySubscription(
            generation: generation,
            task: task
        )
    }

    private func summaryUpdatesFinished(
        generation: UUID,
        window: CompetitionActivityWindow
    ) {
        guard summarySubscriptions[window]?.generation == generation
        else {
            return
        }
        summarySubscriptions[window] = nil
    }

    func completeSignal(_ id: String) {
        let completion = completions.removeValue(forKey: id)
        pendingCompletionSignals.removeAll { $0.id == id }
        completion?()
    }

    private func emit(
        trigger: ActivityRefreshTrigger,
        completion: (() -> Void)?
    ) {
        let id = "healthkit-signal-\(signalInstanceID)-\(nextSignalOrdinal)"
        nextSignalOrdinal += 1
        let signal = EnvironmentSignal(
            id: id,
            trigger: trigger,
            requiresCompletion: completion != nil
        )
        if let completion {
            completions[id] = completion
            pendingCompletionSignals.append(signal)
        }
        continuation?.yield(signal)
    }

    private func stop(token: UUID) {
        guard continuationToken == token else { return }
        continuationToken = nil
        continuation = nil
        // Observer callbacks remain owned by this app-lifetime provider until
        // their persisted refresh calls completeSignal. A later root consumer
        // receives any still-pending callback signals from stream().
    }
}
