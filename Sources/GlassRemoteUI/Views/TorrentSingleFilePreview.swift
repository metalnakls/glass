import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A single file uses the same Finder artwork and live glass as list items.
struct TorrentSingleFilePreview: View {
    let name: String
    let size: UInt64
    var input: TorrentThumbnailInput?
    var onOpen: (() -> Void)?
    @State private var thumbnail: NSImage?

    private var previewInput: TorrentThumbnailInput? {
        guard var input else { return nil }
        input.pixelSize = 1024
        return input
    }

    var body: some View {
        Group {
            if let onOpen {
                Button(action: onOpen) { artwork }
                    .buttonStyle(.plain)
                    .accessibilityLabel(glassText("Open file"))
            } else {
                artwork
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .task(id: previewInput) {
            thumbnail = previewInput.flatMap { TorrentThumbnailService.shared.cachedImage(for: $0) }
            guard let input = previewInput else { return }
            let image = await TorrentThumbnailService.shared.image(for: input)
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }

    private var artwork: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().interpolation(.high).scaledToFit()
                    .frame(maxWidth: 360, maxHeight: 420)
                    .modifier(TorrentIconShadow())
            } else {
                NativeGlassIcon(image: NSWorkspace.shared.icon(for: UTType(filenameExtension: (name as NSString).pathExtension) ?? .data), size: 180)
            }
        }
        .contentShape(Rectangle())
    }
}
