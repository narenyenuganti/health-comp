import CompetitionCore
import SwiftUI

struct CompetitionDetailView: View {
    let competition: LocalCompetitionPresentation
    let source: CompetitionPublicationSource
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                lifecycleHeader

                if case .scheduled = competition.lifecycle {
                    scheduledCard
                }

                if competitionShouldShowScores(competition.lifecycle) {
                    scoreHeader
                } else {
                    Label("Scores begin Day 1", systemImage: "clock")
                        .font(.headline)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 44,
                            alignment: .leading
                        )
                        .padding(16)
                        .background(
                            .background,
                            in: RoundedRectangle(
                                cornerRadius: 18,
                                style: .continuous
                            )
                        )
                }
                sourceStatus
                ownerActivity
                sevenDayScores
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Competition with \(competition.opponentDisplayName)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var lifecycleHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(competitionDetailTitle(competition.lifecycle))
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(lifecycleTint)
            Text(lifecycleSubtitle)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            .background,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }

    private var scheduledCard: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                if let schedule = competition.acceptedConfiguration?.schedule,
                   let dateRange = competitionScheduleDateRangeText(schedule) {
                    Text("Seven-day schedule")
                        .font(.headline)
                    Text(dateRange)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("competition.schedule.dates")
                } else {
                    Text("Starts next competition day")
                        .font(.headline)
                    Text("Your stored schedule sets the seven competition days.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "calendar.badge.clock")
                .font(.title2)
                .foregroundStyle(.indigo)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            Color.indigo.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private var scoreHeader: some View {
        scoreHeaderLayout { scoreCards }
    }

    private var scoreHeaderLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
    }

    @ViewBuilder
    private var scoreCards: some View {
        CompetitionOwnerScoreCard(
            owner: competition.ownerDisplayName,
            todayPoints: todayDay?.ownerAcceptedPoints,
            totalPoints: competition.userPoints,
            isProvisional: scoresAreProvisional,
            periodLabel: competitionScorePeriodLabel(competition.lifecycle),
            tint: .mint,
            identifier: "competition.scoreHeader.naren"
        )
        CompetitionOwnerScoreCard(
            owner: competition.opponentDisplayName,
            todayPoints: todayDay?.opponentRevealedPoints,
            totalPoints: competition.opponentPoints,
            isProvisional: scoresAreProvisional,
            periodLabel: competitionScorePeriodLabel(competition.lifecycle),
            tint: .indigo,
            identifier: "competition.scoreHeader.alex"
        )
    }

    @ViewBuilder
    private var sourceStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let attention = competition.tally?.attention {
                Label(
                    competitionTallyAttentionText(
                        attention,
                        opponentDisplayName: competition.opponentDisplayName,
                        source: source
                    ),
                    systemImage: tallyStatusSymbol(attention)
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tallyStatusTint(attention))
            }

            if let tally = competition.tally {
                Text(
                    competitionTallyDeadlineText(
                        tally,
                        timeZoneIdentifier: competition.timeZoneIdentifier,
                        opponentDisplayName: competition.opponentDisplayName,
                        source: source
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ForEach(
                Array(
                    competitionRefreshTimelineText(
                        lastRefresh: competition.lastRefresh,
                        lastSuccessfulFullWindowRefreshAt: competition.lastSuccessfulFullWindowRefreshAt,
                        timeZoneIdentifier: competition.timeZoneIdentifier
                    ).enumerated()
                ),
                id: \.offset
            ) { offset, line in
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(
                        offset == 0
                            ? "competition.lastSync"
                            : "competition.lastSync.\(offset)"
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            .background,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    @ViewBuilder
    private var ownerActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(competition.ownerDisplayName)’s Activity")
                .font(.headline)

            if let day = activityDay,
               case .observed = day.ownerLatestAvailability,
               let snapshot = day.ownerLatestSnapshot {
                ActivityRingsView(
                    snapshot: snapshot,
                    ownerDisplayName: competition.ownerDisplayName,
                    acceptedPoints: day.ownerAcceptedPoints
                )
                Text(activityEvidenceCaption(day))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let day = activityDay {
                Label(
                    competitionOwnerAvailabilityText(
                        day.ownerLatestAvailability,
                        ordinal: day.ordinal
                    ),
                    systemImage: availabilitySymbol(day.ownerLatestAvailability)
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(availabilityTint(day.ownerLatestAvailability))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
                Label(
                    "Activity appears when Day 1 begins.",
                    systemImage: "clock"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            .background,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }

    private var sevenDayScores: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Seven Days")
                .font(.headline)
                .padding(.horizontal, 4)

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 0) {
                        ForEach(
                            Array(competition.days.enumerated()),
                            id: \.element.ordinal
                        ) { index, day in
                            CompetitionPairedDayRow(
                                day: day,
                                currentDayOrdinal: competition.currentDayOrdinal,
                                ownerName: competition.ownerDisplayName,
                                opponentName: competition.opponentDisplayName
                            )
                            if index < competition.days.count - 1 {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                } else {
                    CompetitionSevenDayChart(
                        days: competition.days,
                        currentDayOrdinal: competition.currentDayOrdinal,
                        ownerName: competition.ownerDisplayName,
                        opponentName: competition.opponentDisplayName
                    )
                }
            }
            .background(
                .background,
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
        }
    }

    private var todayDay: LocalCompetitionDayPresentation? {
        if let ordinal = competition.currentDayOrdinal {
            return competition.days.first { $0.ordinal == ordinal }
        }
        switch competition.lifecycle {
        case .tallying, .completed, .archived:
            return competition.days.first { $0.ordinal == 7 }
        default:
            return nil
        }
    }

    private var activityDay: LocalCompetitionDayPresentation? {
        todayDay ?? competition.days.last(where: {
            $0.ownerLatestAvailability != .notYetOccurred
        })
    }

    private var scoresAreProvisional: Bool {
        if case .tallying = competition.lifecycle { return true }
        return false
    }

    private var lifecycleSubtitle: String {
        switch competition.lifecycle {
        case .scheduled:
            "Your seven-day schedule is set."
        case let .active(dayOrdinal):
            "Day \(dayOrdinal) of 7 with \(competition.opponentDisplayName)."
        case .endsToday:
            "Day 7 closes at the next competition-day boundary."
        case .tallying:
            "Checking the complete seven-day Activity window for stable data."
        default:
            "Local Activity competition with \(competition.opponentDisplayName)."
        }
    }

    private var lifecycleTint: Color {
        switch competition.lifecycle {
        case .tallying: .orange
        case .endsToday: .pink
        default: .accentColor
        }
    }
}

private struct CompetitionSevenDayChart: View {
    let days: [LocalCompetitionDayPresentation]
    let currentDayOrdinal: Int?
    let ownerName: String
    let opponentName: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(days, id: \.ordinal) { day in
                CompetitionPairedDayColumn(
                    day: day,
                    isToday: day.ordinal == currentDayOrdinal,
                    ownerName: ownerName,
                    opponentName: opponentName
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }
}

private struct CompetitionPairedDayColumn: View {
    let day: LocalCompetitionDayPresentation
    let isToday: Bool
    let ownerName: String
    let opponentName: String

    var body: some View {
        VStack(spacing: 5) {
            Text(isToday ? "Today" : "\(day.day.month)/\(day.day.day)")
                .font(
                    .caption2.weight(isToday ? .bold : .regular)
                )
                .foregroundStyle(isToday ? .primary : .secondary)

            HStack(alignment: .bottom, spacing: 3) {
                scoreBar(
                    state: competitionOwnerChartState(day),
                    color: .mint
                )
                scoreBar(
                    state: day.opponentRevealedPoints.map(CompetitionChartState.score) ?? .future,
                    color: .indigo
                )
            }
            .frame(height: 76, alignment: .bottom)

            VStack(spacing: 0) {
                Text(
                    "\(ownerName.prefix(1)) \(competitionChartValueText(competitionOwnerChartState(day)))"
                )
                Text(
                    "\(opponentName.prefix(1)) \(competitionChartValueText(day.opponentRevealedPoints.map(CompetitionChartState.score) ?? .future))"
                )
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            Text("D\(day.ordinal)")
                .font(.caption2.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("competition.day.\(day.ordinal)")
        .accessibilityLabel(
            competitionDayAccessibilityLabel(
                day,
                currentDayOrdinal: isToday ? day.ordinal : nil,
                ownerName: ownerName,
                opponentName: opponentName
            )
        )
    }

    @ViewBuilder
    private func scoreBar(
        state: CompetitionChartState,
        color: Color
    ) -> some View {
        switch state {
        case let .score(points) where points > 0:
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(
                    maxWidth: .infinity,
                    minHeight: 3,
                    idealHeight: max(3, min(72, points / 600 * 72)),
                    maxHeight: max(3, min(72, points / 600 * 72)),
                    alignment: .bottom
                )
        case .score:
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(color, lineWidth: 2)
                .frame(maxWidth: .infinity, minHeight: 5, maxHeight: 5)
        case .future:
            Text("--")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        case .missing:
            Image(systemName: "questionmark.circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        case let .missingWithScore(points):
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 2, dash: [3, 2])
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: 3,
                    idealHeight: max(3, min(72, points / 600 * 72)),
                    maxHeight: max(3, min(72, points / 600 * 72)),
                    alignment: .bottom
                )
        case .unavailable:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        case let .unavailableWithScore(points):
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(
                    Color.orange,
                    style: StrokeStyle(lineWidth: 2, dash: [1, 2])
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: 3,
                    idealHeight: max(3, min(72, points / 600 * 72)),
                    maxHeight: max(3, min(72, points / 600 * 72)),
                    alignment: .bottom
                )
        case .unscored:
            Image(systemName: "minus.circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}

private struct CompetitionOwnerScoreCard: View {
    let owner: String
    let todayPoints: Double?
    let totalPoints: Double
    let isProvisional: Bool
    let periodLabel: String
    let tint: Color
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(owner)
                .font(.headline)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(periodLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(competitionPointsText(todayPoints))
                        .font(.title2.weight(.bold).monospacedDigit())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(competitionScoreTotalLabel(isProvisional: isProvisional))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(competitionPointsText(totalPoints))
                        .font(.title2.weight(.bold).monospacedDigit())
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(
            tint.opacity(0.14),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(
            "\(owner), \(periodLabel) \(competitionPointsAccessibilityText(todayPoints)), \(competitionScoreTotalLabel(isProvisional: isProvisional).lowercased()) \(competitionPointsAccessibilityText(totalPoints))"
        )
    }
}

private struct CompetitionPairedDayRow: View {
    let day: LocalCompetitionDayPresentation
    let currentDayOrdinal: Int?
    let ownerName: String
    let opponentName: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Day \(day.ordinal)")
                    .font(.subheadline.weight(.semibold))
                Text("\(day.day.month)/\(day.day.day)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 62, alignment: .leading)

            Spacer(minLength: 0)

            PairedDayScore(
                initials: "NY",
                points: day.ownerAcceptedPoints,
                status: ownerStatus
            )
            PairedDayScore(
                initials: "A",
                points: day.opponentRevealedPoints,
                status: opponentStatus
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("competition.day.\(day.ordinal)")
        .accessibilityLabel(
            competitionDayAccessibilityLabel(
                day,
                currentDayOrdinal: currentDayOrdinal,
                ownerName: ownerName,
                opponentName: opponentName
            )
        )
    }

    private var ownerStatus: String {
        competitionOwnerAvailabilityShortText(day.ownerLatestAvailability)
    }

    private var opponentStatus: String {
        day.opponentRevealedPoints == nil ? "future" : "observed"
    }
}

private struct PairedDayScore: View {
    let initials: String
    let points: Double?
    let status: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(initials)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(competitionPointsText(points))
                .font(.headline.monospacedDigit())
            Text(status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 58, alignment: .trailing)
    }
}

func competitionDetailTitle(
    _ lifecycle: LocalCompetitionLifecyclePresentation
) -> String {
    switch lifecycle {
    case .scheduled: "Scheduled"
    case let .active(dayOrdinal): "Day \(dayOrdinal)"
    case .endsToday: "Ends Today"
    case .tallying: "Tallying Points"
    case .completed, .archived: "Final Result"
    case .pending: "Invitation"
    case .declined: "Declined"
    case .expired: "Expired"
    }
}

func competitionDayAccessibilityLabel(
    _ day: LocalCompetitionDayPresentation,
    currentDayOrdinal: Int? = nil,
    ownerName: String,
    opponentName: String
) -> String {
    let dayContext: String
    if day.ordinal == currentDayOrdinal {
        dayContext = "Today, scores so far"
    } else if day.ownerLatestAvailability == .notYetOccurred {
        dayContext = "\(competitionDayDateText(day.day)), upcoming, no scores yet"
    } else {
        dayContext = "\(competitionDayDateText(day.day)), complete"
    }
    let owner = "\(ownerName), \(competitionOwnerAccessibilityText(day))"
    let opponent: String
    if let points = day.opponentRevealedPoints {
        opponent = "\(opponentName), \(competitionPointsAccessibilityText(points))"
    } else {
        opponent = "\(opponentName), future, --"
    }
    return "Day \(day.ordinal), \(dayContext). \(owner). \(opponent)."
}

func competitionDayDateText(_ day: CompetitionDay) -> String {
    let symbols = DateFormatter().monthSymbols ?? []
    let month = symbols.indices.contains(day.month - 1)
        ? symbols[day.month - 1]
        : String(day.month)
    return "\(month) \(day.day)"
}

func competitionScheduleDateRangeText(
    _ schedule: CompetitionSchedule,
    locale: Locale = .current
) -> String? {
    guard let days = try? schedule.calendar.sevenDayWindow(
        startingOn: schedule.startDay
    ),
        let first = days.first,
        let last = days.last,
        let firstDate = try? schedule.calendar.startOfDay(first),
        let lastDate = try? schedule.calendar.startOfDay(last),
        let timeZone = TimeZone(
            identifier: schedule.calendar.timeZoneIdentifier
        )
    else {
        return nil
    }
    var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        .locale(locale)
    style.timeZone = timeZone
    return "\(firstDate.formatted(style))–\(lastDate.formatted(style)) (\(schedule.calendar.timeZoneIdentifier))"
}

func competitionOwnerAccessibilityText(
    _ day: LocalCompetitionDayPresentation
) -> String {
    switch day.ownerLatestAvailability {
    case .notYetOccurred:
        "future, --"
    case .observed:
        if let points = day.ownerAcceptedPoints {
            competitionPointsAccessibilityText(points)
        } else {
            "activity observed, no accepted score"
        }
    case .missing:
        "missing activity data, \(competitionPointsAccessibilityText(day.ownerAcceptedPoints))"
    case let .unavailable(reason):
        "\(competitionOwnerAvailabilityText(.unavailable(reason: reason), ordinal: day.ordinal).replacingOccurrences(of: ".", with: "")), \(competitionPointsAccessibilityText(day.ownerAcceptedPoints))"
    }
}

func competitionPointsAccessibilityText(_ points: Double?) -> String {
    guard let points else { return "--" }
    let unit = points == 1 ? "point" : "points"
    return "\(competitionPointsText(points)) \(unit)"
}

func competitionOwnerAvailabilityText(
    _ availability: LocalCompetitionOwnerAvailability,
    ordinal: Int
) -> String {
    switch availability {
    case .notYetOccurred: "Day \(ordinal) has not started yet"
    case .observed: "Day \(ordinal) Activity observed"
    case .missing: "Day \(ordinal) is missing activity data."
    case let .unavailable(reason):
        switch reason {
        case .sourceDataUnavailable:
            "Activity source is temporarily unavailable."
        case .unsupportedActivityConfiguration:
            "This Activity configuration is not supported."
        case .invalidSourceData:
            "Activity data could not be used."
        }
    }
}

private func competitionOwnerAvailabilityShortText(
    _ availability: LocalCompetitionOwnerAvailability
) -> String {
    switch availability {
    case .notYetOccurred: "future"
    case .observed: "observed"
    case .missing: "missing"
    case let .unavailable(reason):
        switch reason {
        case .sourceDataUnavailable: "source unavailable"
        case .unsupportedActivityConfiguration: "unsupported"
        case .invalidSourceData: "invalid data"
        }
    }
}

func competitionTallyAttentionText(
    _ attention: LocalCompetitionTallyAttention,
    opponentDisplayName: String = LocalCompetitionIdentity.opponentDisplayName,
    source _: CompetitionPublicationSource = .simulatedFixture
) -> String {
    switch attention {
    case .noRead:
        return "Waiting for the first complete post-competition Activity check."
    case let .incomplete(missing, unavailable):
        if missing == [7], unavailable.isEmpty {
            return "Day 7 is missing activity data."
        }
        if unavailable == [7], missing.isEmpty {
            return "Day 7 activity source is unavailable."
        }
        let missingText = missing.sorted().map(String.init).joined(separator: ", ")
        let unavailableText = unavailable.sorted().map(String.init).joined(separator: ", ")
        return "Needs Activity data. Missing days: \(missingText.isEmpty ? "none" : missingText). Unavailable days: \(unavailableText.isEmpty ? "none" : unavailableText)."
    case let .unacceptedScores(ordinals):
        return "Waiting to accept scores for days \(ordinals.sorted().map(String.init).joined(separator: ", "))."
    case .opponentPlanUnavailable:
        return "Finalizing \(opponentDisplayName)’s scores."
    case .awaitingStability:
        return "Waiting for one more stable read."
    }
}

func competitionRefreshStatusText(_ status: ActivityRefreshReadStatus) -> String {
    switch status {
    case .completed:
        "Activity data updated."
    case let .failed(reason):
        switch reason {
        case .protectedDataUnavailable:
            "Health data is locked — unlock this iPhone to update."
        case .healthDataUnavailable:
            "Health data is unavailable on this device."
        case .queryCancelled:
            "Activity update was interrupted. HealthComp will try again."
        case .transientFailure, .unknown:
            "Activity couldn’t be updated. HealthComp will try again."
        case .invalidResponse:
            "Activity data couldn’t be read. HealthComp will try again."
        }
    }
}

func competitionRefreshTimelineText(
    lastRefresh: LocalCompetitionRefreshPresentation?,
    lastSuccessfulFullWindowRefreshAt: Date?,
    timeZoneIdentifier: String
) -> [String] {
    var lines: [String] = []
    if let lastRefresh {
        lines.append(
            "Latest Activity check \(competitionDateTimeText(lastRefresh.readAt, timeZoneIdentifier: timeZoneIdentifier)): \(competitionRefreshStatusText(lastRefresh.status))"
        )
    }
    if let lastSuccessfulFullWindowRefreshAt {
        lines.append(
            "Last complete Activity read \(competitionDateTimeText(lastSuccessfulFullWindowRefreshAt, timeZoneIdentifier: timeZoneIdentifier))."
        )
    } else if lastRefresh == nil {
        lines.append("No Activity check yet.")
    }
    return lines
}

func competitionTallyDeadlineText(
    _ tally: LocalCompetitionTallyPresentation,
    timeZoneIdentifier: String,
    opponentDisplayName: String = LocalCompetitionIdentity.opponentDisplayName,
    source: CompetitionPublicationSource = .simulatedFixture
) -> String {
    let deadline = competitionDateTimeText(
        tally.bestAvailableDeadline,
        timeZoneIdentifier: timeZoneIdentifier
    )
    if tally.attention == .awaitingStability {
        return "If complete scores do not stabilize by \(deadline), HealthComp may finalize using the best available accepted data."
    }
    if tally.attention == .opponentPlanUnavailable {
        let qualifier = source == .simulatedFixture ? " simulated" : ""
        return "If \(opponentDisplayName)’s final\(qualifier) scores are still unavailable after \(deadline), HealthComp may finalize using the best available accepted data."
    }
    return "If complete accepted scores are still unavailable after \(deadline), HealthComp may finalize using the best available accepted data."
}

func competitionScoreTotalLabel(isProvisional: Bool) -> String {
    isProvisional ? "Provisional total" : "Total"
}

func competitionScorePeriodLabel(
    _ lifecycle: LocalCompetitionLifecyclePresentation
) -> String {
    if case .tallying = lifecycle { return "Final day" }
    return "Today"
}

enum CompetitionChartState: Equatable {
    case score(Double)
    case future
    case missing
    case missingWithScore(Double)
    case unavailable
    case unavailableWithScore(Double)
    case unscored
}

func competitionOwnerChartState(
    _ day: LocalCompetitionDayPresentation
) -> CompetitionChartState {
    switch day.ownerLatestAvailability {
    case .notYetOccurred:
        .future
    case .missing:
        day.ownerAcceptedPoints.map(CompetitionChartState.missingWithScore)
            ?? .missing
    case .unavailable:
        day.ownerAcceptedPoints.map(
            CompetitionChartState.unavailableWithScore
        ) ?? .unavailable
    case .observed:
        day.ownerAcceptedPoints.map(CompetitionChartState.score) ?? .unscored
    }
}

private func competitionChartValueText(_ state: CompetitionChartState) -> String {
    switch state {
    case let .score(points): competitionPointsText(points)
    case .future: "--"
    case .missing: "?"
    case let .missingWithScore(points): competitionPointsText(points)
    case .unavailable: "!"
    case let .unavailableWithScore(points): competitionPointsText(points)
    case .unscored: "n/a"
    }
}

func competitionDateTimeText(
    _ date: Date,
    timeZoneIdentifier: String
) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
    formatter.dateFormat = "MMM d, h:mm a z"
    return formatter.string(from: date)
}

func activityEvidenceCaption(
    _ day: LocalCompetitionDayPresentation
) -> String {
    guard let acceptedPoints = day.ownerAcceptedPoints else {
        return "Latest Activity source reading shown. No accepted score is available for this day."
    }
    if let acceptedSnapshot = day.ownerAcceptedSnapshot,
       let latestSnapshot = day.ownerLatestSnapshot,
       acceptedSnapshot != latestSnapshot {
        return "Latest Activity source reading shown. The accepted score preserves earlier source evidence under the competition scoring policy."
    }
    if day.ownerAcceptedSnapshot == nil || day.ownerLatestSnapshot == nil {
        return "Latest Activity source reading shown; accepted score \(competitionPointsAccessibilityText(acceptedPoints)). Source snapshots are unavailable for comparison."
    }
    return "Latest Activity source reading shown; accepted score \(competitionPointsAccessibilityText(acceptedPoints))."
}

private func availabilitySymbol(
    _ availability: LocalCompetitionOwnerAvailability
) -> String {
    switch availability {
    case .notYetOccurred: "clock"
    case .observed: "checkmark.circle.fill"
    case .missing: "questionmark.circle"
    case .unavailable: "exclamationmark.triangle.fill"
    }
}

private func availabilityTint(
    _ availability: LocalCompetitionOwnerAvailability
) -> Color {
    switch availability {
    case .observed: .green
    case .unavailable: .orange
    case .notYetOccurred, .missing: .secondary
    }
}

private func tallyStatusSymbol(_ attention: LocalCompetitionTallyAttention) -> String {
    switch attention {
    case .awaitingStability: "arrow.triangle.2.circlepath"
    case .noRead, .incomplete, .unacceptedScores, .opponentPlanUnavailable:
        "exclamationmark.triangle.fill"
    }
}

private func tallyStatusTint(_ attention: LocalCompetitionTallyAttention) -> Color {
    attention == .awaitingStability ? .orange : .primary
}
