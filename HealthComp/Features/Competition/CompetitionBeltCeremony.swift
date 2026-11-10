import AVFoundation
import CompetitionCore
import SwiftUI

// The belt ceremony's clip timings, hold and roll are sanctioned exceptions to
// "numbers live in Motion.swift": they belong to the rendered clips.

/// What one belt event plays: a clip and the words that land on it.
struct CompetitionBeltCeremonyScript: Equatable, Identifiable {
    /// Bundle name of the clip, its beat JSON and its poster.
    let clip: String
    let headline: String
    let title: String
    var detail: String? = nil
    /// The reign's title defenses, rolled up under the title.
    var defenses: Int? = nil
    var isYours = true

    var id: String { clip }

    var announcement: String {
        ([headline, title, detail].compactMap { $0 } + [defenses.map(competitionDefensesText)].compactMap { $0 })
            .joined(separator: ". ")
    }
}

/// Nil for everything without a cinematic: they took a vacant belt, they
/// defended, a tie, a vacant belt, or a retired pair.
func competitionBeltCeremonyScript(
    _ event: CompetitionBeltEvent?,
    opponentName name: String
) -> CompetitionBeltCeremonyScript? {
    guard name != competitionFormerCompetitorName else { return nil }
    switch event {
    case .took(.you, nil, _):
        return .init(clip: "earned", headline: "AND NEW", title: "You took the belt")
    case let .took(.you, weeks?, defenses):
        return .init(
            clip: "taken",
            headline: "AND NEW",
            title: "You took the belt from \(name)",
            detail: "\(name)’s reign: \(competitionReignText(weeks: weeks, defenses: defenses))"
        )
    case let .took(.them, weeks?, defenses):
        return .init(
            clip: "lost",
            headline: "AND NEW",
            title: "\(name) took the belt",
            detail: "Your reign: \(competitionReignText(weeks: weeks, defenses: defenses))",
            isYours: false
        )
    case let .defended(.you, _, defenses):
        return .init(
            clip: "defended",
            headline: "AND STILL",
            title: competitionTitleDefenseText(defenses),
            defenses: defenses
        )
    default:
        return nil
    }
}

/// A clip's file and when things happen in it, from its beat JSON. A render
/// writes either `[beat]` or `{"beats": [beat]}`.
struct CompetitionBeltCeremonyClip {
    private struct Beat: Decodable {
        let t: TimeInterval
        let kind: String
    }
    private struct File: Decodable { let beats: [Beat] }

    let url: URL
    /// When the words land: the clip's last settle beat, where it holds.
    let settle: TimeInterval
    /// One heavy haptic each. Lost is one thud at the yank, then nothing.
    let impacts: [TimeInterval]

    init?(named name: String, in bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: name, withExtension: "mp4"),
              let json = bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: json),
              let beats = (try? JSONDecoder().decode([Beat].self, from: data))
                ?? (try? JSONDecoder().decode(File.self, from: data).beats),
              let settle = beats.filter({ $0.kind == "settle" }).map(\.t).max()
        else { return nil }
        let impacts = beats.filter { $0.kind == "impact" }.map(\.t).sorted()
        self.url = url
        self.settle = settle
        self.impacts = name == "lost" ? Array(impacts.prefix(1)) : impacts
    }
}

/// Test Lab launches run without ceremonies, so its tests stay untouched,
/// unless `--belt-ceremonies` asks for them.
private let competitionBeltCeremoniesAreOn: Bool = {
    let arguments = ProcessInfo.processInfo.arguments
    return arguments.contains("--belt-ceremonies")
        || !arguments.contains { $0.hasSuffix("-competition-test-lab") }
}()

/// True when this result has a ceremony to play or replay.
func competitionBeltCeremonyCanPlay(_ event: CompetitionBeltEvent?, opponentName: String) -> Bool {
    competitionBeltCeremoniesAreOn && competitionBeltCeremonyScript(event, opponentName: opponentName) != nil
}

extension View {
    /// The first-view belt ceremony over the Result screen. `onFinished` starts
    /// the Verdict, at once when there is nothing to play. Setting `replay`
    /// plays it again from the result's belt banner; a replay does not call
    /// `onFinished`.
    func competitionBeltCeremony(
        event: CompetitionBeltEvent?,
        opponentName: String,
        competition: LocalCompetitionPresentation? = nil,
        isFirstView: Bool,
        replay: Binding<Bool> = .constant(false),
        onFinished: @escaping () -> Void
    ) -> some View {
        modifier(CompetitionBeltCeremony(
            event: event,
            opponentName: opponentName,
            competition: competition,
            isFirstView: isFirstView,
            replay: replay,
            onFinished: onFinished
        ))
    }
}

private struct CompetitionBeltCeremony: ViewModifier {
    let event: CompetitionBeltEvent?
    let opponentName: String
    let competition: LocalCompetitionPresentation?
    let isFirstView: Bool
    @Binding var replay: Bool
    let onFinished: () -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @AppStorage(CompetitionMotionSeen.storageKey) private var seen = CompetitionMotionSeen()
    @State private var didStart = false
    @State private var isShowing = false
    @State private var showsJudges = false
    @State private var isReplay = false

    private var script: CompetitionBeltCeremonyScript? {
        competitionBeltCeremonyCanPlay(event, opponentName: opponentName)
            ? competitionBeltCeremonyScript(event, opponentName: opponentName) : nil
    }

    private var judgesAreOn: Bool {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains(where: { $0.hasSuffix("-competition-test-lab") }) {
            return args.contains("--judges-decision")
        }
        #endif
        return true
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if isShowing || (!didStart && isFirstView && (judgesAreOn || script != nil)) {
                    Theme.beltWell.ignoresSafeArea()
                }
            }
            .fullScreenCover(isPresented: $isShowing) {
                if showsJudges, let competition {
                    CompetitionJudgesReveal(
                        competition: competition,
                        onFinished: playBelt,
                        onSkip: finish
                    )
                    .presentationBackground(Theme.ground)
                } else if let script {
                    CompetitionBeltCeremonyPlayer(
                        script: script,
                        onLeaving: verdict,
                        onGone: { present(false) }
                    )
                    .presentationBackground(.clear)
                }
            }
            .onAppear {
                guard !didStart else { return }
                didStart = true
                if judgesAreOn, let competition, !seen.hasSeen(.judges, competition.id), isFirstView {
                    playJudges()
                } else if isFirstView {
                    playBelt()
                } else {
                    onFinished()
                }
            }
            .onChange(of: replay) { _, isOn in
                guard isOn else { return }
                replay = false
                isReplay = true
                if judgesAreOn, competition != nil { playJudges() } else { playBelt() }
            }
    }

    private func playJudges() {
        guard let competition else { return }
        // Latch before presenting: backgrounding or closing never repeats the reveal.
        seen = seen.marking(.judges, competition.id)
        showsJudges = true
        present(true)
    }

    private func playBelt() {
        showsJudges = false
        if let script {
            if voiceOver {
                AccessibilityNotification.Announcement(script.announcement).post()
                finish()
            } else {
                present(true)
            }
        } else {
            finish()
        }
    }

    private func verdict() {
        if !isReplay { onFinished() }
        isReplay = false
    }

    private func finish() {
        verdict()
        present(false)
    }

    private func present(_ shown: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isShowing = shown }
    }
}

/// Full screen on black: the clip, or its poster under Reduce Motion, with the
/// words on the settle beat. A tap anywhere skips it.
private struct CompetitionBeltCeremonyPlayer: View {
    private static let hold: Duration = .seconds(1.2)

    let script: CompetitionBeltCeremonyScript
    let onLeaving: () -> Void
    let onGone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var poster: UIImage?
    @State private var showsWords = false
    @State private var thuds = 0
    @State private var isLeaving = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
                .ignoresSafeArea()
            if let player {
                CompetitionBeltCeremonyVideo(player: player, clip: script.clip)
                    .ignoresSafeArea()
            }
            if let poster {
                // In an overlay, so the filled image can't widen the ZStack.
                Color.clear
                    .overlay {
                        Image(uiImage: poster)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .ignoresSafeArea()
                    .accessibilityElement()
                    .accessibilityAddTraits(.isImage)
                    .accessibilityIdentifier("competition.belt.ceremony.poster.\(script.clip)")
                    .transition(Motion.appear)
            }
            if showsWords {
                CompetitionBeltCeremonyWords(script: script, rolls: !reduceMotion)
                    .transition(Motion.appear)
            }
        }
        // The words' 38% is of the whole screen, where the clips hold clear.
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .opacity(isLeaving ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture { leave() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { leave() }
        .accessibilityIdentifier("competition.belt.ceremony")
        .sensoryFeedback(.impact(weight: .heavy), trigger: thuds)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { leave(animated: false) }
        }
        .task {
            if reduceMotion {
                await showPoster()
            } else {
                await playClip()
            }
            leave()
        }
    }

#if DEBUG
    /// A launch argument can't switch Reduce Motion on in a simulator:
    /// `--belt-reduce-motion` takes its path for the UI tests.
    private static let assumesReduceMotion = ProcessInfo.processInfo.arguments.contains("--belt-reduce-motion")
#else
    private static let assumesReduceMotion = false
#endif

    private var reduceMotion: Bool { systemReduceMotion || Self.assumesReduceMotion }

    private func showPoster() async {
        guard let image = UIImage(named: "\(script.clip)-final.jpg") else { return }
        thuds += 1
        withAnimation(Motion.fade) {
            poster = image
            showsWords = true
        }
        try? await Task.sleep(for: Duration.seconds(0.2) + Self.hold)
    }

    /// Falls through to the end if the clip won't load. Each wait measures
    /// from the player, so a slow start can't pull the beats off the picture.
    private func playClip() async {
        guard let clip = CompetitionBeltCeremonyClip(named: script.clip) else { return }
        let item = AVPlayerItem(url: clip.url)
        let player = AVPlayer(playerItem: item)
        // No audio track and no audio session: the person's music keeps playing.
        player.isMuted = true
        player.allowsExternalPlayback = false
        self.player = player

        var polls = 0
        while item.status == .unknown, polls < 40, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            polls += 1
        }
        guard item.status == .readyToPlay else { return }
        player.play()

        func wait(until time: TimeInterval) async -> Bool {
            let remaining = time - player.currentTime().seconds
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            return !Task.isCancelled && !isLeaving && item.status != .failed
        }
        let beats = clip.impacts.map { ($0, false) } + [(clip.settle, true)]
        for (time, isSettle) in beats.sorted(by: { $0.0 < $1.0 }) {
            guard await wait(until: time) else { return }
            if isSettle {
                withAnimation(Motion.fade) { showsWords = true }
            } else {
                thuds += 1
            }
        }
        guard await wait(until: item.duration.seconds) else { return }
        try? await Task.sleep(for: Self.hold)
    }

    /// Skip, the end of the hold, or backgrounding, whichever comes first.
    private func leave(animated: Bool = true) {
        guard !isLeaving else { return }
        player?.pause()
        onLeaving()
        guard animated else {
            isLeaving = true
            onGone()
            return
        }
        withAnimation(Motion.fade, completionCriteria: .logicallyComplete) {
            isLeaving = true
        } completion: {
            onGone()
        }
    }
}

/// The lower 38% of the screen, where the clips hold still.
private struct CompetitionBeltCeremonyWords: View {
    let script: CompetitionBeltCeremonyScript
    let rolls: Bool

    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize: CGFloat = 96
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 26
    @ScaledMetric(relativeTo: .title) private var countSize: CGFloat = 30
    @State private var rolled = 0

    var body: some View {
        VStack(spacing: 8) {
            Text(script.headline)
                .font(.score(size: headlineSize))
                .foregroundStyle(script.isYours ? Theme.you : Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(script.title)
                .font(.system(size: titleSize, weight: .heavy).width(.condensed))
                .foregroundStyle(Theme.ink)
                .minimumScaleFactor(0.6)
            if let detail = script.detail {
                Text(detail.uppercased())
                    .font(.themeLabel)
                    .tracking(1.2)
                    .foregroundStyle(Theme.secondary)
            }
            if let defenses = script.defenses {
                HStack(spacing: 10) {
                    CompetitionDefensePips(count: defenses, lit: rolled, color: Theme.youFill)
                    Text(String(rolled))
                        .font(.score(size: countSize).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                    Text(rolled == 1 ? "DEFENSE" : "DEFENSES")
                        .font(.themeLabel)
                        .tracking(1.2)
                        .foregroundStyle(Theme.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(competitionDefensesText(rolled))
                .accessibilityIdentifier("competition.belt.ceremony.count")
                .task {
                    guard rolls else {
                        rolled = defenses
                        return
                    }
                    // 180 ms a bar, inside the hold however long the reign.
                    let step = min(0.18, 1 / Double(max(defenses, 1)))
                    for count in 1...max(defenses, 1) {
                        try? await Task.sleep(for: .seconds(step))
                        rolled = count
                    }
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(.vertical, alignment: .top) { height, _ in height * 0.38 }
    }
}

/// AVPlayerLayer rather than AVPlayerViewController: no controls, nothing
/// system-owned on screen, and the clip fills the frame.
private struct CompetitionBeltCeremonyVideo: UIViewRepresentable {
    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
    }

    let player: AVPlayer
    let clip: String

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "competition.belt.ceremony.clip.\(clip)"
        if let layer = view.layer as? AVPlayerLayer {
            layer.player = player
            layer.videoGravity = .resizeAspectFill
        }
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {}
}

// MARK: Judges' decision

struct CompetitionJudgeCard: Equatable {
    let you: [Double?]
    let them: [Double?]
    var yourTotal: Double? { total(you) }
    var theirTotal: Double? { total(them) }
    private func total(_ points: [Double?]) -> Double? {
        points.count == 7 && points.allSatisfy { $0 != nil } ? points.compactMap { $0 }.reduce(0, +) : nil
    }
}

struct CompetitionJudgesDecision: Equatable {
    let cards: [CompetitionJudgeCard]
    let outcome: CompetitionOutcome
    let label: String
}

/// Cards describe the week; final total points always decide the match.
func competitionJudgesDecision(
    days: [LocalCompetitionDayPresentation], you: Double, them: Double
) -> CompetitionJudgesDecision {
    let ordered = days.sorted { $0.ordinal < $1.ordinal }
    func points(_ day: LocalCompetitionDayPresentation, own: Bool, ring: Int) -> Double? {
        let rings = own ? day.ownerRingPoints : day.opponentRingPoints
        let score = own ? day.ownerAcceptedPoints : day.opponentRevealedPoints
        guard let rings, rings.count == 3, rings.allSatisfy({ $0.isFinite && $0 >= 0 }),
              let score, abs(rings.reduce(0, +) - score) < 0.001 else { return nil }
        return rings[ring]
    }
    let cards = (0..<3).map { ring in
        CompetitionJudgeCard(
            you: ordered.map { points($0, own: true, ring: ring) },
            them: ordered.map { points($0, own: false, ring: ring) }
        )
    }
    let outcome: CompetitionOutcome = you == them ? .tie : you > them ? .win : .loss
    var label = outcome == .tie ? "DRAW" : "BY TOTAL POINTS"
    let complete = Set(ordered.map(\.ordinal)) == Set(1...7) && ordered.count == 7
        && cards.allSatisfy { $0.yourTotal != nil && $0.theirTotal != nil }
    if complete, outcome != .tie {
        let own = cards.compactMap(\.yourTotal), other = cards.compactMap(\.theirTotal)
        if abs(own.reduce(0, +) - you) < 0.001 && abs(other.reduce(0, +) - them) < 0.001 {
            let wins = zip(own, other).filter { outcome == .win ? $0 > $1 : $1 > $0 }.count
            let even = zip(own, other).filter { $0 == $1 }.count
            if wins == 3 { label = "UNANIMOUS DECISION" }
            else if wins == 2 { label = even == 1 ? "MAJORITY DECISION" : "SPLIT DECISION" }
        }
    }
    return .init(cards: cards, outcome: outcome, label: label)
}

/// The reveal's editorial clock: a 0.9 s hold, three 1.2 s cards, stamp,
/// one held beat and the raise. Animation curves still belong to Motion.
private struct CompetitionJudgesReveal: View {
    let competition: LocalCompetitionPresentation
    let onFinished: () -> Void
    let onSkip: () -> Void
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
    @State private var raised = false
    @State private var ticks = 0
    @State private var thuds = 0

    private var decision: CompetitionJudgesDecision {
        competitionJudgesDecision(days: competition.days, you: competition.userPoints, them: competition.opponentPoints)
    }
    private var winner: String {
        switch decision.outcome {
        case .win: "YOUR WINNER"
        case .loss: "THE WINNER, \(competition.opponentDisplayName.uppercased())"
        case .tie: "IT’S A DRAW"
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Text("HEALTHCOMP /").foregroundStyle(Theme.ink)
                Spacer()
                Text("7 ROUNDS").foregroundStyle(Theme.secondary)
            }
            .font(.themeLabel).tracking(1.3)
            Spacer(minLength: 0)
            ZStack {
                if stage == 0 { seal.transition(.opacity) }
                if stage == 1 { scorecards.transition(.opacity) }
                if stage == 2 { handRaise.transition(.opacity) }
            }
            Spacer(minLength: 0)
            Button("Skip reveal", action: onSkip)
                .font(.themeLabel)
                .foregroundStyle(Theme.secondary)
                .frame(minHeight: 44)
                .accessibilityIdentifier("competition.judges.skip")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture { if stage > 0 { onSkip() } }
        .accessibilityIdentifier("competition.judges.reveal")
        .sensoryFeedback(.impact(weight: .light), trigger: ticks)
        .sensoryFeedback(.impact(weight: .heavy), trigger: thuds)
        .task {
            guard (try? await Task.sleep(for: .seconds(3))) != nil else { return }
            tapOpens = true
        }
        .task(id: pressing) {
            guard pressing else { progress = 0; return }
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
                guard (try? await Task.sleep(for: .seconds(0.5))) != nil else { return }
            }
            withAnimation(reduceMotion ? Motion.fade : Motion.grow) { stamped = true }
            thuds += 1
            guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            withAnimation(Motion.fade) { stage = 2 }
        }
        .task(id: stage == 2) {
            guard stage == 2 else { return }
            if reduceMotion { raised = true }
            guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            withAnimation(reduceMotion ? Motion.fade : Motion.grow) { raised = true }
            thuds += 1
            if voiceOver {
                AccessibilityNotification.Announcement(
                    "\(winner), \(decision.label.lowercased()), \(competitionPointsText(competition.userPoints)) to \(competitionPointsText(competition.opponentPoints))."
                ).post()
            }
            guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
            onFinished()
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { onSkip() } }
    }

    private var seal: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("YOU VS \(competition.opponentDisplayName.uppercased()) · FINAL BELL")
                .font(.themeLabel).foregroundStyle(Theme.secondary)
            Text("The decision.\nUnder seal.")
                .font(.score(size: 52)).foregroundStyle(Theme.ink)
                .minimumScaleFactor(0.6)
            Text("After seven rounds…\nwe go to the judges’ scorecards.")
                .foregroundStyle(Theme.secondary)
            VStack(spacing: 28) {
                Text("OFFICIAL SCORECARDS").font(.themeLabel).tracking(2)
                    .foregroundStyle(Theme.faint)
                ZStack {
                    RoundedRectangle(cornerRadius: 8).stroke(Theme.faint.opacity(0.5), lineWidth: 1)
                        .frame(height: 150).rotationEffect(.degrees(-4))
                    SlantedBar().fill(Theme.faint.opacity(0.2)).frame(width: 2, height: 145)
                        .rotationEffect(.degrees(12))
                    Circle().fill(Theme.youFill).frame(width: 92, height: 92)
                    Circle().trim(from: 0, to: progress).stroke(Theme.youFill, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 106, height: 106).rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : Motion.press, value: progress)
                    Text("H/").font(.score(size: 36)).foregroundStyle(Theme.onYouFill)
                    if breakingSeal {
                        Rectangle().fill(Theme.beltWell).frame(width: 8, height: 160)
                            .rotationEffect(.degrees(12)).transition(.opacity)
                    }
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
                    .foregroundStyle(Theme.faint)
            }
            .padding(28).background(Theme.beltWell, in: RoundedRectangle(cornerRadius: 20))
            Text(tapOpens ? "Hold or tap to open" : "Hold to open")
                .font(.themeLabel).frame(maxWidth: .infinity).foregroundStyle(Theme.ink)
        }
    }

    private func open() {
        guard stage == 0, !breakingSeal else { return }
        withAnimation(Motion.fade) { breakingSeal = true }
    }

    private var scorecards: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Every round.\nOn the record.").font(.score(size: 46)).foregroundStyle(Theme.ink)
            HStack {
                Text("Three rings. Three judges.")
                Spacer()
                Text("0\(cardIndex + 1) / 03").monospacedDigit()
            }.font(.themeLabel).foregroundStyle(Theme.secondary)
            ZStack {
                card(decision.cards[cardIndex], index: cardIndex).id(cardIndex).transition(.opacity)
                if stamped {
                    Text(decision.label)
                        .font(.score(size: 35)).minimumScaleFactor(0.5).lineLimit(1)
                        .padding(16)
                        .foregroundStyle(Theme.ink).background(Theme.ground)
                        .overlay(Rectangle().stroke(Theme.ink, lineWidth: 3))
                        .rotationEffect(.degrees(reduceMotion ? 0 : -12))
                        .scaleEffect(stamped ? 1 : 1.2)
                        .accessibilityIdentifier("competition.judges.stamp")
                }
            }
            HStack {
                ForEach(0..<3) { index in
                    Text(["MOVE", "EXERCISE", "STAND"][index])
                        .foregroundStyle(index <= cardIndex ? Theme.ink : Theme.faint)
                    if index < 2 { Spacer() }
                }
            }.font(.themeLabel)
        }
    }

    private func card(_ card: CompetitionJudgeCard, index: Int) -> some View {
        VStack(spacing: 14) {
            HStack {
                Circle().fill([Theme.move, Theme.exercise, Theme.stand][index]).frame(width: 10, height: 10)
                Text("Judge \(["Move", "Exercise", "Stand"][index])").font(.themeLabel)
                Spacer()
                Text("OFFICIAL").font(.themeLabel).foregroundStyle(Theme.secondary)
            }
            Divider()
            HStack {
                Text("ROUND").frame(maxWidth: .infinity, alignment: .leading)
                Text("YOU").foregroundStyle(Theme.you).frame(maxWidth: .infinity)
                Text(competition.opponentDisplayName.uppercased()).frame(maxWidth: .infinity)
            }.font(.themeLabel).lineLimit(1).minimumScaleFactor(0.5)
            ForEach(0..<7) { row in
                HStack {
                    Text(dayLabel(row)).font(.themeLabel).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(row < rows ? score(card.you, row) : "—")
                        .foregroundStyle(Theme.you).frame(maxWidth: .infinity)
                    Text(row < rows ? score(card.them, row) : "—")
                        .frame(maxWidth: .infinity)
                }.font(.score(size: 24).monospacedDigit())
            }
            Divider()
            HStack {
                Text("TOTAL").font(.themeLabel).frame(maxWidth: .infinity, alignment: .leading)
                total(card.yourTotal, wins: (card.yourTotal ?? -1) > (card.theirTotal ?? .infinity), own: true)
                total(card.theirTotal, wins: (card.theirTotal ?? -1) > (card.yourTotal ?? .infinity), own: false)
            }.opacity(rows == 7 ? 1 : 0)
        }
        .foregroundStyle(Theme.ink).padding(20)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private func total(_ value: Double?, wins: Bool, own: Bool) -> some View {
        Text(value.map { competitionPointsText($0) } ?? "—")
            .font(.score(size: 27)).minimumScaleFactor(0.5).lineLimit(1)
            .foregroundStyle(own ? Theme.you : Theme.ink)
            .padding(.vertical, 8).frame(maxWidth: .infinity)
            .overlay { if wins { Ellipse().stroke(own ? Theme.youFill : Theme.ink, lineWidth: 2) } }
    }

    private func score(_ values: [Double?], _ row: Int) -> String {
        values.indices.contains(row) ? values[row].map { competitionPointsText($0) } ?? "—" : "—"
    }

    private func dayLabel(_ row: Int) -> String {
        let days = competition.days.sorted { $0.ordinal < $1.ordinal }
        guard days.indices.contains(row) else { return "\(row + 1)" }
        return String(weekdayName(days[row].day).prefix(3))
    }

    private var handRaise: some View {
        VStack(spacing: 20) {
            Text(raised ? winner : "THE DECISION…")
                .font(.score(size: 44)).multilineTextAlignment(.center)
                .foregroundStyle(decision.outcome == .win ? Theme.you : Theme.ink)
                .minimumScaleFactor(0.5).lineLimit(2)
                .accessibilityIdentifier("competition.judges.winner")
            Text(decision.label).font(.themeLabel).tracking(2).foregroundStyle(Theme.secondary)
            CompetitionJudgesFigures(
                leftRaised: raised && decision.outcome != .loss,
                rightRaised: raised && decision.outcome != .win,
                leftLost: raised && decision.outcome == .loss,
                rightLost: raised && decision.outcome == .win
            )
            .frame(height: 310)
            .background(Theme.beltWell, in: RoundedRectangle(cornerRadius: 20))
            .accessibilityHidden(true)
            HStack {
                VStack { Text("YOU").font(.themeLabel); Text(competitionPointsText(competition.userPoints)).font(.score(size: 42)) }
                    .foregroundStyle(Theme.you)
                Spacer()
                Text("—").foregroundStyle(Theme.secondary)
                Spacer()
                VStack { Text(competition.opponentDisplayName.uppercased()).font(.themeLabel); Text(competitionPointsText(competition.opponentPoints)).font(.score(size: 42)) }
                    .foregroundStyle(Theme.ink)
            }
            Text("The combined ring points decide the match.").font(.footnote).foregroundStyle(Theme.secondary)
        }
    }
}

/// Original geometric figures. Both referee hands share the fighters' wrist
/// endpoints, so contact stays intact throughout the raise.
private struct CompetitionJudgesFigures: View, Animatable {
    private var left: Double
    private var right: Double
    private var leftDrop: Double
    private var rightDrop: Double

    init(leftRaised: Bool, rightRaised: Bool, leftLost: Bool, rightLost: Bool) {
        left = leftRaised ? 1 : 0; right = rightRaised ? 1 : 0
        leftDrop = leftLost ? 1 : 0; rightDrop = rightLost ? 1 : 0
    }
    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { .init(.init(left, right), .init(leftDrop, rightDrop)) }
        set { left = newValue.first.first; right = newValue.first.second; leftDrop = newValue.second.first; rightDrop = newValue.second.second }
    }
    var body: some View {
        Canvas { context, size in
            let sx = size.width / 340, sy = size.height / 310
            context.scaleBy(x: sx, y: sy)
            func line(_ points: [CGPoint], color: Color, width: CGFloat) {
                var path = Path(); path.addLines(points)
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
            func ellipse(_ rect: CGRect, color: Color) { context.fill(Path(ellipseIn: rect), with: .color(color)) }
            line([.init(x: 20, y: 270), .init(x: 320, y: 270)], color: Theme.faint.opacity(0.25), width: 1)
            let wrists = [CGPoint(x: 116, y: 183 - 130 * left), CGPoint(x: 224, y: 183 - 130 * right)]
            for index in 0..<2 {
                let x: CGFloat = index == 0 ? 70 : 270
                let inward: CGFloat = index == 0 ? 1 : -1
                let color = index == 0 ? Theme.youFill : Theme.secondary
                let drop = index == 0 ? leftDrop : rightDrop
                let wrist = wrists[index]
                line([.init(x: x - 13, y: 206), .init(x: x - 19, y: 267)], color: color, width: 22)
                line([.init(x: x + 13, y: 206), .init(x: x + 19, y: 267)], color: color, width: 22)
                var torso = Path()
                torso.move(to: .init(x: x - 29, y: 128)); torso.addLine(to: .init(x: x + 29, y: 128))
                torso.addLine(to: .init(x: x + 20, y: 209)); torso.addLine(to: .init(x: x - 20, y: 209)); torso.closeSubpath()
                context.fill(torso, with: .color(color))
                ellipse(CGRect(x: x - 17, y: 81 + 12 * drop, width: 34, height: 39), color: color)
                line([.init(x: x - inward * 25, y: 140), .init(x: x - inward * 36, y: 184), .init(x: x - inward * 28, y: 210)], color: color, width: 15)
                line([.init(x: x + inward * 24, y: 141), .init(x: x + inward * 40, y: (141 + wrist.y) / 2), wrist], color: color, width: 16)
                ellipse(CGRect(x: wrist.x - 11, y: wrist.y - 12, width: 22, height: 24), color: color)
                line([.init(x: x - 19, y: 190), .init(x: x + 19, y: 190)], color: Theme.beltWell, width: 5)
            }
            // Referee behind the joined wrists, neutral stripes and an upright stance.
            line([.init(x: 159, y: 209), .init(x: 153, y: 267)], color: Theme.faint, width: 16)
            line([.init(x: 181, y: 209), .init(x: 187, y: 267)], color: Theme.faint, width: 16)
            context.fill(Path(roundedRect: CGRect(x: 146, y: 132, width: 48, height: 81), cornerRadius: 9), with: .color(Theme.faint))
            for x in [155, 170, 185] { line([.init(x: x, y: 139), .init(x: x, y: 202)], color: Theme.beltWell, width: 5) }
            ellipse(CGRect(x: 156, y: 94, width: 28, height: 31), color: Theme.faint)
            for (index, wrist) in wrists.enumerated() {
                let shoulder: CGFloat = index == 0 ? 149 : 191
                line([.init(x: shoulder, y: 144), .init(x: (shoulder + wrist.x) / 2, y: (144 + wrist.y) / 2 + 8), wrist], color: Theme.faint, width: 12)
                ellipse(CGRect(x: wrist.x - 6, y: wrist.y + 4, width: 12, height: 12), color: Theme.faint)
            }
        }
    }
}
