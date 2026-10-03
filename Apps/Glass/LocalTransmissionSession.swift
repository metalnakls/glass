import Foundation
import GlassRemoteCore
import GlassRemoteServices

actor LocalTransmissionSession: LocalTransmissionServicing {
    private struct CachedFreeSpace {
        let fetchedAt: Date
        let value: ServerFreeSpace
    }

    private static let freeSpaceRefreshInterval: TimeInterval = 60

    private let configDirectory: URL
    private let downloadDirectory: URL
    private var bridge: LocalTransmissionBridge?
    private var cachedFreeSpace: CachedFreeSpace?

    init(appName: String = "Glass") throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(appName, isDirectory: true)

        let configDirectory = support.appendingPathComponent("LocalTransmission", isDirectory: true)
        let downloadDirectory = try FileManager.default.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        self.configDirectory = configDirectory
        self.downloadDirectory = downloadDirectory
    }

    func fetchSnapshot() async throws -> TorrentProviderSnapshot {
        guard let bridge = try bridgeForRefreshIfNeeded() else {
            return emptySnapshot()
        }
        let dictionary = try Self.stringDictionary(bridge.snapshot())
        let statsDictionary = dictionary["stats"] as? [String: Any] ?? [:]
        let torrentsArray = dictionary["torrents"] as? [[String: Any]] ?? []

        return TorrentProviderSnapshot(
            stats: Self.makeSessionStats(from: statsDictionary),
            torrents: torrentsArray.map(Self.makeSummary(from:)),
            freeSpace: localFreeSpace()
        )
    }

    func fetchDefaultDownloadDirectory() async throws -> String? {
        downloadDirectory.path
    }

    func fetchSessionSettings() async throws -> TransmissionSessionSettings {
        let directory = try await fetchDefaultDownloadDirectory() ?? ""
        let data = try JSONSerialization.data(withJSONObject: [
            "version": "local-libtransmission",
            "download-dir": directory
        ])
        return try JSONDecoder().decode(TransmissionSessionSettings.self, from: data)
    }

    func setSessionSettings(_ patch: TransmissionSessionSettingsPatch) async throws {
        if let directory = patch.downloadDirectory {
            _ = directory
        }
    }

    func fetchTorrentDetails(hashString: String) async throws -> TorrentDetails {
        let dictionary = try Self.stringDictionary(ensureBridge().torrentDetails(forHash: hashString))
        return Self.makeDetails(from: dictionary)
    }

    func addMagnet(_ magnet: String, downloadDirectory: String?) async throws -> TorrentAddResult? {
        let existingTorrentHashes = Set(try await fetchSnapshot().torrents.map(\.hashString))
        try ensureBridge().addMagnet(magnet, downloadDirectory: downloadDirectory)
        let snapshot = try await fetchSnapshot()
        guard let addedTorrent = snapshot.torrents.first(where: { !existingTorrentHashes.contains($0.hashString) }) else {
            return nil
        }
        return TorrentAddResult(
            hashString: addedTorrent.hashString,
            name: addedTorrent.name,
            wasDuplicate: false
        )
    }

    func addTorrentFile(
        data: Data,
        torrentName: String?,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection?
    ) async throws -> TorrentAddResult? {
        let existingTorrentHashes = Set(try await fetchSnapshot().torrents.map(\.hashString))
        try ensureBridge().addTorrentData(data, downloadDirectory: downloadDirectory)
        let snapshot = try await fetchSnapshot()
        guard let addedTorrent = snapshot.torrents.first(where: { !existingTorrentHashes.contains($0.hashString) }) else {
            return nil
        }
        if let fileSelection, !fileSelection.isEmpty {
            try await apply(fileSelection, to: addedTorrent.hashString)
        }
        if let torrentName = torrentName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !torrentName.isEmpty,
           torrentName != addedTorrent.name {
            try await renamePath(id: addedTorrent.hashString, path: addedTorrent.name, name: torrentName)
            return TorrentAddResult(hashString: addedTorrent.hashString, name: torrentName, wasDuplicate: false)
        }
        return TorrentAddResult(hashString: addedTorrent.hashString, name: addedTorrent.name, wasDuplicate: false)
    }

    func start(ids: [String]) async throws {
        try ensureBridge().startTorrents(ids)
    }

    func stop(ids: [String]) async throws {
        try ensureBridge().stopTorrents(ids)
    }

    func remove(ids: [String], deleteLocalData: Bool) async throws {
        try ensureBridge().removeTorrents(ids, deleteLocalData: deleteLocalData)
    }

    func verify(ids: [String]) async throws {
        try ensureBridge().verifyTorrents(ids)
    }

    func reannounce(ids: [String]) async throws {
        try ensureBridge().reannounceTorrents(ids)
    }

    func queueMoveTop(ids: [String]) async throws {
        try ensureBridge().moveTorrents(ids, toQueuePosition: 0)
    }

    func queueMoveUp(ids: [String]) async throws {
        let snapshot = try await fetchSnapshot()
        let positions = Dictionary(uniqueKeysWithValues: snapshot.torrents.map { ($0.hashString, $0.queuePosition ?? 0) })
        let target = max(0, (ids.compactMap { positions[$0] }.min() ?? 0) - 1)
        try ensureBridge().moveTorrents(ids, toQueuePosition: target)
    }

    func queueMoveDown(ids: [String]) async throws {
        let snapshot = try await fetchSnapshot()
        let positions = Dictionary(uniqueKeysWithValues: snapshot.torrents.map { ($0.hashString, $0.queuePosition ?? 0) })
        let target = (ids.compactMap { positions[$0] }.max() ?? 0) + 1
        try ensureBridge().moveTorrents(ids, toQueuePosition: target)
    }

    func queueMoveBottom(ids: [String]) async throws {
        let snapshot = try await fetchSnapshot()
        try ensureBridge().moveTorrents(ids, toQueuePosition: snapshot.torrents.count)
    }

    func moveData(id: String, to downloadDirectory: String) async throws {
        try ensureBridge().moveData(
            forTorrent: id,
            toDownloadDirectory: downloadDirectory
        )
    }

    func renamePath(id: String, path: String, name: String) async throws {
        try ensureBridge().renameTorrent(id, path: path, name: name)
    }

    func setFileWanted(ids: [String], fileIndices: [Int], wanted: Bool) async throws {
        for id in ids {
            try ensureBridge().setWanted(wanted, forTorrent: id, fileIndices: fileIndices.map(NSNumber.init))
        }
    }

    func setFilePriority(ids: [String], fileIndices: [Int], priority: Int) async throws {
        for id in ids {
            try ensureBridge().setPriority(priority, forTorrent: id, fileIndices: fileIndices.map(NSNumber.init))
        }
    }

    func setTorrentPriority(ids: [String], priority: Int) async throws {
        try ensureBridge().setPriority(priority, forTorrents: ids)
    }

    private func apply(_ selection: TorrentAddFileSelection, to id: String) async throws {
        if !selection.filesWanted.isEmpty {
            try await setFileWanted(ids: [id], fileIndices: selection.filesWanted, wanted: true)
        }
        if !selection.filesUnwanted.isEmpty {
            try await setFileWanted(ids: [id], fileIndices: selection.filesUnwanted, wanted: false)
        }
        if !selection.priorityHigh.isEmpty {
            try await setFilePriority(ids: [id], fileIndices: selection.priorityHigh, priority: 1)
        }
        if !selection.priorityNormal.isEmpty {
            try await setFilePriority(ids: [id], fileIndices: selection.priorityNormal, priority: 0)
        }
        if !selection.priorityLow.isEmpty {
            try await setFilePriority(ids: [id], fileIndices: selection.priorityLow, priority: -1)
        }
    }

    private static func makeBridge(configDirectory: URL, downloadDirectory: URL) throws -> LocalTransmissionBridge {
        try LocalTransmissionBridge(
            configDirectory: configDirectory,
            downloadDirectory: downloadDirectory
        )
    }

    private func ensureBridge() throws -> LocalTransmissionBridge {
        if let bridge {
            return bridge
        }
        let bridge = try Self.makeBridge(configDirectory: configDirectory, downloadDirectory: downloadDirectory)
        self.bridge = bridge
        return bridge
    }

    private func bridgeForRefreshIfNeeded() throws -> LocalTransmissionBridge? {
        if let bridge {
            return bridge
        }
        guard hasPersistedTorrents else {
            return nil
        }
        return try ensureBridge()
    }

    private var hasPersistedTorrents: Bool {
        let torrentDirectory = configDirectory.appendingPathComponent("torrents", isDirectory: true)
        let resumeDirectory = configDirectory.appendingPathComponent("resume", isDirectory: true)
        return Self.directoryContainsFiles(torrentDirectory, extensions: ["torrent"]) ||
            Self.directoryContainsFiles(resumeDirectory, extensions: ["resume"])
    }

    private func emptySnapshot() -> TorrentProviderSnapshot {
        TorrentProviderSnapshot(
            stats: SessionStats(downloadSpeed: 0, uploadSpeed: 0),
            torrents: [],
            freeSpace: localFreeSpace()
        )
    }

    private func localFreeSpace(now: Date = Date()) -> ServerFreeSpace {
        if let cachedFreeSpace,
           now.timeIntervalSince(cachedFreeSpace.fetchedAt) < Self.freeSpaceRefreshInterval {
            return cachedFreeSpace.value
        }
        let value = ServerFreeSpace(
            path: downloadDirectory.path,
            sizeBytes: availableBytes(at: downloadDirectory) ?? -1
        )
        cachedFreeSpace = CachedFreeSpace(fetchedAt: now, value: value)
        return value
    }

    private func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    private static func directoryContainsFiles(_ url: URL, extensions allowedExtensions: Set<String>) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return false
        }
        for case let fileURL as URL in enumerator {
            guard allowedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                return true
            }
        }
        return false
    }

    private static func stringDictionary(_ dictionary: [AnyHashable: Any]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: dictionary.compactMap { key, value in
            guard let key = key as? String else { return nil }
            return (key, value)
        })
    }

    private static func makeSummary(from dictionary: [String: Any]) -> TorrentSummary {
        TorrentSummary(
            id: dictionary.int("id"),
            hashString: dictionary.string("hashString") ?? "",
            name: dictionary.string("name") ?? "Torrent",
            status: dictionary.int("status"),
            percentDone: dictionary.double("percentDone"),
            metadataPercentComplete: dictionary.optionalDouble("metadataPercentComplete"),
            rateDownload: dictionary.double("rateDownload"),
            rateUpload: dictionary.double("rateUpload"),
            sizeWhenDone: dictionary.uint64("sizeWhenDone"),
            leftUntilDone: dictionary.uint64("leftUntilDone"),
            eta: dictionary.int("eta"),
            uploadRatio: dictionary.double("uploadRatio"),
            peersConnected: dictionary.optionalInt("peersConnected"),
            downloadDir: dictionary.string("downloadDir"),
            bandwidthPriority: dictionary.optionalInt("bandwidthPriority"),
            queuePosition: dictionary.optionalInt("queuePosition"),
            fileCount: dictionary.optionalInt("fileCount"),
            error: dictionary.optionalInt("error"),
            errorString: dictionary.string("errorString"),
            doneDate: dictionary.optionalInt("doneDate")
        )
    }

    private static func makeSessionStats(from dictionary: [String: Any]) -> SessionStats {
        SessionStats(
            downloadSpeed: dictionary.double("downloadSpeed"),
            uploadSpeed: dictionary.double("uploadSpeed")
        )
    }

    private static func makeDetails(from dictionary: [String: Any]) -> TorrentDetails {
        let files = (dictionary["files"] as? [[String: Any]] ?? []).map { item in
            TorrentFile(
                name: item.string("name") ?? "",
                length: item.uint64("length"),
                bytesCompleted: item.uint64("bytesCompleted")
            )
        }
        let fileStats = (dictionary["fileStats"] as? [[String: Any]] ?? []).map { item in
            TorrentFileStats(
                bytesCompleted: item.optionalUInt64("bytesCompleted"),
                wanted: item.bool("wanted"),
                priority: item.optionalInt("priority")
            )
        }
        let peers = (dictionary["peers"] as? [[String: Any]] ?? []).map { item in
            TorrentPeer(
                address: item.string("address"),
                port: item.optionalInt("port"),
                clientName: item.string("clientName"),
                flagStr: item.string("flagStr"),
                progress: item.optionalDouble("progress"),
                rateToClient: item.optionalDouble("rateToClient"),
                rateToPeer: item.optionalDouble("rateToPeer"),
                isEncrypted: item.bool("isEncrypted"),
                isIncoming: item.bool("isIncoming"),
                isUTP: item.bool("isUTP")
            )
        }
        let trackers = (dictionary["trackerStats"] as? [[String: Any]] ?? []).map { item in
            TorrentTracker(
                id: item.optionalInt("id"),
                announce: item.string("announce"),
                scrape: item.string("scrape"),
                host: item.string("host"),
                tier: item.optionalInt("tier"),
                lastAnnounceResult: item.string("lastAnnounceResult"),
                lastAnnounceSucceeded: item.bool("lastAnnounceSucceeded"),
                lastScrapeResult: item.string("lastScrapeResult"),
                lastScrapeSucceeded: item.bool("lastScrapeSucceeded"),
                seederCount: item.optionalInt("seederCount"),
                leecherCount: item.optionalInt("leecherCount"),
                downloadCount: item.optionalInt("downloadCount"),
                nextAnnounceTime: item.optionalInt("nextAnnounceTime")
            )
        }

        return TorrentDetails(
            id: dictionary.int("id"),
            hashString: dictionary.string("hashString") ?? "",
            name: dictionary.string("name") ?? "Torrent",
            status: dictionary.optionalInt("status"),
            percentDone: dictionary.optionalDouble("percentDone"),
            totalSize: dictionary.optionalUInt64("totalSize"),
            sizeWhenDone: dictionary.optionalUInt64("sizeWhenDone"),
            leftUntilDone: dictionary.optionalUInt64("leftUntilDone"),
            eta: dictionary.optionalInt("eta"),
            uploadRatio: dictionary.optionalDouble("uploadRatio"),
            uploadedEver: dictionary.optionalUInt64("uploadedEver"),
            downloadedEver: dictionary.optionalUInt64("downloadedEver"),
            corruptEver: dictionary.optionalUInt64("corruptEver"),
            downloadDir: dictionary.string("downloadDir"),
            addedDate: dictionary.optionalInt("addedDate"),
            activityDate: dictionary.optionalInt("activityDate"),
            startDate: dictionary.optionalInt("startDate"),
            doneDate: dictionary.optionalInt("doneDate"),
            secondsDownloading: dictionary.optionalInt("secondsDownloading"),
            secondsSeeding: dictionary.optionalInt("secondsSeeding"),
            files: files,
            fileStats: fileStats,
            peers: peers,
            trackerStats: trackers,
            pieceCount: dictionary.optionalInt("pieceCount"),
            pieceSize: dictionary.optionalUInt64("pieceSize"),
            bandwidthPriority: dictionary.optionalInt("bandwidthPriority"),
            queuePosition: dictionary.optionalInt("queuePosition"),
            isPrivate: dictionary.bool("isPrivate")
        )
    }
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        self[key] as? String
    }

    func int(_ key: String) -> Int {
        optionalInt(key) ?? 0
    }

    func optionalInt(_ key: String) -> Int? {
        if let number = self[key] as? NSNumber {
            return number.intValue
        }
        return self[key] as? Int
    }

    func int64(_ key: String) -> Int64 {
        if let number = self[key] as? NSNumber {
            return number.int64Value
        }
        return self[key] as? Int64 ?? 0
    }

    func uint64(_ key: String) -> UInt64 {
        optionalUInt64(key) ?? 0
    }

    func optionalUInt64(_ key: String) -> UInt64? {
        if let number = self[key] as? NSNumber {
            return number.uint64Value
        }
        return self[key] as? UInt64
    }

    func double(_ key: String) -> Double {
        optionalDouble(key) ?? 0
    }

    func optionalDouble(_ key: String) -> Double? {
        if let number = self[key] as? NSNumber {
            return number.doubleValue
        }
        return self[key] as? Double
    }

    func bool(_ key: String) -> Bool? {
        if let number = self[key] as? NSNumber {
            return number.boolValue
        }
        return self[key] as? Bool
    }
}
