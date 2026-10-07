import SwiftUI

/// Shared row metrics keep the content, native row and list height in agreement.
@MainActor
struct TorrentFileListLayout {
    static let inspector = Self(isInspector: true)
    let isInspector: Bool
    var outerInset: CGFloat { isInspector ? AppearancePreferences.shared.value(for: "GlassInspector.fileSideInset", fallback: 18.0) : 0 }
    var nativeCellInset: CGFloat { isInspector ? 8 : 0 }
    var contentInset: CGFloat { max(0, outerInset - nativeCellInset) }
    var leadingIconWidth: CGFloat { isInspector ? 28 : 16 }
    var metadataGap: CGFloat { 6 }
    var textLeadingInset: CGFloat { outerInset + leadingIconWidth + columnGap }
    var verticalInset: CGFloat { isInspector ? 6 : 3 }
    var horizontalInset: CGFloat { nativeCellInset }
    var contentHeight: CGFloat { isInspector ? 36 : 32 }
    var rowHeight: CGFloat { contentHeight + verticalInset * 2 }
    var columnGap: CGFloat { isInspector ? 10 : 8 }
    var indent: CGFloat { isInspector ? 14 : 12 }
    var insets: EdgeInsets {
        // The native plain list already supplies the shared side inset.
        EdgeInsets(top: verticalInset, leading: 0, bottom: verticalInset, trailing: 0)
    }
}

/// Give native context-menu and focus feedback the same rounded row silhouette.
struct TorrentFileContextShape: Shape {
    var horizontalOutset: CGFloat

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .path(in: rect.insetBy(dx: -horizontalOutset, dy: 0))
    }
}
