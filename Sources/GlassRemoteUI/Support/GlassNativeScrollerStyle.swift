import AppKit
import SwiftUI

/// Keep AppKit's scroller, but ask for its low-key overlay presentation.
/// This avoids drawing a second scrollbar while keeping native scrolling,
/// keyboard behavior and accessibility.
@MainActor
enum GlassNativeScrollerStyle {
    static func apply(to scroll: NSScrollView) {
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
        for scroller in [scroll.verticalScroller, scroll.horizontalScroller] {
            guard let scroller, scroller.controlSize != .small else { continue }
            scroller.controlSize = .small
        }
    }
}

extension View {
    /// Place on content inside a native scroll view.
    func glassNativeScrollerStyle() -> some View {
        background { GlassNativeScrollerStyleAnchor().frame(width: 1, height: 1) }
    }
}

/// The nearest native scroll view owns the result.
struct GlassNativeScrollerStyleAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.apply() }

    final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); apply() }

        func apply() {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? NSScrollView {
                    GlassNativeScrollerStyle.apply(to: scroll)
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
