import Foundation

// Foundation only: CI compiles this file on its own
// (scripts/test-competition-local-date-formatting.sh).

// MARK: Numbers

private func competitionDisplayedPoints(_ points: Double, _ fractionDigits: Int) -> Double {
    let scale = pow(10, Double(fractionDigits))
    return (points * scale).rounded(.toNearestOrAwayFromZero) / scale
}

/// Whole points by default, rounded half away from zero and grouped in the
/// user's locale. A missing value draws "--".
func competitionPointsText(
    _ points: Double?,
    fractionDigits: Int = 0,
    locale: Locale = .current
) -> String {
    guard let points else { return "--" }
    return competitionDisplayedPoints(points, fractionDigits)
        .formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale))
}

/// VoiceOver never reads "--": a missing value is "no points yet".
func competitionPointsAccessibilityText(
    _ points: Double?,
    fractionDigits: Int = 0,
    locale: Locale = .current
) -> String {
    guard let points else { return "no points yet" }
    let text = competitionPointsText(points, fractionDigits: fractionDigits, locale: locale)
    return competitionDisplayedPoints(points, fractionDigits) == 1
        ? "\(text) point"
        : "\(text) points"
}

/// The margin between the two numbers as shown, never the raw values.
func competitionDisplayedMargin(
    userPoints: Double,
    opponentPoints: Double,
    fractionDigits: Int = 0
) -> Double {
    competitionDisplayedPoints(userPoints, fractionDigits)
        - competitionDisplayedPoints(opponentPoints, fractionDigits)
}

/// Two decimals only when whole points would hide a decided winner.
func competitionFinalFractionDigits(userPoints: Double, opponentPoints: Double) -> Int {
    userPoints != opponentPoints
        && competitionDisplayedMargin(userPoints: userPoints, opponentPoints: opponentPoints) == 0
        ? 2 : 0
}

/// Whole parts that add up to the whole total: the remainder goes to the
/// largest raw part (the first one on ties).
func competitionRoundedParts(_ parts: [Double], total: Double) -> [Double] {
    var rounded = parts.map { $0.rounded(.toNearestOrAwayFromZero) }
    guard let largest = parts.indices.max(by: { parts[$0] < parts[$1] }) else { return rounded }
    rounded[largest] += total.rounded(.toNearestOrAwayFromZero) - rounded.reduce(0, +)
    return rounded
}

// MARK: Dates

private func competitionDateFormatter(
    _ template: String,
    locale: Locale,
    timeZone: TimeZone
) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter
}

private func competitionIsSameYear(_ date: Date, _ now: Date, timeZone: TimeZone) -> Bool {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.component(.year, from: date) == calendar.component(.year, from: now)
}

/// A day: "Thu, Oct 29", with the year only when it isn't the current one.
func competitionDayText(
    _ date: Date,
    weekday: Bool = true,
    now: Date = Date(),
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    let template = (weekday ? "EEE" : "")
        + (competitionIsSameYear(date, now, timeZone: timeZone) ? "" : "y")
        + "MMMd"
    return competitionDateFormatter(template, locale: locale, timeZone: timeZone)
        .string(from: date)
}

/// A week, both days inclusive: "Oct 24 – 30", "Oct 28 – Nov 3".
func competitionWeekText(
    _ first: Date,
    _ last: Date,
    now: Date = Date(),
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    let formatter = DateIntervalFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateTemplate = competitionIsSameYear(last, now, timeZone: timeZone)
        ? "MMMd" : "yMMMd"
    return formatter.string(from: first, to: last)
}

/// A moment: "Tue 9:41 PM" within six days of now, otherwise "Oct 21, 9:41 PM".
func competitionMomentText(
    _ date: Date,
    now: Date = Date(),
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    let template: String
    if abs(date.timeIntervalSince(now)) < 6 * 86_400 {
        template = "EEEjmm"
    } else {
        template = competitionIsSameYear(date, now, timeZone: timeZone)
            ? "MMMdjmm" : "yMMMdjmm"
    }
    return competitionDateFormatter(template, locale: locale, timeZone: timeZone)
        .string(from: date)
}

func competitionAwardEarnedText(
    _ date: Date,
    now: Date = Date(),
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    "Earned \(competitionDayText(date, now: now, locale: locale, timeZone: timeZone))"
}
