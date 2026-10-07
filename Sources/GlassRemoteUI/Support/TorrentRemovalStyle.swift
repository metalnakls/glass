import SwiftUI

/// A removal detaches the transfer; deleting data also discards its contents.
enum TorrentRemovalStyle {
    static func symbol(deleteData: Bool) -> String { deleteData ? "trash" : "minus.circle" }
}
