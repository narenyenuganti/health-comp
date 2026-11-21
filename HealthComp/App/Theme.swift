import SwiftUI
import UIKit

enum Theme {
    static let move = Color(uiColor: UIColor(hex: 0xE4003A))
    static let exercise = Color(uiColor: UIColor(hex: 0x009A4E))
    static let stand = Color(uiColor: UIColor(hex: 0x0072BC))
    static let sleep = dynamic(light: 0x5856D6, dark: 0x7D7AFF)

    static let you = dynamic(light: 0x8F5C00, dark: 0xF2A100)
    static let youFill = Color(uiColor: UIColor(hex: 0xF2A100))
    static let onYouFill = Color(uiColor: UIColor(hex: 0x111111))

    static let inkUI = UIColor(light: 0x111111, dark: 0xF5F5F0)
    static let groundUI = UIColor(light: 0xFAFAF7, dark: 0x0F0F10)
    static let ink = Color(uiColor: inkUI)
    static let onInk = dynamic(light: 0xFAFAF7, dark: 0x0F0F10)
    static let secondary = dynamic(light: 0x5E5E62, dark: 0xA3A3A8, highContrast: (0x3A3A40, 0xCFCFC9))
    static let tertiary = dynamic(light: 0x66666B, dark: 0x8E8E93, highContrast: (0x5E5E62, 0xA3A3A8))
    static let faint = dynamic(light: 0xB8B8B2, dark: 0x48484D, highContrast: (0x8E8E93, 0x6E6E73))
    static let ground = Color(uiColor: groundUI)
    static let panel = dynamic(light: 0xEFEFEA, dark: 0x19191B)
    static let control = dynamic(light: 0xE6E6E0, dark: 0x222225)
    static let hairline = dynamic(light: 0xDEDED8, dark: 0x2C2C30, highContrast: (0xB8B8B2, 0x48484D))
    static let track = dynamic(light: 0xE2E2DC, dark: 0x26262A, highContrast: (0xCFCFC9, 0x3A3A40))
    static let outline = dynamic(light: 0xCFCFC9, dark: 0x3A3A40, highContrast: (0x8E8E93, 0x6E6E73))
    static let beltWell = dynamic(light: 0x0F0F10, dark: 0x19191B)

    private static func dynamic(
        light: UInt32,
        dark: UInt32,
        highContrast: (light: UInt32, dark: UInt32)? = nil
    ) -> Color {
        Color(uiColor: UIColor(light: light, dark: dark, highContrast: highContrast))
    }

#if !os(watchOS)
    static func applyNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = groundUI
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [.foregroundColor: inkUI]
        appearance.largeTitleTextAttributes = [.foregroundColor: inkUI]
        let bar = UINavigationBar.appearance()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactAppearance = appearance
    }
#endif
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    convenience init(
        light: UInt32,
        dark: UInt32,
        highContrast: (light: UInt32, dark: UInt32)? = nil
    ) {
#if os(watchOS)
        self.init(hex: dark)
#else
        self.init { traits in
            let standard: (light: UInt32, dark: UInt32) = (light: light, dark: dark)
            let values = traits.accessibilityContrast == .high
                ? highContrast ?? standard : standard
            return UIColor(hex: traits.userInterfaceStyle == .dark ? values.dark : values.light)
        }
#endif
    }
}

extension Font {
    static func score(size: CGFloat) -> Font {
#if os(watchOS)
        Font(UIFont.preferredFont(forTextStyle: .largeTitle).withSize(size))
            .weight(.heavy).width(.compressed)
#else
        .system(size: size, weight: .heavy).width(.compressed)
#endif
    }

    static let themeLabel = Font.footnote.weight(.bold).width(.condensed)
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "healthcomp.appearance"

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct BrandMark: View {
    var grows = false
    var spins = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var plays = 0

    var body: some View {
        KeyframeAnimator(initialValue: [1.0, 1, 1], trigger: plays) { growth in
            ZStack {
                ForEach(0..<3, id: \.self) { bar in
                    MarkPolygon(MarkPolygon.bars[bar], growth: growth[bar])
                        .fill(MarkPolygon.barColors[bar])
                }
                MarkPolygon(MarkPolygon.block)
                    .fill(Theme.ink)
            }
        } keyframes: { _ in
            KeyframeTrack(\.[0]) { Self.grow(after: 0) }
            KeyframeTrack(\.[1]) { Self.grow(after: 0.15) }
            KeyframeTrack(\.[2]) { Self.grow(after: 0.3) }
        }
        .aspectRatio(1.25, contentMode: .fit)
        .contentShape(Rectangle())
        .onAppear(perform: play)
        .task(id: spins) {
            while spins, !reduceMotion, !Task.isCancelled {
                plays += 1
                try? await Task.sleep(for: .seconds(0.75))
            }
        }
        .gesture(TapGesture().onEnded(play), including: grows ? .all : .subviews)
        .accessibilityHidden(true)
    }

    private func play() {
        if grows && !reduceMotion { plays += 1 }
    }

    @KeyframeTrackContentBuilder<Double>
    private static func grow(after delay: Double) -> some KeyframeTrackContent<Double> {
        MoveKeyframe(0)
        LinearKeyframe(0, duration: delay)
        LinearKeyframe(1, duration: 0.45, timingCurve: .bezier(
            startControlPoint: UnitPoint(x: 0.25, y: 1.2),
            endControlPoint: UnitPoint(x: 0.5, y: 1)
        ))
    }
}

struct MarkPolygon: Shape {
    static let bars: [[(CGFloat, CGFloat)]] = [
        [(17.4, 8), (57.4, 8), (53.8, 26), (13.8, 26)],
        [(22.8, 31), (52.8, 31), (49.2, 49), (19.2, 49)],
        [(12.2, 54), (48.2, 54), (44.6, 72), (8.6, 72)],
    ]
    static let barColors = [Theme.move, Theme.exercise, Theme.stand]
    static let block: [(CGFloat, CGFloat)] = [(63.4, 8), (91.4, 8), (78.6, 72), (50.6, 72)]

    let points: [CGPoint]
    let growth: CGFloat
    let shift: CGFloat
    let stretch: CGFloat

    init(
        _ points: [(CGFloat, CGFloat)],
        growth: CGFloat = 1,
        shift: CGFloat = 0,
        stretch: CGFloat = 1
    ) {
        self.points = points.map { CGPoint(x: $0.0, y: $0.1) }
        self.growth = growth
        self.shift = shift
        self.stretch = stretch
    }

    func path(in rect: CGRect) -> Path {
        var points = points
        if shift > 0 {
            for (left, right) in [(0, 1), (3, 2)] {
                let width = points[right].x - points[left].x
                points[left].x += shift
                points[right].x = points[left].x + width * stretch
            }
        } else {
            for (left, right) in [(0, 1), (3, 2)] {
                let width = points[right].x - points[left].x
                points[right].x += shift
                points[left].x = points[right].x - width * growth * stretch
            }
        }
        return Path { path in
            path.addLines(points.map {
                CGPoint(
                    x: rect.minX + $0.x / 100 * rect.width,
                    y: rect.minY + $0.y / 80 * rect.height
                )
            })
            path.closeSubpath()
        }
    }
}

struct SlantedBar: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.height * tan(12 * .pi / 180) / 2
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX + inset, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX - inset, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.width(.condensed))
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.onInk)
            .tint(Theme.onInk)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                Theme.ink,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .pressFeel(configuration.isPressed, isEnabled: isEnabled, reduceMotion: reduceMotion)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.width(.condensed))
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                Theme.control,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .pressFeel(configuration.isPressed, isEnabled: isEnabled, reduceMotion: reduceMotion)
    }
}

struct QuietButtonStyle: ButtonStyle {
    var color = Theme.secondary
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.width(.condensed))
            .multilineTextAlignment(.center)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .pressFeel(configuration.isPressed, isEnabled: isEnabled, reduceMotion: reduceMotion)
    }
}

private extension View {
    func pressFeel(_ isPressed: Bool, isEnabled: Bool, reduceMotion: Bool) -> some View {
        scaleEffect(isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(isEnabled ? (isPressed ? 0.8 : 1) : 0.45)
            .sensoryFeedback(.impact(weight: .light), trigger: isPressed) { _, pressed in pressed }
            .animation(Motion.press, value: isPressed)
            .animation(Motion.press, value: isEnabled)
    }
}

struct BusyLabel: View {
    let title: String
    let isBusy: Bool

    @State private var showsSpinner = false

    init(_ title: String, isBusy: Bool) {
        self.title = title
        self.isBusy = isBusy
    }

    var body: some View {
        ZStack {
            Text(title)
                .opacity(showsSpinner ? 0 : 1)
            ProgressView()
                .opacity(showsSpinner ? 1 : 0)
                .accessibilityHidden(true)
        }
        .onChange(of: isBusy, initial: true) { _, isBusy in
            withAnimation(isBusy ? Motion.late : Motion.fade) { showsSpinner = isBusy }
        }
    }
}

struct SectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .themeLabel()
            .foregroundStyle(Theme.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

struct DisclosureChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(Theme.tertiary)
            .accessibilityHidden(true)
    }
}

extension View {
    func themeLabel(tracking: CGFloat = 1.2) -> some View {
        font(.themeLabel).tracking(tracking)
    }

    func themePanel(cornerRadius: CGFloat = 20) -> some View {
        background(
            Theme.panel,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}
