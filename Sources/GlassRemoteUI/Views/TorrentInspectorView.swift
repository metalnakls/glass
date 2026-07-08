import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

struct TorrentInspectorView: View {
    @ObservedObject var model: RemoteAppModel
    let selectedTorrent: TorrentSummary?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                serverSection

                if selectedTorrent != nil {
                    Divider()
                    torrentSection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 260, max: 380)
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.selectedSourceName)
                .font(.title2.bold())

            InspectorField("Address", model.selectedSourceRPCURL.host(percentEncoded: false) ?? "Local")
            InspectorField("RPC", model.selectedSourceRPCURL.absoluteString)
            InspectorField("User", model.selectedSourceUsername.isEmpty ? "None" : model.selectedSourceUsername)
            InspectorField("Space", serverSpace)
            InspectorField("Download", model.stats.map { formatRate($0.downloadSpeed) } ?? "0 KB/s")
            InspectorField("Upload", model.stats.map { formatRate($0.uploadSpeed) } ?? "0 KB/s")
        }
    }

    @ViewBuilder
    private var torrentSection: some View {
        if let details = model.selectedTorrentDetails {
            VStack(alignment: .leading, spacing: 14) {
                Text(details.name)
                    .font(.title3.bold())
                    .lineLimit(3)

                DisclosureGroup("Info") {
                    VStack(alignment: .leading, spacing: 8) {
                        InspectorField("Status", details.status.map(formatStatus) ?? "Unavailable")
                        InspectorField("Progress", details.percentDone.map(formatPercent) ?? "Unavailable")
                        InspectorField("Size", formatBytes(details.sizeWhenDone ?? details.totalSize))
                        InspectorField("Left", formatBytes(details.leftUntilDone))
                        InspectorField("Ratio", formatRatio(details.uploadRatio))
                        InspectorField("Download Dir", details.downloadDir ?? "Unavailable")
                        InspectorField("Added", formatTimestamp(details.addedDate))
                        InspectorField("Active", formatTimestamp(details.activityDate))
                        InspectorField("Downloaded", formatBytes(details.downloadedEver))
                        InspectorField("Uploaded", formatBytes(details.uploadedEver))
                    }
                    .padding(.top, 8)
                }

                DisclosureGroup("Files") {
                    TorrentFilesSection(model: model, details: details)
                        .padding(.top, 8)
                }

                DisclosureGroup("Peers") {
                    VStack(alignment: .leading, spacing: 8) {
                        if details.peers.isEmpty {
                            Text("No peers")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(details.peers.enumerated()), id: \.offset) { _, peer in
                                InspectorField(
                                    peer.address ?? "Peer",
                                    "\(formatRate(peer.rateToClient ?? 0)) down, \(formatRate(peer.rateToPeer ?? 0)) up"
                                )
                            }
                        }
                    }
                    .padding(.top, 8)
                }

                DisclosureGroup("Trackers") {
                    VStack(alignment: .leading, spacing: 8) {
                        if details.trackerStats.isEmpty {
                            Text("No trackers")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(details.trackerStats) { tracker in
                                InspectorField(
                                    tracker.host ?? tracker.announce ?? "Tracker",
                                    tracker.lastAnnounceResult?.isEmpty == false ? tracker.lastAnnounceResult! : "Ready"
                                )
                            }
                        }
                    }
                    .padding(.top, 8)
                }

                DisclosureGroup("Pieces") {
                    VStack(alignment: .leading, spacing: 8) {
                        InspectorField("Pieces", details.pieceCount.map(String.init) ?? "Unavailable")
                        InspectorField("Piece Size", formatBytes(details.pieceSize))
                        if let pieceCount = details.pieceCount, let pieces = details.pieces {
                            InspectorField("Complete", "\(completedPieceCount(from: pieces, total: pieceCount)) of \(pieceCount)")
                        }
                    }
                    .padding(.top, 8)
                }

                DisclosureGroup("Settings") {
                    VStack(alignment: .leading, spacing: 8) {
                        InspectorField("Download Limit", limitText(limit: details.downloadLimit, enabled: details.downloadLimited))
                        InspectorField("Upload Limit", limitText(limit: details.uploadLimit, enabled: details.uploadLimited))
                        InspectorField("Seed Ratio", details.seedRatioLimit.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "Unavailable")
                        InspectorField("Priority", formatPriority(details.bandwidthPriority))
                        InspectorField("Queue", details.queuePosition.map { "#\($0 + 1)" } ?? "Unavailable")
                        InspectorField("Private", formatBool(details.isPrivate))
                    }
                    .padding(.top, 8)
                }
            }
        } else if model.isLoadingTorrentDetails {
            ProgressView("Loading details...")
        } else if let error = model.torrentDetailsError {
            Text(error)
                .foregroundStyle(.secondary)
        } else if let selectedTorrent {
            VStack(alignment: .leading, spacing: 10) {
                Text(selectedTorrent.name)
                    .font(.title3.bold())
                Text("Select a torrent to load details.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var serverSpace: String {
        guard let bytes = model.serverFreeSpace[model.selectedSourceID]?.availableBytes
        else {
            return "Unavailable"
        }
        return formatBytes(bytes)
    }

    private func limitText(limit: Int?, enabled: Bool?) -> String {
        guard enabled == true, let limit else { return "Unlimited" }
        return "\(limit) KB/s"
    }
}

private struct TorrentFilesSection: View {
    @ObservedObject var model: RemoteAppModel
    let details: TorrentDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(details.files.enumerated()), id: \.offset) { index, file in
                let stats = details.fileStats.indices.contains(index) ? details.fileStats[index] : nil
                HStack(alignment: .firstTextBaseline) {
                    Toggle(
                        isOn: Binding(
                            get: { stats?.wanted ?? true },
                            set: { isWanted in
                                Task {
                                    await model.setFileWanted(
                                        details.summaryFallback,
                                        fileIndices: [index],
                                        wanted: isWanted
                                    )
                                }
                            }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .lineLimit(2)
                            Text("\(formatBytes(file.bytesCompleted)) of \(formatBytes(file.length))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Menu(formatPriority(stats?.priority)) {
                        Button("High") {
                            Task { await model.setFilePriority(details.summaryFallback, fileIndices: [index], priority: 1) }
                        }
                        Button("Normal") {
                            Task { await model.setFilePriority(details.summaryFallback, fileIndices: [index], priority: 0) }
                        }
                        Button("Low") {
                            Task { await model.setFilePriority(details.summaryFallback, fileIndices: [index], priority: -1) }
                        }
                    }
                    .menuStyle(.button)
                    .fixedSize()
                }
            }
        }
    }
}

private struct InspectorField: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow(alignment: .top) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 86, alignment: .leading)
                Text(value)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .font(.callout)
    }
}

private extension TorrentDetails {
    var summaryFallback: TorrentSummary {
        TorrentSummary(
            id: id,
            hashString: hashString,
            name: name,
            status: status ?? TransmissionTorrentStatus.stopped.rawValue,
            percentDone: percentDone ?? 0,
            rateDownload: 0,
            rateUpload: 0,
            sizeWhenDone: sizeWhenDone ?? totalSize ?? 0,
            leftUntilDone: leftUntilDone ?? 0,
            eta: eta ?? -1,
            uploadRatio: uploadRatio ?? -1,
            peersConnected: nil,
            downloadDir: downloadDir,
            bandwidthPriority: bandwidthPriority,
            queuePosition: queuePosition
        )
    }
}
