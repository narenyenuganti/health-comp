import CompetitionCore
import ComposableArchitecture
import SwiftUI

/// Home's Friends button. Same circle as the + button.
struct FriendsToolbarButton: View {
    let requestCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "person.2")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 34, height: 34)
                .background(Theme.control, in: Circle())
                .overlay(alignment: .topTrailing) {
                    if requestCount > 0 {
                        Text(requestCount > 99 ? "99+" : String(requestCount))
                            .font(.caption2.weight(.semibold))
                            .dynamicTypeSize(.large)
                            .foregroundStyle(Theme.onInk)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Theme.ink, in: Capsule())
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("friends.open")
    }

    private var accessibilityText: String {
        switch requestCount {
        case 0: "Friends"
        case 1: "Friends, 1 request"
        default: "Friends, \(requestCount) requests"
        }
    }
}

/// "Live · Day 3 of 7", "Starts Monday" or "You lead 3–2"; nil with no match.
func friendStatusLine(
    identity: String,
    competitions: [LocalCompetitionPresentation],
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String? {
    let theirs = competitions.filter { $0.opponentIdentity == identity && !$0.isPractice }
    func isLive(_ competition: LocalCompetitionPresentation) -> Bool {
        switch competition.lifecycle {
        case .active, .endsToday, .tallying: true
        default: false
        }
    }
    func isScheduled(_ competition: LocalCompetitionPresentation) -> Bool {
        if case .scheduled = competition.lifecycle { return true }
        return false
    }
    if let match = theirs.first(where: isLive) ?? theirs.first(where: isScheduled) {
        let title = competitionStatusText(match, style: .row, locale: locale, timeZone: timeZone).title
        switch match.lifecycle {
        case .active, .endsToday: return "Live · \(title)"
        default: return title
        }
    }
    guard let record = competitionOpponentRecords(theirs).first else { return nil }
    let high = max(record.wins, record.losses), low = min(record.wins, record.losses)
    var counts: [Int] = [high, low]
    if record.ties > 0 { counts.append(record.ties) }
    let score: String = counts.map(String.init).joined(separator: "–")
    if record.wins == record.losses { return "Tied \(score)" }
    return record.wins > record.losses ? "You lead \(score)" : "\(record.opponentDisplayName) leads \(score)"
}

/// Why a friend can't be challenged now: what the Challenge sheet would
/// otherwise turn up after the tap. Nil when they can be.
func friendChallengeBlocker(
    identity: String,
    competitions: [LocalCompetitionPresentation]
) -> String? {
    let theirs = competitions.filter { $0.opponentIdentity == identity && !$0.isPractice }
    if theirs.contains(where: \.isPending) { return "Challenge pending" }
    // As `matchInProgress`: tallying doesn't count, matching the server.
    let inMatch = theirs.contains {
        switch $0.lifecycle {
        case .scheduled, .active, .endsToday: true
        default: false
        }
    }
    return inMatch ? "In a match with you" : nil
}

extension FriendsFeature.ChangeFailure {
    var message: String {
        switch self {
        case .connection: "Couldn’t update. Check your connection and try again."
        case .unavailable: "This person isn’t available."
        case .limit: "You’ve sent too many requests. Cancel one to add someone new."
        }
    }
}

/// Accept, Add and Requested on a row: the small version of the primary and
/// control buttons.
private struct FriendsRowButtonStyle: ButtonStyle {
    var isProminent = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.width(.condensed))
            .foregroundStyle(isProminent ? Theme.onInk : Theme.secondary)
            .tint(isProminent ? Theme.onInk : Theme.secondary)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(
                isProminent ? Theme.ink : Theme.control,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .animation(Motion.press, value: configuration.isPressed)
            .animation(Motion.press, value: isEnabled)
    }
}

/// Avatar, name and one line under it. Beside each other, or stacked at
/// accessibility sizes so the name gets the width.
struct FriendsPersonLabel: View {
    let person: FriendPerson
    let detail: String?
    /// Ink on a row that is dimmed as a whole, so it stays readable.
    var detailColor: Color = Theme.secondary

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            PersonAvatar(name: person.displayName, photo: person.id, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(detailColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Friends, and search in place of them while there's a query.
struct FriendsView: View {
    let store: StoreOf<MainTabFeature>

    @FocusState private var isFieldFocused: Bool
    @State private var cancelling: FriendPerson?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    private var state: FriendsFeature.State { store.competition.friends }
    private var isSearchShown: Bool { !state.query.isEmpty }
    private var pinsInvite: Bool { !dynamicTypeSize.isAccessibilitySize }

    private var settings: AccountFriendSettings {
        AccountFriendSettings(
            state: store.competition.friendSettings,
            send: { store.send(.competition(.friendSettings($0))) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pinned, so the query and its clear button never scroll away.
            searchField
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)
            ScrollView {
                // Not the field: a keystroke mustn't animate it.
                VStack(alignment: .leading, spacing: 22) {
                    if isSearchShown {
                        searchContent
                    } else {
                        listContent
                        if !pinsInvite { inviteButton }
                    }
                }
                .moving(Motion.settle, value: state)
                .moving(Motion.settle, value: isSearchShown)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { [store] in
                await store.send(.competition(.friends(.requested))).finish()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("friends.screen")
        .background(Theme.ground)
        .safeAreaInset(edge: .bottom) {
            if pinsInvite, !isSearchShown {
                inviteButton
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(Theme.ground)
            }
        }
        .navigationTitle("Friends")
        .navigationBarTitleDisplayMode(.inline)
        // Outside `.refreshable`, which a sheet presented from inside it
        // inherits: a drag down would refresh, not close.
        .sheet(isPresented: Binding(
            get: { store.competition.friendSettings.sheet != nil },
            set: { if !$0 { store.send(.competition(.friendSettings(.usernameSheetClosed))) } }
        )) {
            UsernameSheet(friends: settings)
        }
        .friendsCancelRequestDialog($cancelling) { store.send(.competition(.friends(.changeTapped($0, .cancel)))) }
        .task {
            store.send(.competition(.friends(.requested)))
            store.send(.competition(.friendSettings(.requested)))
            store.send(.competition(.challengeLinkRequested))
        }
        // The Challenge sheet's Search People.
        .onChange(of: state.focusesSearch, initial: true) { _, focuses in
            guard focuses else { return }
            isFieldFocused = true
            store.send(.competition(.friends(.searchFocusRequested(false))))
        }
        // Not `saved?.username == nil`, which is true before the settings
        // load and so never changes when they arrive with no username.
        .onChange(of: store.competition.friendSettings.saved.map { $0.username == nil } ?? false, initial: true) { _, _ in
            promptForUsernameOnce()
        }
    }

    /// Once per account: Not Now is an answer. The key is only set here, so
    /// a failed settings load never spends it.
    private func promptForUsernameOnce() {
        guard let saved = store.competition.friendSettings.saved, saved.username == nil,
              let id = store.competition.ownProfile?.id
        else { return }
        let key = Self.usernamePromptKey(id)
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        store.send(.competition(.friendSettings(.usernameSheetOpened)))
    }

    static func usernamePromptKey(_ id: UUID) -> String {
        "healthcomp.friends.username-prompted.\(id.uuidString.lowercased())"
    }

    private func change(_ person: FriendPerson, _ change: FriendsFeature.Change) {
        store.send(.competition(.friends(.changeTapped(person, change))))
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
            TextField(
                "Search name or username",
                text: Binding(
                    get: { state.query },
                    set: { store.send(.competition(.friends(.queryChanged($0)))) }
                ),
                // One line, so the long prompt would clip at accessibility sizes.
                prompt: Text(dynamicTypeSize.isAccessibilitySize ? "Search" : "Search name or username")
                    .foregroundStyle(Theme.secondary)
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .focused($isFieldFocused)
            .accessibilityIdentifier("friends.search.field")
            if !state.query.isEmpty {
                Button {
                    store.send(.competition(.friends(.queryChanged(""))))
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("friends.search.clear")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 2)
        .frame(minHeight: 48)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            if isFieldFocused {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.ink, lineWidth: 2)
            }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if let failure = state.searchFailure {
            quietLine(
                failure == .rateLimited
                    ? "Too many searches. Try again in a minute."
                    : "Couldn’t search. Check your connection and try again.",
                id: "friends.search.error"
            )
        } else if let results = state.results {
            if results.isEmpty {
                quietLine("No one found.", id: "friends.search.empty")
            } else {
                panel(results) { resultRow($0) }
                Text("Can’t find them? Send your link from Friends.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("friends.search.hint")
            }
        } else if state.isSearching {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func resultRow(_ person: FriendPerson) -> some View {
        let id = person.id.uuidString.lowercased()
        return VStack(alignment: .leading, spacing: 8) {
            rowLayout {
                NavigationLink(value: CompetitionHomeRoute.person(person.identity)) {
                    FriendsPersonLabel(person: person, detail: person.username.map { "@\($0)" })
                }
                .buttonStyle(CompetitionRowButtonStyle())
                .accessibilityIdentifier("friends.result.\(id)")
                resultControl(person)
                    .accessibilityIdentifier("friends.result.action.\(id)")
            }
            failureLine(person)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func resultControl(_ person: FriendPerson) -> some View {
        let isBusy = state.inFlight.contains(person.id)
        switch person.relationship {
        case .none:
            Button { change(person, .add) } label: { BusyLabel("Add", isBusy: isBusy) }
                .buttonStyle(FriendsRowButtonStyle())
                .disabled(isBusy)
        case .incoming:
            Button { change(person, .accept) } label: { BusyLabel("Accept", isBusy: isBusy) }
                .buttonStyle(FriendsRowButtonStyle())
                .disabled(isBusy)
        case .requested:
            Button { cancelling = person } label: { BusyLabel("Requested", isBusy: isBusy) }
                .buttonStyle(FriendsRowButtonStyle(isProminent: false))
                .disabled(isBusy)
        case .friend:
            Label("Friends", systemImage: "checkmark")
                .font(.headline.width(.condensed))
                .foregroundStyle(Theme.secondary)
                .labelStyle(.titleAndIcon)
                .frame(minHeight: 44)
                .padding(.trailing, 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Friends")
        }
    }

    // MARK: Friends

    @ViewBuilder
    private var listContent: some View {
        if let list = state.list {
            if list.friends.isEmpty, list.incoming.isEmpty {
                quietLine("No friends yet. Search for someone or send your link.", id: "friends.empty")
            }
            if !list.incoming.isEmpty {
                section("REQUESTS · \(list.incoming.count)", id: "friends.requests") {
                    panel(list.incoming) { requestRow($0) }
                }
            }
            if !list.friends.isEmpty {
                section("FRIENDS · \(list.friends.count)", id: "friends.list") {
                    panel(list.friends) { friendRow($0) }
                }
            }
        } else if state.loadFailed {
            VStack(alignment: .leading, spacing: 4) {
                quietLine("Couldn’t load your friends.", id: "friends.load-error")
                Button("Try Again") { store.send(.competition(.friends(.requested))) }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("friends.retry")
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func requestRow(_ person: FriendPerson) -> some View {
        let id = person.id.uuidString.lowercased()
        let isBusy = state.inFlight.contains(person.id)
        return VStack(alignment: .leading, spacing: 8) {
            rowLayout {
                FriendsPersonLabel(person: person, detail: person.username.map { "@\($0)" })
                HStack(spacing: 2) {
                    Button { change(person, .accept) } label: { BusyLabel("Accept", isBusy: isBusy) }
                        .buttonStyle(FriendsRowButtonStyle())
                        .disabled(isBusy)
                        .accessibilityIdentifier("friends.request.accept.\(id)")
                    Button { change(person, .decline) } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .accessibilityLabel("Decline \(person.displayName)")
                    .accessibilityIdentifier("friends.request.decline.\(id)")
                }
            }
            failureLine(person)
        }
        .padding(.vertical, 12)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("friends.request.\(id)")
    }

    private func friendRow(_ person: FriendPerson) -> some View {
        NavigationLink(value: CompetitionHomeRoute.person(person.identity)) {
            HStack(spacing: 12) {
                FriendsPersonLabel(
                    person: person,
                    detail: friendStatusLine(
                        identity: person.identity,
                        competitions: store.competition.publication?.dashboard.competitions ?? [],
                        locale: locale,
                        timeZone: timeZone
                    )
                )
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(CompetitionRowButtonStyle())
        .accessibilityIdentifier("friends.friend.\(person.id.uuidString.lowercased())")
    }

    @ViewBuilder
    private var inviteButton: some View {
        let label = Label("Invite with Your Link", systemImage: "square.and.arrow.up")
        Group {
            if let url = store.competition.challengeLink {
                ShareLink(
                    item: url,
                    subject: Text("My HealthComp challenge link"),
                    message: Text("Challenge me to a week of rings on HealthComp.")
                ) { label }
            } else {
                Button { store.send(.competition(.challengeLinkRequested)) } label: { label }
                    .disabled(!store.competition.challengeLinkLoadFailed)
            }
        }
        .buttonStyle(SecondaryButtonStyle())
        .accessibilityIdentifier("friends.invite")
    }

    // MARK: Pieces

    /// Beside each other, or stacked at accessibility sizes.
    @ViewBuilder
    private func rowLayout<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        layout { content() }
    }

    private func section<Content: View>(
        _ title: String,
        id: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title).padding(.horizontal, 4)
            content()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }

    /// Dividers start where the row's text does: past the avatar, or at the
    /// row's edge once rows stack at accessibility sizes.
    private func panel<Row: View>(
        _ people: [FriendPerson],
        @ViewBuilder row: @escaping (FriendPerson) -> Row
    ) -> some View {
        let divider: CGFloat = dynamicTypeSize.isAccessibilitySize ? 14 : 66
        return VStack(spacing: 0) {
            ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                if index > 0 { CompetitionRowDivider(inset: divider) }
                row(person)
            }
        }
        .themePanel()
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func failureLine(_ person: FriendPerson) -> some View {
        if let failure = state.failure(for: person.id) {
            Text(failure.message)
                .font(.callout)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .transition(Motion.appear)
                .accessibilityIdentifier("friends.failure.\(person.id.uuidString.lowercased())")
        }
    }

    private func quietLine(_ text: String, id: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .accessibilityIdentifier(id)
    }
}

extension View {
    /// Cancelling a request, from Friends or a person page.
    func friendsCancelRequestDialog(
        _ person: Binding<FriendPerson?>,
        cancel: @escaping (FriendPerson) -> Void
    ) -> some View {
        confirmationDialog(
            person.wrappedValue.map { "Cancel your request to \($0.displayName)?" } ?? "",
            isPresented: Binding(
                get: { person.wrappedValue != nil },
                set: { if !$0 { person.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: person.wrappedValue
        ) { target in
            Button("Cancel Request", role: .destructive) { cancel(target) }
            Button("Keep Request", role: .cancel) {}
        }
    }
}

/// Friend, block and report on a person page, for someone with a profile id.
struct PersonFriendControls {
    let person: FriendPerson
    /// Nil until your Friends list loads: Add, Cancel and Remove wait for it.
    let relationship: FriendRelationship?
    let isInFlight: Bool
    let failure: FriendsFeature.ChangeFailure?
    let isReported: Bool
    let change: (FriendsFeature.Change) -> Void
    let block: () -> Void
    let report: (_ andBlock: Bool) -> Void
}

/// The person page's confirmations.
enum PersonFriendDialog: Equatable {
    case cancelRequest, remove, block, report
}

/// Add Friend or Cancel Request, Remove Friend, Block, Unblock and Report,
/// each only when it applies, in that order. Mute goes above them.
struct PersonFriendMenuItems: View {
    let name: String
    let controls: PersonFriendControls?
    /// Nil while your block list loads: Block and Report wait for it.
    let isBlocked: Bool?
    let unblock: (() -> Void)?
    /// Whether you've played them: Add Friend is for people you've played.
    var hasPlayed = true
    @Binding var dialog: PersonFriendDialog?

    /// Add Friend or Cancel Request, when either applies.
    enum RequestItem: Equatable { case add, cancel }

    static func requestItem(_ relationship: FriendRelationship?, hasPlayed: Bool) -> RequestItem? {
        switch relationship {
        case .none?: return hasPlayed ? .add : nil
        case .requested?: return .cancel
        case .incoming?, .friend?, nil: return nil
        }
    }

    var body: some View {
        if let controls, isBlocked == false {
            Group {
                switch Self.requestItem(controls.relationship, hasPlayed: hasPlayed) {
                case .add?:
                    Button { controls.change(.add) } label: {
                        Label("Add Friend", systemImage: "person.badge.plus")
                    }
                    .accessibilityIdentifier("friends.menu.add")
                case .cancel?:
                    Button { dialog = .cancelRequest } label: {
                        Label("Cancel Request", systemImage: "xmark")
                    }
                    .accessibilityIdentifier("friends.menu.cancel-request")
                case nil:
                    EmptyView()
                }
                if controls.relationship == .friend {
                    Button { dialog = .remove } label: {
                        Label("Remove Friend", systemImage: "person.badge.minus")
                    }
                    .accessibilityIdentifier("friends.menu.remove")
                }
                Button { dialog = .block } label: {
                    Label("Block \(name)", systemImage: "hand.raised")
                }
                .accessibilityIdentifier("friends.menu.block")
            }
            .disabled(controls.isInFlight)
        }
        if isBlocked == true, let unblock {
            Button(action: unblock) {
                Label("Unblock \(name)", systemImage: "hand.raised.slash")
            }
        }
        if let controls, isBlocked == false, !controls.isReported {
            Button { dialog = .report } label: {
                Label("Report \(name)", systemImage: "flag")
            }
            .disabled(controls.isInFlight)
            .accessibilityIdentifier("friends.menu.report")
        }
    }
}

extension View {
    /// Remove, Block and Report ask first, in the tone of Decline and Block.
    /// `blocking` runs before a block is sent, so the page can pop once it lands.
    func personFriendDialogs(
        _ dialog: Binding<PersonFriendDialog?>,
        name: String,
        controls: PersonFriendControls?,
        blocking: @escaping () -> Void
    ) -> some View {
        func presents(_ kind: PersonFriendDialog) -> Binding<Bool> {
            Binding(
                get: { dialog.wrappedValue == kind && controls != nil },
                set: { if !$0, dialog.wrappedValue == kind { dialog.wrappedValue = nil } }
            )
        }
        return self
            .friendsCancelRequestDialog(Binding(
                get: { dialog.wrappedValue == .cancelRequest ? controls?.person : nil },
                set: { if $0 == nil, dialog.wrappedValue == .cancelRequest { dialog.wrappedValue = nil } }
            )) { _ in controls?.change(.cancel) }
            .confirmationDialog("Remove \(name) as a friend?", isPresented: presents(.remove), titleVisibility: .visible) {
                Button("Remove Friend", role: .destructive) { controls?.change(.remove) }
                    .accessibilityIdentifier("friends.remove.confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can still play each other with a link.")
            }
            .confirmationDialog("Block \(name)?", isPresented: presents(.block), titleVisibility: .visible) {
                Button("Block \(name)", role: .destructive) {
                    blocking()
                    controls?.block()
                }
                .accessibilityIdentifier("friends.block.confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(name) can’t challenge you or find you in search, and you’ll no longer be friends. They aren’t notified.")
            }
            .confirmationDialog("Report \(name)?", isPresented: presents(.report), titleVisibility: .visible) {
                Button("Report") { controls?.report(false) }
                    .accessibilityIdentifier("friends.report.confirm")
                Button("Report and Block \(name)", role: .destructive) {
                    blocking()
                    controls?.report(true)
                }
                .accessibilityIdentifier("friends.report.block")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("We’ll review this account. Reporting doesn’t block them.")
            }
    }
}

/// The quiet lines a person page shows after Remove, Block or Report:
/// why one failed, or that a report went in.
struct PersonFriendNotes: View {
    let failure: FriendsFeature.ChangeFailure?
    let isReported: Bool

    var body: some View {
        if let failure {
            Text(failure.message)
                .font(.callout)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .transition(Motion.appear)
                .accessibilityIdentifier("friends.person.error")
        }
        if isReported {
            Text("Reported. Thanks.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .transition(Motion.appear)
                .accessibilityIdentifier("friends.person.reported")
        }
    }
}

/// Someone you haven't played: who they are, adding them, and challenging
/// a friend. Reached through `.person`, when there is no match record to show.
struct FriendProfileView: View {
    let controls: PersonFriendControls
    var isBlocked: Bool? = false
    var unblock: (() -> Void)? = nil
    /// The Challenge sheet with this friend chosen.
    var challenge: (() -> Void)? = nil
    /// A challenge or match with them, though no finished week yet.
    var hasPlayed = false

    @State private var dialog: PersonFriendDialog?
    @State private var isBlocking = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var person: FriendPerson { controls.person }

    var body: some View {
        // Accessibility sizes scroll the button with the text; pinned, it
        // would squeeze both.
        let pinsButton = !dynamicTypeSize.isAccessibilitySize
        ScrollView {
            VStack(spacing: 6) {
                PersonAvatar(
                    name: person.displayName,
                    photo: isBlocked == false ? person.id : nil,
                    size: 112,
                    initialFont: .largeTitle.weight(.heavy).width(.condensed)
                )
                Text(person.displayName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("friends.person.name")
                if let username = person.username {
                    Text(verbatim: "@\(username)")
                        .foregroundStyle(Theme.secondary)
                        .accessibilityIdentifier("friends.person.username")
                }
                if isBlocked == true {
                    Text("\(person.displayName) can’t challenge you.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 28)
                } else if person.relationship != .friend {
                    Text("Friends can challenge each other without a link.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 28)
                        .padding(.horizontal, 16)
                }
                PersonFriendNotes(failure: nil, isReported: controls.isReported)
                    .padding(.top, 12)
                if !pinsButton {
                    footer.padding(.top, 28)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 40)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("friends.person")
        }
        .background(Theme.ground)
        .safeAreaInset(edge: .bottom) {
            if pinsButton {
                footer
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(Theme.ground)
            }
        }
        .moving(Motion.settle, value: person)
        .moving(Motion.settle, value: controls.failure)
        .moving(Motion.settle, value: controls.isReported)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    PersonFriendMenuItems(
                        name: person.displayName,
                        controls: controls,
                        isBlocked: isBlocked,
                        unblock: unblock,
                        hasPlayed: hasPlayed,
                        dialog: $dialog
                    )
                } label: {
                    CompetitionMoreLabel()
                }
                .accessibilityIdentifier("competition.more")
            }
        }
        .personFriendDialogs($dialog, name: person.displayName, controls: controls) { isBlocking = true }
        // Back to wherever they were found, once the block lands.
        .onChange(of: isBlocked) { _, blocked in
            if isBlocking, blocked == true { dismiss() }
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 10) {
            if let failure = controls.failure {
                Text(failure.message)
                    .font(.callout)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(Motion.appear)
                    .accessibilityIdentifier("friends.person.error")
            }
            if isBlocked == false {
                action
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        let isInFlight = controls.isInFlight
        switch person.relationship {
        case .none:
            Button { controls.change(.add) } label: { BusyLabel("Add Friend", isBusy: isInFlight) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isInFlight)
                .accessibilityIdentifier("friends.person.action")
        case .incoming:
            Button { controls.change(.accept) } label: { BusyLabel("Accept Request", isBusy: isInFlight) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isInFlight)
                .accessibilityIdentifier("friends.person.action")
        case .requested:
            Button { dialog = .cancelRequest } label: { BusyLabel("Requested", isBusy: isInFlight) }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isInFlight)
                .accessibilityIdentifier("friends.person.action")
        case .friend:
            if let challenge {
                Button("Challenge \(person.displayName)", action: challenge)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isInFlight)
                    .accessibilityIdentifier("friends.person.challenge")
            }
        }
    }
}
