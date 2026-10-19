import SwiftUI

/// The drawer behind Home's + button: the rules, the calendar's time zone
/// and one private, single-use link.
struct CreateCompetitionView: View {
    let status: CompetitionFeature.InviteCreationStatus
    let shareLink: CompetitionInviteShareLink?
    let timeZoneIdentifier: String
    let create: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Accessibility sizes scroll the control with the text; pinned, they
        // would squeeze both.
        let pinsControl = !dynamicTypeSize.isAccessibilitySize
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                CompetitionRulesCard(source: .remoteParticipants)
                Text("Your competition calendar uses \(timeZoneIdentifier).")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .accessibilityLabel(
                        "Competition time zone, \(timeZoneIdentifier)"
                    )
                if !pinsControl {
                    control
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            if pinsControl {
                control
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(Theme.ground)
            }
        }
        .background(Theme.ground)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.ground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.create.card")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            // The opponent's slot, still empty.
            SlantedBar()
                .stroke(
                    Theme.tertiary,
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                )
                .frame(width: 16, height: 30)
                .padding(.horizontal, 6)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.heavy).width(.condensed))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(
                    "Create a private, single-use link for a seven-day Activity competition."
                )
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            CompetitionDrawerCloseButton { dismiss() }
                .accessibilityIdentifier("competition.create.done")
        }
    }

    private var title: String {
        status == .ready && shareLink != nil
            ? "Challenge ready"
            : "Challenge someone"
    }

    @ViewBuilder
    private var control: some View {
        switch status {
        case .idle:
            createButton(title: "Create Private Invitation")

        case .creating:
            HStack(spacing: 10) {
                ProgressView()
                Text("Creating invitation…")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Creating private invitation")

        case .ready:
            if let shareLink {
                VStack(alignment: .leading, spacing: 10) {
                    ShareLink(
                        item: shareLink.url.absoluteString,
                        subject: Text("Join my HealthComp competition")
                    ) {
                        Label(
                            "Share Private Invitation",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityHint(
                        "Opens the system share sheet. The private link is not read aloud."
                    )
                    .accessibilityIdentifier("competition.create.share")

                    Label(
                        "Waiting for someone to accept. The link works once.",
                        systemImage: "hourglass"
                    )
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                }
            } else {
                createButton(title: "Try Again")
            }

        case .retryable:
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    "HealthComp couldn’t create the invitation. Your request can be retried safely.",
                    systemImage: "wifi.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                createButton(title: "Try Again")
            }

        case .configurationUnavailable:
            Label(
                "Private invitation links are not configured for this build.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(Theme.secondary)
            .accessibilityIdentifier("competition.create.configuration-error")
        }
    }

    private func createButton(title: String) -> some View {
        Button(title, action: create)
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("competition.create.button")
    }
}
