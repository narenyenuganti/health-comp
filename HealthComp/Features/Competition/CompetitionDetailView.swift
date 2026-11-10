import CompetitionCore
import SwiftUI

/// Flat segments in the app's own surfaces, in place of the system's picker.
private struct CompetitionSegments<Selection: Hashable>: View {
    @Binding var selection: Selection
    let options: [(value: Selection, title: String)]

    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.subheadline.weight(.semibold).width(.condensed))
                        .foregroundStyle(isSelected ? Theme.ink : Theme.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Theme.ground)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .moving(Motion.settle, value: selection)
    }
}

struct CompetitionDetailView: View {
    let competition: LocalCompetitionPresentation
    let source: CompetitionPublicationSource
    var muteButton: CompetitionMuteButton?
    var issue: CompetitionRowIssue? = nil
    var retry: (() async -> Void)? = nil
    /// Pull to refresh on the match screen only; drawers don't inherit it.
    var refresh: (@Sendable () async -> Void)?
    /// Real scheduled matches only: Cancel Match in the ••• menu.
    var cancelMatch: CompetitionCancelMatch? = nil
    /// Real matches only: one nudge a day when the other person's score is stale.
    var nudge: CompetitionNudge? = nil
    /// Real matches only: reactions on the other person's days.
    var reactions: CompetitionReactionControl? = nil
    /// Practice only: End Practice in the ••• menu.
    var endPractice: (() -> Void)? = nil
    /// Real matches only: Report Photo in the ••• menu, while their photo shows.
    var reportPhoto: CompetitionReportPhoto? = nil
    /// The menu's first item, once a week with them has finished. This week
    /// isn't in it until it has a final result.
    var recordLink: CompetitionRecordLink? = nil
    var replayIntro: (() -> Void)? = nil

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @State private var page: Page = .today
    @State private var drawer: Drawer? = nil
    @State private var showsCancelConfirmation = false
    @AppStorage(CompetitionReactionsSeen.storageKey)
    private var reactionsSeen = CompetitionReactionsSeen()
    @AppStorage(CompetitionMotionSeen.storageKey)
    private var motionSeen = CompetitionMotionSeen()
    /// Week has shown on this visit, so later flips and new days settle.
    @State private var weekShown = false
    @State private var showsEndPracticeConfirmation = false
    @State private var showsReportPhotoConfirmation = false
    /// The day you last clapped from the Week list, for the line under it.
    @State private var clappedDay: Int?
    @Environment(\.profilePhotos) private var photos

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
                if let issue {
                    CompetitionIssueLine(issue: issue, retry: retry, id: competition.id)
                        .transition(Motion.appear)
                }

                muteButton?.failureNote
                    .transition(Motion.appear)

                VStack(alignment: .leading, spacing: 12) {
                    CompetitionScoreboardPanel(
                        competition: competition,
                        todayDay: todayDay,
                        isProvisional: scoresAreProvisional,
                        isMuted: muteButton?.isMuted == true
                    )
                    leadStatement
                    freshnessLine
                    liveNudge
                    if cancelMatch?.failed == true {
                        Text("Couldn’t cancel the match. It may have already started.")
                            .font(.callout)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("competition.cancel.error")
                            .transition(Motion.appear)
                    }
                }

                latestReaction

                tallyPanel

                if competitionShouldShowScores(competition.lifecycle) {
                    CompetitionSegments(
                        selection: $page,
                        options: [(Page.today, todayTabTitle), (Page.week, "Week")]
                    )
                    .transition(Motion.appear)

                    ZStack(alignment: .topLeading) {
                        switch page {
                        case .today:
                            todayActivity
                                .transition(Motion.appear)
                        case .week:
                            weekSection
                                .transition(Motion.appear)
                        }
                    }
                    .transition(Motion.appear)
                }
            }
            .moving(Motion.settle, value: layoutKey)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .refreshable(refresh)
        // Back or pop, not a drawer: the line stays while you're here.
        .onDisappear { reactionsSeen = reactionsSeen.marking(competition) }
        .competitionReactionRain(
            incoming: reactions == nil ? nil : competitionReactionRainBatch(
                [competition], seen: reactionsSeen, motionSeen: motionSeen
            ),
            rained: { motionSeen = motionSeen.raining([competition]) }
        )
        .background(Theme.ground)
        .navigationTitle(competition.opponentDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let recordLink {
                        Button(action: recordLink.open) {
                            Label(recordLink.title, systemImage: "chart.bar")
                        }
                        .accessibilityLabel(recordLink.accessibilityLabel)
                        .accessibilityIdentifier("competition.record-link")
                    }
                    if let replayIntro {
                        Button(action: replayIntro) {
                            Label("Replay intro", systemImage: "arrow.counterclockwise")
                        }
                        .accessibilityIdentifier("competition.versus.replay")
                    }
                    if let muteButton {
                        muteButton
                    }
                    reportPhotoItem
                    Button {
                        drawer = .activitySync
                    } label: {
                        Label(
                            "Sync status",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    Button {
                        drawer = .rules
                    } label: {
                        Label("How scoring works", systemImage: "list.bullet")
                    }
                    if let cancelMatch, case .scheduled = competition.lifecycle {
                        Button(role: .destructive) {
                            showsCancelConfirmation = true
                        } label: {
                            Label("Cancel Match", systemImage: "xmark.circle")
                        }
                        .disabled(cancelMatch.isInFlight)
                        .accessibilityIdentifier("competition.match.cancel")
                    }
                    if endPractice != nil {
                        Button(role: .destructive) {
                            showsEndPracticeConfirmation = true
                        } label: {
                            Label("End Practice", systemImage: "xmark.circle")
                        }
                        .accessibilityIdentifier("competition.practice.end")
                    }
                } label: {
                    CompetitionMoreLabel()
                }
                .accessibilityIdentifier("competition.more")
            }
        }
        .confirmationDialog(
            "Cancel your match with \(competition.opponentDisplayName)?",
            isPresented: $showsCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("Cancel Match", role: .destructive) { cancelMatch?.cancel() }
            Button("Keep Match", role: .cancel) {}
        } message: {
            Text("It hasn’t started yet. \(competition.opponentDisplayName) will be told.")
        }
        .confirmationDialog(
            "Report \(competition.opponentDisplayName)’s photo?",
            isPresented: $showsReportPhotoConfirmation,
            titleVisibility: .visible
        ) {
            Button("Report Photo", role: .destructive) { reportPhoto?.report() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won’t see \(competition.opponentDisplayName)’s photo again. We’ll review it. \(competition.opponentDisplayName) isn’t notified.")
        }
        .onChange(of: reportPhoto?.isReported == true) { old, new in
            if !old, new {
                AccessibilityNotification.Announcement(
                    "Photo reported. You’ll see \(competition.opponentDisplayName)’s initial instead."
                ).post()
            }
        }
        .confirmationDialog(
            "End this practice match?",
            isPresented: $showsEndPracticeConfirmation,
            titleVisibility: .visible
        ) {
            Button("End Practice", role: .destructive) { endPractice?() }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("It’s removed from this iPhone.")
        }
        .sheet(item: $drawer) { item in
            switch item {
            case let .day(ordinal):
                dayDrawer(ordinal)
                    .competitionReactionRain()
            case .activitySync:
                activitySyncDrawer
            case .rules:
                CompetitionDrawer(title: "How scoring works") {
                    CompetitionRulesCard(
                        source: source,
                        opponentName: competition.opponentDisplayName,
                        weekText: competition.acceptedConfiguration.flatMap {
                            competitionScheduleDateRangeText(
                                $0.schedule, now: competition.evaluatedAt, locale: locale
                            )
                        }
                    )
                }
            }
        }
    }

    /// Only while their photo shows; after a report, a dimmed Photo Reported.
    @ViewBuilder
    private var reportPhotoItem: some View {
        if let reportPhoto {
            if reportPhoto.isReported {
                Button {} label: {
                    Label("Photo Reported", systemImage: "checkmark.circle")
                }
                .disabled(true)
                .accessibilityIdentifier("competition.match.report-photo")
            } else if photos.photo(competition.opponentProfileID) != nil {
                Button {
                    showsReportPhotoConfirmation = true
                } label: {
                    Label(
                        "Report \(competition.opponentDisplayName)’s Photo",
                        systemImage: "exclamationmark.bubble"
                    )
                }
                .disabled(reportPhoto.isInFlight)
                .accessibilityIdentifier("competition.match.report-photo")
            }
        }
    }

    /// What changes the page's height. Never `competition`: it differs on
    /// every publication and would animate every time-derived string.
    private struct LayoutKey: Equatable {
        let hasIssue: Bool
        let muteFailure: CompetitionMuteFailure?
        let cancelFailed: Bool
        let showsScores: Bool
        let isProvisional: Bool
        let nudge: CompetitionNudgeDisplay?
        let tally: String?
        let takes: String?
        let reaction: Date?
        let hasRings: Bool?
        let availability: LocalCompetitionOwnerAvailability?
    }

    private var layoutKey: LayoutKey {
        LayoutKey(
            hasIssue: issue != nil,
            muteFailure: muteButton?.failure,
            cancelFailed: cancelMatch?.failed == true,
            showsScores: competitionShouldShowScores(competition.lifecycle),
            isProvisional: scoresAreProvisional,
            nudge: nudgeDisplay,
            tally: tallyCopy?.headline,
            takes: competitionWhatItTakes(competition, locale: locale)?.headline,
            reaction: competitionUnseenReaction(competition, seen: reactionsSeen)?.updatedAt,
            hasRings: activityDay.map { competitionRingPanel($0, locale: locale) != nil },
            availability: activityDay?.ownerLatestAvailability
        )
    }

    @ViewBuilder
    private var leadStatement: some View {
        if competitionShouldShowScores(competition.lifecycle) {
            let side = competitionLeadSide(
                userPoints: competition.userPoints,
                opponentPoints: competition.opponentPoints
            )
            let margin = competitionDisplayedMargin(
                userPoints: competition.userPoints,
                opponentPoints: competition.opponentPoints
            )
            // Same side, the margin rolls. A new side is a new id, and only a
            // parent can animate that: the sentence follows the digits.
            ZStack(alignment: .leading) {
                leadText
                    .scoreRoll(abs(margin), id: side)
            }
            .animation(Motion.late, value: side)
            .font(.body)
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sensoryFeedback(.impact(weight: .medium), trigger: side) { old, new in
                new == .you && old != .you
            }
        }
    }

    @ViewBuilder
    private var freshnessLine: some View {
        if competitionShouldShowScores(competition.lifecycle),
           let text = competitionFreshnessText(competition, locale: locale, timeZone: timeZone) {
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("competition.updated")
        }
    }

    private var leadText: Text {
        competitionLeadText(
            userPoints: competition.userPoints,
            opponentPoints: competition.opponentPoints,
            opponentDisplayName: competition.opponentDisplayName,
            locale: locale
        ) + Text(scoresAreProvisional ? " Not final yet." : "")
    }

    /// The newest day reaction you haven't seen; it opens that day.
    @ViewBuilder
    private var latestReaction: some View {
        if reactions != nil,
           let unseen = competitionUnseenReaction(competition, seen: reactionsSeen),
           let day = unseen.target.dayOrdinal {
            Button { drawer = .day(day) } label: {
                HStack(spacing: 8) {
                    CompetitionReactionLine(
                        reaction: unseen,
                        opponentName: competition.opponentDisplayName
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(CompetitionRowButtonStyle())
            .accessibilityLabel(
                competitionReactionAccessibilityText(
                    unseen,
                    opponentName: competition.opponentDisplayName
                )
            )
            .accessibilityHint("Opens Day \(day)")
            .accessibilityIdentifier("competition.reaction.latest")
            .transition(Motion.appear)
        }
    }

    // Who or what the result waits on, and whether you need to act.
    @ViewBuilder
    private var tallyPanel: some View {
        if let copy = tallyCopy {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy.headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(copy.body)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("competition.tally")
                nudgeControl
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .themePanel()
            .transition(Motion.appear)
        }
    }

    private var tallyCopy: CompetitionTallyCopy? {
        competition.tally.map {
            competitionTallyCopy(
                $0,
                opponentDisplayName: competition.opponentDisplayName,
                now: competition.evaluatedAt,
                locale: locale,
                timeZone: timeZone
            )
        }
    }

    /// Under the freshness line while the match is live; the tally panel has its own.
    @ViewBuilder
    private var liveNudge: some View {
        switch competition.lifecycle {
        case .active, .endsToday: nudgeControl
        default: EmptyView()
        }
    }

    @ViewBuilder
    private var nudgeControl: some View {
        if let nudge, let display = nudgeDisplay {
            CompetitionNudgeControl(
                display: display,
                name: competition.opponentDisplayName,
                send: nudge.send
            )
            .transition(Motion.appear)
        }
    }

    private var nudgeDisplay: CompetitionNudgeDisplay? {
        nudge.flatMap {
            competitionNudgeDisplay(
                $0.status, competition: competition, locale: locale, timeZone: timeZone
            )
        }
    }

    /// The Week: your bars grow only when the week has gained a day since they
    /// last drew, and only on the first flip of a visit. Latched on that flip:
    /// a day landing while Week is open settles, it never holds bars at zero.
    private var weekGrows: Bool {
        !weekShown && !reduceMotion && !voiceOver && motionSeen.weekGained(competition)
    }

    private var weekSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let lead = competitionLeadLine(
                competition.days, currentDayOrdinal: competition.currentDayOrdinal
            ) {
                CompetitionLeadLineView(
                    line: lead,
                    days: competition.days,
                    currentDayOrdinal: competition.currentDayOrdinal,
                    opponentName: competition.opponentDisplayName,
                    isDrawn: !weekGrows
                )
                .padding(.bottom, 12)
            }
            SectionLabel("THE WEEK")
            CompetitionWeekChart(
                days: competition.days,
                currentDayOrdinal: competition.currentDayOrdinal,
                now: competition.evaluatedAt,
                opponentName: competition.opponentDisplayName,
                showsDates: true,
                isGrown: !weekGrows,
                selectDay: { drawer = .day($0.ordinal) },
                clap: weekClap
            )
            weekClapNote
            CompetitionRingLegend(
                days: competition.days,
                opponentName: competition.opponentDisplayName
            )
        }
        .onAppear {
            // Only a real draw closes the gate for the day.
            if weekGrows { motionSeen = motionSeen.drawingWeek(competition) }
            weekShown = true
        }
    }

    @ViewBuilder
    private var todayActivity: some View {
        if let day = activityDay {
            VStack(alignment: .leading, spacing: 12) {
                if let takes = competitionWhatItTakes(competition, locale: locale) {
                    CompetitionWhatItTakesPanel(takes: takes)
                        .transition(Motion.appear)
                }
                dayActivity(day, showsPullHint: true)
            }
        } else {
            Label("Activity appears when Day 1 begins.", systemImage: "clock")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(16)
                .themePanel()
        }
    }

    private func dayActivity(
        _ day: LocalCompetitionDayPresentation,
        showsPullHint: Bool
    ) -> some View {
        ZStack(alignment: .topLeading) {
            dayPanel(day, showsPullHint: showsPullHint)
                .transition(Motion.appear)
        }
    }

    /// The day's ring panel, or one line saying why there isn't one.
    @ViewBuilder
    private func dayPanel(
        _ day: LocalCompetitionDayPresentation,
        showsPullHint: Bool
    ) -> some View {
        if let panel = competitionRingPanel(day, locale: locale) {
            // A new day is a new panel: 420 never rolls down to 0 at midnight.
            ActivityRingsView(panel: panel)
                .id(day.ordinal)
        } else if day.ownerLatestAvailability == .notSyncedYet {
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    competitionOwnerAvailabilityText(.notSyncedYet, ordinal: day.ordinal),
                    systemImage: availabilitySymbol(.notSyncedYet)
                )
                .font(.headline)
                .foregroundStyle(Theme.ink)
                if showsPullHint {
                    Text("Your rings update as you move. Pull down to check now.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(16)
            .themePanel()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("competition.notSynced")
        } else {
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
            .padding(16)
            .themePanel()
        }
    }

    @ViewBuilder
    private func dayDrawer(_ ordinal: Int) -> some View {
        if let day = competition.days.first(where: { $0.ordinal == ordinal }) {
            CompetitionDrawer(
                title: "Day \(day.ordinal)",
                subtitle: competitionDayText(
                    day.day, now: competition.evaluatedAt, locale: locale, timeZone: timeZone
                )
            ) {
                CompetitionWeekChart(
                    days: [day],
                    currentDayOrdinal: competition.currentDayOrdinal,
                    now: competition.evaluatedAt,
                    opponentName: competition.opponentDisplayName
                )
                if let reactions {
                    dayReactions(ordinal, control: reactions)
                }
                dayActivity(day, showsPullHint: false)
            }
            .moving(Motion.settle, value: reactions?.failed.contains(.day(ordinal)))
        }
    }

    /// Claps from the Week list go with the day reactions.
    private var weekClap: CompetitionDayClap? {
        guard let reactions, allowsDayReactions else { return nil }
        return CompetitionDayClap(
            sent: { reactions.selection(.day($0), in: competition) },
            isPending: { reactions.pending[.day($0)] != nil },
            send: { ordinal in
                clappedDay = ordinal
                reactions.react(.day(ordinal), .clap)
                if let text = clapNoteText(ordinal) {
                    AccessibilityNotification.Announcement(text).post()
                }
            }
        )
    }

    private func clapNoteText(_ ordinal: Int) -> String? {
        competition.days.first { $0.ordinal == ordinal }.map {
            "You clapped \(competition.opponentDisplayName)’s \(weekdayName($0.day, locale: locale))"
        }
    }

    /// What your last clap from the list sent, or why it didn't.
    @ViewBuilder
    private var weekClapNote: some View {
        if let ordinal = clappedDay, let reactions, allowsDayReactions,
           let text = clapNoteText(ordinal) {
            if reactions.failed.contains(.day(ordinal)) {
                Label("Couldn’t send your reaction. Try again.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("competition.week.clap.error")
                    .transition(Motion.appear)
            } else if reactions.selection(.day(ordinal), in: competition) == .clap {
                HStack(spacing: 10) {
                    CompetitionReactionEmoji(kind: .clap)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(text)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text("Open a day for all four reactions.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .themePanel(cornerRadius: 14)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("competition.week.clap.sent")
                .transition(Motion.appear)
            }
        }
    }

    /// Day reactions close when the result lands (the server agrees).
    private var allowsDayReactions: Bool {
        switch competition.lifecycle {
        case .active, .endsToday, .tallying: competitionCanReact(competition)
        default: false
        }
    }

    /// The reaction you got on this day, and yours to send while you can.
    @ViewBuilder
    private func dayReactions(
        _ ordinal: Int,
        control: CompetitionReactionControl
    ) -> some View {
        let name = competition.opponentDisplayName
        let received = competition.receivedReaction(.day(ordinal))
        let canReact = allowsDayReactions
        if received != nil || canReact {
            VStack(alignment: .leading, spacing: 10) {
                if let received {
                    CompetitionReactionLine(
                        reaction: received,
                        opponentName: name,
                        id: "competition.reaction.received"
                    )
                }
                if canReact {
                    CompetitionReactionLabel("REACT TO \(name.uppercased(with: locale))’S DAY")
                    control.picker(.day(ordinal), in: competition)
                    Text("\(name) sees your reaction on this day.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var activitySyncDrawer: some View {
        CompetitionDrawer(title: "Sync status") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(
                    Array(
                        competitionRefreshTimelineText(
                            lastRefresh: competition.lastRefresh,
                            lastSuccessfulFullWindowRefreshAt: competition.lastSuccessfulFullWindowRefreshAt,
                            now: competition.evaluatedAt,
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
            .themePanel()
        }
    }

    /// "Today" while a day is live, else the day it shows: "Day 7".
    private var todayTabTitle: String {
        todayDay.map {
            $0.ordinal == competition.currentDayOrdinal ? "Today" : "Day \($0.ordinal)"
        } ?? "Today"
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

extension View {
    @ViewBuilder
    func refreshable(_ action: (@Sendable () async -> Void)?) -> some View {
        if let action {
            refreshable(action: action)
        } else {
            self
        }
    }
}

enum CompetitionMuteFailure: Equatable, Sendable {
    case load
    case mute
    case unmute
}

/// Mutes one person, so every match with them goes quiet, not just this one.
/// It sits in a match's ••• menu.
struct CompetitionMuteButton: View {
    let opponentName: String
    let isMuted: Bool
    let isInFlight: Bool
    let failure: CompetitionMuteFailure?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Label(
                isMuted ? "Unmute \(opponentName)" : "Mute \(opponentName)",
                systemImage: isMuted ? "bell.fill" : "bell.slash.fill"
            )
            Text("All your matches with \(opponentName)")
        }
        .disabled(isInFlight)
        .accessibilityIdentifier("competition.notifications.mute")
    }

    /// The menu closes before the save finishes, so a failure shows at the
    /// top of the page.
    @ViewBuilder
    var failureNote: some View {
        if let failure {
            Label(
                competitionMuteFailureText(failure, opponentName: opponentName),
                systemImage: "exclamationmark.circle"
            )
            .font(.caption)
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(
                "competition.notifications.preference-error"
            )
        }
    }
}

func competitionMuteFailureText(
    _ failure: CompetitionMuteFailure,
    opponentName: String
) -> String {
    switch failure {
    case .load: "Couldn’t check whether \(opponentName) is muted."
    case .mute: "Couldn’t mute \(opponentName). Try again from the More menu."
    case .unmute: "Couldn’t unmute \(opponentName). Try again from the More menu."
    }
}

/// The ••• that holds a match's less frequent actions.
/// Hides one person's photos for you, on every screen and device.
struct CompetitionReportPhoto {
    let isReported: Bool
    let isInFlight: Bool
    let report: () -> Void
}

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
    var detents: Set<PresentationDetent> = [.medium, .large]
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
        .presentationDetents(detents)
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
                // Past xxxLarge the glyph outgrows its 30 pt circle.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
          !competition.isPractice,
          !competition.opponentIdentity.hasSuffix(":pending")
    else {
        return nil
    }
    return competition.opponentIdentity
}

/// Explains amber once, the first time a scoreboard shows scores.
struct CompetitionColorHint: View {
    static let storageKey = "healthcomp.colorHintSeen"

    @AppStorage(Self.storageKey) private var isSeen = false

    var body: some View {
        if !isSeen {
            HStack(spacing: 8) {
                SlantedBar().fill(Theme.youFill).frame(width: 18, height: 6)
                Text("Amber is always you.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Color carries no meaning in VoiceOver; the sides already say
            // "YOU".
            .accessibilityHidden(true)
            .onDisappear { isSeen = true }
        }
    }
}

private struct CompetitionScoreboardPanel: View {
    let competition: LocalCompetitionPresentation
    let todayDay: LocalCompetitionDayPresentation?
    let isProvisional: Bool
    let isMuted: Bool

    @ScaledMetric(relativeTo: .largeTitle) private var scoreSize: CGFloat = 56
    @ScaledMetric(relativeTo: .headline) private var avatarSize: CGFloat = 28
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusRow
            ZStack(alignment: .topLeading) {
                if competitionShouldShowScores(competition.lifecycle) {
                    VStack(alignment: .leading, spacing: 16) {
                        scoreboard
                        ZStack {
                            if isProvisional {
                                // The score headers already say "provisional total".
                                CompetitionProvisionalTag()
                                    .frame(maxWidth: .infinity)
                                    .accessibilityHidden(true)
                                    .transition(Motion.appear)
                            } else {
                                VStack(alignment: .leading, spacing: 16) {
                                    Rectangle()
                                        .fill(Theme.hairline)
                                        .frame(height: 1)
                                        .accessibilityHidden(true)
                                    periodRow
                                }
                                .transition(Motion.appear)
                            }
                        }
                        CompetitionColorHint()
                    }
                    .transition(Motion.appear)
                } else {
                    CompetitionScheduledSummary(competition: competition)
                        .transition(Motion.appear)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themePanel()
    }

    // AnyLayout, not ViewThatFits: the XCTest Dynamic Type audit flags
    // text that ViewThatFits swaps out while it cycles sizes.
    private var statusRow: some View {
        let status = competitionStatusText(
            competition, style: .card, locale: locale, timeZone: timeZone
        )
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isLive {
                    Circle()
                        .fill(Theme.ink)
                        .frame(width: 8, height: 8)
                }
                Text(status.title).foregroundStyle(Theme.ink)
                    + Text(isMuted ? " · Muted" : "").foregroundStyle(Theme.secondary)
            }
            .contentTransition(.opacity)
            .animation(Motion.fade, value: isMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let timing = status.timing {
                Text(timing)
                    .foregroundStyle(Theme.secondary)
                    .tracking(0)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.themeLabel)
        .tracking(1.2)
        .textCase(.uppercase)
        // One static element: the hit-region audit treats a traitless
        // element as a control, and this row is read, never tapped.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(status.line + (isMuted ? ". Muted" : ""))
        .accessibilityIdentifier("competition.status")
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
            name: "You",
            avatar: PersonAvatar(name: competition.ownerDisplayName, size: avatarSize, isYou: true),
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
            avatar: PersonAvatar(
                name: competition.opponentDisplayName,
                photo: competition.opponentProfileID,
                size: avatarSize
            ),
            today: todayDay?.opponentRevealedPoints,
            total: competition.opponentPoints,
            color: Theme.ink,
            alignment: alignment,
            identifier: "competition.scoreHeader.alex"
        )
    }

    private func scoreBlock(
        name: String,
        avatar: PersonAvatar,
        today: Double?,
        total: Double,
        color: Color,
        alignment: HorizontalAlignment,
        identifier: String
    ) -> some View {
        // Names may wrap at large sizes; scores never do.
        VStack(alignment: alignment, spacing: 4) {
            HStack(spacing: 8) {
                avatar
                Text(name.uppercased())
                    .font(.themeLabel)
                    .tracking(1.4)
                    .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            }
            Text(competitionPointsText(total))
                .font(.score(size: scoreSize).monospacedDigit())
                .fixedSize()
                .scoreRoll(total, id: competition.id)
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
            .scoreRoll(todayDay?.ownerAcceptedPoints, id: periodID)
    }

    private var opponentPeriodPoints: some View {
        Text(competitionPointsText(todayDay?.opponentRevealedPoints))
            .font(.title.weight(.heavy).width(.condensed).monospacedDigit())
            .foregroundStyle(Theme.ink)
            .fixedSize()
            .scoreRoll(todayDay?.opponentRevealedPoints, id: periodID)
    }

    /// Per day, so midnight replaces the number instead of rolling it down.
    private var periodID: String {
        "\(competition.id.rawValue)-\(todayDay?.ordinal ?? 0)"
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

/// A scheduled match: who plays, when Day 1 is, and the week ahead.
struct CompetitionScheduledSummary: View {
    let competition: LocalCompetitionPresentation

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            (
                Text("YOU").foregroundStyle(Theme.you)
                    + Text("  VS  ")
                    .font(.title3.weight(.heavy).width(.condensed))
                    .foregroundStyle(Theme.tertiary)
                    + Text(competition.opponentDisplayName.uppercased())
                    .foregroundStyle(Theme.ink)
            )
            .font(.title.weight(.heavy).width(.condensed))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("You versus \(competition.opponentDisplayName)")
            Text(dayOneText)
                .font(.body)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("competition.schedule.dates")
            if !competition.days.isEmpty {
                CompetitionWeekStrip(days: competition.days, currentDayOrdinal: nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // The same words for both people in any zone: each scores their own
    // Activity for that calendar date.
    private var dayOneText: String {
        guard let first = competition.days.first?.day
            ?? competition.acceptedConfiguration?.schedule.startDay
        else {
            return "Day 1 starts on the next match day."
        }
        return "Day 1 is \(weekdayName(first, locale: locale)). Points start counting at midnight."
    }
}

func competitionDayAccessibilityLabel(
    _ day: LocalCompetitionDayPresentation,
    currentDayOrdinal: Int? = nil,
    opponentName: String,
    now: Date = Date(),
    locale: Locale = .current
) -> String {
    let date = competitionDayText(day.day, now: now, locale: locale)
    if day.ordinal == currentDayOrdinal {
        return "Day \(day.ordinal), Today, scores so far. \(competitionDayScoresAccessibilityText(day, opponentName: opponentName, locale: locale))"
    }
    if day.ownerLatestAvailability == .notYetOccurred {
        return "Day \(day.ordinal), \(date), upcoming."
    }
    return "Day \(day.ordinal), \(date), complete. \(competitionDayScoresAccessibilityText(day, opponentName: opponentName, locale: locale))"
}

private func competitionDayScoresAccessibilityText(
    _ day: LocalCompetitionDayPresentation,
    opponentName: String,
    locale: Locale
) -> String {
    let opponent = day.opponentRevealedPoints.map {
        competitionPointsAccessibilityText($0, locale: locale)
    } ?? (day.opponentReportedNoData ? "no data" : "not synced")
    return "You, \(competitionOwnerAccessibilityText(day, locale: locale)). \(opponentName), \(opponent)."
}

/// The inclusive week, "Oct 28 – Nov 3". Nil when the stored schedule
/// can't produce its seven days.
func competitionScheduleDateRangeText(
    _ schedule: CompetitionSchedule,
    now: Date = Date(),
    locale: Locale = .current
) -> String? {
    guard let window = try? schedule.calendar.sevenDayWindow(
        startingOn: schedule.startDay
    ),
        let first = window.first,
        let last = window.last
    else {
        return nil
    }
    return competitionWeekText(first, last, now: now, locale: locale)
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
    _ day: LocalCompetitionDayPresentation,
    locale: Locale = .current
) -> String {
    let points = competitionPointsAccessibilityText(day.ownerAcceptedPoints, locale: locale)
    switch day.ownerLatestAvailability {
    case .notYetOccurred:
        return "upcoming"
    case .notSyncedYet:
        return "not synced yet"
    case .observed:
        return day.ownerAcceptedPoints == nil ? "synced, no score yet" : points
    case .missing:
        return "missing activity data, \(points)"
    case let .unavailable(reason):
        return "\(competitionOwnerAvailabilityText(.unavailable(reason: reason), ordinal: day.ordinal).replacingOccurrences(of: ".", with: "")), \(points)"
    }
}

func competitionOwnerAvailabilityText(
    _ availability: LocalCompetitionOwnerAvailability,
    ordinal: Int
) -> String {
    switch availability {
    case .notYetOccurred: "Day \(ordinal) has not started yet"
    case .notSyncedYet: "Today hasn’t synced yet"
    case .observed: "Day \(ordinal) synced"
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

/// The tag a tallying score wears, here and on the person page.
struct CompetitionProvisionalTag: View {
    var body: some View {
        Text("PROVISIONAL")
            .font(.themeLabel)
            .tracking(1.2)
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .overlay(Capsule().stroke(Theme.outline))
            .fixedSize()
    }
}

struct CompetitionTallyCopy: Equatable {
    let headline: String
    let body: String
}

/// What a tallying match waits on and whether you need to do anything.
func competitionTallyCopy(
    _ tally: LocalCompetitionTallyPresentation,
    opponentDisplayName name: String,
    now: Date,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> CompetitionTallyCopy {
    guard now < tally.bestAvailableDeadline else {
        return CompetitionTallyCopy(
            headline: "Finishing the result",
            body: "The deadline passed, so the result uses what’s in. It appears here shortly."
        )
    }
    let deadline = competitionDeadlineText(
        tally.bestAvailableDeadline, now: now, locale: locale, timeZone: timeZone
    )
    let nothingToDo = "Nothing for you to do. If it isn’t done by \(deadline), the result uses what’s in."
    let openAgain = "Open HealthComp again before \(deadline), or the result uses what’s in."
    switch tally.attention {
    case .opponentPlanUnavailable:
        return CompetitionTallyCopy(
            headline: "Waiting for \(name) to sync",
            body: "If \(name) doesn’t sync by \(deadline), the result uses what’s in."
        )
    case .awaitingOpponentCheck:
        return CompetitionTallyCopy(
            headline: "Waiting for \(name)’s last check",
            body: "If \(name) doesn’t open HealthComp by \(deadline), the result uses what’s in."
        )
    case let .incomplete(missing, unavailable) where unavailable.isEmpty:
        let days = competitionDayListText(missing, locale: locale)
        let verb = missing.count == 1 ? "hasn’t" : "haven’t"
        return CompetitionTallyCopy(
            headline: "Waiting for your \(days ?? "Activity")",
            body: "\(days ?? "\(missing.count) days") \(verb) synced from this iPhone. \(openAgain)"
        )
    case let .incomplete(missing, unavailable):
        let all = missing.union(unavailable)
        let days = competitionDayListText(all, locale: locale)
        return CompetitionTallyCopy(
            headline: "Waiting for your \(days ?? "Activity")",
            body: "HealthComp couldn’t read \(days ?? "\(all.count) days") on this iPhone. \(openAgain)"
        )
    case let .unacceptedScores(ordinals):
        return CompetitionTallyCopy(
            headline: "Scoring your \(competitionDayListText(ordinals, locale: locale) ?? "Activity")",
            body: nothingToDo
        )
    case .noRead:
        return CompetitionTallyCopy(
            headline: "Checking Activity on this iPhone",
            body: nothingToDo
        )
    case .awaitingStability, nil:
        return CompetitionTallyCopy(
            headline: "Checking the last scores",
            body: "Nothing for you to do. The result is final by \(deadline) at the latest."
        )
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
    now: Date = Date(),
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> [String] {
    var lines: [String] = []
    if let lastRefresh {
        lines.append(
            "Latest Activity check \(competitionMomentText(lastRefresh.readAt, now: now, locale: locale, timeZone: timeZone)): \(competitionRefreshStatusText(lastRefresh.status))"
        )
    }
    if let lastSuccessfulFullWindowRefreshAt {
        lines.append(
            "Last complete Activity read \(competitionMomentText(lastSuccessfulFullWindowRefreshAt, now: now, locale: locale, timeZone: timeZone))."
        )
    } else if lastRefresh == nil {
        lines.append("No Activity check yet.")
    }
    return lines
}

/// "You: updated 9:41 AM · Hermes: updated 11:40 PM", or just the side that
/// has a time. Nil when neither does.
func competitionFreshnessText(
    _ competition: LocalCompetitionPresentation,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String? {
    func time(_ date: Date) -> String {
        competitionUpdatedText(date, now: competition.evaluatedAt, locale: locale, timeZone: timeZone)
    }
    let you = competition.lastSuccessfulFullWindowRefreshAt.map(time)
    let them = competition.opponentUpdatedAt.map(time)
    let name = competition.opponentDisplayName
    switch (you, them) {
    case let (you?, them?): return "You: updated \(you) · \(name): updated \(them)"
    case let (you?, nil): return "Updated \(you)"
    case let (nil, them?): return "\(name): updated \(them)"
    case (nil, nil): return nil
    }
}

func competitionScoreTotalLabel(isProvisional: Bool) -> String {
    isProvisional ? "Provisional total" : "Total"
}

func competitionScorePeriodLabel(
    _ lifecycle: LocalCompetitionLifecyclePresentation
) -> String {
    if case .tallying = lifecycle { return "Day 7" }
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
    case .notSyncedYet:
        .unscored
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

private func availabilitySymbol(
    _ availability: LocalCompetitionOwnerAvailability
) -> String {
    switch availability {
    case .notYetOccurred: "clock"
    case .notSyncedYet: "arrow.triangle.2.circlepath"
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
    case .notYetOccurred, .notSyncedYet, .missing: Theme.secondary
    }
}

struct CompetitionCancelMatch {
    let isInFlight: Bool
    let failed: Bool
    let cancel: () -> Void
}

struct CompetitionNudge {
    let status: CompetitionFeature.NudgeStatus?
    let send: () -> Void
}

// MARK: Nudge

/// The server uses the same value.
let competitionNudgeStaleInterval: TimeInterval = 12 * 60 * 60

/// Lifecycle and time only; the real-match gate is the caller's.
func competitionCanNudge(_ competition: LocalCompetitionPresentation) -> Bool {
    let now = competition.evaluatedAt
    switch competition.lifecycle {
    case .tallying:
        guard let tally = competition.tally, now < tally.bestAvailableDeadline else {
            return false
        }
        switch tally.attention {
        case .awaitingOpponentCheck?, .opponentPlanUnavailable?: return true
        default: return false
        }
    case .active, .endsToday:
        guard let since = competition.opponentUpdatedAt ?? competition.acceptedConfiguration
            .flatMap({ try? $0.schedule.calendar.startOfDay($0.schedule.startDay) })
        else { return false }
        return now.timeIntervalSince(since) > competitionNudgeStaleInterval
    default:
        return false
    }
}

enum CompetitionNudgeDisplay: Equatable {
    case button(error: String?, isSending: Bool)
    case sent(String)
    case notNeeded(String)
}

/// Nil when there's nothing to show. A sent or refused nudge holds until the
/// match day (in the match's time zone) ends.
func competitionNudgeDisplay(
    _ status: CompetitionFeature.NudgeStatus?,
    competition: LocalCompetitionPresentation,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> CompetitionNudgeDisplay? {
    guard competitionCanNudge(competition) else { return nil }
    var matchCalendar = Calendar(identifier: .gregorian)
    matchCalendar.timeZone = TimeZone(identifier: competition.timeZoneIdentifier) ?? timeZone
    // A server time after this projection (clock skew, or a projection from
    // before midnight) is the newest news there is: it still counts as today.
    func isToday(_ date: Date) -> Bool {
        date > competition.evaluatedAt
            || matchCalendar.isDate(date, inSameDayAs: competition.evaluatedAt)
    }
    switch status {
    case let .sent(date)? where isToday(date):
        let time = competitionUpdatedText(
            date, now: max(date, competition.evaluatedAt), locale: locale, timeZone: timeZone
        )
        return .sent("Nudged at \(time). You can nudge again tomorrow.")
    case let .notNeeded(date)? where isToday(date):
        return .notNeeded("\(competition.opponentDisplayName) doesn’t need a nudge right now.")
    case .sending?:
        return .button(error: nil, isSending: true)
    case .failed?:
        return .button(error: "Couldn’t send the nudge. Try again.", isSending: false)
    default:
        return .button(error: nil, isSending: false)
    }
}

private struct CompetitionNudgeControl: View {
    let display: CompetitionNudgeDisplay
    let name: String
    let send: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
                .transition(Motion.appear)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: display) { old, new in
            if case .button(_, isSending: true) = old, case let .sent(text) = new {
                AccessibilityNotification.Announcement(text).post()
            }
        }
        .sensoryFeedback(trigger: display) { old, new in
            guard case .button(_, isSending: true) = old else { return nil }
            switch new {
            case .sent: return .success
            case .button(.some, _): return .error
            default: return nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch display {
        case let .button(error, isSending):
            VStack(alignment: .leading, spacing: 4) {
                Button("Nudge \(name)", action: send)
                    .buttonStyle(CompetitionNudgeButtonStyle())
                    .disabled(isSending)
                    .accessibilityHint("Sends \(name) a notification to open HealthComp.")
                    .accessibilityIdentifier("competition.nudge")
                if let error {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("competition.nudge.error")
                        .transition(Motion.appear)
                }
            }
        case let .sent(text):
            Label(text, systemImage: "checkmark")
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("competition.nudge.sent")
        case let .notNeeded(text):
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("competition.nudge.error")
        }
    }
}

/// The compact ink pill of the shipped "Review" mark, with a 44 pt target.
private struct CompetitionNudgeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        // A capsule while it fits one line; a long name wraps inside
        // rounded corners instead of past a capsule's ends.
        ViewThatFits(in: .horizontal) {
            pill(configuration.label.lineLimit(1), in: Capsule())
            pill(configuration.label, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
        .animation(Motion.press, value: configuration.isPressed)
        .animation(Motion.press, value: isEnabled)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func pill(_ label: some View, in shape: some Shape) -> some View {
        label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.onInk)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.ink, in: shape)
    }
}
