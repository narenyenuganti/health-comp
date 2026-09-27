import SwiftUI

/// Explains Health access or competition notifications before iOS asks.
struct PermissionOnboardingView: View {
    let step: PermissionOnboardingStep
    let isRequesting: Bool
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
            Text(
                step == .health
                    ? "Score with your rings"
                    : "Know when the lead changes"
            )
            .font(.largeTitle.weight(.heavy).width(.condensed))
            .foregroundStyle(Theme.ink)
            .accessibilityAddTraits(.isHeader)
            Text(
                step == .health
                    ? "HealthComp reads your Activity rings to score each competition day."
                    : "HealthComp only sends competition moments, like these."
            )
            .font(.body)
            .foregroundStyle(Theme.secondary)
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
                    "Only daily points are shared",
                    "Your opponent never sees your rings"
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
            exampleNotification(
                "now",
                "Lead change",
                "The lead changed in your competition with Alex. You 1,217, Alex 1,194."
            )
            exampleNotification(
                "9:00 AM",
                "Final competition day",
                "Today is the final day of your activity competition with Alex."
            )
            exampleNotification(
                "Wed",
                "Competition complete",
                "You won. You 2,431, Alex 2,198."
            )
            Text("Mute any opponent from Home.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
    }

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
