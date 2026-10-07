import SwiftUI

/// All inspector capsules share one height; content never determines their outline.
struct InspectorGlassPill: ViewModifier {
    static let height: CGFloat = 36
    var interactive = false
    var tint: Color?
    var iconOnly = false

    func body(content: Content) -> some View {
        content.padding(.horizontal, iconOnly ? 0 : 18)
            .frame(width: iconOnly ? Self.height : nil, height: Self.height)
            .glassEffect(interactive ? .regular.tint(tint).interactive() : .regular.tint(tint), in: .capsule)
    }
}
