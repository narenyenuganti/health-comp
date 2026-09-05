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
    @State private var isRevealed = false
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                resultHero
                    .opacity(isRevealed ? 1 : 0)
                    .offset(y: isRevealed || reduceMotion ? 0 : 10)

                finalScore
                    .opacity(isRevealed ? 1 : 0)

                if isBestAvailableResult {
                    Label(
                        "Finalized from the best available accepted Activity data after the reconciliation deadline.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                awardPresentation
                    .opacity(isRevealed ? 1 : 0)

                actionControls
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .background(Color(.systemGroupedBackground))
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
        VStack(spacing: 14) {
            HealthCompAwardEmblem(outcome: outcome)
                .frame(width: 150, height: 150)
                .accessibilityHidden(true)
            Text(resultTitle)
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
            Text(resultSubtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var finalScore: some View {
        VStack(spacing: 16) {
            Text("Final score")
                .font(.headline)

            CompetitionFinalScoreLayout { finalScoreOwners }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(
            .background,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
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
            tint: .mint
        )
        Text("–")
            .font(.title2.weight(.medium))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        FinalScoreOwner(
            name: competition.opponentDisplayName,
            points: competition.opponentPoints,
            tint: .indigo
        )
    }

    private var awardPresentation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Awards")
                .font(.headline)
                .padding(.horizontal, 4)

            ForEach(visibleAwards) { award in
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                award.kind == .victory
                                    ? Color.orange.opacity(0.18)
                                    : Color.green.opacity(0.16)
                            )
                        Image(
                            systemName: award.kind == .victory
                                ? "trophy.fill"
                                : "checkmark.seal.fill"
                        )
                        .font(.title2)
                        .foregroundStyle(
                            award.kind == .victory ? .orange : .green
                        )
                    }
                    .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            award.kind == .victory
                                ? "Victory Over \(award.friendDisplayName)"
                                : "Competition Complete"
                        )
                        .font(.headline)
                        Text("Earned in this seven-day competition")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(
                            competitionAwardEarnedText(
                                award.awardedAt,
                                timeZoneIdentifier: competition.timeZoneIdentifier
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(minHeight: 76)
                .background(
                    .background,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var actionControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { resultButtons }
            VStack(spacing: 12) { resultButtons }
        }
    }

    @ViewBuilder
    private var resultButtons: some View {
        if source == .remoteParticipants {
            remoteRematchControl
        } else {
            Button {
                send(.rematchTapped(competition.id))
            } label: {
                commandLabel("Rematch")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(isCommandInFlight)
        }

        switch competitionResultDataControl(
            source: source,
            isArchived: isArchived
        ) {
        case .archive:
            Button("Archive") {
                send(.archiveTapped(competition.id))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(isCommandInFlight)

        case .deleteLocalData:
            Button("Delete Local Data", role: .destructive) {
                isDeleteConfirmationPresented = true
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 44)
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
            .foregroundStyle(.secondary)
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
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("competition.rematch.create")

        case .creating:
            HStack(spacing: 8) {
                ProgressView()
                Text("Creating rematch invitation…")
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityElement(children: .combine)

        case .ready:
            if let createdInviteLink {
                ShareLink(
                    item: createdInviteLink.url,
                    subject: Text("HealthComp rematch"),
                    message: Text(
                        "Open this private link to join our HealthComp rematch."
                    )
                ) {
                    Label(
                        "Share Rematch Invitation",
                        systemImage: "square.and.arrow.up"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(minHeight: 44)
                .accessibilityHint(
                    "Opens the system share sheet. The private link is not read aloud."
                )
                .accessibilityIdentifier("competition.rematch.share")
            }

        case .retryable:
            Button("Try Rematch Again") {
                send(.rematchTapped(competition.id))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("competition.rematch.retry")

        case .configurationUnavailable:
            Label(
                "Rematch links are not configured for this build.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
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

    var body: some View {
        VStack(spacing: 5) {
            Text(name)
                .font(.subheadline.weight(.semibold))
            Text(competitionPointsText(points))
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit()
            Text("points")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
    }
}

private struct HealthCompAwardEmblem: View {
    let outcome: CompetitionOutcome

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: emblemColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: emblemColors[0].opacity(0.28), radius: 20, y: 10)

            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(.white.opacity(0.45), lineWidth: 2)
                .padding(10)

            Image(systemName: emblemSymbol)
                .font(.system(size: 58, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var emblemColors: [Color] {
        switch outcome {
        case .win: [.orange, .pink]
        case .loss: [.indigo, .blue]
        case .tie: [.teal, .indigo]
        }
    }

    private var emblemSymbol: String {
        switch outcome {
        case .win: "trophy.fill"
        case .loss: "figure.run"
        case .tie: "equal.circle.fill"
        }
    }
}
