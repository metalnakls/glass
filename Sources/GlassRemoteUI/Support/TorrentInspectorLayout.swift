import Foundation

/// Leave the list room to breathe, with hysteresis while resizing near the boundary.
enum TorrentInspectorLayout {
    static let listEdgePadding: CGFloat = 32
    static func isVisible(width: CGFloat, wasVisible: Bool) -> Bool {
        width >= (wasVisible ? 720 : 760)
    }
}
