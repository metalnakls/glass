import SwiftUI

/// Floating controls have no full-width surface or hit target behind them.
struct GlassFloatingDock<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        GlassEffectContainer() {
            content()
                .padding()
        }
    }
}

/// Native bars reserve content space and extend the scroll edge effect beneath
/// floating controls. Only the individual controls own a background or hit target.
private struct GlassFloatingChrome<Top: View, Bottom: View>: ViewModifier {
    @ViewBuilder var top: () -> Top
    @ViewBuilder var bottom: () -> Bottom

    func body(content: Content) -> some View {
        content
            .safeAreaBar(edge: .top, spacing: 0) {
                GlassFloatingDock(content: top)
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                GlassFloatingDock(content: bottom)
            }
    }
}

extension View {
    func glassFloatingChrome<Top: View, Bottom: View>(
        @ViewBuilder top: @escaping () -> Top, @ViewBuilder bottom: @escaping () -> Bottom
    ) -> some View {
        modifier(GlassFloatingChrome(top: top, bottom: bottom))
    }
}

/// The system owns button padding, feedback and hit testing for every shared dock.
struct GlassPillButton<Label: View>: View {
    var iconOnly = false
    var tint: Color?
    let action: () -> Void
    @ViewBuilder var label: () -> Label
    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(.glass)
            .buttonBorderShape(iconOnly ? .circle : .capsule)
            .controlSize(.extraLarge)
            .tint(tint)
    }
}

enum GlassModalMetrics {
    static let addTorrent = CGSize(width: 640, height: 580)
    // Deliberate card-stack reveal, shared by loading and loaded import chrome.
    static let cardReveal: CGFloat = 6
    static let cornerRadius: CGFloat = 24
}

/// Scroll content passes under floating controls; indicators retain their native frame.
struct GlassChromeScrollView<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView { content() }
            .scrollEdgeEffectStyle(.soft, for: .all)
    }
}
