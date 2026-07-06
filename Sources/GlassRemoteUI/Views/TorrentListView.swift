import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

struct TorrentListView: View {
    @ObservedObject var model: RemoteAppModel
    @Binding var selection: String?
    let rename: (TorrentSummary) -> Void
    let remove: (TorrentSummary, Bool) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(model.filteredTorrents) { torrent in
                TorrentRowView(torrent: torrent) {
                    Task {
                        if torrent.canStopTransfer {
                            await model.stop(torrent)
                        } else {
                            await model.start(torrent)
                        }
                    }
                }
                .tag(torrent.hashString)
                .contextMenu {
                    torrentContextMenu(for: torrent)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Remove", role: .destructive) {
                        remove(torrent, false)
                    }
                    Button(torrent.canStopTransfer ? "Pause" : "Resume") {
                        Task {
                            if torrent.canStopTransfer {
                                await model.stop(torrent)
                            } else {
                                await model.start(torrent)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.filteredTorrents.isEmpty {
                ContentUnavailableView(
                    model.isLocalSourceSelected ? "Select a Remote" : "No Torrents",
                    systemImage: model.isLocalSourceSelected ? "server.rack" : "tray",
                    description: Text(model.isLocalSourceSelected ? "Add or select a Transmission server in the sidebar." : "This filter has no matching torrents.")
                )
            }
        }
        .glassSoftTopScrollEdge()
    }

    @ViewBuilder
    private func torrentContextMenu(for torrent: TorrentSummary) -> some View {
        Button(torrent.canStopTransfer ? "Pause" : "Resume") {
            Task {
                if torrent.canStopTransfer {
                    await model.stop(torrent)
                } else {
                    await model.start(torrent)
                }
            }
        }
        Button("Verify") {
            Task { await model.verify(torrent) }
        }
        Button("Announce") {
            Task { await model.reannounce(torrent) }
        }
        Menu("Priority") {
            Button("High") {
                Task { await model.setTorrentPriority(torrent, priority: 1) }
            }
            Button("Normal") {
                Task { await model.setTorrentPriority(torrent, priority: 0) }
            }
            Button("Low") {
                Task { await model.setTorrentPriority(torrent, priority: -1) }
            }
        }
        Menu("Queue") {
            Button("Move to Top") {
                Task { await model.moveInQueue([torrent], direction: .top) }
            }
            Button("Move Up") {
                Task { await model.moveInQueue([torrent], direction: .up) }
            }
            Button("Move Down") {
                Task { await model.moveInQueue([torrent], direction: .down) }
            }
            Button("Move to Bottom") {
                Task { await model.moveInQueue([torrent], direction: .bottom) }
            }
        }
        Button("Rename...") {
            rename(torrent)
        }
        Divider()
        Button("Remove") {
            remove(torrent, false)
        }
        Button("Remove and Delete Data", role: .destructive) {
            remove(torrent, true)
        }
    }
}
