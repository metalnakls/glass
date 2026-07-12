import AppKit
import GlassRemoteCore
import SwiftUI
import UniformTypeIdentifiers

struct TorrentRowView: View {
    let torrent: TorrentSummary
    var isGroup = false
    var isNested = false
    var isSelected = false
    var usesCompactLayout = false
    var pendingOldName: String?
    var iconAnimationNamespace: Namespace.ID?
    var iconAnimationID: String?
    let toggleTransfer: () -> Void

    var body: some View {
        Group {
            if usesCompactLayout {
                compactRow
            } else {
                regularRow
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(minHeight: 68, alignment: .center)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.14))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .focusable(false)
        .focusEffectDisabled()
    }

    private var regularRow: some View {
        HStack(alignment: .center, spacing: 16) {
            leadingIcon

            torrentContent

            transferButton
        }
    }

    private var compactRow: some View {
        HStack(spacing: 10) {
            if isGroup {
                Color.clear
                    .frame(width: 42, height: 50)
            } else if showsActivityIcon {
                activityProgress
            }
            torrentContent
            transferButton
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if isGroup {
            Color.clear
                .frame(width: 42, height: 50)
        } else if showsActivityIcon {
            activityProgress
        } else {
            animatedFileIcon
        }
    }

    @ViewBuilder
    private var animatedFileIcon: some View {
        if let iconAnimationNamespace, let iconAnimationID {
            TorrentFileIcon(fileName: torrent.name, isFolder: isFolderLike)
                .matchedGeometryEffect(
                    id: iconAnimationID,
                    in: iconAnimationNamespace,
                    isSource: false
                )
                .frame(width: 42, height: 50, alignment: .center)
        } else {
            TorrentFileIcon(fileName: torrent.name, isFolder: isFolderLike)
                .frame(width: 42, height: 50, alignment: .center)
        }
    }

    private var activityProgress: some View {
        GlassActivityIndicator(
            label: pendingOldName == nil ? "Downloading torrent metadata" : "Renaming torrent"
        )
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 42, height: 50, alignment: .center)
    }

    private var showsActivityIcon: Bool {
        pendingOldName != nil || torrent.isDownloadingMetadata
    }

    private var torrentContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(torrent.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text(formatBytes(torrent.sizeWhenDone))
                    .font(.caption)
                    .foregroundStyle(secondaryTextStyle)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let pendingOldName {
                    Text(pendingOldName)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .strikethrough()
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Text(formatPercent(torrent.percentDone))
                    .font(.caption)
                    .foregroundStyle(secondaryTextStyle)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            HStack(spacing: 10) {
                Text(formatStatus(torrent.status))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Label(formatRate(torrent.rateDownload), systemImage: "arrow.down")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Label(formatRate(torrent.rateUpload), systemImage: "arrow.up")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let queuePosition = torrent.queuePosition {
                    Text("#\(queuePosition + 1)")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .font(.caption)
            .foregroundStyle(secondaryTextStyle)
            .labelStyle(.titleAndIcon)
            .monospacedDigit()

            ProgressView(value: torrent.percentDone, total: 1)
                .controlSize(.small)
        }
        .foregroundStyle(Color.primary)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var transferButton: some View {
        Button(action: toggleTransfer) {
            Image(systemName: torrent.canStopTransfer ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .foregroundStyle(Color.primary)
        .frame(width: 42, height: 50, alignment: .center)
        .help(torrent.canStopTransfer ? "Pause" : "Resume")
        .focusable(false)
        .focusEffectDisabled()
    }

    private var isFolderLike: Bool {
        URL(fileURLWithPath: torrent.name).pathExtension.isEmpty
    }

    private var secondaryTextStyle: Color {
        Color.secondary
    }
}

struct TorrentFileIcon: View {
    let fileName: String
    let isFolder: Bool
    var size: CGFloat = 36

    var body: some View {
        Image(nsImage: nativeIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }

    private var nativeIcon: NSImage {
        TorrentFileIconCache.icon(fileName: fileName, isFolder: isFolder)
    }
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
