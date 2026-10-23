import SwiftUI

/// Reusable temporary feedback: native blur replacement, consistent timing and reduced-motion support.
struct TransientStatusText: View {
    let text: String
    let message: String?
    var body: some View {
        BlurReplacementContent(identity: message ?? text) {
            Text(message.map(glassText) ?? text).textCase(nil)
        }
        .foregroundStyle(message == nil ? Color.primary : Color.secondary)
    }
    static let displayDuration: Duration = .seconds(3)
}

/// Replace a label only when its role changes, without animating live numeric updates.
struct BlurReplacementContent<Content: View>: View {
    let identity: String
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(identity: String, @ViewBuilder content: () -> Content) {
        self.identity = identity
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .leading) {
            content.id(identity).glassTransition()
        }
        .glassMotion(.replacement, value: identity)
    }
}
