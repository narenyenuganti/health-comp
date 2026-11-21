import Foundation

public enum SleepScore {
    public static let goalMinutes = 480.0
    public static let maximumBasisPoints = 10_000
    public static let maximumDailyPoints = 700.0
    public static let historyNights = 13

    public static func durationPoints(minutesAsleep: Double) -> Double {
        guard minutesAsleep.isFinite, minutesAsleep > 0 else { return 0 }
        return 50 * min(1, minutesAsleep / goalMinutes)
    }

    public static func bedtimePoints(onsetMinutes: Double, usualOnsetMinutes: Double?) -> Double {
        guard let usual = usualOnsetMinutes else { return 30 }
        let off = abs(onsetMinutes - usual)
        return 30 * min(1, max(0, (120 - off) / 90))
    }

    public static func interruptionPoints(awakeMinutes: Double) -> Double {
        20 * min(1, max(0, (70 - awakeMinutes) / 60))
    }

    public static func usualOnset(_ onsets: [Double]) -> Double? {
        guard onsets.count >= 3 else { return nil }
        let sorted = onsets.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    public static func night(
        _ samples: [SleepSample],
        in window: DateInterval,
        preference: SleepSourcePreference,
        usualOnsetMinutes: Double?
    ) -> SleepNight {
        let (intervals, source) = chosen(samples, in: window, preference: preference)
        let minutes = mergedDuration(intervals) / 60
        guard minutes > 0, let main = mainSession(intervals) else { return .none }
        let onset = main.start.timeIntervalSince(window.start) / 60
        let awake = max(0, main.duration / 60 - mergedDuration(intervals.filter { main.intersects($0) }) / 60)
        let duration = durationPoints(minutesAsleep: minutes)
        let bedtime = bedtimePoints(onsetMinutes: onset, usualOnsetMinutes: usualOnsetMinutes)
        let interruptions = interruptionPoints(awakeMinutes: awake)
        return SleepNight(
            minutesAsleep: minutes,
            awakeMinutes: awake,
            onsetMinutes: onset,
            source: source,
            durationPoints: duration,
            bedtimePoints: bedtime,
            interruptionPoints: interruptions,
            basisPoints: min(maximumBasisPoints, Int(((duration + bedtime + interruptions) * 100).rounded()))
        )
    }

    public static func onsetMinutes(
        _ samples: [SleepSample],
        in window: DateInterval,
        preference: SleepSourcePreference
    ) -> Double? {
        mainSession(chosen(samples, in: window, preference: preference).intervals)
            .map { $0.start.timeIntervalSince(window.start) / 60 }
    }

    public static func window(for day: CompetitionDay) -> DateInterval? {
        guard let zone = TimeZone(identifier: day.timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var components = DateComponents()
        components.era = day.era
        components.year = day.year
        components.month = day.month
        components.day = day.day
        components.hour = 18
        guard let end = calendar.date(from: components),
              let start = calendar.date(byAdding: .day, value: -1, to: end)
        else { return nil }
        return DateInterval(start: start, end: end)
    }

    public static func minutesAsleep(
        _ samples: [SleepSample],
        in window: DateInterval,
        preference: SleepSourcePreference
    ) -> Double {
        mergedDuration(chosen(samples, in: window, preference: preference).intervals) / 60
    }

    static func chosen(
        _ samples: [SleepSample],
        in window: DateInterval,
        preference: SleepSourcePreference
    ) -> (intervals: [DateInterval], source: SleepSource?) {
        func clipped(_ source: SleepSource) -> [DateInterval] {
            samples.filter { $0.source == source }.compactMap {
                $0.interval.intersection(with: window)
            }.filter { $0.duration > 0 }
        }
        switch preference {
        case .watch: return (clipped(.watch), .watch)
        case .oura: return (clipped(.oura), .oura)
        case .automatic:
            let oura = clipped(.oura)
            if !oura.isEmpty { return (oura, .oura) }
            let watch = clipped(.watch)
            return (watch, watch.isEmpty ? nil : .watch)
        }
    }

    static func mainSession(_ intervals: [DateInterval]) -> DateInterval? {
        var sessions: [(span: DateInterval, asleep: TimeInterval)] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = sessions.last, interval.start.timeIntervalSince(last.span.end) < 2 * 3_600 {
                sessions[sessions.count - 1].span = DateInterval(
                    start: last.span.start, end: max(last.span.end, interval.end)
                )
            } else {
                sessions.append((interval, 0))
            }
        }
        return sessions.map { session in
            (session.span, mergedDuration(intervals.filter { session.span.intersects($0) }))
        }.max { $0.1 < $1.1 }?.0
    }

    static func mergedDuration(_ intervals: [DateInterval]) -> TimeInterval {
        var total: TimeInterval = 0
        var current: DateInterval?
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            guard let open = current else { current = interval; continue }
            if interval.start <= open.end {
                current = DateInterval(start: open.start, end: max(open.end, interval.end))
            } else {
                total += open.duration
                current = interval
            }
        }
        return total + (current?.duration ?? 0)
    }
}

public enum SleepSource: String, Codable, Equatable, Sendable {
    case watch
    case oura
}

public enum SleepSourcePreference: String, Codable, CaseIterable, Equatable, Sendable {
    case automatic
    case watch
    case oura
}

public struct SleepNight: Equatable, Sendable {
    public let minutesAsleep: Double
    public let awakeMinutes: Double
    public let onsetMinutes: Double?
    public let source: SleepSource?
    public let durationPoints: Double
    public let bedtimePoints: Double
    public let interruptionPoints: Double
    public let basisPoints: Int

    public static let none = SleepNight(
        minutesAsleep: 0, awakeMinutes: 0, onsetMinutes: nil, source: nil,
        durationPoints: 0, bedtimePoints: 0, interruptionPoints: 0, basisPoints: 0
    )

    public init(
        minutesAsleep: Double, awakeMinutes: Double, onsetMinutes: Double?, source: SleepSource?,
        durationPoints: Double, bedtimePoints: Double, interruptionPoints: Double, basisPoints: Int
    ) {
        self.minutesAsleep = minutesAsleep
        self.awakeMinutes = awakeMinutes
        self.onsetMinutes = onsetMinutes
        self.source = source
        self.durationPoints = durationPoints
        self.bedtimePoints = bedtimePoints
        self.interruptionPoints = interruptionPoints
        self.basisPoints = basisPoints
    }
}

public struct SleepSample: Equatable, Sendable {
    public let interval: DateInterval
    public let source: SleepSource

    public init(interval: DateInterval, source: SleepSource) {
        self.interval = interval
        self.source = source
    }
}
