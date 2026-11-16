import Foundation

/// Sleep beta: a night is worth up to 100 points, split the way Apple's
/// Sleep Score splits it: time asleep 50, bedtime consistency 30,
/// interruptions 20. Apple doesn't publish its curves, so these are ours. Only
/// the basis points leave the phone.
public enum SleepScore {
    public static let goalMinutes = 480.0
    public static let maximumBasisPoints = 10_000
    /// Rings (600) plus one night (100).
    public static let maximumDailyPoints = 700.0
    /// Nights before this one that set your usual bedtime, as Apple's 13.
    public static let historyNights = 13

    /// 50 at 8 hours asleep, in proportion below.
    public static func durationPoints(minutesAsleep: Double) -> Double {
        guard minutesAsleep.isFinite, minutesAsleep > 0 else { return 0 }
        return 50 * min(1, minutesAsleep / goalMinutes)
    }

    /// 30 within half an hour of your usual bedtime, 0 at two hours off.
    /// No usual bedtime yet (under 3 earlier nights) scores 30.
    public static func bedtimePoints(onsetMinutes: Double, usualOnsetMinutes: Double?) -> Double {
        guard let usual = usualOnsetMinutes else { return 30 }
        let off = abs(onsetMinutes - usual)
        return 30 * min(1, max(0, (120 - off) / 90))
    }

    /// 20 with 10 minutes or less awake after falling asleep, 0 at 70.
    public static func interruptionPoints(awakeMinutes: Double) -> Double {
        20 * min(1, max(0, (70 - awakeMinutes) / 60))
    }

    /// The median bedtime of earlier nights, in minutes after 6 pm; nil
    /// under 3 nights.
    public static func usualOnset(_ onsets: [Double]) -> Double? {
        guard onsets.count >= 3 else { return nil }
        let sorted = onsets.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// One night from the chosen source. `usualOnsetMinutes` comes from
    /// `usualOnset` over the nights before. A night with no sleep is 0.
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

    /// When you fell asleep on that night, in minutes after 6 pm; nil when
    /// nothing was recorded.
    public static func onsetMinutes(
        _ samples: [SleepSample],
        in window: DateInterval,
        preference: SleepSourcePreference
    ) -> Double? {
        mainSession(chosen(samples, in: window, preference: preference).intervals)
            .map { $0.start.timeIntervalSince(window.start) / 60 }
    }

    /// A night counts for the day you wake up on: 6 pm the evening before to
    /// 6 pm that day, in the match's time zone.
    // ponytail: fixed 6 pm cutoff; a shift worker's day sleep after 6 pm lands on tomorrow.
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

    /// Minutes asleep inside `window` from the chosen source, with
    /// overlapping samples counted once.
    public static func minutesAsleep(
        _ samples: [SleepSample],
        in window: DateInterval,
        preference: SleepSourcePreference
    ) -> Double {
        mergedDuration(chosen(samples, in: window, preference: preference).intervals) / 60
    }

    /// One source a night, so wearing both never doubles up: Automatic
    /// prefers Oura on a night it has, else Apple Watch.
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

    /// The night's main sleep: asleep spans less than 2 hours apart join up,
    /// and the stretch with the most sleep wins, so an afternoon nap sets
    /// neither bedtime nor wake-ups.
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

/// The trackers whose sleep counts. Anything else in Health (other apps,
/// hand-entered nights) is ignored.
public enum SleepSource: String, Codable, Equatable, Sendable {
    case watch
    case oura
}

public enum SleepSourcePreference: String, Codable, CaseIterable, Equatable, Sendable {
    case automatic
    case watch
    case oura
}

/// One night's score and what it came from.
public struct SleepNight: Equatable, Sendable {
    public let minutesAsleep: Double
    /// Awake between falling asleep and finally waking.
    public let awakeMinutes: Double
    /// Fell asleep, in minutes after 6 pm the evening before.
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

/// One asleep interval (any stage) from a trusted source.
public struct SleepSample: Equatable, Sendable {
    public let interval: DateInterval
    public let source: SleepSource

    public init(interval: DateInterval, source: SleepSource) {
        self.interval = interval
        self.source = source
    }
}
