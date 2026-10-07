import GlassRemoteCore
import SwiftUI

/// One equal-width segment per selected torrent; total completion remains byte-weighted.
struct TorrentInspectorProgress {
    struct Segment: Identifiable {
        let id: String
        let fraction: Double
        let name: String
    }
    let segments: [Segment]
    let totalBytes: UInt64
    let fraction: Double
    let rate: Double
    let peers: Int

    init(torrents: [TorrentSummary]) {
        segments = torrents.map { Segment(id: $0.hashString, fraction: Self.clamp($0.percentDone), name: $0.name) }
        totalBytes = torrents.reduce(0) { $0 + $1.sizeWhenDone }
        let completed = torrents.reduce(0.0) { $0 + Double($1.sizeWhenDone) * Self.clamp($1.percentDone) }
        fraction = totalBytes > 0 ? completed / Double(totalBytes) : 0
        rate = torrents.reduce(0) { $0 + $1.rateDownload }
        peers = torrents.reduce(0) { $0 + ($1.peersConnected ?? 0) }
    }

    private static func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
}

struct TorrentInspectorProgressView: View {
    let progress: TorrentInspectorProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ForEach(progress.segments) { segment in
                            ZStack(alignment: .leading) {
                                Color.primary.opacity(0.12)
                                Color.secondary.frame(width: geometry.size.width / CGFloat(max(1, progress.segments.count)) * segment.fraction)
                            }
                            .frame(maxWidth: .infinity)
                            .overlay(alignment: .trailing) {
                                if segment.id != progress.segments.last?.id {
                                    Rectangle().fill(.background.opacity(0.65)).frame(width: 1).blur(radius: 0.5)
                                }
                            }
                            .help("\(segment.name): \(formatPercent(segment.fraction))")
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Download progress")
                .accessibilityValue(formatPercent(progress.fraction))
                Text(formatBytes(progress.totalBytes)).textCase(nil).fixedSize(horizontal: true, vertical: false)
            }
            .font(.callout).monospacedDigit()

        }
    }
}
