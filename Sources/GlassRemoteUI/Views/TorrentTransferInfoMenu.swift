import AppKit
import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

/// Shared, on-demand context-menu telemetry; it never changes inspector selection.
struct TorrentTransferInfoMenu: View {
    let model: RemoteAppModel
    let sourceID: UUID
    let torrents: [TorrentSummary]
    @State private var details: [TorrentDetails] = []

    private var requestKey: String { sourceID.uuidString + torrents.map(\.hashString).joined(separator: ":") }
    private var seeds: Int? {
        let counts = details.compactMap { detail in
            detail.trackerStats.compactMap(\.seederCount).filter { $0 >= 0 }.max()
        }
        return counts.count == torrents.count && !counts.isEmpty ? counts.reduce(0, +) : nil
    }

    var body: some View {
        Group {
            TorrentInfoMenuRow(title: "Download speed", value: formatRate(torrents.reduce(0) { $0 + $1.rateDownload }))
                .task(id: requestKey) {
                    guard !torrents.isEmpty else { return }
                    do {
                        let next = try await model.fetchDetails(for: torrents, including: [.peers, .trackers], sourceID: sourceID)
                        guard !Task.isCancelled else { return }
                        details = next
                    } catch { /* Unavailable telemetry stays unknown, rather than showing a false zero. */ }
                }
            TorrentInfoMenuRow(title: "Upload speed", value: formatRate(torrents.reduce(0) { $0 + $1.rateUpload }))
            TorrentInfoMenuRow(title: "Seeds", value: seeds.map(String.init) ?? "—")
            TorrentInfoMenuRow(title: "Peers", value: torrents.allSatisfy { $0.peersConnected != nil }
                ? String(torrents.reduce(0) { $0 + ($1.peersConnected ?? 0) }) : "—")
            TorrentInfoMenuRow(title: "Remaining", value: formatBytes(torrents.reduce(0) { $0 + $1.leftUntilDone }))
            if let torrent = torrents.first, torrents.count == 1 {
                TorrentInfoMenuRow(title: "Upload ratio", value: torrent.uploadRatio >= 0 ? formatNumber(torrent.uploadRatio) : "—")
            }
        }
    }
}

/// Info remains readable and useful: clicking copies the value instead of presenting a disabled menu item.
struct TorrentInfoMenuRow: View {
    let title: String
    let value: String
    var body: some View {
        Button("\(glassText(title)): \(value)") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
        .textCase(nil)
        .help(glassText("Copy value"))
    }
}
