import SwiftUI

struct ClaimCompetitionView: View {
    let status: MainTabFeature.InviteClaimStatus
    let accept: () -> Void
    let decline: () -> Void
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 12)
                statusEmblem
                VStack(spacing: 10) {
                    Text(title)
                        .font(.title.weight(.heavy).width(.condensed))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .font(.body)
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 440)

                if status == .ready {
                    privacyCard
                }

                Spacer(minLength: 12)
                actionControls
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.ground)
            .navigationTitle("Competition Invitation")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(
            status == .claiming || status == .waitingForCompetition
        )
        .accessibilityIdentifier("competition.claim.sheet")
    }

    private var statusEmblem: some View {
        ZStack {
            Circle()
                .fill(Theme.panel)
                .frame(width: 104, height: 104)
            statusIcon
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .claiming, .waitingForCompetition:
            ProgressView()
                .controlSize(.large)
                .tint(Theme.ink)
        case .confirmationTimedOut:
            symbol("clock.badge.exclamationmark")
        case .unavailable:
            symbol("link.badge.plus")
        case .retryable:
            symbol("wifi.exclamationmark")
        case .idle, .ready:
            BrandMark().frame(width: 58)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 40, weight: .semibold))
            .foregroundStyle(Theme.ink)
    }

    private var privacyCard: some View {
        VStack(spacing: 0) {
            CompetitionRuleRow(icon: .symbol("calendar"), title: "Seven calendar days")
            CompetitionRuleDivider()
            CompetitionRuleRow(
                icon: .rings,
                title: "Up to 600 points each day",
                detail: "1 point for every 1% of each ring"
            )
            CompetitionRuleDivider()
            CompetitionRuleRow(
                icon: .symbol("lock.iphone"),
                title: "Raw Health data stays on this iPhone"
            )
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: 440)
        .themePanel(cornerRadius: 18)
    }

    @ViewBuilder
    private var actionControls: some View {
        switch status {
        case .ready:
            VStack(spacing: 8) {
                Button("Accept Invitation", action: accept)
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 440)
                    .accessibilityHint(
                        "Claims the private invitation and schedules the competition."
                    )
                    .accessibilityIdentifier("competition.claim.accept")
                quietButton("Decline Invitation", role: .destructive, action: decline)
                    .accessibilityHint(
                        "Closes this invitation on this device without joining."
                    )
                    .accessibilityIdentifier("competition.claim.decline")
            }

        case .retryable:
            VStack(spacing: 8) {
                Button("Try Again", action: retry)
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 440)
                    .accessibilityIdentifier("competition.claim.retry")
                quietButton("Decline Invitation", role: .destructive, action: decline)
                    .accessibilityIdentifier("competition.claim.decline")
            }

        case .confirmationTimedOut:
            VStack(spacing: 12) {
                Button("Try Refreshing", action: retry)
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 440)
                    .accessibilityIdentifier(
                        "competition.claim.refresh-confirmation"
                    )
                Button("Done", action: dismiss)
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(maxWidth: 440)
                    .accessibilityIdentifier("competition.claim.dismiss")
            }

        case .unavailable:
            Button("Done", action: dismiss)
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 440)
                .accessibilityIdentifier("competition.claim.dismiss")

        case .claiming, .waitingForCompetition:
            Text("Keep HealthComp open for a moment.")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)

        case .idle:
            EmptyView()
        }
    }

    // Declining is quiet and neutral; color is reserved for you and your rings.
    private func quietButton(
        _ title: String,
        role: ButtonRole?,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.headline.width(.condensed))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: 440, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        switch status {
        case .idle, .ready:
            "Join this competition?"
        case .claiming:
            "Accepting invitation…"
        case .waitingForCompetition:
            "Confirming competition…"
        case .confirmationTimedOut:
            "Still waiting for confirmation"
        case .unavailable:
            "Invitation unavailable"
        case .retryable:
            "Couldn’t connect"
        }
    }

    private var message: String {
        switch status {
        case .idle, .ready:
            "Accept to start a private seven-day Activity competition on the creator’s calendar schedule."
        case .claiming:
            "HealthComp is securely claiming this single-use invitation."
        case .waitingForCompetition:
            "The server accepted your invitation. Waiting for the confirmed competition before opening it."
        case .confirmationTimedOut:
            "The server accepted your invitation, but HealthComp has not received the confirmed competition yet. Try refreshing or check Sharing later."
        case .unavailable:
            "This link may be expired, already used, or no longer valid. Ask the sender for a new invitation."
        case .retryable:
            "The invitation is still private on this device. Check your connection and try again."
        }
    }
}
