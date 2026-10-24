import GlassRemoteServices
import SwiftUI

/// An unfinished Add that appears above the loading rows. It uses the same row
/// geometry, dimmed state, trailing status and circular action as an add that is
/// still queued on a server; Resume reopens the saved editor instead.
struct TorrentDraftRow: View {
    let model: RemoteAppModel
    let draft: TorrentAddDraft
    var grid = false
    let rowHeight: CGFloat
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    let columns: TorrentRowColumns
    let resume: () -> Void
    let discard: () -> Void
    var select: () -> Void = {}
    @AppearanceStorage("GlassList.funMode") private var funMode = false

    private var name: String { draft.displayName ?? glassText("New Torrent") }
    private var stateDiameter: CGFloat { GlassListMetrics.stateDiameter(compact: columns.compact && !grid) }

    var body: some View {
        Group {
            if grid { gridBody } else { row }
        }
        .opacity(0.45)
        .background(TorrentArtworkOverflow(enabled: funMode && !grid))
        .contentShape(Rectangle())
        .glassContextMenu(select: select) {
            Button { resume() } label: { Label(glassText("Resume Draft"), systemImage: "arrow.clockwise") }
            TorrentRemovalActions(kind: .draft) { _ in discard() }
        }
        .help(helpText)
    }

    private var row: some View {
        HStack(spacing: 0) {
            if columns.showsArtwork {
                TorrentFileIcon(fileName: name, isFolder: false)
                    .frame(width: TorrentRowColumns.artworkWidth, height: 42)
                    .modifier(TorrentIconPersonality(role: .document))
                    .padding(.trailing, TorrentRowColumns.artworkGap)
            }

            Text(name)
                .font(columns.compact ? .callout : .body)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Text(glassText("Draft"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()

            resumeButton
                .padding(.leading, columns.stateGap)
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, trailingPadding)
        .frame(height: rowHeight)
    }

    private var gridBody: some View {
        VStack(spacing: 10) {
            TorrentFileIcon(fileName: name, isFolder: false)
                .modifier(TorrentIconPersonality(role: .document, grid: true))
                .scaleEffect(1.7)
                .frame(height: 76)
            Text(name)
                .font(.body)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            HStack {
                Text(glassText("Draft"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                resumeButton
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .frame(height: 164)
    }

    private var resumeButton: some View {
        Button { resume() } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: stateDiameter, height: stateDiameter)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .modifier(TorrentRowStateSlot(compact: columns.compact && !grid))
        .help(glassText("Resume Draft"))
        .accessibilityLabel(glassText("Resume Draft"))
    }

    private var helpText: String {
        var parts = [name, glassText("Draft"), sourceName]
        if let directory = draft.downloadDirectory, !directory.isEmpty {
            parts.append(URL(fileURLWithPath: directory).lastPathComponent)
        }
        return parts.joined(separator: " · ")
    }

    private var sourceName: String {
        guard let stored = draft.sourceID else { return glassText("Default Location") }
        guard TorrentAddDraftRestore.sourceID(stored, in: model) != nil else {
            return glassText("Server Unavailable")
        }
        return model.sourceName(for: stored)
    }
}
