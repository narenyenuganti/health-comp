import CompetitionCore
import SwiftUI

struct CompetitionDetailView: View {
    let competition: LocalCompetitionPresentation
    let source: CompetitionPublicationSource
    var muteButton: CompetitionMuteButton?

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    @State private var page: Page = .today
    @State private var drawer: Drawer? = nil

    /// Today's numbers or the whole week; the scoreboard stays above both.
    private enum Page: Hashable {
        case today
        case week
    }

    private enum Drawer: Identifiable, Hashable {
        case day(Int)
        case activitySync
        case rules

        var id: Self { self }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    CompetitionScoreboardPanel(
                        competition: competition,
                        todayDay: todayDay,
                        isProvisional: scoresAreProvisional
                    )
                    leadStatement
                }

                tallyPanel

                if case .scheduled = competition.lifecycle {
                    scheduledCard
                    weekSection
                } else {
                    Picker("Competition view", selection: $page) {
                        Text("Today").tag(Page.today)
                        Text("Week").tag(Page.week)
                    }
                    .pickerStyle(.segmented)

                    switch page {
                    case .today:
                        if let day = todayDay {
                            dayBreakdown(day)
                        }
                        ringsSection
                    case .week:
                        weekSection
                    }
                }

                muteButton?.saveFailure
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Theme.ground)
        .navigationTitle("Competition with \(competition.opponentDisplayName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let muteButton {
                        muteButton
                    }
                    Button {
                        drawer = .activitySync
                    } label: {
                        Label(
                            "Activity Sync",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    Button {
                        drawer = .rules
                    } label: {
                        Label("Rules", systemImage: "list.bullet")
                    }
                } label: {
                    CompetitionMoreLabel()
                }
                .accessibilityIdentifier("competition.more")
            }
        }
        .sheet(item: $drawer) { item in
            switch item {
            case let .day(ordinal):
                dayDrawer(ordinal)
            case .activitySync:
                activitySyncDrawer
            case .rules:
                CompetitionDrawer(title: "Rules") {
                    CompetitionRulesCard(source: source)
                }
            }
        }
    }

    @ViewBuilder
    private var leadStatement: some View {
        if competitionShouldShowScores(competition.lifecycle) {
            leadText
                .font(.body)
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var leadText: Text {
        let margin = competition.userPoints - competition.opponentPoints
        let points = Text(competitionPointsText(abs(margin))).fontWeight(.bold)
        if margin > 0 {
            return Text("You lead by ") + points.foregroundStyle(Theme.you)
                + Text(".")
        }
        if margin < 0 {
            return Text("\(competition.opponentDisplayName) leads by ")
                + points.foregroundStyle(Theme.ink) + Text(".")
        }
        return Text("All square.")
    }

    @ViewBuilder
    private var tallyPanel: some View {
        if let tally = competition.tally {
            VStack(alignment: .leading, spacing: 8) {
                if let attention = tally.attention {
                    Label(
                        competitionTallyAttentionText(
                            attention,
                            opponentDisplayName: competition.opponentDisplayName,
                            source: source
                        ),
                        systemImage: tallyStatusSymbol(attention)
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                }
                Text(
                    competitionTallyDeadlineText(
                        tally,
                        locale: locale,
                        timeZone: timeZone,
                        opponentDisplayName: competition.opponentDisplayName,
                        source: source
                    )
                )
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .themePanel(cornerRadius: 16)
        }
    }

    private var scheduledCard: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                if let schedule = competition.acceptedConfiguration?.schedule,
                   let dateRange = competitionScheduleDateRangeText(
                       schedule, locale: locale, timeZone: timeZone
                   ) {
                    Text(dateRange)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("competition.schedule.dates")
                } else {
                    Text("Starts next competition day")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Text("Your stored schedule sets the seven competition days.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                }
            }
        } icon: {
            Image(systemName: "calendar.badge.clock")
                .font(.title2)
                .foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .themePanel(cornerRadius: 16)
    }

    // "How the day adds up" needs the accepted snapshot to split its points
    // by ring; without it the week chart already shows the total.
    @ViewBuilder
    private func dayBreakdown(
        _ day: LocalCompetitionDayPresentation
    ) -> some View {
        if competitionShouldShowScores(competition.lifecycle),
           let total = day.ownerAcceptedPoints,
           let snapshot = day.ownerAcceptedSnapshot {
            let segments = ringSegments(day)
            if segments.count == 3 {
                TodayBreakdown(
                    title: day.ordinal == competition.currentDayOrdinal
                        ? "HOW TODAY ADDS UP"
                        : "HOW DAY \(day.ordinal) ADDED UP",
                    segments: segments.map { $0.points },
                    labels: ringLabels(snapshot),
                    total: total,
                    opponentName: competition.opponentDisplayName,
                    opponentPoints: day.opponentRevealedPoints
                )
            }
        }
    }

    private var weekSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("THE WEEK")
            CompetitionWeekChart(
                days: competition.days,
                currentDayOrdinal: competition.currentDayOrdinal,
                ownerName: competition.ownerDisplayName,
                opponentName: competition.opponentDisplayName,
                showsDates: true,
                selectDay: { drawer = .day($0.ordinal) }
            )
            CompetitionRingLegend(opponentName: competition.opponentDisplayName)
        }
    }

    private var ringsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(ringsTitle)
            ringsPanel(activityDay)
        }
    }

    private func ringsPanel(
        _ day: LocalCompetitionDayPresentation?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let day,
               case .observed = day.ownerLatestAvailability,
               let snapshot = day.ownerLatestSnapshot {
                ActivityRingsView(
                    snapshot: snapshot,
                    ownerDisplayName: competition.ownerDisplayName,
                    acceptedPoints: day.ownerAcceptedPoints
                )
            } else if let day {
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
                .foregroundStyle(Theme.secondary)
                .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .themePanel()
    }

    @ViewBuilder
    private func evidenceCaption(
        _ day: LocalCompetitionDayPresentation?
    ) -> some View {
        if let day,
           case .observed = day.ownerLatestAvailability,
           day.ownerLatestSnapshot != nil {
            Text(activityEvidenceCaption(day))
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func dayDrawer(_ ordinal: Int) -> some View {
        if let day = competition.days.first(where: { $0.ordinal == ordinal }) {
            CompetitionDrawer(
                title: "Day \(day.ordinal)",
                subtitle: competitionDayDateText(day.day)
            ) {
                CompetitionWeekChart(
                    days: [day],
                    currentDayOrdinal: competition.currentDayOrdinal,
                    ownerName: competition.ownerDisplayName,
                    opponentName: competition.opponentDisplayName
                )
                dayBreakdown(day)
                ringsPanel(day)
                evidenceCaption(day)
            }
        }
    }

    private var activitySyncDrawer: some View {
        CompetitionDrawer(title: "Activity Sync") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(
                    Array(
                        competitionRefreshTimelineText(
                            lastRefresh: competition.lastRefresh,
                            lastSuccessfulFullWindowRefreshAt: competition.lastSuccessfulFullWindowRefreshAt,
                            locale: locale,
                            timeZone: timeZone
                        ).enumerated()
                    ),
                    id: \.offset
                ) { offset, line in
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(
                            offset == 0
                                ? "competition.lastSync"
                                : "competition.lastSync.\(offset)"
                        )
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themePanel(cornerRadius: 18)

            evidenceCaption(activityDay)
        }
    }

    private var ringsTitle: String {
        guard let day = activityDay else { return "YOUR RINGS" }
        return day.ordinal == competition.currentDayOrdinal
            ? "YOUR RINGS · TODAY"
            : "YOUR RINGS · DAY \(day.ordinal)"
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
}

/// Mutes one person, so every match with them goes quiet, not just this one.
/// It sits in a match's ••• menu.
struct CompetitionMuteButton: View {
    let opponentName: String
    let isMuted: Bool
    let isInFlight: Bool
    let saveFailed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Label(
                isMuted
                    ? "Unmute \(opponentName) Notifications"
                    : "Mute \(opponentName) Notifications",
                systemImage: isMuted ? "bell.fill" : "bell.slash.fill"
            )
        }
        .disabled(isInFlight)
        .accessibilityIdentifier("competition.notifications.mute")
    }

    /// The menu closes before the save finishes, so a failure shows on the page.
    @ViewBuilder
    var saveFailure: some View {
        if saveFailed {
            Label(
                "Notification preference could not be saved.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(Theme.secondary)
            .accessibilityIdentifier(
                "competition.notifications.preference-error"
            )
        }
    }
}

/// The ••• that holds a match's less frequent actions.
struct CompetitionMoreLabel: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Theme.ink)
            .frame(width: 34, height: 34)
            .background(Theme.control, in: Circle())
            .accessibilityLabel("More")
    }
}

/// A bottom drawer on the ground surface: a title, a close button and
/// content that scrolls once it outgrows the half-height detent.
struct CompetitionDrawer<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.title2.weight(.heavy).width(.condensed))
                            .foregroundStyle(Theme.ink)
                            .accessibilityAddTraits(.isHeader)
                        if let subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    CompetitionDrawerCloseButton { dismiss() }
                }
                content
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.ground)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.ground)
    }
}

struct CompetitionDrawerCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 30, height: 30)
                .background(Theme.control, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

/// The person a match's mute button silences. Nil hides the button while
/// notifications are off or an invitation is still waiting for someone.
func competitionMuteIdentity(
    _ competition: LocalCompetitionPresentation,
    authorization: CompetitionNotificationAuthorizationState?
) -> String? {
    guard authorization?.permitsNotifications == true,
          !competition.opponentIdentity.hasSuffix(":pending")
    else {
        return nil
    }
    return competition.opponentIdentity
}

private struct CompetitionScoreboardPanel: View {
    let competition: LocalCompetitionPresentation
    let todayDay: LocalCompetitionDayPresentation?
    let isProvisional: Bool

    @ScaledMetric(relativeTo: .largeTitle) private var scoreSize: CGFloat = 56
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusRow
            if competitionShouldShowScores(competition.lifecycle) {
                scoreboard
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                    .accessibilityHidden(true)
                periodRow
            } else {
                Label("Scores begin Day 1", systemImage: "clock")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themePanel()
    }

    // AnyLayout, not ViewThatFits: the XCTest Dynamic Type audit flags
    // text that ViewThatFits swaps out while it cycles sizes.
    private var statusRow: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            statusTitle
                .frame(maxWidth: .infinity, alignment: .leading)
            endText
        }
        .font(.themeLabel)
        .tracking(1.2)
    }

    // The lifecycle title stays its own text: "Day 1", "Ends Today",
    // "Tallying Points" and "Scheduled" are what people and tests look for.
    private var statusTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isLive {
                Circle()
                    .fill(Theme.ink)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            Text(competitionDetailTitle(competition.lifecycle))
                .foregroundStyle(Theme.ink)
            if case .active = competition.lifecycle {
                Text("of 7")
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    @ViewBuilder
    private var endText: some View {
        if case .active = competition.lifecycle,
           let schedule = competition.acceptedConfiguration?.schedule,
           let end = competitionScheduleBoundaries(schedule)?.end {
            Text("ENDS \(competitionDateTimeText(end, locale: locale, timeZone: timeZone))")
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scoreboard: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 12))
        return layout {
            ownerBlock
                .frame(maxWidth: .infinity, alignment: .leading)
            if !stacked {
                SlantedBar()
                    .fill(Theme.outline)
                    .frame(width: 3, height: scoreSize)
                    .accessibilityHidden(true)
            }
            opponentBlock(alignment: stacked ? .leading : .trailing)
                .frame(maxWidth: .infinity, alignment: stacked ? .leading : .trailing)
        }
    }

    private var ownerBlock: some View {
        scoreBlock(
            name: competition.ownerDisplayName,
            today: todayDay?.ownerAcceptedPoints,
            total: competition.userPoints,
            color: Theme.you,
            alignment: .leading,
            identifier: "competition.scoreHeader.naren"
        )
    }

    private func opponentBlock(alignment: HorizontalAlignment) -> some View {
        scoreBlock(
            name: competition.opponentDisplayName,
            today: todayDay?.opponentRevealedPoints,
            total: competition.opponentPoints,
            color: Theme.ink,
            alignment: alignment,
            identifier: "competition.scoreHeader.alex"
        )
    }

    private func scoreBlock(
        name: String,
        today: Double?,
        total: Double,
        color: Color,
        alignment: HorizontalAlignment,
        identifier: String
    ) -> some View {
        // Names may wrap at large sizes; scores never do.
        VStack(alignment: alignment, spacing: 4) {
            Text(name.uppercased())
                .font(.themeLabel)
                .tracking(1.4)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            Text(competitionPointsText(total))
                .font(.score(size: scoreSize).monospacedDigit())
                .fixedSize()
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(
            "\(name), \(periodLabel) \(competitionPointsAccessibilityText(today)), \(competitionScoreTotalLabel(isProvisional: isProvisional).lowercased()) \(competitionPointsAccessibilityText(total))"
        )
    }

    // Visual only: each score block's label already speaks the period points.
    private var periodRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ownerPeriodPoints
                Spacer(minLength: 8)
                periodTitle
                Spacer(minLength: 8)
                opponentPeriodPoints
            }
            VStack(alignment: .leading, spacing: 4) {
                periodTitle
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    ownerPeriodPoints
                    opponentPeriodPoints
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var ownerPeriodPoints: some View {
        Text(competitionPointsText(todayDay?.ownerAcceptedPoints))
            .font(.title.weight(.heavy).width(.condensed).monospacedDigit())
            .foregroundStyle(Theme.you)
            .fixedSize()
    }

    private var opponentPeriodPoints: some View {
        Text(competitionPointsText(todayDay?.opponentRevealedPoints))
            .font(.title.weight(.heavy).width(.condensed).monospacedDigit())
            .foregroundStyle(Theme.ink)
            .fixedSize()
    }

    private var periodTitle: some View {
        Text(periodLabel.uppercased())
            .font(.themeLabel)
            .tracking(1.2)
            .foregroundStyle(Theme.secondary)
            .fixedSize()
    }

    private var periodLabel: String {
        competitionScorePeriodLabel(competition.lifecycle)
    }

    private var isLive: Bool {
        switch competition.lifecycle {
        case .active, .endsToday: true
        default: false
        }
    }
}

/// Move + Exercise + Stand = the day's accepted points, as ring-colored
/// blocks. The opponent only shares a total, so theirs is one neutral block.
private struct TodayBreakdown: View {
    let title: String
    let segments: [Double]
    let labels: [String]
    let total: Double
    let opponentName: String
    let opponentPoints: Double?

    @ScaledMetric(relativeTo: .title) private var blockNumber: CGFloat = 26
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let colors = [Theme.move, Theme.exercise, Theme.stand]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title)
            // A size switch, not ViewThatFits, which the Dynamic Type audit
            // flags. The equation fits a 375pt phone through xLarge.
            VStack(alignment: .leading, spacing: 0) {
                if dynamicTypeSize >= .xxLarge { list } else { equation }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(labels[0].capitalized) \(competitionPointsText(segments[0])) plus \(labels[1].capitalized) \(competitionPointsText(segments[1])) plus \(labels[2].capitalized) \(competitionPointsText(segments[2])) equals \(competitionPointsAccessibilityText(total))."
            )
            if let opponentPoints {
                opponentRow(opponentPoints)
            }
        }
    }

    private var equation: some View {
        HStack(alignment: .top, spacing: 6) {
            block(0)
            operatorText("+")
            block(1)
            operatorText("+")
            block(2)
            operatorText("=")
            VStack(spacing: 6) {
                Text(competitionPointsText(total))
                    .font(.score(size: blockNumber * 1.4).monospacedDigit())
                    .foregroundStyle(Theme.you)
                    .frame(minHeight: 50)
                Text("POINTS")
                    .font(.themeLabel)
                    .tracking(1)
                    .foregroundStyle(Theme.secondary)
            }
            .fixedSize()
        }
    }

    private func block(_ index: Int) -> some View {
        VStack(spacing: 6) {
            Text(competitionPointsText(segments[index]))
                .font(.score(size: blockNumber).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(minWidth: 60, minHeight: 50)
                .background(SlantedBar().fill(colors[index]))
            Text(labels[index])
                .font(.themeLabel)
                .tracking(1)
                .foregroundStyle(Theme.secondary)
        }
        .fixedSize()
    }

    private func operatorText(_ symbol: String) -> some View {
        Text(symbol)
            .font(.title2.weight(.bold))
            .foregroundStyle(Theme.tertiary)
            .frame(minHeight: 50)
            .fixedSize()
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 10) {
                    SlantedBar()
                        .fill(colors[index])
                        .frame(width: 14, height: 14)
                    Text(labels[index].capitalized)
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 8)
                    Text(competitionPointsText(segments[index]))
                        .foregroundStyle(Theme.ink)
                }
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 10) {
                Text("Points")
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Text(competitionPointsText(total))
                    .foregroundStyle(Theme.you)
            }
        }
        .font(.headline.monospacedDigit())
        .padding(16)
        .themePanel(cornerRadius: 16)
    }

    private func opponentRow(_ points: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            opponentBlock(points)
            opponentNote
        }
        .accessibilityElement(children: .combine)
    }

    private func opponentBlock(_ points: Double) -> some View {
        Text(competitionPointsText(points))
            .font(.score(size: blockNumber * 0.85).monospacedDigit())
            .foregroundStyle(Theme.onInk)
            .padding(.horizontal, 12)
            .frame(minWidth: 60, minHeight: 36)
            .background(SlantedBar().fill(Theme.ink))
            .fixedSize()
    }

    private var opponentNote: some View {
        Text("\(opponentName)’s points. Their ring detail stays on their iPhone.")
            .font(.subheadline)
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func ringLabels(_ snapshot: ActivitySnapshot) -> [String] {
    let stand = snapshot.standMode == .rollHours ? "ROLL" : "STAND"
    return ["MOVE", "EXERCISE", stand]
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
    } else if day.ownerLatestAvailability == .notYetOccurred {
        opponent = "\(opponentName), future, --"
    } else {
        opponent = "\(opponentName), score not available, --"
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
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String? {
    guard let boundaries = competitionScheduleBoundaries(schedule) else {
        return nil
    }
    return competitionDateRangeText(
        boundaries.start, boundaries.end, locale: locale, timeZone: timeZone
    )
}

func competitionScheduleBoundaries(
    _ schedule: CompetitionSchedule
) -> (start: Date, end: Date)? {
    guard let days = try? schedule.calendar.sevenDayWindow(
        startingOn: schedule.startDay
    ),
        let first = days.first,
        let last = days.last,
        let firstDate = try? schedule.calendar.startOfDay(first),
        let dayAfterLast = try? schedule.calendar.day(after: last),
        let endDate = try? schedule.calendar.startOfDay(dayAfterLast)
    else {
        return nil
    }
    return (firstDate, endDate)
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
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> [String] {
    var lines: [String] = []
    if let lastRefresh {
        lines.append(
            "Latest Activity check \(competitionDateTimeText(lastRefresh.readAt, locale: locale, timeZone: timeZone)): \(competitionRefreshStatusText(lastRefresh.status))"
        )
    }
    if let lastSuccessfulFullWindowRefreshAt {
        lines.append(
            "Last complete Activity read \(competitionDateTimeText(lastSuccessfulFullWindowRefreshAt, locale: locale, timeZone: timeZone))."
        )
    } else if lastRefresh == nil {
        lines.append("No Activity check yet.")
    }
    return lines
}

func competitionTallyDeadlineText(
    _ tally: LocalCompetitionTallyPresentation,
    locale: Locale = .current,
    timeZone: TimeZone = .current,
    opponentDisplayName: String = LocalCompetitionIdentity.opponentDisplayName,
    source: CompetitionPublicationSource = .simulatedFixture
) -> String {
    let deadline = competitionDateTimeText(
        tally.bestAvailableDeadline,
        locale: locale,
        timeZone: timeZone
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

// Neutral by design: color is reserved for you and your rings.
private func availabilityTint(
    _ availability: LocalCompetitionOwnerAvailability
) -> Color {
    switch availability {
    case .observed, .unavailable: Theme.ink
    case .notYetOccurred, .missing: Theme.secondary
    }
}

private func tallyStatusSymbol(_ attention: LocalCompetitionTallyAttention) -> String {
    switch attention {
    case .awaitingStability: "arrow.triangle.2.circlepath"
    case .noRead, .incomplete, .unacceptedScores, .opponentPlanUnavailable:
        "exclamationmark.triangle.fill"
    }
}
