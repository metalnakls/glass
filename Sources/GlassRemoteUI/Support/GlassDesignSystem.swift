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

enum GlassListMetrics {
    // Established breathing room for pinned titles, independent of document spacing.
    static let pinnedTitleInset: CGFloat = 20
    // Preserve the established title position while the native bar owns blur.
    static let titleVerticalInset: CGFloat = 8
    static func stateDiameter(compact: Bool) -> CGFloat { compact ? 24 : GlassControlMetrics.height }
}

/// Established torrent-row columns, shared by content and native separator bounds.
/// The state button includes its two-point interior padding on both sides.
struct TorrentRowColumns {
    static let horizontalInset: CGFloat = 16
    static let artworkWidth: CGFloat = 36
    static let artworkGap: CGFloat = 12
    static let statePadding: CGFloat = 2
    let showsArtwork: Bool
    let compact: Bool
    let stateGap: CGFloat
    var textLeading: CGFloat { Self.horizontalInset + (showsArtwork ? Self.artworkWidth + Self.artworkGap : 0) }
    var textTrailing: CGFloat { Self.horizontalInset + GlassListMetrics.stateDiameter(compact: compact) + Self.statePadding * 2 + stateGap }
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

/// Document spacing moves inline titles and their content; it never changes
/// the viewport pin inset. Existing Tune keys and saved meanings stay intact.
struct TorrentInlineHeaderSpacing: ViewModifier {
    let isFirst: Bool
    let beforeFirst: CGFloat
    let betweenSections: CGFloat
    let belowHeader: CGFloat
    func body(content: Content) -> some View {
        content.padding(.top, isFirst ? beforeFirst : betweenSections).padding(.bottom, belowHeader)
    }
}

/// One native reorder collection preserves List's viewport-driven row creation.
/// Nesting a separate ForEach inside every row forces List to build every row
/// to discover the collection's shape before it can render its viewport.
struct GlassNativeReorderableRows<Items: RandomAccessCollection, Content: View>: View
where Items.Element: Identifiable, Items.Element.ID: Sendable {
    let items: Items
    var move: (IndexSet, Int) -> Void = { _, _ in }
    @ViewBuilder var content: (Items.Element) -> Content
    var body: some View {
        ForEach(items, content: content).onMove(perform: move)
    }
}

/// A separator is part of a native row, rather than an overlay on its content.
struct GlassListRowSeparator: ViewModifier {
    let visible: Bool
    let leading: CGFloat
    let trailing: CGFloat
    var tint: Color = .primary.opacity(0.12)
    func body(content: Content) -> some View {
        content
            .listRowSeparator(visible ? .visible : .hidden, edges: .bottom)
            .listRowSeparator(.hidden, edges: .top)
            .listRowSeparatorTint(visible ? tint : .clear)
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
