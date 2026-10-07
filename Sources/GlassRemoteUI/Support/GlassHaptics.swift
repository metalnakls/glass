import AppKit

@MainActor enum GlassHaptics {
    enum Action: String { case playPause, swipe, drag, selection }
    private static var lastFeedback = Date.distantPast
    static func perform(_ action: Action) {
        guard AppearancePreferences.shared.value(for: "GlassHaptics.enabled", fallback: true),
              AppearancePreferences.shared.value(for: "GlassHaptics." + action.rawValue, fallback: true),
              Date().timeIntervalSince(lastFeedback) > 0.06 else { return }
        lastFeedback = Date()
        NSHapticFeedbackManager.defaultPerformer.perform(action == .drag ? .alignment : .generic, performanceTime: .now)
    }
}
