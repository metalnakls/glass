import AppKit
import SwiftUI

/// One horizontal document margin for file content and its floating controls.
/// nil delegates the default to SwiftUI, exactly as the native glass dock does.
struct GlassContentMargins: ViewModifier {
    /// Native row and adaptive metadata geometry need a numeric margin. Measure
    /// SwiftUI's default once instead of duplicating a presumed platform inset.
    static let systemValue: CGFloat = {
        NSHostingView(rootView: AnyView(Color.clear.frame(width: 0, height: 0).padding(.horizontal)))
            .fittingSize.width / 2
    }()

    static func prepare(_ table: NSTableView) {
        // SwiftUI's .plain List uses AppKit's full-width style, adding padding
        // outside listRowInsets. Native plain rows leave this owner in charge.
        guard table.style != .plain || table.intercellSpacing.width != 0 else { return }
        table.style = .plain
        table.intercellSpacing.width = 0
        table.sizeLastColumnToFit()
    }
    static var value: CGFloat {
        let preferences = AppearancePreferences.shared
        guard preferences.value(for: "GlassLayout.customSideMargins", fallback: false) else { return systemValue }
        return max(0, min(40, preferences.value(for: "GlassLayout.sideMargin", fallback: 16.0)))
    }

    func body(content: Content) -> some View {
        content.padding(.horizontal, Self.value)
    }
}

extension View {
    func glassContentMargins() -> some View { modifier(GlassContentMargins()) }
}
