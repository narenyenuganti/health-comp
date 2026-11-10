import CompetitionCore
import SwiftUI

/// The group lineup before a match: one slanted panel per player (per team
/// in doubles) slams in, then they part onto the match. The duel intro's
/// host plays it, on the duel's clock: once per match per device, and again
/// from the match's ••• menu.
struct GroupMatchVersusContent: Equatable {
    struct Person: Equatable, Identifiable {
        let id: UUID
        let name: String
        let profileID: UUID?
        let isYou: Bool
        let isBot: Bool
    }

    let id: CompetitionID
    /// "Four-Way", "Doubles".
    let title: String
    /// One panel per player, or per team in doubles; yours first.
    let panels: [[Person]]
    /// "Day 1 is Monday. Most points after seven days wins."
    let footer: String

    var announcement: String {
        let teams = panels.map { $0.map(\.name).formatted(.list(type: .and)) }
        let lineup = panels.count == 2 && panels[0].count == 2
            ? teams.joined(separator: " versus ")
            : teams.formatted(.list(type: .and))
        return "\(title). \(lineup). \(footer)"
    }
}

/// Autoplays only when scheduled or on Day 1. A replay can show a later day.
func groupMatchVersusIntroContent(
    _ match: GroupMatchPresentation,
    source: CompetitionPublicationSource,
    locale: Locale = .current,
    isReplay: Bool = false
) -> GroupMatchVersusContent? {
    guard source == .remoteParticipants else { return nil }
    let dayLine: String
    switch match.lifecycle {
    case .scheduled:
        guard let first = match.schedule?.startDay else { return nil }
        dayLine = "Day 1 is \(weekdayName(first, locale: locale))"
    case .active(dayOrdinal: 1):
        dayLine = "Day 1 starts now"
    case .active, .endsToday, .tallying:
        guard isReplay else { return nil }
        dayLine = competitionStatusText(
            match.lifecycle, schedule: match.schedule, opponentDisplayName: "", style: .card, locale: locale
        ).title
    default:
        return nil
    }
    func person(_ seat: GroupMatchSeat) -> GroupMatchVersusContent.Person {
        let isYou = seat.id == match.viewerSeatID
        return .init(id: seat.id, name: isYou ? "You" : seat.name, profileID: seat.profileID, isYou: isYou, isBot: seat.isBot)
    }
    let panels: [[GroupMatchVersusContent.Person]] = match.format == .doubles
        ? ([match.viewer.team] + Set(match.seats.map(\.team)).subtracting([match.viewer.team]).sorted { ($0 ?? 0) < ($1 ?? 0) })
            .compactMap { $0 }
            .map { match.members(of: .team($0)).map(person) }
        : match.members(of: match.viewerSubject).map { [person($0)] }
            + match.seats.filter { $0.id != match.viewerSeatID }.sorted { $0.number < $1.number }.map { [person($0)] }
    let rule = match.format == .doubles ? "Partners’ points add up." : "Most points after seven days wins."
    return GroupMatchVersusContent(id: match.id, title: match.format.title, panels: panels, footer: "\(dayLine). \(rule)")
}

/// The mockup's 390×844 layout scaled to any screen: panels 520 wide from
/// -65, skewed 11 degrees, under the header and over the footer.
private struct GroupVersusStage {
    static let skew = tan(11 * Double.pi / 180)

    let size: CGSize
    let insets: EdgeInsets
    let labelLine: CGFloat
    let count: Int

    var kx: CGFloat { size.width / 390 }
    var k: CGFloat { min(kx, size.height / 844) }
    var titleSize: CGFloat { 44 * k }
    var headerTop: CGFloat { insets.top + 8 }
    var top: CGFloat { headerTop + labelLine + 8 + titleSize + 20 }
    var footerTop: CGFloat { size.height - (42 + 2 * labelLine + max(insets.bottom, 8) + 12) }
    var height: CGFloat { footerTop - top }
    /// How far the skew moves an edge at the top or bottom.
    var lean: CGFloat { height / 2 * Self.skew }
    var panelWidth: CGFloat { (520 * kx - 4 * CGFloat(count - 1)) / CGFloat(count) }

    func midX(_ index: Int) -> CGFloat {
        -65 * kx + CGFloat(index) * (panelWidth + 4) + panelWidth / 2
    }
}

/// A panel's parallelogram in a rect `2 * lean` wider than the panel.
private struct SkewedPanel: Shape {
    let lean: CGFloat

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addLines([
                CGPoint(x: rect.minX + 2 * lean, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX - 2 * lean, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY),
            ])
            path.closeSubpath()
        }
    }
}

struct GroupMatchVersusIntroView: View {
    let content: GroupMatchVersusContent
    /// By seat id, decided once when the intro starts.
    let photos: [UUID: ProfilePhoto]
    let finished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var labelLine: CGFloat = 20
    @State private var start = Date()
    @State private var isSkipped = false
    /// Reduce Motion's fade.
    @State private var isShown = false
    @State private var hits = 0
    @State private var stamps = 0

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let stage = GroupVersusStage(
                size: CGSize(
                    width: proxy.size.width + insets.leading + insets.trailing,
                    height: proxy.size.height + insets.top + insets.bottom
                ),
                insets: insets,
                labelLine: labelLine,
                count: content.panels.count
            )
            TimelineView(.animation(paused: reduceMotion || isHeld)) { timeline in
                frame(
                    stage,
                    at: reduceMotion || isHeld
                        ? VersusClock.composed
                        : timeline.date.timeIntervalSince(start)
                )
            }
            .frame(width: stage.size.width, height: stage.size.height)
            .contentShape(Rectangle())
            .onTapGesture(perform: skip)
            .opacity(reduceMotion && !isShown ? 0 : 1)
            // Always on black, as the duel's: dark's ink and panel either way.
            .environment(\.colorScheme, .dark)
            .position(
                x: stage.size.width / 2 - insets.leading,
                y: stage.size.height / 2 - insets.top
            )
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: hits)
        .sensoryFeedback(.impact(weight: .light), trigger: stamps)
        .onAppear { start = Date() }
        .task(id: isSkipped) { await play() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.announcement)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { skip() }
        .accessibilityIdentifier("competition.group.versus")
    }

    // MARK: Clock, as the duel's

    private var isHeld: Bool { CompetitionVersusIntroGate.holds && !isSkipped }

    private func sleep(until t: Double) async throws {
        try await Task.sleep(for: .seconds(max(t - Date().timeIntervalSince(start), 0)))
    }

    private func play() async {
        do {
            if isHeld {
                isShown = true
                try await Task.sleep(for: .seconds(3_600))
            }
            if reduceMotion {
                if !isSkipped {
                    withAnimation(Motion.fade) { isShown = true }
                    try await Task.sleep(for: .seconds(0.2))
                    stamps += 1
                    try await Task.sleep(for: .seconds(VersusClock.reducedHold))
                }
                withAnimation(Motion.fade) { isShown = false }
                try await Task.sleep(for: .seconds(0.2))
            } else {
                if !isSkipped {
                    try await sleep(until: VersusClock.contact)
                    hits += 1
                    try await sleep(until: VersusClock.stamp)
                    stamps += 1
                }
                try await sleep(until: VersusClock.end)
            }
            finished()
        } catch {
            // A skip restarted the clock, or the screen went away.
        }
    }

    private func skip() {
        guard isHeld || !isSkipped && Date().timeIntervalSince(start) < VersusClock.split else {
            return
        }
        start = Date().addingTimeInterval(-VersusClock.split)
        isSkipped = true
    }

    // MARK: Frames

    private func frame(_ stage: GroupVersusStage, at t: Double) -> some View {
        let words = VersusClock.ramp(t, VersusClock.tape, 0.2)
            * (1 - VersusClock.ramp(t, VersusClock.split, VersusClock.end - VersusClock.split))
        return ZStack {
            Color.black
            ForEach(Array(content.panels.enumerated()), id: \.offset) { index, people in
                panel(stage, index: index, people: people, at: t)
            }
            header(stage, at: t)
            footer(stage, at: t).opacity(words)
            Color.white.opacity(VersusClock.flash(t))
        }
        .scaleEffect(VersusClock.punch(t))
    }

    /// "EVERYONE'S IN" over the format, landing with the stamp.
    private func header(_ stage: GroupVersusStage, at t: Double) -> some View {
        let landed = VersusClock.slamCurve.value(at: VersusClock.ramp(t, VersusClock.stamp, 0.12))
        let leaving = VersusClock.ramp(t, VersusClock.split, VersusClock.end - VersusClock.split)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Everyone’s in")
                .font(.subheadline.weight(.heavy).width(.condensed))
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(Theme.secondary)
            Text(content.title.uppercased())
                .font(.score(size: stage.titleSize))
                .foregroundStyle(Theme.ink)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .frame(width: stage.size.width - 40, alignment: .leading)
        .scaleEffect(1.6 - 0.6 * landed, anchor: .leading)
        .opacity(landed * (1 - leaving))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: .infinity, alignment: .top)
        .offset(y: stage.headerTop)
    }

    /// The bar fills through the hold, then the day and the rule.
    private func footer(_ stage: GroupVersusStage, at t: Double) -> some View {
        let width = stage.size.width - 48
        let fill = VersusClock.ramp(t, VersusClock.tape, VersusClock.split - VersusClock.tape)
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .leading) {
                SlantedBar().fill(Theme.track)
                SlantedBar().fill(Theme.ink).frame(width: width * fill)
            }
            .frame(height: 10)
            Text(content.footer)
                .font(.subheadline.weight(.bold).width(.condensed))
                .tracking(0.4)
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: width)
        .padding(.top, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .offset(y: stage.footerTop)
    }

    /// One slanted panel. They slam up in turn and all land on contact, and
    /// part up and down alternately at the split.
    private func panel(_ stage: GroupVersusStage, index: Int, people: [GroupMatchVersusContent.Person], at t: Double) -> some View {
        let stagger = 0.05 * Double(index)
        let away = 1 - VersusClock.slamCurve.value(
            at: VersusClock.ramp(t, VersusClock.slam + stagger, VersusClock.contact - VersusClock.slam - stagger)
        )
        let open = VersusClock.openCurve.value(
            at: VersusClock.ramp(t, VersusClock.split, VersusClock.end - VersusClock.split)
        )
        let creep = VersusClock.ramp(t, VersusClock.contact, VersusClock.split - VersusClock.contact)
        let travel = stage.size.height
        let direction: CGFloat = index.isMultiple(of: 2) ? -1 : 1
        let width = stage.panelWidth + 2 * stage.lean
        let isYours = people.contains(where: \.isYou)
        let usesPhotos = content.panels.joined().contains { photos[$0.id] != nil }
        return ZStack(alignment: .topLeading) {
            isYours ? Theme.youFill : Theme.panel
            ForEach(Array(people.enumerated()), id: \.element.id) { slot, person in
                if usesPhotos {
                    photoSlot(stage, person: person, panel: index, slot: slot, of: people.count, width: width, at: t)
                } else {
                    letterSlot(stage, person: person, panel: index, slot: slot, width: width, at: t)
                }
            }
            .offset(y: -6 * creep)
        }
        .frame(width: width, height: stage.height)
        .clipShape(SkewedPanel(lean: stage.lean))
        .position(x: stage.midX(index), y: stage.top + stage.height / 2)
        .offset(
            x: away * travel * GroupVersusStage.skew,
            y: away * travel + direction * open * (stage.height + stage.top)
        )
    }

    /// Where the panel's centre line is at `y`, in its own frame.
    private func centre(_ stage: GroupVersusStage, width: CGFloat, y: CGFloat) -> CGFloat {
        width / 2 + (stage.height / 2 - y) * GroupVersusStage.skew
    }

    /// The giant initial (or a bot's ink square) and the name, stepped down
    /// panel by panel as in the mockup.
    private func letterSlot(
        _ stage: GroupVersusStage, person: GroupMatchVersusContent.Person,
        panel: Int, slot: Int, width: CGFloat, at t: Double
    ) -> some View {
        let isDoubles = content.panels.first?.count == 2
        let letter = 104 * stage.k
        let step = letter + 10 + labelLine + 24
        let first = stage.height * (isDoubles ? (panel == 0 ? 60 : 230) : 70 + 120 * CGFloat(panel)) / 600
        let height = letter + 10 + labelLine
        let middle = first + CGFloat(slot) * step + height / 2
        return VStack(spacing: 10) {
            mark(person, size: letter, letterSize: letter)
                .frame(height: letter)
            name(person, at: t)
        }
        .fixedSize()
        .position(x: centre(stage, width: width, y: middle), y: middle)
    }

    /// A photo filling its share of the panel, or the initial in its place.
    private func photoSlot(
        _ stage: GroupVersusStage, person: GroupMatchVersusContent.Person,
        panel: Int, slot: Int, of count: Int, width: CGFloat, at t: Double
    ) -> some View {
        let nameHeight = labelLine + 2 * (count == 2 ? 14 : 13)
        let box = stage.height / CGFloat(count) - nameHeight
        // The first free-for-all panel leans off the screen at the bottom
        // (and the last at the top), so its name goes over the photo.
        let nameFirst = count == 1 && panel == 0
        let slotTop = CGFloat(slot) * (box + nameHeight)
        let boxMiddle = slotTop + (nameFirst ? nameHeight : 0) + box / 2
        let nameMiddle = slotTop + (nameFirst ? 0 : box) + nameHeight / 2
        return ZStack {
            Group {
                if let photo = photos[person.id], !person.isBot {
                    let image = Image(uiImage: photo.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width * (count == 2 ? 1.5 : 2), height: box)
                        .clipped()
                        .grayscale(1)
                    if person.isYou {
                        // Multiplied into amber: amber still means you.
                        image.contrast(1.15).blendMode(.multiply)
                    } else {
                        image.opacity(0.55)
                    }
                } else {
                    mark(
                        person, size: min(box * 0.6, width),
                        letterSize: min((count == 2 ? 200 : 240) * stage.k, box * 0.9)
                    )
                }
            }
            .frame(width: width, height: box)
            .clipped()
            .position(x: centre(stage, width: width, y: boxMiddle), y: boxMiddle)
            name(person, at: t)
                .position(x: centre(stage, width: width, y: nameMiddle), y: nameMiddle)
        }
    }

    /// The giant initial, or for a bot an ink square: a bot never wears amber.
    @ViewBuilder
    private func mark(_ person: GroupMatchVersusContent.Person, size: CGFloat, letterSize: CGFloat) -> some View {
        let initial = String(person.name.prefix(1)).uppercased()
        if person.isBot {
            Text(initial)
                .font(.score(size: size * 0.6))
                .foregroundStyle(Theme.onInk)
                .frame(width: size, height: size)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        } else {
            Text(initial)
                .font(.score(size: letterSize))
                .foregroundStyle(person.isYou ? Theme.onYouFill : Theme.ink)
                .fixedSize()
        }
    }

    private func name(_ person: GroupMatchVersusContent.Person, at t: Double) -> some View {
        let landing = Spring(duration: 0.32, bounce: 0).value(target: 1.0, time: max(t - VersusClock.names, 0))
        return Text(person.name)
            .font(.subheadline.weight(.heavy).width(.condensed))
            .tracking(1.2)
            .textCase(.uppercase)
            .lineLimit(1)
            .foregroundStyle(person.isYou ? Theme.onYouFill : Theme.ink)
            .opacity(t < VersusClock.names ? 0 : landing)
    }
}

private struct GroupMatchReplayIntroKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// Replay Intro in a group match's ••• menu; nil hides it.
    var groupMatchReplayIntro: (() -> Void)? {
        get { self[GroupMatchReplayIntroKey.self] }
        set { self[GroupMatchReplayIntroKey.self] = newValue }
    }
}
