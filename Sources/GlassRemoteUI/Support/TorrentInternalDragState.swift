import Foundation

/// Window file drops must ignore native moves already owned by this app.
@MainActor enum TorrentInternalDragState {
    static var active = false
}
