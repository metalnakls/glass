import AppKit
import SwiftUI

/// App-wide exceptions to native sizing. Screens must not declare copies.
enum GlassControlMetrics {
    static let size: ControlSize = .extraLarge
    // Native extra-large glass buttons are 36 pt on macOS. Custom search and
    // progress content use that same slot; button padding remains native.
    static let height: CGFloat = 36
    static var labelIconSize: CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .body)
        return ceil(font.ascender - font.descender + font.leading)
    }
}

enum GlassMotion {
    static let control: Animation = .smooth(duration: 0.35)
}

enum GlassListMetrics {
    // Preserve the established title position while the native bar owns blur.
    static let titleVerticalInset: CGFloat = 8
}

/// Scroll effects belong to the container, never to a row or title label.
private struct GlassScrollEdges: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectHidden(true, for: .bottom)
    }
}

extension View {
    func glassScrollEdges() -> some View { modifier(GlassScrollEdges()) }
}

/// File imports, magnet imports and their loading states share this card.
struct GlassAddCard<Content: View, Header: View, Dock: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var header: () -> Header
    @ViewBuilder var dock: () -> Dock

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassFloatingChrome(top: header, bottom: dock)
            .background(.background, in: RoundedRectangle(cornerRadius: GlassModalMetrics.cornerRadius))
    }
}

/// A separator is part of a native row, rather than an overlay on its content.
struct GlassListRowSeparator: ViewModifier {
    let visible: Bool
    let leading: CGFloat
    let trailing: CGFloat
    func body(content: Content) -> some View {
        content
            .listRowSeparator(visible ? .visible : .hidden, edges: .bottom)
            .listRowSeparator(.hidden, edges: .top)
            .listRowSeparatorTint(visible ? .primary.opacity(0.12) : .clear)
            .alignmentGuide(.listRowSeparatorLeading) { _ in leading }
            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width - trailing }
    }
}

/// Pending and resolved imports share the same title/location alignment and Tune offsets.
struct GlassAddHeader<Title: View, Location: View>: View {
    @ViewBuilder var title: () -> Title
    @ViewBuilder var location: () -> Location
    @AppearanceStorage("GlassAdd.titleTopPadding") private var topPadding = 20.0
    @AppearanceStorage("GlassAdd.titleLeftPadding") private var leftPadding = 20.0

    var body: some View {
        HStack(alignment: .top) {
            title().frame(maxWidth: .infinity, alignment: .leading)
            location().fixedSize(horizontal: true, vertical: false)
        }
        .frame(height: GlassAddMetrics.headerHeight, alignment: .top)
        .padding(.leading, max(0, leftPadding - GlassAddMetrics.legacyPadding))
        .padding(.top, max(0, topPadding - GlassAddMetrics.legacyPadding))
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

enum GlassAddMetrics {
    // Includes the native pill plus its free-space caption.
    static let headerHeight: CGFloat = 58
    // Tune stores the former 20 pt baseline; native dock padding now owns it.
    static let legacyPadding: CGFloat = 20
}
