import SwiftUI

/// All inspector capsules share one height; content never determines their outline.
struct InspectorGlassPill: ViewModifier {
    static let height: CGFloat = 44
    var interactive = false
    var tint: Color?

    func body(content: Content) -> some View {
        content.padding(.horizontal, 12)
            .frame(height: Self.height)
            .glassEffect(interactive ? .regular.tint(tint).interactive() : .regular.tint(tint), in: .capsule)
    }
}
