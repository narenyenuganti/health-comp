import CompetitionCore
import ComposableArchitecture
import SwiftUI

/// A finished group match: the server's frozen standings as given, how many
/// days you (or your team) won, who carried in doubles, and Rematch Everyone.
/// A group match never moves a belt.
struct GroupMatchResultView: View {
    let match: GroupMatchPresentation
    let store: StoreOf<GroupMatchFeature>

    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize: CGFloat = 56
    @ScaledMetric(relativeTo: .title) private var scoreSize: CGFloat = 28
    @ScaledMetric(relativeTo: .largeTitle) private var teamScoreSize: CGFloat = 52
    @ScaledMetric(relativeTo: .headline) private var avatarSize: CGFloat = 32
    @ScaledMetric(relativeTo: .largeTitle) private var podiumNumberSize: CGFloat = 44
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsRematch = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                if match.format == .doubles {
                    teams
                    // Only from the server's seat totals; hidden without them.
                    if hasCarry {
                        SectionLabel("WHO CARRIED")
                        carried
                    }
                } else if dynamicTypeSize.isAccessibilitySize || tieCrossesPodium {
                    places(rows)
                } else {
                    podium
                    if rows.count > 3 { places(Array(rows.dropFirst(3))) }
                }
                Text("No belt on the line. Belts change hands in duels.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("competition.group.result.no-belt")
                // At accessibility sizes a pinned control would cover the screen.
                if dynamicTypeSize.isAccessibilitySize { rematchButton }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.ground)
        .safeAreaInset(edge: .bottom) {
            if !dynamicTypeSize.isAccessibilitySize {
                rematchButton
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                    .background(Theme.ground)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // Prefilled with the same lineup; nothing is sent until Create Match.
        .sheet(isPresented: $showsRematch) {
            GroupMatchCreateView(store: store, lineup: GroupMatchLineup(match: match))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.group.result")
    }

    private var rematchButton: some View {
        Button("Rematch Everyone") { showsRematch = true }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("competition.group.result.rematch")
    }

    // MARK: Hero

    /// The server's places, in its order.
    private var rows: [GroupMatchStandingRow] { match.standingRows }

    private var viewerRow: GroupMatchStandingRow? {
        rows.first { $0.subject == match.viewerSubject }
    }

    /// Your place is shared.
    private var isTied: Bool {
        rows.filter { $0.place == viewerRow?.place }.count > 1
    }

    private var isTiedFirst: Bool { isTied && viewerRow?.place == 1 }

    /// Tied places look equal: the podium only when no tie spans 3rd and 4th.
    private var tieCrossesPodium: Bool {
        rows.count > 3 && rows[2].place == rows[3].place
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Final · \(match.format.title)")
                .textCase(.uppercase)
                .font(.themeLabel)
                .tracking(1.2)
                .foregroundStyle(Theme.secondary)
                .padding(.bottom, 10)
            Text(title)
                .textCase(.uppercase)
                .font(.score(size: headlineSize))
                .foregroundStyle(titleColor)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("competition.group.result.title")
            summary
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("competition.group.result.summary")
        }
    }

    private var title: String {
        let team = match.format == .doubles
        guard let viewerRow else { return "Final" }
        if isTied { return team ? "Tied" : "Tied for \(GroupMatchPresentation.placeText(viewerRow.place))" }
        if viewerRow.place == 1 { return team ? "Your team won" : "You won" }
        return team ? "Your team lost" : "You finished \(GroupMatchPresentation.placeText(viewerRow.place))"
    }

    // Amber is a win; a tie is neutral, as in a duel.
    private var titleColor: Color {
        isTied ? Theme.secondary : viewerRow?.place == 1 ? Theme.you : Theme.ink
    }

    /// "By 38 over Sam. You won 3 days."
    private var summary: Text {
        guard let viewerRow else { return Text("") }
        let isDoubles = match.format == .doubles
        let lead: Text
        if isTiedFirst {
            let others = rows.filter { $0.place == 1 && $0.subject != match.viewerSubject }
            let names = others.map { match.name(of: $0.subject) }.formatted(.list(type: .and))
            lead = isDoubles
                ? Text("Both teams finished on \(points(viewerRow.centipoints)).")
                : Text("You and \(names) finished on \(points(viewerRow.centipoints)).")
        } else if viewerRow.place == 1, let second = rows.first(where: { $0.place > 1 }) {
            let margin = Text(GroupMatchPresentation.pointsText(viewerRow.centipoints - second.centipoints))
                .foregroundStyle(Theme.you)
                .bold()
            lead = isDoubles
                ? Text("By \(margin).")
                : Text("By \(margin) over \(match.name(of: second.subject)).")
        } else if let above = rows.last(where: { $0.place < viewerRow.place }) {
            let ahead = rows.filter { $0.place == above.place }.map { match.name(of: $0.subject) }
            let gap = Text(GroupMatchPresentation.pointsText(above.centipoints - viewerRow.centipoints)).bold()
            lead = isDoubles
                ? Text("By \(gap).")
                : Text("\(gap) behind \(ahead.formatted(.list(type: .and))).")
        } else {
            lead = Text("")
        }
        // From the server's day values only; left out without them.
        guard let daysWon = match.frozenDaysWon(by: match.viewerSubject), daysWon > 0 else { return lead }
        let who = isDoubles ? "Your team" : "You"
        return Text("\(lead) \(who) won \(daysWon == 1 ? "1 day" : "\(daysWon) days").")
    }

    /// Decimals only when whole points would hide a real difference between
    /// two totals shown here.
    private var fractionDigits: Int {
        func digits(_ totals: [Int]) -> [Int] {
            totals.flatMap { a in
                totals.map { competitionFinalFractionDigits(userPoints: Double(a) / 100, opponentPoints: Double($0) / 100) }
            }
        }
        return (digits(rows.map(\.centipoints)) + digits(match.frozenSeatTotals.map { Array($0.values) } ?? [])).max() ?? 0
    }

    private func points(_ centipoints: Int) -> String {
        competitionPointsText(Double(centipoints) / 100, fractionDigits: fractionDigits, locale: locale)
    }

    private func spoken(_ centipoints: Int) -> String {
        competitionPointsAccessibilityText(Double(centipoints) / 100, fractionDigits: fractionDigits, locale: locale)
    }

    // MARK: Free-for-all

    private func seat(_ row: GroupMatchStandingRow) -> GroupMatchSeat? {
        guard case let .seat(id) = row.subject else { return nil }
        return match.seats.first { $0.id == id }
    }

    /// 2nd, 1st, 3rd from left to right; tied places stand as tall.
    private var podium: some View {
        let top = Array(rows.prefix(3).enumerated())
        let order = [1, 0, 2].compactMap { index in top.first { $0.offset == index } }
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(order, id: \.element.id) { index, row in
                if let seat = seat(row) {
                    podiumColumn(row, seat: seat, index: index)
                }
            }
        }
        .padding(.top, 8)
    }

    private func podiumColumn(_ row: GroupMatchStandingRow, seat: GroupMatchSeat, index: Int) -> some View {
        let isYou = seat.id == match.viewerSeatID
        let height: CGFloat = switch row.place {
        case 1: 160
        case 2: 110
        default: 76
        }
        return VStack(spacing: 6) {
            PersonAvatar(name: seat.name, photo: seat.profileID, size: avatarSize, isYou: isYou, isBot: seat.isBot)
            Text(isYou ? "You" : seat.name)
                .fontWeight(isYou ? .bold : .regular)
                .foregroundStyle(isYou ? Theme.you : Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(points(row.centipoints))
                .font(.score(size: scoreSize).monospacedDigit())
                .foregroundStyle(isYou ? Theme.you : Theme.ink)
            Text("\(row.place)")
                .font(.score(size: podiumNumberSize))
                .foregroundStyle(isYou ? Theme.onYouFill : Theme.onInk)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .top)
                .background(
                    isYou ? Theme.youFill : row.place >= 3 ? Theme.tertiary : Theme.ink,
                    in: UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous)
                )
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(placeLabel(row, seat: seat))
        .accessibilityIdentifier("competition.group.result.row.\(index + 1)")
    }

    /// Places below the podium, or every place at accessibility sizes.
    private func places(_ shown: [GroupMatchStandingRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(shown) { row in
                if let seat = seat(row), let index = rows.firstIndex(of: row) {
                    if row != shown.first { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    placeRow(row, seat: seat, index: index)
                }
            }
        }
        .padding(.horizontal, 16)
        .themePanel()
    }

    private func placeRow(_ row: GroupMatchStandingRow, seat: GroupMatchSeat, index: Int) -> some View {
        let isYou = seat.id == match.viewerSeatID
        let color = isYou ? Theme.you : Theme.ink
        return HStack(spacing: 12) {
            Text("\(row.place)")
                .font(.score(size: scoreSize))
                .foregroundStyle(color)
            PersonAvatar(name: seat.name, photo: seat.profileID, size: avatarSize, isYou: isYou, isBot: seat.isBot)
            Text(isYou ? "You" : seat.name)
                .fontWeight(isYou ? .bold : .regular)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(points(row.centipoints))
                .font(.score(size: scoreSize).monospacedDigit())
                .foregroundStyle(color)
                .fixedSize()
        }
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(placeLabel(row, seat: seat))
        .accessibilityIdentifier("competition.group.result.row.\(index + 1)")
    }

    /// "1st, You, 2,941 points" or "1st, tied, Sam, bot, 2,941 points".
    private func placeLabel(_ row: GroupMatchStandingRow, seat: GroupMatchSeat) -> String {
        let tied = rows.filter { $0.place == row.place }.count > 1
        return [
            GroupMatchPresentation.placeText(row.place),
            tied ? "tied" : nil,
            seat.id == match.viewerSeatID ? "You" : seat.name,
            seat.isBot ? "bot" : nil,
            spoken(row.centipoints),
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    // MARK: Doubles

    private var viewerTeam: Int { match.viewer.team ?? 1 }

    private func teamRow(_ team: Int) -> GroupMatchStandingRow? {
        rows.first { $0.subject == .team(team) }
    }

    private var teams: some View {
        let theirs = viewerTeam == 1 ? 2 : 1
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom) {
                teamTotal(viewerTeam, alignment: .leading)
                Spacer(minLength: 12)
                teamTotal(theirs, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 12) {
                teamTotal(viewerTeam, alignment: .leading)
                teamTotal(theirs, alignment: .leading)
            }
        }
    }

    private func teamTotal(_ team: Int, alignment: HorizontalAlignment) -> some View {
        let isYours = team == viewerTeam
        let row = teamRow(team)
        return VStack(alignment: alignment, spacing: 6) {
            Text(match.name(of: .team(team)))
                .textCase(.uppercase)
                .font(.themeLabel)
                .tracking(1.2)
            Text(points(row?.centipoints ?? 0))
                .font(.score(size: teamScoreSize).monospacedDigit())
        }
        .foregroundStyle(isYours ? Theme.you : Theme.ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([
            row.map { GroupMatchPresentation.placeText($0.place) },
            isYours ? "Your team" : nil,
            match.seats.filter { $0.team == team }
                .sorted { ($0.id == match.viewerSeatID ? 0 : $0.number) < ($1.id == match.viewerSeatID ? 0 : $1.number) }
                .map(spokenName)
                .formatted(.list(type: .and)),
            spoken(row?.centipoints ?? 0),
        ].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("competition.group.result.team.\(isYours ? "yours" : "theirs")")
    }

    private var carried: some View {
        let theirs = viewerTeam == 1 ? 2 : 1
        return VStack(spacing: 10) {
            carry(viewerTeam)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            carry(theirs)
        }
        .padding(16)
        .themePanel()
    }

    /// Your team: you first. Theirs: the bigger share first. The first named
    /// carries the percentage.
    private func carry(_ team: Int) -> some View {
        let isYours = team == viewerTeam
        let members = match.seats.filter { $0.team == team }.sorted { lhs, rhs in
            if isYours { return lhs.id == match.viewerSeatID }
            return (total(lhs), -lhs.number) > (total(rhs), -rhs.number)
        }
        let share = members.first.flatMap { match.frozenCarryPercent(seatID: $0.id) }
        return VStack(spacing: 10) {
            GeometryReader { proxy in
                let width = proxy.size.width - 3
                HStack(spacing: 3) {
                    if members.count == 2, let share {
                        let first = width * CGFloat(share) / 100
                        segment(members[0], isYours: isYours, isLead: true).frame(width: first)
                        segment(members[1], isYours: isYours, isLead: false).frame(width: width - first)
                    } else {
                        // A team with no points has no split to show.
                        Capsule().fill(Theme.hairline)
                    }
                }
            }
            .frame(height: 14)
            .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack {
                    if members.count == 2 {
                        legend(members[0], share: share)
                        Spacer(minLength: 8)
                        legend(members[1], share: nil)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(members.enumerated()), id: \.element.id) { index, seat in
                        legend(seat, share: index == 0 ? share : nil)
                    }
                }
            }
            .font(.subheadline)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(members.enumerated().map { index, seat in
            [
                spokenName(seat),
                spoken(total(seat)),
                index == 0 ? share.map { "\($0) percent of the team" } : nil,
            ].compactMap { $0 }.joined(separator: ", ")
        }.joined(separator: ". "))
        .accessibilityIdentifier("competition.group.result.carry.\(isYours ? "yours" : "theirs")")
    }

    /// Every seat has a total in the server's result.
    private var hasCarry: Bool {
        guard let totals = match.frozenSeatTotals else { return false }
        return match.seats.allSatisfy { totals[$0.id] != nil }
    }

    private func total(_ seat: GroupMatchSeat) -> Int {
        match.frozenSeatTotals?[seat.id] ?? 0
    }

    /// "You", "Sam", or "Pacer, bot".
    private func spokenName(_ seat: GroupMatchSeat) -> String {
        seat.id == match.viewerSeatID ? "You" : seat.isBot ? "\(seat.name), bot" : seat.name
    }

    /// You fill amber and your partner is an amber outline; a bot is never
    /// amber. Opponents are ink and grey.
    @ViewBuilder
    private func segment(_ seat: GroupMatchSeat, isYours: Bool, isLead: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        if seat.id == match.viewerSeatID {
            shape.fill(Theme.youFill)
        } else if isYours {
            shape.strokeBorder(seat.isBot ? Theme.ink : Theme.youFill, lineWidth: 2)
        } else {
            shape.fill(isLead ? Theme.ink : Theme.tertiary)
        }
    }

    private func legend(_ seat: GroupMatchSeat, share: Int?) -> some View {
        let isYou = seat.id == match.viewerSeatID
        let label = Text("\(isYou ? "You" : seat.name) \(points(total(seat)))")
            .fontWeight(isYou ? .bold : .regular)
            .foregroundStyle(isYou ? Theme.you : Theme.ink)
        return Group {
            if let share {
                Text("\(label) \(Text("· \(share)%").foregroundStyle(Theme.secondary))")
            } else {
                label
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
