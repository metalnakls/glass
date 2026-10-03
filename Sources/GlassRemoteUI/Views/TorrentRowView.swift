import AppKit
import GlassRemoteCore
import SwiftUI
import UniformTypeIdentifiers

struct TorrentRowView: View, Equatable {
    let torrent: TorrentSummary
    var showsExtensions = false
    var density: TorrentRowDensity = .regular
    var grid = false
    @State private var clickRevision = 0
    var groupIsExpanded: Bool?
    var groupCount = 0
    var toggleGroupExpansion: (() -> Void)?
    var pendingOldName: String?
    var shareUnavailable = false
    var thumbnailInput: TorrentThumbnailInput?
    let toggleTransfer: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if grid {
                VStack(spacing: 10) {
                    leadingIcon.scaleEffect(1.7).frame(height: 76)
                    Text(displayName(torrent.name)).font(.body).lineLimit(2).multilineTextAlignment(.center)
                    HStack { sizeLabel; Spacer(); transferButton }
                }.padding(16).frame(maxWidth: .infinity).frame(height: 164)
            } else { row }
        }
        .contentShape(Rectangle())

    }

    private var row: some View {
        HStack(alignment: .center, spacing: density.showsIcon ? 12 : 0) {
            if density.showsIcon {
                leadingIcon
            }

            torrentContent
            transferButton
                .padding(.leading, 16)
        }
    }

    nonisolated static func == (lhs: TorrentRowView, rhs: TorrentRowView) -> Bool {
        lhs.torrent == rhs.torrent
            && lhs.showsExtensions == rhs.showsExtensions
            && lhs.density == rhs.density
            && lhs.grid == rhs.grid
            && lhs.groupIsExpanded == rhs.groupIsExpanded
            && lhs.groupCount == rhs.groupCount
            && lhs.pendingOldName == rhs.pendingOldName
            && lhs.shareUnavailable == rhs.shareUnavailable
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
                        .frame(width: 36, height: 48)
                        .contentShape(Rectangle())
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
            TorrentFileIcon(fileName: torrent.name, isFolder: isFolderLike, thumbnailInput: thumbnailInput)
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
        titleLine
            .foregroundStyle(Color.primary)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(displayName(torrent.name))
                .font(density == .compact ? .callout : .body)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(3)

            if let priority = torrent.bandwidthPriority, priority != 0 {
                Image(systemName: priority > 0 ? "star.fill" : "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(priority > 0 ? Color.primary : Color.secondary)
                    .help(priority > 0 ? "High priority" : "Low priority")
            }
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
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.06), lineWidth: 2)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color(nsColor: .secondaryLabelColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .blur(radius: 0.65)
                .animation(reduceMotion ? nil : .linear(duration: 0.2), value: progress)
                .accessibilityHidden(true)
                .allowsHitTesting(false)

            stateControl
                .help(stateLabel)
                .accessibilityLabel(stateLabel)
                .accessibilityValue("\(progress.formatted(.percent.precision(.fractionLength(0)))) downloaded")
        }
        .frame(width: 36, height: 36)
        .padding(2)
    }

    private var stateControl: some View {
        Button(action: toggleTransfer) {
            Image(systemName: stateSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary)
                .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                .frame(width: 28, height: 28)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(shareUnavailable || torrent.isCompleted)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: stateSymbol)
    }

    private var progress: Double {
        torrent.percentDone.isFinite ? min(max(torrent.percentDone, 0), 1) : 0
    }

    private var stateSymbol: String {
        if shareUnavailable { return "questionmark" }
        if torrent.isCompleted { return "checkmark" }
        return torrent.canStopTransfer ? "pause.fill" : "play.fill"
    }

    private var stateLabel: String {
        if shareUnavailable { return torrent.errorString?.isEmpty == false ? torrent.errorString! : "Download unavailable" }
        if torrent.isCompleted { return "Finished" }
        return torrent.canStopTransfer ? "Pause" : "Resume"
    }

    private var isFolderLike: Bool {
        if thumbnailInput != nil { return false }
        if let count = torrent.fileCount { return count > 1 }
        return URL(fileURLWithPath: torrent.name).pathExtension.isEmpty
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
