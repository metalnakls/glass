import GlassRemoteCore
import SwiftUI

struct TorrentRowView: View {
    let torrent: TorrentSummary
    let toggleTransfer: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            regularRow
            compactRow
        }
        .padding(.vertical, 8)
    }

    private var regularRow: some View {
        HStack(spacing: 14) {
            Image(systemName: iconName)
                .font(.system(size: 32))
                .symbolRenderingMode(.multicolor)
                .frame(width: 44)

            torrentContent

            transferButton
        }
    }

    private var compactRow: some View {
        HStack(spacing: 8) {
            torrentContent
            transferButton
        }
    }

    private var torrentContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(torrent.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text(formatBytes(torrent.sizeWhenDone))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                Text(formatPercent(torrent.percentDone))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .monospacedDigit()

            ProgressView(value: torrent.percentDone, total: 1)
                .controlSize(.small)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var transferButton: some View {
        Button(action: toggleTransfer) {
            Image(systemName: torrent.canStopTransfer ? "pause.fill" : "play.fill")
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .help(torrent.canStopTransfer ? "Pause" : "Resume")
    }

    private var iconName: String {
        let lowercasedName = torrent.name.lowercased()
        if lowercasedName.hasSuffix(".mkv") || lowercasedName.hasSuffix(".mp4") || lowercasedName.hasSuffix(".mov") {
            return "doc.richtext"
        }
        if lowercasedName.hasSuffix(".mp3") || lowercasedName.hasSuffix(".flac") {
            return "waveform"
        }
        return torrent.isCompleted ? "folder" : "folder.badge.arrow.down"
    }
}
