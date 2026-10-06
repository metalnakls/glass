import AppKit

/// Document and pinned surfaces use one compositing order. Row artwork can
/// overlap its neighbors without crossing the flight or header planes.
enum TorrentListRenderOrder {
    static func row(at index: Int) -> CGFloat {
        let position = CGFloat(max(index, 0))
        return min((position + 1) / (position + 2), CGFloat(1).nextDown)
    }

    static let folderFlight: CGFloat = 1
    static let sectionHeader: CGFloat = 2
}
