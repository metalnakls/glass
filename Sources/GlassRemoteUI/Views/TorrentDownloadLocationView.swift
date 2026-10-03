import AppKit
import SwiftUI

/// Compact location identity; server/container paths never serve as the source label.
struct TorrentDownloadLocation: Equatable {
    let sourceName: String
    let folderName: String
    let directoryURL: URL?

    init(directory: String, localName: String?, link: TorrentThumbnailFolderLink?) {
        if let localName {
            sourceName = localName
            directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        } else if let link {
            let root = URL(fileURLWithPath: link.localPath, isDirectory: true)
            let components = root.pathComponents
            sourceName = components.count > 2 && components[1] == "Volumes" ? components[2] : root.lastPathComponent
            directoryURL = TorrentThumbnailFolderLink.directoryURL(
                remoteRoot: link.remoteRoot, localRoot: root, directory: directory
            )
        } else {
            sourceName = "Connect share…"
            directoryURL = nil
        }
        folderName = directoryURL?.lastPathComponent ?? URL(fileURLWithPath: directory).lastPathComponent
    }
}

struct TorrentDownloadLocationView: View {
    let directory: String?
    let itemPath: String
    let sourceID: UUID
    let isLocal: Bool
    let localName: String
    var serverName = ""
    var availableBytes: UInt64?
    let platformIntegration: any GlassPlatformIntegrating
    @State private var errorMessage: String?
    @State private var isOpening = false

    var body: some View {
        if let directory, !directory.isEmpty {
            let link = TorrentThumbnailService.shared.link(for: sourceID)
            let location = TorrentDownloadLocation(directory: directory, localName: isLocal ? localName : nil, link: link)
            Button {
                Task {
                    isOpening = true
                    defer { isOpening = false }
                    do {
                        if !isLocal && (location.directoryURL == nil || NSEvent.modifierFlags.contains(.command)) {
                            guard let folder = try await platformIntegration.chooseThumbnailDirectory() else { return }
                            try await TorrentThumbnailService.shared.setLink(sourceID: sourceID, remoteRoot: directory, localURL: folder)
                        }
                        try await TorrentThumbnailService.shared.openDownloadLocation(
                            sourceID: sourceID, directory: directory, itemPath: itemPath, isLocal: isLocal
                        )
                    } catch { errorMessage = error.localizedDescription }
                }
            } label: {
                HStack(spacing: 9) {
                    NativeLocationIcon(path: isLocal ? "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/SidebarComputer.icns" : link?.localPath)
                    Text(location.directoryURL == nil ? "… / \(serverName)" : isLocal ? localName : "\(location.sourceName) / \(serverName)")
                        .font(.callout.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let availableBytes {
                        Text(formatBytes(availableBytes) + " free")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .disabled(isOpening)
            .help(isLocal ? "Show download in Finder" : "Open connected share in Finder")
            .accessibilityLabel("\(location.sourceName), \(location.folderName)")
            .alert("Couldn’t Open Download Location", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        } else {
            Label("Download location unavailable", systemImage: "folder")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
    }
}
