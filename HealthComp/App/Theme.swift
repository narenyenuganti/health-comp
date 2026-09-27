import SwiftUI
import UIKit

/// L2 · Ring code. Color always means you: Move, Exercise and Stand for your
/// ring detail, amber for your score. The opponent and all structure stay
/// neutral, so no color here carries a second meaning.
enum Theme {
    static let move = Color(uiColor: UIColor(hex: 0xE4003A))
    static let exercise = Color(uiColor: UIColor(hex: 0x009A4E))
    static let stand = Color(uiColor: UIColor(hex: 0x0072BC))

    /// Your score, name and wins. Light mode darkens amber so text keeps 4.5:1.
    static let you = dynamic(light: 0x9C6500, dark: 0xF2A100)
    /// Amber fills stay bright in both modes; put `onYouFill` content on them.
    static let youFill = Color(uiColor: UIColor(hex: 0xF2A100))
    static let onYouFill = Color(uiColor: UIColor(hex: 0x111111))

    static let inkUI = UIColor(light: 0x111111, dark: 0xF5F5F0)
    static let groundUI = UIColor(light: 0xFAFAF7, dark: 0x0F0F10)
    /// Primary text, the opponent, and neutral primary buttons.
    static let ink = Color(uiColor: inkUI)
    static let onInk = dynamic(light: 0xFAFAF7, dark: 0x0F0F10)
    static let secondary = dynamic(light: 0x5E5E62, dark: 0xA3A3A8)
    static let tertiary = dynamic(light: 0x6E6E73, dark: 0x8E8E93)
    static let faint = dynamic(light: 0xB8B8B2, dark: 0x48484D)
    static let ground = Color(uiColor: groundUI)
    static let panel = dynamic(light: 0xEFEFEA, dark: 0x19191B)
    static let control = dynamic(light: 0xE6E6E0, dark: 0x222225)
    static let hairline = dynamic(light: 0xDEDED8, dark: 0x2C2C30)
    static let track = dynamic(light: 0xE2E2DC, dark: 0x26262A)
    static let outline = dynamic(light: 0xCFCFC9, dark: 0x3A3A40)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor(light: light, dark: dark))
    }

    /// Opaque bars in the ground color so each screen reads as one surface.
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

    convenience init(light: UInt32, dark: UInt32) {
        self.init { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        }
    }
}

extension Font {
    /// Scoreboard numerals: SF Pro Compressed, heavy. Size it with
    /// `@ScaledMetric` so it still follows Dynamic Type.
    static func score(size: CGFloat) -> Font {
        .system(size: size, weight: .heavy).width(.compressed)
    }

    /// Section and status labels: SF Pro Condensed, bold. Pair with `.tracking(1.2)`.
    static let themeLabel = Font.footnote.weight(.bold).width(.condensed)
}

/// The person's System / Light / Dark choice from Account → Appearance.
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

/// The mark: three ring bars (Move, Exercise, Stand) facing one neutral
/// opponent block. Geometry lives in a 100×80 box.
struct BrandMark: View {
    var body: some View {
        ZStack {
            MarkPolygon([(17.4, 8), (57.4, 8), (53.8, 26), (13.8, 26)])
                .fill(Theme.move)
            MarkPolygon([(22.8, 31), (52.8, 31), (49.2, 49), (19.2, 49)])
                .fill(Theme.exercise)
            MarkPolygon([(12.2, 54), (48.2, 54), (44.6, 72), (8.6, 72)])
                .fill(Theme.stand)
            MarkPolygon([(63.4, 8), (91.4, 8), (78.6, 72), (50.6, 72)])
                .fill(Theme.ink)
        }
        .aspectRatio(1.25, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct MarkPolygon: Shape {
    let points: [CGPoint]

    init(_ points: [(CGFloat, CGFloat)]) {
        self.points = points.map { CGPoint(x: $0.0, y: $0.1) }
    }

    func path(in rect: CGRect) -> Path {
        Path { path in
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

/// A bar with the mark's 12° slant. Half the slant extends past each side,
/// so neighbouring bars leave a slash-shaped gap like the logo.
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

/// Primary actions are neutral; color is reserved for you and your rings.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

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
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

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
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

/// A condensed section label. Pass the exact string: VoiceOver and the UI
/// tests read it as written.
struct SectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.themeLabel)
            .tracking(1.2)
            .foregroundStyle(Theme.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// The raised surface used for cards and grouped rows.
    func themePanel(cornerRadius: CGFloat = 20) -> some View {
        background(
            Theme.panel,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}
