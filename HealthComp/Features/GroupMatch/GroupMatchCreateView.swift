import CompetitionCore
import ComposableArchitecture
import SwiftUI

/// Someone you can already challenge.
struct GroupMatchPlayer: Hashable, Sendable {
    let profileID: UUID
    let name: String
}

/// Who you're sending the match to, seat by seat. You are never in it.
struct GroupMatchLineup: Equatable {
    enum Entry: Hashable {
        case person(GroupMatchPlayer)
        /// Named by their personal challenge link, never an open seat.
        case linked(CompetitionChallengeLinkCode, name: String)
        case bot(BotMode)

        var name: String {
            switch self {
            case let .person(player): player.name
            case let .linked(_, name): name
            case let .bot(mode): mode.name
            }
        }

        var isPerson: Bool {
            if case .bot = self { false } else { true }
        }
    }

    private(set) var format: GroupMatchFormat
    /// Nil is a seat still to fill. In doubles the first is your partner.
    private(set) var seats: [Entry?]

    init(format: GroupMatchFormat, entries: [Entry] = []) {
        self.format = format
        seats = []
        place(entries)
    }

    /// The same format and players as a match that didn't start.
    init(match: GroupMatchPresentation) {
        let others = match.seats
            .filter { $0.id != match.viewerSeatID }
            .sorted { ($0.team == match.viewer.team ? 0 : 1, $0.number) < ($1.team == match.viewer.team ? 0 : 1, $1.number) }
        self.init(format: match.format, entries: others.map { seat in
            switch seat.occupant {
            case let .person(profileID, _): .person(GroupMatchPlayer(profileID: profileID, name: seat.name))
            case let .bot(mode): .bot(mode)
            }
        })
    }

    /// Doubles: 1 for your team, 2 for theirs. Nil otherwise.
    func team(ofSeat index: Int) -> Int? {
        format == .doubles ? (index == 0 ? 1 : 2) : nil
    }

    /// Teams with an empty seat; `[nil]` while a free-for-all has one.
    var openTeams: [Int?] {
        var teams: [Int?] = []
        for index in seats.indices where seats[index] == nil && !teams.contains(team(ofSeat: index)) {
            teams.append(team(ofSeat: index))
        }
        return teams
    }

    /// Only a four-way's empty seat can go, which makes it a three-way.
    func canRemoveSeat(_ index: Int) -> Bool {
        seats[index] == nil && format == .fourWay
    }

    var filledCount: Int { seats.compactMap { $0 }.count }

    var canCreate: Bool {
        !seats.contains(nil) && seats.contains { $0?.isPerson == true }
    }

    var draft: GroupMatchDraft {
        GroupMatchDraft(format: format, seats: seats.indices.compactMap { index in
            switch seats[index] {
            case let .person(player)?: .person(profileID: player.profileID, team: team(ofSeat: index))
            case let .linked(code, _)?: .challengeLink(code, team: team(ofSeat: index))
            case let .bot(mode)?: .bot(mode, team: team(ofSeat: index))
            case nil: nil
            }
        })
    }

    mutating func add(_ entry: Entry, team: Int?) {
        guard let index = seats.indices.first(where: { seats[$0] == nil && self.team(ofSeat: $0) == team })
        else { return }
        seats[index] = entry
    }

    mutating func remove(seat index: Int) {
        if seats[index] == nil {
            guard canRemoveSeat(index) else { return }
            seats.remove(at: index)
            format = .threeWay
        } else {
            seats[index] = nil
        }
    }

    /// Keeps whoever fits when the format changes.
    mutating func reshape(to format: GroupMatchFormat) {
        guard format != self.format else { return }
        let entries = seats.compactMap { $0 }
        self.format = format
        seats = []
        place(entries)
    }

    private mutating func place(_ entries: [Entry]) {
        seats = Array(entries.prefix(format.seatCount - 1))
        seats += Array(repeating: nil, count: format.seatCount - 1 - seats.count)
    }
}

/// What a pasted challenge link turned out to be.
enum GroupMatchLinkLookup: Equatable, Sendable {
    case idle, resolving, invalid, notFound, unavailable, failed
    case found(name: String)

    /// The duel sheet's `resolve_challenge_link`: a name only, never a seat.
    /// Not found and unavailable stay one answer, as on the duel sheet.
    static func resolve(_ code: CompetitionChallengeLinkCode) async -> Self {
        @Dependency(\.competitionClient) var competitionClient
        do {
            return .found(name: try await competitionClient.resolveChallengeLink(code))
        } catch CompetitionRemoteFailure.ownChallengeLink {
            return .unavailable
        } catch CompetitionRemoteFailure.recipientUnavailable, CompetitionRemoteFailure.notFound {
            return .notFound
        } catch {
            return .failed
        }
    }
}

/// New Match: pick a format, fill the seats, add bots, send.
struct GroupMatchCreateView: View {
    enum Step: Hashable {
        case lineup, bots, link
    }

    let store: StoreOf<GroupMatchFeature>
    /// People you've played.
    let people: [GroupMatchPlayer]
    /// Duel keeps today's challenge sheet.
    let onDuel: () -> Void
    let lookUpLink: @Sendable (CompetitionChallengeLinkCode) async -> GroupMatchLinkLookup
    private let prefilled: [GroupMatchPlayer]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var path: [Step]
    /// Nil is Duel.
    @State private var selection: GroupMatchFormat?
    @State private var lineup: GroupMatchLineup
    @State private var bot: BotMode = .pacer
    /// Waiting for a team in doubles while both have room.
    @State private var pendingEntry: GroupMatchLineup.Entry?
    @State private var asksTeam = false
    @State private var sent: GroupMatchCommand?
    @State private var linkText = ""
    /// The code being looked up or found; nil once the text changes.
    @State private var linkCode: CompetitionChallengeLinkCode?
    @State private var link: GroupMatchLinkLookup = .idle

    init(
        store: StoreOf<GroupMatchFeature>,
        people: [GroupMatchPlayer] = [],
        lineup: GroupMatchLineup? = nil,
        opensAt path: [Step] = [],
        onDuel: @escaping () -> Void = {},
        lookUpLink: @escaping @Sendable (CompetitionChallengeLinkCode) async -> GroupMatchLinkLookup = GroupMatchLinkLookup.resolve
    ) {
        self.store = store
        self.people = people
        self.onDuel = onDuel
        self.lookUpLink = lookUpLink
        var prefilled: [GroupMatchPlayer] = []
        for case let .person(player)? in lineup?.seats ?? [] { prefilled.append(player) }
        self.prefilled = prefilled
        _path = State(initialValue: path)
        _selection = State(initialValue: lineup?.format)
        _lineup = State(initialValue: lineup ?? GroupMatchLineup(format: .fourWay))
    }

    var body: some View {
        NavigationStack(path: $path) {
            formatScreen
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .lineup: lineupScreen
                    case .bots: botScreen
                    case .link: linkScreen
                    }
                }
        }
        .tint(Theme.ink)
        .confirmationDialog(
            "Add \(pendingEntry?.name ?? "")",
            isPresented: $asksTeam,
            titleVisibility: .visible,
            presenting: pendingEntry
        ) { entry in
            Button("Your Team") { place(entry, team: 1) }
            Button("Their Team") { place(entry, team: 2) }
        }
        .onChange(of: sent.map { store.inFlight.contains($0) }) { _, isSending in
            if isSending == false, let sent, !store.failed.contains(sent) { dismiss() }
        }
    }

    // MARK: Format

    private static let formats: [(GroupMatchFormat?, String, String, [FormatGlyph.Mark])] = [
        (nil, "Duel", "You against one person. The belt is on the line.", [.you, .gap(11), .them]),
        (.threeWay, "Three-Way", "Three players, every one for themselves.", [.you, .gap(8), .them, .gap(8), .them]),
        (.fourWay, "Four-Way", "Four players, every one for themselves.",
         [.you, .gap(5), .them, .gap(5), .them, .gap(5), .them]),
        (.doubles, "Doubles", "Two teams of two. Partners’ points add up.",
         [.you, .gap(3), .partner, .gap(10), .them, .gap(3), .them]),
    ]

    private var formatScreen: some View {
        GroupMatchPage {
            GroupMatchHeading("Pick a format", detail: "Seven days. Most ring points wins.")
            VStack(spacing: 10) {
                ForEach(Self.formats.filter { $0.0 == nil || GroupMatchRollout.showsFormatPicker }, id: \.1) { format in
                    GroupMatchOptionCard(
                        title: format.1,
                        detail: format.2,
                        isSelected: selection == format.0,
                        identifier: "competition.group.format.\(format.0?.rawValue ?? "duel")"
                    ) {
                        FormatGlyph(marks: format.3)
                    } action: {
                        selection = format.0
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: selection)
        } actions: {
            Button("Choose Players") {
                guard let selection else { return onDuel() }
                lineup.reshape(to: selection)
                path.append(.lineup)
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("competition.group.choose-players")
        }
        .navigationTitle("New Match")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    // MARK: Lineup

    private var lineupScreen: some View {
        GroupMatchPage {
            if lineup.format == .doubles {
                GroupMatchTeamLabel(isYours: true)
                GroupMatchPanel {
                    hostRow
                    seatRow(0)
                }
                GroupMatchTeamLabel(isYours: false)
                GroupMatchPanel {
                    seatRow(1)
                    seatRow(2)
                }
            } else {
                SectionLabel("PLAYERS · \(lineup.filledCount + 1) OF \(lineup.format.seatCount)")
                GroupMatchPanel {
                    hostRow
                    ForEach(lineup.seats.indices, id: \.self) { seatRow($0) }
                }
            }
            if !candidates.isEmpty {
                SectionLabel("PEOPLE YOU’VE PLAYED")
            }
            GroupMatchPanel {
                ForEach(candidates, id: \.self) { player in
                    if player != candidates.first { CompetitionRowDivider(inset: 0) }
                    GroupMatchSeatRow(name: player.name, photo: player.profileID) {
                        Button("Add") { add(.person(player)) }
                            .buttonStyle(GroupMatchPillButtonStyle())
                            .disabled(lineup.openTeams.isEmpty)
                            .accessibilityLabel("Add \(player.name)")
                            .accessibilityIdentifier(
                                "competition.group.person.\(player.profileID.uuidString.lowercased()).add"
                            )
                    }
                }
                if !candidates.isEmpty { CompetitionRowDivider(inset: 0) }
                NavigationLink(value: Step.bots) {
                    HStack(spacing: 12) {
                        BotGlyph()
                        Text("Add a bot")
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.tertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(lineup.openTeams.isEmpty)
                .accessibilityIdentifier("competition.group.add-bot")
                CompetitionRowDivider(inset: 0)
                NavigationLink(value: Step.link) {
                    HStack(spacing: 12) {
                        Text("Paste a challenge link")
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.tertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(lineup.openTeams.isEmpty)
                .accessibilityIdentifier("competition.group.paste-link")
            }
            if let hint {
                Text(hint)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            if let sent, let line = store.state.failureLine(
                [sent],
                otherwise: "Couldn’t create the match. Check your connection and try again.",
                name: { id in (people + prefilled).first { $0.profileID == id }?.name }
            ) {
                GroupMatchErrorLine(line)
            }
            Button {
                let command = GroupMatchCommand.create(lineup.draft)
                sent = command
                store.send(.commandTapped(command))
            } label: {
                BusyLabel("Create Match", isBusy: isCreating)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!lineup.canCreate || isCreating)
            .accessibilityIdentifier("competition.group.create")
        }
        .moving(Motion.settle, value: lineup)
        .navigationTitle(lineup.format.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hostRow: some View {
        GroupMatchSeatRow(name: "You", kind: .you) {
            Text("Host").font(.subheadline).foregroundStyle(Theme.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("competition.group.seat.1")
    }

    @ViewBuilder
    private func seatRow(_ index: Int) -> some View {
        let number = index + 2
        let entry = lineup.seats[index]
        // In doubles seat 3 opens their team's panel.
        if lineup.format != .doubles || index != 1 { CompetitionRowDivider(inset: 0) }
        // At accessibility sizes Remove goes under the name, which keeps the line.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            Group {
                switch entry {
                case let .person(player)?:
                    GroupMatchSeatRow(
                        name: player.name, photo: player.profileID,
                        kind: lineup.team(ofSeat: index) == 1 ? .partner : .them
                    ) { EmptyView() }
                case let .linked(_, name)?:
                    GroupMatchSeatRow(name: name, kind: lineup.team(ofSeat: index) == 1 ? .partner : .them) { EmptyView() }
                case let .bot(mode)?:
                    GroupMatchSeatRow(name: mode.name, kind: .bot) { EmptyView() }
                case nil:
                    GroupMatchSeatRow(name: "Empty seat", kind: .empty) { EmptyView() }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("competition.group.seat.\(number)")
            if entry != nil || lineup.canRemoveSeat(index) {
                Button("Remove") {
                    lineup.remove(seat: index)
                    // Back keeps the three-way this made.
                    selection = lineup.format
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 4)
                .frame(minHeight: 44)
                .accessibilityLabel(entry.map { "Remove \($0.name)" } ?? "Remove this seat")
                .accessibilityIdentifier("competition.group.seat.\(number).remove")
            }
        }
    }

    /// People you've played who aren't seated, including anyone a rematch
    /// prefilled and you removed.
    private var candidates: [GroupMatchPlayer] {
        var players = people
        for player in prefilled where !players.contains(player) { players.append(player) }
        return players.filter { !lineup.seats.contains(.person($0)) }
    }

    private var hint: String? {
        if lineup.seats.contains(nil) { return "Fill every seat with a person or a bot." }
        if !lineup.canCreate { return "Add at least one other person. Against bots alone, start a practice match." }
        return nil
    }

    private var isCreating: Bool {
        sent.map { store.inFlight.contains($0) } ?? false
    }

    private func add(_ entry: GroupMatchLineup.Entry) {
        let teams = lineup.openTeams
        if teams.count > 1 {
            pendingEntry = entry
            asksTeam = true
        } else if let team = teams.first {
            place(entry, team: team)
        }
    }

    private func place(_ entry: GroupMatchLineup.Entry, team: Int?) {
        lineup.add(entry, team: team)
        if path.last == .bots || path.last == .link { path.removeLast() }
    }

    // MARK: Challenge link

    private var linkScreen: some View {
        GroupMatchPage {
            GroupMatchHeading("Their challenge link", detail: "Paste the link they shared. It adds them, and only them.")
            // Return looks it up rather than adding a line.
            TextField("Challenge link", text: Binding(get: { linkText }, set: { text in
                let clean = text.filter { !$0.isNewline }
                if clean != linkText {
                    linkText = clean
                    link = .idle
                    linkCode = nil
                }
                if text.contains(where: \.isNewline) { findLink() }
            }), axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .lineLimit(3, reservesSpace: true)
                .submitLabel(.search)
                .padding(12)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("competition.group.link.field")
            if case let .found(name) = link {
                GroupMatchPanel {
                    GroupMatchSeatRow(name: name) {
                        Text("Found").font(.subheadline).foregroundStyle(Theme.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("competition.group.link.found")
                }
            } else if let message = linkMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("competition.group.link.message")
            }
        } actions: {
            if case let .found(name) = link, let linkCode {
                Button("Add \(name)") { add(.linked(linkCode, name: name)) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(lineup.openTeams.isEmpty || lineup.seats.contains { if case .linked(linkCode, _)? = $0 { true } else { false } })
                    .accessibilityIdentifier("competition.group.link.add")
            } else {
                Button(action: findLink) {
                    BusyLabel("Find", isBusy: link == .resolving)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(link == .resolving || linkText.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("competition.group.link.find")
            }
        }
        .onAppear { linkText = ""; link = .idle; linkCode = nil }
        .navigationTitle("Challenge Link")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var linkMessage: String? {
        switch link {
        case .invalid: "That isn’t a full challenge link. Ask them to share it again."
        case .notFound: "No account has this link. Check it and try again."
        case .unavailable: "You can’t add this person to a match."
        case .failed: "Couldn’t check that link. Check your connection and try again."
        case .idle, .resolving, .found: nil
        }
    }

    private func findLink() {
        guard link != .resolving else { return }
        guard let code = CompetitionFeature.challengeLinkCode(in: linkText.trimmingCharacters(in: .whitespaces)) else {
            link = .invalid
            return
        }
        linkCode = code
        link = .resolving
        Task {
            let result = await lookUpLink(code)
            // Edited meanwhile: that answer is for a different link.
            if linkCode == code, link == .resolving { link = result }
        }
    }

    // MARK: Bots

    private static let bots: [(BotMode, String, [CGFloat])] = [
        (.pacer, "The usual week, steady every day.", [18, 19, 18, 19, 18, 19, 18]),
        (.chill, "A little under the usual. Starts slow.", [8, 9, 10, 11, 12, 13, 14]),
        (.erratic, "Huge days and off days. Hard to read.", [26, 6, 24, 10, 28, 5, 20]),
        (.beast, "Well above the usual, every day.", [24, 25, 26, 26, 27, 28, 28]),
    ]

    private var botScreen: some View {
        GroupMatchPage {
            GroupMatchHeading("Pick a bot", detail: "Each one is scaled to the group’s usual week.")
            VStack(spacing: 10) {
                ForEach(Self.bots, id: \.0) { mode in
                    GroupMatchOptionCard(
                        title: mode.0.name,
                        detail: mode.1,
                        isSelected: bot == mode.0,
                        identifier: "competition.group.bot.\(mode.0.rawValue)"
                    ) {
                        HStack(alignment: .bottom, spacing: 3) {
                            ForEach(Array(mode.2.enumerated()), id: \.offset) { _, height in
                                RoundedRectangle(cornerRadius: 1).fill(Theme.ink).frame(width: 5, height: height)
                            }
                        }
                        .frame(height: 28, alignment: .bottom)
                    } action: {
                        bot = mode.0
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: bot)
            Text("A bot’s week is fixed before Day 1. It never reacts to the scores.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button("Add \(bot.name)") { add(.bot(bot)) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(lineup.openTeams.isEmpty)
                .accessibilityIdentifier("competition.group.bot.add")
        }
        .navigationTitle("Add a Bot")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A big selectable card: format or bot.
private struct GroupMatchOptionCard<Glyph: View>: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let identifier: String
    @ViewBuilder let glyph: Glyph
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        Button(action: action) {
            HStack(spacing: 16) {
                glyph.accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.bold)).foregroundStyle(Theme.ink)
                    Text(detail).font(.subheadline).foregroundStyle(Theme.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .background(Theme.panel, in: shape)
            .overlay {
                shape.strokeBorder(isSelected ? Theme.ink : Theme.panel, lineWidth: 2)
                    .animation(Motion.fade, value: isSelected)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }
}

/// The mark's slanted bars, one per player: amber you, an amber outline
/// for your partner, ink for everyone else.
private struct FormatGlyph: View {
    enum Mark { case you, partner, them, gap(CGFloat) }

    let marks: [Mark]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(marks.indices, id: \.self) { index in
                switch marks[index] {
                case .you: SlantedBar().fill(Theme.youFill).frame(width: 11, height: 28)
                case .partner: SlantedBar().stroke(Theme.youFill, lineWidth: 2).frame(width: 11, height: 28)
                case .them: SlantedBar().fill(Theme.ink).frame(width: 11, height: 28)
                case let .gap(width): Color.clear.frame(width: width, height: 1)
                }
            }
        }
        .frame(width: 62, alignment: .leading)
    }
}

/// A bot's square with three bars, for "Add a bot".
private struct BotGlyph: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach([14, 5, 11] as [CGFloat], id: \.self) { height in
                Rectangle().fill(Theme.onInk).frame(width: 4, height: height)
            }
        }
        .padding(.bottom, 8)
        .frame(width: 32, height: 32, alignment: .bottom)
        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Add: a small grey capsule.
private struct GroupMatchPillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Theme.control, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}
