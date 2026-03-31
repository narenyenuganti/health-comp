# Health Data Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the health data abstraction layer, HealthKit integration, local caching, and Supabase sync — so the app can read real fitness data from the device and upload it for server-side scoring.

**Architecture:** Protocol-based `HealthDataProvider` with `HealthKitProvider` as the first implementation. Metrics are cached locally in SwiftData for offline support, then synced to Supabase `health_metrics` table. A `HealthSyncClient` TCA dependency orchestrates the flow.

**Tech Stack:** Swift, HealthKit, SwiftData, TCA, Supabase Edge Functions

**Spec:** `docs/superpowers/specs/2026-03-31-health-comp-design.md` — Section 1

---

## File Structure

```
HealthComp/HealthComp/
├── Models/
│   ├── HealthMetric.swift              # Shared metric model (MetricType, HealthMetric, DataSource)
│   └── CachedMetric.swift              # SwiftData model for local cache
├── Services/
│   ├── HealthDataProvider.swift         # Protocol all providers conform to
│   ├── HealthKitProvider.swift          # HealthKit implementation
│   └── HealthSyncClient.swift           # TCA dependency: orchestrates fetch → cache → sync
HealthComp/HealthCompTests/
│   ├── HealthMetricTests.swift          # Model tests
│   ├── HealthKitProviderTests.swift     # Provider logic tests (mocked HKHealthStore)
│   └── HealthSyncClientTests.swift      # Sync flow tests
HealthComp/Supabase/
│   └── migrations/
│       └── 002_create_health_metrics.sql  # health_metrics table
```

---

### Task 1: Health Metrics Table Migration

**Files:**
- Create: `HealthComp/Supabase/migrations/002_create_health_metrics.sql`

- [ ] **Step 1: Write the health_metrics migration**

Create `HealthComp/Supabase/migrations/002_create_health_metrics.sql`:

```sql
-- Health metrics synced from user devices
CREATE TABLE public.health_metrics (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    metric_type text NOT NULL,
    value numeric NOT NULL,
    date date NOT NULL,
    source text NOT NULL DEFAULT 'healthkit',
    synced_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(user_id, metric_type, date, source)
);

-- Indexes for common queries
CREATE INDEX idx_health_metrics_user_date ON public.health_metrics (user_id, date);
CREATE INDEX idx_health_metrics_user_type_date ON public.health_metrics (user_id, metric_type, date);

-- Row Level Security
ALTER TABLE public.health_metrics ENABLE ROW LEVEL SECURITY;

-- Users can only read their own metrics
CREATE POLICY "Users can read own metrics"
    ON public.health_metrics FOR SELECT
    TO authenticated
    USING (user_id = auth.uid());

-- Users can insert their own metrics
CREATE POLICY "Users can insert own metrics"
    ON public.health_metrics FOR INSERT
    TO authenticated
    WITH CHECK (user_id = auth.uid());

-- Users can update their own metrics (upsert on sync)
CREATE POLICY "Users can update own metrics"
    ON public.health_metrics FOR UPDATE
    TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());
```

- [ ] **Step 2: Commit**

```bash
git add HealthComp/Supabase/migrations/002_create_health_metrics.sql
git commit -m "feat: add health_metrics table migration"
```

---

### Task 2: HealthMetric Model (TDD)

**Files:**
- Create: `HealthComp/HealthCompTests/HealthMetricTests.swift`
- Create: `HealthComp/HealthComp/Models/HealthMetric.swift`

- [ ] **Step 1: Write tests**

Create `HealthComp/HealthCompTests/HealthMetricTests.swift`:

```swift
import XCTest
@testable import HealthComp

final class HealthMetricTests: XCTestCase {

    func testMetricTypeRawValues() {
        XCTAssertEqual(MetricType.activeCalories.rawValue, "active_calories")
        XCTAssertEqual(MetricType.exerciseMinutes.rawValue, "exercise_minutes")
        XCTAssertEqual(MetricType.standHours.rawValue, "stand_hours")
        XCTAssertEqual(MetricType.steps.rawValue, "steps")
        XCTAssertEqual(MetricType.sleepScore.rawValue, "sleep_score")
        XCTAssertEqual(MetricType.distance.rawValue, "distance")
    }

    func testDataSourceRawValues() {
        XCTAssertEqual(DataSource.healthkit.rawValue, "healthkit")
        XCTAssertEqual(DataSource.fitbit.rawValue, "fitbit")
        XCTAssertEqual(DataSource.garmin.rawValue, "garmin")
        XCTAssertEqual(DataSource.manual.rawValue, "manual")
    }

    func testHealthMetricDecodesFromSupabase() throws {
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "user_id": "660e8400-e29b-41d4-a716-446655440000",
            "metric_type": "active_calories",
            "value": 523.5,
            "date": "2026-03-31",
            "source": "healthkit",
            "synced_at": "2026-03-31T12:00:00Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metric = try decoder.decode(HealthMetric.self, from: json)

        XCTAssertEqual(metric.metricType, .activeCalories)
        XCTAssertEqual(metric.value, 523.5)
        XCTAssertEqual(metric.source, .healthkit)
    }

    func testHealthMetricEncodesToSupabase() throws {
        let metric = HealthMetric(
            id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
            userId: UUID(uuidString: "660e8400-e29b-41d4-a716-446655440000")!,
            metricType: .steps,
            value: 8500,
            date: "2026-03-31",
            source: .healthkit,
            syncedAt: Date(timeIntervalSince1970: 0)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metric)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["metric_type"] as? String, "steps")
        XCTAssertEqual(dict["value"] as? Double, 8500)
        XCTAssertEqual(dict["source"] as? String, "healthkit")
        XCTAssertEqual(dict["date"] as? String, "2026-03-31")
    }

    func testAllMetricTypesExist() {
        let allTypes: [MetricType] = [
            .activeCalories, .exerciseMinutes, .standHours,
            .steps, .sleepScore, .distance
        ]
        XCTAssertEqual(allTypes.count, 6)
    }
}
```

- [ ] **Step 2: Implement HealthMetric model**

Create `HealthComp/HealthComp/Models/HealthMetric.swift`:

```swift
import Foundation

enum MetricType: String, Codable, Equatable, Sendable, CaseIterable {
    case activeCalories = "active_calories"
    case exerciseMinutes = "exercise_minutes"
    case standHours = "stand_hours"
    case steps
    case sleepScore = "sleep_score"
    case distance
}

enum DataSource: String, Codable, Equatable, Sendable {
    case healthkit
    case fitbit
    case garmin
    case manual
}

struct HealthMetric: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let userId: UUID
    let metricType: MetricType
    let value: Double
    let date: String  // "YYYY-MM-DD" format for Supabase date column
    let source: DataSource
    let syncedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case metricType = "metric_type"
        case value
        case date
        case source
        case syncedAt = "synced_at"
    }
}
```

- [ ] **Step 3: Regenerate project, run tests, commit**

```bash
cd HealthComp && xcodegen generate
xcodebuild test -project HealthComp.xcodeproj -scheme HealthCompTests ...
git add ... && git commit -m "feat: add HealthMetric model with MetricType and DataSource"
```

---

### Task 3: HealthDataProvider Protocol

**Files:**
- Create: `HealthComp/HealthComp/Services/HealthDataProvider.swift`

- [ ] **Step 1: Create the provider protocol**

Create `HealthComp/HealthComp/Services/HealthDataProvider.swift`:

```swift
import Foundation

enum AuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

struct DateRange: Equatable, Sendable {
    let start: Date
    let end: Date

    static func today() -> DateRange {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return DateRange(start: start, end: end)
    }

    static func lastNDays(_ n: Int) -> DateRange {
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        let start = calendar.date(byAdding: .day, value: -n, to: calendar.startOfDay(for: Date()))!
        return DateRange(start: start, end: end)
    }
}

protocol HealthDataProvider: Sendable {
    func requestAuthorization() async throws
    func authorizationStatus() -> AuthorizationStatus
    func fetchMetrics(for range: DateRange, types: [MetricType]) async throws -> [HealthMetric]
    func availableMetricTypes() -> [MetricType]
}
```

- [ ] **Step 2: Build, commit**

```bash
git add ... && git commit -m "feat: add HealthDataProvider protocol"
```

---

### Task 4: HealthKitProvider Implementation (TDD)

**Files:**
- Create: `HealthComp/HealthCompTests/HealthKitProviderTests.swift`
- Create: `HealthComp/HealthComp/Services/HealthKitProvider.swift`

- [ ] **Step 1: Write tests for HealthKit metric mapping**

Create `HealthComp/HealthCompTests/HealthKitProviderTests.swift`:

```swift
import XCTest
@testable import HealthComp

final class HealthKitProviderTests: XCTestCase {

    func testAvailableMetricTypes() {
        let provider = HealthKitProvider(userId: UUID())
        let types = provider.availableMetricTypes()
        XCTAssertTrue(types.contains(.activeCalories))
        XCTAssertTrue(types.contains(.exerciseMinutes))
        XCTAssertTrue(types.contains(.standHours))
        XCTAssertTrue(types.contains(.steps))
        XCTAssertTrue(types.contains(.sleepScore))
        XCTAssertTrue(types.contains(.distance))
    }

    func testMetricTypeToHKQuantityTypeMapping() {
        // Verify all metric types have a corresponding HK type
        let provider = HealthKitProvider(userId: UUID())
        let types = provider.availableMetricTypes()
        for type in types {
            XCTAssertNotNil(
                HealthKitProvider.hkQuantityType(for: type),
                "Missing HK mapping for \(type)"
            )
        }
    }

    func testDateRangeToday() {
        let range = DateRange.today()
        let calendar = Calendar.current
        XCTAssertEqual(
            calendar.startOfDay(for: range.start),
            calendar.startOfDay(for: Date())
        )
        XCTAssertTrue(range.end > range.start)
    }

    func testDateRangeLastNDays() {
        let range = DateRange.lastNDays(7)
        let calendar = Calendar.current
        let daysBetween = calendar.dateComponents([.day], from: range.start, to: range.end).day!
        XCTAssertEqual(daysBetween, 8) // 7 days + today
    }
}
```

- [ ] **Step 2: Implement HealthKitProvider**

Create `HealthComp/HealthComp/Services/HealthKitProvider.swift`:

```swift
import Foundation
import HealthKit

final class HealthKitProvider: HealthDataProvider, @unchecked Sendable {
    private let healthStore: HKHealthStore
    private let userId: UUID

    init(userId: UUID, healthStore: HKHealthStore = HKHealthStore()) {
        self.userId = userId
        self.healthStore = healthStore
    }

    func requestAuthorization() async throws {
        let readTypes: Set<HKObjectType> = Set(
            availableMetricTypes().compactMap { Self.hkObjectType(for: $0) }
        )

        try await healthStore.requestAuthorization(toShare: [], read: readTypes)
    }

    func authorizationStatus() -> AuthorizationStatus {
        guard HKHealthStore.isHealthDataAvailable() else { return .denied }
        // Check status for a representative type
        let status = healthStore.authorizationStatus(for: HKQuantityType(.activeEnergyBurned))
        switch status {
        case .notDetermined: return .notDetermined
        case .sharingAuthorized: return .authorized
        case .sharingDenied: return .denied
        @unknown default: return .notDetermined
        }
    }

    func availableMetricTypes() -> [MetricType] {
        [.activeCalories, .exerciseMinutes, .standHours, .steps, .sleepScore, .distance]
    }

    func fetchMetrics(for range: DateRange, types: [MetricType]) async throws -> [HealthMetric] {
        var results: [HealthMetric] = []

        for type in types {
            let value = try await fetchSingleMetric(type: type, range: range)
            if let value {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"

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

    // MARK: - HK Type Mapping

    static func hkQuantityType(for metricType: MetricType) -> HKQuantityType? {
        switch metricType {
        case .activeCalories: return HKQuantityType(.activeEnergyBurned)
        case .exerciseMinutes: return HKQuantityType(.appleExerciseTime)
        case .standHours: return HKQuantityType(.appleStandTime)
        case .steps: return HKQuantityType(.stepCount)
        case .distance: return HKQuantityType(.distanceWalkingRunning)
        case .sleepScore: return nil  // Sleep uses HKCategoryType, handled separately
        }
    }

    static func hkObjectType(for metricType: MetricType) -> HKObjectType? {
        if metricType == .sleepScore {
            return HKCategoryType(.sleepAnalysis)
        }
        return hkQuantityType(for: metricType)
    }

    // MARK: - Private

    private func fetchSingleMetric(type: MetricType, range: DateRange) async throws -> Double? {
        if type == .sleepScore {
            return try await fetchSleepHours(range: range)
        }

        guard let quantityType = Self.hkQuantityType(for: type) else { return nil }

        let predicate = HKQuery.predicateForSamples(
            withStart: range.start,
            end: range.end,
            options: .strictStartDate
        )

        let descriptor = HKStatisticsQueryDescriptor(
            predicate: HKSamplePredicate<HKQuantitySample>.quantitySample(
                type: quantityType,
                predicate: predicate
            ),
            options: .cumulativeSum
        )

        let result = try await descriptor.result(for: healthStore)

        let unit = Self.unit(for: type)
        return result?.sumQuantity()?.doubleValue(for: unit)
    }

    private func fetchSleepHours(range: DateRange) async throws -> Double? {
        let sleepType = HKCategoryType(.sleepAnalysis)
        let predicate = HKQuery.predicateForSamples(
            withStart: range.start,
            end: range.end,
            options: .strictStartDate
        )

        let descriptor = HKSampleQueryDescriptor<HKCategorySample>(
            predicates: [.categorySample(type: sleepType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )

        let samples = try await descriptor.result(for: healthStore)

        // Sum asleep duration (exclude inBed)
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
        case .standHours: return .minute()  // appleStandTime is in minutes
        case .steps: return .count()
        case .distance: return .meter()
        case .sleepScore: return .count()  // not used for sleep
        }
    }
}
```

- [ ] **Step 3: Regenerate project, run tests, commit**

```bash
git add ... && git commit -m "feat: add HealthKitProvider with metric fetching"
```

---

### Task 5: HealthSyncClient — TCA Dependency (TDD)

**Files:**
- Create: `HealthComp/HealthCompTests/HealthSyncClientTests.swift`
- Create: `HealthComp/HealthComp/Services/HealthSyncClient.swift`

- [ ] **Step 1: Write tests**

Create `HealthComp/HealthCompTests/HealthSyncClientTests.swift`:

```swift
import ComposableArchitecture
import XCTest
@testable import HealthComp

final class HealthSyncClientTests: XCTestCase {

    @MainActor
    func testSyncTodayReturnsMetrics() async throws {
        var fetchedTypes: [MetricType]?

        let client = HealthSyncClient(
            requestAuthorization: {},
            authorizationStatus: { .authorized },
            fetchToday: { types in
                fetchedTypes = types
                return [
                    HealthMetric(
                        id: UUID(),
                        userId: UUID(),
                        metricType: .steps,
                        value: 8500,
                        date: "2026-03-31",
                        source: .healthkit,
                        syncedAt: Date()
                    )
                ]
            },
            fetchRange: { _, _ in [] },
            uploadMetrics: { _ in }
        )

        let metrics = try await client.fetchToday([.steps])
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics.first?.metricType, .steps)
        XCTAssertEqual(fetchedTypes, [.steps])
    }

    @MainActor
    func testUploadMetricsCalled() async throws {
        var uploadedMetrics: [HealthMetric]?

        let client = HealthSyncClient(
            requestAuthorization: {},
            authorizationStatus: { .authorized },
            fetchToday: { _ in [] },
            fetchRange: { _, _ in [] },
            uploadMetrics: { metrics in
                uploadedMetrics = metrics
            }
        )

        let metric = HealthMetric(
            id: UUID(),
            userId: UUID(),
            metricType: .activeCalories,
            value: 450,
            date: "2026-03-31",
            source: .healthkit,
            syncedAt: Date()
        )

        try await client.uploadMetrics([metric])
        XCTAssertEqual(uploadedMetrics?.count, 1)
        XCTAssertEqual(uploadedMetrics?.first?.metricType, .activeCalories)
    }
}
```

- [ ] **Step 2: Implement HealthSyncClient**

Create `HealthComp/HealthComp/Services/HealthSyncClient.swift`:

```swift
import Dependencies
import DependenciesMacros
import Foundation
import Supabase

@DependencyClient
struct HealthSyncClient: Sendable {
    var requestAuthorization: @Sendable () async throws -> Void
    var authorizationStatus: @Sendable () -> AuthorizationStatus = { .notDetermined }
    var fetchToday: @Sendable (_ types: [MetricType]) async throws -> [HealthMetric]
    var fetchRange: @Sendable (_ range: DateRange, _ types: [MetricType]) async throws -> [HealthMetric]
    var uploadMetrics: @Sendable (_ metrics: [HealthMetric]) async throws -> Void
}

extension HealthSyncClient: TestDependencyKey {
    static let testValue = HealthSyncClient()
}

extension DependencyValues {
    var healthSyncClient: HealthSyncClient {
        get { self[HealthSyncClient.self] }
        set { self[HealthSyncClient.self] = newValue }
    }
}

// MARK: - Live Implementation

extension HealthSyncClient: DependencyKey {
    static let liveValue: HealthSyncClient = {
        let supabase = SupabaseService.shared

        // Provider will be created with real userId after auth
        // For now, the live value captures supabase for upload
        return HealthSyncClient(
            requestAuthorization: {
                // Actual provider created per-user at runtime
                // This will be wired when user is authenticated
            },
            authorizationStatus: {
                guard HealthKitAvailability.isAvailable else { return .denied }
                return .notDetermined
            },
            fetchToday: { types in
                // Will be populated by the feature that knows the userId
                return []
            },
            fetchRange: { range, types in
                return []
            },
            uploadMetrics: { metrics in
                guard !metrics.isEmpty else { return }

                // Upsert metrics to Supabase
                try await supabase
                    .from("health_metrics")
                    .upsert(metrics, onConflict: "user_id,metric_type,date,source")
                    .execute()
            }
        )
    }()
}

enum HealthKitAvailability {
    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return HKHealthStore.isHealthDataAvailable()
        #endif
    }
}
```

Note: The live `fetchToday`/`fetchRange` implementations are intentionally minimal stubs. The actual HealthKitProvider will be created and injected by the feature that knows the authenticated user's ID. The upload path is fully functional.

- [ ] **Step 3: Regenerate project, run tests, commit**

```bash
git add ... && git commit -m "feat: add HealthSyncClient with Supabase upload"
```

---

### Task 6: User Goals Table Migration

**Files:**
- Create: `HealthComp/Supabase/migrations/003_create_user_goals.sql`

- [ ] **Step 1: Write the user_goals migration**

Create `HealthComp/Supabase/migrations/003_create_user_goals.sql`:

```sql
-- User personal goals (lock when competitions start)
CREATE TABLE public.user_goals (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    metric_type text NOT NULL,
    goal_value numeric NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(user_id, metric_type)
);

CREATE INDEX idx_user_goals_user ON public.user_goals (user_id);

ALTER TABLE public.user_goals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own goals"
    ON public.user_goals FOR SELECT
    TO authenticated
    USING (user_id = auth.uid());

CREATE POLICY "Users can insert own goals"
    ON public.user_goals FOR INSERT
    TO authenticated
    WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can update own goals"
    ON public.user_goals FOR UPDATE
    TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());
```

- [ ] **Step 2: Commit**

```bash
git add ... && git commit -m "feat: add user_goals table migration"
```

---

## Summary

After completing all 6 tasks:

- **health_metrics table** in Supabase with RLS
- **user_goals table** in Supabase with RLS
- **HealthMetric model** with MetricType, DataSource enums
- **HealthDataProvider protocol** — abstraction for any health data source
- **HealthKitProvider** — reads calories, exercise, stand, steps, sleep, distance from HealthKit
- **HealthSyncClient** — TCA dependency for fetching + uploading metrics

**Next plan:** Plan 3: Social & Friends
