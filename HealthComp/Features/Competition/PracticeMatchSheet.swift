import CompetitionCore
import SwiftUI

struct CompetitionPracticeStart {
    let isStarting: Bool
    let failed: Bool
    var shadowRivals: [PracticeShadowRival] = []
    let start: (PracticeStartTarget) -> Void
}

struct PracticeMatchSheet: View {
    let practice: CompetitionPracticeStart

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selection: OpponentDifficulty = .pacer
    @State private var shadowRivalID: String?
    @State private var hasAttempted = false

    static let bots: [(OpponentDifficulty, String, [CGFloat])] = [
        (.pacer, "Your usual week, steady every day.", [18, 19, 18, 19, 18, 19, 18]),
        (.chill, "A little under your usual. Starts slow.", [8, 9, 10, 11, 12, 13, 14]),
        (.erratic, "Huge days and off days. Hard to read.", [26, 6, 24, 10, 28, 5, 20]),
        (.beast, "Well above your usual, every day.", [24, 25, 26, 26, 27, 28, 28]),
    ]
    static let shadowDefaultBars: [CGFloat] = [14, 20, 12, 22, 16, 26, 19]
    static let shadowDetail = "Modeled on a past rival’s week, with natural variation."
    static let shadowLockedDetail = "Play at least 3 days with someone to unlock their Shadow."
    static let subtitle = "Seven days against a bot, scaled to your last two weeks. It doesn’t count toward your record."
    static let startError = "Couldn’t start the practice match. Try again."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button("Cancel") { dismiss() }
                    .foregroundStyle(Theme.ink)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("competition.practice.cancel")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Practice Match")
                        .font(.largeTitle.weight(.heavy).width(.condensed))
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(Self.subtitle)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 10) {
                    ForEach(Self.bots, id: \.0) { bot in
                        PracticeBotOptionCard(
                            difficulty: bot.0,
                            detail: bot.1,
                            bars: bot.2,
                            isSelected: selection == bot.0
                        ) {
                            selection = bot.0
                        }
                    }
                    if !practice.shadowRivals.isEmpty {
                        PracticeShadowOptionCard(
                            activeRival: selectedShadowRival,
                            hasRivals: true,
                            isSelected: selection == .shadow
                        ) {
                            if shadowRivalID == nil { shadowRivalID = practice.shadowRivals.first?.id }
                            selection = .shadow
                        }
                    }
                }
                .sensoryFeedback(.selection, trigger: selection)

                if selection == .shadow, !practice.shadowRivals.isEmpty {
                    PracticeShadowRivalPicker(
                        rivals: practice.shadowRivals,
                        selectedID: $shadowRivalID
                    )
                    .transition(Motion.appear)
                }

                if dynamicTypeSize.isAccessibilitySize {
                    startControl
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            if !dynamicTypeSize.isAccessibilitySize {
                startControl
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(Theme.ground)
            }
        }
        .moving(Motion.settle, value: showsError)
        .moving(Motion.settle, value: selection == .shadow)
        .background(Theme.ground)
        .presentationBackground(Theme.ground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.practice.sheet")
        .sensoryFeedback(.error, trigger: showsError) { _, new in new }
        .onAppear { hasAttempted = false }
    }

    private var showsError: Bool {
        hasAttempted && practice.failed && !practice.isStarting
    }

    private var isBusy: Bool {
        practice.isStarting || (hasAttempted && !practice.failed)
    }

    private var selectedShadowRival: PracticeShadowRival? {
        if let shadowRivalID, let match = practice.shadowRivals.first(where: { $0.id == shadowRivalID }) {
            return match
        }
        return practice.shadowRivals.first
    }

    private var startControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsError {
                Text(Self.startError)
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(Motion.appear)
                    .accessibilityIdentifier("competition.practice.error")
            }
            Button {
                hasAttempted = true
                if selection == .shadow, let rival = selectedShadowRival {
                    practice.start(.shadow(rival))
                } else {
                    practice.start(.bot(selection))
                }
            } label: {
                BusyLabel("Start Tomorrow", isBusy: isBusy)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isBusy || (selection == .shadow && selectedShadowRival == nil))
            .accessibilityLabel("Start Tomorrow")
            .accessibilityValue(isBusy ? "Action in progress" : "")
            .accessibilityIdentifier("competition.practice.start")
        }
    }
}

struct PracticeBotOptionCard: View {
    let difficulty: OpponentDifficulty
    let detail: String
    let bars: [CGFloat]
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        GroupMatchOptionCard(
            title: PracticeMatch.opponentDisplayName(for: difficulty),
            detail: detail,
            isSelected: isSelected,
            identifier: "competition.practice.pace.\(difficulty.rawValue)"
        ) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, height in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Theme.ink)
                        .frame(width: 5, height: height)
                }
            }
            .frame(height: 28, alignment: .bottom)
        } action: {
            action()
        }
    }
}

struct PracticeShadowOptionCard: View {
    let activeRival: PracticeShadowRival?
    let hasRivals: Bool
    let isSelected: Bool
    let action: () -> Void

    private var bars: [CGFloat] {
        guard isSelected || hasRivals, let activeRival else {
            return PracticeMatchSheet.shadowDefaultBars
        }
        return activeRival.profile.weekdayBarHeights(maxHeight: 28).map(CGFloat.init)
    }

    var body: some View {
        PracticeBotOptionCard(
            difficulty: .shadow,
            detail: hasRivals ? PracticeMatchSheet.shadowDetail : PracticeMatchSheet.shadowLockedDetail,
            bars: bars,
            isSelected: isSelected,
            action: action
        )
        .disabled(!hasRivals)
        .compositingGroup()
        .opacity(hasRivals ? 1 : 0.55)
    }
}

struct PracticeShadowRivalPicker: View {
    let rivals: [PracticeShadowRival]
    @Binding var selectedID: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var activeID: String? {
        if let selectedID, rivals.contains(where: { $0.id == selectedID }) {
            return selectedID
        }
        return rivals.first?.id
    }

    var body: some View {
        let inset: CGFloat = dynamicTypeSize.isAccessibilitySize ? 14 : 62
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("RIVAL").padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(rivals.enumerated()), id: \.element.id) { index, rival in
                    if index > 0 { CompetitionRowDivider(inset: inset) }
                    rivalRow(rival, isSelected: activeID == rival.id)
                }
            }
            .themePanel()
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .sensoryFeedback(.selection, trigger: activeID)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.practice.shadow.rivals")
    }

    private func rivalRow(_ rival: PracticeShadowRival, isSelected: Bool) -> some View {
        let stacks = dynamicTypeSize.isAccessibilitySize
        let layout = stacks
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        let rowID = rival.profileID?.uuidString.lowercased() ?? rival.id
        return Button {
            selectedID = rival.id
        } label: {
            HStack(spacing: 12) {
                layout {
                    PersonAvatar(name: rival.displayName, photo: rival.profileID, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rival.displayName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(rival.summaryLine)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(isSelected ? Theme.ink : Theme.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(CompetitionRowButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rival.displayName), \(rival.summaryLine)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("competition.practice.shadow.rival.\(rowID)")
    }
}
