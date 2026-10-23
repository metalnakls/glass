import SwiftUI

/// Semantic motion shared by controls and screens. Native presentation and
/// saved Tune timings remain with their existing owners.
enum GlassMotion {
    enum Role { case control, replacement, feedback, structure, selection, undo, progress, hover }
    enum Change { case replacement, leading, trailing, bottom, cardAdvance, notification }

    static let control: Animation = .smooth(duration: 0.35)
    static let replacement: Animation = .easeInOut(duration: 0.35)
    static let feedback: Animation = .easeOut(duration: 0.12)
    static let structure: Animation = .smooth(duration: 0.26, extraBounce: 0)
    static let selection: Animation = .snappy(duration: 0.28)
    static let undo: Animation = .snappy(duration: 0.22)
    static let progress: Animation = .linear(duration: 0.2)
    static let hover: Animation = .easeInOut(duration: 0.25)

    static func animation(_ role: Role, reduceMotion: Bool) -> Animation? {
        // Only a short crossfade survives Reduce Motion; movement stops.
        if reduceMotion { return role == .replacement ? .linear(duration: 0.2) : nil }
        return switch role {
        case .control: control
        case .replacement: replacement
        case .feedback: feedback
        case .structure: structure
        case .selection: selection
        case .undo: undo
        case .progress: progress
        case .hover: hover
        }
    }

    static func drop(isTargeted: Bool, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(1.0 / 3, 0, 2.0 / 3, 1, duration: isTargeted ? 0.25 : 0.30)
    }

    static func attention(active: Bool, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return active ? .easeInOut(duration: 0.14).repeatForever(autoreverses: true) : control
    }

    /// Tune's existing saved durations retain their meanings.
    static func inspectorBlur(enabled: Bool, waiting: Bool, easeIn: Double, easeOut: Double,
                              reduceMotion: Bool) -> Animation? {
        enabled && !reduceMotion ? .easeInOut(duration: max(0, waiting ? easeIn : easeOut)) : nil
    }

    /// A countdown represents elapsed time; its duration is not a UI easing token.
    static func countdown(duration: Double) -> Animation { .linear(duration: duration) }


}

private struct GlassMotionModifier<Value: Equatable>: ViewModifier {
    let role: GlassMotion.Role
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(GlassMotion.animation(role, reduceMotion: reduceMotion), value: value)
    }
}

private struct GlassTransitionModifier: ViewModifier {
    let change: GlassMotion.Change
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder func body(content: Content) -> some View {
        if reduceMotion {
            content.transition(.opacity)
        } else {
            switch change {
            case .replacement: content.transition(.blurReplace)
            case .leading: content.transition(.move(edge: .leading).combined(with: .opacity))
            case .trailing: content.transition(.move(edge: .trailing).combined(with: .opacity))
            case .bottom: content.transition(.move(edge: .bottom).combined(with: .opacity))
            case .cardAdvance:
                content.transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)))
            case .notification: content.transition(.blurReplace.combined(with: .move(edge: .bottom)))
            }
        }
    }
}

extension View {
    func glassMotion<Value: Equatable>(_ role: GlassMotion.Role, value: Value) -> some View {
        modifier(GlassMotionModifier(role: role, value: value))
    }
    func glassTransition(_ change: GlassMotion.Change = .replacement) -> some View {
        modifier(GlassTransitionModifier(change: change))
    }
}

/// Proposed values used exclusively by Motion Comparison; never applied to production.
enum GlassMotionCandidate {
    static let control: Animation = .timingCurve(0.23, 1, 0.32, 1, duration: 0.2)
    static let crossfade: Animation = .linear(duration: 0.2)
    static func press(down: Bool) -> Animation {
        .easeOut(duration: down ? 0.16 : 0.1)
    }
}
