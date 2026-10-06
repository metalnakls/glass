import Foundation
import GlassRemoteCore
@testable import GlassRemoteServices
import Observation
import SwiftUI
import Synchronization
import Testing
@testable import GlassRemoteUI

@MainActor @Suite("Row update boundaries")
struct TorrentRowUpdateTests {
    @Test("refresh telemetry does not subscribe the swipe controls")
    func swipeObservation() {
        let record = TorrentRecord(summary(), sourceID: UUID())
        let invalidated = Mutex(false)
        let row = TorrentNativeSwipeRow(enabled: true, remove: { _ in }, presentationChanged: { _ in }) {
            Text(record.summary.rateDownload.formatted())
        }
        withObservationTracking {
            _ = row.body
        } onChange: {
            invalidated.withLock { $0 = true }
        }
        record.apply(summary(rateDownload: 200))
        #expect(!invalidated.withLock { $0 })
    }

    @Test("peer, upload, queue and ETA telemetry does not redraw the visible row")
    func irrelevantTelemetry() {
        #expect(view(summary()) == view(summary(telemetry: 42)))
    }

    @Test("display and transfer changes still redraw the row")
    func visibleChanges() {
        let original = view(summary())
        let changed = [summary(name: "Different.mkv"), summary(status: 0), summary(progress: 0.8),
                       summary(rateDownload: 200), summary(fileCount: 2), summary(priority: 1),
                       summary(metadata: 0.5), summary(doneDate: 100)]
        for torrent in changed { #expect(original != view(torrent)) }
        var unavailable = view(summary())
        unavailable.shareUnavailable = true
        #expect(unavailable != original)
    }

    private func view(_ torrent: TorrentSummary) -> TorrentRowView {
        TorrentRowView(torrent: torrent, toggleTransfer: { true })
    }

    private func summary(name: String = "Movie.mkv", status: Int = 4, progress: Double = 0.5,
                         rateDownload: Double = 100, fileCount: Int = 1, priority: Int = 0,
                         metadata: Double = 1, doneDate: Int? = nil, telemetry: Int = 0) -> TorrentSummary {
        TorrentSummary(id: 1, hashString: "row-updates", name: name, status: status,
            percentDone: progress, metadataPercentComplete: metadata, rateDownload: rateDownload,
            rateUpload: Double(telemetry), sizeWhenDone: 1000, leftUntilDone: 500,
            eta: telemetry, uploadRatio: Double(telemetry), peersConnected: telemetry,
            downloadDir: "/downloads", bandwidthPriority: priority, queuePosition: telemetry,
            fileCount: fileCount, doneDate: doneDate)
    }
}
