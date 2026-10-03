import AppKit
import SwiftUI

/// Finder's actual icon, fetched off the UI thread for mounted network folders.
struct NativeLocationIcon: View {
    let path: String?
    var size: CGFloat = 24
    @State private var image: NSImage?
    var body: some View {
        Image(nsImage: image ?? NSWorkspace.shared.icon(for: .folder))
            .resizable().scaledToFit().frame(width: size, height: size)
            .task(id: path) {
                guard let path else { image = nil; return }
                let data = await Task.detached(priority: .utility) {
                    NSWorkspace.shared.icon(forFile: path).tiffRepresentation
                }.value
                guard !Task.isCancelled else { return }
                image = data.flatMap(NSImage.init(data:))
            }
    }
}
