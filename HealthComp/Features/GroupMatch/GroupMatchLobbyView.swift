import ComposableArchitecture
import SwiftUI

/// Waiting for every seat to accept, or closed because someone didn't.
struct GroupMatchLobbyView: View {
    let match: GroupMatchPresentation
    let store: StoreOf<GroupMatchFeature>

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @State private var confirms: GroupMatchCommand?
    @State private var showsNewMatch = false

    var body: some View {
        Group {
            if case .pending = match.lifecycle { waiting } else { closed }
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
        .sheet(isPresented: $showsNewMatch) {
            GroupMatchCreateView(store: store, lineup: GroupMatchLineup(match: match))
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
            .font(.themeLabel)
            .tracking(1.2)
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
                Text("Starts once every seat has accepted.")
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
            if isHost {
                if let link = store.shareLinks[match.id] {
                    ShareLink(item: link, subject: Text("Join my HealthComp match")) {
                        Text("Share Match Link")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("competition.group.lobby.share")
                } else {
                    Button("Share Match Link") {}
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(true)
                        .accessibilityIdentifier("competition.group.lobby.share")
                }
                quietCommand("Cancel Match", .cancel(match.id), identifier: "competition.group.lobby.cancel")
            } else {
                quietCommand("Withdraw", .withdraw(match.id), identifier: "competition.group.lobby.withdraw")
            }
        }
    }

    @ViewBuilder
    private var waitingLabels: some View {
        let waitingFor = match.seats.filter { $0.invite == .invited }.count
        Text("Waiting for \(waitingFor)")
        Spacer(minLength: 12)
        if case let .pending(_, createdAt, expiresAt?) = match.lifecycle {
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
        if [GroupMatchCommand.cancel(match.id), .withdraw(match.id)].contains(where: { store.failed.contains($0) }) {
            GroupMatchErrorLine("Couldn’t complete that. Check your connection and try again.")
        }
    }

    // MARK: Didn't start

    private var closed: some View {
        GroupMatchPage {
            Text(isCancelled ? "Cancelled" : "Didn’t start")
                .font(.themeLabel)
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Theme.secondary)
            GroupMatchHeading(closedTitle, detail: closedDetail)
            GroupMatchLineupPanels(match: match, identifier: "competition.group.lobby.seat")
        } actions: {
            if isHost {
                Button("Create a New Match") { showsNewMatch = true }
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

    private var missing: [GroupMatchSeat] {
        match.seats.filter { $0.invite != nil && $0.invite != .accepted }
    }

    private var closedTitle: String {
        guard !isCancelled else { return "Match cancelled" }
        let count = ["One", "Two", "Three"][max(0, min(missing.count, 3) - 1)]
        return "\(count) \(missing.count == 1 ? "seat" : "seats") short"
    }

    private var closedDetail: String {
        if isCancelled {
            return isHost ? "You cancelled this match." : "\(match.seats.first(where: { $0.number == 1 })?.name ?? "The host") cancelled this match."
        }
        let names = missing.map { match.name(of: .seat($0.id)) }.formatted(.list(type: .and))
        let sentence = "\(names) didn’t accept, so this match didn’t start."
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
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            if !dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) { actions }
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 20)
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
            .font(.themeLabel)
            .tracking(1.2)
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
        case .partner:
            PersonAvatar(name: name, photo: photo, size: 32)
                .overlay { Circle().strokeBorder(Theme.youFill, lineWidth: 2) }
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
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("\(identifier).\(seat.number)")
            }
        }
    }

    private func kind(of seat: GroupMatchSeat) -> GroupMatchSeatKind {
        if seat.id == match.viewerSeatID { return .you }
        if seat.isBot { return .bot }
        return match.format == .doubles && seat.team == match.viewer.team ? .partner : .them
    }

    private func status(of seat: GroupMatchSeat) -> String {
        let isInvite = match.viewer.invite == .invited
        switch seat.invite {
        case nil: return "In"
        case .accepted?: return isInvite && seat.number == 1 ? "Host" : "In"
        case .declined?: return "Declined"
        case .invited?:
            if isInvite && seat.id == match.viewerSeatID { return "Your seat" }
            if case .pending = match.lifecycle { return "Invited" }
            return "No answer"
        }
    }
}

struct GroupMatchErrorLine: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("competition.group.error")
    }
}
