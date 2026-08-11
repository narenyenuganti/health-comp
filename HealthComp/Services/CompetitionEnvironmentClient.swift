import CompetitionCore
import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

struct EnvironmentInstant: Equatable, Sendable {
    let wallDate: Date
    let monotonic: MonotonicInstant
}

struct CompetitionEnvironmentContext: Equatable, Sendable {
    let instant: EnvironmentInstant
    let timeZoneIdentifier: String
}

struct CompetitionActivityWindow: Hashable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case invalidDayWindow
    }

    let calendar: CompetitionCalendar
    let days: [CompetitionDay]

    init(calendar: CompetitionCalendar, startDay: CompetitionDay) throws {
        let days = try calendar.sevenDayWindow(startingOn: startDay)
        guard days.count == 7 else { throw ValidationError.invalidDayWindow }
        self.calendar = calendar
        self.days = days
    }
}

enum ActivityDayReadResult: Equatable, Sendable {
    case snapshot(day: CompetitionDay, snapshot: ActivitySnapshot)
    case missing(day: CompetitionDay)

    var day: CompetitionDay {
        switch self {
        case let .snapshot(day, _), let .missing(day):
            return day
        }
    }
}

struct ActivityWindowRead: Equatable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case resultDaysDoNotMatchWindow
    }

    let days: [ActivityDayReadResult]

    init(
        window: CompetitionActivityWindow,
        days: [ActivityDayReadResult]
    ) throws {
        guard days.map(\.day) == window.days else {
            throw ValidationError.resultDaysDoNotMatchWindow
        }
        self.days = days
    }
}

struct EnvironmentSignal: Equatable, Sendable {
    let id: String
    let trigger: ActivityRefreshTrigger
    let requiresCompletion: Bool
}

enum CompetitionActivitySourceError: Error, Equatable, Sendable {
    case healthDataUnavailable
    case protectedDataUnavailable
    case invalidResponse
    case unclassifiedQueryFailure
}

protocol CompetitionActivitySource: Sendable {
    func requestReadAuthorization() async throws
    func read(_ window: CompetitionActivityWindow) async throws -> ActivityWindowRead
    func synchronizeSummarySubscriptions(
        to desiredWindows: Set<CompetitionActivityWindow>
    ) async
    func signals() async -> AsyncStream<EnvironmentSignal>
    func completeSignal(_ id: String) async
}

struct CompetitionEnvironmentClient: Sendable {
    enum Kind: Equatable, Sendable {
        case production
#if DEBUG
        case accelerated
#endif
    }

    let kind: Kind
    private let contextOperation: @Sendable () async -> CompetitionEnvironmentContext
    private let requestAuthorizationOperation: @Sendable () async throws -> Void
    private let readOperation: @Sendable (CompetitionActivityWindow) async throws -> ActivityWindowRead
    private let synchronizeSummarySubscriptionsOperation: @Sendable (
        Set<CompetitionActivityWindow>
    ) async -> Void
    private let signalsOperation: @Sendable () async -> AsyncStream<EnvironmentSignal>
    private let completeSignalOperation: @Sendable (String) async -> Void
    private let waitOperation: @Sendable (Date) async throws -> Void
#if DEBUG
    private let advanceFixtureOperation: @Sendable (Date) async throws -> Void
#endif

    private init(
        kind: Kind,
        context: @escaping @Sendable () async -> CompetitionEnvironmentContext,
        requestAuthorization: @escaping @Sendable () async throws -> Void,
        read: @escaping @Sendable (CompetitionActivityWindow) async throws -> ActivityWindowRead,
        synchronizeSummarySubscriptions: @escaping @Sendable (
            Set<CompetitionActivityWindow>
        ) async -> Void,
        signals: @escaping @Sendable () async -> AsyncStream<EnvironmentSignal>,
        completeSignal: @escaping @Sendable (String) async -> Void,
        wait: @escaping @Sendable (Date) async throws -> Void
    ) {
        self.kind = kind
        self.contextOperation = context
        self.requestAuthorizationOperation = requestAuthorization
        self.readOperation = read
        self.synchronizeSummarySubscriptionsOperation = synchronizeSummarySubscriptions
        self.signalsOperation = signals
        self.completeSignalOperation = completeSignal
        self.waitOperation = wait
#if DEBUG
        self.advanceFixtureOperation = { _ in
            throw CompetitionEnvironmentError.fixtureControlsUnavailable
        }
#endif
    }

#if DEBUG
    private init(
        kind: Kind,
        context: @escaping @Sendable () async -> CompetitionEnvironmentContext,
        requestAuthorization: @escaping @Sendable () async throws -> Void,
        read: @escaping @Sendable (CompetitionActivityWindow) async throws -> ActivityWindowRead,
        synchronizeSummarySubscriptions: @escaping @Sendable (
            Set<CompetitionActivityWindow>
        ) async -> Void,
        signals: @escaping @Sendable () async -> AsyncStream<EnvironmentSignal>,
        completeSignal: @escaping @Sendable (String) async -> Void,
        wait: @escaping @Sendable (Date) async throws -> Void,
        advanceFixture: @escaping @Sendable (Date) async throws -> Void
    ) {
        self.kind = kind
        self.contextOperation = context
        self.requestAuthorizationOperation = requestAuthorization
        self.readOperation = read
        self.synchronizeSummarySubscriptionsOperation = synchronizeSummarySubscriptions
        self.signalsOperation = signals
        self.completeSignalOperation = completeSignal
        self.waitOperation = wait
        self.advanceFixtureOperation = advanceFixture
    }

    static func accelerated(fixture: ActivityFixture) -> Self {
        let source = FixtureActivitySource(fixture: fixture)
        return accelerated(source: source)
    }

    static func accelerated(source: FixtureActivitySource) -> Self {
        return Self(
            kind: .accelerated,
            context: { await source.context() },
            requestAuthorization: {
                try await source.requestReadAuthorization()
            },
            read: { window in try await source.read(window) },
            synchronizeSummarySubscriptions: { windows in
                await source.synchronizeSummarySubscriptions(to: windows)
            },
            signals: { await source.signals() },
            completeSignal: { id in await source.completeSignal(id) },
            wait: { date in try await source.wait(until: date) },
            advanceFixture: { date in try await source.advance(to: date) }
        )
    }

    /// A DEBUG-only production-shaped adapter used to prove that calendar-time
    /// evaluation and zero-sleep acceleration translate the same logical
    /// observations. The injected fixture is kept private to DEBUG builds, so
    /// neither fixture control nor a synthetic clock can enter Release.
    static func productionCalendarTestAdapter(
        source: FixtureActivitySource
    ) -> Self {
        Self(
            kind: .production,
            context: { await source.context() },
            requestAuthorization: {
                try await source.requestReadAuthorization()
            },
            read: { window in try await source.read(window) },
            synchronizeSummarySubscriptions: { windows in
                await source.synchronizeSummarySubscriptions(to: windows)
            },
            signals: { await source.signals() },
            completeSignal: { id in await source.completeSignal(id) },
            wait: { date in try await source.wait(until: date) },
            advanceFixture: { _ in
                throw CompetitionEnvironmentError.fixtureControlsUnavailable
            }
        )
    }
#endif

#if os(iOS)
    static func production(
        healthStore: HKHealthStore = HKHealthStore()
    ) -> Self {
        let source = HealthKitProvider(
            userId: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            healthStore: healthStore
        )
        let epochID = Self.productionEpochID(
            wallDate: Date(),
            systemUptime: ProcessInfo.processInfo.systemUptime
        )
        return Self(
            kind: .production,
            context: {
                let wallDate = Date()
                return CompetitionEnvironmentContext(
                    instant: EnvironmentInstant(
                        wallDate: wallDate,
                        monotonic: MonotonicInstant(
                            epochID: epochID,
                            nanoseconds: DispatchTime.now().uptimeNanoseconds
                        )
                    ),
                    timeZoneIdentifier: TimeZone.current.identifier
                )
            },
            requestAuthorization: {
                try await source.requestReadAuthorization()
            },
            read: { window in try await source.read(window) },
            synchronizeSummarySubscriptions: { windows in
                await source.synchronizeSummarySubscriptions(to: windows)
            },
            signals: { await source.signals() },
            completeSignal: { id in await source.completeSignal(id) },
            wait: { date in
                let delay = date.timeIntervalSinceNow
                guard delay > 0 else { return }
                try await Task.sleep(
                    nanoseconds: Self.nanosecondsForDelay(delay)
                )
            }
        )
    }
#endif

    static func productionEpochID(
        wallDate: Date,
        systemUptime: TimeInterval
    ) -> String {
        let estimatedBootDate = wallDate.timeIntervalSinceReferenceDate
            - systemUptime
        let bootSecond = Int64(estimatedBootDate.rounded())
        return "system-boot-\(bootSecond)"
    }

    static func nanosecondsForDelay(_ seconds: TimeInterval) -> UInt64 {
        guard seconds > 0 else { return 0 }
        let nanoseconds = seconds * 1_000_000_000
        guard nanoseconds.isFinite else { return UInt64.max }
        let rounded = nanoseconds.rounded()
        // Double(UInt64.max) rounds upward to 2^64. Branch before conversion:
        // converting that rounded sentinel traps instead of saturating.
        guard rounded < Double(UInt64.max) else { return UInt64.max }
        return UInt64(rounded)
    }

    func context() async -> CompetitionEnvironmentContext {
        await contextOperation()
    }

    func instant() async -> EnvironmentInstant {
        await contextOperation().instant
    }

    func requestHealthAuthorization() async throws {
        try await requestAuthorizationOperation()
    }

    func read(
        _ window: CompetitionActivityWindow
    ) async throws -> ActivityWindowRead {
        try await readOperation(window)
    }

    func synchronizeSummarySubscriptions(
        to desiredWindows: Set<CompetitionActivityWindow>
    ) async {
        await synchronizeSummarySubscriptionsOperation(desiredWindows)
    }

    func signals() async -> AsyncStream<EnvironmentSignal> {
        await signalsOperation()
    }

    func completeSignal(_ id: String) async {
        await completeSignalOperation(id)
    }

    func wait(until date: Date) async throws {
        try await waitOperation(date)
    }

#if DEBUG
    func advanceFixture(to date: Date) async throws {
        try await advanceFixtureOperation(date)
    }
#endif
}

#if DEBUG
enum CompetitionEnvironmentError: Error, Equatable, Sendable {
    case fixtureControlsUnavailable
}
#endif
