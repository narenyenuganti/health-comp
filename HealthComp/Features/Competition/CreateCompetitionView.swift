import SwiftUI

struct CreateCompetitionView: View {
    let status: CompetitionFeature.InviteCreationStatus
    let shareLink: CompetitionInviteShareLink?
    let timeZoneIdentifier: String
    let create: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Invite someone", systemImage: "person.badge.plus")
                .font(.headline)
                .foregroundStyle(.primary)
            Text(
                "Create a private, single-use link for a seven-day Activity competition."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Text("Your competition calendar uses \(timeZoneIdentifier).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    "Competition time zone, \(timeZoneIdentifier)"
                )

            control
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            .background,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.create.card")
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
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Creating private invitation")

        case .ready:
            if let shareLink {
                ShareLink(
                    item: shareLink.url,
                    subject: Text("Join my HealthComp competition"),
                    message: Text(
                        "Open this private link to join my seven-day HealthComp competition."
                    )
                ) {
                    Label("Share Private Invitation", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(minHeight: 44)
                .accessibilityHint(
                    "Opens the system share sheet. The private link is not read aloud."
                )
                .accessibilityIdentifier("competition.create.share")
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
                .foregroundStyle(.secondary)
                createButton(title: "Try Again")
            }

        case .configurationUnavailable:
            Label(
                "Private invitation links are not configured for this build.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .accessibilityIdentifier("competition.create.configuration-error")
        }
    }

    private func createButton(title: String) -> some View {
        Button(title, action: create)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("competition.create.button")
    }
}
