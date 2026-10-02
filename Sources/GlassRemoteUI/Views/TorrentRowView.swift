import AppKit
import GlassRemoteCore
import SwiftUI
import UniformTypeIdentifiers

struct TorrentRowView: View, Equatable {
    let torrent: TorrentSummary
    var showsExtensions = false
    var groupIsExpanded: Bool?
    var toggleGroupExpansion: (() -> Void)?
    var pendingOldName: String?
    var thumbnailInput: TorrentThumbnailInput?
    let toggleTransfer: () -> Void

    var body: some View {
        row
        .padding(.vertical)
        .contentShape(Rectangle())
    }

    private var row: some View {
        HStack(alignment: .center) {
            leadingIcon

            torrentContent
            transferButton
        }
    }

    nonisolated static func == (lhs: TorrentRowView, rhs: TorrentRowView) -> Bool {
        lhs.torrent == rhs.torrent
            && lhs.showsExtensions == rhs.showsExtensions
            && lhs.groupIsExpanded == rhs.groupIsExpanded
            && lhs.pendingOldName == rhs.pendingOldName
            && lhs.thumbnailInput == rhs.thumbnailInput
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if let groupIsExpanded {
            Button {
                toggleGroupExpansion?()
            } label: {
                if groupIsExpanded {
                    Image(systemName: "chevron.down")
                        .font(.body.weight(.semibold))
                        .frame(width: 36)
                        .contentTransition(.symbolEffect(.replace))
                } else {
                    TorrentFileIcon(fileName: "", isFolder: true)
                        .frame(width: 36)
                }
            }
            .buttonStyle(.plain)
            .help(groupIsExpanded ? "Hide Torrents" : "Show Torrents")
            .accessibilityLabel(groupIsExpanded ? "Collapse Group" : "Expand Group")
        } else if showsActivityIcon {
            activityProgress
        } else {
            TorrentFileIcon(fileName: torrent.name, isFolder: isFolderLike, thumbnailInput: thumbnailInput)
        }
    }

    private var activityProgress: some View {
        GlassActivityIndicator(
            label: pendingOldName == nil ? "Downloading torrent metadata" : "Renaming torrent"
        )
        .font(.system(size: 19, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 36)
    }

    private var showsActivityIcon: Bool {
        pendingOldName != nil || torrent.isDownloadingMetadata
    }

    private var torrentContent: some View {
        VStack(alignment: .leading) {
            titleLine
            ProgressView(value: torrent.percentDone, total: 1)
                .controlSize(.small)
                .tint(Color(nsColor: .secondaryLabelColor))
                .accessibilityLabel("Download progress")
        }
        .foregroundStyle(Color.primary)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(displayName(torrent.name))
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(3)

            oldNameLabel

            Spacer()

            sizeLabel
        }
        .animation(.easeInOut(duration: 0.2), value: pendingOldName)
    }

    @ViewBuilder
    private var oldNameLabel: some View {
        if let pendingOldName {
            Text(displayName(pendingOldName))
                .font(.callout)
                .foregroundStyle(.tertiary)
                .strikethrough()
                .lineLimit(1)
                .truncationMode(.tail)
                .transition(.opacity)
        }
    }

    private var sizeLabel: some View {
        Text(formatBytes(torrent.sizeWhenDone))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var transferButton: some View {
        Button(action: toggleTransfer) {
            Image(systemName: torrent.canStopTransfer ? "pause.fill" : "play.fill")
                .imageScale(.medium)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .foregroundStyle(Color.primary)
        .help(torrent.canStopTransfer ? "Pause" : "Resume")
        .accessibilityLabel(torrent.canStopTransfer ? "Pause" : "Resume")
    }

    private var isFolderLike: Bool {
        URL(fileURLWithPath: torrent.name).pathExtension.isEmpty
    }

    private func displayName(_ name: String) -> String {
        guard !showsExtensions, groupIsExpanded == nil, torrent.fileCount.map({ $0 <= 1 }) ?? true else {
            return name
        }
        let fileName = name as NSString
        let fileExtension = fileName.pathExtension
        guard !fileExtension.isEmpty,
              torrent.fileCount == 1 || UTType(filenameExtension: fileExtension) != nil else {
            return name
        }
        return fileName.deletingPathExtension
    }
}

struct TorrentFileIcon: View {
    let fileName: String
    let isFolder: Bool
    var size: CGFloat = 36
    var thumbnailInput: TorrentThumbnailInput?
    @State private var thumbnail: NSImage?
    @State private var isVisible = false

    var body: some View {
        Image(nsImage: thumbnail ?? nativeIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .onScrollVisibilityChange(threshold: 0.1) { isVisible = $0 }
            .task(id: ThumbnailTaskID(input: thumbnailInput, visible: isVisible, revision: TorrentThumbnailService.shared.revision)) {
                guard let input = thumbnailInput, !isFolder else { thumbnail = nil; return }
                guard isVisible else { return }
                thumbnail = TorrentThumbnailService.shared.cachedImage(for: input)
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                let image = await TorrentThumbnailService.shared.image(for: input)
                guard !Task.isCancelled else { return }
                thumbnail = image
            }
    }

    private var nativeIcon: NSImage {
        TorrentFileIconCache.icon(fileName: fileName, isFolder: isFolder)
    }
}

private struct ThumbnailTaskID: Equatable {
    let input: TorrentThumbnailInput?
    let visible: Bool
    let revision: Int
}

@MainActor
private enum TorrentFileIconCache {
    private static let icons = NSCache<NSString, NSImage>()

    static func icon(fileName: String, isFolder: Bool) -> NSImage {
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        let key = (isFolder ? "folder" : "file:\(fileExtension)") as NSString
        if let cached = icons.object(forKey: key) {
            return cached
        }

        let source: NSImage
        if isFolder {
            source = NSWorkspace.shared.icon(for: .folder)
        } else {
            source = NSWorkspace.shared.icon(for: UTType(filenameExtension: fileExtension) ?? .data)
        }
        let icon = source.copy() as? NSImage ?? source
        icon.size = NSSize(width: 32, height: 32)
        icons.setObject(icon, forKey: key)
        return icon
    }
}
