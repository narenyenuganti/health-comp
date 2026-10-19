import SwiftUI

/// The drawer behind Home's + button: the rules, the calendar's time zone
/// and one private, single-use link.
struct CreateCompetitionView: View {
    let status: CompetitionFeature.InviteCreationStatus
    let shareLink: CompetitionInviteShareLink?
    let timeZoneIdentifier: String
    @Binding var recipientCode: String
    let recipient: AuthenticatedProfile?
    let recipientStatus: CompetitionFeature.InviteRecipientStatus
    let findRecipient: () -> Void
    let create: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var recipientCodeIsFocused: Bool

    var body: some View {
        // Accessibility sizes scroll the control with the text; pinned, they
        // would squeeze both.
        let pinsControl = !dynamicTypeSize.isAccessibilitySize
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                recipientSelection
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
        .scrollDismissesKeyboard(.interactively)
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
                    "Choose an existing HealthComp account. Only that account can accept your private link, which expires after 24 hours."
                )
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            CompetitionDrawerCloseButton { dismiss() }
                .accessibilityIdentifier("competition.create.done")
        }
    }

    private var recipientSelection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RECIPIENT")
                .font(.themeLabel)
                .foregroundStyle(Theme.secondary)
            Text("Ask them to share their HealthComp account code from Account.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
            TextField("HealthComp account code", text: $recipientCode, axis: .vertical)
                .focused($recipientCodeIsFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .lineLimit(3, reservesSpace: true)
                .padding(12)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 10))
                .disabled(status == .creating)
                .accessibilityIdentifier("competition.create.recipient-code")
            Button("Find Account") {
                recipientCodeIsFocused = false
                findRecipient()
            }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(status == .creating || recipientStatus == .lookingUp)
                .accessibilityIdentifier("competition.create.find-recipient")
            if recipientStatus == .lookingUp {
                ProgressView("Finding account…")
            } else if recipientStatus == .unavailable {
                Text("This account couldn’t be found. Check the code and connection, then try again.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
            }
            if let recipient {
                Text("Invite \(recipient.displayName)")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("competition.create.recipient-name")
                Text("Confirm this is the person you intended before creating the invitation.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .foregroundStyle(Theme.ink)
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
                        "Waiting for \(recipient?.displayName ?? "the chosen account") to accept. Only that account can use this link, within 24 hours of creation.",
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

        case .pendingInvitationExists:
            Text("An invitation to this account is already pending. Check your outgoing invitations; it expires 24 hours after creation.")
                .font(.callout)
                .foregroundStyle(Theme.secondary)
                .accessibilityIdentifier("competition.create.already-pending")
        }
    }

    private func createButton(title: String) -> some View {
        Button(title, action: create)
            .buttonStyle(PrimaryButtonStyle())
            .disabled(recipient == nil || recipientStatus == .lookingUp)
            .accessibilityIdentifier("competition.create.button")
    }
}
