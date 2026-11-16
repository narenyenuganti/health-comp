import CompetitionCore
import Foundation
import SwiftUI

// Sleep beta: "Rings + Sleep" duels. Each night is worth up to 100 points
// (time asleep 50, bedtime consistency 30, wake-ups 20, as Apple's Sleep
// Score splits it) on top of the rings' 600. Nights live
// beside the ring score, read and written through list_sleep_scoring and
// submit_sleep_night, and are folded into a match's presentation in one
// place, `addingSleep`, so every screen after it sees the combined score.

/// Phone-local settings for the beta.
enum SleepBeta {
    static let enabledKey = "healthcomp.sleepBeta.enabled"
    static let sourceKey = "healthcomp.sleepBeta.source"
    static let introSeenKey = "healthcomp.sleepBeta.introSeen"

    static var sourcePreference: SleepSourcePreference {
        UserDefaults.standard.string(forKey: sourceKey)
            .flatMap(SleepSourcePreference.init(rawValue:)) ?? .automatic
    }
}

extension SleepSourcePreference {
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .watch: "Apple Watch"
        case .oura: "Oura Ring"
        }
    }
}

/// Your own night as this phone read it: its three parts and what they came from.
struct CompetitionSleepReading: Equatable, Sendable {
    let night: SleepNight
    /// 6 pm the evening before, so onsets read as clock times.
    let windowStart: Date
    /// Your usual bedtime from the nights before, in minutes after 6 pm.
    let usualOnsetMinutes: Double?
    let readAt: Date

    var minutesAsleep: Double { night.minutesAsleep }
    var source: SleepSource? { night.source }
    var points: Double { Double(night.basisPoints) / 100 }
    var bedtime: Date? { night.onsetMinutes.map { windowStart.addingTimeInterval($0 * 60) } }
    var usualBedtime: Date? { usualOnsetMinutes.map { windowStart.addingTimeInterval($0 * 60) } }
}

/// Both players' nights in one Rings + Sleep match, by day ordinal, in points.
struct CompetitionSleepPresentation: Equatable, Sendable {
    var owner: [Int: Double] = [:]
    var opponent: [Int: Double] = [:]
    /// What this phone read for your nights, for the night sheet.
    var ownerReadings: [Int: CompetitionSleepReading] = [:]

    var ownerTotal: Double { owner.values.reduce(0, +) }
    var opponentTotal: Double { opponent.values.reduce(0, +) }
}

extension LocalCompetitionPresentation {
    var isSleepMatch: Bool { sleep != nil }

    /// Adds both players' nights to every day, both totals and the verdict.
    /// The server's result is rings-only; in a sleep match the outcome is
    /// the combined score's.
    func addingSleep(
        _ match: CompetitionSleepMatch,
        viewer: UUID,
        readings: [Int: CompetitionSleepReading] = [:]
    ) -> Self {
        var sleep = CompetitionSleepPresentation(ownerReadings: readings)
        for night in match.nights {
            let points = Double(night.basisPoints) / 100
            if night.profileID == viewer {
                sleep.owner[night.dayOrdinal] = points
            } else {
                sleep.opponent[night.dayOrdinal] = points
            }
        }
        var copy = self
        copy.sleep = sleep
        copy.days = days.map { day in
            var day = day
            day.dailyMaximum = SleepScore.maximumDailyPoints
            day.ownerSleepReading = readings[day.ordinal]
            if let points = sleep.owner[day.ordinal] {
                day.ownerSleepPoints = points
                day.ownerAcceptedPoints = (day.ownerAcceptedPoints ?? 0) + points
            }
            if let points = sleep.opponent[day.ordinal] {
                day.opponentSleepPoints = points
                day.opponentRevealedPoints = (day.opponentRevealedPoints ?? 0) + points
            }
            return day
        }
        copy.userPoints += sleep.ownerTotal
        copy.opponentPoints += sleep.opponentTotal
        if let result = terminalResult {
            let user = result.userPoints + sleep.ownerTotal
            let opponent = result.opponentPoints + sleep.opponentTotal
            let outcome = Self.outcome(user, opponent)
            copy.terminalResult = LocalCompetitionTerminalPresentation(
                userPoints: user,
                opponentPoints: opponent,
                outcome: outcome,
                basis: result.basis,
                completedAt: result.completedAt
            )
            switch lifecycle {
            case let .completed(_, basis, completedAt):
                copy.lifecycle = .completed(outcome: outcome, basis: basis, completedAt: completedAt)
            case let .archived(_, basis, completedAt, archivedAt):
                copy.lifecycle = .archived(
                    outcome: outcome, basis: basis,
                    completedAt: completedAt, archivedAt: archivedAt
                )
            default:
                break
            }
        }
        return copy
    }

    private static func outcome(_ user: Double, _ opponent: Double) -> CompetitionOutcome {
        // Hundredths, the server's unit, so float noise never splits a tie.
        let a = (user * 100).rounded(), b = (opponent * 100).rounded()
        return a > b ? .win : a < b ? .loss : .tie
    }
}

/// Your nights for the days of a match that have begun, read from Health:
/// one window per day, 6 pm the evening before to 6 pm that day. Each
/// night's usual bedtime comes from the 13 nights before it, so `samples`
/// should reach back 13 days before Day 1.
func competitionOwnSleep(
    days: [CompetitionDay],
    through ordinal: Int,
    samples: [SleepSample],
    preference: SleepSourcePreference,
    readAt: Date
) -> [Int: CompetitionSleepReading] {
    var readings: [Int: CompetitionSleepReading] = [:]
    for (index, day) in days.prefix(max(0, min(ordinal, 7))).enumerated() {
        guard let window = SleepScore.window(for: day) else { continue }
        // ponytail: earlier nights are whole 24 h steps back, so a DST change
        // shifts them an hour; fine for a bedtime median.
        let onsets = (1...SleepScore.historyNights).compactMap { back -> Double? in
            let earlier = DateInterval(
                start: window.start.addingTimeInterval(-Double(back) * 86_400),
                duration: window.duration
            )
            return SleepScore.onsetMinutes(samples, in: earlier, preference: preference)
        }
        let usual = SleepScore.usualOnset(onsets)
        readings[index + 1] = CompetitionSleepReading(
            night: SleepScore.night(samples, in: window, preference: preference, usualOnsetMinutes: usual),
            windowStart: window.start,
            usualOnsetMinutes: usual,
            readAt: readAt
        )
    }
    return readings
}

/// "7h 18m".
func competitionSleepDurationText(_ minutes: Double) -> String {
    let total = Int(minutes.rounded())
    return "\(total / 60)h \(String(format: "%02d", total % 60))m"
}

/// The ring panel's fourth row: "Sleep · 7h 18m asleep", or why there's no night.
func competitionSleepRow(
    _ day: LocalCompetitionDayPresentation,
    locale: Locale = .current
) -> CompetitionRingRow {
    let points = day.ownerSleepPoints ?? day.ownerSleepReading?.points
    guard let minutes = day.ownerSleepReading?.minutesAsleep, minutes > 0 else {
        let synced = day.ownerSleepPoints != nil
        return CompetitionRingRow(
            title: "Sleep",
            detail: synced ? "Synced" : "No night yet",
            spokenDetail: synced ? "synced" : "no night yet",
            points: points
        )
    }
    let hours = Int(minutes.rounded()) / 60, rest = Int(minutes.rounded()) % 60
    return CompetitionRingRow(
        title: "Sleep",
        detail: "\(competitionSleepDurationText(minutes)) asleep",
        spokenDetail: "\(hours) hours \(rest) minutes asleep",
        points: points
    )
}

/// One night of a Rings + Sleep match: what Health had, its points and theirs.
struct CompetitionNightDrawer: View {
    let competition: LocalCompetitionPresentation
    let ordinal: Int

    @Environment(\.locale) private var locale

    private var reading: CompetitionSleepReading? { competition.sleep?.ownerReadings[ordinal] }
    private var ownPoints: Double? { competition.sleep?.owner[ordinal] }
    private var theirPoints: Double? { competition.sleep?.opponent[ordinal] }

    var body: some View {
        CompetitionDrawer(title: "Night before Day \(ordinal)", subtitle: "Counts for Day \(ordinal)") {
            if let reading, reading.minutesAsleep > 0 {
                VStack(alignment: .leading, spacing: 14) {
                    part("Time asleep", competitionSleepDurationText(reading.minutesAsleep) + " of 8h",
                         reading.night.durationPoints, of: 50)
                    part("Bedtime", bedtimeText(reading), reading.night.bedtimePoints, of: 30)
                    part("Wake-ups", "\(Int(reading.night.awakeMinutes.rounded())) min awake",
                         reading.night.interruptionPoints, of: 20)
                    if let source = reading.source {
                        Text("From \(source == .oura ? "Oura Ring" : "Apple Watch")")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .themePanel()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No sleep in Apple Health")
                        .font(.title3.weight(.heavy).width(.condensed))
                        .foregroundStyle(Theme.ink)
                    Text("This night scores 0 unless your watch or ring syncs it before the match ends.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .themePanel()
                .accessibilityElement(children: .combine)
            }

            VStack(spacing: 12) {
                line("You", ownPoints, color: Theme.you)
                line(competition.opponentDisplayName, theirPoints, color: Theme.ink)
            }
            .padding(16)
            .themePanel()

            Text("Only the points leave your iPhone, never your sleep.")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
        }
        .accessibilityIdentifier("competition.night")
    }

    /// "Fell asleep 11:42 PM, usual 11:20 PM".
    private func bedtimeText(_ reading: CompetitionSleepReading) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
        guard let bedtime = reading.bedtime else { return "" }
        guard let usual = reading.usualBedtime else {
            return "Fell asleep \(bedtime.formatted(time)), no usual time yet"
        }
        return "Fell asleep \(bedtime.formatted(time)), usual \(usual.formatted(time))"
    }

    /// One part of the night's score: what it measured, then its points.
    private func part(_ title: String, _ detail: String, _ points: Double, of maximum: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            SlantedBar()
                .fill(Theme.sleep)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            (Text(Int(points.rounded()).formatted()).foregroundStyle(Theme.ink)
                + Text("/\(maximum)").foregroundStyle(Theme.secondary))
                .font(.headline.weight(.heavy).width(.condensed).monospacedDigit())
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private func line(_ name: String, _ points: Double?, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(points.map { competitionPointsText($0, locale: locale) } ?? "Waiting to sync")
                .font(points == nil ? .subheadline : .headline.weight(.heavy).width(.condensed).monospacedDigit())
                .foregroundStyle(points == nil ? Theme.secondary : Theme.ink)
        }
        .accessibilityElement(children: .combine)
    }
}
