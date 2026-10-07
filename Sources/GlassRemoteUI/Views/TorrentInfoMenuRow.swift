import AppKit
import SwiftUI

/// Info remains readable and useful: clicking copies the value instead of presenting a disabled menu item.
struct TorrentInfoMenuRow: View {
    let title: String
    let value: String
    var body: some View {
        Button("\(glassText(title)): \(value)") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
        .textCase(nil)
        .help(glassText("Copy value"))
    }
}
