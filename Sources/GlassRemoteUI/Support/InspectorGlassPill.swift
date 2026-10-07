import SwiftUI

/// Custom search and progress surfaces match the native extra-large text button height.
/// Padding remains system-determined; buttons use GlassPillButton instead.
struct InspectorGlassPill: ViewModifier {
    static let height: CGFloat = 36
    static let spacing: CGFloat = 8
    var interactive = false
    var tint: Color?
    var iconOnly = false

    func body(content: Content) -> some View {
        content.padding(.horizontal, iconOnly ? 0 : nil)
            .frame(width: iconOnly ? Self.height : nil, height: Self.height)
            .glassEffect(interactive ? .regular.tint(tint).interactive() : .regular.tint(tint), in: .capsule)
    }
}
