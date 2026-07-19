import Foundation
import GlassRemoteCore

public protocol TransmissionRPCServicing: Sendable {
    func testConnection() async throws
    func fetchDefaultDownloadDirectory() async throws -> String?
    func fetchDefaultFreeSpace() async throws -> ServerFreeSpace?
    func fetchSessionStats() async throws -> SessionStats
    func fetchSessionSettings() async throws -> TransmissionSessionSettings
    func setSessionSettings(_ patch: TransmissionSessionSettingsPatch) async throws
    func fetchTorrents() async throws -> [TorrentSummary]
    func fetchTorrentDetails(hashString: String) async throws -> TorrentDetails
    func addMagnet(_ magnet: String, downloadDirectory: String?) async throws
    func addTorrentFile(
        data: Data,
        torrentName: String?,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection?
    ) async throws -> TorrentAddResult?
    func start(ids: [String]) async throws
    func stop(ids: [String]) async throws
    func remove(ids: [String], deleteLocalData: Bool) async throws
    func verify(ids: [String]) async throws
    func reannounce(ids: [String]) async throws
    func queueMoveTop(ids: [String]) async throws
    func queueMoveUp(ids: [String]) async throws
    func queueMoveDown(ids: [String]) async throws
    func queueMoveBottom(ids: [String]) async throws
    func renamePath(id: String, path: String, name: String) async throws
    func setFileWanted(ids: [String], fileIndices: [Int], wanted: Bool) async throws
    func setFilePriority(ids: [String], fileIndices: [Int], priority: Int) async throws
    func setTorrentPriority(ids: [String], priority: Int) async throws
}

extension TransmissionRPCClient: TransmissionRPCServicing {}

public struct TorrentSourceInfo: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let systemImage: String
    public let rpcURL: URL
    public let username: String
    public let isLocal: Bool

    public init(
        id: UUID,
        name: String,
        systemImage: String,
        rpcURL: URL,
        username: String,
        isLocal: Bool
    ) {
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.rpcURL = rpcURL
        self.username = username
        self.isLocal = isLocal
    }
}

public struct TorrentProviderSnapshot: Sendable {
    public let stats: SessionStats
    public let torrents: [TorrentSummary]
    public let freeSpace: ServerFreeSpace?

    public init(stats: SessionStats, torrents: [TorrentSummary], freeSpace: ServerFreeSpace?) {
        self.stats = stats
        self.torrents = torrents
        self.freeSpace = freeSpace
    }
}

public protocol TorrentProvider: Sendable {
    var source: TorrentSourceInfo { get }

    func fetchSnapshot() async throws -> TorrentProviderSnapshot
    func fetchDefaultDownloadDirectory() async throws -> String?
    func fetchSessionSettings() async throws -> TransmissionSessionSettings
    func setSessionSettings(_ patch: TransmissionSessionSettingsPatch) async throws
    func fetchTorrentDetails(hashString: String) async throws -> TorrentDetails
    func addMagnet(_ magnet: String, downloadDirectory: String?) async throws
    func addTorrentFile(
        data: Data,
        torrentName: String?,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection?
    ) async throws -> TorrentAddResult?
    func start(ids: [String]) async throws
    func stop(ids: [String]) async throws
    func remove(ids: [String], deleteLocalData: Bool) async throws
    func verify(ids: [String]) async throws
    func reannounce(ids: [String]) async throws
    func queueMoveTop(ids: [String]) async throws
    func queueMoveUp(ids: [String]) async throws
    func queueMoveDown(ids: [String]) async throws
    func queueMoveBottom(ids: [String]) async throws
    func renamePath(id: String, path: String, name: String) async throws
    func setFileWanted(ids: [String], fileIndices: [Int], wanted: Bool) async throws
    func setFilePriority(ids: [String], fileIndices: [Int], priority: Int) async throws
    func setTorrentPriority(ids: [String], priority: Int) async throws
}

public protocol LocalTransmissionServicing: Sendable {
    func fetchSnapshot() async throws -> TorrentProviderSnapshot
    func fetchDefaultDownloadDirectory() async throws -> String?
    func fetchSessionSettings() async throws -> TransmissionSessionSettings
    func setSessionSettings(_ patch: TransmissionSessionSettingsPatch) async throws
    func fetchTorrentDetails(hashString: String) async throws -> TorrentDetails
    func addMagnet(_ magnet: String, downloadDirectory: String?) async throws
    func addTorrentFile(
        data: Data,
        torrentName: String?,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection?
    ) async throws -> TorrentAddResult?
    func start(ids: [String]) async throws
    func stop(ids: [String]) async throws
    func remove(ids: [String], deleteLocalData: Bool) async throws
    func verify(ids: [String]) async throws
    func reannounce(ids: [String]) async throws
    func queueMoveTop(ids: [String]) async throws
    func queueMoveUp(ids: [String]) async throws
    func queueMoveDown(ids: [String]) async throws
    func queueMoveBottom(ids: [String]) async throws
    func renamePath(id: String, path: String, name: String) async throws
    func setFileWanted(ids: [String], fileIndices: [Int], wanted: Bool) async throws
    func setFilePriority(ids: [String], fileIndices: [Int], priority: Int) async throws
    func setTorrentPriority(ids: [String], priority: Int) async throws
}

public struct UnavailableLocalTransmissionSession: LocalTransmissionServicing {
    private let errorDescription: String

    public init(errorDescription: String = "Local torrent downloading is unavailable in this build.") {
        self.errorDescription = errorDescription
    }

    public func fetchSnapshot() async throws -> TorrentProviderSnapshot { throw error }
    public func fetchDefaultDownloadDirectory() async throws -> String? { throw error }
    public func fetchSessionSettings() async throws -> TransmissionSessionSettings { throw error }
    public func setSessionSettings(_ patch: TransmissionSessionSettingsPatch) async throws { throw error }
    public func fetchTorrentDetails(hashString: String) async throws -> TorrentDetails { throw error }
    public func addMagnet(_ magnet: String, downloadDirectory: String?) async throws { throw error }
    public func addTorrentFile(
        data: Data,
        torrentName: String?,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection?
    ) async throws -> TorrentAddResult? { throw error }
    public func start(ids: [String]) async throws { throw error }
    public func stop(ids: [String]) async throws { throw error }
    public func remove(ids: [String], deleteLocalData: Bool) async throws { throw error }
    public func verify(ids: [String]) async throws { throw error }
    public func reannounce(ids: [String]) async throws { throw error }
    public func queueMoveTop(ids: [String]) async throws { throw error }
    public func queueMoveUp(ids: [String]) async throws { throw error }
    public func queueMoveDown(ids: [String]) async throws { throw error }
    public func queueMoveBottom(ids: [String]) async throws { throw error }
    public func renamePath(id: String, path: String, name: String) async throws { throw error }
    public func setFileWanted(ids: [String], fileIndices: [Int], wanted: Bool) async throws { throw error }
    public func setFilePriority(ids: [String], fileIndices: [Int], priority: Int) async throws { throw error }
    public func setTorrentPriority(ids: [String], priority: Int) async throws { throw error }

    private var error: LocalizedError {
        LocalTransmissionSessionError.unavailable(errorDescription)
    }
}

public enum LocalTransmissionSessionError: LocalizedError {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            return message
        }
    }
}

public actor RemoteTorrentProvider: TorrentProvider {
    private struct SupplementalSnapshot {
        let fetchedAt: Date
        let stats: SessionStats
        let freeSpace: ServerFreeSpace?
    }

    private static let supplementalRefreshInterval: TimeInterval = 30

    public nonisolated let source: TorrentSourceInfo
    private let client: any TransmissionRPCServicing
    private var cachedSupplementalSnapshot: SupplementalSnapshot?

    public init(
        profile: RemoteProfile,
        password: String,
        clientFactory: @Sendable (TransmissionRPCConfig) -> any TransmissionRPCServicing
    ) {
        self.source = TorrentSourceInfo(
            id: profile.id,
            name: profile.name,
            systemImage: "server.rack",
            rpcURL: profile.rpcURL,
            username: profile.username,
            isLocal: false
        )
        self.client = clientFactory(TransmissionRPCConfig(profile: profile, password: password))
    }

    fileprivate init(
        source: TorrentSourceInfo,
        password: String,
        clientFactory: @Sendable (TransmissionRPCConfig) -> any TransmissionRPCServicing
    ) {
        self.source = source
        let profile = RemoteProfile(
            id: source.id,
            name: source.name,
            rpcURL: source.rpcURL,
            username: source.username
        )
        self.client = clientFactory(TransmissionRPCConfig(profile: profile, password: password))
    }

    public func fetchSnapshot() async throws -> TorrentProviderSnapshot {
        async let fetchedTorrents = client.fetchTorrents()
        async let fetchedSupplemental = supplementalSnapshot()
        let (torrents, supplemental) = try await (fetchedTorrents, fetchedSupplemental)
        return TorrentProviderSnapshot(
            stats: supplemental.stats,
            torrents: torrents,
            freeSpace: supplemental.freeSpace
        )
    }

    public func fetchDefaultDownloadDirectory() async throws -> String? {
        try await client.fetchDefaultDownloadDirectory()
    }

    public func fetchSessionSettings() async throws -> TransmissionSessionSettings {
        try await client.fetchSessionSettings()
    }

    public func setSessionSettings(_ patch: TransmissionSessionSettingsPatch) async throws {
        try await client.setSessionSettings(patch)
    }

    public func fetchTorrentDetails(hashString: String) async throws -> TorrentDetails {
        try await client.fetchTorrentDetails(hashString: hashString)
    }

    public func addMagnet(_ magnet: String, downloadDirectory: String?) async throws {
        try await client.addMagnet(magnet, downloadDirectory: downloadDirectory)
    }

    public func addTorrentFile(
        data: Data,
        torrentName: String?,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection?
    ) async throws -> TorrentAddResult? {
        try await client.addTorrentFile(
            data: data,
            torrentName: torrentName,
            downloadDirectory: downloadDirectory,
            fileSelection: fileSelection
        )
    }

    public func start(ids: [String]) async throws {
        try await client.start(ids: ids)
    }

    public func stop(ids: [String]) async throws {
        try await client.stop(ids: ids)
    }

    public func remove(ids: [String], deleteLocalData: Bool) async throws {
        try await client.remove(ids: ids, deleteLocalData: deleteLocalData)
    }

    public func verify(ids: [String]) async throws {
        try await client.verify(ids: ids)
    }

    public func reannounce(ids: [String]) async throws {
        try await client.reannounce(ids: ids)
    }

    public func queueMoveTop(ids: [String]) async throws {
        try await client.queueMoveTop(ids: ids)
    }

    public func queueMoveUp(ids: [String]) async throws {
        try await client.queueMoveUp(ids: ids)
    }

    public func queueMoveDown(ids: [String]) async throws {
        try await client.queueMoveDown(ids: ids)
    }

    public func queueMoveBottom(ids: [String]) async throws {
        try await client.queueMoveBottom(ids: ids)
    }

    public func renamePath(id: String, path: String, name: String) async throws {
        try await client.renamePath(id: id, path: path, name: name)
    }

    public func setFileWanted(ids: [String], fileIndices: [Int], wanted: Bool) async throws {
        try await client.setFileWanted(ids: ids, fileIndices: fileIndices, wanted: wanted)
    }

    public func setFilePriority(ids: [String], fileIndices: [Int], priority: Int) async throws {
        try await client.setFilePriority(ids: ids, fileIndices: fileIndices, priority: priority)
    }

    public func setTorrentPriority(ids: [String], priority: Int) async throws {
        try await client.setTorrentPriority(ids: ids, priority: priority)
    }

    private func defaultFreeSpace() async -> ServerFreeSpace? {
        try? await client.fetchDefaultFreeSpace()
    }

    private func supplementalSnapshot() async throws -> SupplementalSnapshot {
        let now = Date()
        if let cachedSupplementalSnapshot,
           now.timeIntervalSince(cachedSupplementalSnapshot.fetchedAt) < Self.supplementalRefreshInterval {
            return cachedSupplementalSnapshot
        }

        async let fetchedStats = client.fetchSessionStats()
        async let fetchedFreeSpace = defaultFreeSpace()
        let (stats, freeSpace) = try await (fetchedStats, fetchedFreeSpace)
        let snapshot = SupplementalSnapshot(
            fetchedAt: now,
            stats: stats,
            freeSpace: freeSpace
        )
        cachedSupplementalSnapshot = snapshot
        return snapshot
    }
}

public actor LocalTorrentProvider: TorrentProvider {
    public nonisolated let source: TorrentSourceInfo
    private let session: any LocalTransmissionServicing

    public init(
        id: UUID,
        name: String,
        systemImage: String,
        session: any LocalTransmissionServicing
    ) {
        self.source = TorrentSourceInfo(
            id: id,
            name: name,
            systemImage: systemImage,
            rpcURL: URL(string: "glass-local://this-mac")!,
            username: "",
            isLocal: true
        )
        self.session = session
    }

    public func fetchSnapshot() async throws -> TorrentProviderSnapshot {
        try await session.fetchSnapshot()
    }

    public func fetchDefaultDownloadDirectory() async throws -> String? {
        try await session.fetchDefaultDownloadDirectory()
    }

    public func fetchSessionSettings() async throws -> TransmissionSessionSettings {
        try await session.fetchSessionSettings()
    }

    public func setSessionSettings(_ patch: TransmissionSessionSettingsPatch) async throws {
        try await session.setSessionSettings(patch)
    }

    public func fetchTorrentDetails(hashString: String) async throws -> TorrentDetails {
        try await session.fetchTorrentDetails(hashString: hashString)
    }

    public func addMagnet(_ magnet: String, downloadDirectory: String?) async throws {
        try await session.addMagnet(magnet, downloadDirectory: downloadDirectory)
    }

    public func addTorrentFile(
        data: Data,
        torrentName: String?,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection?
    ) async throws -> TorrentAddResult? {
        try await session.addTorrentFile(
            data: data,
            torrentName: torrentName,
            downloadDirectory: downloadDirectory,
            fileSelection: fileSelection
        )
    }

    public func start(ids: [String]) async throws {
        try await session.start(ids: ids)
    }

    public func stop(ids: [String]) async throws {
        try await session.stop(ids: ids)
    }

    public func remove(ids: [String], deleteLocalData: Bool) async throws {
        try await session.remove(ids: ids, deleteLocalData: deleteLocalData)
    }

    public func verify(ids: [String]) async throws {
        try await session.verify(ids: ids)
    }

    public func reannounce(ids: [String]) async throws {
        try await session.reannounce(ids: ids)
    }

    public func queueMoveTop(ids: [String]) async throws {
        try await session.queueMoveTop(ids: ids)
    }

    public func queueMoveUp(ids: [String]) async throws {
        try await session.queueMoveUp(ids: ids)
    }

    public func queueMoveDown(ids: [String]) async throws {
        try await session.queueMoveDown(ids: ids)
    }

    public func queueMoveBottom(ids: [String]) async throws {
        try await session.queueMoveBottom(ids: ids)
    }

    public func renamePath(id: String, path: String, name: String) async throws {
        try await session.renamePath(id: id, path: path, name: name)
    }

    public func setFileWanted(ids: [String], fileIndices: [Int], wanted: Bool) async throws {
        try await session.setFileWanted(ids: ids, fileIndices: fileIndices, wanted: wanted)
    }

    public func setFilePriority(ids: [String], fileIndices: [Int], priority: Int) async throws {
        try await session.setFilePriority(ids: ids, fileIndices: fileIndices, priority: priority)
    }

    public func setTorrentPriority(ids: [String], priority: Int) async throws {
        try await session.setTorrentPriority(ids: ids, priority: priority)
    }
}
