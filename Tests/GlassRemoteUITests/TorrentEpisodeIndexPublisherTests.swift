import Foundation
@testable import GlassRemoteUI
import GlassRemoteCore
import GlassRemoteServices
import Testing

@Suite("Automatic YINA publisher")
struct TorrentEpisodeIndexPublisherTests {
    @Test("selects an existing show folder that contains every torrent video")
    func mappedShowRoot() throws {
        let mappedRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: mappedRoot) }
        let showRoot = mappedRoot.appendingPathComponent("Example Show", isDirectory: true)
        let seasonRoot = showRoot.appendingPathComponent("Season 2", isDirectory: true)
        try FileManager.default.createDirectory(at: seasonRoot, withIntermediateDirectories: true)
        let files = [
            TorrentFile(name: "S02E01.mkv", length: 100, bytesCompleted: 10),
            TorrentFile(name: "S02E02.mkv", length: 100, bytesCompleted: 0)
        ]

        let selected = TorrentEpisodeIndexPublisher.selectShowRoot(
            expectedTitle: "example_show",
            remoteRoot: mappedRoot.path,
            downloadDirectory: seasonRoot.path,
            files: files,
            localRoot: mappedRoot
        )

        #expect(selected?.remotePath == showRoot.path)
        #expect(selected?.localURL == showRoot)
    }

    @Test("rebases absolute torrent paths when the show folder is below the download directory")
    func rebasesChildShowRoot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let show = root.appendingPathComponent("Example Show", isDirectory: true)
        try FileManager.default.createDirectory(at: show, withIntermediateDirectories: true)
        let files = [TorrentFile(name: "Example Show/S01E01.mkv", length: 100, bytesCompleted: 20)]
        let selected = TorrentEpisodeIndexPublisher.selectShowRoot(
            expectedTitle: "Example Show", remoteRoot: root.path,
            downloadDirectory: root.path, files: files, localRoot: root
        )
        #expect(selected?.remotePath == show.path)
        let details = TorrentDetails(
            id: 1, hashString: "ab12cd34", name: "Example Show", downloadDir: root.path,
            files: files, fileStats: [TorrentFileStats(bytesCompleted: 20, wanted: true, priority: 0)]
        )
        let rebased = try #require(TorrentEpisodeIndexPublisher.details(details, relativeTo: show.path))
        #expect(rebased.files.first?.name == "S01E01.mkv")
        #expect(try ShowEpisodeIndex(details: rebased, relativePathPrefix: "").episodes.first?.relativePath == "S01E01.mkv")
    }

    @Test("rejects an existing media symlink that escapes the selected show root")
    func refusesSymlinkEscape() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let show = root.appendingPathComponent("Example Show", isDirectory: true)
        let season = show.appendingPathComponent("Season 1", isDirectory: true)
        try FileManager.default.createDirectory(at: season, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.mkv")
        try Data("media".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: season.appendingPathComponent("S01E01.mkv"), withDestinationURL: outside)
        #expect(TorrentEpisodeIndexPublisher.selectShowRoot(
            expectedTitle: "Example Show", remoteRoot: root.path,
            downloadDirectory: season.path,
            files: [TorrentFile(name: "S01E01.mkv", length: 100, bytesCompleted: 0)],
            localRoot: root
        ) == nil)
    }

    @Test("does not invent a show folder or accept a video outside the chosen root")
    func refusesGuessedOrAmbiguousRoot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let download = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
        let files = [TorrentFile(name: "Example Show/S01E01.mkv", length: 100, bytesCompleted: 0)]

        #expect(TorrentEpisodeIndexPublisher.selectShowRoot(
            expectedTitle: "Example Show", remoteRoot: root.path,
            downloadDirectory: download.path, files: files, localRoot: root
        ) == nil)

        let show = download.appendingPathComponent("Example Show", isDirectory: true)
        try FileManager.default.createDirectory(at: show, withIntermediateDirectories: true)
        let escaping = [
            TorrentFile(name: "Example Show/S01E01.mkv", length: 100, bytesCompleted: 0),
            TorrentFile(name: "../outside/S01E02.mkv", length: 100, bytesCompleted: 0)
        ]
        #expect(TorrentEpisodeIndexPublisher.selectShowRoot(
            expectedTitle: "Example Show", remoteRoot: root.path,
            downloadDirectory: download.path, files: escaping, localRoot: root
        ) == nil)
    }

    @Test("keeps unwanted videos in the published inventory")
    func preservesUnwantedEpisodes() throws {
        let details = TorrentDetails(
            id: 1, hashString: "ab12cd34", name: "Example Show",
            downloadDir: "/share/Example Show",
            files: [
                TorrentFile(name: "Season 1/S01E01.mkv", length: 100, bytesCompleted: 10),
                TorrentFile(name: "Season 1/S01E02.mkv", length: 200, bytesCompleted: 0)
            ],
            fileStats: [
                TorrentFileStats(bytesCompleted: 10, wanted: true, priority: 0),
                TorrentFileStats(bytesCompleted: 0, wanted: false, priority: 0)
            ]
        )

        let index = try ShowEpisodeIndex(details: details, relativePathPrefix: "")
        #expect(index.episodes.count == 2)
        #expect(index.episodes[1].wanted == false)
        #expect(index.episodes[1].availability == .notSelected)
    }

    @Test("rotates bounded work and honors active, inactive, and completed cadences")
    func boundedScheduler() {
        let now = Date(timeIntervalSince1970: 1_000)
        let entries = (0..<5).map {
            TorrentEpisodeIndexPublisher.ScheduleEntry(
                hash: String(format: "%02d", $0),
                isActive: $0 < 4,
                lastPublishedAt: now.addingTimeInterval($0 == 0 ? -16 : ($0 == 4 ? -301 : -2))
            )
        }

        let first = TorrentEpisodeIndexPublisher.scheduledBatch(
            entries: entries, now: now, activeCadence: 15,
            inactiveCadence: 30, completedCadence: 300, cursor: 0, limit: 2
        )
        #expect(first.hashes == ["00", "04"])
        #expect(first.nextCursor == 0)

        let inactive = TorrentEpisodeIndexPublisher.scheduledBatch(
            entries: entries, now: now, activeCadence: 0,
            inactiveCadence: 30, completedCadence: 300, cursor: 0, limit: 5
        )
        #expect(inactive.hashes == ["04"])
    }

    @Test("resolves a demand only to one unambiguous known asset")
    func demandAssetMatching() throws {
        let showID = UUID()
        let index = try makeIndex(hash: "ab12cd34", path: "Season 1/S01E01.mkv", wanted: false)
        let fragment = YinaTransferFragment(showID: showID, writerID: UUID(), index: index)
        let demand = try YinaDownloadDemand(
            showID: showID, requestID: UUID(), participantID: UUID(), writerID: UUID(),
            revision: 1, relativePath: "Season 1/S01E01.mkv", hashString: "ab12cd34", fileIndex: 0
        )
        #expect(TorrentEpisodeIndexPublisher.targetIdentity(for: demand, inventories: [fragment])?.hashString == "ab12cd34")

        let mismatch = try YinaDownloadDemand(
            showID: showID, requestID: UUID(), participantID: UUID(), writerID: UUID(),
            revision: 1, relativePath: "Season 1/S01E99.mkv", hashString: "ab12cd34", fileIndex: 0
        )
        #expect(TorrentEpisodeIndexPublisher.targetIdentity(for: mismatch, inventories: [fragment]) == nil)

        let duplicatePath = try makeIndex(hash: "ef56ab78", path: "Season 1/S01E01.mkv", wanted: true)
        let duplicateFragment = YinaTransferFragment(showID: showID, writerID: UUID(), index: duplicatePath)
        let pathOnly = try YinaDownloadDemand(
            showID: showID, requestID: UUID(), participantID: UUID(), writerID: UUID(),
            revision: 1, relativePath: "Season 1/S01E01.mkv"
        )
        #expect(TorrentEpisodeIndexPublisher.targetIdentity(
            for: pathOnly, inventories: [fragment, duplicateFragment]
        ) == nil)

        let foreign = YinaTransferFragment(showID: UUID(), writerID: UUID(), index: index)
        #expect(TorrentEpisodeIndexPublisher.targetIdentity(for: demand, inventories: [foreign]) == nil)
    }

    @MainActor
    @Test("dispatches one exact demand and does nothing for an ambiguous target")
    func demandActionDispatch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = DemandActionSession()
        let model = RemoteAppModel(
            profileStore: FileProfileStore(fileURL: directory.appendingPathComponent("profiles.json")),
            credentialStore: KeychainCredentialStore(service: "GlassTests.YinaDemand"),
            localSessionFactory: { session }
        )
        let sourceID = model.localSourceID
        let torrent = TorrentSummary(
            id: 7, hashString: "ab12cd34", name: "Example Show S01E01", status: 0,
            percentDone: 0, rateDownload: 0, rateUpload: 0, sizeWhenDone: 100,
            leftUntilDone: 100, eta: -1, uploadRatio: 0, peersConnected: 0,
            downloadDir: "/share", fileCount: 1
        )
        let showID = UUID()
        let index = try makeIndex(hash: torrent.hashString, path: "S01E01.mkv", wanted: false)
        let fragment = YinaTransferFragment(showID: showID, writerID: UUID(), index: index)
        let demand = try YinaDownloadDemand(
            showID: showID, requestID: UUID(), participantID: UUID(), writerID: UUID(), revision: 1,
            relativePath: "S01E01.mkv", hashString: torrent.hashString, fileIndex: 0
        )
        let identity = try #require(TorrentEpisodeIndexPublisher.targetIdentity(for: demand, inventories: [fragment]))
        #expect(await TorrentEpisodeIndexPublisher.dispatchDemandActions(
            model: model, torrent: torrent, identity: identity, sourceID: sourceID
        ))
        #expect(await session.actions == [
            "wanted:\(torrent.hashString):0:true",
            "priority:\(torrent.hashString):0:1",
            "start:\(torrent.hashString)"
        ])

        let ambiguousIndex = try makeIndex(hash: "ef56ab78", path: "S01E01.mkv", wanted: true)
        let ambiguousFragment = YinaTransferFragment(showID: showID, writerID: UUID(), index: ambiguousIndex)
        let ambiguousDemand = try YinaDownloadDemand(
            showID: showID, requestID: UUID(), participantID: UUID(), writerID: UUID(), revision: 1,
            relativePath: "S01E01.mkv"
        )
        let ambiguousIdentity = TorrentEpisodeIndexPublisher.targetIdentity(
            for: ambiguousDemand, inventories: [fragment, ambiguousFragment]
        )
        #expect(ambiguousIdentity == nil)
        if let ambiguousIdentity {
            _ = await TorrentEpisodeIndexPublisher.dispatchDemandActions(
                model: model, torrent: torrent, identity: ambiguousIdentity, sourceID: sourceID
            )
        }
        #expect(await session.actions.count == 3)
    }

    private func makeIndex(hash: String, path: String, wanted: Bool) throws -> ShowEpisodeIndex {
        let details = TorrentDetails(
            id: 1, hashString: hash, name: "Example Show",
            files: [TorrentFile(name: path, length: 100, bytesCompleted: 0)],
            fileStats: [TorrentFileStats(bytesCompleted: 0, wanted: wanted, priority: 0)]
        )
        return try ShowEpisodeIndex(details: details, relativePathPrefix: "")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor DemandActionSession: LocalTransmissionServicing {
    private(set) var actions: [String] = []

    func fetchSnapshot() async throws -> TorrentProviderSnapshot { throw Failure.unused }
    func fetchDefaultDownloadDirectory() async throws -> String? { throw Failure.unused }
    func fetchSessionSettings() async throws -> TransmissionSessionSettings { throw Failure.unused }
    func setSessionSettings(_ patch: TransmissionSessionSettingsPatch) async throws { throw Failure.unused }
    func fetchTorrentDetails(hashString: String) async throws -> TorrentDetails { throw Failure.unused }
    func addMagnet(_ magnet: String, downloadDirectory: String?) async throws -> TorrentAddResult? { throw Failure.unused }
    func addTorrentFile(data: Data, torrentName: String?, downloadDirectory: String?, fileSelection: TorrentAddFileSelection?) async throws -> TorrentAddResult? { throw Failure.unused }
    func start(ids: [String]) async throws { actions.append("start:\(ids.joined(separator: ","))") }
    func stop(ids: [String]) async throws { throw Failure.unused }
    func remove(ids: [String], deleteLocalData: Bool) async throws { throw Failure.unused }
    func verify(ids: [String]) async throws { throw Failure.unused }
    func reannounce(ids: [String]) async throws { throw Failure.unused }
    func queueMoveTop(ids: [String]) async throws { throw Failure.unused }
    func queueMoveUp(ids: [String]) async throws { throw Failure.unused }
    func queueMoveDown(ids: [String]) async throws { throw Failure.unused }
    func queueMoveBottom(ids: [String]) async throws { throw Failure.unused }
    func renamePath(id: String, path: String, name: String) async throws { throw Failure.unused }
    func setFileWanted(ids: [String], fileIndices: [Int], wanted: Bool) async throws {
        actions.append("wanted:\(ids.joined(separator: ",")):\(fileIndices.map(String.init).joined(separator: ",")):\(wanted)")
    }
    func setFilePriority(ids: [String], fileIndices: [Int], priority: Int) async throws {
        actions.append("priority:\(ids.joined(separator: ",")):\(fileIndices.map(String.init).joined(separator: ",")):\(priority)")
    }
    func setTorrentPriority(ids: [String], priority: Int) async throws { throw Failure.unused }

    private enum Failure: Error { case unused }
}
