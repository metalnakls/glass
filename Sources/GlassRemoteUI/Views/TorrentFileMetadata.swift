import SwiftUI

/// Sizes share a trailing column; progress is secondary and adapts to name space.
struct TorrentFileMetadata: View {
    enum Presentation { case sizeOnly, inline, stacked }
    let size: String
    let sizeColumnText: String
    let progress: String?
    let presentation: Presentation

    var body: some View {
        Group {
            switch presentation {
            case .sizeOnly: sizeLabel
            case .inline:
                HStack(spacing: TorrentFileListLayout.shared.metadataGap) {
                    Text("100%").hidden().overlay(alignment: .trailing) {
                        if let progress { Text(progress) }
                    }
                    sizeLabel
                }
            case .stacked:
                VStack(alignment: .trailing, spacing: TorrentFileListLayout.shared.metadataGap) {
                    sizeLabel
                    if let progress { Text(progress).font(.caption2) }
                }
            }
        }
        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var sizeLabel: some View {
        Text(sizeColumnText).textCase(nil).hidden().overlay(alignment: .trailing) {
            Text(size).textCase(nil).fixedSize()
        }
    }
}
