import AppKit
import GlassRemoteCore
import SwiftUI
import UniformTypeIdentifiers

struct TorrentRowView: View, Equatable {
    let torrent: TorrentSummary
    var showsExtensions = false
    var density: TorrentRowDensity = .regular
    var grid = false
    var folderMotion: TorrentFolderMotion?
    var folderIDs: [String] = []
    var folderID: String?
    var iconPosition = 0
    var torrentGroupLandingID: String = ""
    @State private var clickRevision = 0
    @State private var pendingRunning: Bool?
    @State private var commandTask: Task<Void, Never>?
    @AppearanceStorage("GlassList.funMode") private var funMode = false
    @AppearanceStorage("GlassList.stateGap") private var stateGap = 8.0
    @AppearanceStorage("GlassList.progressGlowBlur") private var progressGlowBlur = 3.0
    @AppearanceStorage("GlassList.progressGlowStrength") private var progressGlowStrength = 0.8
    @AppearanceStorage("GlassList.progressLineWidth") private var progressLineWidth = 2.0
    @AppearanceStorage("GlassList.stateGlass") private var stateGlass = true
    @AppearanceStorage("GlassList.progressFilled") private var progressFilled = false
    var groupIsExpanded: Bool?
    var groupCount = 0
    var toggleGroupExpansion: (() -> Void)?
    var pendingOldName: String?
    var isAdding = false
    var shareUnavailable = false
    var thumbnailInput: TorrentThumbnailInput?
    var fileAction: ((TorrentFileActions.Action) -> Void)?
    let toggleTransfer: () async -> Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if grid {
                VStack(spacing: 10) {
                    leadingIcon.modifier(TorrentIconPersonality(role: iconRole, position: iconPosition, enabled: groupIsExpanded != true, grid: true)).scaleEffect(1.7).frame(height: 76)
                    Text(displayName(torrent.name)).font(.body).lineLimit(2).multilineTextAlignment(.center)
                    HStack { sizeLabel; Spacer(); transferButton }
                }.padding(16).frame(maxWidth: .infinity).frame(height: 164)
            } else { row }
        }
        .opacity(isAdding ? 0.45 : 1)
        .background(TorrentArtworkOverflow(enabled: funMode && !grid, order: iconPosition))
        .contentShape(Rectangle())
        .onChange(of: torrent.canStopTransfer) { _, running in
            if pendingRunning == running { pendingRunning = nil; commandTask?.cancel() }
        }
        .onChange(of: torrent.isCompleted) { _, completed in
            if completed { pendingRunning = nil; commandTask?.cancel() }
        }
        .onDisappear { commandTask?.cancel(); pendingRunning = nil }
    }

    private var iconRole: TorrentIconRole {
        if groupIsExpanded != nil { return .fan }
        if isFolderLike { return .folder }
        return thumbnailInput == nil ? .document : .artwork
    }

    private var row: some View {
        HStack(alignment: .center, spacing: 0) {
            if density.showsIcon {
                interactiveLeadingIcon.modifier(TorrentIconPersonality(role: iconRole, position: iconPosition, enabled: groupIsExpanded != true))
                    .background {
                        if let folderMotion, groupIsExpanded != nil || folderID != nil {
                            TorrentFolderLandingAnchor(controller: folderMotion, id: folderID ?? torrentGroupLandingID, pose: TorrentIconPose.forRole(iconRole, position: iconPosition))
                        }
                    }
                    .padding(.trailing, 12)
            }

            torrentContent
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { fileAction?(.open) }
                .simultaneousGesture(TapGesture().onEnded {
                    if NSEvent.modifierFlags.contains(.command) { fileAction?(.reveal) }
                })
            transferButton
                .padding(.leading, stateGap)
        }
    }

    nonisolated static func == (lhs: TorrentRowView, rhs: TorrentRowView) -> Bool {
        lhs.torrent == rhs.torrent
            && lhs.showsExtensions == rhs.showsExtensions
            && lhs.density == rhs.density
            && lhs.grid == rhs.grid
            && lhs.folderIDs == rhs.folderIDs
            && lhs.iconPosition == rhs.iconPosition
            && lhs.torrentGroupLandingID == rhs.torrentGroupLandingID
            && lhs.folderID == rhs.folderID
            && lhs.groupIsExpanded == rhs.groupIsExpanded
            && lhs.groupCount == rhs.groupCount
            && lhs.pendingOldName == rhs.pendingOldName
            && lhs.isAdding == rhs.isAdding
            && lhs.shareUnavailable == rhs.shareUnavailable
            && lhs.thumbnailInput == rhs.thumbnailInput
    }

    @ViewBuilder
    private var interactiveLeadingIcon: some View {
        if groupIsExpanded != nil {
            leadingIcon
        } else {
            leadingIcon
                .onTapGesture(count: 2) { fileAction?(.open) }
                .simultaneousGesture(TapGesture().onEnded {
                    if NSEvent.modifierFlags.contains(.command) { fileAction?(.reveal) }
                })
        }
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
                        .contentShape(Rectangle().inset(by: -12))
                        .contentTransition(.symbolEffect(.replace))
                } else {
                    GroupFolderFanIcon(count: groupCount, controller: folderMotion, ids: folderIDs)
                        .frame(width: 36, height: 42)
                }
            }
            .buttonStyle(.plain)
            .offset(x: groupIsExpanded && !grid ? TorrentIconPose.forRole(.fan, position: iconPosition).x : 0)
            .help(groupIsExpanded ? "Hide Torrents" : "Show Torrents")
            .accessibilityLabel(groupIsExpanded ? "Collapse Group" : "Expand Group")
        } else if showsActivityIcon {
            activityProgress
        } else if let folderID, let folderMotion {
            TorrentFileIcon(fileName: "", isFolder: true)
                .opacity(folderMotion.flyingIDs.contains(folderID) ? 0 : 1)
                .transaction { $0.animation = nil }
                .background(TorrentFolderRevealAnchor(controller: folderMotion, id: folderID,
                    visible: !folderMotion.flyingIDs.contains(folderID)))
                .transition(.identity)
                .frame(width: 36, height: 42)
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
        HStack(alignment: .center) {
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

    private var stateDiameter: CGFloat { density == .compact && !grid ? 24 : 36 }

    private var transferButton: some View {
        ZStack {
            if !isAdding && !stateGlass && !progressFilled {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: progressLineWidth)
                    .allowsHitTesting(false)
                Circle().trim(from: 0, to: progress)
                    .stroke(Color.primary.opacity(progressGlowStrength), style: StrokeStyle(lineWidth: progressLineWidth * 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .blur(radius: progressGlowBlur)
                    .allowsHitTesting(false)
                Circle().trim(from: 0, to: progress)
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: progressLineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .allowsHitTesting(false)
            }
            stateControl
                .help(stateLabel)
                .accessibilityLabel(stateLabel)
                .accessibilityValue("\(progress.formatted(.percent.precision(.fractionLength(0)))) downloaded")
        }
        .frame(width: stateDiameter, height: stateDiameter)
        .animation(reduceMotion ? nil : .linear(duration: 0.2), value: progress)
        .padding(2)
    }

    @ViewBuilder
    private var stateControl: some View {
        if isAdding {
            GlassActivityIndicator(label: "Adding torrent")
                .frame(width: stateDiameter, height: stateDiameter)
        } else if stateGlass {
            Button(action: requestStateChange) { stateGlyph.frame(width: stateDiameter, height: stateDiameter) }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .allowsHitTesting(!shareUnavailable && !torrent.isCompleted && pendingRunning == nil)
        } else if shareUnavailable || torrent.isCompleted {
            stateImage
        } else {
            Button(action: requestStateChange) { stateImage }
                .buttonStyle(.plain)
                .allowsHitTesting(pendingRunning == nil)
        }
    }

    private func requestStateChange() {
        clickRevision &+= 1
        pendingRunning = !torrent.canStopTransfer
        commandTask?.cancel()
        commandTask = Task {
            let succeeded = await toggleTransfer()
            guard !Task.isCancelled else { return }
            if !succeeded { pendingRunning = nil; return }
            if pendingRunning == torrent.canStopTransfer { pendingRunning = nil; return }
            // Keep the optimistic symbol alive until refreshed server state arrives.
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            pendingRunning = nil
        }
    }

    private var stateImage: some View {
        ZStack {
            Circle().fill(progressFilled ? Color.white : Color(nsColor: .controlBackgroundColor).opacity(0.5))
            if progressFilled {
                ProgressDisc(progress: progress).fill(.black)
            }
            stateGlyph.foregroundStyle(progressFilled ? Color.black : Color.primary)
            if progressFilled {
                stateGlyph.foregroundStyle(.white).mask(ProgressDisc(progress: progress))
            }
        }
        .frame(width: density == .compact && !grid ? 20 : 28, height: density == .compact && !grid ? 20 : 28)
        .phaseAnimator([false, true], trigger: clickRevision) { view, pressed in
            view.scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
        } animation: { _ in .easeOut(duration: 0.12) }
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: stateSymbol)
    }

    private var stateGlyph: some View {
        Image(systemName: stateSymbol)
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
            .symbolEffect(.rotate.wholeSymbol.clockwise, options: .repeating.speed(1.2), isActive: pendingRunning != nil && !reduceMotion)
            .opacity(reduceMotion && pendingRunning != nil ? 0.65 : 1)
    }

    private var progress: Double {
        torrent.percentDone.isFinite ? min(max(torrent.percentDone, 0), 1) : 0
    }

    private var stateSymbol: String {
        if shareUnavailable { return "questionmark" }
        if torrent.isCompleted { return "checkmark" }
        return (pendingRunning ?? torrent.canStopTransfer) ? "pause.fill" : "play.fill"
    }

    private var stateLabel: String {
        if isAdding { return "Adding torrent" }
        if shareUnavailable { return torrent.errorString?.isEmpty == false ? torrent.errorString! : "Download unavailable" }
        if torrent.isCompleted { return "Finished" }
        return torrent.canStopTransfer ? "Pause" : "Resume"
    }

    private var isFolderLike: Bool {
        if thumbnailInput != nil { return false }
        return TorrentArtworkKind.isFolder(name: torrent.name, fileCount: torrent.fileCount)
    }

    private func displayName(_ name: String) -> String {
        guard !showsExtensions, groupIsExpanded == nil, torrent.fileCount.map({ $0 <= 1 }) ?? true else { return name }
        return TorrentExtensionPolicy.name(name, hiding: TorrentExtensionPolicy.hiddenExtension(paths: [name]))
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
    var controller: TorrentFolderMotion?
    var ids: [String] = []

    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { index in
                matchedFanIcon(index)
                    .zIndex(Double(index))
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func matchedFanIcon(_ index: Int) -> some View {
        if let controller, ids.indices.contains(index) {
            fanIcon(index)
                .opacity(controller.flyingIDs.contains(ids[index]) ? 0 : 1)
                .transaction { $0.animation = nil }
                .background(TorrentFolderRevealAnchor(controller: controller, id: ids[index],
                    visible: !controller.flyingIDs.contains(ids[index])))
                .transition(.identity)
        } else { fanIcon(index) }
    }

    private func fanIcon(_ index: Int) -> some View {
        TorrentFileIcon(fileName: "", isFolder: true, size: 27)
            .rotationEffect(rotation(for: index), anchor: .bottom)
            .offset(offset(for: index))
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
    @Environment(\.glassSampleArtwork) private var sampleArtwork
    @State private var thumbnail: NSImage?
    @State private var artworkTint = Color.black
    @AppearanceStorage("GlassList.funMode") private var funMode = false
    @AppearanceStorage("GlassList.posterColoredShadows") private var coloredShadows = true

    @ViewBuilder
    var body: some View {
        if isFolder {
            // Folder flights need only the cached system image. Visibility tracking
            // and thumbnail revisions otherwise invalidate every moving folder.
            Image(nsImage: nativeIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(funMode ? 0.10 : 0), radius: 3, y: 2)
        } else {
        Image(nsImage: displayedThumbnail ?? nativeIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .shadow(color: (coloredShadows && displayedThumbnail != nil ? artworkTint : .black).opacity(funMode ? 0.12 : 0), radius: 5, y: 3)
            // List already realizes a viewport buffer and the shared preloader
            // warms nearby artwork. Load once on realization rather than adding
            // a visibility observer and a second state/layout update per icon.
            .task(id: ThumbnailTaskID(input: thumbnailInput, revision: TorrentThumbnailService.shared.revision)) {
                if sampleArtwork {
                    let image = TorrentSampleArtwork.image(for: fileName)
                    thumbnail = image; artworkTint = TorrentArtworkTint.color(image)
                    return
                }
                guard let input = thumbnailInput, !isFolder else { thumbnail = nil; return }
                thumbnail = TorrentThumbnailService.shared.cachedImage(for: input)
                if let thumbnail { artworkTint = TorrentArtworkTint.color(thumbnail) }
                let image = await TorrentThumbnailService.shared.image(for: input)
                guard !Task.isCancelled else { return }
                thumbnail = image
                if let image { artworkTint = TorrentArtworkTint.color(image) }
            }
        }
    }

    private var displayedThumbnail: NSImage? {
        thumbnail ?? thumbnailInput.flatMap { TorrentThumbnailService.shared.cachedImage(for: $0) }
    }

    private var nativeIcon: NSImage {
        TorrentFileIconCache.icon(fileName: fileName, isFolder: isFolder)
    }
}

private struct ThumbnailTaskID: Equatable {
    let input: TorrentThumbnailInput?
    let revision: Int
}

@MainActor
enum TorrentFileIconCache {
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


private struct ProgressDisc: Shape {
    var progress: Double
    var animatableData: Double { get { progress } set { progress = newValue } }
    func path(in rect: CGRect) -> Path {
        guard progress > 0 else { return Path() }
        if progress >= 1 { return Path(ellipseIn: rect) }
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(-90), endAngle: .degrees(-90 + progress * 360), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// A multi-file root remains a folder even if only one file is wanted/downloaded.
enum TorrentArtworkKind {
    static func isFolder(name: String, fileCount: Int?) -> Bool {
        (fileCount ?? 0) > 1 || URL(fileURLWithPath: name).pathExtension.isEmpty
    }
}
