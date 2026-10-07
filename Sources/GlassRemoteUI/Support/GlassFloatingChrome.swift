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

private struct GlassChromeInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}

extension EnvironmentValues {
    var glassChromeInsets: EdgeInsets {
        get { self[GlassChromeInsetsKey.self] }
        set { self[GlassChromeInsetsKey.self] = newValue }
    }
}

private struct GlassFloatingChrome<Top: View, Bottom: View>: ViewModifier {
    @ViewBuilder var top: () -> Top
    @ViewBuilder var bottom: () -> Bottom
    @State private var topHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.glassChromeInsets, EdgeInsets(top: topHeight, leading: 0, bottom: bottomHeight, trailing: 0))
            .overlay(alignment: .top) {
                GlassFloatingDock(content: top)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
            }
            .overlay(alignment: .bottom) {
                GlassFloatingDock(content: bottom)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomHeight = $0 }
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
    @Environment(\.glassChromeInsets) private var chromeInsets
    var body: some View {
        ScrollView { content() }
            .contentMargins(.top, chromeInsets.top, for: .scrollContent)
            .contentMargins(.bottom, chromeInsets.bottom, for: .scrollContent)
            .scrollEdgeEffectStyle(.soft, for: .all)
    }
}
