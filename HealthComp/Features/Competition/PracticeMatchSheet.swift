import CompetitionCore
import SwiftUI

/// What Home needs to offer a practice match.
struct CompetitionPracticeStart {
    let isStarting: Bool
    let failed: Bool
    let start: (OpponentDifficulty) -> Void
}

/// Pick a bot; the practice starts tomorrow like a real match.
struct PracticeMatchSheet: View {
    let practice: CompetitionPracticeStart

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selection: OpponentDifficulty = .pacer
    /// `commandRejected` lingers in the dashboard, so only a Start tapped in
    /// this presentation shows the error.
    @State private var hasAttempted = false

    /// Each bot's week as seven bars, tallest 28 pt.
    private static let bots: [(OpponentDifficulty, String, [CGFloat])] = [
        (.pacer, "Your usual week, steady every day.", [18, 19, 18, 19, 18, 19, 18]),
        (.chill, "A little under your usual. Starts slow.", [8, 9, 10, 11, 12, 13, 14]),
        (.erratic, "Huge days and off days. Hard to read.", [26, 6, 24, 10, 28, 5, 20]),
        (.beast, "Well above your usual, every day.", [24, 25, 26, 26, 27, 28, 28]),
    ]

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
                    Text("Seven days against a bot, scaled to your last two weeks. It doesn’t count toward your record.")
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 10) {
                    ForEach(Self.bots, id: \.0) { bot in
                        botRow(bot.0, detail: bot.1, bars: bot.2)
                    }
                }
                .sensoryFeedback(.selection, trigger: selection)

                // At accessibility sizes a pinned button would cover the rows.
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

    /// `isStarting` clears a tick before the sheet closes, so a start that
    /// didn't fail stays busy until it has gone.
    private var isBusy: Bool {
        practice.isStarting || (hasAttempted && !practice.failed)
    }

    private func botRow(
        _ difficulty: OpponentDifficulty,
        detail: String,
        bars: [CGFloat]
    ) -> some View {
        let isSelected = selection == difficulty
        let title = PracticeMatch.opponentDisplayName(for: difficulty)
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return Button {
            selection = difficulty
        } label: {
            HStack(spacing: 16) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { _, height in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Theme.ink)
                            .frame(width: 5, height: height)
                    }
                }
                .frame(height: 28, alignment: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.bold))
                        .foregroundStyle(Theme.ink)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .background(Theme.panel, in: shape)
            .overlay {
                shape.strokeBorder(isSelected ? Theme.ink : Theme.panel, lineWidth: 2)
                    .animation(Motion.fade, value: isSelected)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("competition.practice.pace.\(difficulty.rawValue)")
    }

    private var startControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsError {
                Text("Couldn’t start the practice match. Try again.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(Motion.appear)
                    .accessibilityIdentifier("competition.practice.error")
            }
            Button {
                hasAttempted = true
                practice.start(selection)
            } label: {
                BusyLabel("Start Tomorrow", isBusy: isBusy)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isBusy)
            .accessibilityLabel("Start Tomorrow")
            .accessibilityValue(isBusy ? "Action in progress" : "")
            .accessibilityIdentifier("competition.practice.start")
        }
    }
}
