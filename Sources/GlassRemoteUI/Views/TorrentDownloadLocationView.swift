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
                        if !isLocal && location.directoryURL == nil {
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
                    Image(systemName: isLocal ? "desktopcomputer" : "externaldrive.connected.to.line.below")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(location.sourceName).font(.callout.weight(.medium))
                        Text(location.folderName).font(.caption).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.tertiary)
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
