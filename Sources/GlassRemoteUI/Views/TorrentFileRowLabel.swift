import GlassRemoteCore
import SwiftUI

/// Canonical file identity and progress presentation shared by every torrent-file container.
struct TorrentFileRowLabel: View {
    let file: TorrentFile
    var displayName: String?
    var completedBytes: UInt64?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayName ?? file.name)
                .lineLimit(2)
                .truncationMode(.middle)

            Text(detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var detailText: String {
        guard let completedBytes else { return formatBytes(file.length) }
        return "\(formatBytes(completedBytes)) of \(formatBytes(file.length))"
    }
}
