import ComposableArchitecture
import SwiftUI

/// Waiting for every seat to accept, everyone in before Day 1, or closed
/// because someone didn't accept or withdrew.
struct GroupMatchLobbyView: View {
    let match: GroupMatchPresentation
    let store: StoreOf<GroupMatchFeature>
    let createNewMatch: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @State private var confirms: GroupMatchCommand?

    var body: some View {
        Group {
            switch match.lifecycle {
            case .pending, .scheduled: waiting
            default: closed
            }
        }
        .navigationTitle(match.format.title)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            confirms == .cancel(match.id) ? "Cancel this match?" : "Withdraw from this match?",
            isPresented: Binding(get: { confirms != nil }, set: { if !$0 { confirms = nil } }),
            titleVisibility: .visible
        ) {
            if let confirms {
                Button(confirms == .cancel(match.id) ? "Cancel Match" : "Withdraw", role: .destructive) {
                    store.send(.commandTapped(confirms))
                }
            }
            Button("Keep Match", role: .cancel) {}
        } message: {
            Text("It won’t start, and everyone in it sees that.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.group.lobby")
    }

    private var isHost: Bool { match.viewer.number == 1 }

    // MARK: Waiting

    private var waiting: some View {
        GroupMatchPage {
            ViewThatFits(in: .horizontal) {
                HStack { waitingLabels }
                VStack(alignment: .leading, spacing: 6) { waitingLabels }
            }
            .themeLabel()
            .textCase(.uppercase)
            .foregroundStyle(Theme.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("competition.group.lobby.status")
            VStack(alignment: .leading, spacing: 6) {
                versusTitle
                    .font(.largeTitle.weight(.heavy).width(.condensed))
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(isScheduled
                    ? isHost ? "Until Day 1, you can still cancel." : "Until Day 1, you can still withdraw."
                    : "Starts once every seat has accepted.")
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GroupMatchLineupPanels(match: match, identifier: "competition.group.lobby.seat")
            if isHost {
                Text("To change the players or the format, cancel this match and create a new one.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            failure
            // No match link this round: seats are named at creation.
            if isHost {
                quietCommand("Cancel Match", .cancel(match.id), identifier: "competition.group.lobby.cancel")
            } else {
                quietCommand("Withdraw", .withdraw(match.id), identifier: "competition.group.lobby.withdraw")
            }
        }
    }

    private var isScheduled: Bool {
        if case .scheduled = match.lifecycle { true } else { false }
    }

    /// Day 1 as the match's own calendar has it.
    private var startDay: String? {
        guard let schedule = match.schedule,
              let start = try? schedule.calendar.startOfDay(schedule.startDay),
              let zone = TimeZone(identifier: schedule.calendar.timeZoneIdentifier)
        else { return nil }
        return competitionDayText(start, weekday: true, includesYear: false, locale: locale, timeZone: zone)
    }

    @ViewBuilder
    private var waitingLabels: some View {
        let waitingFor = match.seats.filter { $0.invite == .invited }.count
        Text(isScheduled ? "Everyone’s in" : "Waiting for \(waitingFor)")
        Spacer(minLength: 12)
        if isScheduled, let startDay {
            Text("Starts \(startDay)")
        } else if case let .pending(_, createdAt, expiresAt?) = match.lifecycle {
            // An invite lasts days, so its creation is close enough to now for the format.
            Text("Answer by \(competitionMomentText(expiresAt, now: createdAt, locale: locale, timeZone: timeZone))")
        }
    }

    /// "You vs three", or "You + Priya vs Sam + Leo" in doubles.
    private var versusTitle: Text {
        let you = Text("You").foregroundStyle(Theme.you)
        let vs = Text("vs").foregroundStyle(Theme.secondary)
        guard match.format == .doubles, let team = match.viewer.team else {
            return Text("\(you) \(vs) \(match.format == .threeWay ? "two" : "three")")
        }
        let partner = match.seats.first { $0.team == team && $0.id != match.viewerSeatID }?.name ?? ""
        return Text("\(you) + \(partner) \(vs) \(match.name(of: .team(team == 1 ? 2 : 1)))")
    }

    private func quietCommand(_ title: String, _ command: GroupMatchCommand, identifier: String) -> some View {
        Button(role: .destructive) {
            confirms = command
        } label: {
            BusyLabel(title, isBusy: store.inFlight.contains(command))
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(store.inFlight.contains(command))
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var failure: some View {
        if let line = store.state.failureLine(
            [.cancel(match.id), .withdraw(match.id)],
            otherwise: "Couldn’t complete that. Check your connection and try again."
        ) {
            GroupMatchErrorLine(line)
        }
    }

    // MARK: Didn't start

    private var closed: some View {
        GroupMatchPage {
            Text(isCancelled ? "Cancelled" : "Didn’t start")
                .themeLabel()
                .textCase(.uppercase)
                .foregroundStyle(Theme.secondary)
            GroupMatchHeading(closedTitle, detail: closedDetail)
            GroupMatchLineupPanels(match: match, identifier: "competition.group.lobby.seat")
        } actions: {
            if isHost {
                Button("Create a New Match", action: createNewMatch)
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("competition.group.lobby.new-match")
            }
            Button("Done") { dismiss() }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("competition.group.lobby.done")
        }
    }

    private var isCancelled: Bool {
        if case .cancelled = match.lifecycle { true } else { false }
    }

    private var withdrew: [GroupMatchSeat] {
        match.seats.filter { $0.invite == .withdrew }
    }

    private var missing: [GroupMatchSeat] {
        match.closedBeforeStartSeats
    }

    private var closedTitle: String {
        guard !isCancelled else { return "Match cancelled" }
        guard (1...3).contains(missing.count) else { return "Match closed" }
        return ["One seat", "Two seats", "Three seats"][missing.count - 1] + " short"
    }

    private var closedDetail: String {
        if isCancelled {
            return isHost ? "You cancelled this match." : "\(match.seats.first(where: { $0.number == 1 })?.name ?? "The host") cancelled this match."
        }
        guard !missing.isEmpty else { return "This match didn’t start." }
        let names = missing.map { match.name(of: .seat($0.id)) }.formatted(.list(type: .and))
        let sentence = "\(names) \(withdrew.isEmpty ? "didn’t accept" : "withdrew"), so this match didn’t start."
        guard isHost else { return sentence }
        return missing.count == 1
            ? "\(sentence) Create a new one with a different player, a bot in that seat, or another format."
            : "\(sentence) Create a new one with different players, bots in those seats, or another format."
    }
}

// MARK: - Shared by the create, lobby and invite screens

/// One job per screen: content that scrolls over its actions, which stay
/// pinned unless the text is so large they would cover it.
struct GroupMatchPage<Content: View, Actions: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(@ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) { actions }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            if !dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) { actions }
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                    .background(Theme.ground)
            }
        }
        .background(Theme.ground)
    }
}

/// A screen's big uppercase title and the line under it.
struct GroupMatchHeading: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle.weight(.heavy).width(.condensed))
                .textCase(.uppercase)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .foregroundStyle(Theme.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Grouped rows on the panel. Put a `CompetitionRowDivider(inset: 0)`
/// between rows.
struct GroupMatchPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .themePanel()
    }
}

/// "Your team" in amber, "Their team" in ink.
struct GroupMatchTeamLabel: View {
    let isYours: Bool

    var body: some View {
        Text(isYours ? "YOUR TEAM" : "THEIR TEAM")
            .themeLabel()
            .foregroundStyle(isYours ? Theme.you : Theme.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

enum GroupMatchSeatKind { case you, partner, them, bot, empty }

/// A seat: avatar, name and whatever goes on the right.
struct GroupMatchSeatRow<Trailing: View>: View {
    let name: String
    var photo: UUID? = nil
    var kind: GroupMatchSeatKind = .them
    @ViewBuilder let trailing: Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            // The circle stays 32 pt, so its initial stops growing where it would clip.
            avatar.dynamicTypeSize(...DynamicTypeSize.xLarge)
            // At accessibility sizes the status goes under the name, which keeps the line.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Text(name)
                    .fontWeight(kind == .you ? .bold : nil)
                    .foregroundStyle(kind == .you ? Theme.you : kind == .empty ? Theme.secondary : Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
        }
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
        .frame(minHeight: 56)
    }

    @ViewBuilder
    private var avatar: some View {
        switch kind {
        case .empty:
            Circle()
                .strokeBorder(Theme.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
        // The amber ring is yours alone; "Your team" marks a partner.
        default:
            PersonAvatar(name: name, photo: photo, size: 32, isYou: kind == .you, isBot: kind == .bot)
        }
    }
}

/// The lineup of a match that was sent: one panel, or one per team.
/// Photos come only from what the viewer may already see; the server adds
/// seats that have accepted.
struct GroupMatchLineupPanels: View {
    let match: GroupMatchPresentation
    /// Each row's identifier is this plus its seat number.
    let identifier: String
    var title: String? = nil

    var body: some View {
        if match.format == .doubles, let team = match.viewer.team {
            GroupMatchTeamLabel(isYours: true)
            panel(match.seats.filter { $0.team == team }.sorted { ($0.id == match.viewerSeatID ? 0 : 1) < ($1.id == match.viewerSeatID ? 0 : 1) })
            GroupMatchTeamLabel(isYours: false)
            panel(match.seats.filter { $0.team != team })
        } else {
            if let title { SectionLabel(title) }
            panel(match.seats)
        }
    }

    private func panel(_ seats: [GroupMatchSeat]) -> some View {
        GroupMatchPanel {
            ForEach(seats) { seat in
                if seat.id != seats.first?.id { CompetitionRowDivider(inset: 0) }
                let label = status(of: seat)
                GroupMatchSeatRow(
                    name: seat.id == match.viewerSeatID ? "You" : seat.name,
                    photo: seat.profileID,
                    kind: kind(of: seat)
                ) {
                    Text(label)
                        .font(.subheadline)
                        .fontWeight(label == "In" ? .bold : nil)
                        .foregroundStyle(label == "In" ? Theme.ink : Theme.secondary)
                }
                // Another person opens their profile, where they can be blocked or reported.
                .modifier(CompetitionProfileTap(route: match.profileRoute(seat)))
                .accessibilityElement(children: .combine)
                .modifier(CompetitionProfileAction(route: match.profileRoute(seat), name: seat.name))
                .accessibilityIdentifier("\(identifier).\(seat.number)")
            }
        }
    }

    private func kind(of seat: GroupMatchSeat) -> GroupMatchSeatKind {
        if seat.id == match.viewerSeatID { return .you }
        if seat.isBot { return .bot }
        return match.format == .doubles && seat.team == match.viewer.team ? .partner : .them
    }

    func status(of seat: GroupMatchSeat) -> String {
        let isInvite = match.screen == .invite
        switch seat.invite {
        case nil: return "In"
        case .accepted?: return isInvite && seat.number == 1 ? "Host" : "In"
        case .declined?: return "Declined"
        case .withdrew?: return "Withdrew"
        case .invited?:
            if isInvite && seat.id == match.viewerSeatID { return "Your seat" }
            if case .pending = match.lifecycle { return "Invited" }
            return "No answer"
        }
    }
}

extension GroupMatchPresentation {
    /// Another person's profile, where they can be blocked or reported. Never
    /// you, a bot or a deleted account.
    func profileRoute(_ seat: GroupMatchSeat) -> CompetitionHomeRoute? {
        guard seat.id != viewerSeatID, let id = seat.profileID, seat.name != competitionFormerCompetitorName
        else { return nil }
        return .profile(RemoteCompetitionOpponentIdentity.identity(for: id))
    }
}

/// Why an action failed: the one style for it on every group screen, read
/// out by VoiceOver when it appears, since the button's busy state just ends.
struct GroupMatchErrorLine: View {
    let text: String
    var identifier = "competition.group.error"

    init(_ text: String, identifier: String = "competition.group.error") {
        self.text = text
        self.identifier = identifier
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
            .onAppear { AccessibilityNotification.Announcement(text).post() }
            .onChange(of: text) { _, text in AccessibilityNotification.Announcement(text).post() }
    }
}
