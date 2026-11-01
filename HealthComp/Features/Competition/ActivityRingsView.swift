import CompetitionCore
import SwiftUI

struct CompetitionRingRow: Equatable, Sendable {
    /// "Move" | "Move Time" | "Exercise" | "Stand" | "Roll" | "Stand or Roll"
    let title: String
    /// "420/500 kcal" | "No data"
    let detail: String
    /// "420 of 500 kilocalories" | "no data"
    let spokenDetail: String
    /// Whole points; nil when the reading has no score.
    let points: Double?
}

struct CompetitionRingPanel: Equatable, Sendable {
    /// Always Move, Exercise, Stand.
    let rows: [CompetitionRingRow]
    let isPaused: Bool
    let note: String?
    let footer: String
    let accessibilityLabel: String
}

/// One snapshot as three ring rows whose points add up to the day's points:
/// the accepted snapshot when there is one, otherwise the latest. Nil when the
/// day has neither snapshot.
func competitionRingPanel(
    _ day: LocalCompetitionDayPresentation,
    locale: Locale = .current
) -> CompetitionRingPanel? {
    guard let snapshot = day.ownerAcceptedSnapshot ?? day.ownerLatestSnapshot else {
        return nil
    }
    let isAccepted = day.ownerAcceptedSnapshot != nil
    let total = isAccepted
        ? day.ownerAcceptedPoints
        : ActivityScoreCalculator.score(snapshot, policy: day.scoringPolicy).availableScore?.points
    let shares = competitionRingShares(snapshot, perRingCap: day.scoringPolicy.perRingCap)
    let sum = shares.reduce(0, +)
    let points = total.map { total in
        competitionRoundedParts(shares.map { sum > 0 ? total * $0 / sum : 0 }, total: total)
    }

    func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)).locale(locale))
    }
    func row(_ index: Int, _ title: String, _ reading: ActivityRingReading, _ unit: String, _ spokenUnit: String) -> CompetitionRingRow {
        guard let value = reading.value, let goal = reading.goal, goal > 0 else {
            return CompetitionRingRow(title: title, detail: "No data", spokenDetail: "no data", points: points?[index])
        }
        return CompetitionRingRow(
            title: title,
            detail: "\(number(value))/\(number(goal)) \(unit)",
            spokenDetail: "\(number(value)) of \(number(goal)) \(spokenUnit)",
            points: points?[index]
        )
    }

    let minutes = snapshot.moveMode == .moveMinutes
    let standTitle = switch snapshot.standMode {
    case .standHours: "Stand"
    case .rollHours: "Roll"
    case .unknown: "Stand or Roll"
    }
    let rows = [
        row(0, minutes ? "Move Time" : "Move", snapshot.move, minutes ? "min" : "kcal", minutes ? "minutes" : "kilocalories"),
        row(1, "Exercise", snapshot.exercise, "min", "minutes"),
        row(2, standTitle, snapshot.standOrRoll, "hr", "hours"),
    ]
    let isPaused = snapshot.pauseState == .paused

    let note: String? = if isAccepted, day.ownerLatestSnapshot != snapshot {
        "Points use an earlier reading. Your rings have changed since."
    } else if !isAccepted, total != nil {
        "These points haven’t synced yet."
    } else {
        nil
    }

    let rule: String = if let cap = day.scoringPolicy.perRingCap {
        "1 point per 1% of each ring, up to \(Int(cap))% per ring."
    } else if sum * 100 > ActivityScore.maximumDailyPoints {
        "Capped at 600 points a day."
    } else {
        "1 point per 1% of each ring."
    }

    let spokenRows = rows.map { row in
        "\(row.title), \(row.spokenDetail)"
            + (row.points.map { ", \(competitionPointsAccessibilityText($0, locale: locale))" } ?? "")
    }
    let spoken = (["Your rings"] + spokenRows
        + (isPaused ? ["Activity tracking paused"] : [])
        + [note].compactMap { $0.map { String($0.dropLast()) } })
        .joined(separator: ". ") + "."

    return CompetitionRingPanel(
        rows: rows,
        isPaused: isPaused,
        note: note,
        footer: "\(rule) Your ring values stay on this iPhone.",
        accessibilityLabel: spoken
    )
}

/// Your rings for one day: three rows that add up to the day's points, then
/// the scoring rule. Ring colors appear only here, on your own rows.
struct ActivityRingsView: View {
    let panel: CompetitionRingPanel

    @Environment(\.locale) private var locale

    private let colors = [Theme.move, Theme.exercise, Theme.stand]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(panel.rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        SlantedBar()
                            .fill(colors[index])
                            .frame(width: 10, height: 10)
                        (Text(row.title).fontWeight(.semibold).foregroundStyle(Theme.ink)
                            + Text(" · \(row.detail)").foregroundStyle(Theme.secondary))
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let points = row.points {
                            Text(competitionPointsText(points, locale: locale))
                                .font(.headline.weight(.heavy).width(.condensed).monospacedDigit())
                                .foregroundStyle(Theme.ink)
                                .fixedSize()
                        }
                    }
                }
                if panel.isPaused {
                    Text("Activity tracking paused")
                        .font(.caption.bold())
                        .foregroundStyle(Theme.ink)
                }
                if let note = panel.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .themePanel()
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("competition.ownerRings")
            .accessibilityLabel(panel.accessibilityLabel)

            Text(panel.footer)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
