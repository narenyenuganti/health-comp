import SwiftUI

enum Motion {
    static let grow = Animation.timingCurve(growCurve, duration: 0.45)
    static let growCurve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.25, y: 1.2),
        endControlPoint: UnitPoint(x: 0.5, y: 1)
    )
    static func grow(_ index: Int, of count: Int) -> Animation {
        grow.delay(0.3 * Double(index) / Double(max(count - 1, 1)))
    }
    static let settle = Animation.smooth(duration: 0.3)
    static let fade = Animation.easeOut(duration: 0.2)
    static let press = Animation.easeOut(duration: 0.14)
    static let late = Animation.easeOut(duration: 0.15).delay(0.2)
    static func beat(_ step: Int) -> Animation {
        fade.delay(0.25 + 0.15 * Double(step))
    }

    static let appear = AnyTransition.opacity.animation(fade)
    static let pendingOpacity = 0.02
    static let rain = 2.3
}

extension View {
    func moving<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(Moving(animation: animation, value: value))
    }

    func scoreRoll(_ value: Double?, id: some Hashable) -> some View {
        modifier(ScoreRoll(value: value)).id(id)
    }

    func waitingFade() -> some View {
        modifier(WaitingFade())
    }
}

private struct Moving<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion || isLuminanceReduced ? nil : animation, value: value)
    }
}

private struct ScoreRoll: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let value: Double?

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .opacity : .numericText(value: value ?? 0))
            .animation(
                isLuminanceReduced ? nil : reduceMotion ? Motion.fade : Motion.settle,
                value: value
            )
    }
}

private struct WaitingFade: ViewModifier {
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .onAppear { withAnimation(Motion.late) { isShown = true } }
    }
}
