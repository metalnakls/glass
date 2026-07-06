import GlassRemoteCore
import SwiftUI

struct TorrentRowView: View {
    let torrent: TorrentSummary
    let toggleTransfer: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: iconName)
                .font(.system(size: 32))
                .symbolRenderingMode(.multicolor)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(torrent.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(formatBytes(torrent.sizeWhenDone))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(formatPercent(torrent.percentDone))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                HStack(spacing: 12) {
                    Text(formatStatus(torrent.status))
                    Label(formatRate(torrent.rateDownload), systemImage: "arrow.down")
                    Label(formatRate(torrent.rateUpload), systemImage: "arrow.up")
                    if let queuePosition = torrent.queuePosition {
                        Text("#\(queuePosition + 1)")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)

                ProgressView(value: torrent.percentDone, total: 1)
                    .controlSize(.small)
            }

            Button(action: toggleTransfer) {
                Image(systemName: torrent.canStopTransfer ? "pause.fill" : "play.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .help(torrent.canStopTransfer ? "Pause" : "Resume")
        }
        .padding(.vertical, 10)
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
