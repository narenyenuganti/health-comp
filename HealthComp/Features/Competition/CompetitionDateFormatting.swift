import Foundation

func competitionDateRangeText(
    _ firstDate: Date,
    _ lastDate: Date,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    let formatter = DateIntervalFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateTemplate = "yMMMdjmz"
    return formatter.string(from: firstDate, to: lastDate)
}

func competitionDateTimeText(
    _ date: Date,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return "\(formatter.string(from: date)) \(timeZone.abbreviation(for: date) ?? timeZone.identifier)"
}

func competitionAwardDateText(
    _ date: Date,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateStyle = .medium
    return "\(formatter.string(from: date)) \(timeZone.abbreviation(for: date) ?? timeZone.identifier)"
}

func competitionAwardEarnedText(
    _ date: Date,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    "Earned \(competitionAwardDateText(date, locale: locale, timeZone: timeZone))"
}
