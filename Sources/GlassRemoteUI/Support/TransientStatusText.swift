import SwiftUI

/// Reusable temporary feedback: native blur replacement, consistent timing and reduced-motion support.
struct TransientStatusText: View {
    let text: String
    let message: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack(alignment: .leading) {
            if reduceMotion {
                Text(message ?? text).id(message ?? text).transition(.opacity)
            } else {
                Text(message ?? text).id(message ?? text).transition(.blurReplace)
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.2 : 0.65), value: message ?? text)
    }
    static let displayDuration: Duration = .seconds(3)
}
