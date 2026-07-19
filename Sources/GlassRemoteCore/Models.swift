import Foundation

public struct RemoteProfile: Hashable, Sendable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var rpcURL: URL
    public var username: String

    public init(id: UUID = UUID(), name: String, rpcURL: URL, username: String) {
        self.id = id
        self.name = name
        self.rpcURL = Self.normalizeRPCURL(rpcURL)
        self.username = username
    }

    public static func normalizeRPCURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        if components.scheme == nil || components.scheme?.isEmpty == true {
            components.scheme = "http"
        }

        if components.path.isEmpty || components.path == "/" {
            components.path = "/transmission/rpc"
        }

        return components.url ?? url
    }
}

public enum TorrentListSource: Hashable, Sendable, Codable, Identifiable {
    case localMac
    case remote(UUID)

    public var id: String {
        switch self {
        case .localMac:
            return "local-mac"
        case let .remote(id):
            return "remote-\(id.uuidString)"
        }
    }
}

public enum TorrentGroup: String, CaseIterable, Sendable, Codable, Identifiable {
    case all
    case downloading
    case completed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all:
            return "All"
        case .downloading:
            return "Downloading"
        case .completed:
            return "Completed"
        }
    }

    public var systemImage: String {
        switch self {
        case .all:
            return "tray.full"
        case .downloading:
            return "arrow.down.circle"
        case .completed:
            return "checkmark.circle"
        }
    }
}

public enum TransmissionTorrentStatus: Int, Sendable, Hashable, Codable, CaseIterable {
    case stopped = 0
    case checkQueued = 1
    case checking = 2
    case downloadQueued = 3
    case downloading = 4
    case seedQueued = 5
    case seeding = 6

    public var isDownloading: Bool {
        self == .downloading
    }

    public var isRunningOrQueued: Bool {
        self != .stopped
    }

    public var canStopTransfer: Bool {
        isRunningOrQueued
    }
}

public struct TorrentSummary: Sendable, Hashable, Codable, Identifiable {
    public let id: Int
    public let hashString: String
    public let name: String
    public let status: Int
    public let percentDone: Double
    public let metadataPercentComplete: Double?
    public let rateDownload: Double
    public let rateUpload: Double
    public let sizeWhenDone: UInt64
    public let leftUntilDone: UInt64
    public let eta: Int
    public let uploadRatio: Double
    public let peersConnected: Int?
    public let downloadDir: String?
    public let bandwidthPriority: Int?
    public let queuePosition: Int?
    public let fileCount: Int?

    public init(
        id: Int,
        hashString: String,
        name: String,
        status: Int,
        percentDone: Double,
        metadataPercentComplete: Double? = nil,
        rateDownload: Double,
        rateUpload: Double,
        sizeWhenDone: UInt64,
        leftUntilDone: UInt64,
        eta: Int,
        uploadRatio: Double,
        peersConnected: Int?,
        downloadDir: String?,
        bandwidthPriority: Int? = nil,
        queuePosition: Int? = nil,
        fileCount: Int? = nil
    ) {
        self.id = id
        self.hashString = hashString
        self.name = name
        self.status = status
        self.percentDone = percentDone
        self.metadataPercentComplete = metadataPercentComplete
        self.rateDownload = rateDownload
        self.rateUpload = rateUpload
        self.sizeWhenDone = sizeWhenDone
        self.leftUntilDone = leftUntilDone
        self.eta = eta
        self.uploadRatio = uploadRatio
        self.peersConnected = peersConnected
        self.downloadDir = downloadDir
        self.bandwidthPriority = bandwidthPriority
        self.queuePosition = queuePosition
        self.fileCount = fileCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, hashString, name, status, percentDone, metadataPercentComplete
        case rateDownload, rateUpload, sizeWhenDone, leftUntilDone, eta, uploadRatio
        case peersConnected, downloadDir, bandwidthPriority, queuePosition
        case fileCount = "file-count"
    }

    public var transmissionStatus: TransmissionTorrentStatus? {
        TransmissionTorrentStatus(rawValue: status)
    }

    public var isCompleted: Bool {
        percentDone >= 1.0 || leftUntilDone == 0 && sizeWhenDone > 0
    }

    public var isDownloading: Bool {
        transmissionStatus?.isDownloading == true
    }

    public var isDownloadingMetadata: Bool {
        isDownloading && metadataPercentComplete.map { $0 < 1 } == true
    }

    public var isRunningOrQueued: Bool {
        transmissionStatus?.isRunningOrQueued ?? (status != TransmissionTorrentStatus.stopped.rawValue)
    }

    public var canStopTransfer: Bool {
        transmissionStatus?.canStopTransfer ?? isRunningOrQueued
    }

    public var isActive: Bool {
        isRunningOrQueued
    }
}

public enum TorrentListMerger {
    public static func merge(existing: [TorrentSummary], incoming: [TorrentSummary]) -> [TorrentSummary] {
        let existingByHash = Dictionary(
            existing.lazy.filter { !$0.hashString.isEmpty }.map { ($0.hashString, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let existingByID = Dictionary(
            existing.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return incoming.map { incomingTorrent in
            let existingTorrent = if incomingTorrent.hashString.isEmpty {
                existingByID[incomingTorrent.id]
            } else {
                existingByHash[incomingTorrent.hashString] ?? existingByID[incomingTorrent.id]
            }
            if let existingTorrent, existingTorrent == incomingTorrent {
                return existingTorrent
            }
            return incomingTorrent
        }
    }
}

public struct TorrentDetails: Sendable, Hashable, Codable, Identifiable {
    public let id: Int
    public let hashString: String
    public let name: String
    public let status: Int?
    public let percentDone: Double?
    public let totalSize: UInt64?
    public let sizeWhenDone: UInt64?
    public let leftUntilDone: UInt64?
    public let eta: Int?
    public let uploadRatio: Double?
    public let uploadedEver: UInt64?
    public let downloadedEver: UInt64?
    public let corruptEver: UInt64?
    public let downloadDir: String?
    public let addedDate: Int?
    public let activityDate: Int?
    public let startDate: Int?
    public let doneDate: Int?
    public let secondsDownloading: Int?
    public let secondsSeeding: Int?
    public let files: [TorrentFile]
    public let fileStats: [TorrentFileStats]
    public let peers: [TorrentPeer]
    public let trackerStats: [TorrentTracker]
    public let pieceCount: Int?
    public let pieceSize: UInt64?
    public let pieces: String?
    public let downloadLimit: Int?
    public let downloadLimited: Bool?
    public let uploadLimit: Int?
    public let uploadLimited: Bool?
    public let seedRatioLimit: Double?
    public let seedRatioMode: Int?
    public let bandwidthPriority: Int?
    public let queuePosition: Int?
    public let honorsSessionLimits: Bool?
    public let isPrivate: Bool?

    public init(
        id: Int,
        hashString: String,
        name: String,
        status: Int? = nil,
        percentDone: Double? = nil,
        totalSize: UInt64? = nil,
        sizeWhenDone: UInt64? = nil,
        leftUntilDone: UInt64? = nil,
        eta: Int? = nil,
        uploadRatio: Double? = nil,
        uploadedEver: UInt64? = nil,
        downloadedEver: UInt64? = nil,
        corruptEver: UInt64? = nil,
        downloadDir: String? = nil,
        addedDate: Int? = nil,
        activityDate: Int? = nil,
        startDate: Int? = nil,
        doneDate: Int? = nil,
        secondsDownloading: Int? = nil,
        secondsSeeding: Int? = nil,
        files: [TorrentFile] = [],
        fileStats: [TorrentFileStats] = [],
        peers: [TorrentPeer] = [],
        trackerStats: [TorrentTracker] = [],
        pieceCount: Int? = nil,
        pieceSize: UInt64? = nil,
        pieces: String? = nil,
        downloadLimit: Int? = nil,
        downloadLimited: Bool? = nil,
        uploadLimit: Int? = nil,
        uploadLimited: Bool? = nil,
        seedRatioLimit: Double? = nil,
        seedRatioMode: Int? = nil,
        bandwidthPriority: Int? = nil,
        queuePosition: Int? = nil,
        honorsSessionLimits: Bool? = nil,
        isPrivate: Bool? = nil
    ) {
        self.id = id
        self.hashString = hashString
        self.name = name
        self.status = status
        self.percentDone = percentDone
        self.totalSize = totalSize
        self.sizeWhenDone = sizeWhenDone
        self.leftUntilDone = leftUntilDone
        self.eta = eta
        self.uploadRatio = uploadRatio
        self.uploadedEver = uploadedEver
        self.downloadedEver = downloadedEver
        self.corruptEver = corruptEver
        self.downloadDir = downloadDir
        self.addedDate = addedDate
        self.activityDate = activityDate
        self.startDate = startDate
        self.doneDate = doneDate
        self.secondsDownloading = secondsDownloading
        self.secondsSeeding = secondsSeeding
        self.files = files
        self.fileStats = fileStats
        self.peers = peers
        self.trackerStats = trackerStats
        self.pieceCount = pieceCount
        self.pieceSize = pieceSize
        self.pieces = pieces
        self.downloadLimit = downloadLimit
        self.downloadLimited = downloadLimited
        self.uploadLimit = uploadLimit
        self.uploadLimited = uploadLimited
        self.seedRatioLimit = seedRatioLimit
        self.seedRatioMode = seedRatioMode
        self.bandwidthPriority = bandwidthPriority
        self.queuePosition = queuePosition
        self.honorsSessionLimits = honorsSessionLimits
        self.isPrivate = isPrivate
    }
}

public struct TorrentFile: Sendable, Hashable, Codable {
    public let name: String
    public let length: UInt64
    public let bytesCompleted: UInt64

    public init(name: String, length: UInt64, bytesCompleted: UInt64) {
        self.name = name
        self.length = length
        self.bytesCompleted = bytesCompleted
    }
}

public struct TorrentFileStats: Sendable, Hashable, Codable {
    public let bytesCompleted: UInt64?
    public let wanted: Bool?
    public let priority: Int?

    public init(bytesCompleted: UInt64?, wanted: Bool?, priority: Int?) {
        self.bytesCompleted = bytesCompleted
        self.wanted = wanted
        self.priority = priority
    }
}

public struct TorrentAddFileSelection: Sendable, Hashable {
    public var filesWanted: [Int]
    public var filesUnwanted: [Int]
    public var priorityHigh: [Int]
    public var priorityNormal: [Int]
    public var priorityLow: [Int]

    public init(
        filesWanted: [Int] = [],
        filesUnwanted: [Int] = [],
        priorityHigh: [Int] = [],
        priorityNormal: [Int] = [],
        priorityLow: [Int] = []
    ) {
        self.filesWanted = filesWanted
        self.filesUnwanted = filesUnwanted
        self.priorityHigh = priorityHigh
        self.priorityNormal = priorityNormal
        self.priorityLow = priorityLow
    }

    public var isEmpty: Bool {
        filesWanted.isEmpty
            && filesUnwanted.isEmpty
            && priorityHigh.isEmpty
            && priorityNormal.isEmpty
            && priorityLow.isEmpty
    }
}

public struct TorrentAddResult: Sendable, Hashable {
    public let hashString: String
    public let name: String
    public let wasDuplicate: Bool

    public init(hashString: String, name: String, wasDuplicate: Bool) {
        self.hashString = hashString
        self.name = name
        self.wasDuplicate = wasDuplicate
    }
}

public struct TorrentPathRename: Sendable, Hashable, Identifiable {
    public let path: String
    public let name: String

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }

    public var id: String { path }
}

public struct TorrentAddNamingPlan: Sendable, Hashable {
    public let rootName: String
    public let pathRenames: [TorrentPathRename]

    public init(rootName: String, pathRenames: [TorrentPathRename]) {
        self.rootName = rootName
        self.pathRenames = pathRenames
    }
}

public struct TorrentPeer: Sendable, Hashable, Codable {
    public let address: String?
    public let port: Int?
    public let clientName: String?
    public let flagStr: String?
    public let progress: Double?
    public let rateToClient: Double?
    public let rateToPeer: Double?
    public let isEncrypted: Bool?
    public let isIncoming: Bool?
    public let isUTP: Bool?

    public init(
        address: String? = nil,
        port: Int? = nil,
        clientName: String? = nil,
        flagStr: String? = nil,
        progress: Double? = nil,
        rateToClient: Double? = nil,
        rateToPeer: Double? = nil,
        isEncrypted: Bool? = nil,
        isIncoming: Bool? = nil,
        isUTP: Bool? = nil
    ) {
        self.address = address
        self.port = port
        self.clientName = clientName
        self.flagStr = flagStr
        self.progress = progress
        self.rateToClient = rateToClient
        self.rateToPeer = rateToPeer
        self.isEncrypted = isEncrypted
        self.isIncoming = isIncoming
        self.isUTP = isUTP
    }
}

public struct TorrentTracker: Sendable, Hashable, Codable, Identifiable {
    public let id: Int?
    public let announce: String?
    public let scrape: String?
    public let host: String?
    public let tier: Int?
    public let lastAnnounceResult: String?
    public let lastAnnounceSucceeded: Bool?
    public let lastScrapeResult: String?
    public let lastScrapeSucceeded: Bool?
    public let seederCount: Int?
    public let leecherCount: Int?
    public let downloadCount: Int?
    public let nextAnnounceTime: Int?

    public init(
        id: Int? = nil,
        announce: String? = nil,
        scrape: String? = nil,
        host: String? = nil,
        tier: Int? = nil,
        lastAnnounceResult: String? = nil,
        lastAnnounceSucceeded: Bool? = nil,
        lastScrapeResult: String? = nil,
        lastScrapeSucceeded: Bool? = nil,
        seederCount: Int? = nil,
        leecherCount: Int? = nil,
        downloadCount: Int? = nil,
        nextAnnounceTime: Int? = nil
    ) {
        self.id = id
        self.announce = announce
        self.scrape = scrape
        self.host = host
        self.tier = tier
        self.lastAnnounceResult = lastAnnounceResult
        self.lastAnnounceSucceeded = lastAnnounceSucceeded
        self.lastScrapeResult = lastScrapeResult
        self.lastScrapeSucceeded = lastScrapeSucceeded
        self.seederCount = seederCount
        self.leecherCount = leecherCount
        self.downloadCount = downloadCount
        self.nextAnnounceTime = nextAnnounceTime
    }
}

public struct CachedTorrentList: Sendable, Hashable, Codable {
    public let profileID: UUID
    public var torrents: [TorrentSummary]
    public var refreshedAt: Date

    public init(profileID: UUID, torrents: [TorrentSummary], refreshedAt: Date = Date()) {
        self.profileID = profileID
        self.torrents = torrents
        self.refreshedAt = refreshedAt
    }
}

public struct DownloadDirectoryHistory: Sendable, Hashable, Codable {
    public let profileID: UUID
    public var directories: [String]
    public var favoriteDirectories: [String]

    public init(profileID: UUID, directories: [String], favoriteDirectories: [String] = []) {
        self.profileID = profileID
        self.directories = directories
        self.favoriteDirectories = favoriteDirectories
    }

    private enum CodingKeys: String, CodingKey {
        case profileID
        case directories
        case favoriteDirectories
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        directories = try container.decode([String].self, forKey: .directories)
        favoriteDirectories = try container.decodeIfPresent([String].self, forKey: .favoriteDirectories) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profileID, forKey: .profileID)
        try container.encode(directories, forKey: .directories)
        try container.encode(favoriteDirectories, forKey: .favoriteDirectories)
    }
}

public struct SessionStats: Sendable, Equatable, Codable {
    public let downloadSpeed: Double
    public let uploadSpeed: Double

    public init(downloadSpeed: Double, uploadSpeed: Double) {
        self.downloadSpeed = downloadSpeed
        self.uploadSpeed = uploadSpeed
    }
}

public struct ServerFreeSpace: Sendable, Equatable, Codable {
    public let path: String
    public let sizeBytes: Int64
    public let totalSize: Int64?

    public init(path: String, sizeBytes: Int64, totalSize: Int64? = nil) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.totalSize = totalSize
    }

    public var availableBytes: UInt64? {
        guard sizeBytes >= 0 else { return nil }
        return UInt64(sizeBytes)
    }
}

public struct GlassRemotePreferences: Sendable, Hashable, Codable {
    public var isTorrentCachingEnabled: Bool
    public var cachedServerLimit: Int

    public init(isTorrentCachingEnabled: Bool = true, cachedServerLimit: Int = 4) {
        self.isTorrentCachingEnabled = isTorrentCachingEnabled
        self.cachedServerLimit = max(1, cachedServerLimit)
    }
}
