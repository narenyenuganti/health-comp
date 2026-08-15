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
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
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
            .background(Color(.systemGroupedBackground))
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
                .fill(emblemColor.opacity(0.16))
                .frame(width: 104, height: 104)
            statusIcon
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(emblemColor)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .claiming, .waitingForCompetition:
            ProgressView()
                .controlSize(.large)
        case .confirmationTimedOut:
            Image(systemName: "clock.badge.exclamationmark")
        case .unavailable:
            Image(systemName: "link.badge.plus")
        case .retryable:
            Image(systemName: "wifi.exclamationmark")
        case .idle, .ready:
            Image(systemName: "person.2.badge.plus")
        }
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Seven calendar days", systemImage: "calendar")
            Label("Up to 600 points each day", systemImage: "gauge.with.dots.needle.67percent")
            Label(
                "Raw Health data stays on this iPhone",
                systemImage: "lock.iphone"
            )
        }
        .font(.subheadline.weight(.medium))
        .frame(maxWidth: 440, alignment: .leading)
        .padding(18)
        .background(
            .background,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }

    @ViewBuilder
    private var actionControls: some View {
        switch status {
        case .ready:
            VStack(spacing: 12) {
                Button("Accept Invitation", action: accept)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: 440, minHeight: 44)
                    .accessibilityHint(
                        "Claims the private invitation and schedules the competition."
                    )
                    .accessibilityIdentifier("competition.claim.accept")
                Button("Decline Invitation", role: .destructive, action: decline)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: 440, minHeight: 44)
                    .accessibilityHint(
                        "Closes this invitation on this device without joining."
                    )
                    .accessibilityIdentifier("competition.claim.decline")
            }

        case .retryable:
            VStack(spacing: 12) {
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: 440, minHeight: 44)
                    .accessibilityIdentifier("competition.claim.retry")
                Button("Decline Invitation", role: .destructive, action: decline)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: 440, minHeight: 44)
                    .accessibilityIdentifier("competition.claim.decline")
            }

        case .confirmationTimedOut:
            VStack(spacing: 12) {
                Button("Try Refreshing", action: retry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: 440, minHeight: 44)
                    .accessibilityIdentifier(
                        "competition.claim.refresh-confirmation"
                    )
                Button("Done", action: dismiss)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: 440, minHeight: 44)
                    .accessibilityIdentifier("competition.claim.dismiss")
            }

        case .unavailable:
            Button("Done", action: dismiss)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: 440, minHeight: 44)
                .accessibilityIdentifier("competition.claim.dismiss")

        case .claiming, .waitingForCompetition:
            Text("Keep HealthComp open for a moment.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

        case .idle:
            EmptyView()
        }
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

    private var emblemColor: Color {
        switch status {
        case .unavailable:
            .orange
        case .retryable:
            .red
        case .idle, .ready, .claiming, .waitingForCompetition:
            .indigo
        case .confirmationTimedOut:
            .orange
        }
    }
}
