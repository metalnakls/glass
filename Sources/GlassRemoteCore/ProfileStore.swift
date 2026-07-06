import Foundation

public protocol ProfileStore: Sendable {
    func loadProfiles() throws -> [RemoteProfile]
    func saveProfiles(_ profiles: [RemoteProfile]) throws
    func loadPreferences() throws -> GlassRemotePreferences
    func savePreferences(_ preferences: GlassRemotePreferences) throws
    func loadTorrentCache() throws -> [CachedTorrentList]
    func saveTorrentCache(_ cache: [CachedTorrentList]) throws
    func loadDownloadDirectoryHistory() throws -> [DownloadDirectoryHistory]
    func saveDownloadDirectoryHistory(_ history: [DownloadDirectoryHistory]) throws
}

public struct FileProfileStore: ProfileStore {
    private let fileURL: URL
    private let preferencesURL: URL
    private let torrentCacheURL: URL
    private let downloadDirectoryHistoryURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.preferencesURL = fileURL.deletingLastPathComponent().appendingPathComponent("preferences.json")
        self.torrentCacheURL = fileURL.deletingLastPathComponent().appendingPathComponent("torrent-cache.json")
        self.downloadDirectoryHistoryURL = fileURL.deletingLastPathComponent().appendingPathComponent("download-directories.json")
    }

    public static func applicationSupportStore(appName: String = "Glass") throws -> FileProfileStore {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return FileProfileStore(fileURL: baseURL.appendingPathComponent(appName).appendingPathComponent("profiles.json"))
    }

    public func loadProfiles() throws -> [RemoteProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([RemoteProfile].self, from: data)
    }

    public func saveProfiles(_ profiles: [RemoteProfile]) throws {
        let data = try encoder.encode(profiles)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    public func loadPreferences() throws -> GlassRemotePreferences {
        guard FileManager.default.fileExists(atPath: preferencesURL.path) else {
            return GlassRemotePreferences()
        }
        let data = try Data(contentsOf: preferencesURL)
        return try decoder.decode(GlassRemotePreferences.self, from: data)
    }

    public func savePreferences(_ preferences: GlassRemotePreferences) throws {
        let data = try encoder.encode(preferences)
        try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: preferencesURL, options: .atomic)
    }

    public func loadTorrentCache() throws -> [CachedTorrentList] {
        guard FileManager.default.fileExists(atPath: torrentCacheURL.path) else {
            return []
        }
        let data = try Data(contentsOf: torrentCacheURL)
        return try decoder.decode([CachedTorrentList].self, from: data)
    }

    public func saveTorrentCache(_ cache: [CachedTorrentList]) throws {
        let data = try encoder.encode(cache)
        try FileManager.default.createDirectory(at: torrentCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: torrentCacheURL, options: .atomic)
    }

    public func loadDownloadDirectoryHistory() throws -> [DownloadDirectoryHistory] {
        guard FileManager.default.fileExists(atPath: downloadDirectoryHistoryURL.path) else {
            return []
        }
        let data = try Data(contentsOf: downloadDirectoryHistoryURL)
        return try decoder.decode([DownloadDirectoryHistory].self, from: data)
    }

    public func saveDownloadDirectoryHistory(_ history: [DownloadDirectoryHistory]) throws {
        let data = try encoder.encode(history)
        try FileManager.default.createDirectory(at: downloadDirectoryHistoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: downloadDirectoryHistoryURL, options: .atomic)
    }
}
