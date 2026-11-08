import CompetitionCore
import SwiftUI

struct CompetitionInviteView: View {
    let competition: LocalCompetitionPresentation
    let source: CompetitionPublicationSource
    let isCommandInFlight: Bool
    /// The outgoing challenge's link, when this iPhone has asked for it.
    let link: CompetitionFeature.InviteLinkState?
    let send: (CompetitionFeature.Action) -> Void
    /// The last accept, decline or cancel failed.
    var commandFailed = false
    /// A challenge you received, once you've finished a week together.
    var recordLink: CompetitionRecordLink? = nil
    @State private var showsDeclineConfirmation = false
    @State private var showsCancelConfirmation = false
    @State private var showsBlockConfirmation = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                faceOff
                invitationCopy
                if direction == .incoming, let recordLink {
                    CompetitionRecordLinkRow(link: recordLink)
                }
                CompetitionRulesCard(
                    source: source,
                    opponentName: competition.opponentDisplayName
                )
                actionControls
                if isRemoteOutgoing, dynamicTypeSize.isAccessibilitySize {
                    outgoingControls
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.ground)
        // The link stays in reach; PR 7 adds Cancel Challenge under it.
        .safeAreaInset(edge: .bottom) {
            if isRemoteOutgoing, !dynamicTypeSize.isAccessibilitySize {
                outgoingControls
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                    .background(Theme.ground)
            }
        }
        .moving(Motion.settle, value: commandFailed)
        .moving(Motion.settle, value: linkIsShareable)
        .sensoryFeedback(.error, trigger: commandFailed) { _, new in new }
        .task(id: competition.id) {
            if isRemoteOutgoing, link == nil {
                send(.inviteLinkNeeded(competition.id))
            }
        }
        .navigationTitle(competition.opponentDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isRemoteIncoming {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            showsBlockConfirmation = true
                        } label: {
                            Label("Block \(competition.opponentDisplayName)", systemImage: "hand.raised")
                        }
                        .disabled(isCommandInFlight)
                        .accessibilityIdentifier("competition.invite.block")
                    } label: {
                        CompetitionMoreLabel()
                    }
                    .accessibilityIdentifier("competition.more")
                }
            }
        }
        // The simulated fixture has no server, so it offers no block.
        .alert(
            "Decline challenge from \(competition.opponentDisplayName)?",
            isPresented: declineBinding(remote: false)
        ) {
            Button("Keep Challenge", role: .cancel) {}
            Button("Decline Challenge", role: .destructive) {
                send(.declineTapped(competition.id))
            }
        } message: {
            Text("This closes the challenge without starting a match.")
        }
        .confirmationDialog(
            "Decline challenge from \(competition.opponentDisplayName)?",
            isPresented: declineBinding(remote: true),
            titleVisibility: .visible
        ) {
            Button("Decline Challenge", role: .destructive) {
                send(.declineTapped(competition.id))
            }
            .accessibilityIdentifier("competition.invite.decline.confirm")
            Button("Decline and Block \(competition.opponentDisplayName)", role: .destructive) {
                send(.blockTapped(competition.id))
            }
            .accessibilityIdentifier("competition.invite.decline-block")
            Button("Keep Challenge", role: .cancel) {}
        } message: {
            Text("\(competition.opponentDisplayName) will see a decline either way. If you block them, they can’t challenge you again.")
        }
        .confirmationDialog(
            "Block \(competition.opponentDisplayName)?",
            isPresented: $showsBlockConfirmation,
            titleVisibility: .visible
        ) {
            Button("Block \(competition.opponentDisplayName)", role: .destructive) {
                send(.blockTapped(competition.id))
            }
            .accessibilityIdentifier("competition.invite.block.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This declines the challenge. \(competition.opponentDisplayName) will see a decline and can’t challenge you again.")
        }
        .confirmationDialog(
            "Cancel your challenge to \(competition.opponentDisplayName)?",
            isPresented: $showsCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("Cancel Challenge", role: .destructive) {
                send(.cancelTapped(competition.id))
            }
            Button("Keep Challenge", role: .cancel) {}
        } message: {
            Text("\(competition.opponentDisplayName) won’t be able to accept it.")
        }
    }

    private var outgoingControls: some View {
        VStack(spacing: 6) {
            // `.loading` to `.ready` stays a swap: both are
            // competition.invite.share, and they differ by an opacity.
            ZStack {
                shareControl
                    .id(linkIsShareable)
                    .transition(Motion.appear)
            }
            Button(role: .destructive) {
                showsCancelConfirmation = true
            } label: {
                Text("Cancel Challenge")
                    .font(.headline.width(.condensed))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isCommandInFlight)
            .accessibilityIdentifier("competition.invite.cancel")
            if commandFailed {
                errorLine("Couldn’t cancel the challenge. Check your connection and try again.")
            }
        }
    }

    private var linkIsShareable: Bool {
        switch link {
        case nil, .loading?, .ready?: true
        case .failed?, .notOnThisPhone?: false
        }
    }

    private func errorLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .transition(Motion.appear)
            .accessibilityIdentifier("competition.invite.error")
    }

    // The mark, labeled: your ring bars against their single block.
    private var faceOff: some View {
        CompetitionInvitationFaceOff(
            ownName: competition.ownerDisplayName,
            opponentDisplayName: competition.opponentDisplayName,
            opponentPhoto: competition.opponentProfileID
        )
    }

    private var invitationCopy: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(direction == .incoming ? "CHALLENGE RECEIVED" : "CHALLENGE SENT")
                .font(.themeLabel)
                .tracking(1.4)
                .foregroundStyle(Theme.secondary)
            Text(directionTitle)
                .font(.largeTitle.weight(.heavy).width(.condensed))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if isRemoteOutgoing {
                Text(directionBody)
                    .font(.body)
                    .foregroundStyle(Theme.secondary)
                    .accessibilityIdentifier("competition.invite.expiry")
            } else {
                Text(directionBody)
                    .font(.body)
                    .foregroundStyle(Theme.secondary)
            }
            if let disclosure = competitionFixtureDisclosure(
                source: source,
                opponentDisplayName: competition.opponentDisplayName
            ) {
                Text(disclosure)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
            }
            if source == .simulatedFixture, direction == .outgoing {
                Text(
                    "Starting simulates \(competition.opponentDisplayName) accepting this local challenge."
                )
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actionControls: some View {
        if case let .pending(direction, _, _) = competition.lifecycle {
            if source == .remoteParticipants {
                // The outgoing title already says who you're waiting for.
                if direction == .incoming {
                    VStack(spacing: 6) {
                        incomingButtons
                        if commandFailed {
                            errorLine("Couldn’t complete that. Check your connection and try again.")
                        }
                    }
                }
            } else {
                switch direction {
                case .outgoing:
                    Button {
                        send(.acceptTapped(competition.id))
                    } label: {
                        commandLabel(
                            "Start with \(competition.opponentDisplayName)"
                        )
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isCommandInFlight)
                    .accessibilityValue(
                        isCommandInFlight ? "Action in progress" : ""
                    )
                    .accessibilityHint("Accepts the local simulated match")

                case .incoming:
                    VStack(spacing: 6) { incomingButtons }
                }
            }
        }
    }

    @ViewBuilder
    private var incomingButtons: some View {
        Button {
            send(.acceptTapped(competition.id))
        } label: {
            commandLabel("Accept")
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isCommandInFlight)
        .accessibilityLabel(
            "Accept challenge from \(competition.opponentDisplayName)"
        )
        .accessibilityHint("Starts on the next match calendar day.")
        .accessibilityIdentifier("competition.invite.accept")

        Button(role: .destructive) {
            showsDeclineConfirmation = true
        } label: {
            Text("Decline")
                .font(.headline.width(.condensed))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCommandInFlight)
        .accessibilityLabel(
            "Decline challenge from \(competition.opponentDisplayName)"
        )
        .accessibilityHint("Closes this challenge without starting.")
        .accessibilityValue(
            isCommandInFlight ? "Action in progress" : ""
        )
        .accessibilityIdentifier("competition.invite.decline")
    }

    private func commandLabel(_ title: String) -> some View {
        BusyLabel(title, isBusy: isCommandInFlight)
            .frame(maxWidth: .infinity)
    }

    private var direction: InvitationDirection {
        guard case let .pending(direction, _, _) = competition.lifecycle else {
            return .outgoing
        }
        return direction
    }

    private var isRemoteOutgoing: Bool {
        source == .remoteParticipants && direction == .outgoing
    }

    private var isRemoteIncoming: Bool {
        source == .remoteParticipants && direction == .incoming
    }

    /// One decline flag; the fixture shows the alert, a remote challenge the dialog.
    private func declineBinding(remote: Bool) -> Binding<Bool> {
        Binding(
            get: { showsDeclineConfirmation && (source == .remoteParticipants) == remote },
            set: { showsDeclineConfirmation = $0 }
        )
    }

    private var directionTitle: String {
        if isRemoteOutgoing {
            return "Waiting for \(competition.opponentDisplayName)"
        }
        return competitionInviteTitle(
            direction: direction,
            opponentDisplayName: competition.opponentDisplayName
        )
    }

    private var directionBody: String {
        let name = competition.opponentDisplayName
        if direction == .incoming {
            let sentence = "\(name) challenged you to compare Activity points for seven days."
            guard source == .remoteParticipants,
                  let expiresAt = competition.pendingExpiresAt
            else { return sentence }
            let moment = competitionMomentText(
                expiresAt, now: competition.evaluatedAt, locale: locale, timeZone: timeZone
            )
            return "\(sentence) Answer by \(moment). Day 1 is the day after you accept."
        }
        guard source == .remoteParticipants else {
            return "Start when you are ready. Day 1 begins on the next match calendar day."
        }
        let dayOne = "If \(name) accepts, Day 1 is the next day."
        guard let expiresAt = competition.pendingExpiresAt else { return dayOne }
        let moment = competitionMomentText(
            expiresAt,
            now: competition.evaluatedAt,
            locale: locale,
            timeZone: timeZone
        )
        return "Expires \(moment). \(dayOne)"
    }

    @ViewBuilder
    private var shareControl: some View {
        switch link {
        case let .ready(shareLink, _)?:
            ShareLink(
                item: competitionShareMessage(
                    senderName: competition.ownerDisplayName,
                    link: shareLink
                ),
                subject: Text("Join my HealthComp match")
            ) {
                Label("Share Link Again", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityHint(
                "Opens the system share sheet. The private link is not read aloud."
            )
            .accessibilityIdentifier("competition.invite.share")

        case .failed?:
            VStack(alignment: .leading, spacing: 10) {
                Text("Couldn’t load the link. Check your connection and try again.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { send(.inviteLinkNeeded(competition.id)) }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("competition.invite.share-retry")
            }

        case .notOnThisPhone?:
            Text("The link isn’t on this iPhone. \(competition.opponentDisplayName) can still accept it in HealthComp.")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("competition.invite.link-missing")

        case nil, .loading?:
            Button {} label: {
                Label {
                    BusyLabel("Share Link Again", isBusy: true)
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(true)
            .accessibilityValue("Loading")
            .accessibilityIdentifier("competition.invite.share")
        }
    }
}

struct CompetitionInvitationFaceOff: View {
    /// Yours, for your initial.
    var ownName = ""
    let opponentDisplayName: String
    /// Their account. The server shares a photo only once you may see it.
    var opponentPhoto: UUID? = nil
    /// The claim sheet has its own mark above.
    var showsMark = true

    var body: some View {
        VStack(spacing: 8) {
            if showsMark {
                BrandMark().frame(width: 176)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 8) {
                    PersonAvatar(name: ownName, size: 56, isYou: true)
                    Text("YOU")
                        .foregroundStyle(Theme.you)
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 8) {
                    PersonAvatar(name: opponentDisplayName, photo: opponentPhoto, size: 56)
                    Text(opponentDisplayName.uppercased())
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
            }
            .font(.themeLabel)
            .tracking(1.4)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

/// One line of the challenge rules: calendar, scoring or privacy. Shared by
/// the invitation screen and the claim sheet.
struct CompetitionRuleRow: View {
    enum Icon {
        case symbol(String)
        case rings
    }

    let icon: Icon
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: 14) {
            iconView
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case let .symbol(name):
            Image(systemName: name)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.ink)
        case .rings:
            VStack(alignment: .leading, spacing: 2) {
                SlantedBar().fill(Theme.move).frame(width: 18, height: 4)
                SlantedBar().fill(Theme.exercise).frame(width: 13, height: 4)
                    .padding(.leading, 3)
                SlantedBar().fill(Theme.stand).frame(width: 16, height: 4)
            }
        }
    }
}

struct CompetitionRuleDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }
}

/// The one rules and consent card: the week, scoring, who wins and what the
/// other person sees. Shown on the create, challenge and claim screens and
/// from a match's ••• menu.
struct CompetitionRulesCard: View {
    let source: CompetitionPublicationSource
    var opponentName: String? = nil
    var weekText: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            CompetitionRuleRow(
                icon: .symbol("calendar"),
                title: "Seven days",
                detail: weekText ?? "Day 1 is the day after the challenge is accepted."
            )
            CompetitionRuleDivider()
            CompetitionRuleRow(
                icon: .rings,
                title: "1 point per 1% of each ring",
                detail: "Up to 600 points a day"
            )
            CompetitionRuleDivider()
            CompetitionRuleRow(
                icon: .symbol("trophy"),
                title: "Most points after 7 days wins",
                detail: "Equal totals tie. A day with no data scores 0."
            )
            CompetitionRuleDivider()
            if source == .simulatedFixture {
                CompetitionRuleRow(
                    icon: .symbol("lock.iphone"),
                    title: "Nothing leaves this iPhone",
                    detail: opponentName.map { "\($0) is simulated." }
                )
            } else {
                CompetitionRuleRow(
                    icon: .symbol("lock.iphone"),
                    title: "\(opponentName ?? "The other person") sees your daily points and rounded ring percentages",
                    detail: "Also whether you use Move Time or Roll, why a day has no data, and when your iPhone last updated your scores. Your Health data stays on your iPhone."
                )
            }
        }
        .padding(.horizontal, 16)
        .themePanel(cornerRadius: 18)
    }
}

func competitionFixtureDisclosure(
    source: CompetitionPublicationSource,
    opponentDisplayName: String
) -> String? {
    guard source == .simulatedFixture else { return nil }
    return "\(opponentDisplayName) is simulated on this iPhone."
}

func competitionInviteTitle(
    direction: InvitationDirection,
    opponentDisplayName: String
) -> String {
    direction == .incoming
        ? "Challenge from \(opponentDisplayName)"
        : "Challenge to \(opponentDisplayName)"
}
