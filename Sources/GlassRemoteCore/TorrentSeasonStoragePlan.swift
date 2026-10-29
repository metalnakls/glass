import Foundation

public struct TorrentSeasonStoragePlan: Sendable {
    public let downloadDirectory: String
    public let namingPlan: TorrentAddNamingPlan

    public init(downloadDirectory: String, namingPlan: TorrentAddNamingPlan) {
        self.downloadDirectory = downloadDirectory
        self.namingPlan = namingPlan
    }

    /// Reuse a known physical show root in this library, preserving its spelling.
    /// Other libraries and manually named, non-season downloads remain independent.
    public init(baseDirectory: String, namingPlan: TorrentAddNamingPlan, existing: [Self] = []) {
        guard let season = namingPlan.season else {
            self.init(downloadDirectory: baseDirectory, namingPlan: namingPlan)
            return
        }
        let key = TorrentSeriesIdentity.key(for: season.title)
        let base = URL(fileURLWithPath: baseDirectory).standardizedFileURL
        let selectedShow = TorrentSeriesIdentity.key(for: base.lastPathComponent) == key
            ? base.lastPathComponent : nil
        let directory = Self.baseDirectory(base: baseDirectory, title: season.title)
        let root = existing.first {
            URL(fileURLWithPath: $0.downloadDirectory).standardizedFileURL.path == directory
                && TorrentSeriesIdentity.key(for: $0.namingPlan.rootName) == key
        }?.namingPlan.rootName ?? selectedShow ?? namingPlan.rootName
        self.init(downloadDirectory: directory, namingPlan: namingPlan.withDisplayName(root))
    }

    public static func baseDirectory(base: String, title: String) -> String {
        let baseURL = URL(fileURLWithPath: base).standardizedFileURL
        if TorrentSeriesIdentity.key(for: baseURL.lastPathComponent) == TorrentSeriesIdentity.key(for: title) {
            return baseURL.deletingLastPathComponent().path
        }
        return baseURL.path
    }
}

