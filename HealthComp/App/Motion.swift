import SwiftUI

/// The motion language. SwiftUI only: every target that compiles Theme.swift
/// compiles this too, the widgets and the watch included.
///
/// Choose by what changed. Length or possession, once: `grow`. Anything live
/// that moves or resizes: `settle`. Appearance only: `fade`. Touch: `press`.
/// Waiting: `.waitingFade()`. Numbers outside this file need a reason.
enum Motion {
    /// The brand curve, the only overshoot. Geometry only, never colour.
    /// First full length at about 238 ms: key haptics and later beats off that.
    static let grow = Animation.timingCurve(0.25, 1.2, 0.5, 1, duration: 0.45)
    /// The mark's envelope: 0.3 s of stagger however many items there are.
    static func grow(_ index: Int, of count: Int) -> Animation {
        grow.delay(0.3 * Double(index) / Double(max(count - 1, 1)))
    }
    /// Live change. A zero-bounce spring, so a new publication can land
    /// mid-move and retarget with velocity. Its tail runs past 0.3 s, so
    /// nothing may wait on it.
    static let settle = Animation.smooth(duration: 0.3)
    static let fade = Animation.easeOut(duration: 0.2)
    static let press = Animation.easeOut(duration: 0.14)
    /// Arrives after its cause: a wait that outlasts 200 ms, or the lead
    /// sentence on a side change. A new `id` cuts unless a parent carries the
    /// animation, so the lead needs the ZStack:
    /// `ZStack { lead.scoreRoll(abs(margin), id: side) }.animation(Motion.late, value: side)`
    static let late = Animation.easeOut(duration: 0.15).delay(0.2)
    /// The first-result clock: the mark's 150 ms step, starting once the push
    /// is mostly clear. Hero 0, score 1, everything else 2.
    /// `firstView = !seen && !archived` gates the haptic and the Announcement.
    /// `staged = firstView && !reduceMotion && !voiceOver` gates this clock.
    static func beat(_ step: Int) -> Animation {
        fade.delay(0.25 + 0.15 * Double(step))
    }

    /// The default transition. It keeps its own clock, so it lasts one fade
    /// under `settle` and survives Reduce Motion. Where old and new share a
    /// slot, give them a ZStack with `.zIndex`; a VStack would stack both.
    static let appear = AnyTransition.opacity.animation(fade)
    /// Not yet revealed, but still hittable and in the accessibility tree.
    /// At 0.001 a tap does nothing, and at 0 the element is not hittable.
    static let pendingOpacity = 0.02
}

extension View {
    /// `settle` and `grow` go through here, so Reduce Motion lands them on
    /// their final state. `fade` and `press` use plain `.animation`: a fade
    /// is what motion is replaced with.
    func moving<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(Moving(animation: animation, value: value))
    }

    /// A number that means points. `id` is the match, plus the day for
    /// per-day numbers, so one person's score or yesterday's total never
    /// rolls into another. Nil is a placeholder.
    func scoreRoll(_ value: Double?, id: some Hashable) -> some View {
        modifier(ScoreRoll(value: value)).id(id)
    }

    /// For spinners. A transition cannot do this: it does not fire when the
    /// parent mounts, which is the launch case.
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
