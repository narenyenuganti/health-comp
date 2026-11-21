import Foundation

private func competitionDisplayedPoints(_ points: Double, _ fractionDigits: Int) -> Double {
    let scale = pow(10, Double(fractionDigits))
    return (points * scale).rounded(.toNearestOrAwayFromZero) / scale
}

func competitionPointsText(
    _ points: Double?,
    fractionDigits: Int = 0,
    locale: Locale = .current
) -> String {
    guard let points else { return "--" }
    return competitionDisplayedPoints(points, fractionDigits)
        .formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale))
}

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

func competitionDisplayedMargin(
    userPoints: Double,
    opponentPoints: Double,
    fractionDigits: Int = 0
) -> Double {
    competitionDisplayedPoints(userPoints, fractionDigits)
        - competitionDisplayedPoints(opponentPoints, fractionDigits)
}

func competitionFinalFractionDigits(userPoints: Double, opponentPoints: Double) -> Int {
    guard userPoints != opponentPoints,
          competitionDisplayedMargin(userPoints: userPoints, opponentPoints: opponentPoints) == 0
    else {
        return 0
    }
    return (2...4).first {
        competitionDisplayedMargin(
            userPoints: userPoints, opponentPoints: opponentPoints, fractionDigits: $0
        ) != 0
    } ?? 4
}

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

func competitionRoundedParts(_ parts: [Double], total: Double) -> [Double] {
    var rounded = parts.map { $0.rounded(.toNearestOrAwayFromZero) }
    guard let largest = parts.indices.max(by: { parts[$0] < parts[$1] }) else { return rounded }
    rounded[largest] += total.rounded(.toNearestOrAwayFromZero) - rounded.reduce(0, +)
    return rounded
}

enum CompetitionDayOutcome: Equatable {
    case today, upcoming, won, lost, tied, noData
}

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

private final class CompetitionFormatterCache: @unchecked Sendable {
    static let shared = CompetitionFormatterCache()

    private struct Key: Hashable {
        let template: String
        let locale: String
        let timeZone: String
    }

    private let lock = NSLock()
    private var dateFormatters: [Key: DateFormatter] = [:]
    private var intervalFormatters: [Key: DateIntervalFormatter] = [:]
    private var ordinalFormatters: [String: NumberFormatter] = [:]

    func formatDate(_ date: Date, template: String, locale: Locale, timeZone: TimeZone) -> String {
        let key = Key(template: template, locale: locale.identifier, timeZone: timeZone.identifier)
        lock.lock()
        defer { lock.unlock() }
        let formatter: DateFormatter
        if let existing = dateFormatters[key] {
            formatter = existing
        } else {
            let created = DateFormatter()
            created.calendar = Calendar(identifier: .gregorian)
            created.locale = locale
            created.timeZone = timeZone
            created.setLocalizedDateFormatFromTemplate(template)
            dateFormatters[key] = created
            formatter = created
        }
        return formatter.string(from: date)
    }

    func formatInterval(from first: Date, to last: Date, template: String, locale: Locale, timeZone: TimeZone) -> String {
        let key = Key(template: template, locale: locale.identifier, timeZone: timeZone.identifier)
        lock.lock()
        defer { lock.unlock() }
        let formatter: DateIntervalFormatter
        if let existing = intervalFormatters[key] {
            formatter = existing
        } else {
            let created = DateIntervalFormatter()
            created.calendar = Calendar(identifier: .gregorian)
            created.locale = locale
            created.timeZone = timeZone
            created.dateTemplate = template
            intervalFormatters[key] = created
            formatter = created
        }
        return formatter.string(from: first, to: last)
    }

    func formatOrdinal(_ value: Int, locale: Locale) -> String {
        let key = locale.identifier
        lock.lock()
        defer { lock.unlock() }
        let formatter: NumberFormatter
        if let existing = ordinalFormatters[key] {
            formatter = existing
        } else {
            let created = NumberFormatter()
            created.locale = locale
            created.numberStyle = .ordinal
            ordinalFormatters[key] = created
            formatter = created
        }
        return formatter.string(from: value as NSNumber) ?? String(value)
    }
}

func competitionFormattedDate(
    _ date: Date,
    template: String,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    CompetitionFormatterCache.shared.formatDate(
        date,
        template: template,
        locale: locale,
        timeZone: timeZone
    )
}

func competitionOrdinalText(
    _ value: Int,
    locale: Locale = Locale(identifier: "en_US")
) -> String {
    CompetitionFormatterCache.shared.formatOrdinal(value, locale: locale)
}

private func competitionIsSameYear(_ date: Date, _ now: Date, timeZone: TimeZone) -> Bool {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.component(.year, from: date) == calendar.component(.year, from: now)
}

func competitionYear(of now: Date, timeZone: TimeZone) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.component(.year, from: now)
}

func competitionDayText(
    _ date: Date,
    weekday: Bool = true,
    now: Date = .now,
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

func competitionDayText(
    _ date: Date,
    weekday: Bool,
    includesYear: Bool,
    locale: Locale,
    timeZone: TimeZone
) -> String {
    let template = (weekday ? "EEE" : "") + (includesYear ? "y" : "") + "MMMd"
    return competitionFormattedDate(date, template: template, locale: locale, timeZone: timeZone)
}

func competitionWeekText(
    _ first: Date,
    _ last: Date,
    now: Date = .now,
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

func competitionWeekText(
    _ first: Date,
    _ last: Date,
    includesYear: Bool,
    locale: Locale,
    timeZone: TimeZone
) -> String {
    CompetitionFormatterCache.shared.formatInterval(
        from: first,
        to: last,
        template: includesYear ? "yMMMd" : "MMMd",
        locale: locale,
        timeZone: timeZone
    )
}

func competitionMomentText(
    _ date: Date,
    now: Date = .now,
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
    return competitionFormattedDate(date, template: template, locale: locale, timeZone: timeZone)
}

func competitionDeadlineText(
    _ date: Date,
    now: Date = .now,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    guard calendar.startOfDay(for: date) == date else {
        return competitionMomentText(date, now: now, locale: locale, timeZone: timeZone)
    }
    let weekday = competitionFormattedDate(
        date.addingTimeInterval(-1),
        template: "EEE",
        locale: locale,
        timeZone: timeZone
    )
    return "\(weekday) night"
}

func competitionUpdatedText(
    _ date: Date,
    now: Date = .now,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    guard calendar.isDate(date, inSameDayAs: now) else {
        return competitionMomentText(date, now: now, locale: locale, timeZone: timeZone)
    }
    return competitionFormattedDate(date, template: "jmm", locale: locale, timeZone: timeZone)
}
