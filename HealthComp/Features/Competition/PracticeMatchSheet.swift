import CompetitionCore
import SwiftUI

/// What Home needs to offer a practice match.
struct CompetitionPracticeStart {
    let isStarting: Bool
    let failed: Bool
    let start: (OpponentDifficulty) -> Void
}

/// Pick a pace; the practice starts tomorrow like a real match.
struct PracticeMatchSheet: View {
    let practice: CompetitionPracticeStart

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selection: OpponentDifficulty = .balanced
    /// `commandRejected` lingers in the dashboard, so only a Start tapped in
    /// this presentation shows the error.
    @State private var hasAttempted = false

    private static let paces: [(OpponentDifficulty, String, String)] = [
        (.relaxed, "Relaxed", "About half your usual rings"),
        (.balanced, "Balanced", "About your usual rings"),
        (.challenging, "Challenging", "A bit more than usual"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Practice Match")
                        .font(.title3.weight(.heavy).width(.condensed))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("7 days against a pacer. It doesn’t count toward your record.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 0) {
                    ForEach(Array(Self.paces.enumerated()), id: \.offset) { index, pace in
                        if index > 0 {
                            CompetitionRowDivider(inset: 16)
                        }
                        paceRow(pace.0, title: pace.1, detail: pace.2)
                    }
                }
                .themePanel()
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                // At accessibility sizes a pinned button would cover the rows.
                if dynamicTypeSize.isAccessibilitySize {
                    startControl
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
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
        .background(Theme.ground)
        .presentationDetents([.medium, .large])
        // At AX sizes the rows overflow the medium height: a drag scrolls
        // them, and the grabber still resizes.
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.ground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.practice.sheet")
        .onAppear { hasAttempted = false }
    }

    private func paceRow(
        _ difficulty: OpponentDifficulty,
        title: String,
        detail: String
    ) -> some View {
        let isSelected = selection == difficulty
        return Button {
            selection = difficulty
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    // At AX sizes a full-size mark would split "Challenging".
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(isSelected ? Theme.ink : Theme.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(CompetitionRowButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("competition.practice.pace.\(difficulty.rawValue)")
    }

    private var startControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasAttempted, practice.failed, !practice.isStarting {
                Text("Couldn’t start the practice match. Try again.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("competition.practice.error")
            }
            Button {
                hasAttempted = true
                practice.start(selection)
            } label: {
                if practice.isStarting {
                    ProgressView()
                } else {
                    Text("Start Tomorrow")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(practice.isStarting)
            .accessibilityLabel("Start Tomorrow")
            .accessibilityValue(practice.isStarting ? "Action in progress" : "")
            .accessibilityIdentifier("competition.practice.start")
        }
    }
}
