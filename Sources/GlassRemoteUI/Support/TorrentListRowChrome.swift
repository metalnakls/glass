import AppKit
import SwiftUI

/// Shared selection, elevation and hit geometry for native torrent and draft rows.
/// These are the existing card bounds; each caller owns its outer document inset.
struct TorrentListRowChrome: ViewModifier {
    let rowID: String
    let isSelected: Bool
    let isReordering: Bool
    let isSwiping: Bool
    let grid: Bool
    let rowHeight: CGFloat
    let artworkOverflow: CGFloat
    let elevationController: TorrentListElevationController
    let select: () -> Void

    func body(content: Content) -> some View {
        content
            .frame(height: grid ? 164 : rowHeight, alignment: .center)
            .background {
                if isReordering || (isSelected && isSwiping) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .padding(.leading, -14 - artworkOverflow).padding(.trailing, -14)
                        .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
                }
                if !grid {
                    TorrentListElevationAnchor(controller: elevationController, rowID: rowID, selected: isSelected)
                        .padding(.leading, -14 - artworkOverflow).padding(.trailing, -14)
                        .padding(.vertical, TorrentCardGeometry.verticalInset)
                }
            }
            .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 12))
            .opacity(isReordering ? 0.45 : 1)
            .simultaneousGesture(TapGesture().onEnded { select() })
            .background {
                if grid && isSelected {
                    RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                }
            }
    }
}
