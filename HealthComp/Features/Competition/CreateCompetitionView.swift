import CompetitionCore
import SwiftUI

/// The drawer behind Home's + button: a friend, or someone else by search
/// or their link; then the rules, the calendar's time zone and one private,
/// single-use link.
struct CreateCompetitionView: View {
    let status: CompetitionFeature.ChallengeSheetStatus
    let timeZoneIdentifier: String
    let evaluatedAt: Date
    @Binding var recipientCode: String
    let recipient: CompetitionFeature.InviteRecipient?
    let recipientStatus: CompetitionFeature.InviteRecipientStatus
    let senderName: String?
    /// Your own challenge link; Share Your Link shows once it has loaded.
    var ownChallengeLink: URL? = nil
    /// A FRIEND; empty omits the group.
    var friends: [FriendPerson] = []
    /// Your matches, to dim a friend you can't challenge now.
    var competitions: [LocalCompetitionPresentation] = []
    var chooseFriend: ((FriendPerson) -> Void)? = nil
    /// Closes the sheet on Friends' search; nil omits the row.
    var searchPeople: (() -> Void)? = nil
    let findRecipient: () -> Void
    let create: () -> Void
    let openChallenge: (CompetitionID) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @FocusState private var recipientCodeIsFocused: Bool
    /// Paste Their Challenge Link was tapped: the link field and Find show.
    @State private var entersLink = false

    /// Nobody chosen yet and no link being entered: the two groups.
    private var isPicking: Bool { recipient == nil && !entersLink }

    var body: some View {
        // Accessibility sizes scroll the control with the text; pinned, they
        // would squeeze both.
        let pinsControl = !dynamicTypeSize.isAccessibilitySize && !isPicking
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if isPicking {
                    picker
                } else {
                    recipientSelection
                    CompetitionRulesCard(source: .remoteParticipants)
                    Text(competitionTimeZoneText(timeZoneIdentifier, locale: locale))
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .accessibilityIdentifier("competition.create.time-zone")
                    if dynamicTypeSize.isAccessibilitySize {
                        controlSlot
                    }
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
                controlSlot
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(Theme.ground)
            }
        }
        // Here, so the inset and the rows under a new line move together.
        .moving(Motion.settle, value: status.controlPhase)
        .moving(Motion.settle, value: recipient?.displayName)
        .moving(Motion.settle, value: competitionRecipientErrorText(recipientStatus))
        .moving(Motion.settle, value: ownChallengeLink)
        .moving(Motion.settle, value: isPicking)
        .background(Theme.ground)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.ground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.create.card")
        .sensoryFeedback(.success, trigger: isSent) { !$0 && $1 }
        .sensoryFeedback(.error, trigger: status.controlPhase == .failed) { _, new in new }
        .sensoryFeedback(.error, trigger: recipientStatus) { _, new in
            competitionRecipientErrorText(new) != nil
        }
        .onChange(of: recipientStatus) { _, newValue in
            if let text = competitionRecipientErrorText(newValue) {
                announce(text)
            }
        }
        .onChange(of: recipient) { _, newValue in
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
                announce(failureText(failure))
            case .ready, .creating, .alreadyChallenged, .challengedYou, .inMatch:
                break
            }
        }
    }

    private func failureText(_ failure: CompetitionFeature.InviteCreationFailure) -> String {
        failure == .recipientGone
            ? "You can’t challenge \(recipientName) right now."
            : competitionInviteFailureText(failure, opponentName: recipientName)
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    private var isSent: Bool {
        status.controlPhase == .sent || status.controlPhase == .accepted
    }

    private var isLocked: Bool {
        switch status {
        case .creating, .sent: true
        case .ready, .alreadyChallenged, .challengedYou, .inMatch, .failed: false
        }
    }

    private var canFind: Bool {
        !isLocked
            && recipientStatus != .lookingUp
            && !recipientCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var codeBinding: Binding<String> {
        Binding(
            get: { recipientCode },
            set: { newValue in
                guard newValue.contains(where: \.isNewline) else {
                    recipientCode = newValue
                    return
                }
                let code = newValue.filter { !$0.isNewline }
                recipientCode = code
                if !isLocked, recipientStatus != .lookingUp,
                   !code.trimmingCharacters(in: .whitespaces).isEmpty {
                    find()
                }
            }
        )
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
            // The opponent's slot: empty, then filled in neutral ink once
            // the challenge is sent.
            ZStack {
                SlantedBar()
                    .stroke(
                        Theme.tertiary,
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )
                    .opacity(isSent ? 0 : 1)
                SlantedBar()
                    .fill(Theme.ink)
                    .opacity(isSent ? 1 : 0)
            }
            .animation(Motion.fade, value: isSent)
            .frame(width: 16, height: 30)
            .padding(.horizontal, 6)
            .padding(.top, 2)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.heavy).width(.condensed))
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.opacity)
                    .animation(Motion.fade, value: isSent)
                    .accessibilityAddTraits(.isHeader)
                if entersLink {
                    Text(
                        "Choose an existing HealthComp account. Only that account can accept your private link, which expires after 24 hours."
                    )
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            CompetitionDrawerCloseButton { dismiss() }
                .accessibilityIdentifier("competition.create.done")
        }
    }

    // MARK: Picker

    private var picker: some View {
        // Accessibility sizes stack the avatar or icon above the text, so
        // dividers start at the row's edge, as on Friends.
        let friendInset: CGFloat = dynamicTypeSize.isAccessibilitySize ? 14 : 66
        let actionInset: CGFloat = dynamicTypeSize.isAccessibilitySize ? 14 : 50
        return VStack(alignment: .leading, spacing: 22) {
            if !friends.isEmpty {
                pickerGroup("A FRIEND", id: "competition.create.friends") {
                    ForEach(Array(friends.enumerated()), id: \.element.id) { index, friend in
                        if index > 0 { CompetitionRowDivider(inset: friendInset) }
                        friendRow(friend)
                    }
                }
            }
            pickerGroup("SOMEONE ELSE", id: "competition.create.someone-else") {
                if let searchPeople {
                    Button(action: searchPeople) {
                        pickerRowLabel("Search People", systemImage: "magnifyingglass", opens: true)
                    }
                    .buttonStyle(CompetitionRowButtonStyle())
                    .accessibilityIdentifier("competition.create.search-people")
                    CompetitionRowDivider(inset: actionInset)
                }
                Button { entersLink = true } label: {
                    pickerRowLabel("Paste Their Challenge Link", systemImage: "link", opens: true)
                }
                .buttonStyle(CompetitionRowButtonStyle())
                .accessibilityIdentifier("competition.create.paste-link")
                if let ownChallengeLink {
                    CompetitionRowDivider(inset: actionInset)
                    ShareLink(
                        item: ownChallengeLink,
                        subject: Text("My HealthComp challenge link"),
                        message: Text("Challenge me to a week of rings on HealthComp.")
                    ) {
                        pickerRowLabel("Share Your Link", systemImage: "square.and.arrow.up", opens: false)
                    }
                    .buttonStyle(CompetitionRowButtonStyle())
                    .transition(Motion.appear)
                    .accessibilityIdentifier("competition.create.share-own-link")
                }
            }
        }
    }

    /// A friend you're already playing or challenging is dimmed and says so.
    /// The whole row dims from ink, as one image, so the reason stays
    /// readable and a photo never shows the initial behind it.
    private func friendRow(_ friend: FriendPerson) -> some View {
        let blocker: String? = friendChallengeBlocker(identity: friend.identity, competitions: competitions)
        let status: String? = friendStatusLine(
            identity: friend.identity,
            competitions: competitions,
            locale: locale,
            timeZone: timeZone
        )
        let detail: String = blocker ?? status ?? "No matches yet"
        let isDimmed: Bool = blocker != nil
        return Button { chooseFriend?(friend) } label: {
            HStack(spacing: 12) {
                FriendsPersonLabel(
                    person: friend,
                    detail: detail,
                    detailColor: isDimmed ? Theme.ink : Theme.secondary
                )
                if blocker == nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(CompetitionRowButtonStyle())
        .disabled(isDimmed || chooseFriend == nil)
        .compositingGroup()
        .opacity(isDimmed ? 0.55 : 1)
        .accessibilityIdentifier("competition.create.friend.\(friend.id.uuidString.lowercased())")
    }

    /// The icon sits above the title at accessibility sizes, as a friend's
    /// avatar does, so neither squeezes the other.
    private func pickerRowLabel(_ title: String, systemImage: String, opens: Bool) -> some View {
        let stacks: Bool = dynamicTypeSize.isAccessibilitySize
        let layout: AnyLayout = stacks
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return HStack(spacing: 12) {
            layout {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 24)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if opens {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    private func pickerGroup<Content: View>(
        _ title: String,
        id: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title).padding(.horizontal, 4)
            VStack(spacing: 0) { content() }
                .themePanel()
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }

    // MARK: Chosen

    private var recipientSelection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if entersLink {
                linkEntry
            }
            if let recipient {
                Text("Challenge \(recipient.displayName)")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(Motion.appear)
                    .accessibilityIdentifier("competition.create.recipient-name")
                Text("Confirm this is the person you intended before creating the challenge.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .transition(Motion.appear)
            }
        }
        .foregroundStyle(Theme.ink)
    }

    /// Their challenge link, Find, and your own to share: as before friends.
    @ViewBuilder
    private var linkEntry: some View {
        Text("THEIR CHALLENGE LINK")
            .font(.themeLabel)
            .foregroundStyle(Theme.secondary)
        Text("Paste the challenge link they shared. Or send them yours so they can challenge you.")
            .font(.subheadline)
            .foregroundStyle(Theme.secondary)
        // A long code wraps instead of clipping, and the reserved lines
        // keep the field itself a 44 pt target (a one-line field fails
        // both audits). Return runs Find rather than adding a line.
        TextField("Challenge link", text: codeBinding, axis: .vertical)
            .focused($recipientCodeIsFocused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.body.monospaced())
            .lineLimit(3, reservesSpace: true)
            .submitLabel(.search)
            .padding(12)
            .background(Theme.control, in: RoundedRectangle(cornerRadius: 10))
            .disabled(isLocked)
            .accessibilityIdentifier("competition.create.recipient-code")
        Button(action: find) {
            BusyLabel("Find", isBusy: recipientStatus == .lookingUp)
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(!canFind)
        .accessibilityValue(recipientStatus == .lookingUp ? "Finding account" : "")
        .accessibilityIdentifier("competition.create.find-recipient")
        if let ownChallengeLink {
            ShareLink(
                item: ownChallengeLink,
                subject: Text("My HealthComp challenge link"),
                message: Text("Challenge me to a week of rings on HealthComp.")
            ) {
                Label("Share Your Link", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(SecondaryButtonStyle())
            .transition(Motion.appear)
            .accessibilityIdentifier("competition.create.share-own-link")
        }
        if let error = competitionRecipientErrorText(recipientStatus) {
            Text(error)
                .font(.callout)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .transition(Motion.appear)
                .accessibilityIdentifier("competition.create.recipient-error")
        }
    }

    private var title: String {
        if case .sent = status { return "Challenge sent" }
        return "Challenge someone"
    }

    /// One slot: a new control crossfades over the last while height settles.
    /// The group makes the incoming control ride the slot, not land ahead of it.
    private var controlSlot: some View {
        ZStack(alignment: .top) {
            control
                .id(status.controlPhase)
                .transition(Motion.appear)
        }
        .geometryGroup()
    }

    @ViewBuilder
    private var control: some View {
        switch status {
        // One arm, so the button stays put and BusyLabel keeps its clock.
        case .ready, .creating:
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

        case let .challengedYou(challenge):
            conflictControl(
                "\(challenge.opponentDisplayName) already challenged you.",
                button: "Review Challenge",
                id: challenge.id
            )

        case let .inMatch(match):
            conflictControl(
                "You already have a match with \(match.opponentDisplayName).",
                button: "View Match",
                id: match.id
            )

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

        case .failed(.recipientGone):
            // A friend or someone you've played: never "No account has this link".
            Text(failureText(.recipientGone))
                .font(.callout)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("competition.create.recipient-unavailable")

        case .failed(.conflict):
            Text(competitionInviteFailureText(.conflict, opponentName: recipientName))
                .font(.callout)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("competition.create.conflict")

        case let .failed(failure):
            Text(competitionInviteFailureText(failure, opponentName: recipientName))
                .font(.callout)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("competition.create.already-pending")
        }
    }

    private func conflictControl(_ text: String, button: String, id: CompetitionID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("competition.create.conflict")
            Button(button) { openChallenge(id) }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("competition.create.open-existing")
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
        // The share is optional: the challenge already reached them in the app.
        if let expiresAt = challenge?.pendingExpiresAt {
            return "\(name) gets it in HealthComp. Waiting for \(name). Expires \(moment(expiresAt))."
        }
        return "\(name) gets it in HealthComp. Waiting for \(name). Expires in 24 hours."
    }

    private func alreadyChallengedText(_ challenge: LocalCompetitionPresentation) -> String {
        let sentence = "You already challenged \(challenge.opponentDisplayName)."
        guard let expiresAt = challenge.pendingExpiresAt else { return sentence }
        return "\(sentence) Expires \(moment(expiresAt))."
    }

    private func createButton(title: String) -> some View {
        let isCreating = status == .creating
        return Button(action: create) {
            BusyLabel(title, isBusy: isCreating)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isCreating || recipient == nil || recipientStatus == .lookingUp)
        .accessibilityLabel(isCreating ? "Creating challenge" : title)
        .accessibilityIdentifier("competition.create.button")
    }
}

/// Which control a challenge status draws, payloads collapsed: `status` itself
/// changes on every publication, so nothing may key on it.
enum ChallengeControlPhase: Hashable {
    case compose, existing, sent, accepted, failed
}

extension CompetitionFeature.ChallengeSheetStatus {
    var controlPhase: ChallengeControlPhase {
        switch self {
        case .ready, .creating: .compose
        case .alreadyChallenged, .challengedYou, .inMatch: .existing
        case let .sent(_, challenge, _): challenge?.isPending == false ? .accepted : .sent
        case .failed: .failed
        }
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
    case .invalidCode: "That isn’t a full challenge link. Ask them to share it again."
    case .ownCode: "That’s your own link. Ask them for theirs."
    case .notFound: "No account has this link. Check it and try again."
    case .connectionFailed: "Couldn’t look up that link. Check your connection and try again."
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
        return "You can’t challenge \(opponentName)."
    case .alreadyPending:
        return "You already challenged \(opponentName). It expires 24 hours after you sent it."
    case .conflict:
        return "You already have a challenge or match with \(opponentName)."
    }
}

/// "Challenge Maya?": someone's challenge link, opened on this iPhone.
struct ChallengeFromLinkView: View {
    let link: MainTabFeature.ChallengeFromLink
    /// The + sheet's slot, which this sheet sends through.
    let status: CompetitionFeature.ChallengeSheetStatus
    let send: () -> Void
    let retry: () -> Void
    let openCompetition: (CompetitionID) -> Void
    let close: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let pinsControl = !dynamicTypeSize.isAccessibilitySize
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    Spacer()
                    CompetitionDrawerCloseButton(action: close)
                        .accessibilityIdentifier("competition.link.close")
                }
                ZStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 18) { content }
                        .id(link.status)
                        .transition(Motion.appear)
                }
                if !pinsControl, case .ready = link.status {
                    controlSlot
                        .transition(Motion.appear)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            if pinsControl, case .ready = link.status {
                controlSlot
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(Theme.ground)
                    .transition(Motion.appear)
            }
        }
        .moving(Motion.settle, value: controlPhase)
        .background(Theme.ground)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.ground)
        .interactiveDismissDisabled(status == .creating)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.link.sheet")
        // The success lands in MainTabView: this sheet may never render `.sent`.
        .sensoryFeedback(.error, trigger: status.controlPhase == .failed) { _, new in new }
        .sensoryFeedback(.error, trigger: linkFailed) { _, new in new }
    }

    private var linkFailed: Bool {
        link.status == .unavailable || link.status == .retryable
    }

    /// Here `.sent` is still the sending row, until the sheet closes.
    private var controlPhase: ChallengeControlPhase {
        switch status.controlPhase {
        case .sent, .accepted: .compose
        case let phase: phase
        }
    }

    /// One slot: a new control crossfades over the last while height settles.
    /// The group makes the incoming control ride the slot, not land ahead of it.
    private var controlSlot: some View {
        ZStack(alignment: .top) {
            control
                .id(controlPhase)
                .transition(Motion.appear)
        }
        .geometryGroup()
    }

    @ViewBuilder
    private var content: some View {
        switch link.status {
        case .resolving:
            ProgressView("Opening link…")
                .waitingFade()
                .frame(maxWidth: .infinity, minHeight: 200)
        case let .ready(name):
            HStack(alignment: .top, spacing: 14) {
                Text(name.first.map { String($0).uppercased() } ?? "?")
                    .font(.title3.weight(.heavy).width(.condensed))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .background(Theme.control, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Challenge \(name)?")
                        .font(.title3.weight(.heavy).width(.condensed))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("competition.link.name")
                    Text("From \(name)’s challenge link")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            CompetitionRulesCard(source: .remoteParticipants, opponentName: name)
        case .ownLink:
            message("That’s your link", "Share it with someone so they can challenge you.")
        case .unavailable:
            message("Link not found", "This challenge link isn’t active. Ask for a new one.")
        case .retryable:
            message("Couldn’t connect", "Check your connection and try again.")
            Button("Try Again", action: retry)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("competition.link.retry")
        }
    }

    private func message(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.heavy).width(.condensed))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(body)
                .font(.body)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var name: String {
        if case let .ready(name) = link.status { return name }
        return "them"
    }

    @ViewBuilder
    private var control: some View {
        switch status {
        // One arm, so the caption stays and the height holds.
        case .ready, .creating, .sent:
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    if status == .ready {
                        Button("Send Challenge", action: send)
                            .buttonStyle(PrimaryButtonStyle())
                            .transition(Motion.appear)
                            .accessibilityIdentifier("competition.link.send")
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                                .waitingFade()
                            Text("Sending…")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .transition(Motion.appear)
                        .accessibilityElement(children: .combine)
                    }
                }
                Text("\(name) gets it in HealthComp. Nothing to send back.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .alreadyChallenged(challenge):
            existing("You already challenged \(challenge.opponentDisplayName).", "Open Challenge", challenge.id)
        case let .challengedYou(challenge):
            existing("\(challenge.opponentDisplayName) already challenged you.", "Review Challenge", challenge.id)
        case let .inMatch(match):
            existing("You already have a match with \(match.opponentDisplayName).", "View Match", match.id)
        case let .failed(failure):
            VStack(alignment: .leading, spacing: 8) {
                Text(competitionInviteFailureText(failure, opponentName: name))
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("competition.create.send-error")
                if failure == .connection {
                    Button("Try Again", action: send)
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("competition.link.send")
                }
            }
        }
    }

    private func existing(_ text: String, _ button: String, _ id: CompetitionID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("competition.create.conflict")
            Button(button) { openCompetition(id) }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("competition.create.open-existing")
        }
    }
}
