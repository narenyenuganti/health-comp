import CompetitionCore
import SwiftUI

// The reveal's clock (hold, cards, stamp, lights, raise, close-up) is an
// editorial exception to "numbers live in Motion.swift", like the versus intro.

/// Test Lab launches run without the reveal, so its tests stay untouched,
/// unless `--judges-decision` asks for it.
let competitionJudgesAreOn: Bool = {
    #if DEBUG
    let arguments = ProcessInfo.processInfo.arguments
    if arguments.contains(where: { $0.hasSuffix("-competition-test-lab") }) {
        return arguments.contains("--judges-decision")
    }
    #endif
    return true
}()

// MARK: What the reveal draws

/// The judges' reveal for any format: every fighter, the side each one scores
/// for, and the result's places. Cards describe the week; places decide it.
struct CompetitionJudgesBout: Equatable {
    struct Fighter: Equatable {
        let name: String
        var photo: UUID? = nil
        var isYou = false
        var isBot = false
        let side: Int
    }

    struct Side: Equatable {
        /// "YOU", "SAM" or "YOU + PRIYA".
        let label: String
        let isYours: Bool
        let place: Int
        let total: Double
        /// Move, Exercise, Stand: seven rounds each, nil without a breakdown.
        let cards: [[Double?]]

        func cardTotal(_ ring: Int) -> Double? {
            guard cards.indices.contains(ring), cards[ring].count == 7, cards[ring].allSatisfy({ $0 != nil })
            else { return nil }
            // Whole centipoints, so two equal cards compare equal.
            return (cards[ring].compactMap { $0 }.reduce(0, +) * 100).rounded() / 100
        }
    }

    enum Format: Equatable { case duel, freeForAll, doubles }

    let format: Format
    /// You first; in doubles your partner second.
    let fighters: [Fighter]
    let sides: [Side]
    let dayLabels: [String]
    let label: String

    var winners: [Int] { sides.indices.filter { sides[$0].place == 1 } }
    var isDraw: Bool { winners.count != 1 }
    var yoursWon: Bool { !isDraw && sides[winners[0]].isYours }

    var title: String {
        guard !isDraw, let winner = winners.first else { return "IT’S A DRAW" }
        let names = fighters.filter { $0.side == winner }.map { $0.name.uppercased() }
        let word = names.count > 1 ? "WINNERS" : "WINNER"
        return sides[winner].isYours ? "YOUR \(word)" : "THE \(word), \(names.joined(separator: " & "))"
    }

    var heading: String { sides.map(\.label).joined(separator: " VS ") + " · FINAL BELL" }
}

/// One rule for every format: unanimous when the winner tops all three cards
/// alone, majority or split at two, otherwise total points.
func competitionJudgesVerdict(winner: [Double], rest: [[Double]]) -> String {
    var wins = 0, even = 0
    for ring in 0..<3 {
        let best = rest.map { $0[ring] }.max() ?? -.infinity
        if winner[ring] > best + 0.001 { wins += 1 } else if winner[ring] > best - 0.001 { even += 1 }
    }
    if wins == 3 { return "UNANIMOUS DECISION" }
    if wins == 2 { return even == 1 ? "MAJORITY DECISION" : "SPLIT DECISION" }
    return "BY TOTAL POINTS"
}

extension CompetitionJudgesBout {
    init(_ competition: LocalCompetitionPresentation) {
        let decision = competitionJudgesDecision(
            days: competition.days, you: competition.userPoints, them: competition.opponentPoints
        )
        let days = competition.days.sorted { $0.ordinal < $1.ordinal }
        self.init(
            format: .duel,
            fighters: [
                Fighter(name: competition.ownerDisplayName, isYou: true, side: 0),
                Fighter(name: competition.opponentDisplayName, photo: competition.opponentProfileID, side: 1),
            ],
            sides: [
                Side(label: "YOU", isYours: true, place: decision.outcome == .loss ? 2 : 1,
                     total: competition.userPoints, cards: decision.cards.map(\.you)),
                Side(label: competition.opponentDisplayName.uppercased(), isYours: false,
                     place: decision.outcome == .win ? 2 : 1,
                     total: competition.opponentPoints, cards: decision.cards.map(\.them)),
            ],
            dayLabels: (0..<7).map { days.indices.contains($0) ? String(weekdayName(days[$0].day).prefix(3)) : "\($0 + 1)" },
            label: decision.label
        )
    }

    /// Nil until the server's result is in.
    init?(_ match: GroupMatchPresentation) {
        guard let rows = match.frozenStandings else { return nil }
        let isDoubles = match.format == .doubles
        let viewerTeam = match.viewer.team
        func rank(_ seat: GroupMatchSeat) -> Int {
            seat.id == match.viewerSeatID ? 0 : isDoubles && seat.team == viewerTeam ? 1 : seat.number + 1
        }
        let seats = match.seats.sorted { rank($0) < rank($1) }
        func subject(_ seat: GroupMatchSeat) -> MatchStandingSubject {
            isDoubles ? .team(seat.team ?? 0) : .seat(seat.id)
        }
        var subjects: [MatchStandingSubject] = []
        for seat in seats where !subjects.contains(subject(seat)) { subjects.append(subject(seat)) }
        func members(_ of: MatchStandingSubject) -> [GroupMatchSeat] {
            seats.filter { subject($0) == of }
        }
        func points(_ side: MatchStandingSubject, ring: Int, ordinal: Int) -> Double? {
            var sum = 0
            for seat in members(side) {
                // Days after a player left score nothing.
                if let cutoff = match.configuration.leaveCutoffs[seat.id], ordinal > cutoff { continue }
                guard let rings = match.rings.first(where: { $0.seatID == seat.id && $0.ordinal == ordinal }),
                      rings.centipoints.count == 3 else { return nil }
                sum += rings.centipoints[ring]
            }
            return Double(sum) / 100
        }
        var sides: [Side] = []
        for side in subjects {
            guard let row = rows.first(where: { $0.subject == side }) else { return nil }
            sides.append(Side(
                label: match.name(of: side).uppercased(),
                isYours: side == match.viewerSubject,
                place: row.place,
                total: Double(row.centipoints) / 100,
                cards: (0..<3).map { ring in (1...7).map { points(side, ring: ring, ordinal: $0) } }
            ))
        }
        let days = match.calendarDays
        self.init(
            format: isDoubles ? .doubles : .freeForAll,
            fighters: seats.map { seat in
                Fighter(
                    name: seat.name, photo: seat.profileID, isYou: seat.id == match.viewerSeatID, isBot: seat.isBot,
                    side: subjects.firstIndex(of: subject(seat)) ?? 0
                )
            },
            sides: sides,
            dayLabels: (0..<7).map { days.indices.contains($0) ? String(weekdayName(days[$0]).prefix(3)) : "\($0 + 1)" },
            label: Self.label(sides)
        )
    }

    static func label(_ sides: [Side]) -> String {
        let first = sides.indices.filter { sides[$0].place == 1 }
        guard first.count == 1, let winner = first.first else { return "DRAW" }
        let totals = sides.map { side in (0..<3).compactMap { side.cardTotal($0) } }
        for (side, cards) in zip(sides, totals) {
            guard cards.count == 3, abs(cards.reduce(0, +) - side.total) < 0.001 else { return "BY TOTAL POINTS" }
        }
        var rest = totals
        rest.remove(at: winner)
        return competitionJudgesVerdict(winner: totals[winner], rest: rest)
    }
}

// MARK: Where everyone stands

struct CompetitionJudgesStance: Equatable {
    /// Where they wait, then where they stand for the raise.
    var lineupX: CGFloat
    var lineupScale: CGFloat
    var x: CGFloat
    var scale: CGFloat
    /// 1 on the left, facing right.
    var facing: CGFloat
    /// A doubles partner, behind the one the referee holds.
    var isOuter = false
    /// The referee has their wrist.
    var isHeld = false
    /// Their light is cut before the raise.
    var isOut = false
    var won = false
    var place = 1
}

/// Seconds from when the ring appears.
struct CompetitionJudgesRingClock: Equatable {
    /// When each cut place loses its light, last place first.
    var cuts: [Int: Double] = [:]
    /// When the last two walk to the referee.
    var walk: Double?
    var raise = 1.0
    var hasReferee = true
    var focus: Double { raise + 1.25 }
    var end: Double { focus + 1.5 }
}

extension CompetitionJudgesBout {
    /// A duel and doubles are the shipped raise. A free-for-all cuts the
    /// lights from last place up until two stand, then is the same raise.
    /// When a tie means no cut leaves two, it cuts until only the winners stand.
    var ring: (stances: [CompetitionJudgesStance], clock: CompetitionJudgesRingClock) {
        let lineup: [(CGFloat, CGFloat)] = switch format {
        case .duel: [(72, 1), (288, 1)]
        case .doubles: [(100, 0.9), (48, 0.8), (260, 0.9), (312, 0.8)]
        case .freeForAll: fighters.count == 3
            ? [(62, 0.84), (180, 0.84), (298, 0.84)]
            : [(46, 0.76), (135, 0.76), (225, 0.76), (314, 0.76)]
        }
        var clock = CompetitionJudgesRingClock()
        var stances = fighters.enumerated().map { index, fighter in
            let spot = lineup[min(index, lineup.count - 1)]
            let isOuter = format == .doubles && index % 2 == 1
            let place = sides[fighter.side].place
            return CompetitionJudgesStance(
                lineupX: spot.0, lineupScale: spot.1, x: spot.0, scale: spot.1,
                facing: spot.0 <= 180 ? 1 : -1, isOuter: isOuter,
                isHeld: format != .freeForAll && !isOuter, won: place == 1, place: place
            )
        }
        guard format == .freeForAll else { return (stances, clock) }
        let keep = stances.filter { $0.place < 3 }.count == 2 ? 2 : 1
        for (step, place) in Set(stances.map(\.place)).filter({ $0 > keep }).sorted(by: >).enumerated() {
            clock.cuts[place] = 0.8 + 0.7 * Double(step)
        }
        let lastCut = clock.cuts.values.max() ?? 0
        let standing = stances.indices.filter { stances[$0].place <= keep }
        for index in stances.indices where stances[index].place > keep { stances[index].isOut = true }
        if keep == 2 {
            clock.walk = lastCut + 0.7
            clock.raise = lastCut + 1.9
            for (corner, index) in standing.enumerated() {
                stances[index].x = corner == 0 ? 72 : 288
                stances[index].scale = 1
                stances[index].facing = corner == 0 ? 1 : -1
                stances[index].isHeld = true
            }
        } else {
            // Only the winners stand, one or several: no referee, and each
            // raises their own arms.
            clock.hasReferee = false
            clock.raise = lastCut + 1
        }
        return (stances, clock)
    }
}

// MARK: The reveal

/// The reveal's editorial clock: a 0.9 s hold, three 1.2 s cards, stamp,
/// one held beat and the raise. Animation curves still belong to Motion.
struct CompetitionJudgesReveal: View {
    let bout: CompetitionJudgesBout
    let onFinished: () -> Void
    let onSkip: () -> Void
    let onBackground: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    @State private var stage = 0
    @State private var pressing = false
    @State private var breakingSeal = false
    @State private var progress = 0.0
    @State private var tapOpens = false
    @State private var cardIndex = 0
    @State private var rows = 0
    @State private var stamped = false
    @State private var inked = false
    @State private var raised = false
    @State private var focused = false
    @State private var ringStart = Date.distantPast
    @State private var ticks = 0
    @State private var thuds = 0

    private var isWide: Bool { bout.sides.count > 2 }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("HEALTHCOMP /").foregroundStyle(Theme.ink)
                Spacer()
                Text("7 ROUNDS").foregroundStyle(Theme.secondary)
            }
            .font(.themeLabel).tracking(1.3)
            GeometryReader { geometry in
                ScrollView {
                    ZStack {
                        if stage == 0 { seal.transition(.opacity) }
                        if stage == 1 { scorecards.transition(.opacity) }
                        if stage == 2 { handRaise.transition(.opacity) }
                    }
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollIndicators(.hidden)
            }
            Button(action: skip) {
                Text("Skip reveal")
                    .font(.themeLabel)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("competition.judges.skip")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture { if stage > 0 || !breakingSeal { skip() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.judges.reveal")
        .sensoryFeedback(.impact(weight: .light), trigger: ticks)
        .sensoryFeedback(.impact(weight: .heavy), trigger: thuds)
        .task {
            guard (try? await Task.sleep(for: .seconds(3))) != nil else { return }
            tapOpens = true
        }
        .task(id: pressing) {
            guard pressing else { progress = breakingSeal ? 1 : 0; return }
            for tick in 1...9 {
                guard (try? await Task.sleep(for: .seconds(0.1))) != nil, pressing else { return }
                progress = Double(tick) / 9
                if tick % 3 == 0 { ticks += 1 }
            }
        }
        .task(id: breakingSeal) {
            guard breakingSeal else { return }
            guard (try? await Task.sleep(for: .seconds(0.3))) != nil else { return }
            withAnimation(Motion.fade) { stage = 1 }
        }
        .task(id: stage) {
            guard stage == 1 else { return }
            for card in 0..<3 {
                cardIndex = card
                rows = reduceMotion ? 7 : 0
                for row in 1...7 {
                    guard (try? await Task.sleep(for: .seconds(0.1))) != nil else { return }
                    if !reduceMotion { rows = row }
                }
                // On the pen's circle, just after the totals show.
                if bout.sides.allSatisfy({ $0.cardTotal(card) != nil }) { Sounds.play(.total, in: 0.2) }
                guard (try? await Task.sleep(for: .seconds(0.5))) != nil else { return }
            }
            // The stamp slams on the versus intro's curve.
            withAnimation(reduceMotion ? Motion.fade : .timingCurve(VersusClock.slamCurve, duration: VersusClock.slam)) {
                stamped = true
            }
            thuds += 1
            Sounds.play(.stamp, in: reduceMotion ? 0 : VersusClock.slam)
            guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            ringStart = .now
            Sounds.play(.clear)
            withAnimation(Motion.fade) { stage = 2 }
        }
        .task(id: stage == 2) {
            guard stage == 2 else { return }
            let clock = bout.ring.clock
            if bout.yoursWon { Sounds.play(.cheer, in: reduceMotion ? 0 : clock.raise) }
            if !reduceMotion {
                // One thud for each light that cuts, then the raise.
                var now = 0.0
                for beat in clock.cuts.values.sorted() + [clock.raise] {
                    guard (try? await Task.sleep(for: .seconds(beat - now))) != nil else { return }
                    now = beat
                    thuds += 1
                }
            }
            raised = true
            // Let the raise settle and hold before the personal close-up.
            guard (try? await Task.sleep(for: .seconds(reduceMotion ? 0.8 : 1.25))) != nil else { return }
            focused = true
            guard (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
            onFinished()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                Sounds.stop()
                onBackground()
            }
        }
    }

    private var seal: some View {
        let size: CGFloat = bout.fighters.count > 3 ? 52 : bout.fighters.count > 2 ? 60 : 72
        let spread: CGFloat = breakingSeal && !reduceMotion ? 32 : 0
        let hot = Color(red: 1, green: 0.93, blue: 0.75)
        return VStack(alignment: .leading, spacing: 24) {
            Text(bout.heading)
                .font(.themeLabel).foregroundStyle(Theme.secondary)
            Text("The decision.\nUnder seal.")
                .font(.score(size: 52)).foregroundStyle(Theme.ink)
                .minimumScaleFactor(0.6)
            Text("After seven rounds…\nwe go to the judges’ scorecards.")
                .foregroundStyle(Theme.secondary)
            VStack(spacing: 28) {
                Text("OFFICIAL SCORECARDS").font(.themeLabel).tracking(2)
                    .foregroundStyle(Theme.secondary)
                    .environment(\.colorScheme, .dark)
                ZStack {
                    RoundedRectangle(cornerRadius: 8).stroke(Theme.faint.opacity(0.5), lineWidth: 1)
                        .frame(height: 150).rotationEffect(.degrees(-4))
                    SlantedBar().fill(Theme.faint.opacity(0.2)).frame(width: 2, height: 145)
                        .rotationEffect(.degrees(12))
                    // Your side left of the cut, everyone else right of it.
                    HStack(spacing: -14) {
                        avatars(bout.fighters.filter { bout.sides[$0.side].isYours }, size: size)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .offset(x: -spread, y: -6)
                        avatars(bout.fighters.filter { !bout.sides[$0.side].isYours }, size: size)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .offset(x: spread, y: 6)
                    }
                    .moving(Motion.grow, value: breakingSeal)
                    // The cut lights as the seal breaks.
                    Rectangle().fill(breakingSeal ? hot : Theme.beltWell)
                        .frame(width: breakingSeal ? 8 : 3, height: breakingSeal ? 160 : 140)
                        .shadow(color: hot.opacity(breakingSeal ? 0.6 : 0), radius: 11)
                        .rotationEffect(.degrees(12))
                    Circle().trim(from: 0, to: progress).stroke(Theme.youFill, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 156, height: 156).rotationEffect(.degrees(-90))
                        .shadow(color: Theme.youFill.opacity(0.7), radius: 4)
                        .opacity(progress > 0 ? 1 : 0)
                        .animation(reduceMotion ? nil : Motion.press, value: progress)
                }
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.9, maximumDistance: 60, pressing: { pressing = $0 }, perform: open)
                .onTapGesture { if tapOpens || voiceOver { open() } }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Hold to open")
                .accessibilityHint("Opens the judges’ decision")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, open)
                .accessibilityIdentifier("competition.judges.seal")
                Text("THREE RINGS. THREE JUDGES.").font(.themeLabel).tracking(1.5)
                    .foregroundStyle(Theme.secondary)
                    .environment(\.colorScheme, .dark)
            }
            .padding(28).background(Theme.beltWell, in: RoundedRectangle(cornerRadius: 20))
            Text(tapOpens ? "Hold or tap to open" : "Hold to open")
                .font(.themeLabel).frame(maxWidth: .infinity).foregroundStyle(Theme.ink)
        }
    }

    private func open() {
        guard stage == 0, !breakingSeal else { return }
        progress = 1
        withAnimation(Motion.fade) { breakingSeal = true }
        // On the cut to the scorecards.
        Sounds.play(.final, in: 0.3)
    }

    private func skip() {
        Sounds.stop()
        onSkip()
    }

    private var scorecards: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Every round.\nOn the record.").font(.score(size: 46)).foregroundStyle(Theme.ink)
            HStack {
                Text("Three rings. Three judges.")
                Spacer()
                Text("0\(cardIndex + 1) / 03").monospacedDigit()
            }.font(.themeLabel).foregroundStyle(Theme.secondary)
            ZStack {
                card(cardIndex).id(cardIndex).transition(.opacity)
            }
            .animation(Motion.fade, value: cardIndex)
            ZStack {
                if stamped {
                    stamp
                } else {
                    HStack {
                        ForEach(0..<3) { index in
                            Text(["MOVE", "EXERCISE", "STAND"][index])
                                .foregroundStyle(index <= cardIndex ? Theme.ink : Theme.faint)
                            if index < 2 { Spacer() }
                        }
                    }.font(.themeLabel)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 60)
        }
    }

    /// Lands a little crooked, with a ring of ink that spreads and fades.
    private var stamp: some View {
        Text(bout.label)
            .font(.score(size: 30)).minimumScaleFactor(0.5).lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(Theme.ink)
            .overlay(Rectangle().stroke(Theme.ink, lineWidth: 3))
            .padding(4)
            .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1))
            .overlay {
                if !reduceMotion {
                    Rectangle().stroke(Theme.ink, lineWidth: 2)
                        .scaleEffect(x: inked ? 1.16 : 1, y: inked ? 1.4 : 1)
                        .opacity(inked ? 0 : 0.45)
                        .animation(Motion.fade.delay(VersusClock.slam), value: inked)
                }
            }
            .rotationEffect(.degrees(-5))
            .onAppear { inked = true }
            .transition(reduceMotion ? .opacity : .scale(scale: 1.7).combined(with: .opacity))
            .accessibilityIdentifier("competition.judges.stamp")
    }

    private func card(_ index: Int) -> some View {
        let totals = bout.sides.map { $0.cardTotal(index) }
        return VStack(spacing: 6) {
            HStack {
                Circle().fill([Theme.move, Theme.exercise, Theme.stand][index]).frame(width: 10, height: 10)
                Text("Judge \(["Move", "Exercise", "Stand"][index])").font(.themeLabel)
                Spacer()
                Text("OFFICIAL").font(.themeLabel).foregroundStyle(Theme.secondary)
            }
            if totals.contains(nil) {
                Text("Ring breakdown unavailable").font(.footnote).foregroundStyle(Theme.secondary)
            }
            Divider()
            HStack {
                lead(Text("ROUND"))
                ForEach(bout.sides.indices, id: \.self) { side in
                    VStack(spacing: 4) {
                        avatars(bout.fighters.filter { $0.side == side }, size: 24, overlap: -8)
                        Text(bout.sides[side].label)
                            .foregroundStyle(bout.sides[side].isYours ? Theme.you : Theme.ink)
                    }.frame(maxWidth: .infinity)
                }
            }.font(.themeLabel).lineLimit(1).minimumScaleFactor(0.5)
            ForEach(0..<7) { row in
                HStack {
                    lead(Text(bout.dayLabels[row]).font(.themeLabel).foregroundStyle(Theme.secondary))
                    ForEach(bout.sides.indices, id: \.self) { side in
                        // Each round ticks in with a short rise.
                        ZStack {
                            Text("—").opacity(row < rows ? 0 : 1).transaction { $0.animation = nil }
                            Text(score(bout.sides[side].cards[index], row))
                                .opacity(row < rows ? 1 : 0)
                                .offset(y: row < rows || reduceMotion ? 0 : 7)
                        }
                        .foregroundStyle(bout.sides[side].isYours ? Theme.you : Theme.ink)
                        .frame(maxWidth: .infinity)
                    }
                }
                .font(.score(size: 24).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
                .animation(reduceMotion ? nil : Motion.press, value: rows)
            }
            Divider()
            HStack {
                lead(Text("TOTAL").font(.themeLabel))
                ForEach(bout.sides.indices, id: \.self) { side in
                    let others = totals.indices.filter { $0 != side }.map { totals[$0] ?? .infinity }
                    total(totals[side], wins: (totals[side] ?? -1) > (others.max() ?? .infinity),
                          own: bout.sides[side].isYours)
                }
            }.opacity(rows == 7 ? 1 : 0)
        }
        .foregroundStyle(Theme.ink).padding(20)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    /// The row's label; narrow once there are more than two columns of points.
    private func lead(_ text: Text) -> some View {
        text.frame(maxWidth: isWide ? 44 : .infinity, alignment: .leading)
    }

    /// The winning total is circled by pen once the card is full.
    private func total(_ value: Double?, wins: Bool, own: Bool) -> some View {
        Text(value.map { competitionPointsText($0) } ?? "—")
            .font(.score(size: isWide ? 24 : 27)).lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(own ? Theme.you : Theme.ink)
            .padding(.vertical, 8).frame(maxWidth: .infinity)
            .overlay {
                if wins {
                    CompetitionJudgesPenCircle().trim(from: 0, to: rows == 7 ? 1 : 0)
                        .stroke(own ? Theme.youFill : Theme.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .animation(reduceMotion ? nil : Motion.fade.delay(0.1), value: rows == 7)
                }
            }
    }

    private func score(_ values: [Double?], _ row: Int) -> String {
        values.indices.contains(row) ? values[row].map { competitionPointsText($0) } ?? "—" : "—"
    }

    private func avatars(_ fighters: [CompetitionJudgesBout.Fighter], size: CGFloat, overlap: CGFloat = -14) -> some View {
        HStack(spacing: overlap) {
            ForEach(Array(fighters.enumerated()), id: \.offset) { _, fighter in
                PersonAvatar(
                    name: fighter.name, photo: fighter.photo, size: size,
                    isYou: fighter.isYou, isBot: fighter.isBot,
                    initialFont: .score(size: size * 0.5)
                )
            }
        }
    }

    private var handRaise: some View {
        let clock = bout.ring.clock
        return VStack(spacing: 20) {
            Text(raised ? bout.title : "THE DECISION…")
                .font(.score(size: 44)).multilineTextAlignment(.center)
                .foregroundStyle(raised && bout.yoursWon ? Theme.you : Theme.ink)
                .minimumScaleFactor(0.5).lineLimit(2)
                .accessibilityIdentifier("competition.judges.winner")
            Text(bout.label).font(.themeLabel).tracking(2).foregroundStyle(Theme.secondary)
            CompetitionJudgesRing(
                bout: bout,
                start: ringStart,
                still: reduceMotion ? (focused ? clock.focus + 1 : clock.focus) : nil
            )
            .id(reduceMotion && focused)
            .transition(.opacity)
            .animation(Motion.fade, value: focused)
            .frame(height: 310)
            .background(Theme.beltWell)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .accessibilityHidden(true)
            HStack(alignment: .bottom) {
                ForEach(bout.sides.indices, id: \.self) { index in
                    let side = bout.sides[index]
                    if index > 0 {
                        Spacer(minLength: 4)
                        if !isWide {
                            Text("—").foregroundStyle(Theme.secondary)
                            Spacer(minLength: 4)
                        }
                    }
                    VStack {
                        Text(side.label).font(.themeLabel).lineLimit(1).minimumScaleFactor(0.5)
                        Text(competitionPointsText(side.total)).font(.score(size: isWide ? 32 : 42))
                    }
                    .foregroundStyle(side.isYours ? Theme.you : Theme.ink)
                }
            }
            Text("The combined ring points decide the match.").font(.footnote).foregroundStyle(Theme.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(focused ? "competition.judges.payoff" : "competition.judges.stage")
    }
}

/// A loop of pen, not a clean ellipse: it starts inside and overshoots its start.
private struct CompetitionJudgesPenCircle: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x / 100, y: rect.minY + rect.height * y / 44)
        }
        var path = Path()
        path.move(to: point(14, 12))
        path.addCurve(to: point(95, 22), control1: point(40, -2), control2: point(92, 4))
        path.addCurve(to: point(22, 40), control1: point(97, 40), control2: point(50, 46))
        path.addCurve(to: point(30, 6), control1: point(-2, 34), control2: point(0, 12))
        return path
    }
}

// MARK: Group matches

extension View {
    /// The judges' reveal over a finished group match, once, on the first
    /// visit. A group match never moves a belt, so nothing follows it.
    func competitionGroupJudges(_ match: GroupMatchPresentation) -> some View {
        modifier(CompetitionGroupJudges(match: match))
    }
}

private struct CompetitionGroupJudges: ViewModifier {
    let match: GroupMatchPresentation
    @AppStorage(CompetitionMotionSeen.storageKey) private var seen = CompetitionMotionSeen()
    @State private var didStart = false
    @State private var isShowing = false
    /// Held from the start, so a refresh mid-reveal cannot change or empty it.
    @State private var playing: CompetitionJudgesBout?

    private var bout: CompetitionJudgesBout? {
        guard competitionJudgesAreOn, case .completed = match.lifecycle, !seen.hasSeen(.judges, match.id)
        else { return nil }
        return CompetitionJudgesBout(match)
    }

    func body(content: Content) -> some View {
        content
            // Nothing of the result shows before the reveal covers it.
            .overlay { if isShowing || (!didStart && bout != nil) { Theme.ground.ignoresSafeArea() } }
            .fullScreenCover(isPresented: $isShowing) {
                if let playing {
                    CompetitionJudgesReveal(bout: playing, onFinished: finish, onSkip: finish, onBackground: finish)
                        .presentationBackground(Theme.ground)
                }
            }
            .onAppear {
                guard !didStart else { return }
                didStart = true
                playing = bout
                if playing != nil { present(true) }
            }
    }

    private func finish() {
        seen = seen.marking(.judges, match.id)
        present(false)
    }

    private func present(_ shown: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isShowing = shown }
    }
}

// MARK: The ring

/// Two fixed-length arm segments: the shoulder rotates first, then the
/// elbow straightens late. The referee holds this exact wrist endpoint.
/// `dip` is the beat before the raise; a `loose` arm hangs straight.
func competitionJudgeArm(
    shoulder: CGPoint, inward: CGFloat, raised: Double, dip: Double = 0, loose: Double = 0
) -> (elbow: CGPoint, wrist: CGPoint) {
    let progress = min(1.08, max(0, raised))
    let upper = 0.2 + 2.6 * progress - 0.12 * dip - 0.1 * loose
    let forearm = upper + 0.75 * (1 - progress * progress) * (1 - loose) - 0.1 * loose
    let elbow = CGPoint(
        x: shoulder.x + inward * CGFloat(sin(upper)) * 35,
        y: shoulder.y + CGFloat(cos(upper)) * 35
    )
    let wrist = CGPoint(
        x: elbow.x + inward * CGFloat(sin(forearm)) * 35,
        y: elbow.y + CGFloat(cos(forearm)) * 35
    )
    return (elbow, wrist)
}

/// The fighters, the referee and the ring, drawn in code from one clock:
/// original athletic figures with no image assets, lit from above. The
/// profile photos are the heads. Reduce Motion holds one `still` moment.
private struct CompetitionJudgesRing: View {
    let bout: CompetitionJudgesBout
    let start: Date
    let still: Double?

    var body: some View {
        let ring = bout.ring
        return TimelineView(.animation(minimumInterval: 1 / 60, paused: still != nil)) { timeline in
            let time = still ?? timeline.date.timeIntervalSince(start)
            let frame = JudgesRing.frame(bout: bout, stances: ring.stances, clock: ring.clock, time: CGFloat(time))
            let focus = CGFloat(Motion.growCurve.value(at: Double(JudgesRing.ramp(CGFloat(time), CGFloat(ring.clock.focus), 0.45))))
            let winners = frame.figures.filter(\.stance.won).map(\.index)
            GeometryReader { geometry in
                ZStack {
                    Canvas { context, size in
                        context.scaleBy(x: size.width / 360, y: size.height / 340)
                        JudgesRing.draw(frame, in: context)
                    }
                    .opacity(Double(1 - min(1, focus)))
                    RadialGradient(colors: [Theme.secondary.opacity(0.18), Theme.secondary.opacity(0)],
                                   center: .center, startRadius: 20, endRadius: 180)
                        .opacity(Double(min(1, focus)))
                    ForEach(frame.figures, id: \.index) { figure in
                        head(figure, focus: focus, winners: winners, size: geometry.size)
                    }
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private func head(_ figure: JudgesRing.Figure, focus: CGFloat, winners: [Int], size: CGSize) -> some View {
        let fighter = bout.fighters[figure.index]
        let isYours = bout.sides[fighter.side].isYours
        let slot = winners.firstIndex(of: figure.index)
        let zoom = slot == nil ? 0 : focus
        let count = min(max(winners.count, 1), 4)
        let big: CGFloat = [120, 104, 84, 68][count - 1]
        let spacing: CGFloat = [0, 140, 105, 84][count - 1]
        let targetX = 180 + (CGFloat(slot ?? 0) - CGFloat(count - 1) / 2) * spacing
        let base = 44 * figure.scale
        let diameter = max(1, base + (big - base) * zoom)
        return PersonAvatar(name: fighter.name, photo: fighter.photo, size: diameter, isYou: fighter.isYou,
                            isBot: fighter.isBot, initialFont: .score(size: diameter * 0.5))
            .overlay(Circle().stroke(isYours ? Theme.youFill : Theme.ink.opacity(0.2), lineWidth: isYours ? 2 : 1))
            .overlay(Circle().fill(Theme.beltWell.opacity(0.75 * Double(1 - figure.lit))))
            .overlay(alignment: .bottom) {
                Text(fighter.isYou ? "YOU" : fighter.name.uppercased())
                    .font(.themeLabel).tracking(1.5).foregroundStyle(isYours ? Theme.youFill : Theme.ink)
                    .fixedSize().offset(y: 28).opacity(slot == nil ? 0 : Double(min(1, focus)))
            }
            .opacity(Double(figure.alpha) * (slot == nil ? 1 - Double(min(1, focus)) : 1))
            .position(x: (figure.head.x + (targetX - figure.head.x) * zoom) * size.width / 360,
                      y: (figure.head.y + (165 - figure.head.y) * zoom) * size.height / 340)
    }
}

/// The ring's drawing, in the shipped 360 x 340 space with the floor at 316.
private enum JudgesRing {
    static let floor: CGFloat = 316
    static let refereeTone = Color(red: 150 / 255, green: 150 / 255, blue: 156 / 255)
    /// You, then everyone else from near to far. Opaque, so limbs overlap cleanly.
    static let tones: [Color] = [
        Theme.youFill, Theme.secondary,
        Color(red: 134 / 255, green: 134 / 255, blue: 142 / 255),
        Color(red: 116 / 255, green: 116 / 255, blue: 124 / 255),
    ]
    static let partnerTone = Color(red: 216 / 255, green: 143 / 255, blue: 0)
    static let paper = Color(red: 245 / 255, green: 245 / 255, blue: 240 / 255)

    struct Pose {
        var facing: CGFloat
        var shoulderY: CGFloat
        var lean: CGFloat
        var waistY: CGFloat
        var hipX: CGFloat
        var shoulderIn: CGPoint
        var shoulderOut: CGPoint
        var elbowIn: CGPoint
        var wristIn: CGPoint
        var elbowOut: CGPoint
        var wristOut: CGPoint
        var hipIn: CGPoint
        var hipOut: CGPoint
        var kneeIn: CGPoint
        var kneeOut: CGPoint
        var ankleIn: CGPoint
        var ankleOut: CGPoint
        var toeIn: CGPoint
        var toeOut: CGPoint
        var head: CGPoint
    }

    struct Figure {
        var index: Int
        var stance: CompetitionJudgesStance
        var x: CGFloat
        var scale: CGFloat
        var pose: Pose
        var tone: Color
        var lit: CGFloat
        var alpha: CGFloat
        var rise: CGFloat
        var wrist: CGPoint
        var head: CGPoint
    }

    struct Arm {
        var shoulder: CGPoint
        var elbow: CGPoint
        var wrist: CGPoint
    }

    struct Cone {
        var top: CGFloat
        var bottom: CGFloat
        var width: CGFloat
        var alpha: CGFloat
        var amber: CGFloat
    }

    struct Frame {
        var time: CGFloat
        var figures: [Figure]
        var refereeX: CGFloat
        var refereeDip: CGFloat
        var refereeLook: CGFloat
        var refereeAlpha: CGFloat
        var arms: [Arm]
        var cones: [Cone]
        var flashes: [(point: CGPoint, glow: CGFloat)]
        var tags: [(x: CGFloat, text: String, alpha: CGFloat)]
        var lightX: CGFloat
        var haze: CGFloat
    }

    // MARK: Motion

    static func clamp(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
    static func ramp(_ t: CGFloat, _ start: CGFloat, _ length: CGFloat) -> CGFloat { clamp((t - start) / length) }
    static func smooth(_ x: CGFloat) -> CGFloat { let x = clamp(x); return x * x * (3 - 2 * x) }
    static func mix(_ a: CGFloat, _ b: CGFloat, _ k: CGFloat) -> CGFloat { a + (b - a) * k }
    /// The same scatter every time: nothing here may differ between frames.
    static func noise(_ index: Int) -> CGFloat {
        let x = sin(CGFloat(index) * 127.1 + 311.7) * 43758.5453
        return x - x.rounded(.down)
    }
    /// The raise overshoots and settles; the referee's arm follows it.
    static func spring(_ x: CGFloat) -> CGFloat { x <= 0 ? 0 : 1 - exp(-8 * x) * cos(13 * x) }
    /// A light that flickers twice and dies to a glow.
    static func cut(_ t: CGFloat) -> CGFloat {
        t < 0 ? 1 : t < 0.05 ? 0.35 : t < 0.1 ? 0.9 : t < 0.14 ? 0.25 : 0.16 + 0.3 * exp(-(t - 0.14) * 9)
    }

    /// A fighter's joints with the feet at (0, 0). The held arm keeps the
    /// shipped kinematics: shoulder first, elbow late.
    static func pose(
        facing s: CGFloat, rise: CGFloat, pump: CGFloat, drop d: CGFloat, breath: CGFloat, dip: CGFloat, loose: CGFloat
    ) -> Pose {
        let full = min(1, max(0, rise))
        let up = 3.5 * full
        let shoulderY = -170 - 5 * full + 8 * d - breath - up + 4 * dip
        let lean = -s * 3 * full + s * 4 * d
        let hipX = s * 1.5 * d
        let shoulderIn = CGPoint(x: lean + s * 26, y: shoulderY + 2)
        let shoulderOut = CGPoint(x: lean - s * 26, y: shoulderY + 2 + 3 * d)
        let held = competitionJudgeArm(
            shoulder: shoulderIn, inward: s, raised: Double(rise), dip: Double(dip), loose: Double(loose)
        )
        let q = clamp(pump)
        let upper = mix(0.24, 2.75, q)
        let forearm = mix(0.14, 3.05, 1 - (1 - q) * (1 - q))
        let elbowOut = CGPoint(x: shoulderOut.x - s * sin(upper) * 35, y: shoulderOut.y + cos(upper) * 35)
        let wristOut = CGPoint(x: elbowOut.x - s * sin(forearm) * 35, y: elbowOut.y + cos(forearm) * 35)
        return Pose(
            facing: s, shoulderY: shoulderY, lean: lean, waistY: -112 + 3 * d - up * 0.6, hipX: hipX,
            shoulderIn: shoulderIn, shoulderOut: shoulderOut,
            elbowIn: held.elbow, wristIn: held.wrist, elbowOut: elbowOut, wristOut: wristOut,
            hipIn: CGPoint(x: hipX + s * 10, y: -98 - up * 0.4), hipOut: CGPoint(x: hipX - s * 10, y: -98 - up * 0.4),
            kneeIn: CGPoint(x: s * 15, y: -50 + 2 * d), kneeOut: CGPoint(x: -s * 19, y: -52 + 2 * d),
            ankleIn: CGPoint(x: s * 21, y: -8), ankleOut: CGPoint(x: -s * 25, y: -8),
            toeIn: CGPoint(x: s * 33, y: -5), toeOut: CGPoint(x: -s * 38, y: -5),
            head: CGPoint(x: lean * 1.3 + s * 2.5 * d, y: shoulderY - 41 + 5 * d)
        )
    }

    static func frame(
        bout: CompetitionJudgesBout, stances: [CompetitionJudgesStance], clock: CompetitionJudgesRingClock, time t: CGFloat
    ) -> Frame {
        let isFreeForAll = bout.format == .freeForAll
        let raise = CGFloat(clock.raise)
        let walk = clock.walk.map { CGFloat($0) }
        let tau = t - raise
        let dip: CGFloat = tau > -0.24 && tau < 0 ? sin(.pi * (tau + 0.24) / 0.24) : 0
        // Free-for-all: the two left standing walk in and the referee takes their wrists.
        let move: CGFloat = walk.map { smooth(ramp(t, $0, 0.5)) } ?? (isFreeForAll ? 0 : 1)
        let hold: CGFloat = walk.map { smooth(ramp(t, $0 + 0.2, 0.4)) } ?? 1
        let swing = smooth(ramp(tau, 0, 0.5))
        let lead = bout.isDraw ? nil : stances.firstIndex(where: \.won)
        let winnerX = lead.map { mix(180, stances[$0].x, 0.55) } ?? 180
        let lightX = mix(180, winnerX, swing)

        var figures: [Figure] = []
        for (index, stance) in stances.enumerated() {
            let cutAt = clock.cuts[stance.place].map { CGFloat($0) } ?? 0
            let isOut = stance.isOut
            let lit: CGFloat = isOut ? cut(t - cutAt) : 1
            let gone: CGFloat = isOut ? walk.map { ramp(t, $0, 0.3) } ?? 0 : 0
            let back: CGFloat = isOut ? smooth(ramp(t, cutAt + 0.05, 0.45)) : 0
            let side: CGFloat = stance.lineupX < 170 ? -1 : stance.lineupX > 190 ? 1 : 0
            let x: CGFloat = isOut ? stance.lineupX + side * 26 * gone : mix(stance.lineupX, stance.x, move)
            let scale: CGFloat = isOut ? stance.lineupScale * (1 - 0.04 * back) : mix(stance.lineupScale, stance.scale, move)
            let isHeld = stance.isHeld && clock.hasReferee && !isOut
            let late: CGFloat = stance.isOuter ? 0.1 : 0
            let raises = stance.won && !isOut
            let rise: CGFloat = raises ? spring(tau - late) * (stance.isOuter ? 0.97 : 1) : 0
            let pump: CGFloat = raises ? spring(tau - 0.14 - late) * 0.95 : 0
            let slump = CGFloat(UnitCurve.easeOut.value(at: Double(ramp(tau - (stance.isOuter ? 0.08 : 0), 0.06, 0.5))))
            let drop: CGFloat = isOut ? 0.75 * back : stance.won ? 0 : slump
            let breath: CGFloat = tau > 0 || isOut ? 0 : sin(t * 2 * .pi / 2.5 + CGFloat(index))
            let loose: CGFloat = isHeld ? (isFreeForAll ? 1 - hold : 0) : 1
            let joints = pose(
                facing: stance.facing, rise: rise, pump: pump, drop: drop,
                breath: breath, dip: isHeld ? dip : 0, loose: loose
            )
            let tone: Color = bout.format == .doubles && index == 1
                ? (bout.fighters[index].isBot ? tones[2] : partnerTone) : tones[min(index, 3)]
            figures.append(Figure(
                index: index, stance: stance, x: x, scale: scale, pose: joints, tone: tone,
                lit: lit, alpha: 1 - gone, rise: rise,
                wrist: CGPoint(x: x + scale * joints.wristIn.x, y: floor + scale * joints.wristIn.y),
                head: CGPoint(x: x + scale * joints.head.x, y: floor + scale * joints.head.y)
            ))
        }

        // The referee: one wrist in each hand, eyes on the winner after the raise.
        let lookTo: CGFloat = winnerX > 180 ? 1 : winnerX < 180 ? -1 : 0
        let refereeX = 180 + lookTo * 3 * swing
        var arms: [Arm] = []
        for direction: CGFloat in [-1, 1] {
            let shoulder = CGPoint(x: refereeX + direction * 19, y: 152 + 3 * dip)
            var wrist = CGPoint(x: shoulder.x + direction * 7, y: shoulder.y + 90)
            var up: CGFloat = 0
            if let figure = figures.first(where: {
                $0.stance.isHeld && !$0.stance.isOut && $0.stance.facing == -direction
            }) {
                wrist = CGPoint(x: mix(wrist.x, figure.wrist.x, hold), y: mix(wrist.y, figure.wrist.y - 1, hold))
                up = clamp(figure.rise)
            }
            arms.append(Arm(
                shoulder: shoulder,
                // The shipped elbow: most of the way out, sagging until the arm is up.
                elbow: CGPoint(
                    x: shoulder.x + (wrist.x - shoulder.x) * 0.65,
                    y: (shoulder.y + wrist.y) / 2 + 17 * (1 - up) * hold + 6 * (1 - hold)
                ),
                wrist: wrist
            ))
        }

        // One light for the pair; in a free-for-all each has their own until the walk.
        var cones = [Cone(
            top: mix(180, lightX, 0.35), bottom: lightX, width: mix(150, 112, swing),
            alpha: isFreeForAll ? move : 1, amber: bout.yoursWon ? swing : 0
        )]
        if isFreeForAll {
            for figure in figures {
                cones.append(Cone(
                    top: mix(180, figure.x, 0.8), bottom: figure.x, width: 44 * figure.scale,
                    alpha: figure.lit * (1 - move) * figure.alpha, amber: 0
                ))
            }
        }
        // Cameras in the dark: a few while they wait, a burst at the raise.
        var flashes: [(point: CGPoint, glow: CGFloat)] = []
        for index in 0..<46 {
            let at = index < 20
                ? 0.3 + CGFloat(index) * 0.42 + 0.3 * noise(index)
                : raise + 0.02 + 1.1 * noise(index + 11) * noise(index + 12)
            guard t >= at, t < at + 0.17 else { continue }
            flashes.append((CGPoint(x: 10 + 340 * noise(index + 50), y: 16 + 118 * noise(index + 90)), 1 - (t - at) / 0.17))
        }
        let tags = figures.filter(\.stance.isOut).map { figure in
            (x: figure.x, text: GroupMatchPresentation.placeText(figure.stance.place).uppercased(),
             alpha: ramp(t, CGFloat(clock.cuts[figure.stance.place] ?? 0) + 0.15, 0.2) * figure.alpha)
        }
        return Frame(
            time: t, figures: figures, refereeX: refereeX, refereeDip: 3 * dip, refereeLook: lookTo * 2.2 * swing,
            refereeAlpha: clock.hasReferee ? walk.map { ramp(t, $0 + 0.05, 0.35) } ?? 1 : 0,
            arms: arms, cones: cones, flashes: flashes, tags: tags, lightX: lightX,
            haze: isFreeForAll ? move : 1
        )
    }

    // MARK: Shapes

    /// A tapered limb: the hull of two circles.
    static func limb(_ a: CGPoint, _ ra: CGFloat, _ b: CGPoint, _ rb: CGFloat) -> Path {
        let distance = max(hypot(b.x - a.x, b.y - a.y), 0.001)
        let along = atan2(b.y - a.y, b.x - a.x)
        let spread = acos(max(-1, min(1, (ra - rb) / distance)))
        var path = Path()
        func arc(_ centre: CGPoint, _ radius: CGFloat, _ from: CGFloat, _ to: CGFloat) {
            for step in 0...10 {
                let angle = from + (to - from) * CGFloat(step) / 10
                let point = CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
                if path.isEmpty { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        arc(a, ra, along + spread, along - spread + 2 * .pi)
        arc(b, rb, along - spread, along + spread)
        path.closeSubpath()
        return path
    }

    static func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        path.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
        path.closeSubpath()
        return path
    }

    /// The glove's own space: wrist at the origin, the fist along +y.
    static func gloveSpace(_ wrist: CGPoint, _ elbow: CGPoint) -> CGAffineTransform {
        let dx = wrist.x - elbow.x, dy = wrist.y - elbow.y
        return CGAffineTransform(translationX: wrist.x, y: wrist.y).rotated(by: atan2(-dx, dy))
    }

    static func glove(_ wrist: CGPoint, _ elbow: CGPoint, thumb: CGFloat) -> [Path] {
        let space = gloveSpace(wrist, elbow)
        return [
            Path(roundedRect: CGRect(x: -11.5, y: -5, width: 23, height: 30), cornerRadius: 10).applying(space),
            Path(ellipseIn: CGRect(x: thumb * 10.5 - 5.5, y: 0.5, width: 11, height: 17)).applying(space),
        ]
    }

    static func shorts(_ pose: Pose, grow: CGFloat) -> Path {
        let x = pose.hipX, y = pose.waistY
        return polygon([
            (x - 21 - grow, y - 4), (x + 21 + grow, y - 4), (x + 27 + grow, -66 + grow), (x + 5, -67 + grow),
            (x, -80), (x - 5, -67 + grow), (x - 27 - grow, -66 + grow),
        ])
    }

    /// The whole silhouette, each part its own path so overlaps never cut holes.
    static func fighter(_ pose: Pose) -> [Path] {
        let lean = pose.lean, top = pose.shoulderY, waist = pose.waistY, hip = pose.hipX, width: CGFloat = 30
        var torso = Path()
        torso.move(to: CGPoint(x: lean - 9, y: top - 9))
        torso.addQuadCurve(to: CGPoint(x: lean - width, y: top + 3), control: CGPoint(x: lean - 23, y: top - 8))
        torso.addCurve(to: CGPoint(x: hip - 19, y: waist),
                       control1: CGPoint(x: lean - width + 1, y: top + 30), control2: CGPoint(x: hip - 22, y: waist - 22))
        torso.addLine(to: CGPoint(x: hip + 19, y: waist))
        torso.addCurve(to: CGPoint(x: lean + width, y: top + 3),
                       control1: CGPoint(x: hip + 22, y: waist - 22), control2: CGPoint(x: lean + width - 1, y: top + 30))
        torso.addQuadCurve(to: CGPoint(x: lean + 9, y: top - 9), control: CGPoint(x: lean + 23, y: top - 8))
        torso.closeSubpath()
        let parts: [Path] = [
            limb(pose.hipIn, 12.5, pose.kneeIn, 9.5), limb(pose.kneeIn, 9, pose.ankleIn, 6.5),
            limb(pose.hipOut, 12.5, pose.kneeOut, 9.5), limb(pose.kneeOut, 9, pose.ankleOut, 6.5),
            limb(pose.ankleIn, 7.5, pose.toeIn, 5.5), limb(pose.ankleOut, 7.5, pose.toeOut, 5.5),
            shorts(pose, grow: 0), torso,
            limb(CGPoint(x: lean, y: top - 2), 9, CGPoint(x: mix(lean, pose.head.x, 0.6), y: top - 24), 7.5),
            limb(pose.shoulderOut, 10.5, pose.elbowOut, 8), limb(pose.elbowOut, 7.5, pose.wristOut, 6.5),
            limb(pose.shoulderIn, 10.5, pose.elbowIn, 8), limb(pose.elbowIn, 7.5, pose.wristIn, 6.5),
        ]
        return parts + glove(pose.wristOut, pose.elbowOut, thumb: pose.facing)
            + glove(pose.wristIn, pose.elbowIn, thumb: -pose.facing)
    }

    /// Drawn inside the silhouette: shorts, glove cuffs, boots, a few lines of muscle.
    static func detail(_ pose: Pose, tone: Color, in context: GraphicsContext) {
        let lean = pose.lean, top = pose.shoulderY, waist = pose.waistY, hip = pose.hipX, s = pose.facing
        context.fill(shorts(pose, grow: 1), with: .color(Theme.beltWell))
        context.fill(Path(CGRect(x: hip - 22, y: waist - 5, width: 44, height: 7.5)), with: .color(tone))
        var stripe = Path()
        stripe.move(to: CGPoint(x: hip - s * 20, y: waist + 7))
        stripe.addLine(to: CGPoint(x: hip - s * 24, y: -69))
        context.stroke(stripe, with: .color(tone.opacity(0.75)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        var hem = Path()
        hem.move(to: CGPoint(x: hip - 27, y: -66)); hem.addLine(to: CGPoint(x: hip - 5, y: -67))
        hem.move(to: CGPoint(x: hip + 5, y: -67)); hem.addLine(to: CGPoint(x: hip + 27, y: -66))
        context.stroke(hem, with: .color(tone.opacity(0.55)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        var muscle = Path()
        muscle.move(to: CGPoint(x: lean - 21, y: top + 20))
        muscle.addQuadCurve(to: CGPoint(x: lean - 1.5, y: top + 22), control: CGPoint(x: lean - 11, y: top + 28))
        muscle.move(to: CGPoint(x: lean + 21, y: top + 20))
        muscle.addQuadCurve(to: CGPoint(x: lean + 1.5, y: top + 22), control: CGPoint(x: lean + 11, y: top + 28))
        muscle.move(to: CGPoint(x: lean * 0.7, y: top + 31))
        muscle.addLine(to: CGPoint(x: hip, y: waist - 9))
        context.stroke(muscle, with: .color(.black.opacity(0.2)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))

        for (wrist, elbow) in [(pose.wristOut, pose.elbowOut), (pose.wristIn, pose.elbowIn)] {
            var mitt = context
            mitt.concatenate(gloveSpace(wrist, elbow))
            mitt.fill(Path(roundedRect: CGRect(x: -11.5, y: -5, width: 23, height: 30), cornerRadius: 10),
                      with: .color(.white.opacity(0.1)))
            var shine = Path()
            shine.addArc(center: CGPoint(x: -1, y: 13), radius: 7.5, startAngle: .radians(-2.5), endAngle: .radians(-1.1), clockwise: false)
            mitt.stroke(shine, with: .color(.white.opacity(0.4)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            var crease = Path()
            crease.move(to: CGPoint(x: -9, y: 12))
            crease.addQuadCurve(to: CGPoint(x: 9, y: 12), control: CGPoint(x: 0, y: 16))
            mitt.stroke(crease, with: .color(.black.opacity(0.22)), lineWidth: 1.4)
            mitt.fill(Path(roundedRect: CGRect(x: -9.5, y: -8, width: 19, height: 8), cornerRadius: 2.5),
                      with: .color(paper.opacity(0.78)))
        }
        var laces = Path()
        for (ankle, toe) in [(pose.ankleIn, pose.toeIn), (pose.ankleOut, pose.toeOut)] {
            context.fill(limb(ankle, 8, toe, 6), with: .color(.black.opacity(0.3)))
            context.fill(limb(CGPoint(x: ankle.x, y: ankle.y - 16), 7.5, ankle, 8), with: .color(.black.opacity(0.3)))
            for y: CGFloat in [-13, -9, -5] {
                laces.move(to: CGPoint(x: ankle.x - 4, y: ankle.y + y))
                laces.addLine(to: CGPoint(x: ankle.x + 4, y: ankle.y + y))
            }
        }
        context.stroke(laces, with: .color(.white.opacity(0.28)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
    }

    // MARK: Drawing

    /// One figure: its flat shape, light from above, its details, then a
    /// bright edge on the side that faces the light.
    static func figure(
        _ shape: [Path], tone: Color, lit: CGFloat, alpha: CGFloat, lightFrom: CGFloat,
        in context: GraphicsContext, detail: (GraphicsContext) -> Void
    ) {
        guard alpha > 0.01 else { return }
        let space = CGRect(x: 0, y: 0, width: 360, height: 340)
        var body = context
        body.opacity = Double(alpha)
        body.drawLayer { layer in
            for part in shape { layer.fill(part, with: .color(tone)) }
            layer.blendMode = .sourceAtop
            layer.fill(Path(space), with: .linearGradient(
                Gradient(stops: [
                    .init(color: .white.opacity(0.22), location: 0),
                    .init(color: .white.opacity(0), location: 0.3),
                    .init(color: .black.opacity(0.26), location: 1),
                ]),
                startPoint: CGPoint(x: 0, y: 80), endPoint: CGPoint(x: 0, y: 322)
            ))
            detail(layer)
            if lit < 1 { layer.fill(Path(space), with: .color(Theme.beltWell.opacity(Double(1 - lit) * 0.82))) }
        }
        var rim = context
        rim.opacity = Double(alpha * 0.5 * lit)
        rim.blendMode = .plusLighter
        rim.drawLayer { layer in
            for part in shape { layer.fill(part, with: .color(.white)) }
            layer.blendMode = .destinationOut
            layer.translateBy(x: -1.15 * lightFrom, y: 1.8)
            for part in shape { layer.fill(part, with: .color(.white)) }
        }
    }

    static func cone(_ cone: Cone, in context: GraphicsContext) {
        guard cone.alpha > 0.01 else { return }
        // Warms to amber when the light finds your side.
        let light = Color(
            red: Double(mix(245, 248, cone.amber)) / 255,
            green: Double(mix(245, 214, cone.amber)) / 255,
            blue: Double(mix(240, 150, cone.amber)) / 255
        )
        let alpha = Double(cone.alpha)
        for (wide, strength) in [(1.3, 0.4), (0.85, 0.6)] as [(CGFloat, Double)] {
            context.fill(
                polygon([
                    (cone.top - 9 * wide, -30), (cone.top + 9 * wide, -30),
                    (cone.bottom + cone.width * wide, 322), (cone.bottom - cone.width * wide, 322),
                ]),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: light.opacity(0.26 * alpha * strength), location: 0),
                        .init(color: light.opacity(0.07 * alpha * strength), location: 0.75),
                        .init(color: light.opacity(0), location: 1),
                    ]),
                    startPoint: CGPoint(x: 0, y: -30), endPoint: CGPoint(x: 0, y: 322)
                )
            )
        }
        var pool = context
        pool.translateBy(x: cone.bottom, y: 318)
        pool.scaleBy(x: 1, y: 0.11)
        let radius = cone.width * 1.1
        pool.fill(
            Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(colors: [light.opacity(0.2 * alpha), light.opacity(0)]),
                center: .zero, startRadius: 2, endRadius: radius
            )
        )
    }

    static func dot(_ centre: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
    }

    static func draw(_ frame: Frame, in context: GraphicsContext) {
        // The dark, with cameras in it.
        for index in 0..<34 {
            context.fill(
                dot(CGPoint(x: 8 + 344 * noise(index + 3), y: 14 + 122 * noise(index + 21)), 0.8 + 1.4 * noise(index + 40)),
                with: .color(paper.opacity(0.03 + 0.04 * Double(noise(index + 7))))
            )
        }
        for flash in frame.flashes {
            let glow = Double(flash.glow), at = flash.point
            context.fill(dot(at, 11), with: .radialGradient(
                Gradient(stops: [
                    .init(color: .white.opacity(0.95 * glow), location: 0),
                    .init(color: .white.opacity(0.35 * glow), location: 0.25),
                    .init(color: .white.opacity(0), location: 1),
                ]),
                center: at, startRadius: 0, endRadius: 11
            ))
            var star = Path()
            star.move(to: CGPoint(x: at.x - 13, y: at.y)); star.addLine(to: CGPoint(x: at.x + 13, y: at.y))
            star.move(to: CGPoint(x: at.x, y: at.y - 9)); star.addLine(to: CGPoint(x: at.x, y: at.y + 9))
            context.stroke(star, with: .color(.white.opacity(0.7 * glow)), lineWidth: 0.8)
        }
        for light in frame.cones { cone(light, in: context) }

        // The ropes are the three rings: Move, Exercise, Stand.
        for (tone, y) in [(Theme.move, 172), (Theme.exercise, 212), (Theme.stand, 252)] as [(Color, CGFloat)] {
            for (lift, colour, width) in [(0, tone.opacity(0.5), 2.4), (1, Color.white.opacity(0.13), 0.8)] as [(CGFloat, Color, CGFloat)] {
                var rope = Path()
                rope.move(to: CGPoint(x: -6, y: y - lift))
                rope.addQuadCurve(to: CGPoint(x: 366, y: y - lift), control: CGPoint(x: 180, y: y + 5 - lift))
                context.stroke(rope, with: .color(colour), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }
        for x: CGFloat in [-3, 350] {
            context.fill(Path(roundedRect: CGRect(x: x, y: 160, width: 13, height: 160), cornerRadius: 4),
                         with: .color(paper.opacity(0.1)))
        }
        // The canvas floor.
        context.fill(Path(CGRect(x: 0, y: 300, width: 360, height: 40)), with: .linearGradient(
            Gradient(stops: [
                .init(color: paper.opacity(0), location: 0),
                .init(color: paper.opacity(0.07), location: 0.42),
                .init(color: paper.opacity(0.02), location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: 300), endPoint: CGPoint(x: 0, y: 340)
        ))
        var edge = Path()
        edge.move(to: CGPoint(x: 0, y: 316.5)); edge.addLine(to: CGPoint(x: 360, y: 316.5))
        context.stroke(edge, with: .color(Theme.secondary.opacity(0.28)), lineWidth: 1)
        var shadows: [(x: CGFloat, radius: CGFloat, alpha: CGFloat)] = frame.figures.map {
            (x: $0.x, radius: 46 * $0.scale, alpha: $0.alpha * $0.lit)
        }
        shadows.append((x: frame.refereeX, radius: 30, alpha: frame.refereeAlpha * 0.8))
        for shadow in shadows where shadow.alpha > 0.01 {
            var ground = context
            ground.translateBy(x: shadow.x, y: 319)
            ground.scaleBy(x: 1, y: 0.17)
            ground.fill(dot(.zero, shadow.radius), with: .radialGradient(
                Gradient(colors: [.black.opacity(0.6 * Double(shadow.alpha)), .black.opacity(0)]),
                center: .zero, startRadius: 2, endRadius: shadow.radius
            ))
        }
        for tag in frame.tags where tag.alpha > 0.01 {
            var text = context.resolve(Text(tag.text).font(.system(size: 10, weight: .bold).width(.condensed)))
            text.shading = .color(Theme.secondary.opacity(Double(tag.alpha)))
            context.draw(text, at: CGPoint(x: tag.x, y: 330))
        }

        // The referee stays upright and quieter than any corner.
        let x = frame.refereeX, dy = frame.refereeDip, headX = x + frame.refereeLook * 1.5
        var body: [Path] = []
        for side: CGFloat in [-1, 1] {
            body += [
                limb(CGPoint(x: x + side * 9, y: 232 + dy), 9, CGPoint(x: x + side * 11, y: 272 + dy * 0.5), 7.5),
                limb(CGPoint(x: x + side * 11, y: 272 + dy * 0.5), 7, CGPoint(x: x + side * 13, y: 305), 6),
                limb(CGPoint(x: x + side * 12, y: 310), 5.5, CGPoint(x: x + side * 22, y: 311.5), 4.5),
                limb(CGPoint(x: x + side * 21, y: 153 + dy), 8.5, CGPoint(x: x + side * 17, y: 160 + dy), 8),
            ]
        }
        var shirt = Path()
        shirt.move(to: CGPoint(x: x - 22, y: 149 + dy))
        shirt.addQuadCurve(to: CGPoint(x: x + 22, y: 149 + dy), control: CGPoint(x: x, y: 140 + dy))
        shirt.addQuadCurve(to: CGPoint(x: x + 16, y: 236 + dy), control: CGPoint(x: x + 21, y: 200 + dy))
        shirt.addLine(to: CGPoint(x: x - 16, y: 236 + dy))
        shirt.addQuadCurve(to: CGPoint(x: x - 22, y: 149 + dy), control: CGPoint(x: x - 21, y: 200 + dy))
        shirt.closeSubpath()
        body += [
            shirt,
            limb(CGPoint(x: x, y: 147 + dy), 6.5, CGPoint(x: mix(x, headX, 0.6), y: 133 + dy), 6),
            Path(ellipseIn: CGRect(x: headX - 13.5, y: 101.5 + dy, width: 27, height: 35)),
        ]
        figure(body, tone: refereeTone, lit: 1, alpha: frame.refereeAlpha, lightFrom: frame.lightX > x ? 1 : -1, in: context) { layer in
            for stripe in stride(from: CGFloat(-16), through: 16, by: 8) {
                layer.fill(Path(CGRect(x: x + stripe - 1.6, y: 150 + dy, width: 3.2, height: 84)),
                           with: .color(Theme.beltWell.opacity(0.55)))
            }
            layer.fill(Path(CGRect(x: x - 30, y: 234 + dy, width: 60, height: 72)), with: .color(Theme.beltWell.opacity(0.3)))
            layer.fill(Path(CGRect(x: x - 40, y: 304, width: 80, height: 14)), with: .color(Theme.beltWell.opacity(0.6)))
            layer.fill(Path(CGRect(x: x - 17, y: 232 + dy, width: 34, height: 4.5)), with: .color(Theme.beltWell.opacity(0.7)))
            layer.fill(Path(CGRect(x: x - 3, y: 232.5 + dy, width: 6, height: 3.5)), with: .color(paper.opacity(0.75)))
            var collar = Path()
            collar.addLines([CGPoint(x: x - 9, y: 145 + dy), CGPoint(x: x, y: 154 + dy), CGPoint(x: x + 9, y: 145 + dy)])
            layer.stroke(collar, with: .color(paper.opacity(0.7)), lineWidth: 3)
            layer.fill(polygon([(x - 7, 152 + dy), (x + 7, 160 + dy), (x + 7, 152 + dy), (x - 7, 160 + dy)]),
                       with: .color(Theme.beltWell))
        }

        // Cut lights first, then partners, so whoever the referee holds is in front.
        let order = frame.figures.sorted {
            ($0.stance.isOut ? 0 : $0.stance.isOuter ? 1 : 2) < ($1.stance.isOut ? 0 : $1.stance.isOuter ? 1 : 2)
        }
        for fighter in order {
            let space = CGAffineTransform(translationX: fighter.x, y: floor).scaledBy(x: fighter.scale, y: fighter.scale)
            figure(
                JudgesRing.fighter(fighter.pose).map { $0.applying(space) }, tone: fighter.tone,
                lit: fighter.lit, alpha: fighter.alpha, lightFrom: frame.lightX > fighter.x ? 1 : -1, in: context
            ) { layer in
                var local = layer
                local.concatenate(space)
                detail(fighter.pose, tone: fighter.tone, in: local)
            }
        }

        // His arms cross in front of the fighters: a sleeve, a white cuff, a hand.
        var sleeves: [Path] = []
        for arm in frame.arms {
            sleeves += [limb(arm.shoulder, 8, arm.elbow, 6.5), limb(arm.elbow, 6.5, arm.wrist, 5.5),
                        Path(ellipseIn: CGRect(x: arm.wrist.x - 8, y: arm.wrist.y - 7, width: 16, height: 14))]
        }
        figure(sleeves, tone: refereeTone, lit: 1, alpha: frame.refereeAlpha, lightFrom: frame.lightX > x ? 1 : -1, in: context) { layer in
            for arm in frame.arms {
                let dx = arm.wrist.x - arm.elbow.x, dy = arm.wrist.y - arm.elbow.y
                let length = max(hypot(dx, dy), 0.001)
                let cuff = CGPoint(x: arm.wrist.x - dx / length * 9, y: arm.wrist.y - dy / length * 9)
                layer.fill(limb(cuff, 6.6, CGPoint(x: cuff.x - dx / length * 4, y: cuff.y - dy / length * 4), 6.8),
                           with: .color(paper.opacity(0.6)))
                layer.fill(Path(ellipseIn: CGRect(x: arm.wrist.x - 8, y: arm.wrist.y - 7, width: 16, height: 14)),
                           with: .color(paper.opacity(0.3)))
            }
        }

        // Haze in the light, and the edges fall away.
        for index in 0..<18 {
            let y = (noise(index + 60) * 300 + frame.time * (5 + 9 * noise(index + 70))).truncatingRemainder(dividingBy: 300)
            let x = frame.lightX + (noise(index + 80) - 0.5) * (60 + y * 0.45)
            context.fill(dot(CGPoint(x: x, y: y), 0.7 + 1.1 * noise(index + 95)),
                         with: .color(paper.opacity((0.1 + 0.16 * Double(noise(index + 90))) * Double(frame.haze))))
        }
        context.fill(Path(CGRect(x: 0, y: 0, width: 360, height: 340)), with: .radialGradient(
            Gradient(colors: [.black.opacity(0), .black.opacity(0.5)]),
            center: CGPoint(x: 180, y: 170), startRadius: 120, endRadius: 250
        ))
    }
}
