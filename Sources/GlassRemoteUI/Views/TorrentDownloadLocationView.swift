import AppKit
import SwiftUI

/// The destination is the visible authority; a server only supplies its fallback name.
struct TorrentDownloadLocation: Equatable {
    let sourceName: String
    let folderName: String
    let directoryURL: URL?

    init(directory: String, localName: String?, serverName: String = "", link: TorrentThumbnailFolderLink?) {
        let remoteFolder = URL(fileURLWithPath: directory).lastPathComponent
        if localName != nil {
            directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
            sourceName = remoteFolder.isEmpty ? directory : remoteFolder
        } else if let link, let resolved = TorrentThumbnailFolderLink.directoryURL(
            remoteRoot: link.remoteRoot, localRoot: URL(fileURLWithPath: link.localPath, isDirectory: true), directory: directory
        ) {
            directoryURL = resolved
            sourceName = Self.shareName(link: link, fallback: serverName)
        } else {
            directoryURL = nil
            sourceName = serverName.isEmpty ? "Remote downloads" : serverName
        }
        folderName = directoryURL?.lastPathComponent ?? remoteFolder
    }

    static func shareName(link: TorrentThumbnailFolderLink?, fallback: String) -> String {
        guard let link else { return fallback }
        let root = URL(fileURLWithPath: link.localPath, isDirectory: true)
        let components = root.pathComponents
        return components.count > 2 && components[1] == "Volumes" ? components[2] : root.lastPathComponent
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
    var torrentErrors: [String] = []
    let platformIntegration: any GlassPlatformIntegrating
    @State private var errorMessage: String?
    @State private var isOpening = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let directory, !directory.isEmpty {
                let link = TorrentThumbnailService.shared.link(for: sourceID)
                let location = TorrentDownloadLocation(directory: directory, localName: isLocal ? localName : nil,
                    serverName: serverName, link: link)
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
                    HStack(spacing: 10) {
                        NativeLocationIcon(path: location.directoryURL?.path, size: 28)
                        Text(location.sourceName)
                            .font(.headline)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isOpening)
                .help(isLocal ? directory : "\(serverName): \(directory)\nClick to open the share; ⌘-click to reconnect it.")
                .accessibilityLabel(location.sourceName)
                .alert("Couldn’t Open Download Location", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                    Button("OK") { errorMessage = nil }
                } message: {
                    Text(errorMessage ?? "")
                }
            } else {
                Label("Location unavailable", systemImage: "folder")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .trailing, spacing: 4) {
                if !torrentErrors.isEmpty {
                    Text(Array(Set(torrentErrors.map { $0.hasPrefix("No data found") ? "No data found" : $0 })).sorted().joined(separator: " · "))
                        .font(.caption).foregroundStyle(.red)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .help(torrentErrors.joined(separator: "\n"))
                }
                if let availableBytes {
                    Text(formatBytes(availableBytes) + " free")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
