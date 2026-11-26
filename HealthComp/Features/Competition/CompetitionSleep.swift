import CompetitionCore
import Foundation
import SwiftUI

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

struct CompetitionSleepReading: Equatable, Sendable {
    let night: SleepNight
    let windowStart: Date
    let usualOnsetMinutes: Double?
    let readAt: Date

    var minutesAsleep: Double { night.minutesAsleep }
    var source: SleepSource? { night.source }
    var points: Double { Double(night.basisPoints) / 100 }
    var bedtime: Date? { night.onsetMinutes.map { windowStart.addingTimeInterval($0 * 60) } }
    var wakeTime: Date? {
        bedtime.map { $0.addingTimeInterval((minutesAsleep + night.awakeMinutes) * 60) }
    }
    var usualBedtime: Date? { usualOnsetMinutes.map { windowStart.addingTimeInterval($0 * 60) } }
}

struct CompetitionSleepPresentation: Equatable, Sendable {
    var owner: [Int: Double] = [:]
    var opponent: [Int: Double] = [:]
    var ownerReadings: [Int: CompetitionSleepReading] = [:]

    var ownerTotal: Double { owner.values.reduce(0, +) }
    var opponentTotal: Double { opponent.values.reduce(0, +) }
}

extension LocalCompetitionPresentation {
    var isSleepMatch: Bool { metrics.includesSleep || sleep != nil }

    func addingSleep(
        _ match: CompetitionSleepMatch,
        viewer: UUID,
        readings: [Int: CompetitionSleepReading] = [:]
    ) -> Self {
        applyingMetrics(.all, sleep: match, viewer: viewer, readings: readings)
    }

    func applyingMetrics(
        _ metrics: CompetitionMetrics,
        sleep match: CompetitionSleepMatch? = nil,
        viewer: UUID? = nil,
        readings: [Int: CompetitionSleepReading] = [:],
        practiceBotSleepNights: [Int: Double]? = nil
    ) -> Self {
        let effective = metrics.isEmpty ? .threeRings : metrics
        var sleepPresentation: CompetitionSleepPresentation?
        if effective.includesSleep {
            var built = CompetitionSleepPresentation(ownerReadings: readings)
            if let match, let viewer {
                for night in match.nights {
                    let points = Double(night.basisPoints) / 100
                    if night.profileID == viewer {
                        built.owner[night.dayOrdinal] = points
                    } else {
                        built.opponent[night.dayOrdinal] = points
                    }
                }
            } else {
                for (ordinal, reading) in readings where reading.minutesAsleep > 0 {
                    built.owner[ordinal] = reading.points
                }
                if let botNights = practiceBotSleepNights {
                    built.opponent = botNights
                }
            }
            sleepPresentation = built
        }

        var copy = self
        copy.metrics = effective
        copy.sleep = sleepPresentation

        let needsRescore = !effective.isDefaultRings
        guard needsRescore else { return copy }

        var newUserTotal = 0.0
        var newOpponentTotal = 0.0
        copy.days = days.map { day in
            var day = day
            day.metrics = effective
            day.dailyMaximum = effective.dailyMaximum
            day.ownerSleepReading = readings[day.ordinal]

            let ownerSleep = sleepPresentation?.owner[day.ordinal]
            let opponentSleep = sleepPresentation?.opponent[day.ordinal]
            day.ownerSleepPoints = ownerSleep
            day.opponentSleepPoints = opponentSleep

            let ownerActivity: Double?
            if !effective.includesActivityRings {
                ownerActivity = nil
            } else if let ringPoints = day.ownerRingPoints, ringPoints.count == 3 {
                ownerActivity = effective.activeActivityIndices.reduce(0.0) { $0 + ringPoints[$1] }
            } else if let snapshot = day.ownerAcceptedSnapshot {
                ownerActivity = ActivityScoreCalculator.score(
                    snapshot, policy: day.scoringPolicy, metrics: effective
                ).availableScore?.points
            } else if effective.intersection(.threeRings) == .threeRings {
                ownerActivity = day.ownerAcceptedPoints
            } else {
                ownerActivity = nil
            }

            if let ownerActivity, let ownerSleep {
                day.ownerAcceptedPoints = ownerActivity + ownerSleep
            } else if let ownerActivity {
                day.ownerAcceptedPoints = ownerActivity
            } else if let ownerSleep {
                day.ownerAcceptedPoints = ownerSleep
            } else if !effective.includesActivityRings {
                day.ownerAcceptedPoints = nil
            } else if day.ownerAcceptedPoints != nil {
                day.ownerAcceptedPoints = 0
            }

            let opponentActivity: Double?
            if !effective.includesActivityRings {
                opponentActivity = nil
            } else if let ringPoints = day.opponentRingPoints, ringPoints.count == 3 {
                opponentActivity = effective.activeActivityIndices.reduce(0.0) { $0 + ringPoints[$1] }
            } else if let revealed = day.opponentRevealedPoints {
                if effective.intersection(.threeRings) == .threeRings {
                    opponentActivity = revealed
                } else {
                    opponentActivity = Double(effective.scaleBotActivityPoints(Int(revealed.rounded())))
                }
            } else {
                opponentActivity = nil
            }

            if let opponentActivity, let opponentSleep {
                day.opponentRevealedPoints = opponentActivity + opponentSleep
            } else if let opponentActivity {
                day.opponentRevealedPoints = opponentActivity
            } else if let opponentSleep {
                day.opponentRevealedPoints = opponentSleep
            } else if !effective.includesActivityRings {
                day.opponentRevealedPoints = nil
            } else if day.opponentRevealedPoints != nil {
                day.opponentRevealedPoints = 0
            }

            if let points = day.ownerAcceptedPoints { newUserTotal += points }
            if let points = day.opponentRevealedPoints { newOpponentTotal += points }
            return day
        }

        copy.userPoints = newUserTotal
        copy.opponentPoints = newOpponentTotal

        if let result = terminalResult {
            let outcome = Self.outcome(newUserTotal, newOpponentTotal)
            copy.terminalResult = LocalCompetitionTerminalPresentation(
                userPoints: newUserTotal,
                opponentPoints: newOpponentTotal,
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
        let a = (user * 100).rounded(), b = (opponent * 100).rounded()
        return a > b ? .win : a < b ? .loss : .tie
    }
}

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

func competitionSleepDurationText(_ minutes: Double) -> String {
    let total = Int(minutes.rounded())
    let mins = (total % 60).formatted(.number.precision(.integerLength(2)))
    return "\(total / 60)h \(mins)m"
}

func competitionSleepRow(
    _ day: LocalCompetitionDayPresentation,
    locale: Locale = .current
) -> CompetitionRingRow {
    let points = day.ownerSleepPoints ?? day.ownerSleepReading?.points
    guard let minutes = day.ownerSleepReading?.minutesAsleep, minutes > 0 else {
        let synced = day.ownerSleepPoints != nil
        return CompetitionRingRow(
            metric: .sleep,
            title: "Sleep",
            detail: synced ? "Synced" : "No night yet",
            spokenDetail: synced ? "synced" : "no night yet",
            points: points
        )
    }
    let hours = Int(minutes.rounded()) / 60, rest = Int(minutes.rounded()) % 60
    return CompetitionRingRow(
        metric: .sleep,
        title: "Sleep",
        detail: "\(competitionSleepDurationText(minutes)) asleep",
        spokenDetail: "\(hours) hours \(rest) minutes asleep",
        points: points,
        sleepReading: day.ownerSleepReading
    )
}

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

    private func bedtimeText(_ reading: CompetitionSleepReading) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
        guard let bedtime = reading.bedtime else { return "" }
        guard let usual = reading.usualBedtime else {
            return "Fell asleep \(bedtime.formatted(time)), no usual time yet"
        }
        return "Fell asleep \(bedtime.formatted(time)), usual \(usual.formatted(time))"
    }

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
            let score = Text(Int(points.rounded()).formatted()).foregroundStyle(Theme.ink)
            let cap = Text("/\(maximum)").foregroundStyle(Theme.secondary)
            Text("\(score)\(cap)")
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
