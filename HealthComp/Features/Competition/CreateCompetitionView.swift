import CompetitionCore
import SwiftUI

/// The drawer behind Home's + button: the rules, the calendar's time zone
/// and one private, single-use link.
struct CreateCompetitionView: View {
    let status: CompetitionFeature.ChallengeSheetStatus
    let timeZoneIdentifier: String
    let evaluatedAt: Date
    @Binding var recipientCode: String
    let recipient: AuthenticatedProfile?
    let recipientStatus: CompetitionFeature.InviteRecipientStatus
    let senderName: String?
    let findRecipient: () -> Void
    let create: () -> Void
    let openChallenge: (CompetitionID) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
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
                Text(competitionTimeZoneText(timeZoneIdentifier, locale: locale))
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .accessibilityIdentifier("competition.create.time-zone")
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
            if recipientCodeIsFocused {
                Button("Done") { recipientCodeIsFocused = false }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("competition.create.keyboard-done")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Theme.ground)
            } else if pinsControl {
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
        .onChange(of: recipientStatus) { _, newValue in
            if let text = competitionRecipientErrorText(newValue) {
                announce(text)
            }
        }
        .onChange(of: recipient?.id) { _, newValue in
            if newValue != nil, let recipient {
                announce("Found \(recipient.displayName)")
            }
        }
        .onChange(of: status) { oldValue, newValue in
            switch newValue {
            case .sent:
                if case .sent = oldValue { return }
                announce("Challenge sent")
            case let .failed(failure):
                announce(competitionInviteFailureText(failure, opponentName: recipientName))
            case .ready, .creating, .alreadyChallenged:
                break
            }
        }
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    private var isLocked: Bool {
        switch status {
        case .creating, .sent: true
        case .ready, .alreadyChallenged, .failed: false
        }
    }

    private var canFind: Bool {
        !isLocked
            && recipientStatus != .lookingUp
            && !recipientCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func find() {
        recipientCodeIsFocused = false
        findRecipient()
    }

    private var recipientName: String {
        recipient?.displayName ?? "them"
    }

    private func moment(_ date: Date) -> String {
        competitionMomentText(date, now: evaluatedAt, locale: locale, timeZone: timeZone)
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
            TextField("HealthComp account code", text: $recipientCode)
                .focused($recipientCodeIsFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .submitLabel(.search)
                .onSubmit { if canFind { find() } }
                .padding(12)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 10))
                .disabled(isLocked)
                .accessibilityIdentifier("competition.create.recipient-code")
            Button("Find Account", action: find)
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!canFind)
                .accessibilityIdentifier("competition.create.find-recipient")
            if recipientStatus == .lookingUp {
                ProgressView("Finding account…")
            } else if let error = competitionRecipientErrorText(recipientStatus) {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("competition.create.recipient-error")
            }
            if let recipient {
                Text("Challenge \(recipient.displayName)")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("competition.create.recipient-name")
                Text("Confirm this is the person you intended before creating the challenge.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .foregroundStyle(Theme.ink)
    }

    private var title: String {
        if case .sent = status { return "Challenge sent" }
        return "Challenge someone"
    }

    @ViewBuilder
    private var control: some View {
        switch status {
        case .ready:
            createButton(title: "Create Challenge")

        case let .alreadyChallenged(challenge):
            VStack(alignment: .leading, spacing: 10) {
                Text(alreadyChallengedText(challenge))
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("competition.create.already-pending")
                Button("Open Challenge") { openChallenge(challenge.id) }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("competition.create.open-existing")
            }

        case .creating:
            HStack(spacing: 10) {
                ProgressView()
                Text("Creating challenge…")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Creating challenge")

        case let .sent(_, challenge, link):
            sentControl(challenge: challenge, link: link)

        case .failed(.connection):
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    competitionInviteFailureText(.connection, opponentName: recipientName),
                    systemImage: "wifi.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .accessibilityIdentifier("competition.create.send-error")
                createButton(title: "Try Again")
            }

        case .failed(.unavailable):
            Label(
                competitionInviteFailureText(.unavailable, opponentName: recipientName),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(Theme.secondary)
            .accessibilityIdentifier("competition.create.configuration-error")

        case let .failed(failure):
            Text(competitionInviteFailureText(failure, opponentName: recipientName))
                .font(.callout)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("competition.create.already-pending")
        }
    }

    @ViewBuilder
    private func sentControl(
        challenge: LocalCompetitionPresentation?,
        link: CompetitionInviteShareLink?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let challenge, !challenge.isPending {
                // Accepted while the sheet was open.
                Text(competitionStatusText(challenge, style: .row, locale: locale, timeZone: timeZone).line)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            } else {
                if let link {
                    ShareLink(
                        item: competitionShareMessage(senderName: senderName, link: link),
                        subject: Text("Join my HealthComp match")
                    ) {
                        Label("Share Challenge", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityHint(
                        "Opens the system share sheet. The private link is not read aloud."
                    )
                    .accessibilityIdentifier("competition.create.share")
                }
                Text(waitingText(challenge))
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func waitingText(_ challenge: LocalCompetitionPresentation?) -> String {
        let name = challenge?.opponentDisplayName ?? recipientName
        if let expiresAt = challenge?.pendingExpiresAt {
            return "Waiting for \(name). Expires \(moment(expiresAt))."
        }
        return "Waiting for \(name). Expires in 24 hours."
    }

    private func alreadyChallengedText(_ challenge: LocalCompetitionPresentation) -> String {
        let sentence = "You already challenged \(challenge.opponentDisplayName)."
        guard let expiresAt = challenge.pendingExpiresAt else { return sentence }
        return "\(sentence) Expires \(moment(expiresAt))."
    }

    private func createButton(title: String) -> some View {
        Button(title, action: create)
            .buttonStyle(PrimaryButtonStyle())
            .disabled(recipient == nil || recipientStatus == .lookingUp)
            .accessibilityIdentifier("competition.create.button")
    }
}

extension LocalCompetitionPresentation {
    var isPending: Bool {
        if case .pending = lifecycle { return true }
        return false
    }

    var pendingExpiresAt: Date? {
        if case let .pending(_, _, expiresAt) = lifecycle { return expiresAt }
        return nil
    }
}

/// "Days run midnight to midnight, Pacific Time."
func competitionTimeZoneText(_ identifier: String, locale: Locale = .current) -> String {
    let name = TimeZone(identifier: identifier)?
        .localizedName(for: .generic, locale: locale) ?? identifier
    return "Days run midnight to midnight, \(name)."
}

/// One string, so Copy carries the whole link.
func competitionShareMessage(
    senderName: String?,
    link: CompetitionInviteShareLink
) -> String {
    guard let senderName, !senderName.isEmpty else {
        return "Join me for a week of rings on HealthComp: \(link.url.absoluteString)"
    }
    return "\(senderName) challenged you to a week of rings on HealthComp: \(link.url.absoluteString)"
}

func competitionRecipientErrorText(
    _ status: CompetitionFeature.InviteRecipientStatus
) -> String? {
    switch status {
    case .idle, .lookingUp: nil
    case .invalidCode: "That isn’t a full account code. Ask them to share it again."
    case .ownCode: "That’s your own code. Ask them for theirs."
    case .notFound: "No account has this code. Check it and try again."
    case .connectionFailed: "Couldn’t look up that code. Check your connection and try again."
    }
}

func competitionInviteFailureText(
    _ failure: CompetitionFeature.InviteCreationFailure,
    opponentName: String
) -> String {
    switch failure {
    case .connection:
        return "Couldn’t send the challenge. Check your connection and try again."
    case .unavailable:
        #if DEBUG || HEALTHCOMP_STAGING
        return "Challenge links are not configured for this build."
        #else
        return "Challenges aren’t available right now."
        #endif
    case .recipientGone:
        return "\(opponentName) isn’t on HealthComp anymore."
    case .alreadyPending:
        return "You already challenged \(opponentName). It expires 24 hours after you sent it."
    }
}
