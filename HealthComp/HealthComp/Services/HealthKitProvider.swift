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
