import CompetitionCore
import SwiftUI

/// The beat before a match: you and them collide on the slash, then the
/// screen splits open onto the match, which is live underneath throughout.
/// Automatically once per match per device; replayable from the match menu.

/// What the intro says.
struct CompetitionVersusIntroContent: Equatable {
    let id: CompetitionID
    let you: String
    let them: String
    /// "1–4"; nil on a first fight.
    let yourTape: String?
    let theirTape: String?
    let holder: CompetitionBeltHolder?
    /// "First fight", "Title on the line", or nil for a rematch with no belt.
    let headline: String?
    let dayLine: String
    /// Their account, for their photo.
    var themPhoto: UUID? = nil

    var announcement: String { "You versus \(them). \(dayLine)." }
}

/// The photos the intro starts with. It decides once: a photo that lands
/// mid-intro waits for the match screen.
private struct VersusPhotos {
    var you: ProfilePhoto?
    var them: ProfilePhoto?
}

/// Autoplays only when scheduled or on Day 1. A replay can show a later day.
func competitionVersusIntroContent(
    _ competition: LocalCompetitionPresentation,
    in publication: LocalCompetitionPublication,
    locale: Locale = .current,
    isReplay: Bool = false
) -> CompetitionVersusIntroContent? {
    guard publication.source == .remoteParticipants, !competition.isPractice else { return nil }
    let dayLine: String
    switch competition.lifecycle {
    case .scheduled:
        guard let first = competition.days.first?.day
            ?? competition.acceptedConfiguration?.schedule.startDay
        else { return nil }
        dayLine = "Day 1 is \(weekdayName(first, locale: locale))"
    case .active(dayOrdinal: 1):
        dayLine = "Day 1 starts now"
    case .active, .endsToday, .tallying:
        guard isReplay else { return nil }
        dayLine = competitionStatusText(competition, style: .card, locale: locale).title
    default:
        return nil
    }

    let competitions = publication.dashboard.competitions
    let record = competitionOpponentRecords(competitions)
        .first { $0.opponentIdentity == competition.opponentIdentity }
    // Going in is only known once earlier matches with them have finished.
    let waits = competitionBeltWaitsOnAnEarlierMatch(competition, in: competitions)
    let holder = waits ? nil : record?.belt.holder
    let defenses = record.map { competitionVersusDefenses($0.belt) } ?? 0
    func tape(_ text: String?, _ side: CompetitionBeltHolder) -> String? {
        guard let text, holder == side, defenses > 0 else { return text }
        return "\(text) · \(defenses) \(defenses == 1 ? "defense" : "defenses")"
    }
    let theirRecord = record.map {
        ([$0.losses, $0.wins] + ($0.ties > 0 ? [$0.ties] : []))
            .map(String.init).joined(separator: "–")
    }
    return CompetitionVersusIntroContent(
        id: competition.id,
        you: competition.ownerDisplayName,
        them: competition.opponentDisplayName,
        yourTape: tape(record?.text, .you),
        theirTape: tape(theirRecord, .them),
        holder: holder,
        headline: holder != nil ? "Title on the line"
            : record == nil && !waits ? "First fight" : nil,
        dayLine: dayLine,
        themPhoto: competition.opponentProfileID
    )
}

/// The holder's title defenses in the current reign.
private func competitionVersusDefenses(_ belt: CompetitionBelt) -> Int {
    belt.holder == nil ? 0 : belt.current?.defenses ?? 0
}

/// Off in the Test Labs and UI tests unless `--versus-intro` turns it on, so
/// their matches open as they always did.
enum CompetitionVersusIntroGate {
    static let isEnabled: Bool = {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--local-competition-test-lab")
            || arguments.contains("--multi-user-competition-test-lab") {
            // Once per process: the marks persist otherwise.
            UserDefaults.standard.removeObject(forKey: CompetitionMotionSeen.storageKey)
            return arguments.contains("--versus-intro")
        }
#endif
        return true
    }()

#if DEBUG
    /// VoiceOver doesn't run in a simulator: `--versus-voiceover` takes its
    /// path and leaves the announcement here for the lab to show.
    static let assumesVoiceOver = ProcessInfo.processInfo.arguments.contains("--versus-voiceover")
    static let announcedKey = "healthcomp.versusAnnounced"
    /// `--versus-hold` keeps the composed screen up until a tap: XCUITest
    /// only looks once the app idles, and by then the intro is gone.
    static let holds = ProcessInfo.processInfo.arguments.contains("--versus-hold")
#else
    static let assumesVoiceOver = false
    static let holds = false
#endif
}

extension View {
    /// On the NavigationStack, not a destination: only this covers the bar.
    func competitionVersusIntro(
        matchID: CompetitionID?,
        publication: LocalCompetitionPublication?,
        isPlaying: Binding<Bool>,
        replay: Binding<Bool>
    ) -> some View {
        modifier(CompetitionVersusIntroHost(
            matchID: matchID,
            publication: publication,
            isPlaying: isPlaying,
            replay: replay
        ))
    }
}

private struct CompetitionVersusIntroHost: ViewModifier {
    let matchID: CompetitionID?
    let publication: LocalCompetitionPublication?
    @Binding var isPlaying: Bool
    @Binding var replay: Bool

    @AppStorage(CompetitionMotionSeen.storageKey)
    private var seen = CompetitionMotionSeen()
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.profilePhotos) private var photos
    @State private var playing: CompetitionVersusIntroContent?
    @State private var playingPhotos = VersusPhotos()

    /// The open match, if its intro is due. One rule covers the accepter and
    /// the sender, on arrival or in place when the other side accepts.
    private var due: CompetitionVersusIntroContent? {
        guard let matchID, !seen.hasSeen(.versus, matchID) else { return nil }
        return introContent()
    }

    private func introContent(isReplay: Bool = false) -> CompetitionVersusIntroContent? {
        guard CompetitionVersusIntroGate.isEnabled, playing == nil, scenePhase == .active,
              let matchID, let publication,
              let competition = publication.dashboard.competitions.first(where: { $0.id == matchID })
        else { return nil }
        return competitionVersusIntroContent(competition, in: publication, locale: locale, isReplay: isReplay)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if let playing {
                    CompetitionVersusIntroView(content: playing, photos: playingPhotos) {
                        self.playing = nil
                        isPlaying = false
                    }
                    // Past this the words crowd the slash. The label has them all.
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                }
            }
            .onChange(of: due, initial: true) { _, due in
                guard let due else { return }
                play(due)
            }
            .onChange(of: replay) { _, requested in
                guard requested else { return }
                replay = false
                if let intro = introContent(isReplay: true) { play(intro) }
            }
    }

    private func play(_ intro: CompetitionVersusIntroContent) {
        seen = seen.marking(.versus, intro.id)
        if voiceOver || CompetitionVersusIntroGate.assumesVoiceOver {
            announce(intro.announcement)
        } else {
            playingPhotos = VersusPhotos(you: photos.own, them: photos.photo(intro.themPhoto))
            playing = intro
            isPlaying = true
        }
    }

    private func announce(_ text: String) {
#if DEBUG
        UserDefaults.standard.set(text, forKey: CompetitionVersusIntroGate.announcedKey)
#endif
        // After the push, or VoiceOver's own reading of the new screen cuts it off.
        Task {
            try? await Task.sleep(for: .seconds(0.75))
            AccessibilityNotification.Announcement(text).post()
        }
    }
}

/// Every number of the intro lives here and in `VersusStage`, ported from the
/// approved preview: a sanctioned exception to Motion.swift, "nothing
/// scale-pops", "one haptic" and "never hold".
private enum VersusClock {
    static let slam = 0.15
    static let contact = 0.45
    static let stamp = 0.6
    static let names = 0.8
    static let tape = 1.0
    static let split = 3.68
    static let end = 4.0
    /// Everything in place, for Reduce Motion.
    static let composed = 3.67
    /// Reduce Motion's hold: a fade in, this, a fade out.
    static let reducedHold = 3.6

    static let slamCurve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.55, y: 0),
        endControlPoint: UnitPoint(x: 1, y: 0.45)
    )
    static let openCurve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.7, y: 0),
        endControlPoint: UnitPoint(x: 0.3, y: 1)
    )

    /// 0 to 1 across one beat, held at either end.
    static func ramp(_ t: Double, _ start: Double, _ duration: Double) -> Double {
        min(max((t - start) / duration, 0), 1)
    }

    /// Lit at contact and again at the split, dying fast each time.
    static func hotLine(_ t: Double) -> Double {
        switch t {
        case contact..<(contact + 0.24): 1 - ramp(t, contact, 0.24)
        case split..<(split + 0.14): 1 - ramp(t, split, 0.14)
        default: 0
        }
    }

    static func flash(_ t: Double) -> Double {
        t < contact ? 0 : 0.4 * (1 - UnitCurve.easeOut.value(at: ramp(t, contact, 0.12)))
    }

    /// The screen punch: 27 ms out, the rest of 180 ms back.
    static func punch(_ t: Double) -> Double {
        let up = UnitCurve.easeOut.value(at: ramp(t, contact, 0.027))
        let back = UnitCurve.easeOut.value(at: ramp(t, contact + 0.027, 0.153))
        return 1 + 0.035 * (up - back)
    }
}

/// The preview's 393×880 layout on any screen. The slash runs through
/// `center` at 12 degrees, and the name boxes stop short of it at their
/// nearest corner, so no name can reach it.
private struct VersusStage {
    static let slope = tan(12 * Double.pi / 180)

    let size: CGSize
    let insets: EdgeInsets
    let labelLine: CGFloat

    var kx: CGFloat { size.width / 393 }
    var ky: CGFloat { size.height / 880 }
    var k: CGFloat { min(kx, ky) }
    var footerTop: CGFloat { size.height - (42 + 2 * labelLine + max(insets.bottom, 8) + 12) }
    var center: CGPoint { CGPoint(x: size.width / 2, y: footerTop / 2) }

    func slashX(_ y: CGFloat) -> CGFloat { center.x + (center.y - y) * Self.slope }

    /// `holdsBelt` makes room for the belt under the name.
    func yourBox(holdsBelt: Bool) -> CGRect {
        let top = insets.top + 8
        let bottom = top + (holdsBelt ? 200 : 150) * ky
        return CGRect(x: 20, y: top, width: slashX(bottom) - 21 - 20, height: bottom - top)
    }

    func theirBox(holdsBelt: Bool) -> CGRect {
        let bottom = footerTop - 14
        let top = bottom - (holdsBelt ? 200 : 178) * ky
        let left = slashX(top) + 21
        return CGRect(x: left, y: top, width: size.width - 20 - left, height: bottom - top)
    }

    /// The giant initial's centre, kept clear of its own side's words: they
    /// share its colour, so any overlap would hide them. A belt or a large
    /// text size moves the initial, never the words.
    func initialY(isYours: Bool, holdsBelt: Bool) -> CGFloat {
        // SF Pro's capitals are about 0.7 em tall; 12 covers the creep.
        let half = 0.35 * 660 * k
        return isYours
            ? max(456 * ky, yourBox(holdsBelt: holdsBelt).maxY + 12 + half)
            : min(316 * ky, theirBox(holdsBelt: holdsBelt).minY - 12 - half)
    }
}

/// One side of the slash, `inset` away from it (negative overlaps it).
private struct VersusSlashSide: Shape {
    let isYours: Bool
    let centerY: CGFloat
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        func x(_ y: CGFloat) -> CGFloat {
            rect.midX + (centerY - y) * VersusStage.slope + (isYours ? -inset : inset)
        }
        let edge = isYours ? rect.minX : rect.maxX
        return Path { path in
            path.addLines([
                CGPoint(x: edge, y: rect.minY),
                CGPoint(x: x(rect.minY), y: rect.minY),
                CGPoint(x: x(rect.maxY), y: rect.maxY),
                CGPoint(x: edge, y: rect.maxY),
            ])
            path.closeSubpath()
        }
    }
}

private struct CompetitionVersusIntroView: View {
    let content: CompetitionVersusIntroContent
    let photos: VersusPhotos
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
            let stage = VersusStage(
                size: CGSize(
                    width: proxy.size.width + insets.leading + insets.trailing,
                    height: proxy.size.height + insets.top + insets.bottom
                ),
                insets: insets,
                labelLine: labelLine
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
            // Always on black: dark's ink, panel and track in either mode.
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
    }

    private var isHeld: Bool { CompetitionVersusIntroGate.holds && !isSkipped }

    /// Off the same clock as the frames, so a haptic lands on its hit.
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

    /// To the split, or Reduce Motion's fade out.
    private func skip() {
        guard isHeld || !isSkipped && Date().timeIntervalSince(start) < VersusClock.split else {
            return
        }
        start = Date().addingTimeInterval(-VersusClock.split)
        isSkipped = true
    }

    /// Each half holds the same scene, cut on the slash.
    private func frame(_ stage: VersusStage, at t: Double) -> some View {
        let open = VersusClock.openCurve.value(
            at: VersusClock.ramp(t, VersusClock.split, VersusClock.end - VersusClock.split)
        ) * (stage.size.width + 40)
        return ZStack {
            scene(stage, at: t)
                .clipShape(VersusSlashSide(isYours: true, centerY: stage.center.y, inset: -1))
                .offset(x: -open)
            scene(stage, at: t)
                .clipShape(VersusSlashSide(isYours: false, centerY: stage.center.y, inset: -1))
                .offset(x: open)
            Color.white.opacity(VersusClock.flash(t))
            Path { path in
                path.move(to: CGPoint(x: stage.slashX(0), y: 0))
                path.addLine(to: CGPoint(x: stage.slashX(stage.size.height), y: stage.size.height))
            }
            .stroke(.white, lineWidth: 7)
            .shadow(color: .white, radius: 7)
            .shadow(color: .white, radius: 18)
            .opacity(VersusClock.hotLine(t))
        }
        .scaleEffect(VersusClock.punch(t))
    }

    private func scene(_ stage: VersusStage, at t: Double) -> some View {
        ZStack {
            Color.black
            panel(stage, isYours: true, at: t)
            panel(stage, isYours: false, at: t)
            who(stage, isYours: true, at: t)
            who(stage, isYours: false, at: t)
            footer(stage, at: t)
            stamp(stage, at: t)
        }
    }

    /// A slanted panel with a giant cropped initial, or the photo in its
    /// place as a duotone, that creeps through the hold.
    private func panel(_ stage: VersusStage, isYours: Bool, at t: Double) -> some View {
        let side: CGFloat = isYours ? -1 : 1
        let away = 1 - VersusClock.slamCurve.value(
            at: VersusClock.ramp(t, VersusClock.slam, VersusClock.contact - VersusClock.slam)
        )
        let creep = VersusClock.ramp(t, VersusClock.contact, VersusClock.split - VersusClock.contact)
        let dx = stage.size.width + 60
        let holdsBelt = content.holder == (isYours ? .you : .them)
        let center = CGPoint(
            x: (isYours ? 240 : 150) * stage.kx,
            y: stage.initialY(isYours: isYours, holdsBelt: holdsBelt)
        )
        return ZStack {
            isYours ? Theme.youFill : Theme.panel
            if let photo = isYours ? photos.you : photos.them {
                // The initial's square, so the face stays clear of the name.
                let image = Image(uiImage: photo.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 470 * stage.k, height: 470 * stage.k)
                    .clipped()
                    .grayscale(1)
                Group {
                    if isYours {
                        // Multiplied into amber: amber still means you.
                        image.contrast(1.15).blendMode(.multiply)
                    } else {
                        image.opacity(0.55)
                    }
                }
                // Anchored like the letter: outward from the same edge.
                .frame(width: 0, height: 0, alignment: isYours ? .trailing : .leading)
                .offset(x: -side * (12 - 14 * creep), y: side * (6 - 7 * creep))
                .position(center)
            } else {
                Text(String((isYours ? content.you : content.them).prefix(1)).uppercased())
                    .font(.score(size: 660 * stage.k))
                    .foregroundStyle(isYours ? Theme.onYouFill : Theme.ink)
                    .fixedSize()
                    .frame(width: 0, height: 0, alignment: isYours ? .trailing : .leading)
                    .offset(x: -side * (12 - 14 * creep), y: side * (6 - 7 * creep))
                    .position(center)
            }
        }
        .clipShape(VersusSlashSide(isYours: isYours, centerY: stage.center.y, inset: 5))
        .offset(x: side * away * dx, y: side * away * dx * 0.2)
    }

    /// The name, and under it the tape line and belt.
    private func who(_ stage: VersusStage, isYours: Bool, at t: Double) -> some View {
        let holdsBelt = content.holder == (isYours ? .you : .them)
        let box = isYours
            ? stage.yourBox(holdsBelt: holdsBelt)
            : stage.theirBox(holdsBelt: holdsBelt)
        let side: CGFloat = isYours ? -1 : 1
        let landing = Spring(duration: 0.32, bounce: 0)
            .value(target: 1.0, time: max(t - VersusClock.names, 0))
        let tape = isYours ? content.yourTape : content.theirTape
        // A line per word and after each hyphen, so no word ever breaks.
        let name = (isYours ? content.you : content.them).uppercased()
            .replacingOccurrences(of: "-", with: "-\n")
            .replacingOccurrences(of: " ", with: "\n")
        return VStack(alignment: isYours ? .leading : .trailing, spacing: 8 * stage.k) {
            Text(name)
                .font(.score(size: 128 * stage.k))
                .lineLimit(name.split(separator: "\n").count)
                .minimumScaleFactor(0.1)
                .multilineTextAlignment(isYours ? .leading : .trailing)
                .offset(x: side * 56 * (1 - landing))
                .opacity(t < VersusClock.names ? 0 : landing)
            if tape != nil || holdsBelt {
                VStack(alignment: isYours ? .leading : .trailing, spacing: 6 * stage.k) {
                    if holdsBelt {
                        Image(isYours ? "BeltHeroGold" : "BeltHeroPewter")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 220 * stage.k)
                            .offset(x: side * 16)
                            .frame(width: box.width, alignment: isYours ? .leading : .trailing)
                    }
                    if let tape {
                        Text(tape)
                            .font(.title3.weight(.heavy).width(.condensed))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                }
                .opacity(VersusClock.ramp(t, VersusClock.tape, 0.2))
                .layoutPriority(1)
            }
        }
        .foregroundStyle(isYours ? Theme.onYouFill : Theme.ink)
        .frame(
            width: box.width,
            height: box.height,
            alignment: isYours ? .topLeading : .bottomTrailing
        )
        .position(x: box.midX, y: box.midY)
    }

    /// The event, the slanted bar and the day. A beat, not a real wait.
    private func footer(_ stage: VersusStage, at t: Double) -> some View {
        let width = stage.size.width - 48
        let fill = VersusClock.ramp(t, VersusClock.tape, VersusClock.split - VersusClock.tape)
        return VStack(alignment: .trailing, spacing: 8) {
            Text(content.headline ?? " ")
                .font(.subheadline.weight(.heavy).width(.condensed))
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(Theme.ink)
            ZStack(alignment: .leading) {
                SlantedBar().fill(Theme.track)
                SlantedBar().fill(Theme.ink).frame(width: width * fill)
            }
            .frame(height: 10)
            Text(content.dayLine)
                .font(.subheadline.weight(.bold).width(.condensed))
                .tracking(0.4)
                .foregroundStyle(Theme.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .frame(width: width)
        .opacity(VersusClock.ramp(t, VersusClock.tape, 0.2))
        .padding(.top, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .offset(y: stage.footerTop)
    }

    /// VS, the one scale-in the app allows.
    private func stamp(_ stage: VersusStage, at t: Double) -> some View {
        let landed = VersusClock.slamCurve.value(at: VersusClock.ramp(t, VersusClock.stamp, 0.12))
        let height = 100 * stage.k
        return ZStack {
            SlantedBar().fill(.black)
            Text("VS")
                .font(.score(size: 92 * stage.k))
                .foregroundStyle(.white)
                .fixedSize()
                .frame(height: height)
                .transformEffect(CGAffineTransform(
                    a: 1, b: 0, c: -VersusStage.slope, d: 1,
                    tx: VersusStage.slope * height / 2, ty: 0
                ))
        }
        .frame(width: 132 * stage.k, height: height)
        .scaleEffect(2.6 - 1.6 * landed)
        .opacity(landed)
        .position(stage.center)
    }
}
