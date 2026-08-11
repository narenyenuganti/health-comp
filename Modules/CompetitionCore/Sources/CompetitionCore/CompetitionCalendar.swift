import Foundation

public struct CompetitionCalendar: Codable, Hashable, Sendable {
    public enum ArithmeticError: Error, Equatable, Sendable {
        case timeZoneMismatch(expected: String, actual: String)
        case unableToRepresentDay(CompetitionDay)
        case unableToAddCalendarDay(CompetitionDay)
        case unableToExtractGregorianComponents
    }

    public let timeZoneIdentifier: String

    public init(timeZoneIdentifier: String) throws {
        _ = try CompetitionDay.timeZone(for: timeZoneIdentifier)
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public func day(containing date: Date) throws -> CompetitionDay {
        let components = try calendar().dateComponents(
            [.era, .year, .month, .day],
            from: date
        )
        guard
            let era = components.era,
            let year = components.year,
            let month = components.month,
            let day = components.day
        else {
            throw ArithmeticError.unableToExtractGregorianComponents
        }
        return try CompetitionDay(
            era: era,
            year: year,
            month: month,
            day: day,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    public func startDay(afterAcceptanceAt acceptanceDate: Date) throws -> CompetitionDay {
        try day(after: day(containing: acceptanceDate))
    }

    public func sevenDayWindow(startingOn startDay: CompetitionDay) throws -> [CompetitionDay] {
        var result = [try requireCompetitionTimeZone(startDay)]
        result.reserveCapacity(7)
        for _ in 1..<7 {
            result.append(try day(after: result[result.count - 1]))
        }
        return result
    }

    public func day(after day: CompetitionDay) throws -> CompetitionDay {
        let localDay = try requireCompetitionTimeZone(day)
        let localStart = try startOfDay(localDay)
        guard let nextStart = try calendar().date(
            byAdding: .day,
            value: 1,
            to: localStart
        ) else {
            throw ArithmeticError.unableToAddCalendarDay(localDay)
        }
        return try self.day(containing: nextStart)
    }

    public func startOfDay(_ day: CompetitionDay) throws -> Date {
        let localDay = try requireCompetitionTimeZone(day)
        let gregorianCalendar = try calendar()
        let timeZone = try CompetitionDay.timeZone(for: timeZoneIdentifier)
        let components = DateComponents(
            calendar: gregorianCalendar,
            timeZone: timeZone,
            era: localDay.era,
            year: localDay.year,
            month: localDay.month,
            day: localDay.day
        )
        guard let date = gregorianCalendar.date(from: components) else {
            throw ArithmeticError.unableToRepresentDay(localDay)
        }
        return gregorianCalendar.startOfDay(for: date)
    }

    private func calendar() throws -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = try CompetitionDay.timeZone(for: timeZoneIdentifier)
        return result
    }

    private func requireCompetitionTimeZone(
        _ day: CompetitionDay
    ) throws -> CompetitionDay {
        guard day.timeZoneIdentifier == timeZoneIdentifier else {
            throw ArithmeticError.timeZoneMismatch(
                expected: timeZoneIdentifier,
                actual: day.timeZoneIdentifier
            )
        }
        return day
    }

    private enum CodingKeys: String, CodingKey {
        case timeZoneIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            timeZoneIdentifier: container.decode(
                String.self,
                forKey: .timeZoneIdentifier
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timeZoneIdentifier, forKey: .timeZoneIdentifier)
    }
}
