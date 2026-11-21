import CompetitionCore
import SwiftUI

struct ClaimCompetitionView: View {
    let liveStatus: MainTabFeature.InviteClaimStatus
    var livePreview: CompetitionInvitePreview? = nil
    var ownName = ""
    var now: Date = Date()
    var hasQueuedChallenge = false
    var declineFailed = false
    let accept: () -> Void
    let notNow: () -> Void
    let decline: () -> Void
    var block: (() -> Void)? = nil
    let retry: () -> Void
    let dismiss: () -> Void

    @State private var showsDeclineConfirmation = false
    @State private var lastStatus = MainTabFeature.InviteClaimStatus.loadingPreview
    @State private var lastPreview: CompetitionInvitePreview?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    private var status: MainTabFeature.InviteClaimStatus {
        liveStatus == .idle ? lastStatus : liveStatus
    }

    private var preview: CompetitionInvitePreview? {
        liveStatus == .idle ? lastPreview : livePreview
    }

    var body: some View {
        let pinsControls = !dynamicTypeSize.isAccessibilitySize
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 12)
                    statusEmblem
                    if showsPreview, let preview {
                        CompetitionInvitationFaceOff(
                            ownName: ownName,
                            opponentDisplayName: preview.sender.displayName,
                            opponentPhoto: preview.sender.id,
                            showsMark: false
                        )
                        .transition(Motion.appear)
                    }
                    ZStack(alignment: .top) {
                        VStack(spacing: 10) {
                            Text(title)
                                .font(.title.weight(.heavy).width(.condensed))
                                .foregroundStyle(Theme.ink)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier(showsPreview ? "competition.claim.sender" : "")
                            if showsPreview, let preview {
                                previewLines(preview)
                            } else if let message {
                                Text(message)
                                    .font(.body)
                                    .foregroundStyle(Theme.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .id(slotKey)
                        .transition(Motion.appear)
                    }
                    .frame(maxWidth: 440)

                    if showsPreview, let preview {
                        CompetitionMetricTagStrip(metrics: preview.metrics)
                            .frame(maxWidth: 440, alignment: .leading)
                            .transition(Motion.appear)
                        CompetitionRulesCard(
                            source: .remoteParticipants,
                            opponentName: preview.sender.displayName,
                            metrics: preview.metrics
                        )
                        .frame(maxWidth: 440)
                        .transition(Motion.appear)
                    }

                    if hasQueuedChallenge {
                        Text("Another challenge link is waiting.")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                            .transition(Motion.appear)
                    }

                    if !pinsControls {
                        controlSlot
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) {
                if pinsControls {
                    controlSlot
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity)
                        .background(Theme.ground)
                }
            }
            .moving(Motion.settle, value: settleKey)
            .moving(Motion.settle, value: hasQueuedChallenge)
            .background(Theme.ground)
            .navigationTitle("Challenge")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.ground)
        .interactiveDismissDisabled(
            status == .claiming || status == .waitingForCompetition
                || status == .declining
        )
        .confirmationDialog(
            "Decline challenge from \(senderName)?",
            isPresented: $showsDeclineConfirmation,
            titleVisibility: .visible
        ) {
            Button("Decline Challenge", role: .destructive, action: decline)
            if let block {
                Button("Decline and Block \(senderName)", role: .destructive, action: block)
                    .accessibilityIdentifier("competition.claim.decline-block")
            }
            Button("Keep Challenge", role: .cancel) {}
        } message: {
            Text("\(senderName) will see a decline either way. If you block them, they can’t challenge you again.")
        }
        .accessibilityIdentifier("competition.claim.sheet")
        .onChange(of: liveStatus, initial: true) { _, new in
            if new != .idle { lastStatus = new }
        }
        .onChange(of: livePreview, initial: true) { _, new in
            if liveStatus != .idle { lastPreview = new }
        }
        .onChange(of: title) { _, new in
            AccessibilityNotification.Announcement(new).post()
        }
        .sensoryFeedback(.error, trigger: liveStatus) { old, new in
            [.loadingPreview, .claiming, .waitingForCompetition].contains(old)
                && [.retryable, .wrongAccount, .confirmationTimedOut].contains(new)
        }
        .sensoryFeedback(.error, trigger: declineFailed) { _, new in new }
    }

    private var slotKey: MainTabFeature.InviteClaimStatus {
        status == .declining ? .ready : status
    }

    private var settleKey: MainTabFeature.InviteClaimStatus {
        slotKey == .loadingPreview ? .ready : slotKey
    }

    private var showsPreview: Bool {
        (status == .ready || status == .declining) && preview != nil
    }

    private var senderName: String {
        preview?.sender.displayName ?? "the sender"
    }

    @ViewBuilder
    private func previewLines(_ preview: CompetitionInvitePreview) -> some View {
        let zone = competitionTimeZoneName(preview.timeZoneIdentifier, locale: locale)
        let startDay = competitionClaimStartDay(preview, now: now)
        VStack(spacing: 4) {
            if let startDay {
                Text("Starts \(competitionDayText(startDay, now: now, locale: locale, timeZone: timeZone)) · \(zone)")
            } else {
                Text(zone)
            }
            Text("Answer by \(competitionMomentText(preview.expiresAt, now: now, locale: locale, timeZone: timeZone))")
        }
        .font(.body)
        .foregroundStyle(Theme.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(previewAccessibilityLabel(preview, startDay: startDay, zone: zone))
        .accessibilityIdentifier("competition.claim.start")
    }

    private func previewAccessibilityLabel(
        _ preview: CompetitionInvitePreview,
        startDay: CompetitionDay?,
        zone: String
    ) -> String {
        let expiry = preview.expiresAt.formatted(
            Date.FormatStyle(date: .complete, time: .shortened, locale: locale, timeZone: timeZone)
        )
        guard let startDay,
              let calendar = try? CompetitionCalendar(timeZoneIdentifier: preview.timeZoneIdentifier),
              let date = try? calendar.startOfDay(startDay)
        else {
            return "\(zone). Answer by \(expiry)."
        }
        var style = Date.FormatStyle(date: .complete, time: .omitted, locale: locale)
        style.timeZone = TimeZone(identifier: preview.timeZoneIdentifier) ?? timeZone
        return "Starts \(date.formatted(style)), \(zone). Answer by \(expiry)."
    }

    private var statusEmblem: some View {
        ZStack {
            statusIcon
                .id(emblemKey)
                .transition(Motion.appear)
        }
        .frame(width: 104, height: 104)
        .background(Theme.panel, in: Circle())
        .accessibilityHidden(true)
    }

    private var emblemKey: MainTabFeature.InviteClaimStatus {
        switch status {
        case .claiming, .waitingForCompetition: .loadingPreview
        default: slotKey
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .loadingPreview, .claiming, .waitingForCompetition:
            ProgressView()
                .controlSize(.large)
                .tint(Theme.ink)
        case .confirmationTimedOut:
            symbol("clock.badge.exclamationmark")
        case .unavailable:
            symbol("link.badge.plus")
        case .wrongAccount:
            symbol("person.crop.circle.badge.xmark")
        case .ownChallenge:
            symbol("person.crop.circle.badge.checkmark")
        case .activeMatchExists:
            symbol("calendar.badge.clock")
        case .retryable:
            symbol("wifi.exclamationmark")
        case .idle, .ready, .declining:
            BrandMark(grows: true).frame(width: 58)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 40, weight: .semibold))
            .foregroundStyle(Theme.ink)
    }

    private var controlSlot: some View {
        ZStack(alignment: .top) {
            actionControls
                .id(slotKey)
                .transition(Motion.appear)
        }
    }

    @ViewBuilder
    private var actionControls: some View {
        switch status {
        case .ready, .declining:
            VStack(spacing: 8) {
                Button("Accept", action: accept)
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 440)
                    .disabled(status == .declining)
                    .accessibilityLabel("Accept \(senderName)’s challenge")
                    .accessibilityIdentifier("competition.claim.accept")
                Button("Not Now", action: notNow)
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(maxWidth: 440)
                    .disabled(status == .declining)
                    .accessibilityLabel("Not now")
                    .accessibilityHint("Keeps the challenge on Home")
                    .accessibilityIdentifier("competition.claim.not-now")
                if status == .declining {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Declining…")
                    }
                    .font(.headline.width(.condensed))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: 440, minHeight: 44)
                    .accessibilityElement(children: .combine)
                } else if preview != nil {
                    Button("Decline", role: .destructive) {
                        showsDeclineConfirmation = true
                    }
                    .buttonStyle(QuietButtonStyle())
                    .frame(maxWidth: 440)
                    .accessibilityLabel("Decline \(senderName)’s challenge")
                    .accessibilityHint("\(senderName) is told")
                    .accessibilityIdentifier("competition.claim.decline")
                }
                Text(
                    declineFailed
                        ? "Couldn’t decline. Check your connection and try again."
                        : "\(senderName) is told if you decline."
                )
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(Motion.fade, value: declineFailed)
                .accessibilityIdentifier(declineFailed ? "competition.claim.decline-error" : "")
            }

        case .retryable:
            VStack(spacing: 8) {
                Button("Try Again", action: retry)
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 440)
                    .accessibilityIdentifier("competition.claim.retry")
                Button("Not Now", action: notNow)
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(maxWidth: 440)
                    .accessibilityIdentifier("competition.claim.not-now")
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

        case .unavailable, .wrongAccount, .ownChallenge, .activeMatchExists:
            Button("Done", action: dismiss)
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 440)
                .accessibilityIdentifier("competition.claim.dismiss")

        case .claiming, .waitingForCompetition:
            Text("Keep HealthComp open for a moment.")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)

        case .loadingPreview, .idle:
            EmptyView()
        }
    }

    private var title: String {
        switch status {
        case .loadingPreview:
            "Opening challenge…"
        case .idle, .ready, .declining:
            preview.map { "\($0.sender.displayName) challenged you" } ?? "Join this match?"
        case .claiming:
            "Accepting challenge…"
        case .waitingForCompetition:
            "Confirming match…"
        case .confirmationTimedOut:
            "Still waiting for confirmation"
        case .unavailable:
            "Challenge unavailable"
        case .wrongAccount:
            "This challenge is for someone else"
        case .ownChallenge:
            "That’s your challenge"
        case .activeMatchExists:
            "You’re already in a match"
        case .retryable:
            "Couldn’t connect"
        }
    }

    private var message: String? {
        switch status {
        case .loadingPreview:
            nil
        case .idle, .ready, .declining:
            "Accept to start a private seven-day Activity match on the sender’s calendar."
        case .claiming, .waitingForCompetition:
            nil
        case .confirmationTimedOut:
            "It’s accepted. The match will appear on Home."
        case .ownChallenge:
            "You sent this link. Only the person you challenged can accept it."
        case .activeMatchExists:
            "You can accept a new challenge from this person after your current match ends."
        case .unavailable:
            "This link may be expired, already used, or no longer valid. Ask the sender for a new challenge."
        case .wrongAccount:
            "Only the account it was sent to can accept it. Ask the sender to challenge this account."
        case .retryable:
            "Check your connection and try again."
        }
    }
}

func competitionTimeZoneName(_ identifier: String, locale: Locale = .current) -> String {
    TimeZone(identifier: identifier)?.localizedName(for: .generic, locale: locale) ?? identifier
}

func competitionClaimStartDay(_ preview: CompetitionInvitePreview, now: Date) -> CompetitionDay? {
    let calendar = try? CompetitionCalendar(timeZoneIdentifier: preview.timeZoneIdentifier)
    return try? calendar?.startDay(afterAcceptanceAt: now)
}
