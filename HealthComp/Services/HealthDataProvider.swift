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
