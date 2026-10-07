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
    @AppStorage("GlassList.showExtensions") private var showsExtensions = false

    var body: some View {
        VStack(spacing: 24) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit()
                        .frame(maxWidth: 320, maxHeight: 340)
                        .modifier(TorrentIconShadow())
                } else {
                    NativeGlassIcon(image: NSWorkspace.shared.icon(for: UTType(filenameExtension: (name as NSString).pathExtension) ?? .data), size: 180)
                }
            }
            Text(TorrentExtensionPolicy.name(name, hiding: showsExtensions ? nil : TorrentExtensionPolicy.hiddenExtension(paths: [name]))).textCase(nil)
                .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            if let onOpen {
                Button(action: onOpen) { Label(glassText("Open"), systemImage: "play.fill") }
                    .buttonStyle(.plain).modifier(InspectorGlassPill(interactive: true))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(32)
        .task(id: input) {
            thumbnail = input.flatMap { TorrentThumbnailService.shared.cachedImage(for: $0) }
            guard let input else { return }
            let image = await TorrentThumbnailService.shared.image(for: input)
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }
}
