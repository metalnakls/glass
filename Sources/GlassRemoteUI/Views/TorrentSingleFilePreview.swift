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
    @State private var hovering = false
    @State private var refreshID = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var previewInput: TorrentThumbnailInput? {
        guard var input else { return nil }
        input.pixelSize = 1024
        return input
    }

    var body: some View {
        Group {
            if let onOpen {
                Button(action: onOpen) {
                    artwork.overlay {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .modifier(InspectorGlassPill(interactive: true, iconOnly: true))
                            .opacity(hovering ? 1 : 0)
                            .blur(radius: hovering || reduceMotion ? 0 : 22)
                            .animation(reduceMotion ? nil : .easeInOut(duration: hovering ? 0.25 : 0.30), value: hovering)
                    }
                }
                    .buttonStyle(TorrentPreviewPressStyle())
                    .onHover { hovering = $0 }
                    .accessibilityLabel(glassText("Open file"))
            } else {
                artwork
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshID = UUID() }
        .task(id: "\(previewInput?.key ?? "")-\(refreshID)") {
            thumbnail = previewInput.flatMap { TorrentThumbnailService.shared.cachedArtwork(for: $0) }
            guard let input = previewInput else { return }
            let image = await TorrentThumbnailService.shared.image(for: input)
            guard !Task.isCancelled else { return }
            if let image { thumbnail = image }
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

private struct TorrentPreviewPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
