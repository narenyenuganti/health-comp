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

struct EnvironmentSignalOwnershipScope: Hashable, Sendable {
    private let id: UUID

    init() {
        self.id = UUID()
    }
}

struct EnvironmentSignalOwnershipLease: Hashable, Sendable {
    let profileID: UUID
    let scope: EnvironmentSignalOwnershipScope
    let ownerID: UUID

    init(
        profileID: UUID,
        scope: EnvironmentSignalOwnershipScope,
        ownerID: UUID = UUID()
    ) {
        self.profileID = profileID
        self.scope = scope
        self.ownerID = ownerID
    }
}

struct EnvironmentSignalOwnershipActivation: Hashable, Sendable {
    let lease: EnvironmentSignalOwnershipLease
    let reservationID: UUID?
    let expectedOwnerID: UUID?

    var scope: EnvironmentSignalOwnershipScope { lease.scope }

    init(
        lease: EnvironmentSignalOwnershipLease,
        reservationID: UUID?,
        expectedOwnerID: UUID? = nil
    ) {
        self.lease = lease
        self.reservationID = reservationID
        self.expectedOwnerID = expectedOwnerID
    }
}

struct EnvironmentSignal: Equatable, Sendable {
    let id: String
    let trigger: ActivityRefreshTrigger
    let requiresCompletion: Bool
    let ownershipScope: EnvironmentSignalOwnershipScope?

    init(
        id: String,
        trigger: ActivityRefreshTrigger,
        requiresCompletion: Bool,
        ownershipScope: EnvironmentSignalOwnershipScope? = nil
    ) {
        self.id = id
        self.trigger = trigger
        self.requiresCompletion = requiresCompletion
        self.ownershipScope = ownershipScope
    }
}

enum CompetitionActivitySourceError: Error, Equatable, Sendable {
    case healthDataUnavailable
    case protectedDataUnavailable
    case invalidResponse
    case unclassifiedQueryFailure
}

enum EnvironmentSignalOwnershipError: Error, Equatable, Sendable {
    case activeOwnerNotRetired
    case inactiveOwner
    case pendingCallbacks
}

protocol CompetitionActivitySource: Sendable {
    func requestReadAuthorization() async throws
    func read(_ window: CompetitionActivityWindow) async throws -> ActivityWindowRead
    func activateSignalOwnership(
        for profileID: UUID
    ) async throws -> EnvironmentSignalOwnershipActivation
    func commitSignalOwnershipActivation(
        _ activation: EnvironmentSignalOwnershipActivation
    ) async throws
    func rollbackSignalOwnershipActivation(
        _ activation: EnvironmentSignalOwnershipActivation
    ) async
    func quiesceSignalOwnership(
        _ lease: EnvironmentSignalOwnershipLease
    ) async throws -> [EnvironmentSignal]
    func retireSignalOwnership(
        _ lease: EnvironmentSignalOwnershipLease
    ) async throws
    func synchronizeSummarySubscriptions(
        to desiredWindows: Set<CompetitionActivityWindow>
    ) async
    func signals() async -> AsyncStream<EnvironmentSignal>
    func completeSignal(_ id: String) async -> Bool
}

struct CompetitionEnvironmentClient: Sendable {
    enum Kind: Equatable, Sendable {
        case production
#if DEBUG
        case accelerated
#endif
    }

    let kind: Kind
    private let source: any CompetitionActivitySource
    private let contextOperation: @Sendable () async -> CompetitionEnvironmentContext
    private let waitOperation: @Sendable (Date) async throws -> Void
#if DEBUG
    private var advanceFixtureOperation: (@Sendable (Date) async throws -> Void)?
#endif

    private init(
        kind: Kind,
        source: any CompetitionActivitySource,
        context: @escaping @Sendable () async -> CompetitionEnvironmentContext,
        wait: @escaping @Sendable (Date) async throws -> Void
    ) {
        self.kind = kind
        self.source = source
        self.contextOperation = context
        self.waitOperation = wait
    }

#if DEBUG
    static func accelerated(fixture: ActivityFixture) -> Self {
        let source = FixtureActivitySource(fixture: fixture)
        return accelerated(source: source)
    }

    static func accelerated(source: FixtureActivitySource) -> Self {
        var client = Self(
            kind: .accelerated,
            source: source,
            context: { await source.context() },
            wait: { date in try await source.wait(until: date) }
        )
        client.advanceFixtureOperation = { date in try await source.advance(to: date) }
        return client
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
            source: source,
            context: { await source.context() },
            wait: { date in try await source.wait(until: date) }
        )
    }
#endif

#if os(iOS)
    static func production(
        healthStore: HKHealthStore = HKHealthStore()
    ) -> Self {
        let source = HealthKitProvider(healthStore: healthStore)
        let epochID = Self.productionEpochID(
            wallDate: Date(),
            systemUptime: ProcessInfo.processInfo.systemUptime
        )
        return Self(
            kind: .production,
            source: source,
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
        try await source.requestReadAuthorization()
    }

    func read(
        _ window: CompetitionActivityWindow
    ) async throws -> ActivityWindowRead {
        try await source.read(window)
    }

    func activateSignalOwnership(
        for profileID: UUID
    ) async throws -> EnvironmentSignalOwnershipActivation {
        try await source.activateSignalOwnership(for: profileID)
    }

    func commitSignalOwnershipActivation(
        _ activation: EnvironmentSignalOwnershipActivation
    ) async throws {
        try await source.commitSignalOwnershipActivation(activation)
    }

    func rollbackSignalOwnershipActivation(
        _ activation: EnvironmentSignalOwnershipActivation
    ) async {
        await source.rollbackSignalOwnershipActivation(activation)
    }

    func quiesceSignalOwnership(
        _ lease: EnvironmentSignalOwnershipLease
    ) async throws -> [EnvironmentSignal] {
        try await source.quiesceSignalOwnership(lease)
    }

    func retireSignalOwnership(
        _ lease: EnvironmentSignalOwnershipLease
    ) async throws {
        try await source.retireSignalOwnership(lease)
    }

    func synchronizeSummarySubscriptions(
        to desiredWindows: Set<CompetitionActivityWindow>
    ) async {
        await source.synchronizeSummarySubscriptions(to: desiredWindows)
    }

    func signals() async -> AsyncStream<EnvironmentSignal> {
        await source.signals()
    }

    func completeSignal(_ id: String) async -> Bool {
        await source.completeSignal(id)
    }

    func wait(until date: Date) async throws {
        try await waitOperation(date)
    }

#if DEBUG
    func advanceFixture(to date: Date) async throws {
        guard let advanceFixtureOperation else {
            throw CompetitionEnvironmentError.fixtureControlsUnavailable
        }
        try await advanceFixtureOperation(date)
    }
#endif
}

#if DEBUG
enum CompetitionEnvironmentError: Error, Equatable, Sendable {
    case fixtureControlsUnavailable
}
#endif

#if os(iOS)
extension HealthKitProvider: CompetitionActivitySource {}
#endif
