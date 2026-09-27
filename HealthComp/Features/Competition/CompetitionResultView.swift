import CompetitionCore
import SwiftUI

struct CompetitionResultView: View {
    let competition: LocalCompetitionPresentation
    let awards: [LocalCompetitionAward]
    let source: CompetitionPublicationSource
    let inviteCreationStatus: CompetitionFeature.InviteCreationStatus
    let createdInviteLink: CompetitionInviteShareLink?
    let isCommandInFlight: Bool
    let send: (CompetitionFeature.Action) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize: CGFloat = 64
    @State private var isRevealed = false
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                resultHero
                    .opacity(isRevealed ? 1 : 0)
                    .offset(y: isRevealed || reduceMotion ? 0 : 10)

                VStack(spacing: 12) {
                    finalScore
                    marginChips
                }
                .opacity(isRevealed ? 1 : 0)

                if isBestAvailableResult {
                    Label(
                        "Finalized from the best available accepted Activity data after the reconciliation deadline.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !competition.days.isEmpty {
                    weekSection
                }

                if let ringTotals {
                    ringTotalsSection(ringTotals)
                }

                awardPresentation
                    .opacity(isRevealed ? 1 : 0)

                actionControls
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.ground)
        .navigationTitle("Result")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if reduceMotion {
                isRevealed = true
            } else {
                withAnimation(.easeOut(duration: 0.28)) {
                    isRevealed = true
                }
            }
        }
    }

    private var resultHero: some View {
        VStack(spacing: 10) {
            Text(resultKicker)
                .font(.themeLabel)
                .tracking(1.2)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            Text(resultTitle)
                .font(.score(size: headlineSize))
                .foregroundStyle(outcome == .win ? Theme.you : Theme.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(resultSubtitle)
                .font(.body)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var resultKicker: String {
        var parts = ["FINAL"]
        if let first = competition.days.first?.day,
           let last = competition.days.last?.day {
            parts.append("\(first.month)/\(first.day)–\(last.month)/\(last.day)")
        }
        parts.append("VS \(competition.opponentDisplayName.uppercased())")
        return parts.joined(separator: " · ")
    }

    private var finalScore: some View {
        VStack(spacing: 16) {
            Text("Final score")
                .font(.themeLabel)
                .tracking(1.2)
                .foregroundStyle(Theme.secondary)

            CompetitionFinalScoreLayout { finalScoreOwners }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .themePanel(cornerRadius: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("competition.result")
        .accessibilityLabel(
            "\(resultTitle). Final score. \(competition.ownerDisplayName) \(competitionPointsAccessibilityText(competition.userPoints)). \(competition.opponentDisplayName) \(competitionPointsAccessibilityText(competition.opponentPoints))."
        )
    }

    @ViewBuilder
    private var finalScoreOwners: some View {
        FinalScoreOwner(
            name: competition.ownerDisplayName,
            points: competition.userPoints,
            tint: Theme.you
        )
        Text("–")
            .font(.title2.weight(.medium))
            .foregroundStyle(Theme.faint)
            .accessibilityHidden(true)
        FinalScoreOwner(
            name: competition.opponentDisplayName,
            points: competition.opponentPoints,
            tint: Theme.ink
        )
    }

    // The margin is yours, so it is amber: filled for a win, outlined otherwise.
    @ViewBuilder
    private var marginChips: some View {
        if marginText != nil || daysWonText != nil {
            HStack(spacing: 10) {
                if let marginText {
                    Text(marginText)
                        .font(.headline.weight(.heavy).width(.condensed).monospacedDigit())
                        .foregroundStyle(outcome == .win ? Theme.onYouFill : Theme.you)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background { chipBackground(filled: outcome == .win) }
                }
                if let daysWonText {
                    Text(daysWonText)
                        .font(.subheadline.weight(.bold).width(.condensed))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background { chipBackground(filled: false) }
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func chipBackground(filled: Bool) -> some View {
        if filled {
            SlantedBar().fill(Theme.youFill)
        } else {
            SlantedBar().stroke(Theme.outline, lineWidth: 1.5)
        }
    }

    private var marginText: String? {
        let margin = competition.userPoints - competition.opponentPoints
        guard margin != 0 else { return nil }
        return (margin > 0 ? "+" : "−") + competitionPointsText(abs(margin))
    }

    private var daysWonText: String? {
        let decided = competition.days.compactMap { day -> Bool? in
            guard let owner = day.ownerAcceptedPoints,
                  let opponent = day.opponentRevealedPoints
            else { return nil }
            return owner > opponent
        }
        guard !decided.isEmpty else { return nil }
        return "\(decided.filter { $0 }.count) of \(competition.days.count) days"
    }

    private var weekSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("THE WEEK")
            CompetitionWeekChart(
                days: competition.days,
                currentDayOrdinal: nil,
                ownerName: competition.ownerDisplayName,
                opponentName: competition.opponentDisplayName
            )
            if competition.days.contains(where: { ringSegments($0).count == 3 }) {
                CompetitionRingLegend(opponentName: competition.opponentDisplayName)
            }
        }
    }

    /// Your week by ring. Shown only when every scored day has a ring split,
    /// so the three parts always add up to your final score.
    private var ringTotals: [(title: String, color: Color, points: Double)]? {
        let scored = competition.days.map(ringSegments).filter { !$0.isEmpty }
        guard !scored.isEmpty, scored.allSatisfy({ $0.count == 3 }) else {
            return nil
        }
        let totals = (0..<3).map { index in
            scored.reduce(0.0) { $0 + $1[index].points }
        }
        return [
            ("MOVE", Theme.move, totals[0]),
            ("EXERCISE", Theme.exercise, totals[1]),
            ("STAND", Theme.stand, totals[2]),
        ]
    }

    private func ringTotalsSection(
        _ totals: [(title: String, color: Color, points: Double)]
    ) -> some View {
        let sum = totals.reduce(0.0) { $0 + $1.points }
        // AnyLayout, not ViewThatFits, which the Dynamic Type audit flags.
        let labelsLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel("HOW YOU SCORED")
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(totals.indices, id: \.self) { index in
                        SlantedBar()
                            .fill(totals[index].color)
                            .frame(
                                width: ringShareWidth(
                                    totals[index].points,
                                    of: sum,
                                    in: proxy.size.width - 4
                                )
                            )
                    }
                }
            }
            .frame(height: 24)
            .accessibilityHidden(true)
            labelsLayout { ringTotalLabels(totals) }
        }
        .accessibilityElement(children: .combine)
    }

    private func ringShareWidth(
        _ points: Double,
        of sum: Double,
        in width: CGFloat
    ) -> CGFloat {
        guard sum > 0 else { return 0 }
        return max(2, width * points / sum)
    }

    @ViewBuilder
    private func ringTotalLabels(
        _ totals: [(title: String, color: Color, points: Double)]
    ) -> some View {
        ForEach(totals.indices, id: \.self) { index in
            VStack(alignment: .leading, spacing: 2) {
                Text(totals[index].title)
                    .font(.themeLabel)
                    .tracking(1.1)
                    .foregroundStyle(Theme.secondary)
                Text(competitionPointsText(totals[index].points.rounded()))
                    .font(.title2.weight(.heavy).width(.condensed).monospacedDigit())
                    .foregroundStyle(Theme.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var awardPresentation: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Awards")

            ForEach(visibleAwards) { award in
                HStack(spacing: 14) {
                    awardBadge(award.kind)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            award.kind == .victory
                                ? "Victory Over \(award.friendDisplayName)"
                                : "Competition Complete"
                        )
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                        Text("Earned in this seven-day competition")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                        Text(
                            competitionAwardEarnedText(
                                award.awardedAt,
                                timeZoneIdentifier: competition.timeZoneIdentifier
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        if award.kind == .victory {
                            Text(
                                competitionVictoryCountText(
                                    awards.filter {
                                        $0.kind == .victory
                                            && $0.friendDisplayName
                                                == award.friendDisplayName
                                    }.count,
                                    friendDisplayName: award.friendDisplayName
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(minHeight: 76)
                .themePanel(cornerRadius: 18)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // A victory is yours, so its badge is amber; completion stays neutral.
    private func awardBadge(_ kind: LocalCompetitionAward.Kind) -> some View {
        ZStack {
            if kind == .victory {
                Circle().fill(Theme.youFill)
                Image(systemName: "trophy.fill")
                    .foregroundStyle(Theme.onYouFill)
            } else {
                Circle().stroke(Theme.outline, lineWidth: 2)
                Image(systemName: "checkmark")
                    .foregroundStyle(Theme.ink)
            }
        }
        .font(.title3.weight(.bold))
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
    }

    private var actionControls: some View {
        VStack(spacing: 10) {
            rematchControl
            dataControl
        }
    }

    @ViewBuilder
    private var rematchControl: some View {
        if source == .remoteParticipants {
            remoteRematchControl
        } else {
            Button {
                send(.rematchTapped(competition.id))
            } label: {
                commandLabel("Rematch")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isCommandInFlight)
        }
    }

    @ViewBuilder
    private var dataControl: some View {
        switch competitionResultDataControl(
            source: source,
            isArchived: isArchived
        ) {
        case .archive:
            Button("Archive") {
                send(.archiveTapped(competition.id))
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(isCommandInFlight)

        case .deleteLocalData:
            Button("Delete Local Data", role: .destructive) {
                isDeleteConfirmationPresented = true
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(isCommandInFlight)
            .confirmationDialog(
                "Delete this competition from this iPhone?",
                isPresented: $isDeleteConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Delete Local Data", role: .destructive) {
                    send(.deleteTapped(competition.id))
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This permanently removes the local competition journal and its notifications."
                )
            }

        case .preservedHistory:
            Label(
                "Archived competition history is preserved.",
                systemImage: "archivebox.fill"
            )
            .font(.footnote)
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("competition.history.preserved")
        }
    }

    @ViewBuilder
    private var remoteRematchControl: some View {
        switch inviteCreationStatus {
        case .idle:
            Button("Create Rematch Invitation") {
                send(.rematchTapped(competition.id))
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("competition.rematch.create")

        case .creating:
            HStack(spacing: 8) {
                ProgressView()
                Text("Creating rematch invitation…")
            }
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, minHeight: 54)
            .accessibilityElement(children: .combine)

        case .ready:
            if let createdInviteLink {
                ShareLink(
                    item: createdInviteLink.url,
                    subject: Text("HealthComp rematch"),
                    message: Text("Rematch? Join my 7-day Activity challenge on HealthComp.")
                ) {
                    Label(
                        "Share Rematch Invitation",
                        systemImage: "square.and.arrow.up"
                    )
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityHint(
                    "Opens the system share sheet. The private link is not read aloud."
                )
                .accessibilityIdentifier("competition.rematch.share")
            }

        case .retryable:
            Button("Try Rematch Again") {
                send(.rematchTapped(competition.id))
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("competition.rematch.retry")

        case .configurationUnavailable:
            Label(
                "Rematch links are not configured for this build.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(Theme.secondary)
        }
    }

    @ViewBuilder
    private func commandLabel(_ title: String) -> some View {
        if isCommandInFlight {
            HStack(spacing: 8) {
                ProgressView()
                Text(title)
            }
            .frame(maxWidth: .infinity)
        } else {
            Text(title)
                .frame(maxWidth: .infinity)
        }
    }

    private var visibleAwards: [LocalCompetitionAward] {
        let matching = awards.filter { $0.competitionID == competition.id }
        return matching
    }

    private var outcome: CompetitionOutcome {
        competition.terminalResult?.outcome ?? {
            if competition.userPoints > competition.opponentPoints { return .win }
            if competition.userPoints < competition.opponentPoints { return .loss }
            return .tie
        }()
    }

    private var resultTitle: String {
        competitionResultTitle(
            outcome: outcome,
            opponentDisplayName: competition.opponentDisplayName
        )
    }

    private var resultSubtitle: String {
        competitionResultSubtitle(
            outcome: outcome,
            opponentDisplayName: competition.opponentDisplayName,
            source: source
        )
    }

    private var isArchived: Bool {
        if case .archived = competition.lifecycle { return true }
        return false
    }

    private var isBestAvailableResult: Bool {
        competition.terminalResult?.basis == .bestAvailable
    }
}

enum CompetitionResultDataControl: Equatable {
    case archive
    case deleteLocalData
    case preservedHistory
}

func competitionResultDataControl(
    source: CompetitionPublicationSource,
    isArchived: Bool
) -> CompetitionResultDataControl {
    guard isArchived else { return .archive }
    return source == .remoteParticipants ? .preservedHistory : .deleteLocalData
}

func competitionResultTitle(
    outcome: CompetitionOutcome,
    opponentDisplayName: String
) -> String {
    switch outcome {
    case .win: "You Won"
    case .loss: "\(opponentDisplayName) Won"
    case .tie: "It’s a Tie"
    }
}

func competitionResultSubtitle(
    outcome: CompetitionOutcome,
    opponentDisplayName: String,
    source: CompetitionPublicationSource
) -> String {
    switch outcome {
    case .win:
        "Your seven-day Activity total finished ahead."
    case .loss:
        source == .simulatedFixture
            ? "\(opponentDisplayName)’s simulated seven-day total finished ahead."
            : "\(opponentDisplayName)’s seven-day Activity total finished ahead."
    case .tie:
        "Both seven-day totals finished even."
    }
}

// Keep one owner hierarchy while fitting the native stack to available width.
struct CompetitionFinalScoreLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let contentProposal = contentSizedProposal(proposal)
        let layout = fittingLayout(proposal: contentProposal, subviews: subviews)
        var layoutCache = layout.makeCache(subviews: subviews)
        return layout.sizeThatFits(
            proposal: contentProposal, subviews: subviews, cache: &layoutCache
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let contentProposal = contentSizedProposal(proposal)
        let layout = fittingLayout(proposal: contentProposal, subviews: subviews)
        var layoutCache = layout.makeCache(subviews: subviews)
        _ = layout.sizeThatFits(
            proposal: contentProposal, subviews: subviews, cache: &layoutCache
        )
        layout.placeSubviews(
            in: bounds, proposal: contentProposal, subviews: subviews,
            cache: &layoutCache
        )
    }

    private func contentSizedProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        // This text-only card uses its ideal size for unbounded dimensions.
        // Preserve finite width when only height is unbounded so names wrap.
        ProposedViewSize(
            width: proposal.width.flatMap { $0.isFinite ? $0 : nil },
            height: proposal.height.flatMap { $0.isFinite ? $0 : nil }
        )
    }

    private func fittingLayout(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> AnyLayout {
        let horizontal = AnyLayout(HStackLayout(spacing: 24))
        guard let width = proposal.width, width.isFinite else {
            return horizontal
        }
        var horizontalCache = horizontal.makeCache(subviews: subviews)
        let idealWidth = horizontal.sizeThatFits(
            proposal: .unspecified, subviews: subviews,
            cache: &horizontalCache
        ).width
        return idealWidth <= width
            ? horizontal
            : AnyLayout(VStackLayout(spacing: 18))
    }
}

private struct FinalScoreOwner: View {
    let name: String
    let points: Double
    let tint: Color

    @ScaledMetric(relativeTo: .largeTitle) private var scoreSize: CGFloat = 52

    var body: some View {
        VStack(spacing: 4) {
            Text(name)
                .font(.subheadline.weight(.semibold))
            Text(competitionPointsText(points))
                .font(.score(size: scoreSize))
                .monospacedDigit()
            Text("points")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
    }
}
