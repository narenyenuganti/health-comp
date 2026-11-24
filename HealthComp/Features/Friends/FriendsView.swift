import CompetitionCore
import ComposableArchitecture
import SwiftUI

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

func friendChallengeBlocker(
    identity: String,
    competitions: [LocalCompetitionPresentation]
) -> String? {
    let theirs = competitions.filter { $0.opponentIdentity == identity && !$0.isPractice }
    if theirs.contains(where: \.isPending) { return "Challenge pending" }
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
                in: RoundedRectangle(cornerRadius: 12)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .animation(Motion.press, value: configuration.isPressed)
            .animation(Motion.press, value: isEnabled)
    }
}

struct FriendsPersonLabel: View {
    let person: FriendPerson
    let detail: String?
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

struct FriendsView: View {
    let store: StoreOf<MainTabFeature>

    @FocusState private var isFieldFocused: Bool
    @State private var cancelling: FriendPerson?
    @State private var sortOrder: FriendsSortOrder = .name
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
            searchField
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)
            ScrollView {
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
        .sheet(isPresented: Binding(
            get: { store.competition.friendSettings.sheet != nil },
            set: { if !$0 { store.send(.competition(.friendSettings(.usernameSheetClosed))) } }
        )) {
            UsernameSheet(friends: settings)
        }
        .friendsCancelRequestDialog($cancelling) { store.send(.competition(.friends(.changeTapped($0, .cancel)))) }
        .onChange(of: spokenStatus) { _, new in
            if let new { AccessibilityNotification.Announcement(new).post() }
        }
        .task {
            store.send(.competition(.friends(.requested)))
            store.send(.competition(.friendSettings(.requested)))
            store.send(.competition(.challengeLinkRequested))
        }
        .onChange(of: state.focusesSearch, initial: true) { _, focuses in
            guard focuses else { return }
            isFieldFocused = true
            store.send(.competition(.friends(.searchFocusRequested(false))))
        }
        .onChange(of: store.competition.friendSettings.saved.map { $0.username == nil } ?? false, initial: true) { _, _ in
            promptForUsernameOnce()
        }
    }

    private var spokenStatus: String? {
        if let failure = state.failure { return failure.failure.message }
        if let searchFailureText { return searchFailureText }
        guard let results = state.results else { return nil }
        switch results.count {
        case 0: return "No one found."
        case 1: return "1 person found"
        default: return "\(results.count) people found"
        }
    }

    private var searchFailureText: String? {
        state.searchFailure.map {
            $0 == .rateLimited
                ? "Too many searches. Try again in a minute."
                : "Couldn’t search. Check your connection and try again."
        }
    }

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
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            if isFieldFocused {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.ink, lineWidth: 2)
            }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if let searchFailureText {
            quietLine(searchFailureText, id: "friends.search.error")
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
        } else {
            quietLine("Type at least 3 characters.", id: "friends.search.short")
        }
    }

    private func resultRow(_ person: FriendPerson) -> some View {
        let id = person.id.uuidString.lowercased()
        return VStack(alignment: .leading, spacing: 8) {
            rowLayout {
                NavigationLink(value: CompetitionHomeRoute.profile(person.identity)) {
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
                .accessibilityValue(person.displayName)
                .accessibilityInputLabels(["Add \(person.displayName)", "Add"])
        case .incoming:
            Button { change(person, .accept) } label: { BusyLabel("Accept", isBusy: isBusy) }
                .buttonStyle(FriendsRowButtonStyle())
                .disabled(isBusy)
                .accessibilityValue(person.displayName)
                .accessibilityInputLabels(["Accept \(person.displayName)", "Accept"])
        case .requested:
            requestedButton(person, isBusy: isBusy)
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

    @ViewBuilder
    private var listContent: some View {
        let competitions = store.competition.publication?.dashboard.competitions ?? []
        let highlights = ringsideHighlights(competitions, locale: locale)
        if let list = state.list {
            if !highlights.isEmpty {
                RingsideHighlightsStrip(
                    highlights: highlights,
                    openMatch: { id in store.send(.pathChanged([id])) },
                    react: { id, ordinal, kind in
                        store.send(.competition(.reactionTapped(id, .day(ordinal), kind)))
                    }
                )
            }
            if list.friends.isEmpty, list.incoming.isEmpty, list.outgoing.isEmpty {
                quietLine("No friends yet. Search for someone or send your link.", id: "friends.empty")
            }
            if !list.incoming.isEmpty {
                section("REQUESTS · \(list.incoming.count)", id: "friends.requests") {
                    panel(list.incoming) { requestRow($0) }
                }
            }
            if !list.friends.isEmpty {
                let ordered = sortedFriends(list.friends, by: sortOrder, competitions: competitions)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SectionLabel("FRIENDS · \(list.friends.count)")
                        Spacer(minLength: 8)
                        if list.friends.count > 1 {
                            Menu {
                                Picker("Sort by", selection: $sortOrder) {
                                    ForEach(FriendsSortOrder.allCases) { option in
                                        Text(option.title).tag(option)
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(sortOrder.title)
                                        .font(.caption.weight(.bold).width(.condensed))
                                    Image(systemName: "arrow.up.arrow.down")
                                        .font(.caption2.weight(.bold))
                                }
                                .foregroundStyle(Theme.you)
                                .padding(.horizontal, 8)
                                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                                .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("friends.sort")
                        }
                    }
                    .padding(.horizontal, 4)
                    panel(ordered) { friendRow($0) }
                }
                .moving(Motion.settle, value: sortOrder)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("friends.list")
            }
            if !list.outgoing.isEmpty {
                section("SENT · \(list.outgoing.count)", id: "friends.sent") {
                    panel(list.outgoing) { sentRow($0) }
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
                personLink(person)
                HStack(spacing: 10) {
                    Button { change(person, .accept) } label: { BusyLabel("Accept", isBusy: isBusy) }
                        .buttonStyle(FriendsRowButtonStyle())
                        .disabled(isBusy)
                        .accessibilityValue(person.displayName)
                        .accessibilityInputLabels(["Accept \(person.displayName)", "Accept"])
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

    private func sentRow(_ person: FriendPerson) -> some View {
        let id = person.id.uuidString.lowercased()
        return VStack(alignment: .leading, spacing: 8) {
            rowLayout {
                personLink(person)
                requestedButton(person, isBusy: state.inFlight.contains(person.id))
            }
            failureLine(person)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("friends.sent.\(id)")
    }

    private func requestedButton(_ person: FriendPerson, isBusy: Bool) -> some View {
        Button { cancelling = person } label: { BusyLabel("Requested", isBusy: isBusy) }
            .buttonStyle(FriendsRowButtonStyle(isProminent: false))
            .disabled(isBusy)
            .accessibilityValue(person.displayName)
            .accessibilityHint("Cancels your request")
            .accessibilityInputLabels(["Requested \(person.displayName)", "Requested"])
    }

    private func personLink(_ person: FriendPerson) -> some View {
        NavigationLink(value: CompetitionHomeRoute.profile(person.identity)) {
            FriendsPersonLabel(person: person, detail: person.username.map { "@\($0)" })
        }
        .buttonStyle(CompetitionRowButtonStyle())
    }

    private func friendRow(_ person: FriendPerson) -> some View {
        let competitions = store.competition.publication?.dashboard.competitions ?? []
        let todayPoints = sortOrder == .todayPoints
            ? friendLiveTodayPoints(identity: person.identity, competitions: competitions)
            : nil
        let margin = sortOrder == .margin
            ? friendLiveMargin(identity: person.identity, competitions: competitions)
            : nil
        return NavigationLink(value: CompetitionHomeRoute.profile(person.identity)) {
            HStack(spacing: 12) {
                FriendsPersonLabel(
                    person: person,
                    detail: friendStatusLine(
                        identity: person.identity,
                        competitions: competitions,
                        locale: locale,
                        timeZone: timeZone
                    )
                )
                if let todayPoints {
                    Text(competitionPointsText(todayPoints, locale: locale))
                        .font(.headline.weight(.heavy).width(.condensed).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                } else if let margin {
                    let sign = margin > 0 ? "+" : margin < 0 ? "\u{2212}" : ""
                    Text("\(sign)\(competitionPointsText(abs(margin), locale: locale))")
                        .font(.headline.weight(.heavy).width(.condensed).monospacedDigit())
                        .foregroundStyle(margin > 0 ? Theme.you : Theme.ink)
                }
                DisclosureChevron()
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
        .clipShape(RoundedRectangle(cornerRadius: 20))
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

struct PersonFriendControls {
    let person: FriendPerson
    let relationship: FriendRelationship?
    let isInFlight: Bool
    let failure: FriendsFeature.ChangeFailure?
    let isReported: Bool
    let change: (FriendsFeature.Change) -> Void
    let block: () -> Void
    let report: (_ andBlock: Bool) -> Void
}

enum PersonFriendDialog: Equatable {
    case cancelRequest, remove, block, report
}

struct PersonFriendMenuItems: View {
    let name: String
    let controls: PersonFriendControls?
    let isBlocked: Bool?
    let unblock: (() -> Void)?
    var hasPlayed = true
    @Binding var dialog: PersonFriendDialog?

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

struct FriendProfileView: View {
    let controls: PersonFriendControls
    var isBlocked: Bool? = false
    var unblock: (() -> Void)? = nil
    var challenge: (() -> Void)? = nil
    var hasPlayed = false
    var rivalry: CompetitionProfileRivalry? = nil
    var career: CompetitionCareer? = nil
    var ownCareer: CompetitionCareer? = nil
    var muteButton: CompetitionMuteButton? = nil
    var drawerBack: (() -> Void)? = nil

    @State private var dialog: PersonFriendDialog?
    @State private var isBlocking = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @ScaledMetric(relativeTo: .largeTitle) private var nameSize: CGFloat = 52
    @ScaledMetric(relativeTo: .largeTitle) private var recordSize: CGFloat = 64
    @ScaledMetric(relativeTo: .title2) private var tapeValueSize: CGFloat = 21

    private var person: FriendPerson { controls.person }
    private var hasWeeks: Bool { rivalry?.weeks.isEmpty == false }
    private var isFirstMatch: Bool {
        guard let rivalry else { return false }
        return rivalry.weeks.isEmpty && rivalry.challengeTitle == nil
    }

    var body: some View {
        let pinsButton = !dynamicTypeSize.isAccessibilitySize
        VStack(spacing: 0) {
            if let drawerBack {
                CompetitionDrawerHeader(back: drawerBack) {
                    moreMenu(usesDrawerStyle: true)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if isBlocked == true {
                        quietLine("\(person.displayName) can’t challenge you.")
                    } else if let rivalry, let record = rivalry.record, hasWeeks {
                        recordSection(record, rivalry: rivalry)
                    } else if isFirstMatch {
                        beltPrize("FIRST MATCH", line: "Win this week to take it.")
                    } else if person.relationship == .friend {
                        beltPrize("NOT PLAYED YET", line: "Win your first week with \(person.displayName) to take it.")
                    } else {
                        quietLine("Friends can challenge each other without a link.")
                    }
                    if isBlocked == false, let career, let ownCareer {
                        tape(you: ownCareer, them: career)
                    }
                    PersonFriendNotes(failure: nil, isReported: controls.isReported)
                    if !pinsButton {
                        footer
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("friends.person")
            }
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
        .moving(Motion.settle, value: career)
        .onChange(of: controls.failure) { _, new in
            if let new { AccessibilityNotification.Announcement(new.message).post() }
        }
        .onChange(of: controls.isReported) { _, reported in
            if reported { AccessibilityNotification.Announcement("Reported. Thanks.").post() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if drawerBack == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    moreMenu(usesDrawerStyle: false)
                }
            }
        }
        .personFriendDialogs($dialog, name: person.displayName, controls: controls) { isBlocking = true }
        .onChange(of: isBlocked) { _, blocked in
            if isBlocking, blocked == true { dismiss() }
        }
    }

    private func moreMenu(usesDrawerStyle: Bool) -> some View {
        Menu {
            if let muteButton {
                muteButton
            }
            PersonFriendMenuItems(
                name: person.displayName,
                controls: controls,
                isBlocked: isBlocked,
                unblock: unblock,
                hasPlayed: hasPlayed,
                dialog: $dialog
            )
        } label: {
            if usesDrawerStyle {
                CompetitionDrawerMoreLabel()
            } else {
                CompetitionMoreLabel()
            }
        }
        .accessibilityIdentifier("competition.more")
    }

    private var rowLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
    }

    private var header: some View {
        rowLayout {
            PersonAvatar(
                name: person.displayName,
                photo: isBlocked == false ? person.id : nil,
                size: 96,
                initialFont: .largeTitle.weight(.heavy).width(.condensed)
            )
            VStack(alignment: .leading, spacing: 0) {
                Text(person.displayName.uppercased(with: locale))
                    .font(.score(size: dynamicTypeSize.isAccessibilitySize ? min(nameSize, 72) : nameSize))
                    .foregroundStyle(Theme.ink)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.5)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(person.displayName)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("friends.person.name")
                if let username = person.username {
                    Text(verbatim: "@\(username)")
                        .foregroundStyle(Theme.secondary)
                        .accessibilityIdentifier("friends.person.username")
                }
            }
        }
    }

    private func quietLine(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func recordSection(_ record: CompetitionOpponentRecord, rivalry: CompetitionProfileRivalry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    recordLabel
                    Spacer(minLength: 8)
                    weeksLabel(rivalry.weeks.count)
                }
                VStack(alignment: .leading, spacing: 4) {
                    recordLabel
                    weeksLabel(rivalry.weeks.count)
                }
            }
            competitionRecordText(record)
                .font(.score(size: dynamicTypeSize.isAccessibilitySize ? min(recordSize, 96) : recordSize).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityLabel(record.accessibilityText)
                .accessibilityIdentifier("friends.person.record")
            if competitionRivalryPieces(weeks: rivalry.weeks.count, isLedger: false).form {
                CompetitionFormStrip(
                    outcomes: rivalry.weeks.compactMap(\.terminalResult?.outcome),
                    opponentName: person.displayName,
                    isLive: rivalry.isLive
                )
            }
        }
        beltRow(rivalry)
    }

    private var recordLabel: some View {
        SectionLabel("YOUR RECORD WITH \(person.displayName.uppercased(with: locale))")
            .fixedSize(horizontal: false, vertical: true)
    }

    private func weeksLabel(_ count: Int) -> some View {
                Text(competitionWeeksText(count).uppercased(with: locale))
                    .themeLabel()
                    .foregroundStyle(Theme.secondary)
    }

    private func beltRow(_ rivalry: CompetitionProfileRivalry) -> some View {
        let belt = rivalry.belt
        let since = belt.holder == nil ? nil : belt.current.flatMap {
            competitionBeltSinceText($0, weeks: rivalry.weeks, now: rivalry.now, locale: locale, timeZone: timeZone)
        }
        let defenses = belt.holder == nil ? 0 : belt.current?.defenses ?? 0
        let title = competitionBeltTitle(belt, name: person.displayName)
        let holdLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 12))
        return VStack(alignment: .leading, spacing: 12) {
            if let holder = belt.holder {
                CompetitionBeltHeroArt(holder: holder)
            }
            holdLayout {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(belt.holder == .you ? Theme.you : Theme.ink)
                    if let since {
                        Text(since)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if defenses > 0 {
                    if !dynamicTypeSize.isAccessibilitySize {
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
                        CompetitionDefensePips(
                            count: defenses,
                            color: belt.holder == .you ? Theme.youFill : Theme.ink
                        )
                        Text(competitionDefensesText(defenses).uppercased(with: locale))
                            .themeLabel()
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, belt.holder == nil ? 16 : 0)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themePanel()
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [title, since, defenses > 0 ? competitionDefensesText(defenses) : nil]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
        .accessibilityIdentifier("friends.person.belt")
    }

    private func beltPrize(_ label: String, line: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CompetitionBeltHeroArt(holder: .you)
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(label)
                Text("No one holds the belt yet")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 2)
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themePanel()
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("friends.person.prize")
    }

    private func tape(you: CompetitionCareer, them: CompetitionCareer) -> some View {
        let rows = [
            ("CAREER", you.text, them.text),
            ("BELTS", String(you.belts), String(them.belts)),
            ("WIN STREAK", String(you.winStreak), String(them.winStreak)),
            ("BEST WEEK", competitionPointsText(you.bestWeek), competitionPointsText(them.bestWeek)),
        ]
        let name = person.displayName
        return VStack(spacing: 10) {
            if !dynamicTypeSize.isAccessibilitySize {
                CompetitionTapeRow(
                    you: "YOU", label: "TALE OF THE TAPE", them: name.uppercased(with: locale), valueFont: .themeLabel
                )
            }
            ForEach(rows, id: \.0) { label, yours, theirs in
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                            .themeLabel(tracking: 1.1)
                            .foregroundStyle(Theme.secondary)
                        Text("You \(yours)").foregroundStyle(Theme.you)
                        Text("\(name) \(theirs)").foregroundStyle(Theme.ink)
                    }
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    CompetitionTapeRow(you: yours, label: label, them: theirs, valueFont: .score(size: tapeValueSize))
                }
            }
        }
        .padding(16)
        .themePanel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rows.map { "\($0.0): You \($0.1), \(name) \($0.2)" }.joined(separator: ", "))
        .accessibilityIdentifier("friends.person.tape")
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
                if let identity = rivalry?.record?.opponentIdentity, hasWeeks {
                    NavigationLink("All Weeks with \(person.displayName)", value: CompetitionHomeRoute.person(identity))
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("competition.profile.weeks")
                    if person.relationship == .incoming {
                        action
                    } else if let title = rivalry?.challengeTitle, let challenge {
                        Button(title, action: challenge)
                            .buttonStyle(PrimaryButtonStyle())
                            .accessibilityIdentifier("friends.person.challenge")
                    }
                } else {
                    action
                }
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
            if let challenge, !isFirstMatch {
                Button(rivalry?.challengeTitle ?? "Challenge \(person.displayName)", action: challenge)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isInFlight)
                    .accessibilityIdentifier("friends.person.challenge")
            }
        }
    }
}
