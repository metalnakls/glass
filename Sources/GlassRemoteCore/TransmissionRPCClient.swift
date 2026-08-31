import Foundation

public enum TransmissionRPCError: Error, Equatable, Sendable {
    case invalidResponse
    case http(status: Int, bodyPreview: String?)
    case network(url: String, message: String)
    case rpcResult(String)
    case serialization(String)
}

extension TransmissionRPCError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Transmission RPC returned a non-HTTP response."
        case let .http(status, bodyPreview):
            var message = "Transmission RPC returned HTTP \(status). \(httpHint(for: status))"
            if let bodyPreview, !bodyPreview.isEmpty {
                message += " Response: \(bodyPreview)"
            }
            return message
        case let .network(url, message):
            return "Could not reach \(url): \(message). Check the host, port, LAN/VPN, and that Transmission RPC is enabled."
        case let .rpcResult(result):
            return "Transmission RPC rejected the request: \(result)."
        case let .serialization(message):
            return message
        }
    }

    private func httpHint(for status: Int) -> String {
        switch status {
        case 401:
            return "Check the username and password."
        case 403:
            return "The server rejected this client, usually because Transmission RPC whitelist or host whitelist settings blocked it."
        case 404:
            return "Check the RPC path. Transmission usually uses /transmission/rpc."
        case 409:
            return "The Transmission session id challenge failed after retry."
        default:
            return "Check the Transmission RPC server configuration."
        }
    }
}

public struct TransmissionRPCConfig: Sendable, Equatable {
    public var profile: RemoteProfile
    public var password: String
    public var timeout: TimeInterval

    public init(profile: RemoteProfile, password: String, timeout: TimeInterval = 20.0) {
        self.profile = profile
        self.password = password
        self.timeout = timeout
    }
}

public actor TransmissionRPCClient {
    private let session: URLSession
    private var sessionId: String?
    private var config: TransmissionRPCConfig

    public init(config: TransmissionRPCConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func updateConfig(_ config: TransmissionRPCConfig) {
        self.config = config
        self.sessionId = nil
    }

    public func testConnection() async throws {
        _ = try await request(method: "session-get", arguments: [:]) as RPCEnvelope<SessionGetArgs>
    }

    public func fetchDefaultDownloadDirectory() async throws -> String? {
        let envelope: RPCEnvelope<SessionGetArgs> = try await request(method: "session-get", arguments: [:])
        return envelope.arguments.downloadDir
    }

    public func fetchDefaultFreeSpace() async throws -> ServerFreeSpace? {
        let envelope: RPCEnvelope<SessionGetArgs> = try await request(method: "session-get", arguments: [:])
        guard let path = envelope.arguments.downloadDir, !path.isEmpty else {
            return nil
        }

        if let sizeBytes = envelope.arguments.downloadDirFreeSpace {
            return ServerFreeSpace(path: path, sizeBytes: sizeBytes)
        }

        do {
            return try await fetchFreeSpace(at: path)
        } catch {
            return try await fetchLegacyFreeSpace(at: path)
        }
    }

    public func fetchFreeSpace(at path: String) async throws -> ServerFreeSpace {
        let envelope: RPCEnvelope<ServerFreeSpace> = try await request(method: "free_space", arguments: ["path": .string(path)])
        return envelope.arguments
    }

    private func fetchLegacyFreeSpace(at path: String) async throws -> ServerFreeSpace {
        let envelope: RPCEnvelope<ServerFreeSpace> = try await request(method: "free-space", arguments: ["path": .string(path)])
        return envelope.arguments
    }

    public func fetchSessionStats() async throws -> SessionStats {
        let envelope: RPCEnvelope<SessionStats> = try await request(method: "session-stats", arguments: [:])
        return envelope.arguments
    }

    public func fetchSessionSettings() async throws -> TransmissionSessionSettings {
        let fields = TransmissionSessionSettings.requestFields
        let envelope: RPCEnvelope<TransmissionSessionSettings> = try await request(method: "session-get", arguments: [
            "fields": .array(fields.map { .string($0) })
        ])
        return envelope.arguments
    }

    public func setSessionSettings(_ patch: TransmissionSessionSettingsPatch) async throws {
        let _: RPCEnvelope<EmptyArgs> = try await request(method: "session-set", arguments: patch.arguments)
    }

    public func fetchTorrents() async throws -> [TorrentSummary] {
        let fields = [
            "id", "hashString", "name", "status", "percentDone", "metadataPercentComplete", "rateDownload", "rateUpload",
            "sizeWhenDone", "leftUntilDone", "eta", "uploadRatio", "peersConnected", "downloadDir",
            "bandwidthPriority", "queuePosition", "file-count"
        ]

        let envelope: RPCEnvelope<TorrentGetArgs> = try await request(method: "torrent-get", arguments: [
            "fields": .array(fields.map { .string($0) })
        ])
        return envelope.arguments.torrents
    }

    public func fetchRecentlyActiveTorrents() async throws -> TorrentCollectionUpdate {
        let fields = [
            "id", "hashString", "name", "status", "percentDone", "metadataPercentComplete", "rateDownload", "rateUpload",
            "sizeWhenDone", "leftUntilDone", "eta", "uploadRatio", "peersConnected", "downloadDir",
            "bandwidthPriority", "queuePosition", "file-count"
        ]

        let envelope: RPCEnvelope<TorrentGetArgs> = try await request(method: "torrent-get", arguments: [
            "ids": .string("recently-active"),
            "fields": .array(fields.map { .string($0) })
        ])
        return .delta(changed: envelope.arguments.torrents, removedIDs: envelope.arguments.removed)
    }

    public func fetchTorrentDetails(hashString: String) async throws -> TorrentDetails {
        let fields = [
            "id", "hashString", "name", "status", "percentDone", "totalSize", "sizeWhenDone",
            "leftUntilDone", "eta", "uploadRatio", "uploadedEver", "downloadedEver", "corruptEver",
            "downloadDir", "addedDate", "activityDate", "startDate", "doneDate",
            "secondsDownloading", "secondsSeeding", "downloadLimit", "downloadLimited", "uploadLimit",
            "uploadLimited", "seedRatioLimit", "seedRatioMode", "bandwidthPriority", "queuePosition",
            "honorsSessionLimits", "isPrivate"
        ]

        return try await fetchTorrentDetails(hashString: hashString, fields: fields)
    }

    public func fetchTorrentFiles(hashString: String) async throws -> TorrentDetails {
        try await fetchTorrentDetails(
            hashString: hashString,
            fields: ["id", "hashString", "name", "files", "fileStats"]
        )
    }

    public func fetchTorrentPeers(hashString: String) async throws -> TorrentDetails {
        try await fetchTorrentDetails(
            hashString: hashString,
            fields: ["id", "hashString", "name", "peers"]
        )
    }

    public func fetchTorrentTrackers(hashString: String) async throws -> TorrentDetails {
        try await fetchTorrentDetails(
            hashString: hashString,
            fields: ["id", "hashString", "name", "trackerStats"]
        )
    }

    public func fetchTorrentPieces(hashString: String) async throws -> TorrentDetails {
        try await fetchTorrentDetails(
            hashString: hashString,
            fields: ["id", "hashString", "name", "pieceCount", "pieceSize", "pieces"]
        )
    }

    private func fetchTorrentDetails(hashString: String, fields: [String]) async throws -> TorrentDetails {

        let envelope: RPCEnvelope<TorrentDetailsGetArgs> = try await request(method: "torrent-get", arguments: [
            "ids": .array([.string(hashString)]),
            "fields": .array(fields.map { .string($0) })
        ])

        guard let details = envelope.arguments.torrents.first else {
            throw TransmissionRPCError.serialization("Transmission RPC returned no details for the selected torrent.")
        }

        return details
    }

    public func addMagnet(_ magnet: String, downloadDirectory: String?) async throws -> TorrentAddResult? {
        var args: [String: JSONValue] = ["filename": .string(magnet)]
        if let downloadDirectory, !downloadDirectory.isEmpty {
            args["download-dir"] = .string(downloadDirectory)
        }

        let envelope: RPCEnvelope<TorrentAddArgs> = try await request(method: "torrent-add", arguments: args)
        guard let torrent = envelope.arguments.added ?? envelope.arguments.duplicate else { return nil }
        return TorrentAddResult(
            hashString: torrent.hashString,
            name: torrent.name,
            wasDuplicate: envelope.arguments.added == nil
        )
    }

    @discardableResult
    public func addTorrentFile(
        base64Metainfo: String,
        torrentName: String? = nil,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection? = nil
    ) async throws -> TorrentAddResult? {
        var args: [String: JSONValue] = ["metainfo": .string(base64Metainfo)]
        if let downloadDirectory, !downloadDirectory.isEmpty {
            args["download-dir"] = .string(downloadDirectory)
        }
        if let fileSelection {
            fileSelection.apply(to: &args)
        }

        let envelope: RPCEnvelope<TorrentAddArgs> = try await request(method: "torrent-add", arguments: args)
        guard let torrent = envelope.arguments.added ?? envelope.arguments.duplicate else { return nil }
        let wasDuplicate = envelope.arguments.added == nil
        let trimmedName = torrentName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String
        if let trimmedName, !trimmedName.isEmpty, trimmedName != torrent.name {
            try await renamePath(id: torrent.hashString, path: torrent.name, name: trimmedName)
            resolvedName = trimmedName
        } else {
            resolvedName = torrent.name
        }
        return TorrentAddResult(hashString: torrent.hashString, name: resolvedName, wasDuplicate: wasDuplicate)
    }

    @discardableResult
    public func addTorrentFile(
        data: Data,
        torrentName: String? = nil,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection? = nil
    ) async throws -> TorrentAddResult? {
        try await addTorrentFile(
            base64Metainfo: data.base64EncodedString(),
            torrentName: torrentName,
            downloadDirectory: downloadDirectory,
            fileSelection: fileSelection
        )
    }

    public func start(ids: [String]) async throws {
        let _: RPCEnvelope<EmptyArgs> = try await request(method: "torrent-start", arguments: ["ids": .array(ids.map(JSONValue.string))])
    }

    public func stop(ids: [String]) async throws {
        let _: RPCEnvelope<EmptyArgs> = try await request(method: "torrent-stop", arguments: ["ids": .array(ids.map(JSONValue.string))])
    }

    public func remove(ids: [String], deleteLocalData: Bool) async throws {
        let _: RPCEnvelope<EmptyArgs> = try await request(
            method: "torrent-remove",
            arguments: [
                "ids": .array(ids.map(JSONValue.string)),
                "delete-local-data": .bool(deleteLocalData)
            ]
        )
    }

    public func verify(ids: [String]) async throws {
        let _: RPCEnvelope<EmptyArgs> = try await request(method: "torrent-verify", arguments: ["ids": .array(ids.map(JSONValue.string))])
    }

    public func reannounce(ids: [String]) async throws {
        let _: RPCEnvelope<EmptyArgs> = try await request(method: "torrent-reannounce", arguments: ["ids": .array(ids.map(JSONValue.string))])
    }

    public func queueMoveTop(ids: [String]) async throws {
        try await queueMove(method: "queue-move-top", ids: ids)
    }

    public func queueMoveUp(ids: [String]) async throws {
        try await queueMove(method: "queue-move-up", ids: ids)
    }

    public func queueMoveDown(ids: [String]) async throws {
        try await queueMove(method: "queue-move-down", ids: ids)
    }

    public func queueMoveBottom(ids: [String]) async throws {
        try await queueMove(method: "queue-move-bottom", ids: ids)
    }

    public func renamePath(id: String, path: String, name: String) async throws {
        let _: RPCEnvelope<EmptyArgs> = try await request(
            method: "torrent-rename-path",
            arguments: [
                "ids": .array([.string(id)]),
                "path": .string(path),
                "name": .string(name)
            ]
        )
    }

    public func setFileWanted(ids: [String], fileIndices: [Int], wanted: Bool) async throws {
        let key = wanted ? "files-wanted" : "files-unwanted"
        let _: RPCEnvelope<EmptyArgs> = try await request(
            method: "torrent-set",
            arguments: [
                "ids": .array(ids.map(JSONValue.string)),
                key: .array(fileIndices.map(JSONValue.int))
            ]
        )
    }

    public func setFilePriority(ids: [String], fileIndices: [Int], priority: Int) async throws {
        let key: String
        switch priority {
        case let value where value > 0:
            key = "priority-high"
        case let value where value < 0:
            key = "priority-low"
        default:
            key = "priority-normal"
        }

        let _: RPCEnvelope<EmptyArgs> = try await request(
            method: "torrent-set",
            arguments: [
                "ids": .array(ids.map(JSONValue.string)),
                key: .array(fileIndices.map(JSONValue.int))
            ]
        )
    }

    public func setTorrentPriority(ids: [String], priority: Int) async throws {
        let _: RPCEnvelope<EmptyArgs> = try await request(
            method: "torrent-set",
            arguments: [
                "ids": .array(ids.map(JSONValue.string)),
                "bandwidthPriority": .int(priority)
            ]
        )
    }

    private func queueMove(method: String, ids: [String]) async throws {
        let _: RPCEnvelope<EmptyArgs> = try await request(method: method, arguments: ["ids": .array(ids.map(JSONValue.string))])
    }

    private func request<T: Decodable>(method: String, arguments: [String: JSONValue]) async throws -> RPCEnvelope<T> {
        try await performRequest(method: method, arguments: arguments, retrying: false)
    }

    private func performRequest<T: Decodable>(method: String, arguments: [String: JSONValue], retrying: Bool) async throws -> RPCEnvelope<T> {
        var request = URLRequest(url: config.profile.rpcURL)
        request.timeoutInterval = config.timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Glass-Remote", forHTTPHeaderField: "User-Agent")
        if let sessionId, !sessionId.isEmpty {
            request.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id")
        }

        let credentials = credentials(for: config)
        if !credentials.username.isEmpty {
            let authPayload = "\(credentials.username):\(credentials.password)"
            guard let encoded = authPayload.data(using: .utf8)?.base64EncodedString() else {
                throw TransmissionRPCError.serialization("Failed to encode Basic auth.")
            }
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }

        let body = RPCBody(method: method, arguments: arguments)
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw TransmissionRPCError.serialization("Failed to encode RPC body: \(error.localizedDescription)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TransmissionRPCError.network(
                url: safeURLDescription(config.profile.rpcURL),
                message: error.localizedDescription
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw TransmissionRPCError.invalidResponse
        }

        if let newSessionId = headerValue("X-Transmission-Session-Id", in: http), !newSessionId.isEmpty {
            sessionId = newSessionId
        }

        if http.statusCode == 409 {
            if !retrying, let sessionId, !sessionId.isEmpty {
                return try await performRequest(method: method, arguments: arguments, retrying: true)
            }
            throw TransmissionRPCError.http(status: http.statusCode, bodyPreview: previewBody(data))
        }

        guard (200..<300).contains(http.statusCode) else {
            throw TransmissionRPCError.http(status: http.statusCode, bodyPreview: previewBody(data))
        }

        do {
            let envelope = try JSONDecoder().decode(RPCEnvelope<T>.self, from: data)
            if envelope.result != "success" {
                throw TransmissionRPCError.rpcResult(envelope.result)
            }
            return envelope
        } catch let error as TransmissionRPCError {
            throw error
        } catch {
            throw TransmissionRPCError.serialization("Failed to decode RPC response: \(error.localizedDescription)")
        }
    }

    private func headerValue(_ name: String, in response: HTTPURLResponse) -> String? {
        if let direct = response.value(forHTTPHeaderField: name), !direct.isEmpty {
            return direct
        }
        return nil
    }

    private func previewBody(_ data: Data) -> String? {
        guard !data.isEmpty, var text = String(data: data, encoding: .utf8) else {
            return nil
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 500 {
            text = String(text.prefix(500)) + "..."
        }
        return text.isEmpty ? nil : text
    }

    private func credentials(for config: TransmissionRPCConfig) -> (username: String, password: String) {
        let urlComponents = URLComponents(url: config.profile.rpcURL, resolvingAgainstBaseURL: false)
        let username = config.profile.username.isEmpty ? (urlComponents?.user ?? "") : config.profile.username
        let password = config.password.isEmpty ? (urlComponents?.password ?? "") : config.password
        return (username, password)
    }

    private func safeURLDescription(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        return components?.string ?? url.absoluteString
    }
}

public struct TransmissionSessionSettings: Decodable, Sendable, Equatable {
    public static let requestFields = [
        "version", "rpc-version", "download-dir", "incomplete-dir", "incomplete-dir-enabled",
        "rename-partial-files", "start-added-torrents", "trash-original-torrent-files",
        "speed-limit-down", "speed-limit-down-enabled", "speed-limit-up", "speed-limit-up-enabled",
        "alt-speed-enabled", "alt-speed-down", "alt-speed-up", "alt-speed-time-enabled",
        "alt-speed-time-begin", "alt-speed-time-end", "alt-speed-time-day", "seedRatioLimit",
        "seedRatioLimited", "idle-seeding-limit", "idle-seeding-limit-enabled",
        "download-queue-enabled", "download-queue-size", "seed-queue-enabled", "seed-queue-size",
        "queue-stalled-enabled", "queue-stalled-minutes", "peer-limit-global",
        "peer-limit-per-torrent", "peer-port", "pex-enabled", "dht-enabled", "lpd-enabled",
        "utp-enabled", "encryption", "blocklist-enabled", "blocklist-url", "blocklist-size"
    ]

    public let version: String?
    public let rpcVersion: Int?
    public let downloadDirectory: String?
    public let incompleteDirectory: String?
    public let incompleteDirectoryEnabled: Bool?
    public let renamePartialFiles: Bool?
    public let startAddedTorrents: Bool?
    public let trashOriginalTorrentFiles: Bool?
    public let downloadSpeedLimit: Int?
    public let downloadSpeedLimited: Bool?
    public let uploadSpeedLimit: Int?
    public let uploadSpeedLimited: Bool?
    public let alternativeSpeedEnabled: Bool?
    public let alternativeDownloadSpeedLimit: Int?
    public let alternativeUploadSpeedLimit: Int?
    public let alternativeSpeedTimeEnabled: Bool?
    public let alternativeSpeedTimeBegin: Int?
    public let alternativeSpeedTimeEnd: Int?
    public let alternativeSpeedTimeDay: Int?
    public let seedRatioLimit: Double?
    public let seedRatioLimited: Bool?
    public let idleSeedingLimit: Int?
    public let idleSeedingLimitEnabled: Bool?
    public let downloadQueueEnabled: Bool?
    public let downloadQueueSize: Int?
    public let seedQueueEnabled: Bool?
    public let seedQueueSize: Int?
    public let queueStalledEnabled: Bool?
    public let queueStalledMinutes: Int?
    public let globalPeerLimit: Int?
    public let torrentPeerLimit: Int?
    public let peerPort: Int?
    public let pexEnabled: Bool?
    public let dhtEnabled: Bool?
    public let lpdEnabled: Bool?
    public let utpEnabled: Bool?
    public let encryption: String?
    public let blocklistEnabled: Bool?
    public let blocklistURL: String?
    public let blocklistSize: Int?

    enum CodingKeys: String, CodingKey {
        case version
        case rpcVersion = "rpc-version"
        case downloadDirectory = "download-dir"
        case incompleteDirectory = "incomplete-dir"
        case incompleteDirectoryEnabled = "incomplete-dir-enabled"
        case renamePartialFiles = "rename-partial-files"
        case startAddedTorrents = "start-added-torrents"
        case trashOriginalTorrentFiles = "trash-original-torrent-files"
        case downloadSpeedLimit = "speed-limit-down"
        case downloadSpeedLimited = "speed-limit-down-enabled"
        case uploadSpeedLimit = "speed-limit-up"
        case uploadSpeedLimited = "speed-limit-up-enabled"
        case alternativeSpeedEnabled = "alt-speed-enabled"
        case alternativeDownloadSpeedLimit = "alt-speed-down"
        case alternativeUploadSpeedLimit = "alt-speed-up"
        case alternativeSpeedTimeEnabled = "alt-speed-time-enabled"
        case alternativeSpeedTimeBegin = "alt-speed-time-begin"
        case alternativeSpeedTimeEnd = "alt-speed-time-end"
        case alternativeSpeedTimeDay = "alt-speed-time-day"
        case seedRatioLimit
        case seedRatioLimited
        case idleSeedingLimit = "idle-seeding-limit"
        case idleSeedingLimitEnabled = "idle-seeding-limit-enabled"
        case downloadQueueEnabled = "download-queue-enabled"
        case downloadQueueSize = "download-queue-size"
        case seedQueueEnabled = "seed-queue-enabled"
        case seedQueueSize = "seed-queue-size"
        case queueStalledEnabled = "queue-stalled-enabled"
        case queueStalledMinutes = "queue-stalled-minutes"
        case globalPeerLimit = "peer-limit-global"
        case torrentPeerLimit = "peer-limit-per-torrent"
        case peerPort = "peer-port"
        case pexEnabled = "pex-enabled"
        case dhtEnabled = "dht-enabled"
        case lpdEnabled = "lpd-enabled"
        case utpEnabled = "utp-enabled"
        case encryption
        case blocklistEnabled = "blocklist-enabled"
        case blocklistURL = "blocklist-url"
        case blocklistSize = "blocklist-size"
    }
}

public struct TransmissionSessionSettingsPatch: Sendable, Equatable {
    public var downloadDirectory: String?
    public var incompleteDirectory: String?
    public var incompleteDirectoryEnabled: Bool?
    public var renamePartialFiles: Bool?
    public var startAddedTorrents: Bool?
    public var trashOriginalTorrentFiles: Bool?
    public var downloadSpeedLimit: Int?
    public var downloadSpeedLimited: Bool?
    public var uploadSpeedLimit: Int?
    public var uploadSpeedLimited: Bool?
    public var alternativeSpeedEnabled: Bool?
    public var alternativeDownloadSpeedLimit: Int?
    public var alternativeUploadSpeedLimit: Int?
    public var alternativeSpeedTimeEnabled: Bool?
    public var alternativeSpeedTimeBegin: Int?
    public var alternativeSpeedTimeEnd: Int?
    public var alternativeSpeedTimeDay: Int?
    public var seedRatioLimit: Double?
    public var seedRatioLimited: Bool?
    public var idleSeedingLimit: Int?
    public var idleSeedingLimitEnabled: Bool?
    public var downloadQueueEnabled: Bool?
    public var downloadQueueSize: Int?
    public var seedQueueEnabled: Bool?
    public var seedQueueSize: Int?
    public var queueStalledEnabled: Bool?
    public var queueStalledMinutes: Int?
    public var globalPeerLimit: Int?
    public var torrentPeerLimit: Int?
    public var peerPort: Int?
    public var pexEnabled: Bool?
    public var dhtEnabled: Bool?
    public var lpdEnabled: Bool?
    public var utpEnabled: Bool?
    public var encryption: String?
    public var blocklistEnabled: Bool?
    public var blocklistURL: String?

    public init(
        downloadDirectory: String? = nil,
        incompleteDirectory: String? = nil,
        incompleteDirectoryEnabled: Bool? = nil,
        renamePartialFiles: Bool? = nil,
        startAddedTorrents: Bool? = nil,
        trashOriginalTorrentFiles: Bool? = nil,
        downloadSpeedLimit: Int? = nil,
        downloadSpeedLimited: Bool? = nil,
        uploadSpeedLimit: Int? = nil,
        uploadSpeedLimited: Bool? = nil,
        alternativeSpeedEnabled: Bool? = nil,
        alternativeDownloadSpeedLimit: Int? = nil,
        alternativeUploadSpeedLimit: Int? = nil,
        alternativeSpeedTimeEnabled: Bool? = nil,
        alternativeSpeedTimeBegin: Int? = nil,
        alternativeSpeedTimeEnd: Int? = nil,
        alternativeSpeedTimeDay: Int? = nil,
        seedRatioLimit: Double? = nil,
        seedRatioLimited: Bool? = nil,
        idleSeedingLimit: Int? = nil,
        idleSeedingLimitEnabled: Bool? = nil,
        downloadQueueEnabled: Bool? = nil,
        downloadQueueSize: Int? = nil,
        seedQueueEnabled: Bool? = nil,
        seedQueueSize: Int? = nil,
        queueStalledEnabled: Bool? = nil,
        queueStalledMinutes: Int? = nil,
        globalPeerLimit: Int? = nil,
        torrentPeerLimit: Int? = nil,
        peerPort: Int? = nil,
        pexEnabled: Bool? = nil,
        dhtEnabled: Bool? = nil,
        lpdEnabled: Bool? = nil,
        utpEnabled: Bool? = nil,
        encryption: String? = nil,
        blocklistEnabled: Bool? = nil,
        blocklistURL: String? = nil
    ) {
        self.downloadDirectory = downloadDirectory
        self.incompleteDirectory = incompleteDirectory
        self.incompleteDirectoryEnabled = incompleteDirectoryEnabled
        self.renamePartialFiles = renamePartialFiles
        self.startAddedTorrents = startAddedTorrents
        self.trashOriginalTorrentFiles = trashOriginalTorrentFiles
        self.downloadSpeedLimit = downloadSpeedLimit
        self.downloadSpeedLimited = downloadSpeedLimited
        self.uploadSpeedLimit = uploadSpeedLimit
        self.uploadSpeedLimited = uploadSpeedLimited
        self.alternativeSpeedEnabled = alternativeSpeedEnabled
        self.alternativeDownloadSpeedLimit = alternativeDownloadSpeedLimit
        self.alternativeUploadSpeedLimit = alternativeUploadSpeedLimit
        self.alternativeSpeedTimeEnabled = alternativeSpeedTimeEnabled
        self.alternativeSpeedTimeBegin = alternativeSpeedTimeBegin
        self.alternativeSpeedTimeEnd = alternativeSpeedTimeEnd
        self.alternativeSpeedTimeDay = alternativeSpeedTimeDay
        self.seedRatioLimit = seedRatioLimit
        self.seedRatioLimited = seedRatioLimited
        self.idleSeedingLimit = idleSeedingLimit
        self.idleSeedingLimitEnabled = idleSeedingLimitEnabled
        self.downloadQueueEnabled = downloadQueueEnabled
        self.downloadQueueSize = downloadQueueSize
        self.seedQueueEnabled = seedQueueEnabled
        self.seedQueueSize = seedQueueSize
        self.queueStalledEnabled = queueStalledEnabled
        self.queueStalledMinutes = queueStalledMinutes
        self.globalPeerLimit = globalPeerLimit
        self.torrentPeerLimit = torrentPeerLimit
        self.peerPort = peerPort
        self.pexEnabled = pexEnabled
        self.dhtEnabled = dhtEnabled
        self.lpdEnabled = lpdEnabled
        self.utpEnabled = utpEnabled
        self.encryption = encryption
        self.blocklistEnabled = blocklistEnabled
        self.blocklistURL = blocklistURL
    }

    var arguments: [String: JSONValue] {
        var args: [String: JSONValue] = [:]
        args.add("download-dir", downloadDirectory)
        args.add("incomplete-dir", incompleteDirectory)
        args.add("incomplete-dir-enabled", incompleteDirectoryEnabled)
        args.add("rename-partial-files", renamePartialFiles)
        args.add("start-added-torrents", startAddedTorrents)
        args.add("trash-original-torrent-files", trashOriginalTorrentFiles)
        args.add("speed-limit-down", downloadSpeedLimit)
        args.add("speed-limit-down-enabled", downloadSpeedLimited)
        args.add("speed-limit-up", uploadSpeedLimit)
        args.add("speed-limit-up-enabled", uploadSpeedLimited)
        args.add("alt-speed-enabled", alternativeSpeedEnabled)
        args.add("alt-speed-down", alternativeDownloadSpeedLimit)
        args.add("alt-speed-up", alternativeUploadSpeedLimit)
        args.add("alt-speed-time-enabled", alternativeSpeedTimeEnabled)
        args.add("alt-speed-time-begin", alternativeSpeedTimeBegin)
        args.add("alt-speed-time-end", alternativeSpeedTimeEnd)
        args.add("alt-speed-time-day", alternativeSpeedTimeDay)
        args.add("seedRatioLimit", seedRatioLimit)
        args.add("seedRatioLimited", seedRatioLimited)
        args.add("idle-seeding-limit", idleSeedingLimit)
        args.add("idle-seeding-limit-enabled", idleSeedingLimitEnabled)
        args.add("download-queue-enabled", downloadQueueEnabled)
        args.add("download-queue-size", downloadQueueSize)
        args.add("seed-queue-enabled", seedQueueEnabled)
        args.add("seed-queue-size", seedQueueSize)
        args.add("queue-stalled-enabled", queueStalledEnabled)
        args.add("queue-stalled-minutes", queueStalledMinutes)
        args.add("peer-limit-global", globalPeerLimit)
        args.add("peer-limit-per-torrent", torrentPeerLimit)
        args.add("peer-port", peerPort)
        args.add("pex-enabled", pexEnabled)
        args.add("dht-enabled", dhtEnabled)
        args.add("lpd-enabled", lpdEnabled)
        args.add("utp-enabled", utpEnabled)
        args.add("encryption", encryption)
        args.add("blocklist-enabled", blocklistEnabled)
        args.add("blocklist-url", blocklistURL)
        return args
    }
}

private struct SessionGetArgs: Decodable, Sendable {
    let downloadDir: String?
    let downloadDirFreeSpace: Int64?
    let rpcVersion: Int?
    let version: String?

    enum CodingKeys: String, CodingKey {
        case downloadDir = "download-dir"
        case downloadDirFreeSpace = "download-dir-free-space"
        case downloadDirFreeSpaceSnake = "download_dir_free_space"
        case rpcVersion = "rpc-version"
        case version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downloadDir = try container.decodeIfPresent(String.self, forKey: .downloadDir)
        downloadDirFreeSpace = try container.decodeFlexibleInt64IfPresent(
            forKeys: [.downloadDirFreeSpace, .downloadDirFreeSpaceSnake]
        )
        rpcVersion = try container.decodeIfPresent(Int.self, forKey: .rpcVersion)
        version = try container.decodeIfPresent(String.self, forKey: .version)
    }
}

private struct TorrentGetArgs: Decodable, Sendable {
    let torrents: [TorrentSummary]
    let removed: [Int]

    private enum CodingKeys: String, CodingKey {
        case torrents
        case removed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        torrents = try container.decode([TorrentSummary].self, forKey: .torrents)
        removed = try container.decodeIfPresent([Int].self, forKey: .removed) ?? []
    }
}

private struct TorrentDetailsGetArgs: Decodable, Sendable {
    let torrents: [TorrentDetails]
}

private struct TorrentAddArgs: Decodable, Sendable {
    let added: AddedTorrent?
    let duplicate: AddedTorrent?

    private enum CodingKeys: String, CodingKey {
        case added = "torrent-added"
        case duplicate = "torrent-duplicate"
    }
}

private struct AddedTorrent: Decodable, Sendable {
    let name: String
    let hashString: String
}

private struct EmptyArgs: Decodable, Sendable {}

extension ServerFreeSpace {
    private enum CodingKeys: String, CodingKey {
        case path
        case sizeBytes = "size-bytes"
        case totalSize = "total-size"
        case sizeBytesSnake = "size_bytes"
        case totalSizeSnake = "total_size"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        sizeBytes = try container.decodeFlexibleInt64(forKeys: [.sizeBytes, .sizeBytesSnake])
        totalSize = try container.decodeFlexibleInt64IfPresent(forKeys: [.totalSize, .totalSizeSnake])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(sizeBytes, forKey: .sizeBytes)
        try container.encodeIfPresent(totalSize, forKey: .totalSize)
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleInt64(forKeys keys: [Key]) throws -> Int64 {
        for key in keys {
            if let value = try decodeFlexibleInt64IfPresent(forKey: key) {
                return value
            }
        }
        throw DecodingError.keyNotFound(
            keys[0],
            DecodingError.Context(codingPath: codingPath, debugDescription: "Missing integer value")
        )
    }

    func decodeFlexibleInt64IfPresent(forKeys keys: [Key]) throws -> Int64? {
        for key in keys {
            if let value = try decodeFlexibleInt64IfPresent(forKey: key) {
                return value
            }
        }
        return nil
    }

    private func decodeFlexibleInt64IfPresent(forKey key: Key) throws -> Int64? {
        if let value = try decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try decodeIfPresent(Double.self, forKey: key) {
            return Int64(value)
        }
        return nil
    }
}

private struct RPCBody: Encodable {
    let method: String
    let arguments: [String: JSONValue]
}

private struct RPCEnvelope<T: Decodable>: Decodable {
    let result: String
    let arguments: T
}

public enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case int(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

private extension TorrentAddFileSelection {
    func apply(to args: inout [String: JSONValue]) {
        guard !isEmpty else { return }
        if !filesWanted.isEmpty {
            args["files-wanted"] = .array(filesWanted.map(JSONValue.int))
        }
        if !filesUnwanted.isEmpty {
            args["files-unwanted"] = .array(filesUnwanted.map(JSONValue.int))
        }
        if !priorityHigh.isEmpty {
            args["priority-high"] = .array(priorityHigh.map(JSONValue.int))
        }
        if !priorityNormal.isEmpty {
            args["priority-normal"] = .array(priorityNormal.map(JSONValue.int))
        }
        if !priorityLow.isEmpty {
            args["priority-low"] = .array(priorityLow.map(JSONValue.int))
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    mutating func add(_ key: String, _ value: String?) {
        guard let value else { return }
        self[key] = .string(value)
    }

    mutating func add(_ key: String, _ value: Int?) {
        guard let value else { return }
        self[key] = .int(value)
    }

    mutating func add(_ key: String, _ value: Double?) {
        guard let value else { return }
        self[key] = .number(value)
    }

    mutating func add(_ key: String, _ value: Bool?) {
        guard let value else { return }
        self[key] = .bool(value)
    }
}
