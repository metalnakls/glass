import AppKit
import GlassRemoteCore
import SwiftUI
import UniformTypeIdentifiers

struct TorrentRowView: View, Equatable {
    let torrent: TorrentSummary
    var sourceName: String?
    var density: TorrentRowDensity = .regular
    var groupIsExpanded: Bool?
    var groupCount = 0
    var toggleGroupExpansion: (() -> Void)?
    var pendingOldName: String?
    let toggleTransfer: () -> Void

    var body: some View {
        row
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var row: some View {
        HStack(alignment: .center, spacing: density.showsIcon ? 12 : 0) {
            if density.showsIcon {
                leadingIcon
                    .frame(width: 36, height: 42)
            }

            torrentContent
            transferButton
        }
    }

    nonisolated static func == (lhs: TorrentRowView, rhs: TorrentRowView) -> Bool {
        lhs.torrent == rhs.torrent
            && lhs.sourceName == rhs.sourceName
            && lhs.density == rhs.density
            && lhs.groupIsExpanded == rhs.groupIsExpanded
            && lhs.groupCount == rhs.groupCount
            && lhs.pendingOldName == rhs.pendingOldName
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
                        .frame(width: 36, height: 42)
                        .contentTransition(.symbolEffect(.replace))
                } else {
                    GroupFolderFanIcon(count: groupCount)
                        .frame(width: 36, height: 42)
                }
            }
            .buttonStyle(.plain)
            .help(groupIsExpanded ? "Hide Torrents" : "Show Torrents")
            .accessibilityLabel(groupIsExpanded ? "Collapse Group" : "Expand Group")
        } else if showsActivityIcon {
            activityProgress
        } else {
            TorrentFileIcon(fileName: torrent.name, isFolder: isFolderLike)
                .frame(width: 36, height: 42, alignment: .center)
        }
    }

    private var activityProgress: some View {
        GlassActivityIndicator(
            label: pendingOldName == nil ? "Downloading torrent metadata" : "Renaming torrent"
        )
        .font(.system(size: 19, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 36, height: 42, alignment: .center)
    }

    private var showsActivityIcon: Bool {
        pendingOldName != nil || torrent.isDownloadingMetadata
    }

    private var torrentContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleLine
            metadataLine
            ProgressView(value: torrent.percentDone, total: 1)
                .controlSize(.small)
        }
        .foregroundStyle(Color.primary)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(torrent.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(3)

            if density.showsSize {
                sizeLabel
            }

            oldNameLabel

            Spacer(minLength: 4)

            Text(formatPercent(torrent.percentDone))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .animation(.easeInOut(duration: 0.2), value: pendingOldName)
    }

    @ViewBuilder
    private var oldNameLabel: some View {
        if let pendingOldName {
            Text(pendingOldName)
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

    private var metadataLine: some View {
        HStack(spacing: 9) {
            if let sourceName {
                Text(sourceName).lineLimit(1)
            }
            Text(formatStatus(torrent.status))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(2)

            if density.showsAllRelevantRates {
                completeRateLabels
            } else if density.showsPrimaryRate {
                primaryRateLabel
            }

            if density.showsQueuePosition, let queuePosition = torrent.queuePosition {
                Text("#\(queuePosition + 1)")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .monospacedDigit()
    }

    @ViewBuilder
    private var completeRateLabels: some View {
        switch ratePresentation {
        case .none:
            EmptyView()
        case .download:
            downloadRateLabel
        case .upload:
            uploadRateLabel
        case .downloadAndUpload:
            HStack(spacing: 9) {
                downloadRateLabel
                uploadRateLabel
            }
        }
    }

    @ViewBuilder
    private var primaryRateLabel: some View {
        switch ratePresentation {
        case .none:
            EmptyView()
        case .download, .downloadAndUpload:
            downloadRateLabel
        case .upload:
            uploadRateLabel
        }
    }

    private var downloadRateLabel: some View {
        Label(formatRate(torrent.rateDownload), systemImage: "arrow.down")
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var uploadRateLabel: some View {
        Label(formatRate(torrent.rateUpload), systemImage: "arrow.up")
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var transferButton: some View {
        Button(action: toggleTransfer) {
            Image(systemName: torrent.canStopTransfer ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .foregroundStyle(Color.primary)
        .frame(width: 40, height: 42, alignment: .center)
        .help(torrent.canStopTransfer ? "Pause" : "Resume")
    }

    private var ratePresentation: RatePresentation {
        if torrent.canStopTransfer {
            if torrent.status == TransmissionTorrentStatus.seeding.rawValue || torrent.rateUpload > 0 && torrent.rateDownload == 0 {
                return .upload
            }
            return .downloadAndUpload
        }
        return .none
    }

    private var isFolderLike: Bool {
        URL(fileURLWithPath: torrent.name).pathExtension.isEmpty
    }
}

enum TorrentRowDensity: Equatable {
    case compact
    case standard
    case regular

    init(width: CGFloat) {
        if width >= 540 {
            self = .regular
        } else if width >= 430 {
            self = .standard
        } else {
            self = .compact
        }
    }

    var showsIcon: Bool {
        self != .compact
    }

    var showsSize: Bool {
        self != .compact
    }

    var showsAllRelevantRates: Bool {
        self == .regular
    }

    var showsPrimaryRate: Bool {
        self != .compact
    }

    var showsQueuePosition: Bool {
        self == .regular
    }
}

private enum RatePresentation {
    case none
    case download
    case upload
    case downloadAndUpload
}

private struct GroupFolderFanIcon: View {
    let count: Int

    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { index in
                TorrentFileIcon(fileName: "", isFolder: true, size: 27)
                    .rotationEffect(rotation(for: index), anchor: .bottom)
                    .offset(offset(for: index))
                    .zIndex(Double(index))
            }
        }
        .accessibilityHidden(true)
    }

    private func rotation(for index: Int) -> Angle {
        guard count > 1 else { return .zero }
        let progress = Double(index) / Double(count - 1)
        return .degrees(-9 + (18 * progress))
    }

    private func offset(for index: Int) -> CGSize {
        guard count > 1 else { return .zero }
        let progress = CGFloat(index) / CGFloat(count - 1)
        return CGSize(width: -5 + (10 * progress), height: abs(progress - 0.5) * 2)
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
