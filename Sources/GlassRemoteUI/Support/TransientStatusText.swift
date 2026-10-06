import SwiftUI

/// Reusable temporary feedback: native blur replacement, consistent timing and reduced-motion support.
struct TransientStatusText: View {
    let text: String
    let message: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack(alignment: .leading) {
            if reduceMotion {
                Text(glassText(message ?? text)).id(message ?? text).transition(.opacity)
            } else {
                Text(glassText(message ?? text)).id(message ?? text).transition(.blurReplace)
            }
        }
        .foregroundStyle(message == nil ? Color.primary : Color.secondary)
        .glassTextStyle()
        .animation(.easeInOut(duration: reduceMotion ? 0.2 : 0.65), value: message ?? text)
    }
    static let displayDuration: Duration = .seconds(3)
}
