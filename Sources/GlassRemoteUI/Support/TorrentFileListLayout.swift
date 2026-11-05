import AppKit
import SwiftUI

/// Shared row metrics keep the content, native row and list height in agreement.
@MainActor
struct TorrentFileListLayout {
    static let shared = Self()
    // Finder-sized identity glyphs; one glyph plus its gap is one hierarchy level.
    var leadingIconWidth: CGFloat { 16 }
    var disclosureWidth: CGFloat { 12 }
    var identityIconWidth: CGFloat { 16 }
    var metadataGap: CGFloat { 6 }
    var textLeadingInset: CGFloat { leadingIconWidth + columnGap + disclosureWidth + columnGap + identityIconWidth + columnGap }
    var verticalInset: CGFloat { 4 }
    // Row interior, distinct from the document margin: keep native controls and
    // metadata off the rounded selection edge on all four sides.
    var selectionInterior: CGFloat { verticalInset }
    // Native-style selection extends halfway into the document margin without
    // shifting the content columns or the native separators.
    var selectionOutset: CGFloat { GlassContentMargins.value / 2 }
    var contentHeight: CGFloat {
        // Reserve two native caption lines even when progress is inline, so
        // adaptive metadata cannot change the embedded list's row-height math.
        [NSFont.TextStyle.caption1, .caption2].reduce(CGFloat.zero) { height, style in
            let font = NSFont.preferredFont(forTextStyle: style)
            return height + ceil(font.ascender - font.descender + font.leading)
        }
    }
    var rowHeight: CGFloat { contentHeight + verticalInset * 2 }
    // Stacked metadata gets a real interline gap and breathing room above/below.
    func contentHeight(stacked: Bool) -> CGFloat { contentHeight + (stacked ? metadataGap : 0) }
    func verticalInset(stacked: Bool) -> CGFloat { stacked ? 6 : verticalInset }
    func rowHeight(stacked: Bool) -> CGFloat { contentHeight(stacked: stacked) + 2 * verticalInset(stacked: stacked) }
    var columnGap: CGFloat { 6 }
    var iconLeadingInset: CGFloat { leadingIconWidth + columnGap + disclosureWidth + columnGap }
    func iconLeadingInset(hierarchical: Bool) -> CGFloat {
        iconLeadingInset - (hierarchical ? 0 : disclosureWidth + columnGap)
    }
    func textLeadingInset(hierarchical: Bool) -> CGFloat {
        iconLeadingInset(hierarchical: hierarchical) + identityIconWidth + columnGap
    }
    var indent: CGFloat { identityIconWidth + columnGap }
    var insets: EdgeInsets {
        // Horizontal document margins belong solely to GlassContentMargins.
        EdgeInsets(top: verticalInset, leading: 0, bottom: verticalInset, trailing: 0)
    }

    /// Add an inline progress column only after reserving 18 average body-text
    /// characters for the name, including the deepest folder's indentation.
    /// This responds to font metrics, translated sizes, Tune and window width.
    func canShowInlineProgress(width: CGFloat, sizeText: String, depth: Int) -> Bool {
        let body = NSFont.preferredFont(forTextStyle: .body)
        let caption = NSFont.preferredFont(forTextStyle: .caption1)
        let name = String(repeating: "n", count: 18).size(withAttributes: [.font: body]).width
        let metadata = (sizeText + "100%").size(withAttributes: [.font: caption]).width + metadataGap
        return width >= 2 * (GlassContentMargins.value + selectionInterior) + textLeadingInset + CGFloat(depth) * indent + name + columnGap + metadata
    }
}

/// Give native context-menu and focus feedback the same rounded row silhouette.
struct TorrentFileContextShape: Shape {
    var horizontalOutset: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .path(in: rect.insetBy(dx: -horizontalOutset, dy: 0))
    }
}

struct TorrentFileSelectionShape: Shape {
    var horizontalOutset: CGFloat
    var joinsAbove: Bool
    var joinsBelow: Bool

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(topLeadingRadius: joinsAbove ? 0 : 12,
            bottomLeadingRadius: joinsBelow ? 0 : 12,
            bottomTrailingRadius: joinsBelow ? 0 : 12,
            topTrailingRadius: joinsAbove ? 0 : 12)
            .path(in: rect.insetBy(dx: -horizontalOutset, dy: 0))
    }
}
