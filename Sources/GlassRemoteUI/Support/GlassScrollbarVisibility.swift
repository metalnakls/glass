import SwiftUI

/// One live Tune preference for native scroll indicators throughout Glass.
struct GlassScrollbarVisibility: ViewModifier {
    static var visibility: ScrollIndicatorVisibility {
        AppearancePreferences.shared.value(for: "GlassScroll.hideScrollbars", fallback: true) ? .hidden : .automatic
    }
    func body(content: Content) -> some View { content.scrollIndicators(Self.visibility) }
}

extension View {
    func glassScrollbarVisibility() -> some View { modifier(GlassScrollbarVisibility()) }
}
