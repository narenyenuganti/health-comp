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
            detail: "\(name)'s reign: \(competitionReignText(weeks: weeks, defenses: defenses))"
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
        isFirstView: Bool,
        replay: Binding<Bool> = .constant(false),
        onFinished: @escaping () -> Void
    ) -> some View {
        modifier(CompetitionBeltCeremony(
            event: event,
            opponentName: opponentName,
            isFirstView: isFirstView,
            replay: replay,
            onFinished: onFinished
        ))
    }
}

private struct CompetitionBeltCeremony: ViewModifier {
    let event: CompetitionBeltEvent?
    let opponentName: String
    let isFirstView: Bool
    @Binding var replay: Bool
    let onFinished: () -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    /// Latches the first-view decision: `isFirstView` flips when the seen
    /// store is written.
    @State private var didStart = false
    @State private var showing: CompetitionBeltCeremonyScript?
    /// Black under the cover, so the result isn't read before it comes up.
    @State private var isBlacked = false
    @State private var isReplay = false

    private var script: CompetitionBeltCeremonyScript? {
        competitionBeltCeremonyCanPlay(event, opponentName: opponentName)
            ? competitionBeltCeremonyScript(event, opponentName: opponentName)
            : nil
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if isBlacked || (!didStart && isFirstView && script != nil && !voiceOver) {
                    Color.black.ignoresSafeArea()
                }
            }
            .fullScreenCover(item: $showing) { script in
                CompetitionBeltCeremonyPlayer(
                    script: script,
                    onLeaving: finished,
                    onGone: { present(nil) }
                )
                .presentationBackground(.clear)
            }
            .onAppear {
                guard !didStart else { return }
                didStart = true
                if isFirstView, let script {
                    play(script)
                } else {
                    onFinished()
                }
            }
            .onChange(of: replay) { _, isOn in
                guard isOn else { return }
                replay = false
                isReplay = true
                if let script { play(script) }
            }
    }

    private func play(_ script: CompetitionBeltCeremonyScript) {
        if voiceOver {
            AccessibilityNotification.Announcement(script.announcement).post()
            finished()
        } else {
            isBlacked = true
            present(script)
        }
    }

    private func finished() {
        isBlacked = false
        if !isReplay { onFinished() }
        isReplay = false
    }

    // The cover has its own fade, so the system's slide is switched off.
    private func present(_ script: CompetitionBeltCeremonyScript?) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { showing = script }
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
