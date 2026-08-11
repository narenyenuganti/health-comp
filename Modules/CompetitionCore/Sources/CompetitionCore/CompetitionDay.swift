import Foundation

public struct CompetitionDay: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidTimeZoneIdentifier(String)
        case invalidGregorianDate(era: Int, year: Int, month: Int, day: Int)
    }

    public let era: Int
    public let year: Int
    public let month: Int
    public let day: Int
    public let timeZoneIdentifier: String

    public init(
        era: Int,
        year: Int,
        month: Int,
        day: Int,
        timeZoneIdentifier: String
    ) throws {
        let timeZone = try Self.timeZone(for: timeZoneIdentifier)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let components = DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            era: era,
            year: year,
            month: month,
            day: day
        )
        let representedComponents: DateComponents?
        if let date = calendar.date(from: components) {
            representedComponents = calendar.dateComponents(
                [.era, .year, .month, .day],
                from: date
            )
        } else {
            representedComponents = nil
        }

        guard
            representedComponents?.era == era,
            representedComponents?.year == year,
            representedComponents?.month == month,
            representedComponents?.day == day
        else {
            throw ValidationError.invalidGregorianDate(
                era: era,
                year: year,
                month: month,
                day: day
            )
        }

        self.era = era
        self.year = year
        self.month = month
        self.day = day
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    static func timeZone(for identifier: String) throws -> TimeZone {
        guard let timeZone = TimeZone(identifier: identifier) else {
            throw ValidationError.invalidTimeZoneIdentifier(identifier)
        }
        return timeZone
    }

    private enum CodingKeys: String, CodingKey {
        case era
        case year
        case month
        case day
        case timeZoneIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            era: container.decode(Int.self, forKey: .era),
            year: container.decode(Int.self, forKey: .year),
            month: container.decode(Int.self, forKey: .month),
            day: container.decode(Int.self, forKey: .day),
            timeZoneIdentifier: container.decode(String.self, forKey: .timeZoneIdentifier)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(era, forKey: .era)
        try container.encode(year, forKey: .year)
        try container.encode(month, forKey: .month)
        try container.encode(day, forKey: .day)
        try container.encode(timeZoneIdentifier, forKey: .timeZoneIdentifier)
    }
}
