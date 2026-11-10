import CompetitionCore
import SwiftUI

/// Explains Health access or competition notifications before iOS asks.
struct PermissionOnboardingView: View {
    let step: PermissionOnboardingStep
    let isRequesting: Bool
    /// Accept was tapped on a challenge, so Health is asked in its terms.
    var isForChallenge = false
    let continueTapped: () -> Void
    let notNowTapped: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Accessibility sizes scroll the actions with the text; pinned, they
        // would squeeze both.
        let pinsActions = !dynamicTypeSize.isAccessibilitySize
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                switch step {
                case .health: healthDetails
                case .notifications: notificationExamples
                }
                if !pinsActions {
                    actions
                }
            }
            .padding(24)
            .frame(maxWidth: 480, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            if pinsActions {
                actions
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
                    .background(Theme.ground)
            }
        }
        .background(Theme.ground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(step == .health ? "HEALTH" : "NOTIFICATIONS")
                .font(.themeLabel)
                .tracking(1.4)
                .foregroundStyle(Theme.secondary)
            Text(title)
                .font(.largeTitle.weight(.heavy).width(.condensed))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.body)
                .foregroundStyle(Theme.secondary)
        }
    }

    private var title: String {
        switch step {
        case .health:
            isForChallenge
                ? "Connect Health so your rings count"
                : "Score with your rings"
        case .notifications:
            "Know when the lead changes"
        }
    }

    private var message: String {
        switch step {
        case .health:
            isForChallenge
                ? "HealthComp reads your Activity rings to score each match day. You’ll join the match right after."
                : "HealthComp reads your Activity rings to score each match day."
        case .notifications:
            "HealthComp sends match moments, like these, and friend requests."
        }
    }

    private var healthDetails: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 14) {
                ringRow(Theme.move, "Move", "Calories or move time toward your goal")
                ringRow(Theme.exercise, "Exercise", "Minutes of brisk activity")
                ringRow(
                    Theme.stand,
                    "Stand",
                    "Hours you stood, or rolled, and moved for a minute"
                )
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Text("1 point for every 1% of each ring, up to 600 a day.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themePanel(cornerRadius: 18)

            VStack(alignment: .leading, spacing: 0) {
                privacyRow(
                    "iphone",
                    "Scored on this iPhone",
                    "Raw Health data stays on it"
                )
                Rectangle().fill(Theme.hairline).frame(height: 1)
                privacyRow(
                    "lock",
                    "Derived match data is shared",
                    "Daily points, rounded Activity percentages and modes"
                )
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themePanel(cornerRadius: 18)
        }
    }

    private func ringRow(
        _ color: Color,
        _ title: String,
        _ detail: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            SlantedBar().fill(color).frame(width: 22, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func privacyRow(
        _ systemImage: String,
        _ title: String,
        _ detail: String
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    // The planner's real copy, with sample names and scores.
    private var notificationExamples: some View {
        VStack(spacing: 10) {
            ForEach(Array(Self.notificationSamples.enumerated()), id: \.offset) { _, sample in
                exampleNotification(sample.time, sample.content.title, sample.content.body)
            }
            Text("Mute anyone from your match with them.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
    }

    /// Generated by the live policy, so the samples can't drift from it.
    private static let notificationSamples: [(time: String, content: CompetitionNotificationContent)] = {
        let sampleID = CompetitionID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        func sample(
            _ family: CompetitionNotificationMessageFamily,
            _ ownerPoints: Double? = nil,
            _ opponentPoints: Double? = nil,
            _ outcome: CompetitionOutcome? = nil
        ) -> CompetitionNotificationContent {
            CompetitionNotificationPolicy.liveV1.content(
                CompetitionNotificationMessage(
                    family: family,
                    competitionID: sampleID,
                    opponentDisplayName: "Alex",
                    ownerPoints: ownerPoints,
                    opponentPoints: opponentPoints,
                    outcome: outcome
                )
            )
        }
        return [
            ("now", sample(.opportunistic(.leadChange), 1_217, 1_194)),
            ("earlier", sample(.scheduled(.finalDay))),
            ("Wed", sample(.opportunistic(.result), 2_431, 2_198, .win)),
        ]
    }()

    private func exampleNotification(
        _ time: String,
        _ title: String,
        _ body: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            BrandMark()
                .frame(width: 26)
                .frame(width: 36, height: 36)
                .background(
                    Theme.ground,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.hairline)
                )
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("HEALTHCOMP")
                        .font(.caption.weight(.bold).width(.condensed))
                        .tracking(1.2)
                        .foregroundStyle(Theme.secondary)
                    // The time is decoration; at accessibility sizes it
                    // would break the app name mid-word.
                    if !dynamicTypeSize.isAccessibilitySize {
                        Spacer(minLength: 8)
                        Text(time)
                            .font(.caption)
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themePanel(cornerRadius: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example notification. \(title). \(body)")
    }

    private var actions: some View {
        VStack(spacing: 6) {
            Button(
                step == .health ? "Connect Health" : "Turn On Notifications",
                action: continueTapped
            )
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("onboarding.continue")
            if step == .health {
                Text("iOS will ask which Activity data to share.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            } else {
                Button("Not now", action: notNowTapped)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("onboarding.notNow")
            }
        }
        .disabled(isRequesting)
    }
}
