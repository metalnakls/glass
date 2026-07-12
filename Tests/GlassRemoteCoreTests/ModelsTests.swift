import Testing
@testable import GlassRemoteCore

@Suite("Core models")
struct ModelsTests {
    @Test("maps Transmission torrent statuses")
    func mapsTransmissionTorrentStatuses() {
        #expect(TransmissionTorrentStatus(rawValue: 0) == .stopped)
        #expect(TransmissionTorrentStatus(rawValue: 1) == .checkQueued)
        #expect(TransmissionTorrentStatus(rawValue: 2) == .checking)
        #expect(TransmissionTorrentStatus(rawValue: 3) == .downloadQueued)
        #expect(TransmissionTorrentStatus(rawValue: 4) == .downloading)
        #expect(TransmissionTorrentStatus(rawValue: 5) == .seedQueued)
        #expect(TransmissionTorrentStatus(rawValue: 6) == .seeding)
        #expect(TransmissionTorrentStatus(rawValue: 99) == nil)
    }

    @Test("uses status for download and stop semantics")
    func usesStatusForTransferHelpers() {
        let activelyDownloading = makeTorrent(status: TransmissionTorrentStatus.downloading.rawValue, percentDone: 1)
        let queuedDownload = makeTorrent(status: TransmissionTorrentStatus.downloadQueued.rawValue)
        let queuedSeed = makeTorrent(status: TransmissionTorrentStatus.seedQueued.rawValue)
        let stopped = makeTorrent(status: TransmissionTorrentStatus.stopped.rawValue)
        let seedingWithDownloadRate = makeTorrent(status: TransmissionTorrentStatus.seeding.rawValue, rateDownload: 2_048)

        #expect(activelyDownloading.status == 4)
        #expect(activelyDownloading.isDownloading)
        #expect(activelyDownloading.isCompleted)
        #expect(queuedDownload.isDownloading == false)
        #expect(queuedDownload.canStopTransfer)
        #expect(queuedSeed.canStopTransfer)
        #expect(stopped.canStopTransfer == false)
        #expect(seedingWithDownloadRate.isDownloading == false)
    }

    @Test("detects active metadata downloads")
    func detectsActiveMetadataDownloads() {
        let downloadingMetadata = makeTorrent(
            status: TransmissionTorrentStatus.downloading.rawValue,
            metadataPercentComplete: 0.4
        )
        let metadataComplete = makeTorrent(
            status: TransmissionTorrentStatus.downloading.rawValue,
            metadataPercentComplete: 1
        )
        let stoppedMetadata = makeTorrent(
            status: TransmissionTorrentStatus.stopped.rawValue,
            metadataPercentComplete: 0.4
        )

        #expect(downloadingMetadata.isDownloadingMetadata)
        #expect(metadataComplete.isDownloadingMetadata == false)
        #expect(stoppedMetadata.isDownloadingMetadata == false)
        #expect(makeTorrent().isDownloadingMetadata == false)
    }

    @Test("preserves incoming order and drops stale torrents")
    func mergerPreservesIncomingOrder() {
        let firstExisting = makeTorrent(id: 1, hashString: "first", name: "First")
        let secondExisting = makeTorrent(id: 2, hashString: "second", name: "Second")
        let staleExisting = makeTorrent(id: 3, hashString: "stale", name: "Stale")
        let updatedSecond = makeTorrent(id: 2, hashString: "second", name: "Second Updated", queuePosition: 8)

        let merged = TorrentListMerger.merge(
            existing: [firstExisting, secondExisting, staleExisting],
            incoming: [updatedSecond, firstExisting]
        )

        #expect(merged.map(\.id) == [2, 1])
        #expect(merged.map(\.name) == ["Second Updated", "First"])
        #expect(merged.first?.queuePosition == 8)
    }

    @Test("keeps unchanged incoming torrents unchanged")
    func mergerReusesUnchangedValues() {
        let unchanged = makeTorrent(id: 11, hashString: "unchanged", name: "Unchanged", queuePosition: 2)
        let changed = makeTorrent(id: 12, hashString: "changed", name: "Changed")
        let changedIncoming = makeTorrent(id: 12, hashString: "changed", name: "Changed Incoming")

        let merged = TorrentListMerger.merge(
            existing: [unchanged, changed],
            incoming: [unchanged, changedIncoming]
        )

        #expect(merged[0] == unchanged)
        #expect(merged[0].queuePosition == 2)
        #expect(merged[1] == changedIncoming)
    }
}

private func makeTorrent(
    id: Int = 1,
    hashString: String = "hash",
    name: String = "Torrent",
    status: Int = TransmissionTorrentStatus.stopped.rawValue,
    percentDone: Double = 0,
    metadataPercentComplete: Double? = nil,
    rateDownload: Double = 0,
    queuePosition: Int? = nil
) -> TorrentSummary {
    TorrentSummary(
        id: id,
        hashString: hashString,
        name: name,
        status: status,
        percentDone: percentDone,
        metadataPercentComplete: metadataPercentComplete,
        rateDownload: rateDownload,
        rateUpload: 0,
        sizeWhenDone: 100,
        leftUntilDone: percentDone >= 1 ? 0 : 100,
        eta: -1,
        uploadRatio: 0,
        peersConnected: nil,
        downloadDir: nil,
        queuePosition: queuePosition
    )
}
