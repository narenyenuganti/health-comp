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

/// Whole points, unless they would hide a decided winner: then two decimals,
/// or more (up to four) until the two numbers differ.
func competitionFinalFractionDigits(userPoints: Double, opponentPoints: Double) -> Int {
    guard userPoints != opponentPoints,
          competitionDisplayedMargin(userPoints: userPoints, opponentPoints: opponentPoints) == 0
    else {
        return 0
    }
    // ponytail: capped at 4; totals are stored in hundredths, so 2 is the real case.
    return (2...4).first {
        competitionDisplayedMargin(
            userPoints: userPoints, opponentPoints: opponentPoints, fractionDigits: $0
        ) != 0
    } ?? 4
}

/// "Won by 230 points" or "Lost by 1 point", from the margin as shown. Nil
/// when the shown totals are equal.
func competitionMarginText(
    userPoints: Double,
    opponentPoints: Double,
    fractionDigits: Int,
    locale: Locale = .current
) -> String? {
    let margin = competitionDisplayedMargin(
        userPoints: userPoints,
        opponentPoints: opponentPoints,
        fractionDigits: fractionDigits
    )
    guard margin != 0 else { return nil }
    return (margin > 0 ? "Won by " : "Lost by ")
        + competitionPointsAccessibilityText(
            abs(margin), fractionDigits: fractionDigits, locale: locale
        )
}

/// "You lead by 12.", "Hermes leads by 382." or "All square.", from the
/// numbers as shown. `competitionLeadText` is the styled version.
func competitionLeadSentence(
    userPoints: Double,
    opponentPoints: Double,
    opponentDisplayName: String,
    fractionDigits: Int = 0,
    locale: Locale = .current
) -> String {
    let margin = competitionDisplayedMargin(
        userPoints: userPoints, opponentPoints: opponentPoints, fractionDigits: fractionDigits
    )
    guard margin != 0 else { return "All square." }
    let points = competitionPointsText(abs(margin), fractionDigits: fractionDigits, locale: locale)
    return margin > 0 ? "You lead by \(points)." : "\(opponentDisplayName) leads by \(points)."
}

/// "+54", "−54" (U+2212) or "0", from the margin as shown.
func competitionSignedMarginText(
    userPoints: Double,
    opponentPoints: Double,
    fractionDigits: Int = 0,
    locale: Locale = .current
) -> String {
    let margin = competitionDisplayedMargin(
        userPoints: userPoints, opponentPoints: opponentPoints, fractionDigits: fractionDigits
    )
    guard margin != 0 else { return "0" }
    let points = competitionPointsText(abs(margin), fractionDigits: fractionDigits, locale: locale)
    return (margin > 0 ? "+" : "\u{2212}") + points
}

/// Whole parts that add up to the whole total: the remainder goes to the
/// largest raw part (the first one on ties).
func competitionRoundedParts(_ parts: [Double], total: Double) -> [Double] {
    var rounded = parts.map { $0.rounded(.toNearestOrAwayFromZero) }
    guard let largest = parts.indices.max(by: { parts[$0] < parts[$1] }) else { return rounded }
    rounded[largest] += total.rounded(.toNearestOrAwayFromZero) - rounded.reduce(0, +)
    return rounded
}

// MARK: Days

/// Every closed day reads one way on the strip, in the result's day counts
/// and in the rows.
enum CompetitionDayOutcome: Equatable {
    case today, upcoming, won, lost, tied, noData
}

/// A day is no data when either score is missing, or when both read 0.
func competitionDayOutcome(
    ordinal: Int,
    currentDayOrdinal: Int?,
    hasOccurred: Bool,
    ownerPoints: Double?,
    opponentPoints: Double?
) -> CompetitionDayOutcome {
    if ordinal == currentDayOrdinal { return .today }
    if !hasOccurred { return .upcoming }
    guard let owner = ownerPoints,
          let opponent = opponentPoints,
          owner.rounded(.toNearestOrAwayFromZero) != 0
            || opponent.rounded(.toNearestOrAwayFromZero) != 0
    else { return .noData }
    let margin = competitionDisplayedMargin(userPoints: owner, opponentPoints: opponent)
    if margin > 0 { return .won }
    if margin < 0 { return .lost }
    return .tied
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

/// The year of `now` where the viewer is.
func competitionYear(of now: Date, timeZone: TimeZone) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.component(.year, from: now)
}

/// A day: "Thu, Oct 29", with the year only when it isn't the current one.
func competitionDayText(
    _ date: Date,
    weekday: Bool = true,
    now: Date = Date(),
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    competitionDayText(
        date,
        weekday: weekday,
        includesYear: !competitionIsSameYear(date, now, timeZone: timeZone),
        locale: locale,
        timeZone: timeZone
    )
}

/// The day style with the year decided by the caller.
func competitionDayText(
    _ date: Date,
    weekday: Bool,
    includesYear: Bool,
    locale: Locale,
    timeZone: TimeZone
) -> String {
    let template = (weekday ? "EEE" : "") + (includesYear ? "y" : "") + "MMMd"
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
    competitionWeekText(
        first,
        last,
        includesYear: !competitionIsSameYear(last, now, timeZone: timeZone),
        locale: locale,
        timeZone: timeZone
    )
}

/// The week style with the year decided by the caller.
func competitionWeekText(
    _ first: Date,
    _ last: Date,
    includesYear: Bool,
    locale: Locale,
    timeZone: TimeZone
) -> String {
    let formatter = DateIntervalFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateTemplate = includesYear ? "yMMMd" : "MMMd"
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

/// A tally deadline: "Wed night" when it falls exactly on midnight in
/// `timeZone`, otherwise the moment style.
func competitionDeadlineText(
    _ date: Date,
    now: Date = Date(),
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    guard calendar.startOfDay(for: date) == date else {
        return competitionMomentText(date, now: now, locale: locale, timeZone: timeZone)
    }
    let weekday = competitionDateFormatter("EEE", locale: locale, timeZone: timeZone)
        .string(from: date.addingTimeInterval(-1))
    return "\(weekday) night"
}

/// "9:41 AM" when `date` is on `now`'s day in `timeZone`; otherwise the moment style.
func competitionUpdatedText(
    _ date: Date,
    now: Date = Date(),
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    guard calendar.isDate(date, inSameDayAs: now) else {
        return competitionMomentText(date, now: now, locale: locale, timeZone: timeZone)
    }
    return competitionDateFormatter("jmm", locale: locale, timeZone: timeZone)
        .string(from: date)
}
